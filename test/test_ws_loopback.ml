(* End-to-end tests of [Ws_client] against a websocket server on 127.0.0.1, built from the
   same async_websocket library with [~role:Server]. *)

open! Core
open Async
open Venue_net

module Server = struct
  type t =
    { tcp : (Socket.Address.Inet.t, int) Tcp.Server.t
    ; requests : (string * string) list Queue.t (** request headers, per connection *)
    ; received : (int * string) Queue.t (** (connection number, frame) *)
    ; sockets : string Websocket.t Queue.t
    }

  let rec read_headers reader acc =
    match%bind Reader.read_line reader with
    | `Eof | `Ok "" -> return (List.rev acc)
    | `Ok line ->
      read_headers
        reader
        (match String.lsplit2 line ~on:':' with
         | Some (k, v) -> (String.lowercase k, String.strip v) :: acc
         | None -> acc)
  ;;

  (* "ping" -> "pong" (when [pong]); "sub:x" -> "ack:x@<connection number>". *)
  let reply ~pong to_client n frame =
    match String.chop_prefix frame ~prefix:"sub:" with
    | Some topic -> Pipe.write_without_pushback to_client (sprintf "ack:%s@%d" topic n)
    | None ->
      if pong && String.equal frame "ping"
      then Pipe.write_without_pushback to_client "pong"
  ;;

  let handle ~pong ~refuse t reader writer =
    let%bind headers = read_headers reader [] in
    Queue.enqueue t.requests headers;
    if refuse
    then (
      Writer.write writer "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
      Writer.flushed writer)
    else (
      let key = List.Assoc.find_exn headers ~equal:String.equal "sec-websocket-key" in
      Writer.write
        writer
        (sprintf
           "HTTP/1.1 101 Switching Protocols\r\n\
            Upgrade: websocket\r\n\
            Connection: Upgrade\r\n\
            Sec-WebSocket-Accept: %s\r\n\
            \r\n"
           (Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key));
      let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
      Queue.enqueue t.sockets ws;
      let n = Queue.length t.sockets in
      let from_client, to_client = Websocket.pipes ws in
      if n = 1 then Pipe.write_without_pushback to_client "hello 1";
      Pipe.iter_without_pushback from_client ~f:(fun frame ->
        Queue.enqueue t.received (n, frame);
        reply ~pong to_client n frame))
  ;;

  let start ?(pong = true) ?(refuse = false) () =
    let requests = Queue.create () in
    let received = Queue.create () in
    let sockets = Queue.create () in
    let t_ref = ref None in
    let%map tcp =
      Tcp.Server.create
        ~on_handler_error:`Ignore
        Tcp.Where_to_listen.of_port_chosen_by_os
        (fun _ reader writer ->
           handle ~pong ~refuse (Option.value_exn !t_ref) reader writer)
    in
    let t = { tcp; requests; received; sockets } in
    t_ref := Some t;
    t
  ;;

  let url t =
    Uri.of_string (sprintf "ws://127.0.0.1:%d/stream" (Tcp.Server.listening_on t.tcp))
  ;;

  let close t = Tcp.Server.close ~close_existing_connections:true t.tcp

  let frames_from t n =
    List.filter_map (Queue.to_list t.received) ~f:(fun (m, frame) ->
      Option.some_if (m = n) frame)
  ;;
end

(* Waits for [values_available] rather than racing [Pipe.read] against the timeout: a
   timed out [Pipe.read] stays queued on the pipe and would swallow the next message. *)
