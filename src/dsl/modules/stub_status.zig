const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// nginx_status-style stub status page. Bound to the `content`
/// phase: renders active/reading/writing/waiting/accepted/requests from the
/// shared server counters (`ctx.stats`, updated atomically by the reactors)
/// into the comptime HTML/plain-text skeleton.
pub const stub_status = registry.Module{
    .name = "stub_status",
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

    // The skeleton is a comptime literal; only the numbers are
    // formatted at runtime. The body lives in the shared request memory —
    // the server reclaims it when the response is done.
    const body = ctx.sharedFmt("Active connections: {d}\n" ++
        "server accepts handled requests\n" ++
        " {d} {d} {d}\n" ++
        "Reading: {d} Writing: {d} Waiting: {d}\n", .{
        active,
        accepted,
        requests,
        accepted,
        reading,
        writing,
        waiting,
    }) orelse return error.OutOfMemory;

    ctx.resp.status = .ok;
    ctx.resp.body = body;
    ctx.resp.setHeader("Content-Type", "text/plain");
    return .handled;
}

const testing = std.testing;

test "stub status renders from a stats struct" {
    const allocator = testing.allocator;
    const Stats = registry.ServerStats;
    var stats = Stats.init();
    stats.active.store(3, .monotonic);
    stats.reading.store(1, .monotonic);
    stats.writing.store(1, .monotonic);
    stats.waiting.store(1, .monotonic);
    stats.accepted.store(10, .monotonic);
    stats.requests.store(99, .monotonic);

    var req = registry.Request.init(allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = allocator, .stats = &stats };

    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings(
        "Active connections: 3\nserver accepts handled requests\n 10 99 10\nReading: 1 Writing: 1 Waiting: 1\n",
        resp.body,
    );
}
