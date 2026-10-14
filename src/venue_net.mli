(** Async HTTP and websocket clients for JSON and text APIs.

    - {!Http}: one-shot HTTP/1.1 requests over cohttp that read the whole body, with JSON
      and form helpers, an optional timeout that closes the socket, and a record mode that
      saves request/response pairs as test fixtures.
    - {!Ws_client}: a websocket client that keeps one logical connection alive: it
      reconnects with jittered exponential backoff, sends keepalives, replaces silent
      connections and calls back after every handshake so the caller can resubscribe.
    - {!Tls}: the certificate and host-name checks used for every [https://] and [wss://]
      connection.

    Message types, subscriptions and request signing belong to the caller.

    {[
      open! Core
      open Async
      open Venue_net

      let fetch () =
        let%map response =
          Http.get
            ~timeout:(Time_ns.Span.of_sec 10.)
            (Uri.of_string "https://example.com")
        in
        Or_error.bind response ~f:(Http.decode_json ~f:Yojson.Safe.Util.to_assoc)
      ;;

      let tail () =
        let%bind ws =
          Ws_client.connect
            ~ping:(`Frame (Time_ns.Span.of_sec 15.))
            ~on_connect:(fun ws -> Ws_client.send ws {|{"op":"subscribe"}|})
            ~url:(Uri.of_string "wss://example.com/stream")
            ()
          >>| ok_exn
        in
        Pipe.iter_without_pushback (Ws_client.messages ws) ~f:print_endline
      ;;
    ]}

    Complete programs are in [examples/]. *)

module Http = Http
module Tls = Tls
module Ws_client = Ws_client
