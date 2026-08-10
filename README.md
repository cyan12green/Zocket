src/
    main.zig
    net/
        socket.zig
        epoll.zig
        server.zig
        connection.zig
        buffer.zig
    http/
        parser.zig
        response.zig
    runtime/
        worker.zig
        scheduler.zig
    dsl/
        lexer.zig
        parser.zig
        vm.zig


Suggested Milestones
Milestone 1

Single-threaded epoll echo server.

Benchmark:

connections/sec
latency
throughput

Use:

wrk
bombardier
iperf
Milestone 2

Multi-threaded reactors.

One epoll loop per core.

Milestone 3

HTTP parsing.

Implement:

request line
headers
keep-alive

Avoid full RFC compliance initially.

Milestone 4

Router + DSL.

Example desired DSL:
