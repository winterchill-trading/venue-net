# venue-net

Venue-independent HTTP and websocket client plumbing for Async.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Core, Async,
async_websocket, cohttp-async). Venue clients (Hyperliquid, Binance, Bybit, ...) build
their typed APIs on top of it; message types, subscriptions, de-duplication and request
signing stay in the venue libraries.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam install . --deps-only --with-test
dune build && dune test
```

`https://` and `wss://` need `async_ssl` (OpenSSL 3). Without it conduit-async silently
has no TLS. On macOS with Homebrew's `openssl@4`, see the OpenSSL notes in
[hl-client](https://github.com/winterchill-trading/hl-client#macos-and-openssl).

## `Venue_net.Http`

```ocaml
type response = int * string                     (* status, body *)

val request   : ?headers:(string * string) list -> ?body:string -> Cohttp.Code.meth -> Uri.t
  -> response Or_error.t Deferred.t
val get       : ?headers:(string * string) list -> Uri.t -> response Or_error.t Deferred.t
val delete    : ?headers:(string * string) list -> Uri.t -> response Or_error.t Deferred.t
val put       : ?headers:(string * string) list -> ?body:string -> Uri.t -> response Or_error.t Deferred.t
val post_json : ?headers:(string * string) list -> Uri.t -> Yojson.Safe.t -> response Or_error.t Deferred.t
val post_form : ?headers:(string * string) list -> Uri.t -> (string * string) list
  -> response Or_error.t Deferred.t
val decode_json : response -> f:(Yojson.Safe.t -> 'a) -> 'a Or_error.t
val is_success  : int -> bool
```

- Transport failures are `Error`, tagged `(METHOD uri)`. Every HTTP status is `Ok`, so
  venue error bodies can be decoded.
- `post_json` sets `Content-Type: application/json` and `post_form` sets
  `application/x-www-form-urlencoded`, unless `headers` already has a content type.
- `decode_json` turns a non-2xx status, invalid JSON and exceptions from `f` into an
  `Error` carrying the status and body.
- `https://` goes through OpenSSL with SNI (cohttp-async sets it).

## `Venue_net.Ws_client`

```ocaml
module Ping : sig
  type t = [ `Text of string * Time_ns.Span.t | `Frame of Time_ns.Span.t | `None ]
end

val connect
  :  ?headers:(string * string) list
  -> ?ping:Ping.t                         (* default `None *)
  -> ?max_silent_intervals:int            (* default 2 *)
  -> ?initial_backoff:Time_ns.Span.t      (* default 0.5s *)
  -> ?max_backoff:Time_ns.Span.t          (* default 30s *)
  -> ?backoff_jitter:float                (* default 0.2 *)
  -> ?handshake_timeout:Time_ns.Span.t    (* default 10s *)
  -> ?on_connect:(t -> unit Deferred.t)
  -> ?log_name:string
  -> ?time_source:Time_source.t           (* default wall clock *)
  -> url:Uri.t
  -> unit
  -> t Or_error.t Deferred.t

val messages     : t -> string Pipe.Reader.t
val send         : t -> string -> unit Deferred.t
val is_connected : t -> bool
val reconnects   : t -> int
val close        : t -> unit Deferred.t
val is_closed    : t -> bool
```

- The upgrade handshake is written by hand (async_websocket only frames) over Conduit.
  `ws://` is plain TCP; `wss://` is OpenSSL with SNI set to the URL's host
  (`Conduit_async.V3.resolve_uri` alone leaves SNI unset, which CDNs reject). `headers`
  go on every upgrade request.
- `connect` returns once the first handshake succeeds or fails; afterwards the
  connection is maintained in the background. On close it reconnects with exponential
  backoff (doubling from `initial_backoff` to `max_backoff`, reset after a successful
  handshake). Each delay is spread uniformly over `delay * (1 +/- backoff_jitter)` so
  clients dropped together do not reconnect in lockstep, and the chosen delay is logged.
- `handshake_timeout` bounds the TCP connect plus upgrade handshake of every attempt; a
  timed out attempt counts as a failure and its socket is closed.
- `time_source` drives the keepalive, the watchdog, the handshake timeout and the
  reconnect delay. Pass a `Time_source.create` clock in tests to step them; socket I/O
  still runs in real time.
- Keepalive: `` `Text (payload, interval) `` sends an application ping (Hyperliquid
  `{"method":"ping"}`, Bybit `{"op":"ping"}`); `` `Frame interval `` sends websocket
  ping frames; `` `None `` sends nothing (Binance pings the client). Incoming ping frames
  are always answered.
- Watchdog: with a ping interval, when `max_silent_intervals` consecutive intervals pass
  with no incoming frame at all (data or control, so pongs count), the socket is closed
  and replaced.
- `on_connect` runs after every handshake, the first included; resubscribe and
  re-authenticate there. `reconnects t` is `0` on the first connection. Exceptions are
  logged.
- `messages` carries raw text frames from every connection, without pushback; it is
  closed by `close`. `send` drops the frame while disconnected.
- Logs go to `Log.Global`, prefixed with `log_name`.

## Tests

`dune test` runs without network access: an HTTP echo server on `127.0.0.1` (methods,
content types, form encoding, transport errors, `decode_json`), the handshake (RFC 6455
vectors), base64, backoff and a jitter band property, and a loopback websocket server that checks extra handshake
headers, `on_connect`, server close and reconnect, text keepalive, silent-connection
replacement, ping-frame pongs as traffic, a refused upgrade and shutdown.
`test_ws_fake_clock.ml` runs the reconnect backoff (1 s, 2 s, 4 s) on a synthetic clock
and checks that a listener which never answers the upgrade times out and leaves the open
file descriptor count where it started.
