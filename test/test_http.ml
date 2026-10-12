(* [Http] against a cohttp-async server on 127.0.0.1 that echoes the request. *)

open! Core
open Async
open Venue_net

let with_echo_server f =
  let%bind server =
    Cohttp_async.Server.create
      ~on_handler_error:`Ignore
      Tcp.Where_to_listen.of_port_chosen_by_os
      (fun ~body _ request ->
         let%bind body = Cohttp_async.Body.to_string body in
         let headers = Cohttp.Request.headers request in
         let content_type =
           Option.value (Cohttp.Header.get headers "content-type") ~default:"-"
         in
         let status =
           match Uri.path (Cohttp.Request.uri request) with
           | "/missing" -> `Not_found
           | _ -> `OK
         in
         Cohttp_async.Server.respond_string
           ~status
           (sprintf
              "%s %s [%s] %s"
              (Cohttp.Code.string_of_method (Cohttp.Request.meth request))
              (Uri.path_and_query (Cohttp.Request.uri request))
              content_type
              body))
  in
  let base = sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on server) in
  let%bind () = f (fun path -> Uri.of_string (base ^ path)) in
  Cohttp_async.Server.close server
;;

let print response = print_s [%sexp (response : Http.response Or_error.t)]

let%expect_test "methods and encodings" =
  with_echo_server (fun uri ->
    let%bind () = Http.get (uri "/a?x=1") >>| print in
    let%bind () = Http.delete (uri "/b") >>| print in
    let%bind () = Http.put ~body:"p" (uri "/c") >>| print in
    let%bind () = Http.post_json (uri "/d") (`Assoc [ "k", `Int 1 ]) >>| print in
    let%bind () =
      Http.post_json ~headers:[ "Content-Type", "text/plain" ] (uri "/e") (`String "s")
      >>| print
    in
    let%bind () = Http.post_form (uri "/f") [ "a", "1 2"; "b", "x&y" ] >>| print in
    let%bind () = Http.get (uri "/missing") >>| print in
    [%expect
      {|
      (Ok (200 "GET /a?x=1 [-] "))
      (Ok (200 "DELETE /b [-] "))
      (Ok (200 "PUT /c [-] p"))
      (Ok (200 "POST /d [application/json] {\"k\":1}"))
      (Ok (200 "POST /e [text/plain] \"s\""))
      (Ok (200 "POST /f [application/x-www-form-urlencoded] a=1%202&b=x%26y"))
      (Ok (404 "GET /missing [-] "))
      |}];
    return ())
;;

let%expect_test "transport errors are tagged with method and uri" =
  (* Port 1 on loopback refuses connections. *)
  let%bind result = Http.get (Uri.of_string "http://127.0.0.1:1/x") in
  (match result with
   | Ok _ -> print_endline "unexpected success"
   | Error error ->
     (match Error.sexp_of_t error with
      | List (tag :: _) -> print_s tag
      | sexp -> print_s sexp));
  [%expect {| (GET http://127.0.0.1:1/x) |}];
  return ()
;;

let%expect_test "decode_json" =
  let show response =
    print_s
      [%sexp
        (Http.decode_json response ~f:(Yojson.Safe.Util.member "a")
         |> Or_error.map ~f:Yojson.Safe.to_string
         : string Or_error.t)]
  in
  show (200, {|{"a":[1]}|});
  show (500, {|{"a":1}|});
  show (200, "not json");
  [%expect
    {|
    (Ok [1])
    (Error (((status 500) (body "{\"a\":1}")) "unexpected HTTP status"))
    (Error
     (((status 200) (body "not json"))
      ("Yojson__Common.Json_error(\"Line 1, bytes 0-8:\\nInvalid token 'not json'\")")))
    |}];
  return ()
;;
