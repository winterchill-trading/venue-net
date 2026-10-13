open! Core
open! Async
open Venue_net

(* Certificate checks against badssl.com, through both paths venue-net opens: [Http]
   (cohttp with [Tls.config]) and a Conduit V3 connect with [Tls.config_v3] (what
   [Ws_client] uses for wss). The network may be absent (sandboxed builds), so a host that
   does not resolve skips the check, and a timeout skips that host. *)

let with_timeout f =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_sec 20.) (f ()) with
  | `Timeout -> `Timeout
  | `Result (Ok ()) -> `Ok
  | `Result (Error _) -> `Rejected
;;

let via_http host =
  with_timeout (fun () ->
    Http.get (Uri.of_string ("https://" ^ host ^ "/")) |> Deferred.Or_error.ignore_m)
;;

let via_conduit_v3 host =
  with_timeout (fun () ->
    Monitor.try_with_or_error ~extract_exn:true (fun () ->
      let%bind addr =
        Conduit_async.V3.resolve_uri (Uri.of_string ("https://" ^ host ^ ":443/"))
      in
      let inet =
        match addr with
        | OpenSSL (inet, _) | Inet inet -> inet
      in
      let%bind _socket, reader, writer =
        Conduit_async.V3.connect (OpenSSL (inet, Tls.config_v3 ~host))
      in
      let%bind () = Writer.close writer in
      Reader.close reader))
;;

let resolves host =
  match%map
    Monitor.try_with (fun () ->
      Clock_ns.with_timeout
        (Time_ns.Span.of_sec 5.)
        (Async_unix.Unix.Inet_addr.of_string_or_getbyname host))
  with
  | Ok (`Result _) -> true
  | _ -> false
;;

let show = function
  | `Ok -> "accepted"
  | `Rejected -> "rejected"
  | `Timeout -> "timeout"
;;

(* Measured 2026-10-13 with conduit-async 8.0.0: the default configs reject self-signed,
   expired and untrusted-root certificates but ACCEPT wrong.host (no host-name check).
   Both venue-net paths must reject all four and still accept a good host. Prints nothing,
   so the expected output is the same online and offline. *)
let%expect_test "Tls rejects bad certificates on http and wss paths" =
  let%bind online = resolves "badssl.com" in
  if not online
  then return ()
  else
    Deferred.List.iter
      ~how:`Sequential
      [ "self-signed", `Rejected
      ; "expired", `Rejected
      ; "wrong.host", `Rejected
      ; "untrusted-root", `Rejected
      ; "sha256", `Ok
      ]
      ~f:(fun (sub, expected) ->
        let host = sub ^ ".badssl.com" in
        Deferred.List.iter
          ~how:`Sequential
          [ "http", via_http; "conduit-v3", via_conduit_v3 ]
          ~f:(fun (path, check) ->
            match%map check host with
            | `Timeout -> ()
            | got ->
              if not (String.equal (show got) (show expected))
              then
                raise_s
                  [%message
                    "unexpected TLS outcome"
                      host
                      path
                      ~got:(show got)
                      ~expected:(show expected)]))
;;
