(* Prints the first frames of a websocket stream, resubscribing after every reconnect:

   dune exec examples/ws_tail.exe -- wss://ws.postman-echo.com/raw '[{"hello":1}]' 3 *)

open! Core
open Async
open Venue_net

let main ~url ~subscribe ~count =
  let%bind ws =
    Ws_client.connect
      ~ping:(`Frame (Time_ns.Span.of_sec 15.))
      ~max_buffered_messages:10_000
      ~on_connect:(fun ws -> Ws_client.send ws subscribe)
      ~url:(Uri.of_string url)
      ()
    >>| ok_exn
  in
  let%bind frames = Pipe.read_exactly (Ws_client.messages ws) ~num_values:count in
  (match frames with
   | `Exactly frames | `Fewer frames -> Queue.iter frames ~f:print_endline
   | `Eof -> ());
  Ws_client.close ws
;;

let () =
  Command.async
    ~summary:"Connect, send one frame after every handshake, print the first frames"
    (let%map_open.Command url = anon ("URL" %: string)
     and subscribe = anon ("FRAME" %: string)
     and count = anon ("COUNT" %: int) in
     fun () -> main ~url ~subscribe ~count)
  |> Command_unix.run
;;
