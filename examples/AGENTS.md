# AGENTS.md: examples/

`http_get.ml` and `ws_tail.ml`: small programs that show the HTTP and websocket clients.

- CI builds them with `dune build`; they are not run, because both need network access.
- If an API used here changes, update the example in the same commit.
