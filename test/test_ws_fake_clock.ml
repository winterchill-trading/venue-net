(* [Ws_client] timers on a synthetic clock. Sockets are real (127.0.0.1), so the tests
   wait in real time for I/O and step the synthetic clock for every delay. *)

open! Core
open Async
open Venue_net

module Server = struct
  (* What the server does with each successive connection. *)
  type behaviour =
    | Accept
    | Refuse (** answers the upgrade with 404 *)
    | Stall (** reads the upgrade request and never answers *)

  type t =
    { tcp : (Socket.Address.Inet.t, int) Tcp.Server.t
    ; mutable script : behaviour list
    ; mutable connections : int
    ; mutable client_gone : int (** stalled connections the client has closed *)
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

  let rec drain reader =
    match%bind Reader.read_line reader with
    | `Eof -> return ()
    | `Ok _ -> drain reader
  ;;

  let handle t reader writer =
    t.connections <- t.connections + 1;
    let behaviour =
      match t.script with
      | [] -> Accept
      | b :: rest ->
        t.script <- rest;
        b
    in
    let%bind headers = read_headers reader [] in
    match behaviour with
    | Stall ->
      let%map () = drain reader in
      t.client_gone <- t.client_gone + 1
    | Refuse ->
      Writer.write writer "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
      Writer.flushed writer
    | Accept ->
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
      let from_client, _to_client = Websocket.pipes ws in
      Pipe.drain from_client
  ;;

  let start script =
    let t_ref = ref None in
    let%map tcp =
      Tcp.Server.create
        ~on_handler_error:`Ignore
        Tcp.Where_to_listen.of_port_chosen_by_os
        (fun _ reader writer -> handle (Option.value_exn !t_ref) reader writer)
    in
    let t =
      { tcp; script; connections = 0; client_gone = 0; sockets = Queue.create () }
    in
    t_ref := Some t;
    t
  ;;

  let url t =
    Uri.of_string (sprintf "ws://127.0.0.1:%d/stream" (Tcp.Server.listening_on t.tcp))
  ;;

  let close t = Tcp.Server.close ~close_existing_connections:true t.tcp
end

let sec = Time_ns.Span.of_sec

(* Polls [f] in real time; I/O on the loopback sockets completes in milliseconds. *)
let wait_until ?(timeout = sec 5.) f =
  let deadline = Time_ns.add (Time_ns.now ()) timeout in
  Deferred.repeat_until_finished () (fun () ->
    if f ()
    then return (`Finished true)
    else if Time_ns.( > ) (Time_ns.now ()) deadline
    then return (`Finished false)
    else (
      let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      `Repeat ()))
;;

(* Lets real I/O that should NOT happen have a chance to happen. *)
let settle () = Clock_ns.after (Time_ns.Span.of_int_ms 50)

(* The delay of the next alarm on [clock], if it is shorter than [below]. Used to see the
   reconnect sleep the client has scheduled, ignoring longer timers. *)
let next_alarm_within clock ~below =
  match Time_source.next_alarm_fires_at clock with
  | None -> None
  | Some at ->
    let delay = Time_ns.diff at (Time_source.now clock) in
    Option.some_if Time_ns.Span.(delay < below) delay
;;

let open_fds () =
  let%map entries = Sys.readdir "/dev/fd" in
  Array.length entries
;;

