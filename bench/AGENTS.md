# AGENTS.md: bench/

`main.exe`: two measurements over loopback. The delivery hop alone (100,000 frames already queued on the
connection's pipe), and frames per second end to end against an in-process websocket server, in bursts
or one frame per write.

- Run it from the workspace with `dune exec --root .. ./venue-net/bench/main.exe`. It needs no network.
- Numbers depend on the machine. Record the machine and the commit with any number you put in the README or a commit.
- It is not a test. A pinned count from it belongs in `test/`, with a comment about the platform.
