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

let block_frames = 1_000
let block = String.concat (List.init block_frames ~f:(fun _ -> encode_frame payload))

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

let blast writer n =
  Deferred.repeat_until_finished n (fun left ->
    if left <= 0
    then return (`Finished ())
    else (
      Writer.write writer block;
      let%map () = Writer.flushed writer in
      `Repeat (left - block_frames)))
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
    match String.chop_prefix frame ~prefix:"blast:" with
    | Some n -> blast writer (Int.of_string n)
    | None -> Pipe.write to_client frame)
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
let measure client ~n ~(received : int ref) ~(done_ : unit Ivar.t ref) =
  received := 0;
  done_ := Ivar.create ();
  Gc.full_major ();
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%bind () = Ws_client.send client (sprintf "blast:%d" n) in
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

let report name results =
  let best =
    List.min_elt results ~compare:(fun a b -> Float.compare a.seconds b.seconds)
  in
  let best = Option.value_exn best in
  let words = List.map results ~f:(fun r -> r.words) in
  printf
    "%-10s %10.0f frames/s  %8.1f ns/frame  %6.1f words/frame (min %.1f max %.1f)\n%!"
    name
    (Float.of_int frames_per_run /. best.seconds)
    (best.seconds *. 1e9 /. Float.of_int frames_per_run)
    (List.sum (module Float) words ~f:Fn.id /. Float.of_int (List.length words))
    (Option.value_exn (List.min_elt words ~compare:Float.compare))
    (Option.value_exn (List.max_elt words ~compare:Float.compare))
;;

let url server =
  Uri.of_string (sprintf "ws://127.0.0.1:%d/bench" (Tcp.Server.listening_on server))
;;

let run_mode server name =
  let n = frames_per_run in
  let received = ref 0 in
  let done_ = ref (Ivar.create ()) in
  let on_frame = counter ~n ~received ~done_ in
  let%bind client = Ws_client.connect ~url:(url server) () >>| Or_error.ok_exn in
  don't_wait_for (Pipe.iter_without_pushback (Ws_client.messages client) ~f:on_frame);
  (* One warm-up run, then [runs] measured ones. *)
  let%bind (_ : result) = measure client ~n ~received ~done_ in
  let%bind results =
    Deferred.List.init runs ~how:`Sequential ~f:(fun _ ->
      measure client ~n ~received ~done_)
  in
  report name results;
  Ws_client.close client
;;

let main () =
  Log.Global.set_output [];
  let%bind server = start_server () in
  printf
    "%d frames of %d bytes per run, best of %d runs\n%!"
    frames_per_run
    payload_bytes
    runs;
  let%bind () = run_mode server "pipe" in
  Tcp.Server.close ~close_existing_connections:true server
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"Ws_client frames/s against a local server"
       (Command.Param.return main))
;;
