# AGENTS.md: test/

Inline tests (ppx_expect and Quickcheck) for the HTTP client, the websocket client, the handshake, TLS,
the delivery path and the reconnect backoff. They run offline; the TLS test is skipped without network.

- The HTTP tests use a local echo server on `127.0.0.1`. The websocket tests use a loopback server.
- `test_ws_fake_clock.ml` runs the reconnect backoff on a synthetic clock. Do not replace it with real sleeps.
- `test_ws_deliver.ml` pins words per frame. The counts are platform-specific; keep the comment.
- Racing a pipe read against a timeout in a test is a bug (see the root AGENTS.md pitfalls).
- Promote expect output with `dune promote` only after reading the diff.
