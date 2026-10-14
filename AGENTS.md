# AGENTS.md: venue-net

## Purpose

venue-net is a general client layer for Async: a reconnecting websocket client and a one-shot HTTP
client for `https://` and `wss://` APIs. It holds nothing exchange-specific; venue clients build their
typed APIs and their signing on top of it.

## Layout

| Path | Holds |
| --- | --- |
| `src/` | The `venue-net` library: `Venue_net.Http`, `Venue_net.Ws_client`, TLS host-name checks, the top-level module |
| `test/` | Inline tests: HTTP against a local echo server, handshake vectors, reconnect and delivery, a fake clock |
| `bench/` | `main.exe`: delivery-hop and end-to-end frame throughput over loopback |
| `examples/` | `http_get.ml` and `ws_tail.ml`, built by CI and not run (both need network) |
| `.github/` | `ci.yml` |
| `README.md`, `CHANGES.md` | User documentation and the changelog (`Unreleased` section) |

## Build, test, docs

Run from the repository root, inside the workspace (`..` is the workspace root):

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @venue-net/all
opam exec --switch 5.2.0+ox -- dune build --root .. @venue-net/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @venue-net/doc
```

For parallel work, set `DUNE_BUILD_DIR=_build-venue-net-<task>` (resolved from the workspace
root, because of `--root ..`).

Standalone (outside the workspace): add the organisation opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`),
install the dependencies with `opam install --deps-only --with-test .`, then `dune build` and `dune test`.
The README's switch and OpenSSL notes describe a stock setup; do not create a new switch inside the workspace.

Benchmark: `dune exec --root .. ./venue-net/bench/main.exe` from the workspace. It needs only loopback.

## Conventions

- Format only this repository: `dune build --root .. @venue-net/fmt --auto-promote`. Never run `dune fmt`
  at the workspace root.
- Every module has an `.mli`. Use labelled arguments, `open! Core`, `ppx_jane`.
- The sources use no OxCaml-only language feature (no modes, `[@zero_alloc]`, unboxed types, `or_null`).
  Keep it that way; the README's Portability section explains why it matters.
- Every timeout must stop the work it raced, not only the wait. Check the descriptor count in the test.
- Words per frame on the delivery path are pinned in `test/test_ws_deliver.ml`. Those counts are the
  OCaml runtime's, and they differ between arm64 and amd64; keep the comment that says so.
- `CHANGES.md`: every user-visible change goes under `## Unreleased`.
- Odoc on every public value. CI fails on any odoc warning.

## Dependencies and dependents

venue-net depends on `async`, `async_ssl`, `async_websocket`, `cohttp`, `conduit-async`, `core`,
`core_unix`, `ipaddr`, `uri` and `yojson`. It uses no sibling repository. Dependents: `../hl-client`,
`../binance-client`, `../bybit-client`, the okx, coinbase, kraken, deribit and bitget feeds,
`../hl-leaderboard` and `../hl-copy-api`. An API change here reaches all of them, so build at least one
of them before merging.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` composite action from `winterchill-trading/infra`, then
`dune build`, `dune test`, and a documentation build with `ODOC_WARN_ERROR` (the step fails if the log
contains a warning), plus the `obj-magic` reusable workflow. The TLS test is skipped offline.
To check a run, use `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
Do not poll in a loop.

## Pitfalls

- `with_timeout` only stops waiting; the work it raced keeps running. A timeout must close the socket.
- Racing `Pipe.read` against a timeout leaves the read queued, where it swallows the next message. Wait
  on `Pipe.values_available`, then `Pipe.read_now`.
- `Pipe.read_now` allocates on every call; batch with `Pipe.read_now'` on hot paths.
- `async_ssl` must be built against OpenSSL 3. It does not compile against OpenSSL 4, and a plain `-lssl`
  can resolve to Homebrew's OpenSSL 4 at link time. The README has the pkg-config workaround; use it.
- `cohttp-async` and `conduit-async` do not check host names. `Venue_net.Tls` adds the check; do not
  bypass it.
- `send` cannot tell whether the server received a frame. Delivery guarantees belong to the protocol
  above this library, not here.

## Where to read more

- `README.md` (build, TLS, HTTP and websocket APIs, performance, timeouts, tests, portability, known gaps).
- `CHANGES.md` for the history.
- `../specs/repos/venue-net.md` for the repository summary.
- `../oxcaml-claude-skills/AGENTS.md` (workspace guide) and the skill
  `../oxcaml-claude-skills/skills/async-http-websocket/` for the Async client patterns.
- `../oxcaml-claude-skills/GOTCHAS.md`, section "Venue clients round" and the "From venue-net" entries.

## Never do

- Create an opam switch inside the workspace, or run `opam install`/`opam upgrade` that changes the
  compiler, `core`, `base`, `async` or `ppx_jane` on the shared `5.2.0+ox` switch. Dry-run first:
  `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Add exchange-specific types, subscriptions or signing to this library.
- Publish, tag or release. The release flow in README has not been run yet and is a maintainer decision.
- Commit credentials or recorded traffic that contains them.