let read_and_print messages n =
  Deferred.repeat_until_finished n (fun n ->
    if n = 0
    then return (`Finished ())
    else (
      match%map
        Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) (Pipe.values_available messages)
      with
      | `Timeout ->
        print_endline "timeout";
        `Finished ()
      | `Result `Eof ->
        print_endline "eof";
        `Finished ()
      | `Result `Ok ->
        (match Pipe.read_now messages with
         | `Ok message -> print_endline message
         | `Eof | `Nothing_available -> ());
        `Repeat (n - 1)))
;;

let ms = Time_ns.Span.of_int_ms

let%expect_test "handshake, on_connect, server close, reconnect and shutdown" =
  Log.Global.set_output [];
  let%bind server = Server.start () in
  let%bind ws =
    Ws_client.connect
      ~headers:[ "X-Test", "yes" ]
      ~initial_backoff:(ms 10)
      ~on_connect:(fun ws ->
        printf "on_connect reconnects=%d\n" (Ws_client.reconnects ws);
        Ws_client.send ws "sub:trades")
      ~url:(Server.url server)
      ()
    >>| ok_exn
  in
  let messages = Ws_client.messages ws in
  let%bind () = read_and_print messages 2 in
  print_s
    [%sexp
      (List.Assoc.find (Queue.get server.requests 0) ~equal:String.equal "x-test"
       : string option)];
  [%expect {|
    on_connect reconnects=0
    hello 1
    ack:trades@1
    (yes)
    |}];
  (* The server drops the connection; the client reconnects and [on_connect] resends. *)
  let%bind () =
    Websocket.close
      (Queue.get server.sockets 0)
      ~code:Endpoint_going_away
      ~reason:"restart"
  in
  let%bind () = read_and_print messages 1 in
  print_s
    [%sexp
      { connected = (Ws_client.is_connected ws : bool)
      ; reconnects = (Ws_client.reconnects ws : int)
      }];
  [%expect
    {|
    on_connect reconnects=1
    ack:trades@2
    ((connected true) (reconnects 1))
    |}];
  let%bind () = Ws_client.send ws "ping" in
  let%bind () = read_and_print messages 1 in
  let%bind () = Ws_client.close ws in
  let%bind () = Ws_client.close ws in
  let%bind () = read_and_print messages 1 in
  (* Give a stray reconnect attempt the chance to show up. *)
  let%bind () = Clock_ns.after (ms 50) in
  print_s
    [%sexp
      { closed = (Ws_client.is_closed ws : bool)
      ; connections = (Queue.length server.sockets : int)
      ; received = (Queue.to_list server.received : (int * string) list)
      }];
  [%expect
    {|
    pong
    eof
    ((closed true) (connections 2)
     (received ((1 sub:trades) (2 sub:trades) (2 ping))))
    |}];
  Server.close server
;;

let%expect_test "a text keepalive keeps a responsive connection" =
  Log.Global.set_output [];
  let%bind server = Server.start () in
  let%bind ws =
    Ws_client.connect ~ping:(`Text ("ping", ms 20)) ~url:(Server.url server) () >>| ok_exn
  in
  let%bind () = Clock_ns.after (ms 300) in
  let%bind () = Ws_client.close ws in
  let pings = List.count (Server.frames_from server 1) ~f:(String.equal "ping") in
  print_s
    [%sexp
      { connections = (Queue.length server.sockets : int)
      ; reconnects = (Ws_client.reconnects ws : int)
      ; at_least_five_pings = (pings >= 5 : bool)
      }];
  [%expect {| ((connections 1) (reconnects 0) (at_least_five_pings true)) |}];
  Server.close server
;;

let%expect_test "a silent connection is replaced" =
  Log.Global.set_output [];
  let%bind server = Server.start ~pong:false () in
  let reconnected = Ivar.create () in
  let%bind ws =
    Ws_client.connect
      ~ping:(`Text ("ping", ms 50))
      ~initial_backoff:(ms 10)
      ~on_connect:(fun ws ->
        if Ws_client.reconnects ws > 0 then Ivar.fill_if_empty reconnected ();
        return ())
      ~url:(Server.url server)
      ()
    >>| ok_exn
  in
  (* "hello 1" counts as traffic, so the first tick pings; the next two intervals are
     silent ([max_silent_intervals] defaults to 2): one more ping, then the socket is
     closed and replaced. *)
  let%bind result =
    Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) (Ivar.read reconnected)
  in
  let%bind () = Ws_client.close ws in
  print_s
    [%sexp
      ((match result with
        | `Result () -> "reconnected"
        | `Timeout -> "timeout")
       : string)
      , (Queue.length server.sockets : int)
      , (Server.frames_from server 1 : string list)];
  [%expect {| (reconnected 2 (ping ping)) |}];
  Server.close server
