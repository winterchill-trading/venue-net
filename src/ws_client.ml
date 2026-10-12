open! Core
open Async

module Ping = struct
  type t =
    [ `Text of string * Time_ns.Span.t
    | `Frame of Time_ns.Span.t
    | `None
    ]
  [@@deriving sexp_of]

  let interval : t -> _ = function
    | `Text (_, interval) | `Frame interval -> Some interval
    | `None -> None
  ;;
end

let base64 s =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let buf = Buffer.create ((n + 2) / 3 * 4) in
  let byte i = if i < n then Char.to_int s.[i] else 0 in
  let i = ref 0 in
  while !i < n do
    let b = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) lor byte (!i + 2) in
    let sextet shift = alphabet.[(b lsr shift) land 63] in
    Buffer.add_char buf (sextet 18);
    Buffer.add_char buf (sextet 12);
    Buffer.add_char buf (if !i + 1 < n then sextet 6 else '=');
    Buffer.add_char buf (if !i + 2 < n then sextet 0 else '=');
    i := !i + 3
  done;
  Buffer.contents buf
;;

let default_port uri =
  match Uri.port uri, Uri.scheme uri with
  | Some port, _ -> port
  | None, Some ("wss" | "https") -> 443
  | None, _ -> 80
;;

let is_tls uri =
  match Uri.scheme uri with
  | Some ("wss" | "https") -> true
  | _ -> false
;;

let handshake_request ?(headers = []) uri ~key =
  let host = Option.value (Uri.host uri) ~default:"localhost" in
  let host =
    match Uri.port uri with
    | None -> host
    | Some port -> sprintf "%s:%d" host port
  in
  let path =
    match Uri.path_and_query uri with
    | "" -> "/"
    | path -> path
  in
  String.concat
    ([ sprintf "GET %s HTTP/1.1\r\n" path
     ; sprintf "Host: %s\r\n" host
     ; "Upgrade: websocket\r\n"
     ; "Connection: Upgrade\r\n"
     ; sprintf "Sec-WebSocket-Key: %s\r\n" key
     ; "Sec-WebSocket-Version: 13\r\n"
     ]
     @ List.map headers ~f:(fun (name, value) -> sprintf "%s: %s\r\n" name value)
     @ [ "\r\n" ])
;;

let check_handshake_response ~key ~status_line ~headers =
  let header name =
    List.find_map headers ~f:(fun (k, v) ->
      Option.some_if (String.Caseless.equal k name) (String.strip v))
  in
  match String.split status_line ~on:' ' with
  | _ :: "101" :: _ ->
    let expected = Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key in
    (match header "Sec-WebSocket-Accept" with
     | Some accept when String.equal accept expected -> Ok ()
     | accept ->
       Or_error.error_s
         [%message
           "bad Sec-WebSocket-Accept" (accept : string option) (expected : string)])
  | _ -> Or_error.error_s [%message "websocket upgrade refused" (status_line : string)]
;;

let next_backoff ~max span = Time_ns.Span.min max (Time_ns.Span.scale span 2.)

let backoff ~initial ~max ~attempts =
  List.folding_map (List.range 0 attempts) ~init:initial ~f:(fun span _ ->
    next_backoff ~max span, span)
;;

(* The key only has to be unpredictable enough to defeat caching proxies. Seeded from the
   clock because Base forbids [Random.State.make_self_init] inside inline tests. *)
let random_state =
  lazy (Random.State.make [| Time_ns.to_int_ns_since_epoch (Time_ns.now ()) |])
;;

(* Spreads [span] uniformly over [span * (1 - jitter), span * (1 + jitter)], so clients
   that lost their connections together do not all come back at the same instant. *)
let jittered ~jitter ~random_state span =
  if Float.(jitter <= 0.)
  then span
  else (
    let jitter = Float.min jitter 1. in
    Time_ns.Span.scale span (1. +. (jitter *. (Random.State.float random_state 2. -. 1.))))
;;

let new_key () =
  let state = force random_state in
  base64 (String.init 16 ~f:(fun _ -> Char.of_int_exn (Random.State.int state 256)))
;;

(* Reads the status line and headers of the upgrade response. Bytes after the blank line
   stay buffered in [reader] for the websocket framing layer. *)
let read_handshake_response reader =
  let read_line () =
    match%map Reader.read_line reader with
    | `Ok line -> Ok line
    | `Eof -> Or_error.error_string "connection closed during websocket handshake"
  in
  let rec read_headers acc =
    match%bind read_line () with
    | Error _ as e -> return e
    | Ok "" -> return (Ok (List.rev acc))
    | Ok line ->
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> read_headers ((k, v) :: acc)
       | None -> read_headers acc)
  in
  match%bind read_line () with
  | Error _ as e -> return e
  | Ok status_line ->
    let%map headers = read_headers [] in
    Or_error.map headers ~f:(fun headers -> status_line, headers)
