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

(* cohttp-async's default TLS config never checks the certificate's host name; see [Tls].
   Plain [http://] needs no config. *)
let ssl_config uri =
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some host -> Some (Tls.config ~host)
  | _ -> None
;;

(* The connection is opened here rather than by [Cohttp_async.Client] so that a timed out
   request can close its socket: cohttp-async keeps the reader and writer to itself, and
   closing one of its [Connection.t]s waits for the running request. The request and
   response are still written and parsed by cohttp ([Private.Make] is the functor its own
   backends use), and the TLS config is the same [Tls.config] cohttp-async was given. *)
module Input = struct
  (* A growable read buffer over an Async [Reader.t], the input channel cohttp's parser
     wants ([refill] plus a view of the buffered bytes). *)
  type t =
    { reader : Reader.t
    ; mutable buf : Bytes.t
    ; mutable pos : int
    ; mutable len : int
    }

  (* Bound on the buffered, unparsed bytes; only a status line plus headers can reach it,
     because bodies are read in pieces no longer than what is buffered. *)
  let max_buffer = 1 lsl 20
  let create reader = { reader; buf = Bytes.create 0x4000; pos = 0; len = 0 }

  let refill t =
    if t.pos > 0
    then (
      Bytes.blit ~src:t.buf ~src_pos:t.pos ~dst:t.buf ~dst_pos:0 ~len:t.len;
      t.pos <- 0);
    if t.len = Bytes.length t.buf
    then (
      if t.len >= max_buffer
      then failwithf "HTTP response header longer than %d bytes" max_buffer ();
      let buf = Bytes.create (2 * Bytes.length t.buf) in
      Bytes.blit ~src:t.buf ~src_pos:0 ~dst:buf ~dst_pos:0 ~len:t.len;
      t.buf <- buf);
    match%map Reader.read t.reader t.buf ~pos:t.len ~len:(Bytes.length t.buf - t.len) with
    | `Eof -> `Eof
    | `Ok n ->
      t.len <- t.len + n;
      `Ok
  ;;

  let consume t n =
    t.pos <- t.pos + n;
    t.len <- t.len - n
  ;;

  let with_input_buffer t ~f =
    let result, consumed =
      f
        (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:t.buf)
        ~pos:t.pos
        ~len:t.len
    in
    consume t consumed;
    result
  ;;

  let take t n =
    let s = Bytes.To_string.sub t.buf ~pos:t.pos ~len:n in
    consume t n;
    s
  ;;

  (* A line ends at LF; a CR before it is dropped. At end of input, buffered bytes are
     returned as a last line. *)
  let rec read_line t =
    let newline = ref (-1) in
    let i = ref t.pos in
    while !newline < 0 && !i < t.pos + t.len do
      if Char.equal (Bytes.get t.buf !i) '\n' then newline := !i;
      incr i
    done;
    if !newline >= 0
    then (
      let n = !newline - t.pos in
      let line = take t (n + 1) in
      let line = String.prefix line n in
      return (Some (String.chop_suffix_if_exists line ~suffix:"\r")))
    else (
      match%bind refill t with
      | `Ok -> read_line t
      | `Eof -> return (if t.len = 0 then None else Some (take t t.len)))
  ;;

  let rec read t n =
    if t.len > 0
    then return (take t (Int.min n t.len))
    else (
      match%bind refill t with
      | `Ok -> read t n
      | `Eof -> return "")
  ;;
end

module Io = struct
  type 'a t = 'a Deferred.t

  let ( >>= ) = Deferred.( >>= )
  let return = Deferred.return

  type ic = Input.t
  type oc = Writer.t
  type conn = unit

  let refill = Input.refill
  let with_input_buffer = Input.with_input_buffer
  let read_line = Input.read_line
  let read = Input.read

  let write oc s =
    Writer.write oc s;
    return ()
  ;;

  let flush = Writer.flushed
end

module Request_io = Cohttp.Request.Private.Make (Io)
module Response_io = Cohttp.Response.Private.Make (Io)

let port uri =
  match Uri.port uri, Uri.scheme uri with
  | Some port, _ -> port
  | None, Some "https" -> 443
  | None, _ -> 80
;;

(* IPv4 first address, as cohttp-async resolves it. *)
let address uri =
  let host = Option.value (Uri.host uri) ~default:"localhost" in
  match%map Unix.Addr_info.get ~host [ AI_FAMILY PF_INET; AI_SOCKTYPE SOCK_STREAM ] with
  | { ai_addr = ADDR_INET (addr, _); _ } :: _ ->
    let addr = Ipaddr_unix.of_inet_addr addr in
    (match ssl_config uri with
     | Some config -> `OpenSSL (addr, port uri, config)
     | None -> `TCP (addr, port uri))
  | _ -> raise_s [%message "Failed to resolve Uri" ~uri:(Uri.to_string uri : string)]
;;

let read_body (meth : Cohttp.Code.meth) response ic =
  let has_body =
    match meth with
    | `HEAD -> `No
    | _ -> Cohttp.Response.has_body response
  in
  match has_body with
  | `No -> return ""
  | `Yes | `Unknown ->
    let reader = Response_io.make_body_reader response ic in
    let buffer = Buffer.create 4096 in
    let rec loop () =
      match%bind Response_io.read_body_chunk reader with
      | Chunk s ->
        Buffer.add_string buffer s;
        loop ()
      | Final_chunk s ->
        Buffer.add_string buffer s;
        return (Buffer.contents buffer)
      | Done -> return (Buffer.contents buffer)
    in
    loop ()
;;

let close_socket (reader, writer) =
  let%bind () = Writer.close writer in
  Reader.close reader
;;

(* One request on a fresh connection, closed afterwards. [socket] is filled once the
   connection exists, so a caller that gives up can close it. *)
let exchange ~interrupt ~socket ~headers ~body meth uri =
  let%bind address = address uri in
  let%bind reader, writer = Conduit_async.V2.connect ?interrupt address in
  Ivar.fill_if_empty socket (reader, writer);
  Monitor.protect
    ~finally:(fun () -> close_socket (reader, writer))
    (fun () ->
      let body = Option.value body ~default:"" in
      let request =
        Cohttp.Request.make_for_client
          ~headers
          ~chunked:false
          ~body_length:(Int64.of_int (String.length body))
          meth
          uri
      in
      let%bind () =
        Request_io.write
          ~flush:true
          (fun w ->
            if String.is_empty body then return () else Request_io.write_body w body)
          request
          writer
      in
      let ic = Input.create reader in
      match%bind Response_io.read ic with
      | `Eof -> failwith "Connection closed by remote host"
      | `Invalid reason -> failwith reason
      | `Ok response ->
        let%map body = read_body meth response ic in
        Cohttp.Code.code_of_status (Cohttp.Response.status response), body)
;;

let request ?content_type ?(headers = []) ?body ?timeout meth uri =
  let headers = header_list ?content_type headers in
  let request_body = body in
  let socket = Ivar.create () in
  (* The deadline also interrupts the TCP connect (and TLS handshake) in conduit. *)
  let deadline = Option.map timeout ~f:(fun timeout -> timeout, Clock_ns.after timeout) in
  let attempt =
    Monitor.try_with_or_error ~rest:`Log ~extract_exn:true (fun () ->
      exchange ~interrupt:(Option.map deadline ~f:snd) ~socket ~headers ~body meth uri)
  in
  let result =
    match deadline with
    | None -> attempt
    | Some (timeout, deadline) ->
      (match%map
         Deferred.choose
           [ Deferred.choice attempt (fun result -> `Result result)
           ; Deferred.choice deadline (fun () -> `Timeout)
           ]
       with
       | `Result result -> result
       | `Timeout ->
         (* Closing the socket fails the pending read, so nothing is left running. *)
         upon (Ivar.read socket) (fun socket -> don't_wait_for (close_socket socket));
         Or_error.error_s [%message "HTTP request timed out" (timeout : Time_ns.Span.t)])
  in
  (let%bind.Deferred.Or_error response = result in
   let%map () = Record.save ~headers ~body:request_body meth uri response in
   Ok response)
  |> Deferred.Or_error.tag_s
       ~tag:
         (Sexp.List [ Atom (Cohttp.Code.string_of_method meth); Atom (Uri.to_string uri) ])
;;

let get ?headers ?timeout uri = request ?headers ?timeout `GET uri
let delete ?headers ?timeout uri = request ?headers ?timeout `DELETE uri
let put ?headers ?body ?timeout uri = request ?headers ?body ?timeout `PUT uri

let post_json ?headers ?timeout uri json =
  request
    ~content_type:"application/json"
    ?headers
    ?timeout
    ~body:(Yojson.Safe.to_string json)
    `POST
    uri
;;

let post_form ?headers ?timeout uri params =
  request
    ~content_type:"application/x-www-form-urlencoded"
    ?headers
    ?timeout
    ~body:(Uri.encoded_of_query (List.map params ~f:(fun (k, v) -> k, [ v ])))
    `POST
    uri
;;

let request ?headers ?body ?timeout meth uri = request ?headers ?body ?timeout meth uri
let is_success status = status >= 200 && status < 300

let decode_json ((status, body) : response) ~f =
  let result =
    if is_success status
    then Or_error.try_with (fun () -> f (Yojson.Safe.from_string body))
    else Or_error.error_string "unexpected HTTP status"
  in
  Or_error.tag_s result ~tag:[%message "" (status : int) (body : string)]
;;
