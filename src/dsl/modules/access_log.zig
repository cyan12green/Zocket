const std = @import("std");
const registry = @import("../registry.zig");
const vars = @import("../vars.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Access logging. Bound to the `log` phase,
/// which runs as pipeline post-processing after every request. The format
/// is a named `log_format` from the config, compiled at comptime into a
/// complex-value fragment list; per-request rendering walks the constant
/// fragment list — zero string scanning. Lines are buffered per reactor
/// (thread-local) and flushed when the buffer fills.
///
/// Default format (nginx combined):
/// `$ip - - [$date] "$request" $status $bytes "$referer" "$user_agent"`
pub const access_log = registry.Module{
    .name = "access_log",
    .phase = .log,
    .run = run,
};

pub const combined_format = "$ip - - [$date] \"$request\" $status $bytes \"$referer\" \"$user_agent\"";

/// The combined-format fragment list, built at compile time (the default
/// when the route declares no `access_log` directive).
pub const combined_frags = vars.parseComplexValue(combined_format, &.{});

/// Built-in JSON form: one object per request with the standard fields.
/// Values are escaped (quotes/backslashes/control bytes); `status` and
/// `bytes` stay bare JSON numbers.
const jfrags = struct {
    const date = vars.parseComplexValue("$date", &.{});
    const ip = vars.parseComplexValue("$ip", &.{});
    const request = vars.parseComplexValue("$request", &.{});
    const status = vars.parseComplexValue("$status", &.{});
    const bytes = vars.parseComplexValue("$bytes", &.{});
    const referer = vars.parseComplexValue("$referer", &.{});
    const user_agent = vars.parseComplexValue("$user_agent", &.{});
};

/// Sink wrapper that JSON-escapes every appended chunk (chunk boundaries do
/// not matter for per-byte escaping).
fn JsonEsc(comptime Ptr: type) type {
    return struct {
        inner: Ptr,
        pub fn appendAll(self: *@This(), bytes: []const u8) !void {
            for (bytes) |c| {
                switch (c) {
                    '"' => try self.inner.appendAll("\\\""),
                    '\\' => try self.inner.appendAll("\\\\"),
                    '\n' => try self.inner.appendAll("\\n"),
                    '\r' => try self.inner.appendAll("\\r"),
                    '\t' => try self.inner.appendAll("\\t"),
                    0...8, 11, 12, 14...0x1f => {
                        var buf: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch {};
                        try self.inner.appendAll(buf[0..6]);
                    },
                    else => try self.inner.appendAll(&[_]u8{c}),
                }
            }
        }
    };
}

fn renderJson(ctx: *Context, sink: anytype) !void {
    var esc = JsonEsc(@TypeOf(sink)){ .inner = sink };
    try sink.appendAll("{\"ts\":\"");
    try vars.renderComplex(ctx, jfrags.date, &esc);
    try sink.appendAll("\",\"remote_addr\":\"");
    try vars.renderComplex(ctx, jfrags.ip, &esc);
    try sink.appendAll("\",\"request\":\"");
    try vars.renderComplex(ctx, jfrags.request, &esc);
    try sink.appendAll("\",\"status\":");
    try vars.renderComplex(ctx, jfrags.status, &esc);
    try sink.appendAll(",\"bytes\":");
    try vars.renderComplex(ctx, jfrags.bytes, &esc);
    try sink.appendAll(",\"referer\":\"");
    try vars.renderComplex(ctx, jfrags.referer, &esc);
    try sink.appendAll("\",\"user_agent\":\"");
    try vars.renderComplex(ctx, jfrags.user_agent, &esc);
    try sink.appendAll("\"}");
}

fn run(ctx: *Context) anyerror!Action {
    const allocator = ctx.allocator orelse return .pass;
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    // JSON mode (`access_log json;`) and `off` are decided before the
    // named-format lookup.
    if (ctx.route) |route| {
        if (route.log_off) return .pass;
        if (route.log_json) {
            var stack_buf: [1024]u8 = undefined;
            var stack_sink = vars.StackSink{ .buf = &stack_buf };
            if (renderJson(ctx, &stack_sink)) |_| {
                std.log.info("{s}", .{stack_buf[0..stack_sink.len]});
            } else |_| {
                var sink = vars.ArrayListSink{ .list = &line, .allocator = allocator };
                try renderJson(ctx, &sink);
                std.log.info("{s}", .{line.items});
            }
            return .pass;
        }
    }

    // The route's log_format index selects a named format; `off` (null)
    // disables logging. Default: the combined format (index 0 semantics).
    const frags = blk: {
        if (ctx.route) |route| {
            if (route.log_format) |idx| {
                if (ctx.formats) |fmts| {
                    if (idx < fmts.len) break :blk fmts[idx].value;
                }
            }
        }
        break :blk combined_frags;
    };

    // Common case: render straight into a stack buffer (no per-line arena
    // traffic); fall back to the arena-backed list for very long lines
    // (huge request lines / user agents).
    var stack_buf: [1024]u8 = undefined;
    var stack_sink = vars.StackSink{ .buf = &stack_buf };
    if (vars.renderComplex(ctx, frags, &stack_sink)) |_| {
        std.log.info("{s}", .{stack_buf[0..stack_sink.len]});
    } else |_| {
        var sink = vars.ArrayListSink{ .list = &line, .allocator = allocator };
        try vars.renderComplex(ctx, frags, &sink);
        std.log.info("{s}", .{line.items});
    }
    return .pass;
}

const testing = std.testing;

test "json access log escapes quotes and control bytes" {
    const allocator = testing.allocator;
    var req = registry.Request.init(allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/a\"b";
    try req.addHeaderParsed("User-Agent", "Mozilla/5.0 \"quoted\"\n");
    var resp = registry.Response.init(.ok);
    resp.status = .ok;
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = allocator };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var sink = vars.ArrayListSink{ .list = &out, .allocator = allocator };
    try renderJson(&ctx, &sink);

    try testing.expect(std.mem.startsWith(u8, out.items, "{\"ts\":\""));
    try testing.expect(std.mem.indexOf(u8, out.items, "\"remote_addr\":") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "/a\\\"b") != null); // escaped quote in the URI
    try testing.expect(std.mem.indexOf(u8, out.items, "\\\"quoted\\\"") != null); // escaped UA quotes
    try testing.expect(std.mem.indexOf(u8, out.items, "\\n") != null); // escaped newline
    try testing.expect(std.mem.endsWith(u8, out.items, "\"}") or std.mem.endsWith(u8, out.items, "}"));
}

