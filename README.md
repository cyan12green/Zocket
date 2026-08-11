src/
    main.zig
    root.zig             (library root; re-exports + comptime test imports)
    net/
        server.zig        (M1 single-threaded, kept for A/B)
        multireactor.zig  (M2: accept loop + dispatcher + reactor lifecycle)
        reactor.zig       (M2/M3/M4: per-core epoll thread, echo or HTTP mode)
        dispatcher.zig
        eventfd.zig
        epoll.zig
        connection.zig
        buffer.zig
        sockets.zig
    http/
        parser.zig        (M3: incremental HTTP/1.x request parser)
        response.zig      (M3: response builder)
    dsl/
        phase.zig         (M4: nginx-style phase enum, execution order)
        router.zig        (M4: prefix/exact route matching)
        registry.zig      (M4: comptime module registry + Context)
        pipeline.zig      (M4: phase dispatch loop)
        modules/
            echo.zig      (M4: echo content module)
    runtime/
        config.zig        (M4: route table, JSON + struct-literal loading)
        server.zig        (M4: shared request processor wiring)


Status
Milestone 1  DONE   Single-threaded epoll echo server (src/net/server.zig).
                     Baseline recorded in bench/BENCH.md.
Milestone 2  DONE   Multi-threaded reactors, one epoll loop per core
                     (src/net/multireactor.zig, reactor.zig). Best
                     throughput at --threads <physical cores>.
Milestone 3  DONE   HTTP/1.1 parsing (request line, headers, Content-Length
                     body, keep-alive), response builder, HTTP reactor mode
                     (--http). Docs/plan: docs/M3.md.
Milestone 4  DONE   Config-driven phase pipeline: comptime module registry,
                     nginx-style phase dispatch, prefix/exact routing, echo
                     module, JSON or struct-literal config. Docs: docs/M4.md.

Run modes

  zig build run                       HTTP mode (default), port 8080
  zig build run -- --http --threads 4 HTTP, 4 reactors (best on this box)
  zig build run -- --config <file>    HTTP, config-driven pipeline (JSON)
  zig build run -- --echo             raw byte-echo, multi-reactor
  zig build run -- --single           Milestone 1 single-threaded echo

Benchmarks and correctness checks: see bench/BENCH.md and docs/M3.md, docs/M4.md.
