(** A reconnecting websocket client for text-frame APIs.

    A [t] owns one logical connection. The upgrade handshake is written by hand (async
    websocket only does framing) over Conduit: [ws://] is plain TCP, [wss://] is OpenSSL
    with SNI set to the URL's host. When the socket closes, or goes silent, the client
    reconnects in the background with exponential backoff and calls [on_connect] again so
    the caller can re-authenticate and resubscribe. Incoming text frames from every
    connection are delivered, in order, on one pipe.

    Subscriptions, de-duplication and message decoding are venue specific and stay with
    the caller. *)

open! Core
open Async

module Ping : sig
  (** Application-level keepalive.

      - [`Text (payload, interval)]: send [payload] as a text frame every [interval] (e.g.
        Hyperliquid's [{"method":"ping"}], Bybit's [{"op":"ping"}]).
      - [`Frame interval]: send a websocket ping control frame every [interval].
      - [`None]: send nothing, e.g. Binance, whose server pings the client. Incoming ping
        frames are always answered with pongs. *)
  type t =
    [ `Text of string * Time_ns.Span.t
    | `Frame of Time_ns.Span.t
    | `None
    ]
  [@@deriving sexp_of]

  val interval : t -> Time_ns.Span.t option
end

type t

(** [connect ~url ()] opens the first connection and returns once its handshake has
    succeeded (or failed). Later disconnects are retried in the background.

    - [headers] are added to every upgrade request.
    - [ping] (default [`None]) is the keepalive. With a ping interval, the connection is
      also watched: when [max_silent_intervals] (default 2) consecutive intervals pass
      without any incoming frame (data or control, e.g. pongs), the socket is closed and
      replaced.
    - [initial_backoff] (default 0.5s) and [max_backoff] (default 30s) bound the delay
      between reconnection attempts; it doubles after each failure and resets after a
      successful handshake.
    - [on_connect] runs after every successful handshake, the first one included, as soon
      as frames start being read; use it to authenticate and (re)subscribe. [reconnects t]
      tells a first connection ([0]) from a reconnection. Exceptions it raises are logged;
      the connection is kept.
    - [log_name] (default ["venue-net ws"]) prefixes log lines.
    - [time_source] (default the wall clock) drives the keepalive, the silence watchdog
      and the reconnection delay, so tests can step them with a synthetic clock. Socket
      I/O still runs in real time. *)
val connect
  :  ?headers:(string * string) list
  -> ?ping:Ping.t
  -> ?max_silent_intervals:int
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> ?on_connect:(t -> unit Deferred.t)
  -> ?log_name:string
  -> ?time_source:Time_source.t
  -> url:Uri.t
  -> unit
  -> t Or_error.t Deferred.t

val url : t -> Uri.t

(** Raw text frames from all connections. Closed by [close]. Buffered without pushback, so
    consumers should keep up. *)
val messages : t -> string Pipe.Reader.t

(** Send a text frame on the current connection; dropped if disconnected. *)
val send : t -> string -> unit Deferred.t

val is_connected : t -> bool

(** Number of successful reconnections so far (the first connection does not count). *)
val reconnects : t -> int

(** Close the socket, stop reconnecting and close [messages]. Idempotent. *)
val close : t -> unit Deferred.t

val is_closed : t -> bool

(** Pure pieces, exposed for testing. *)
module For_testing : sig
  val base64 : string -> string

  (** The HTTP upgrade request for [uri] with the given [Sec-WebSocket-Key]. *)
  val handshake_request : ?headers:(string * string) list -> Uri.t -> key:string -> string

  (** Check a [101 Switching Protocols] response against [key]. Header names are
      case-insensitive. *)
  val check_handshake_response
    :  key:string
    -> status_line:string
    -> headers:(string * string) list
    -> unit Or_error.t

  (** Successive reconnection delays. *)
  val backoff
    :  initial:Time_ns.Span.t
    -> max:Time_ns.Span.t
    -> attempts:int
    -> Time_ns.Span.t list
end
