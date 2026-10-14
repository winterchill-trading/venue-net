(lang dune 3.17)

(name venue-net)

(generate_opam_files true)

(license MIT)

(authors "WinterChill AI")

(maintainers "hello@winterchill.xyz")

(source
 (github winterchill-trading/venue-net))

(homepage "https://github.com/winterchill-trading/venue-net")

(bug_reports "https://github.com/winterchill-trading/venue-net/issues")

(documentation "https://github.com/winterchill-trading/venue-net#readme")

(package
 (name venue-net)
 (synopsis "Reconnecting websocket and one-shot HTTP clients for Async")
 (description
  "HTTP/1.1 and websocket clients for programs built on Jane Street's Async. Http sends one request per connection over cohttp and conduit-async and returns the status and the whole body, with JSON and form helpers, a timeout that closes the socket, and a record mode that saves request/response pairs as test fixtures. Ws_client keeps one logical websocket connection open: jittered exponential reconnect backoff, a handshake timeout, text or ping-frame keepalives, a silence watchdog, an optional bound on unread messages and a callback after every handshake for resubscribing. Every https:// and wss:// connection checks the certificate chain and the host name. Built for OxCaml and the Jane Street v0.18 preview packages.")
 (depends
  (ocaml
   (>= 5.2))
  dune
  (core
   (>= v0.18~preview))
  (core_unix
   (>= v0.18~preview))
  (async
   (>= v0.18~preview))
  (async_ssl
   (>= v0.18~preview))
  (async_websocket
   (>= v0.18~preview))
  (ppx_jane
   (>= v0.18~preview))
  (cohttp
   (>= 6.2.1))
  (conduit-async
   (>= 8.0.0))
  (ipaddr
   (>= 5.6.0))
  (uri
   (>= 4.4.0))
  (yojson
   (>= 2.2.0))
  (cohttp-async
   (and
    :with-test
    (>= 6.2.1)))
  (odoc :with-doc)))
