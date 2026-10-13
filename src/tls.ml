open! Core
open! Async
module Ssl = Async_ssl.Ssl

let candidates =
  [ "/etc/ssl/certs/ca-certificates.crt" (* Debian, Ubuntu (CI) *)
  ; "/etc/pki/tls/certs/ca-bundle.crt" (* Fedora, RHEL *)
  ; "/etc/ssl/cert.pem" (* macOS system, Alpine *)
  ; "/opt/homebrew/etc/openssl@3/cert.pem" (* Homebrew on arm64 *)
  ; "/usr/local/etc/openssl@3/cert.pem" (* Homebrew on x86_64 *)
  ]
;;

let ca_file () =
  match Sys.getenv "SSL_CERT_FILE" with
  | Some f when not (String.is_empty f) -> Some f
  | _ ->
    List.find candidates ~f:(fun f ->
      match Core_unix.access f [ `Read ] with
      | Ok () -> true
      | Error _ -> false)
;;

let verify ~host conn =
  let ok =
    match Ssl.Connection.peer_certificate conn with
    | Some (Ok _) -> Result.is_ok (Ssl.Connection.check_peer_certificate_host conn host)
    | None | Some (Error _) -> false
  in
  return ok
;;

let config ~host =
  Conduit_async.V2.Ssl.Config.create
    ~hostname:host
    ?ca_file:(ca_file ())
    ~verify_modes:[ Ssl.Verify_mode.Verify_peer ]
    ~verify:(verify ~host)
    ()
;;

let config_v3 ~host =
  Conduit_async.V3.Ssl.Config.create
    ~hostname:host
    ?ca_file:(ca_file ())
    ~verify_modes:[ Ssl.Verify_mode.Verify_peer ]
    ~verify:(verify ~host)
    ()
;;
