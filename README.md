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

CI installs the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## TLS

Every `https://` request and `wss://` connection uses `Venue_net.Tls`: `Verify_peer`, an
explicit CA bundle (`SSL_CERT_FILE` if set, else the usual system and Homebrew paths, else
OpenSSL's defaults) and a check that the certificate's names match the URL's host.
conduit-async 8.0.0's default client config checks the chain but not the host name, so
before this a valid certificate for any other domain was accepted.
`test/test_tls.ml` checks that the `self-signed`, `expired`, `untrusted-root` and
`wrong.host` badssl.com hosts are rejected and a good one accepted on both paths; it is
skipped when badssl.com does not resolve.

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
- `https://` goes through OpenSSL with SNI and full certificate checks (see [TLS](#tls)).

### Record mode

```sh
VENUE_NET_HTTP_RECORD=fixtures/ my-client-binary ...
```

or `Http.Record.set_dir (Some "fixtures")` in code. Every completed request (any status)
becomes one JSON file, `<METHOD>-<host and path>-<n>.json`, holding the method, URI,
request headers and body, status and response body; `Http.Record.load` reads one back
for decode tests. Header and query values whose names contain `key`, `sign`, `auth`,
`token`, `passphrase` or `cookie` are written as `<redacted>`; request bodies are
written verbatim, so check them before committing fixtures from signed endpoints.

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
  -> ?on_message:(string -> unit)         (* frames straight from the connection *)
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
- `on_message`, when given, gets every text frame straight from the connection's frame
  pipe, in order and across reconnects, and `messages` stays empty. It runs in the
  reading job, so it must not block; an exception it raises goes to the monitor that
  was current at `connect`, and the next frame is still delivered. `on_connect` still
  runs before the first frame of each connection.
- Logs go to `Log.Global`, prefixed with `log_name`.

## Performance

`dune exec bench/main.exe` (needs nothing but loopback) has two parts:

- the delivery hop alone: 100,000 frames already queued on the connection's frame pipe,
  moved to a counting consumer;
- frames per second end to end against an in-process websocket server that writes
  pre-encoded 200-byte text frames, either 1,000 per write (burst) or one per write.

Frames are taken off the connection pipe a batch at a time (`Pipe.read_now'`).
`Pipe.read_now`, which `Pipe.iter_without_pushback` calls once per element, allocates
about 13 words per call (a lazy and two closures in `values_were_read`); the old relay
paid that twice per frame, once for itself and once for the consumer of `messages`.
`test/test_ws_deliver.ml` pins the hop at 13 words per frame through `messages` (the
consumer's own `iter_without_pushback`) and 0 with `on_message`, and checks both paths
against the old relay on random batch sequences.

Measured on arm64 (Apple silicon, CI is amd64), release profile; dev and
`OCAMLPARAM='_,O3=1'` are within a few ns of release:

| | ns/frame | words/frame |
| --- | --- | --- |
| hop: old relay + `messages` iter | 53 to 64 | 26.0 |
| hop: batched relay + `messages` iter | 22 to 25 | 13.0 |
| hop: `on_message` | 2.5 | 0.0 |
| burst end to end: old, `messages` iter | 133 to 141 | 60.6 |
| burst: now, `messages` iter | 145 to 177 | 48.5 |
| burst: now, `messages` with `Pipe.iter'` | 139 to 165 | 35.5 |
| burst: now, `on_message` | 134 to 143 | 35.5 |
| one frame per write: old, `messages` iter | 2850 to 3700 | 213.1 |
| one frame per write: now, `on_message` | 2600 to 3700 | 189.2 |

End-to-end times were taken on a loaded machine and the spread between runs is larger
than the change; the word counts are exact. Most of the remaining 35 words per frame are
async_websocket's (`Iobuf.to_string` of the payload, the frame record), outside this
library.

## Timeouts and abandoned work

`with_timeout` only stops waiting; the work it raced keeps running. Every timeout in
this library was checked for work left behind:

- `Ws_client` handshake (`handshake_timeout`): on timeout the attempt's socket is closed
  as soon as it exists, which fails the pending handshake read, and a connection that
  completes anyway is closed. The stalled-handshake test checks the descriptor count.
- `Ws_client` reconnect sleep: raced against `close`; after `close` the alarm stays
  scheduled until it fires (at most `max_backoff`) and then does nothing.
- `Ws_client` keepalive: `every'` stops when the connection's frame pipe closes.
- `Http` has no timeout. cohttp-async's `?interrupt` only covers the TCP connect, and
  closing a `Cohttp_async.Client.Connection` waits for the running request, so a stalled
  response cannot be cancelled. A caller that wraps an `Http` call in `with_timeout`
  abandons a socket that stays open until the server answers or the kernel gives up.
- Tests: racing `Pipe.read` against a timeout leaves the read queued on the pipe, where
  it swallows the next message. Wait on `Pipe.values_available` and then `Pipe.read_now`.

## Tests

`dune test` runs without network access: an HTTP echo server on `127.0.0.1` (methods,
content types, form encoding, transport errors, `decode_json`, record mode and
redaction), the handshake (RFC 6455
vectors), base64, backoff and a jitter band property, and a loopback websocket server that checks extra handshake
headers, `on_connect`, server close and reconnect, text keepalive, silent-connection
replacement, ping-frame pongs as traffic, a refused upgrade and shutdown.
`test_ws_deliver.ml` pins words per frame of the delivery hop and checks it against the
old per-frame relay; the loopback tests also cover `on_message` across a reconnect.
`test_ws_fake_clock.ml` runs the reconnect backoff (1 s, 2 s, 4 s) on a synthetic clock
and checks that a listener which never answers the upgrade times out and leaves the open
file descriptor count where it started.
