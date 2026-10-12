open! Core
open Async
module T = Venue_net.Ws_client.For_testing

let%expect_test "base64" =
  List.iter [ ""; "f"; "fo"; "foo"; "foob"; "the sample nonce" ] ~f:(fun s ->
    print_endline (T.base64 s));
  [%expect
    {|

    Zg==
    Zm8=
    Zm9v
    Zm9vYg==
    dGhlIHNhbXBsZSBub25jZQ==
    |}];
  return ()
;;

let%expect_test "handshake request" =
  print_string
    (T.handshake_request
       (Uri.of_string "ws://localhost:3000/ws")
       ~key:"dGhlIHNhbXBsZSBub25jZQ==");
  print_string
    (T.handshake_request
       ~headers:[ "X-Api-Key", "abc" ]
       (Uri.of_string "wss://stream.example.com/v5/public?x=1")
       ~key:"k");
  [%expect
    {|
    GET /ws HTTP/1.1
    Host: localhost:3000
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
    Sec-WebSocket-Version: 13

    GET /v5/public?x=1 HTTP/1.1
    Host: stream.example.com
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Key: k
    Sec-WebSocket-Version: 13
    X-Api-Key: abc
    |}];
  return ()
;;

let%expect_test "handshake response (RFC 6455 example)" =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let check status_line headers =
    print_s
      [%sexp (T.check_handshake_response ~key ~status_line ~headers : unit Or_error.t)]
  in
  check
    "HTTP/1.1 101 Switching Protocols"
    [ "upgrade", " websocket"; "sec-websocket-accept", " s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ];
  check "HTTP/1.1 101 Switching Protocols" [ "Sec-WebSocket-Accept", "wrong" ];
  check "HTTP/1.1 404 Not Found" [];
  [%expect
    {|
    (Ok ())
    (Error
     ("bad Sec-WebSocket-Accept" (accept (wrong))
      (expected s3pPLMBiTxaQ9kYGzzhZRbK+xOo=)))
    (Error ("websocket upgrade refused" (status_line "HTTP/1.1 404 Not Found")))
    |}];
  return ()
;;

let%expect_test "backoff" =
  print_s
    [%sexp
      (T.backoff
         ~initial:(Time_ns.Span.of_sec 0.5)
         ~max:(Time_ns.Span.of_sec 30.)
         ~attempts:9
       : Time_ns.Span.t list)];
  [%expect {| (500ms 1s 2s 4s 8s 16s 30s 30s 30s) |}];
  return ()
;;

let%expect_test "jittered delays stay within the band and vary" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: int * float * int]
    (Quickcheck.Generator.tuple3
       (Int.gen_incl 1 60_000)
       (Float.gen_incl 0. 1.5)
       Int.quickcheck_generator)
    ~f:(fun (ms, jitter, seed) ->
      let span = Time_ns.Span.of_int_ms ms in
      let random_state = Random.State.make [| seed |] in
      let delay = T.jittered ~jitter ~random_state span in
      let band = Float.min jitter 1. in
      let lo = Time_ns.Span.scale span (1. -. band) in
      let hi = Time_ns.Span.scale span (1. +. band) in
      if Time_ns.Span.(delay < lo || delay > hi)
      then
        raise_s
          [%message
            "out of band"
              (span : Time_ns.Span.t)
              (jitter : float)
              (delay : Time_ns.Span.t)]);
  let random_state = Random.State.make [| 42 |] in
  let delays =
    List.init 20 ~f:(fun _ ->
      T.jittered ~jitter:0.2 ~random_state (Time_ns.Span.of_sec 1.))
  in
  print_s
    [%sexp
      { distinct =
          (List.length (List.dedup_and_sort delays ~compare:Time_ns.Span.compare) : int)
      ; no_jitter =
          (T.jittered ~jitter:0. ~random_state (Time_ns.Span.of_sec 1.) : Time_ns.Span.t)
      }];
  [%expect {| ((distinct 20) (no_jitter 1s)) |}];
  return ()
;;
