(** Small HTTP/1.1 client helpers for Async.

    Every call opens a new connection, sends one request, reads the whole response body,
    closes the connection and returns [(status, body)]. Connection and transport failures
    become [Error] (tagged with the method and URI); any HTTP status, including 4xx and
    5xx, is returned as [Ok], so callers can decode an API's error bodies. Requests and
    responses are encoded and parsed by cohttp; connections go through conduit-async.
    [https://] URIs use OpenSSL with SNI, the CA bundle and the host-name check of {!Tls}.
    There is no connection reuse, no redirect following and no response decompression. *)

open! Core
open Async

(** [(status, body)] *)
type response = int * string [@@deriving sexp_of]

(** [request meth uri] sends [body] (if any) with [headers] on a new connection, reads the
    whole response and closes the connection.

    @param timeout
      bounds the whole call: DNS lookup, connect, TLS handshake, sending and reading. When
      it expires the result is an [Error] and the connection is closed, so no socket is
      left waiting for a stalled server. The DNS lookup itself runs in a thread and is
      only abandoned, not cancelled. Without [timeout] the call waits as long as the
      server and the kernel let it. *)
val request
  :  ?headers:(string * string) list
  -> ?body:string
  -> ?timeout:Time_ns.Span.t
  -> Cohttp.Code.meth
  -> Uri.t
  -> response Or_error.t Deferred.t

(** [get uri] is [request `GET uri]. *)
val get
  :  ?headers:(string * string) list
  -> ?timeout:Time_ns.Span.t
  -> Uri.t
  -> response Or_error.t Deferred.t

(** [delete uri] is [request `DELETE uri]. *)
val delete
  :  ?headers:(string * string) list
  -> ?timeout:Time_ns.Span.t
  -> Uri.t
  -> response Or_error.t Deferred.t

(** [put ?body uri] is [request ?body `PUT uri]. *)
val put
  :  ?headers:(string * string) list
  -> ?body:string
  -> ?timeout:Time_ns.Span.t
  -> Uri.t
  -> response Or_error.t Deferred.t

(** POSTs [json] with [Content-Type: application/json], unless [headers] already sets a
    content type. *)
val post_json
  :  ?headers:(string * string) list
  -> ?timeout:Time_ns.Span.t
  -> Uri.t
  -> Yojson.Safe.t
  -> response Or_error.t Deferred.t

(** POSTs [params] as an [application/x-www-form-urlencoded] body, unless [headers]
    already sets a content type. *)
val post_form
  :  ?headers:(string * string) list
  -> ?timeout:Time_ns.Span.t
  -> Uri.t
  -> (string * string) list
  -> response Or_error.t Deferred.t

(** [decode_json response ~f] parses the body as JSON and applies [f]. Parse and decode
    exceptions, and a non-2xx status, become an [Error] that includes the status and the
    body. *)
val decode_json : response -> f:(Yojson.Safe.t -> 'a) -> 'a Or_error.t

(** [is_success status] is true for 2xx. *)
val is_success : int -> bool

(** Record mode: every completed request (any status) is written as one JSON file, for
    checking in as test fixtures. Transport failures are not recorded, and a failure to
    write is logged, never returned.

    Recording is off unless a directory is set, either with [set_dir] or through the
    [VENUE_NET_HTTP_RECORD] environment variable read at startup. Files are named
    [<METHOD>-<host and path>-<n>.json] with the first free [n]. Values of headers and
    query parameters whose names contain [key], [sign], [auth], [token], [passphrase] or
    [cookie] are replaced by ["<redacted>"]; request bodies are written verbatim. *)
module Record : sig
  type entry =
    { meth : string
    ; uri : string
    ; request_headers : (string * string) list
    ; request_body : string option
    ; status : int
    ; response_body : string
    }
  [@@deriving sexp_of]

  (** ["VENUE_NET_HTTP_RECORD"]: when set and non-empty at program start, its value is the
      initial recording directory. *)
  val env_var : string

  (** [set_dir (Some dir)] records every later request into [dir] (created on first
      write); [set_dir None] stops recording. *)
  val set_dir : string option -> unit

  (** The current recording directory, if recording is on. *)
  val dir : unit -> string option

  (** Reads one recorded file back. *)
  val load : string -> entry Or_error.t Deferred.t

  (** The JSON written to each file. *)
  val entry_to_json : entry -> Yojson.Safe.t

  (** Inverse of {!entry_to_json}.

      Raises [Yojson.Safe.Util.Type_error] if a field is missing or has the wrong type. *)
  val entry_of_json : Yojson.Safe.t -> entry
end