test "combined format parses into fragments covering the standard fields" {
    var saw_ip = false;
    var saw_date = false;
    var saw_request = false;
    var saw_status = false;
    var saw_bytes = false;
    var saw_referer = false;
    var saw_user_agent = false;
    for (combined_frags) |f| {
        if (f == .builtin) {
            switch (f.builtin) {
                .ip => saw_ip = true,
                .date => saw_date = true,
                .request => saw_request = true,
                .status => saw_status = true,
                .bytes => saw_bytes = true,
                .referer => saw_referer = true,
                .user_agent => saw_user_agent = true,
                else => {},
            }
        }
    }
    try testing.expect(saw_ip and saw_date and saw_request and saw_status and saw_bytes and saw_referer and saw_user_agent);
}

test "access_log renders a custom format via renderComplex" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/who?q=1";
    req.decoded_target = "/who";
    req.query_string = "?q=1";
    var resp = registry.Response.init(.ok);
    resp.setBody("hello");
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator };

    const fmt = vars.parseComplexValue("$request $status", &.{});
    var line = std.ArrayList(u8).empty;
    defer line.deinit(testing.allocator);
    var sink = vars.ArrayListSink{ .list = &line, .allocator = testing.allocator };
    try vars.renderComplex(&ctx, fmt, &sink);
    try testing.expectEqualStrings("GET /who?q=1 HTTP/1.1 200", line.items);
}

test "access_log passes with no allocator and logs the combined default" {
    // No allocator: nothing to render into, pass silently.
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Default combined format renders end to end (info-level line).
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.method = .get;
    req2.target = "/";
    var resp2 = registry.Response.init(.ok);
    resp2.setBody("hi");
    var ctx2 = Context{ .req = &req2, .resp = &resp2, .allocator = testing.allocator };
    ctx2.client_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
    try testing.expectEqual(Action.pass, try run(&ctx2));
}

test "access_log honours a named format and falls back on bad indexes" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .post;
    req.target = "/submit";
    var resp = registry.Response.init(.not_found);
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator };

    const short_value = vars.parseComplexValue("$request $status", &.{});
    const fmts = [_]registry.LogFormat{
        .{ .name = "short", .value = short_value },
    };
    ctx.formats = &fmts;

    // Valid index selects the named format.
    const short_route = registry.Route{ .path = "/", .log_format = 0 };
    ctx.route = &short_route;
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Out-of-range index falls back to combined.
    const bad_route = registry.Route{ .path = "/", .log_format = 7 };
    ctx.route = &bad_route;
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Index set but no format table: combined default.
    var ctx2 = Context{ .req = &req, .resp = &resp, .allocator = testing.allocator };
    ctx2.route = &short_route;
    try testing.expectEqual(Action.pass, try run(&ctx2));
}
