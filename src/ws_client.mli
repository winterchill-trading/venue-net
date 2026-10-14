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
    - [backoff_jitter] (default 0.2) spreads each delay uniformly over
      [delay * (1 +/- backoff_jitter)] (clamped to [0, 1]; [0.] disables it), so many
      clients dropped at once do not reconnect in lockstep. The chosen delay is logged.
    - [handshake_timeout] (default 10s) bounds the TCP connect plus upgrade handshake of
      every attempt. A timed out attempt counts as a failed one, and its socket is closed
      rather than left to finish in the background.
    - [on_connect] runs after every successful handshake, the first one included, as soon
      as frames start being read; use it to authenticate and (re)subscribe. [reconnects t]
      tells a first connection ([0]) from a reconnection. Exceptions it raises are logged;
      the connection is kept.
    - [on_message], when given, receives every incoming text frame straight from the
      connection's frame pipe, in order, with no second pipe in between; [messages] then
      stays empty. It runs synchronously in the reading job, so it should not block. An
      exception it raises is sent to the monitor that was current when [connect] was
      called, and delivery goes on with the next frame. Without it, frames are relayed to
      [messages].
    - [max_buffered_messages] (default unbounded) bounds memory when the reader of
      [messages] falls behind. When more than this many frames wait in [messages], the
      current connection is closed (counted by {!overflows}), frames already in [messages]
      are kept, and the next connection is opened only once the reader has brought
      [messages] back down to this size. [on_connect] then runs as after any reconnection,
      so the caller resubscribes and resyncs. It has no effect with [on_message].
    - [log_name] (default ["venue-net ws"]) prefixes log lines.
    - [time_source] (default the wall clock) drives the keepalive, the silence watchdog,
      the handshake timeout and the reconnection delay, so tests can step them with a
      synthetic clock. Socket I/O still runs in real time. *)
val connect
  :  ?headers:(string * string) list
  -> ?ping:Ping.t
  -> ?max_silent_intervals:int
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> ?backoff_jitter:float
  -> ?handshake_timeout:Time_ns.Span.t
  -> ?on_connect:(t -> unit Deferred.t)
  -> ?on_message:(string -> unit)
  -> ?max_buffered_messages:int
  -> ?log_name:string
  -> ?time_source:Time_source.t
  -> url:Uri.t
  -> unit
  -> t Or_error.t Deferred.t

(** The URL given to {!connect}. *)
val url : t -> Uri.t

(** Raw text frames from all connections. Closed by [close]. Buffered without pushback, so
    consumers should keep up. Empty when [connect] was given [on_message]. *)
val messages : t -> string Pipe.Reader.t

(** Send a text frame on the current connection; dropped silently if disconnected. The
    result is determined when the frame has been handed to the connection's writer. *)
val send : t -> string -> unit Deferred.t

(** Like {!send}, but a frame that cannot be queued because there is no open connection is
    an [Error] rather than dropped silently. [Ok] means the frame was queued on the
    current connection, not that the server received it: a connection can still drop with
    frames in flight. *)
val send_or_error : t -> string -> unit Or_error.t Deferred.t

(** True between a successful handshake and the end of that connection. *)
val is_connected : t -> bool

(** Number of successful reconnections so far (the first connection does not count). *)
val reconnects : t -> int

(** Number of connections closed because [messages] held more than [max_buffered_messages]
    frames. *)
val overflows : t -> int

(** Close the socket, stop reconnecting and close [messages]. Idempotent. *)
val close : t -> unit Deferred.t

(** True once {!close} has been called. *)
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

  (** [jittered ~jitter ~random_state span] is the delay actually slept for a backoff step
      of [span]. *)
  val jittered
    :  jitter:float
    -> random_state:Random.State.t
    -> Time_ns.Span.t
    -> Time_ns.Span.t

  (** [deliver from_server ~received ~on_message ~messages] moves one connection's frames
      to [on_message], or to [messages] when it is [None], until [from_server] closes,
      setting [received] on each frame. [on_overflow] is called once, the first time
      [messages] holds more than [max_buffered] frames after a batch. *)
  val deliver
    :  ?max_buffered:int
    -> ?on_overflow:(unit -> unit)
    -> string Pipe.Reader.t
    -> received:bool ref
    -> on_message:(string -> unit) option
    -> messages:string Pipe.Writer.t
    -> unit Deferred.t
end
