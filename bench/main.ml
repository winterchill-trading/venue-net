(* Frames per second and words per frame through [Ws_client], against a websocket server
   on 127.0.0.1 in the same process.

   The server answers the text frame "blast:<n>" with [n] text frames of [payload_bytes]
   bytes, written as pre-encoded bytes so that it allocates almost nothing per frame; any
   other frame is echoed. Words per frame are minor heap words over the whole receive
   phase (client framing, the [Ws_client] delivery and the consumer), divided by [n]. *)

open! Core
open Async
open Venue_net

let payload_bytes = 200
let frames_per_run = 200_000
let runs = 5

(* An unmasked, final text frame (server to client) holding [payload]. *)
let encode_frame payload =
  let len = String.length payload in
  assert (len >= 126 && len < 65536);
  let b = Bytes.create (4 + len) in
  Bytes.set b 0 (Char.of_int_exn 0x81);
  Bytes.set b 1 (Char.of_int_exn 126);
  Bytes.set b 2 (Char.of_int_exn (len lsr 8));
  Bytes.set b 3 (Char.of_int_exn (len land 0xff));
  Bytes.From_string.blit ~src:payload ~src_pos:0 ~dst:b ~dst_pos:4 ~len;
  Bytes.to_string b
;;

let payload =
  let prefix = {|{"channel":"trades","data":[{"coin":"BTC","px":"|} in
  prefix ^ String.make (payload_bytes - String.length prefix - 3) '1' ^ {|"}]|}
;;

let block frames = String.concat (List.init frames ~f:(fun _ -> encode_frame payload))
let blocks = Int.Table.create ()

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

(* [n] frames, [per_write] of them per write, waiting for each write to flush. *)
let blast writer ~n ~per_write =
  let block = Hashtbl.find_or_add blocks per_write ~default:(fun () -> block per_write) in
  Deferred.repeat_until_finished n (fun left ->
    if left <= 0
    then return (`Finished ())
    else (
      Writer.write writer block;
      let%map () = Writer.flushed writer in
      `Repeat (left - per_write)))
;;

let handle reader writer =
  let%bind headers = read_headers reader [] in
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
  let from_client, to_client = Websocket.pipes ws in
  Pipe.iter from_client ~f:(fun frame ->
    match String.split frame ~on:':' with
    | [ "blast"; n; per_write ] ->
      blast writer ~n:(Int.of_string n) ~per_write:(Int.of_string per_write)
    | _ -> Pipe.write to_client frame)
;;

let start_server () =
  Tcp.Server.create
    ~on_handler_error:`Ignore
    Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _ reader writer -> handle reader writer)
;;

type result =
  { seconds : float
  ; words : float
  }

(* Sends "blast:n" and waits until [received] has counted [n] frames. *)
let measure client ~n ~per_write ~(received : int ref) ~(done_ : unit Ivar.t ref) =
  received := 0;
  done_ := Ivar.create ();
  Gc.full_major ();
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%bind () = Ws_client.send client (sprintf "blast:%d:%d" n per_write) in
  let%map () = Ivar.read !done_ in
  let t1 = Time_ns.now () in
  let words1 = Gc.minor_words () in
  { seconds = Time_ns.Span.to_sec (Time_ns.diff t1 t0)
  ; words = Float.of_int (words1 - words0) /. Float.of_int n
  }
;;

let counter ~n ~received ~done_ _frame =
  incr received;
  if !received = n then Ivar.fill_exn !done_ ()
;;

let report name ~n results =
  let best =
    List.min_elt results ~compare:(fun a b -> Float.compare a.seconds b.seconds)
  in
  let best = Option.value_exn best in
  let words = List.map results ~f:(fun r -> r.words) in
  printf
    "%-10s %10.0f frames/s  %8.1f ns/frame  %6.1f words/frame (min %.1f max %.1f)\n%!"
    name
    (Float.of_int n /. best.seconds)
    (best.seconds *. 1e9 /. Float.of_int n)
    (List.sum (module Float) words ~f:Fn.id /. Float.of_int (List.length words))
    (Option.value_exn (List.min_elt words ~compare:Float.compare))
    (Option.value_exn (List.max_elt words ~compare:Float.compare))
;;

let url server =
  Uri.of_string (sprintf "ws://127.0.0.1:%d/bench" (Tcp.Server.listening_on server))
;;

type mode =
  | Pipe_iter (** [messages] read with [Pipe.iter_without_pushback] *)
  | Pipe_iter' (** [messages] read a batch at a time with [Pipe.iter'] *)
  | On_message (** frames handed to [on_message] *)

let mode_name = function
  | Pipe_iter -> "pipe iter"
  | Pipe_iter' -> "pipe iter'"
  | On_message -> "on_message"
;;

let run_mode server mode ~n ~per_write =
  let received = ref 0 in
  let done_ = ref (Ivar.create ()) in
  let on_frame = counter ~n ~received ~done_ in
  let%bind client =
    match mode with
    | On_message -> Ws_client.connect ~on_message:on_frame ~url:(url server) ()
    | Pipe_iter | Pipe_iter' -> Ws_client.connect ~url:(url server) ()
  in
  let client = Or_error.ok_exn client in
  (match mode with
   | On_message -> ()
   | Pipe_iter ->
     don't_wait_for (Pipe.iter_without_pushback (Ws_client.messages client) ~f:on_frame)
   | Pipe_iter' ->
     don't_wait_for
       (Pipe.iter' (Ws_client.messages client) ~f:(fun batch ->
          Queue.iter batch ~f:on_frame;
          return ())));
  (* One warm-up run, then [runs] measured ones. *)
  let%bind (_ : result) = measure client ~n ~per_write ~received ~done_ in
  let%bind results =
    Deferred.List.init runs ~how:`Sequential ~f:(fun _ ->
      measure client ~n ~per_write ~received ~done_)
  in
  report (mode_name mode) ~n results;
  Ws_client.close client
;;

(* The delivery hop alone, in process: [hop_frames] frames already queued on a closed pipe
   (one batch) are moved to a counting consumer. [relay] is the per-frame relay that
   [Ws_client] used before batching. *)
let hop_frames = 100_000

let relay from_server ~messages =
  Pipe.iter_without_pushback from_server ~f:(fun frame ->
    Pipe.write_without_pushback_if_open messages frame)
;;

let hop name ~run =
  let measure () =
    let from_server, writer = Pipe.create () in
    for _ = 1 to hop_frames do
      Pipe.write_without_pushback writer payload
    done;
    Pipe.close writer;
    let count = ref 0 in
    let words0 = Gc.minor_words () in
    let t0 = Time_ns.now () in
    let%map () = run from_server ~count in
    let t1 = Time_ns.now () in
    assert (!count = hop_frames);
    ( Time_ns.Span.to_sec (Time_ns.diff t1 t0)
    , Float.of_int (Gc.minor_words () - words0) /. Float.of_int hop_frames )
  in
  let%map results = Deferred.List.init 20 ~how:`Sequential ~f:(fun _ -> measure ()) in
  let best =
    List.fold results ~init:Float.infinity ~f:(fun acc (s, _) -> Float.min acc s)
  in
  printf
    "%-24s %8.1f ns/frame  %5.1f words/frame\n%!"
    name
    (best *. 1e9 /. Float.of_int hop_frames)
    (snd (List.last_exn results))
;;

let via_messages ~deliver from_server ~count =
  let messages_reader, messages_writer = Pipe.create () in
  let consumer =
    Pipe.iter_without_pushback messages_reader ~f:(fun (_ : string) -> incr count)
  in
  let%bind () = deliver from_server ~messages:messages_writer in
  Pipe.close messages_writer;
  consumer
;;

let hops () =
  printf "delivery hop only: %d queued frames, best of 20\n%!" hop_frames;
  let%bind () = hop "relay + pipe iter (old)" ~run:(via_messages ~deliver:relay) in
  let%bind () =
    hop
      "deliver + pipe iter"
      ~run:
        (via_messages ~deliver:(fun from_server ~messages ->
           Ws_client.For_testing.deliver
             from_server
             ~received:(ref false)
             ~on_message:None
             ~messages))
  in
  hop "deliver + on_message" ~run:(fun from_server ~count ->
    let _, messages = Pipe.create () in
    Ws_client.For_testing.deliver
      from_server
      ~received:(ref false)
      ~on_message:(Some (fun (_ : string) -> incr count))
      ~messages)
;;

let main () =
  Log.Global.set_output [];
  let%bind () = hops () in
  let%bind server = start_server () in
  let%bind () =
    Deferred.List.iter
      ~how:`Sequential
      [ "burst", frames_per_run, 1_000; "one per write", frames_per_run / 10, 1 ]
      ~f:(fun (scenario, n, per_write) ->
        printf
          "%s: %d frames of %d bytes per run, %d per server write, best of %d runs\n%!"
          scenario
          n
          payload_bytes
          per_write
          runs;
        Deferred.List.iter
          ~how:`Sequential
          [ Pipe_iter; Pipe_iter'; On_message ]
          ~f:(fun mode -> run_mode server mode ~n ~per_write))
  in
  Tcp.Server.close ~close_existing_connections:true server
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"Ws_client frames/s against a local server"
       (Command.Param.return main))
;;