;;

let tcp_connect uri =
  let host = Option.value (Uri.host uri) ~default:"localhost" in
  let uri = Uri.with_port uri (Some (default_port uri)) in
  let%bind addr = Conduit_async.V3.resolve_uri uri in
  let addr : _ Conduit_async.V3.addr =
    match addr with
    | (OpenSSL (inet, _) | Inet inet) when is_tls uri ->
      (* [resolve_uri] builds a TLS config without SNI, which CDNs reject. *)
      OpenSSL (inet, Conduit_async.V3.Ssl.Config.create ~hostname:host ())
    | addr -> addr
  in
  let%map _socket, reader, writer = Conduit_async.V3.connect addr in
  reader, writer
;;

module Connection = struct
  type t =
    { ws : string Websocket.t
    ; from_server : string Pipe.Reader.t
    ; to_server : string Pipe.Writer.t
    }

  let close t = Websocket.close t.ws ~code:Normal_closure ~reason:""

  let close_socket (reader, writer) =
    let%bind () = Writer.close writer in
    Reader.close reader
  ;;

  (* TCP connect plus upgrade handshake, bounded by [timeout] on [time_source]. A timed
     out attempt is not left running: its socket is closed as soon as it exists, which
     fails a pending handshake read, and a connection that still completes is closed. *)
  let open_ ~time_source ~timeout ~headers uri =
    let socket = Ivar.create () in
    let attempt =
      Monitor.try_with_or_error ~rest:`Log ~extract_exn:true (fun () ->
        let%bind reader, writer = tcp_connect uri in
        Ivar.fill_exn socket (reader, writer);
        let fail err =
          let%bind () = close_socket (reader, writer) in
          Error.raise err
        in
        let key = new_key () in
        Writer.write writer (handshake_request ~headers uri ~key);
        let%bind () = Writer.flushed writer in
        match%bind read_handshake_response reader with
        | Error err -> fail err
        | Ok (status_line, response_headers) ->
          (match check_handshake_response ~key ~status_line ~headers:response_headers with
           | Error err -> fail err
           | Ok () ->
             let ws = Websocket.create ~opcode:`Text ~role:Client reader writer in
             let from_server, to_server = Websocket.pipes ws in
             return { ws; from_server; to_server }))
    in
    (match%map Time_source.with_timeout time_source timeout attempt with
     | `Result result -> result
     | `Timeout ->
       upon (Ivar.read socket) (fun socket -> don't_wait_for (close_socket socket));
       upon attempt (function
         | Ok connection -> don't_wait_for (close connection)
         | Error _ -> ());
       Or_error.error_s
         [%message "websocket handshake timed out" (timeout : Time_ns.Span.t)])
    |> Deferred.Or_error.tag_s
         ~tag:[%message "websocket connect" ~uri:(Uri.to_string uri : string)]
  ;;

  let send t frame = Pipe.write_if_open t.to_server frame

  let send_ping t (ping : Ping.t) =
    match ping with
    | `Text (payload, _) -> send t payload
    | `Frame _ ->
      Websocket.send_ping t.ws "";
      return ()
    | `None -> return ()
  ;;
end

type t =
  { url : Uri.t
  ; headers : (string * string) list
  ; ping : Ping.t
  ; max_silent_intervals : int
  ; initial_backoff : Time_ns.Span.t
  ; max_backoff : Time_ns.Span.t
  ; backoff_jitter : float
  ; handshake_timeout : Time_ns.Span.t
  ; on_connect : t -> unit Deferred.t
  ; log_name : string
  ; time_source : Time_source.t
  ; mutable connection : Connection.t option
  ; mutable reconnects : int
  ; messages_reader : string Pipe.Reader.t
  ; messages_writer : string Pipe.Writer.t
  ; closed : unit Ivar.t
  }

let url t = t.url
let messages t = t.messages_reader
let is_connected t = Option.is_some t.connection
let reconnects t = t.reconnects
let is_closed t = Ivar.is_full t.closed

let send t frame =
  match t.connection with
  | None -> return ()
  | Some connection -> Connection.send connection frame
;;

let url_string t = Uri.to_string t.url

let run_on_connect t =
  don't_wait_for
    (match%map Monitor.try_with_or_error ~extract_exn:true (fun () -> t.on_connect t) with
     | Ok () -> ()
     | Error error ->
       Log.Global.error_s
         [%message
           (sprintf "%s: on_connect failed" t.log_name)
             ~url:(url_string t : string)
             (error : Error.t)])
;;

(* Sends the keepalive every interval and closes the connection after
   [max_silent_intervals] consecutive intervals with no incoming frame. *)
let watch t (connection : Connection.t) ~received =
  match Ping.interval t.ping with
  | None -> ()
  | Some interval ->
    let silent_intervals = ref 0 in
    Time_source.every'
      ~start:(Time_source.after t.time_source interval)
      ~stop:(Pipe.closed connection.from_server)
      t.time_source
      interval
      (fun () ->
         if !received then silent_intervals := 0 else incr silent_intervals;
         received := false;
         if !silent_intervals >= t.max_silent_intervals
         then (
           Log.Global.info_s
             [%message
               (sprintf "%s: no data received, reconnecting" t.log_name)
                 ~url:(url_string t : string)];
           Connection.close connection)
         else Connection.send_ping connection t.ping)
;;

(* Runs one connection until it closes. *)
let serve t (connection : Connection.t) =
  t.connection <- Some connection;
  let received = ref true in
  (* Control frames (pongs, server pings) count as activity too. *)
  let frames = Websocket.frame_received connection.ws in
  if not (Bus.is_closed frames)
  then (
    let (_ : _ Bus.Subscriber.t) =
      Bus.subscribe_exn frames ~f:(fun _ -> received := true)
    in
    ());
  watch t connection ~received;
  run_on_connect t;
  let%bind () =
    Pipe.iter_without_pushback connection.from_server ~f:(fun frame ->
      received := true;
      Pipe.write_without_pushback_if_open t.messages_writer frame)
  in
  t.connection <- None;
  let%map reason = Websocket.close_finished connection.ws in
  Log.Global.info_s
    [%message
      (sprintf "%s: disconnected" t.log_name)
        ~url:(url_string t : string)
        (reason : Websocket.Connection_close_reason.t * string * Core.Info.t option)]
;;

let rec reconnect_loop t ~delay =
  if is_closed t
  then return ()
  else (
    let sleep =
      jittered ~jitter:t.backoff_jitter ~random_state:(force random_state) delay
    in
    Log.Global.info_s
      [%message
        (sprintf "%s: reconnecting" t.log_name)
          ~url:(url_string t : string)
          ~after:(sleep : Time_ns.Span.t)];
    let%bind () =
      Deferred.any [ Time_source.after t.time_source sleep; Ivar.read t.closed ]
    in
    if is_closed t
    then return ()
    else (
      match%bind
        Connection.open_
          ~time_source:t.time_source
          ~timeout:t.handshake_timeout
          ~headers:t.headers
          t.url
      with
      | Error error ->
        Log.Global.error_s
          [%message (sprintf "%s: reconnect failed" t.log_name) (error : Error.t)];
        reconnect_loop t ~delay:(next_backoff ~max:t.max_backoff delay)
      | Ok connection ->
        if is_closed t
        then Connection.close connection
        else (
          t.reconnects <- t.reconnects + 1;
          Log.Global.info_s
            [%message (sprintf "%s: reconnected" t.log_name) ~url:(url_string t : string)];
          let%bind () = serve t connection in
          reconnect_loop t ~delay:t.initial_backoff)))
;;

let connect
  ?(headers = [])
  ?(ping = `None)
  ?(max_silent_intervals = 2)
  ?(initial_backoff = Time_ns.Span.of_sec 0.5)
  ?(max_backoff = Time_ns.Span.of_sec 30.)
  ?(backoff_jitter = 0.2)
  ?(handshake_timeout = Time_ns.Span.of_sec 10.)
  ?(on_connect = fun _ -> return ())
  ?(log_name = "venue-net ws")
  ?(time_source = Time_source.wall_clock ())
  ~url
  ()
  =
  let%map.Deferred.Or_error connection =
    Connection.open_ ~time_source ~timeout:handshake_timeout ~headers url
  in
  let messages_reader, messages_writer = Pipe.create () in
  let t =
    { url
    ; headers
    ; ping
    ; max_silent_intervals
    ; initial_backoff
    ; max_backoff
    ; backoff_jitter
    ; handshake_timeout
    ; on_connect
    ; log_name
    ; time_source
    ; connection = None
    ; reconnects = 0
    ; messages_reader
    ; messages_writer
    ; closed = Ivar.create ()
    }
  in
  don't_wait_for
    (let%bind () = serve t connection in
     reconnect_loop t ~delay:initial_backoff);
  t
;;

let close t =
  if is_closed t
  then return ()
  else (
    Ivar.fill_exn t.closed ();
    Pipe.close t.messages_writer;
    match t.connection with
    | None -> return ()
    | Some connection -> Connection.close connection)
;;

module For_testing = struct
  let base64 = base64
  let handshake_request = handshake_request
  let check_handshake_response = check_handshake_response
  let backoff = backoff
  let jittered = jittered
end