;;

let%expect_test "pongs to ping frames count as traffic" =
  Log.Global.set_output [];
  (* The server never sends data, but its websocket layer answers ping frames. *)
  let%bind server = Server.start ~pong:false () in
  let%bind ws =
    Ws_client.connect
      ~ping:(`Frame (ms 20))
      ~max_silent_intervals:1
      ~url:(Server.url server)
      ()
    >>| ok_exn
  in
  let%bind () = Clock_ns.after (ms 300) in
  let%bind () = Ws_client.close ws in
  print_s
    [%sexp
      { connections = (Queue.length server.sockets : int)
      ; reconnects = (Ws_client.reconnects ws : int)
      ; text_frames = (Server.frames_from server 1 : string list)
      }];
  [%expect {| ((connections 1) (reconnects 0) (text_frames ())) |}];
  Server.close server
;;

let%expect_test "a refused upgrade fails connect" =
  Log.Global.set_output [];
  let%bind server = Server.start ~refuse:true () in
  let%bind result = Ws_client.connect ~url:(Server.url server) () in
  (match result with
   | Ok _ -> print_endline "unexpected success"
   | Error error ->
     print_s
       (match Error.sexp_of_t error with
        | List [ _tag; inner ] -> inner
        | sexp -> sexp));
  [%expect {| ("websocket upgrade refused" (status_line "HTTP/1.1 404 Not Found")) |}];
  Server.close server
;;

let%expect_test "on_message gets every frame across a reconnect; messages stays empty" =
  Log.Global.set_output [];
  let%bind server = Server.start () in
  let got = Queue.create () in
  let wanted = ref 0 in
  let reached = ref (Ivar.create ()) in
  let wait_for n =
    wanted := n;
    reached := Ivar.create ();
    if Queue.length got >= n then Ivar.fill_if_empty !reached ();
    Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) (Ivar.read !reached)
    >>| function
    | `Result () -> ()
    | `Timeout -> print_endline "timeout"
  in
  let raised = Queue.create () in
  let%bind ws =
    (* [on_message] raises on "boom"; the exception reaches the monitor current at
       [connect] and delivery goes on. *)
    Monitor.try_with
      ~rest:(`Call (fun exn -> Queue.enqueue raised (Exn.to_string exn)))
      (fun () ->
        Ws_client.connect
          ~initial_backoff:(ms 10)
          ~on_connect:(fun ws -> Ws_client.send ws "sub:trades")
          ~on_message:(fun frame ->
            Queue.enqueue got frame;
            if Queue.length got >= !wanted then Ivar.fill_if_empty !reached ();
            if String.equal frame "ack:boom@1" then failwith "boom")
          ~url:(Server.url server)
          ())
    >>| Result.ok_exn
    >>| ok_exn
  in
  let%bind () = wait_for 2 in
  let%bind () = Ws_client.send ws "sub:boom" in
  let%bind () = wait_for 3 in
  let%bind () =
    Websocket.close
      (Queue.get server.sockets 0)
      ~code:Endpoint_going_away
      ~reason:"restart"
  in
  let%bind () = wait_for 4 in
  let%bind () = Ws_client.send ws "ping" in
  let%bind () = wait_for 5 in
  let%bind () = Ws_client.close ws in
  let%bind () = Pipe.closed (Ws_client.messages ws) in
  print_s
    [%sexp
      { frames = (Queue.to_list got : string list)
      ; raised = (Queue.length raised : int)
      ; messages = (Pipe.length (Ws_client.messages ws) : int)
      ; reconnects = (Ws_client.reconnects ws : int)
      }];
  [%expect
    {|
    ((frames ("hello 1" ack:trades@1 ack:boom@1 ack:trades@2 pong)) (raised 1)
     (messages 0) (reconnects 1))
    |}];
  Server.close server
;;
