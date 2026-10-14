# venue-net

Reconnecting websocket and one-shot HTTP clients for
[Async](https://github.com/janestreet/async), for programs that talk to JSON and text
APIs over `https://` and `wss://`.

- `Venue_net.Http`: one request per connection over cohttp, the whole body back as
  `(status, body)`, JSON and form helpers, an optional timeout that closes the socket,
  and a record mode that saves request/response pairs as test fixtures.
- `Venue_net.Ws_client`: one logical websocket connection kept open in the background:
  jittered exponential reconnect backoff, a handshake timeout, text or ping-frame
  keepalives, a silence watchdog, an optional bound on unread messages and a callback
  after every handshake for (re)subscribing and (re)authenticating.
- `Venue_net.Tls`: the certificate chain and host-name checks used by both.

Message types, subscriptions, de-duplication and request signing are left to the
caller. The name comes from its first use (exchange API clients); nothing in it is
specific to exchanges.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Core, Async,
async_websocket) plus cohttp and conduit-async.

```ocaml
open! Core
open Async
open Venue_net

let tail () =
  let%bind ws =
    Ws_client.connect
      ~ping:(`Frame (Time_ns.Span.of_sec 15.))
      ~on_connect:(fun ws -> Ws_client.send ws {|{"op":"subscribe","topic":"x"}|})
      ~url:(Uri.of_string "wss://example.com/stream")
      ()
    >>| ok_exn
  in
  Pipe.iter_without_pushback (Ws_client.messages ws) ~f:print_endline
```

[`examples/`](examples) has two complete programs, built by `dune build`:
`http_get.exe URL FIELD` and `ws_tail.exe URL FRAME COUNT`.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam install . --deps-only --with-test
dune build && dune test
```