let%expect_test "reconnect delays follow the backoff on a synthetic clock" =
  Log.Global.set_output [];
  let%bind server = Server.start [ Accept; Refuse; Refuse; Accept ] in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let reconnected = Ivar.create () in
  let%bind ws =
    Ws_client.connect
      ~time_source:(Time_source.read_only clock)
      ~initial_backoff:(sec 1.)
      ~backoff_jitter:0.
      ~handshake_timeout:(sec 60.)
      ~on_connect:(fun ws ->
        if Ws_client.reconnects ws > 0 then Ivar.fill_if_empty reconnected ();
        return ())
      ~url:(Server.url server)
      ()
    >>| ok_exn
  in
  let%bind () =
    Websocket.close (Queue.get server.sockets 0) ~code:Endpoint_going_away ~reason:"bye"
  in
  let%bind (_ : bool) = wait_until (fun () -> not (Ws_client.is_connected ws)) in
  (* Each step: the client schedules a sleep on the synthetic clock; nothing reaches the
     server until the clock moves past it. *)
  let rec step n =
    if Ivar.is_full reconnected
    then return ()
    else (
      let%bind (_ : bool) =
        wait_until (fun () -> Option.is_some (next_alarm_within clock ~below:(sec 30.)))
      in
      let delay = Option.value_exn (next_alarm_within clock ~below:(sec 30.)) in
      let before = server.connections in
      let%bind () =
        Time_source.advance_by_alarms_by clock (Time_ns.Span.( - ) delay (sec 0.01))
      in
      let%bind () = settle () in
      let early = server.connections - before in
      let%bind () = Time_source.advance_by_alarms_by clock (sec 0.01) in
      let%bind (_ : bool) =
        wait_until (fun () -> server.connections > before || Ivar.is_full reconnected)
      in
      (* Alarms fire on timing-wheel slots, so the scheduled delay is rounded up by a
         fraction of a millisecond. *)
      let delay_ms = Float.iround_nearest_exn (Time_ns.Span.to_ms delay) in
      print_s
        [%message
          (n : int) (delay_ms : int) (early : int) ~connections:(server.connections : int)];
      let%bind (_ : bool) =
        wait_until (fun () ->
          Ivar.is_full reconnected
          || Option.is_some (next_alarm_within clock ~below:(sec 30.)))
      in
      step (n + 1))
  in
  let%bind () = step 1 in
  print_s
    [%message
      ""
        ~reconnects:(Ws_client.reconnects ws : int)
        ~connected:(Ws_client.is_connected ws : bool)];
  [%expect
    {|
    ((n 1) (delay_ms 1000) (early 0) (connections 2))
    ((n 2) (delay_ms 2000) (early 0) (connections 3))
    ((n 3) (delay_ms 4000) (early 0) (connections 4))
    ((reconnects 1) (connected true))
    |}];
  let%bind () = Ws_client.close ws in
  Server.close server
;;

let%expect_test "a stalled handshake times out and releases its socket" =
  Log.Global.set_output [];
  let%bind server = Server.start [ Stall ] in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind fds_before = open_fds () in
  let result =
    Ws_client.connect
      ~time_source:(Time_source.read_only clock)
      ~handshake_timeout:(sec 5.)
      ~url:(Server.url server)
      ()
  in
  let%bind (_ : bool) = wait_until (fun () -> server.connections = 1) in
  let%bind fds_during = open_fds () in
  let%bind () = Time_source.advance_by_alarms_by clock (sec 4.9) in
  let%bind () = settle () in
  print_s [%message "" ~pending_after_4_9s:(not (Deferred.is_determined result) : bool)];
  let%bind () = Time_source.advance_by_alarms_by clock (sec 0.1) in
  let%bind result in
  let timed_out =
    match result with
    | Ok _ -> false
    | Error error ->
      String.is_substring (Error.to_string_hum error) ~substring:"timed out"
  in
  let%bind released = wait_until (fun () -> server.client_gone = 1) in
  let%bind fds_after = open_fds () in
  print_s
    [%message
      (timed_out : bool)
        ~server_saw_close:(released : bool)
        ~fds_during_minus_before:(fds_during - fds_before : int)
        ~fds_after_minus_before:(fds_after - fds_before : int)];
  [%expect
    {|
    (pending_after_4_9s true)
    ((timed_out true) (server_saw_close true) (fds_during_minus_before 2)
     (fds_after_minus_before 0))
    |}];
  Server.close server
;;
