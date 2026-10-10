const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Prometheus metrics endpoint (`content metrics;` in a location): renders
/// the shared server counters in the Prometheus text exposition format
/// (version 0.0.4). The metric names use the `zocket_` prefix; scraping is
/// pull-based like nginx-prometheus-exporter, but built in.
///
/// The skeleton is a comptime literal and only the numbers are formatted at
/// runtime into the shared request memory (reclaimed with the response).
pub const metrics = registry.Module{
    .name = "metrics",
    .phase = .content,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const stats = ctx.stats orelse return .pass;

    const active = stats.active.load(.monotonic);
    const reading = stats.reading.load(.monotonic);
    const writing = stats.writing.load(.monotonic);
    const waiting = stats.waiting.load(.monotonic);
    const accepted = stats.accepted.load(.monotonic);
    const requests = stats.requests.load(.monotonic);

    const body = ctx.sharedFmt(
        "# HELP zocket_requests_total Total HTTP requests served.\n" ++
            "# TYPE zocket_requests_total counter\n" ++
            "zocket_requests_total {d}\n" ++
            "# HELP zocket_connections_accepted_total Total accepted TCP connections.\n" ++
            "# TYPE zocket_connections_accepted_total counter\n" ++
            "zocket_connections_accepted_total {d}\n" ++
            "# HELP zocket_connections_active Currently established connections.\n" ++
            "# TYPE zocket_connections_active gauge\n" ++
            "zocket_connections_active {d}\n" ++
            "# HELP zocket_connections_reading Connections currently reading a request.\n" ++
            "# TYPE zocket_connections_reading gauge\n" ++
            "zocket_connections_reading {d}\n" ++
            "# HELP zocket_connections_writing Connections currently writing a response.\n" ++
            "# TYPE zocket_connections_writing gauge\n" ++
            "zocket_connections_writing {d}\n" ++
            "# HELP zocket_connections_waiting Idle keep-alive connections.\n" ++
            "# TYPE zocket_connections_waiting gauge\n" ++
            "zocket_connections_waiting {d}\n",
        .{ requests, accepted, active, reading, writing, waiting },
    ) orelse return error.OutOfMemory;

    ctx.resp.status = .ok;
    ctx.resp.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    ctx.resp.body = body;
    return .handled;
}

const testing = std.testing;

test "metrics renders the exposition format from the shared counters" {
    const allocator = testing.allocator;
    var stats = registry.ServerStats.init();
    _ = stats.requests.fetchAdd(1234, .monotonic);
    _ = stats.accepted.fetchAdd(99, .monotonic);
    stats.active.store(7, .monotonic);
    stats.reading.store(1, .monotonic);
    stats.writing.store(2, .monotonic);
    stats.waiting.store(4, .monotonic);

    var req = registry.Request.init(allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = allocator, .stats = &stats };
    try testing.expectEqual(Action.handled, try run(&ctx));

    const body = resp.body;
    try testing.expect(std.mem.indexOf(u8, body, "zocket_requests_total 1234\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "zocket_connections_accepted_total 99\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "zocket_connections_active 7\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "zocket_connections_reading 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "zocket_connections_writing 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "zocket_connections_waiting 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "# TYPE zocket_requests_total counter\n") != null);
}

test "metrics without stats passes" {
    const allocator = testing.allocator;
    var req = registry.Request.init(allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = allocator };
    try testing.expectEqual(Action.pass, try run(&ctx));
}
