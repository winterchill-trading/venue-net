(* [Http.Record] against a cohttp-async server on 127.0.0.1. *)

open! Core
open Async
open Venue_net

let with_server f =
  let%bind server =
    Cohttp_async.Server.create
      ~on_handler_error:`Ignore
      Tcp.Where_to_listen.of_port_chosen_by_os
      (fun ~body:_ _ request ->
         match Uri.path (Cohttp.Request.uri request) with
         | "/missing" -> Cohttp_async.Server.respond_string ~status:`Not_found "{}"
         | _ -> Cohttp_async.Server.respond_string {|{"levels":[[],[]]}|})
  in
  let port = Cohttp_async.Server.listening_on server in
  let uri path = Uri.of_string (sprintf "http://127.0.0.1:%d%s" port path) in
  let%bind () = f uri in
  Cohttp_async.Server.close server
;;

let%expect_test "record mode writes one redacted file per request" =
  Log.Global.set_output [];
  let%bind dir = Unix.mkdtemp "record" in
  let dir = Filename.concat dir "fixtures" in
  print_s [%sexp (Http.Record.dir () : string option)];
  Http.Record.set_dir (Some dir);
  let%bind () =
    with_server (fun uri ->
      let%bind (_ : Http.response) =
        Http.post_json
          ~headers:[ "X-Api-Key", "secret"; "X-Trace", "1" ]
          (uri "/info")
          (`Assoc [ "type", `String "l2Book" ])
        >>| ok_exn
      in
      let%bind (_ : Http.response) =
        Http.get (uri "/info?coin=BTC&signature=abc") >>| ok_exn
      in
      let%bind (_ : Http.response) = Http.get (uri "/missing") >>| ok_exn in
      (* A second call to the same endpoint gets the next index. *)
      let%bind (_ : Http.response) = Http.get (uri "/info") >>| ok_exn in
      return ())
  in
  Http.Record.set_dir None;
  (* Off again: nothing more is written. *)
  let%bind () =
    with_server (fun uri ->
      Http.get (uri "/info") >>| ok_exn >>| (ignore : Http.response -> unit))
  in
  let%bind files = Sys.readdir dir in
  let files = Array.to_list files |> List.sort ~compare:String.compare in
  print_s [%sexp (files : string list)];
  let%bind () =
    Deferred.List.iter ~how:`Sequential files ~f:(fun file ->
      let%map entry = Http.Record.load (Filename.concat dir file) >>| ok_exn in
      let uri = Uri.of_string entry.uri in
      let entry : Http.Record.entry =
        { entry with
          uri = Uri.path_and_query uri
        ; request_headers =
            List.filter entry.request_headers ~f:(fun (k, _) ->
              String.is_prefix (String.lowercase k) ~prefix:"x-")
        }
      in
      print_s [%sexp (entry : Http.Record.entry)])
  in
  [%expect
    {|
    ()
    (GET-127.0.0.1-info-1.json GET-127.0.0.1-info-2.json
     GET-127.0.0.1-missing-1.json POST-127.0.0.1-info-1.json)
    ((meth GET) (uri /info?coin=BTC&signature=%3Credacted%3E)
     (request_headers ()) (request_body ()) (status 200)
     (response_body "{\"levels\":[[],[]]}"))
    ((meth GET) (uri /info) (request_headers ()) (request_body ()) (status 200)
     (response_body "{\"levels\":[[],[]]}"))
    ((meth GET) (uri /missing) (request_headers ()) (request_body ())
     (status 404) (response_body {}))
    ((meth POST) (uri /info)
     (request_headers ((X-Api-Key <redacted>) (X-Trace 1)))
     (request_body ("{\"type\":\"l2Book\"}")) (status 200)
     (response_body "{\"levels\":[[],[]]}"))
    |}];
  return ()
;;
