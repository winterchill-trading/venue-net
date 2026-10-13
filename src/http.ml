open! Core
open Async

type response = int * string [@@deriving sexp_of]

let header_list ?content_type headers =
  let header = Cohttp.Header.of_list headers in
  match content_type with
  | None -> header
  | Some content_type ->
    Cohttp.Header.add_unless_exists header "Content-Type" content_type
;;

module Record = struct
  type entry =
    { meth : string
    ; uri : string
    ; request_headers : (string * string) list
    ; request_body : string option
    ; status : int
    ; response_body : string
    }
  [@@deriving sexp_of]

  let env_var = "VENUE_NET_HTTP_RECORD"

  let current_dir =
    ref
      (match Core.Sys.getenv env_var with
       | None | Some "" -> None
       | Some dir -> Some dir)
  ;;

  let set_dir dir = current_dir := dir
  let dir () = !current_dir

  let is_secret name =
    let name = String.lowercase name in
    List.exists [ "key"; "sign"; "auth"; "token"; "passphrase"; "cookie" ] ~f:(fun s ->
      String.is_substring name ~substring:s)
  ;;

  let redacted = "<redacted>"

  let redact_uri uri =
    Uri.with_query
      uri
      (List.map (Uri.query uri) ~f:(fun (k, v) ->
         if is_secret k then k, [ redacted ] else k, v))
  ;;

  let entry_to_json e : Yojson.Safe.t =
    `Assoc
      [ "method", `String e.meth
      ; "uri", `String e.uri
      ; ( "request_headers"
        , `Assoc (List.map e.request_headers ~f:(fun (k, v) -> k, `String v)) )
      ; ( "request_body"
        , match e.request_body with
          | None -> `Null
          | Some b -> `String b )
      ; "status", `Int e.status
      ; "response_body", `String e.response_body
      ]
  ;;

  let entry_of_json json =
    let open Yojson.Safe.Util in
    let string_field name = member name json |> to_string in
    { meth = string_field "method"
    ; uri = string_field "uri"
    ; request_headers =
        member "request_headers" json
        |> to_assoc
        |> List.map ~f:(fun (k, v) -> k, to_string v)
    ; request_body = member "request_body" json |> to_string_option
    ; status = member "status" json |> to_int
    ; response_body = string_field "response_body"
    }
  ;;

  (* [GET-api.example.com-v1-orders-3.json]: method, host and path, then the first free
     index, so repeated calls to one endpoint keep every response. *)
  let slug e =
    let uri = Uri.of_string e.uri in
    let raw = Option.value (Uri.host uri) ~default:"" ^ Uri.path uri in
    let slug =
      String.map raw ~f:(fun c ->
        if Char.is_alphanum c || Char.equal c '.' then c else '-')
      |> String.strip ~drop:(Char.equal '-')
    in
    let slug = if String.length slug > 80 then String.prefix slug 80 else slug in
    e.meth ^ "-" ^ slug
  ;;

  let write dir e =
    let%bind () = Unix.mkdir ~p:() dir in
    let stem = Filename.concat dir (slug e) in
    let rec free n =
      let path = sprintf "%s-%d.json" stem n in
      match%bind Sys.file_exists path with
      | `No -> return path
      | `Yes | `Unknown -> free (n + 1)
    in
    let%bind path = free 1 in
    Writer.save path ~contents:(Yojson.Safe.pretty_to_string (entry_to_json e) ^ "\n")
  ;;

  let save ~headers ~body meth uri ((status, response_body) : int * string) =
    match !current_dir with
    | None -> return ()
    | Some dir ->
      let entry =
        { meth = Cohttp.Code.string_of_method meth
        ; uri = Uri.to_string (redact_uri uri)
        ; request_headers =
            List.map (Cohttp.Header.to_list headers) ~f:(fun (k, v) ->
              k, if is_secret k then redacted else v)
        ; request_body = body
        ; status
        ; response_body
        }
      in
      (match%map Monitor.try_with_or_error (fun () -> write dir entry) with
       | Ok () -> ()
       | Error error ->
         Log.Global.error_s
           [%message "venue-net http: recording failed" (error : Error.t)])
  ;;

  let load path =
    Monitor.try_with_or_error (fun () ->
      let%map contents = Reader.file_contents path in
      entry_of_json (Yojson.Safe.from_string contents))
    |> Deferred.Or_error.tag_s ~tag:[%message "Http.Record.load" (path : string)]
  ;;
end

(* cohttp-async's default TLS config never checks the certificate's host name; see
   [Tls]. Plain [http://] needs no config. *)
let ssl_config uri =
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some host -> Some (Tls.config ~host)
  | _ -> None
;;

let request ?content_type ?(headers = []) ?body meth uri =
  let headers = header_list ?content_type headers in
  let request_body = body in
  let body = Option.map body ~f:Cohttp_async.Body.of_string in
  Monitor.try_with_or_error ~extract_exn:true (fun () ->
    let%bind response, body =
      Cohttp_async.Client.call ~headers ?body ?ssl_config:(ssl_config uri) meth uri
    in
    let%bind body = Cohttp_async.Body.to_string body in
    let response = Cohttp.Code.code_of_status (Cohttp.Response.status response), body in
    let%map () = Record.save ~headers ~body:request_body meth uri response in
    response)
  |> Deferred.Or_error.tag_s
       ~tag:
         (Sexp.List [ Atom (Cohttp.Code.string_of_method meth); Atom (Uri.to_string uri) ])
;;

let get ?headers uri = request ?headers `GET uri
let delete ?headers uri = request ?headers `DELETE uri
let put ?headers ?body uri = request ?headers ?body `PUT uri

let post_json ?headers uri json =
  request
    ~content_type:"application/json"
    ?headers
    ~body:(Yojson.Safe.to_string json)
    `POST
    uri
;;

let post_form ?headers uri params =
  request
    ~content_type:"application/x-www-form-urlencoded"
    ?headers
    ~body:(Uri.encoded_of_query (List.map params ~f:(fun (k, v) -> k, [ v ])))
    `POST
    uri
;;

let request ?headers ?body meth uri = request ?headers ?body meth uri
let is_success status = status >= 200 && status < 300

let decode_json ((status, body) : response) ~f =
  let result =
    if is_success status
    then Or_error.try_with (fun () -> f (Yojson.Safe.from_string body))
    else Or_error.error_string "unexpected HTTP status"
  in
  Or_error.tag_s result ~tag:[%message "" (status : int) (body : string)]
;;
