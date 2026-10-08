const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Prometheus exposition + JSON status API (C3 observability).
/// Both bind to `content`: `location /metrics { prometheus; }`
/// renders `zocket_*` gauges from `ctx.stats`; `location /status {
/// status_json; }` renders the same counters as JSON. No new reactor
/// counters in v1 — the six existing ServerStats fields are the source;
/// per-module counters (cache hits, rate sheds) ride the shmem-zone
/// contract when that lands.
pub const prometheus = registry.Module{
    .name = "prometheus",
    .phase = .content,
    .run = runPrometheus,
};

pub const status_json = registry.Module{
    .name = "status_json",
    .phase = .content,
    .run = runStatusJson,
};

fn runPrometheus(ctx: *Context) anyerror!Action {
    const stats = ctx.stats orelse return .pass;
    const body = ctx.sharedFmt(
        "# HELP zocket_connections_active Currently active connections.\n" ++
            "# TYPE zocket_connections_active gauge\n" ++
            "zocket_connections_active {d}\n" ++
            "# HELP zocket_connections_accepted Total accepted connections.\n" ++
            "# TYPE zocket_connections_accepted counter\n" ++
            "zocket_connections_accepted {d}\n" ++
            "# HELP zocket_requests_total Total requests handled.\n" ++
            "# TYPE zocket_requests_total counter\n" ++
            "zocket_requests_total {d}\n" ++
            "# HELP zocket_connections_reading Connections in reading state.\n" ++
            "# TYPE zocket_connections_reading gauge\n" ++
            "zocket_connections_reading {d}\n" ++
            "# HELP zocket_connections_writing Connections in writing state.\n" ++
            "# TYPE zocket_connections_writing gauge\n" ++
            "zocket_connections_writing {d}\n" ++
            "# HELP zocket_connections_waiting Idle keep-alive connections.\n" ++
            "# TYPE zocket_connections_waiting gauge\n" ++
            "zocket_connections_waiting {d}\n",
        .{
            stats.active.load(.monotonic),
            stats.accepted.load(.monotonic),
            stats.requests.load(.monotonic),
            stats.reading.load(.monotonic),
            stats.writing.load(.monotonic),
            stats.waiting.load(.monotonic),
        },
    ) orelse return error.OutOfMemory;
    ctx.resp.status = .ok;
    ctx.resp.body = body;
    ctx.resp.setHeader("Content-Type", "text/plain; version=0.0.4");
    return .handled;
}

fn runStatusJson(ctx: *Context) anyerror!Action {
    const stats = ctx.stats orelse return .pass;
    const body = ctx.sharedFmt(
        "{{\"active\":{d},\"accepted\":{d},\"requests\":{d},\"reading\":{d},\"writing\":{d},\"waiting\":{d}}}",
        .{
            stats.active.load(.monotonic),
            stats.accepted.load(.monotonic),
            stats.requests.load(.monotonic),
            stats.reading.load(.monotonic),
            stats.writing.load(.monotonic),
            stats.waiting.load(.monotonic),
        },
    ) orelse return error.OutOfMemory;
    ctx.resp.status = .ok;
    ctx.resp.body = body;
    ctx.resp.setHeader("Content-Type", "application/json");
    return .handled;
}

/// JSON string escaper for log lines (quote, backslash, control chars as
/// \u00XX; forward slash left bare). Pure, unit-tested; access_log's
/// `log_format json` preset composes through it.
pub fn jsonEscape(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{0:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, &buf);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

const testing = std.testing;

test "prometheus renders exposition from stats" {
    var stats = registry.ServerStats.init();
    stats.active.store(3, .monotonic);
    stats.accepted.store(10, .monotonic);
    stats.requests.store(99, .monotonic);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator, .stats = &stats };
    try testing.expectEqual(Action.handled, try runPrometheus(&ctx));
    try testing.expect(std.mem.indexOf(u8, resp.body, "zocket_requests_total 99") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "# TYPE zocket_connections_active gauge") != null);
}

test "prometheus passes without stats" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator };
    try testing.expectEqual(Action.pass, try runPrometheus(&ctx));
}

test "status_json renders counters as JSON" {
    var stats = registry.ServerStats.init();
    stats.active.store(2, .monotonic);
    stats.requests.store(7, .monotonic);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator, .stats = &stats };
    try testing.expectEqual(Action.handled, try runStatusJson(&ctx));
    try testing.expectEqualStrings(
        "{\"active\":2,\"accepted\":0,\"requests\":7,\"reading\":0,\"writing\":0,\"waiting\":0}",
        resp.body,
    );
}

test "jsonEscape quotes and escapes controls" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try jsonEscape(&list, testing.allocator, "a\"b\\c\n\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001\"", list.items);
}
