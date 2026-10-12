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

let request ?content_type ?(headers = []) ?body meth uri =
  let headers = header_list ?content_type headers in
  let body = Option.map body ~f:Cohttp_async.Body.of_string in
  Monitor.try_with_or_error ~extract_exn:true (fun () ->
    let%bind response, body = Cohttp_async.Client.call ~headers ?body meth uri in
    let%map body = Cohttp_async.Body.to_string body in
    Cohttp.Code.code_of_status (Cohttp.Response.status response), body)
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
