# AGENTS.md: src/

The `venue_net` library. Each module has an `.mli`; change it first and keep it documented.

- `http.ml`: one request per connection over cohttp: the whole body back as `(status, body)`, JSON and
  form helpers, an optional timeout that closes the socket, and record mode for test fixtures.
- `ws_client.ml`: one logical websocket connection kept open in the background, with jittered
  exponential backoff, a handshake timeout, keepalives, a silence watchdog and a bound on unread messages.
- `tls.ml`: the host-name check on top of `async_ssl`. Both `Http` and `Ws_client` use it.
- `venue_net.ml`: the top-level module that re-exports the public surface.

Rules: a new option that can stall needs a timeout that closes what it waits on, and a test that counts
descriptors afterwards. Record mode redacts what the README says it redacts; extend the redaction with the feature.
