(lang dune 3.17)

(name venue-net)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/venue-net))

(package
 (name venue-net)
 (synopsis "Venue-independent HTTP and websocket client plumbing for Async")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_ssl
  ppx_jane
  yojson
  cohttp
  cohttp-async
  ipaddr
  conduit-async
  async_websocket
  uri))