The Jane Street `v0.18~preview` packages (including `async_websocket`, whose
`Websocket.t` became polymorphic in that version) come from the OxCaml opam repository.
The library itself uses no OxCaml-only language feature; see [Portability](#portability).

`https://` and `wss://` need `async_ssl`, built against OpenSSL 3. Without it
conduit-async silently has no TLS. `async_ssl` does not compile against OpenSSL 4
(`ASN1_STRING_data` was removed), and if Homebrew's `openssl@4` is linked, a plain
`-lssl` can resolve to it at link time because other C libraries put
`-L/opt/homebrew/lib` first. A pkg-config file naming the `openssl@3` libraries by
absolute path avoids both:

```sh
D=$(opam var prefix)/share/openssl3-pkgconfig; O=/opt/homebrew/opt/openssl@3
mkdir -p $D && cat > $D/openssl.pc <<PC
Name: OpenSSL
Description: openssl@3
Version: 3
Libs: -L$O/lib $O/lib/libssl.dylib $O/lib/libcrypto.dylib
Cflags: -I$O/include
PC
PKG_CONFIG_PATH=$D opam reinstall async_ssl
```

The first `Libs` entry must start with `-`, since dune reads it as an ordered set.

## TLS

Every `https://` request and `wss://` connection uses `Venue_net.Tls`: `Verify_peer`, an
explicit CA bundle (`SSL_CERT_FILE` if set, else the usual system and Homebrew paths, else
OpenSSL's defaults) and a check that the certificate's names match the URL's host.
conduit-async 8.0.0's default client config checks the chain but not the host name, so
without this a valid certificate for any other domain is accepted.
`test/test_tls.ml` checks that the `self-signed`, `expired`, `untrusted-root` and
`wrong.host` badssl.com hosts are rejected and a good one accepted on both paths; it is
skipped when badssl.com does not resolve.

## `Venue_net.Http`

```ocaml
type response = int * string                     (* status, body *)

val request   : ?headers:(string * string) list -> ?body:string -> ?timeout:Time_ns.Span.t
  -> Cohttp.Code.meth -> Uri.t -> response Or_error.t Deferred.t
val get       : ?headers:(string * string) list -> ?timeout:Time_ns.Span.t -> Uri.t
  -> response Or_error.t Deferred.t
val delete    : (* as get *)
val put       : ?headers:(string * string) list -> ?body:string -> ?timeout:Time_ns.Span.t
  -> Uri.t -> response Or_error.t Deferred.t
val post_json : ?headers:(string * string) list -> ?timeout:Time_ns.Span.t -> Uri.t
  -> Yojson.Safe.t -> response Or_error.t Deferred.t
val post_form : ?headers:(string * string) list -> ?timeout:Time_ns.Span.t -> Uri.t
  -> (string * string) list -> response Or_error.t Deferred.t
val decode_json : response -> f:(Yojson.Safe.t -> 'a) -> 'a Or_error.t
val is_success  : int -> bool
```

- Each call opens a connection, sends one request, reads the whole body and closes the
  connection. There is no connection reuse, redirect following or decompression.
- Transport failures are `Error`, tagged `(METHOD uri)`. Every HTTP status is `Ok`, so
  an API's error bodies can be decoded.
- `timeout` bounds the whole call (DNS, connect, TLS handshake, request and response).
  When it expires the call returns `Error ("HTTP request timed out" ...)` and the socket
  is closed, so a stalled server does not keep a descriptor open. The DNS lookup runs in
  a thread and is abandoned, not cancelled.
- `post_json` sets `Content-Type: application/json` and `post_form` sets
  `application/x-www-form-urlencoded`, unless `headers` already has a content type.
- `decode_json` turns a non-2xx status, invalid JSON and exceptions from `f` into an
  `Error` carrying the status and body.
- `https://` goes through OpenSSL with SNI and full certificate checks (see [TLS](#tls)).
- Requests and responses are written and parsed by cohttp (`Cohttp.Request.Private.Make`
  and `Cohttp.Response.Private.Make`, the functors cohttp's own backends use) over a
  conduit-async connection this library owns, which is what lets a timeout close it.

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
  -> ?max_buffered_messages:int           (* default unbounded *)
  -> ?log_name:string
  -> ?time_source:Time_source.t           (* default wall clock *)
  -> url:Uri.t
  -> unit
  -> t Or_error.t Deferred.t

val messages      : t -> string Pipe.Reader.t
val send          : t -> string -> unit Deferred.t
val send_or_error : t -> string -> unit Or_error.t Deferred.t
val is_connected  : t -> bool
val reconnects    : t -> int
val overflows     : t -> int
val close         : t -> unit Deferred.t
val is_closed     : t -> bool
```

- The upgrade handshake is written by hand (async_websocket only frames) over Conduit.
  `ws://` is plain TCP; `wss://` is OpenSSL with SNI set to the URL's host
  (`Conduit_async.V3.resolve_uri` alone leaves SNI unset, which CDNs reject). `headers`
  go on every upgrade request. Text frames only; no compression extension or subprotocol
  negotiation.
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
- Keepalive: `` `Text (payload, interval) `` sends an application-level ping (for APIs
  that expect e.g. `{"op":"ping"}`); `` `Frame interval `` sends websocket ping frames;
  `` `None `` sends nothing (for servers that ping the client). Incoming ping frames are
  always answered.
- Watchdog: with a ping interval, when `max_silent_intervals` consecutive intervals pass
  with no incoming frame at all (data or control, so pongs count), the socket is closed
  and replaced.
- `on_connect` runs after every handshake, the first included; resubscribe and
  re-authenticate there. `reconnects t` is `0` on the first connection. Exceptions are
  logged.
- `messages` carries raw text frames from every connection; it is closed by `close`.
  Without `max_buffered_messages` it is unbounded. With it, once more than that many
  frames wait unread, the current connection is closed (`overflows` counts this), the
  frames already buffered are kept, and the next connection is opened only after the
  reader has brought the backlog back down to the bound; `on_connect` then resubscribes
  as after any reconnection. async_websocket reads its socket without pushback, so
  closing the connection is how the backlog is bounded.
- `send` drops the frame while disconnected; `send_or_error` returns an `Error` instead.
  Either way a frame queued just before a disconnect can be lost, so resend state from
  `on_connect`.
- `on_message`, when given, gets every text frame straight from the connection's frame
  pipe, in order and across reconnects, and `messages` stays empty. It runs in the
  reading job, so it must not block; an exception it raises goes to the monitor that
  was current at `connect`, and the next frame is still delivered. `on_connect` still
  runs before the first frame of each connection.
- Logs go to `Log.Global`, prefixed with `log_name`.

There is no request rate limiter: callers that must respect an API's rate limits pace
their own calls.

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
- `Http` `timeout`: the deadline also interrupts conduit's connect, and on expiry the
  socket is closed as soon as it exists, which fails a pending read or write. The test
  checks that the server sees the close and that the descriptor count returns to where
  it started. Without `timeout`, a caller that wraps an `Http` call in its own
  `with_timeout` abandons a socket that stays open until the server answers.
- Tests: racing `Pipe.read` against a timeout leaves the read queued on the pipe, where
  it swallows the next message. Wait on `Pipe.values_available` and then `Pipe.read_now`.

## Tests

`dune test` runs without network access (the TLS test is skipped offline): an HTTP echo
server on `127.0.0.1` (methods, content types, form encoding, chunked and empty bodies,
`HEAD`, transport errors, timeouts and socket release, `decode_json`, record mode and
redaction), the handshake (RFC 6455 vectors), base64, backoff and a jitter band
property, and a loopback websocket server that checks extra handshake headers,
`on_connect`, server close and reconnect, text keepalive, silent-connection
replacement, ping-frame pongs as traffic, a refused upgrade, the `max_buffered_messages`
bound, `send_or_error` and shutdown. `test_ws_deliver.ml` pins words per frame of the
delivery hop and checks it against the old per-frame relay; the loopback tests also
cover `on_message` across a reconnect. `test_ws_fake_clock.ml` runs the reconnect backoff
(1 s, 2 s, 4 s) on a synthetic clock and checks that a listener which never answers the
upgrade times out and leaves the open file descriptor count where it started.

## Portability

The sources use no OxCaml-only language feature (no modes, `[@zero_alloc]`, unboxed
types, `or_null` or `let mutable`). A plain OCaml 5.2 build is blocked by package
versions, not by the code: on a stock switch with Jane Street v0.17 and cohttp 5.3,
`Websocket.t` takes no type parameter (v0.18 made it polymorphic) and
`Cohttp.Request.Private` does not exist yet (cohttp 6 added it). With cohttp >= 6.2 and
a v0.18 release of the Jane Street packages on the default opam repository it should
build unchanged.

## Releasing

Versions follow [CHANGES.md](CHANGES.md); `## Unreleased` collects changes until a
release. The intended flow, not yet run, is dune-release:

```sh
dune-release tag 0.1.0      # tags the commit whose CHANGES.md heading is 0.1.0
dune-release distrib        # builds and checks the tarball
dune-release publish        # GitHub release
dune-release opam pkg       # opam file with the tarball URL and checksum
dune-release opam submit    # pull request to opam-repository
```

Nothing has been tagged or published.

## Known gaps

- `https://` and `wss://` need `async_ssl` built against OpenSSL 3 (see [Build](#build)).
  This is an external build constraint, not something the library can fix.
- No HTTP connection reuse: every request pays a TCP and TLS handshake. Adding a pool
  needs decisions on idle timeouts, per-host limits and how a timeout poisons a pooled
  connection.
- `send` and `send_or_error` cannot tell whether the server received a frame; a frame
  queued just before a disconnect is lost. Delivery guarantees need application-level
  acknowledgements, which belong to the protocol on top.
- The Jane Street `v0.18~preview` dependencies exist only on the OxCaml opam repository
  (see [Portability](#portability)).

## Used by

hl-client, binance-client, bybit-client, the okx, coinbase, kraken, deribit and bitget
feeds, hl-leaderboard and hl-copy-api, all in the
[winterchill-trading](https://github.com/winterchill-trading) organisation.
