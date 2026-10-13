(* Words per frame of [Ws_client]'s delivery from a connection's frame pipe to the
   consumer, with and without the [messages] pipe hop. The frames are preallocated and the
   source pipe is filled and closed up front, so only delivery is counted. *)

open! Core
open Async
open Venue_net

let frames = 10_000
let payload = String.make 200 'x'

let source () =
  let reader, writer = Pipe.create () in
  for _ = 1 to frames do
    Pipe.write_without_pushback writer payload
  done;
  Pipe.close writer;
  reader
;;

(* Minor words per frame for [deliver] plus the consumer, rounded to a tenth. *)
let words_per_frame ~on_message =
  let from_server = source () in
  let count = ref 0 in
  let messages_reader, messages_writer = Pipe.create () in
  let received = ref false in
  let on_message = if on_message then Some (fun (_ : string) -> incr count) else None in
  let words0 = Gc.minor_words () in
  let consumer =
    Pipe.iter_without_pushback messages_reader ~f:(fun (_ : string) -> incr count)
  in
  let%bind () =
    Ws_client.For_testing.deliver
      from_server
      ~received
      ~on_message
      ~messages:messages_writer
  in
  Pipe.close messages_writer;
  let%map () = consumer in
  let words = Gc.minor_words () - words0 in
  assert (!count = frames);
  Float.round_decimal (Float.of_int words /. Float.of_int frames) ~decimal_digits:1
;;

let%expect_test "words per frame" =
  let%bind via_pipe = words_per_frame ~on_message:false in
  let%map direct = words_per_frame ~on_message:true in
  print_s [%sexp { via_pipe : float; direct : float }];
  [%expect {| ((via_pipe 13) (direct 0)) |}]
;;

(* The relay [deliver] replaced: one [read_now] per frame into [messages]. *)
let reference_relay from_server ~messages =
  Pipe.iter_without_pushback from_server ~f:(fun frame ->
    Pipe.write_without_pushback_if_open messages frame)
;;

(* Writes [batches] into a fresh pipe, yielding between batches so that the reader sees
   them as separate arrivals, and returns what [run] delivered. *)
let delivered batches ~run =
  let from_server, writer = Pipe.create () in
  let out = Queue.create () in
  let finished = run from_server ~out in
  let%bind () =
    Deferred.List.iter batches ~how:`Sequential ~f:(fun batch ->
      List.iter batch ~f:(Pipe.write_without_pushback writer);
      Scheduler.yield ())
  in
  Pipe.close writer;
  let%map () = finished in
  Queue.to_list out
;;

let via_messages ~on_message from_server ~out =
  let messages_reader, messages_writer = Pipe.create () in
  let consumer = Pipe.iter_without_pushback messages_reader ~f:(Queue.enqueue out) in
  let on_message = Option.map on_message ~f:(fun () -> Queue.enqueue out) in
  let%bind () =
    Ws_client.For_testing.deliver
      from_server
      ~received:(ref false)
      ~on_message
      ~messages:messages_writer
  in
  Pipe.close messages_writer;
  consumer
;;

let%test_unit "deliver hands over the same frames, in order, as the old relay" =
  Quickcheck.test
    ~trials:100
    [%quickcheck.generator: string list list]
    ~sexp_of:[%sexp_of: string list list]
    ~f:(fun batches ->
      Thread_safe.block_on_async_exn (fun () ->
        let%bind expected =
          delivered batches ~run:(fun from_server ~out ->
            let messages_reader, messages_writer = Pipe.create () in
            let consumer =
              Pipe.iter_without_pushback messages_reader ~f:(Queue.enqueue out)
            in
            let%bind () = reference_relay from_server ~messages:messages_writer in
            Pipe.close messages_writer;
            consumer)
        in
        let%bind piped = delivered batches ~run:(via_messages ~on_message:None) in
        let%map direct = delivered batches ~run:(via_messages ~on_message:(Some ())) in
        [%test_result: string list] piped ~expect:expected;
        [%test_result: string list] direct ~expect:expected;
        [%test_result: string list] expected ~expect:(List.concat batches)))
;;
