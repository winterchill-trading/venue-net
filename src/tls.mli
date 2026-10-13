(** TLS settings for every HTTPS and WSS connection this library opens.

    With conduit-async 8.0.0 the default client config sets only the SNI host name:
    async_ssl checks the certificate chain ([Verify_peer], OpenSSL's default CA paths), but
    nothing compares the certificate's names with the host, and conduit's [verify] hook
    accepts everything. So a valid certificate for any other domain was accepted. The
    configs here add an explicit CA bundle and a host-name check. *)

open! Core
open! Async

(** The CA bundle: [SSL_CERT_FILE] if set and non-empty, else the first readable of the
    usual system and Homebrew locations, else [None] (OpenSSL's built-in default paths). *)
val ca_file : unit -> string option

(** The [verify] hook: requires a validated peer certificate whose names match [host]. *)
val verify : host:string -> Async_ssl.Ssl.Connection.t -> bool Deferred.t

(** Client config for [host] as cohttp-async takes it ([?ssl_config]): SNI, [Verify_peer],
    the CA bundle from {!ca_file} and {!verify}. *)
val config : host:string -> Conduit_async.V2.Ssl.Config.t

(** The same settings for a [Conduit_async.V3.OpenSSL] address (the websocket client).
    V2 and V3 configs are distinct abstract types, hence two functions. *)
val config_v3 : host:string -> Conduit_async.V3.Ssl.Config.t
