(* Fetches a JSON document and prints one field:

   dune exec examples/http_get.exe -- https://api.github.com/repos/ocaml/dune full_name *)

open! Core
open Async
open Venue_net

let main ~url ~field =
  let%map response = Http.get ~timeout:(Time_ns.Span.of_sec 10.) (Uri.of_string url) in
  let value =
    Or_error.bind response ~f:(Http.decode_json ~f:(Yojson.Safe.Util.member field))
  in
  match value with
  | Ok json -> print_endline (Yojson.Safe.to_string json)
  | Error error -> Print.eprint_s [%sexp (error : Error.t)]
;;

let () =
  Command.async
    ~summary:"GET a JSON document and print one field"
    (let%map_open.Command url = anon ("URL" %: string)
     and field = anon ("FIELD" %: string) in
     fun () -> main ~url ~field)
  |> Command_unix.run
;;
