(** Venue-independent networking: JSON/form HTTP helpers and a reconnecting websocket
    client. Venue specifics (message types, subscriptions, signing) stay in the venue
    libraries. *)

module Http = Http
module Ws_client = Ws_client
