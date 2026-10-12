(** Small HTTP client helpers on top of cohttp-async.

    Every call reads the whole response body and returns [(status, body)]. Connection and
    transport failures become [Error] (tagged with the method and URI); any HTTP status,
    including 4xx and 5xx, is returned as [Ok], so callers can decode venue error bodies.
    [https://] URIs use OpenSSL via conduit-async, which sets SNI to the URI's host. *)

open! Core
open Async

(** [(status, body)] *)
type response = int * string [@@deriving sexp_of]

(** [request meth uri] sends [body] (if any) with [headers] and reads the response. *)
val request
  :  ?headers:(string * string) list
  -> ?body:string
  -> Cohttp.Code.meth
  -> Uri.t
  -> response Or_error.t Deferred.t

val get : ?headers:(string * string) list -> Uri.t -> response Or_error.t Deferred.t
val delete : ?headers:(string * string) list -> Uri.t -> response Or_error.t Deferred.t

val put
  :  ?headers:(string * string) list
  -> ?body:string
  -> Uri.t
  -> response Or_error.t Deferred.t

(** POSTs [json] with [Content-Type: application/json], unless [headers] already sets a
    content type. *)
val post_json
  :  ?headers:(string * string) list
  -> Uri.t
  -> Yojson.Safe.t
  -> response Or_error.t Deferred.t

(** POSTs [params] as an [application/x-www-form-urlencoded] body. *)
val post_form
  :  ?headers:(string * string) list
  -> Uri.t
  -> (string * string) list
  -> response Or_error.t Deferred.t

(** [decode_json response ~f] parses the body as JSON and applies [f]. Parse and decode
    exceptions, and a non-2xx status, become an [Error] that includes the status and the
    body. *)
val decode_json : response -> f:(Yojson.Safe.t -> 'a) -> 'a Or_error.t

(** [is_success status] is true for 2xx. *)
val is_success : int -> bool
