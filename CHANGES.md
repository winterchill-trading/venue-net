# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## Unreleased

## 0.1.0

First version prepared for release (not yet tagged or published).

### Added

- `Http`: `request`, `get`, `delete`, `put`, `post_json`, `post_form`, `decode_json`,
  `is_success`, all returning `(status, body)` with transport failures as `Error`.
- `Http`: optional `timeout` on every call; on expiry the socket is closed.
- `Http.Record`: record mode that writes request/response pairs as JSON fixtures, with
  secret headers and query parameters redacted.
- `Ws_client`: reconnecting websocket client with jittered exponential backoff, a
  handshake timeout, text or ping-frame keepalives, a silence watchdog, `on_connect`
  after every handshake, `on_message` for direct delivery and a synthetic `time_source`
  for tests.
- `Ws_client`: `max_buffered_messages` bound on unread `messages`, with `overflows`.
- `Ws_client.send_or_error`: reports a frame that could not be queued.
- `Tls`: certificate chain and host-name verification for every `https://` and `wss://`
  connection.
- Examples `http_get` and `ws_tail` under `examples/`.

### Changed

- `Http` opens its own conduit-async connection and uses cohttp only to write and parse
  messages, so a timed out request can close its socket. Responses, errors and TLS
  settings are as before.
