src/
    main.zig
    net/
        server.zig        (M1 single-threaded, kept for A/B)
        multireactor.zig  (M2: accept loop + dispatcher + reactor lifecycle)
        reactor.zig       (M2/M3: per-core epoll thread, echo or HTTP mode)
        dispatcher.zig
        eventfd.zig
        epoll.zig
        connection.zig
        buffer.zig
        sockets.zig
    http/
        parser.zig        (M3: incremental HTTP/1.x request parser)
        response.zig      (M3: response builder)
    runtime/
        worker.zig        (planned)
        scheduler.zig
    dsl/
        lexer.zig         (planned)
        parser.zig
        vm.zig


Status
Milestone 1  DONE   Single-threaded epoll echo server (src/net/server.zig).
                     Baseline recorded in bench/BENCH.md.
Milestone 2  DONE   Multi-threaded reactors, one epoll loop per core
                     (src/net/multireactor.zig, reactor.zig). Best
                     throughput at --threads <physical cores>.
Milestone 3  IN PROGRESS
                     HTTP/1.1 parsing (request line, headers, Content-Length
                     body, keep-alive), response builder, HTTP reactor mode
                     (--http). Docs/plan: docs/M3.md.
Milestone 4  TODO   Router + DSL.

Run modes

  zig build run                       HTTP mode (default), port 8080
  zig build run -- --http --threads 4 HTTP, 4 reactors (best on this box)
  zig build run -- --echo             raw byte-echo, multi-reactor
  zig build run -- --single           Milestone 1 single-threaded echo

Benchmarks and correctness checks: see bench/BENCH.md and docs/M3.md.
