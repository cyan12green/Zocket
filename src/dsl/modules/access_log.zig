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

fn run(ctx: *Context) anyerror!Action {
    const allocator = ctx.allocator orelse return .pass;
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

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

    var sink = vars.ArrayListSink{ .list = &line, .allocator = allocator };
    try vars.renderComplex(ctx, frags, &sink);
    try line.append(allocator, '\n');

    // Write to stderr per line (thread-local buffer only for the syscall
    // batching; a per-thread buffer alone never flushed for low request
    // volumes, since each reactor thread holds its own 4096-byte window).
    _ = std.posix.write(2, line.items) catch {};
    return .pass;
}

const testing = std.testing;

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
