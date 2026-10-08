//! Response body substitution (nginx `sub_filter` equivalent). A response
//! filter (runs after every outcome in reverse declaration order): replaces
//! `match` with `replacement` in text bodies. `sub_filter_once on`
//! (default) replaces the first occurrence only; `off` replaces all.
//!
//! Config:
//!   location / {
//!       sub_filter "Powered by X" "Powered by Zocket";
//!       sub_filter_once off;
//!   }
//!
//! Memory bodies only (file/sendfile bodies pass through — same rule as
//! gunzip); skipped for non-2xx, encoded bodies, and empty matches.

const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const sub_filter = registry.Module{
    .name = "sub_filter",
    .phase = .log,
    .kind = .filter,
    .run = run,
    .directives = &.{"sub_filter"},
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const match = route.sub_filter_match orelse return .pass;
    const repl = route.sub_filter_replacement orelse return .pass;
    if (match.len == 0) return .pass;
    if (ctx.resp.status != .ok and ctx.resp.status != .not_found) {
        // nginx filters successful responses; error pages opt in via 404.
        // Keep the gate tight: 200 + 404 only.
        return .pass;
    }
    if (ctx.resp.body.len == 0 or ctx.resp.body_from_file) return .pass;
    if (hasHeader(ctx.resp, "content-encoding")) return .pass;
    const ctype = headerValue(ctx.resp, "content-type") orelse "text/html";
    if (!isTextual(ctype)) return .pass;

    const out = substitute(ctx, ctx.resp.body, match, repl, route.sub_filter_once) orelse return .pass;
    ctx.resp.body = out;
    return .pass;
}

/// Substitute match→repl (first only when `once`); null when nothing
/// matched. Pure over buffers (unit-tested); the caller owns arena снимки.
fn substitute(ctx: *Context, body: []const u8, match: []const u8, repl: []const u8, once: bool) ?[]const u8 {
    const first = std.mem.indexOf(u8, body, match) orelse return null;
    var total = body.len - match.len + repl.len;
    if (!once) {
        var count: usize = 1;
        var pos = first + match.len;
        while (std.mem.indexOfPos(u8, body, pos, match)) |idx| {
            count += 1;
            pos = idx + match.len;
        }
        total = body.len - count * match.len + count * repl.len;
    }
    const out = ctx.sharedAlloc(total) orelse return null;
    @memcpy(out[0..first], body[0..first]);
    @memcpy(out[first..][0..repl.len], repl);
    if (once) {
        @memcpy(out[first + repl.len ..], body[first + match.len ..]);
        return out;
    }
    var w = first + repl.len;
    var r = first + match.len;
    while (std.mem.indexOfPos(u8, body, r, match)) |idx| {
        @memcpy(out[w..][0 .. idx - r], body[r..idx]);
        w += idx - r;
        @memcpy(out[w..][0..repl.len], repl);
        w += repl.len;
        r = idx + match.len;
    }
    @memcpy(out[w..], body[r..]);
    return out;
}

fn isTextual(ctype: []const u8) bool {
    // text/*, JSON, XML, JavaScript, URL-encoded — nginx's sub_filter_types
    // default (text/html) plus the usual suspects, presence-matched.
    if (std.ascii.startsWithIgnoreCase(ctype, "text/")) return true;
    const lower_ok = std.ascii.startsWithIgnoreCase(ctype, "application/json") or
        std.ascii.startsWithIgnoreCase(ctype, "application/xml") or
        std.ascii.startsWithIgnoreCase(ctype, "application/javascript") or
        std.ascii.startsWithIgnoreCase(ctype, "application/x-www-form-urlencoded");
    return lower_ok;
}

fn hasHeader(resp: *const registry.Response, comptime name: []const u8) bool {
    const parser = @import("../../http/parser.zig");
    for (resp.headers[0..resp.header_count]) |h| {
        if (parser.header_hasher.hash(h.name) == comptime parser.header_hasher.hash(name)) return true;
    }
    return false;
}

fn headerValue(resp: *const registry.Response, comptime name: []const u8) ?[]const u8 {
    const parser = @import("../../http/parser.zig");
    for (resp.headers[0..resp.header_count]) |h| {
        if (parser.header_hasher.hash(h.name) == comptime parser.header_hasher.hash(name)) return h.value;
    }
    return null;
}

const testing = std.testing;

test "sub_filter replaces once by default, all when off" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    resp.setBody("aXbXc");
    resp.setHeader("Content-Type", "text/html");
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .sub_filter_match = "X", .sub_filter_replacement = "YZ", .sub_filter_once = true };
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("aYZbXc", resp.body);

    var resp2 = registry.Response.init(.ok);
    resp2.setBody("aXbXc");
    resp2.setHeader("Content-Type", "text/html");
    var ctx2 = Context{ .req = &req, .resp = &resp2 };
    ctx2.route = &.{ .path = "/", .sub_filter_match = "X", .sub_filter_replacement = "YZ", .sub_filter_once = false };
    try testing.expectEqual(Action.pass, try run(&ctx2));
    try testing.expectEqualStrings("aYZbYZc", resp2.body);
}

test "sub_filter skips encoded, binary and file bodies" {
    const run_case = struct {
        fn go(setup: *const fn (*registry.Response) void) !Action {
            var req = registry.Request.init(testing.allocator);
            defer req.deinit();
            var resp = registry.Response.init(.ok);
            setup(&resp);
            var ctx = Context{ .req = &req, .resp = &resp };
            ctx.route = &.{ .path = "/", .sub_filter_match = "X", .sub_filter_replacement = "Y", .sub_filter_once = false };
            return run(&ctx);
        }
    }.go;
    // Encoded body.
    try testing.expectEqual(Action.pass, try run_case(struct {
        fn s(r: *registry.Response) void {
            r.setBody("X");
            r.setHeader("Content-Encoding", "gzip");
        }
    }.s));
    // Non-textual content type.
    try testing.expectEqual(Action.pass, try run_case(struct {
        fn s(r: *registry.Response) void {
            r.setBody("X");
            r.setHeader("Content-Type", "image/png");
        }
    }.s));
    // Missing content-type defaults to text/html (substituted).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.setBody("axb");
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &.{ .path = "/", .sub_filter_match = "x", .sub_filter_replacement = "YY", .sub_filter_once = true };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expectEqualStrings("aYYb", resp.body);
    }
    // No match: body untouched (same slice).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.setBody("abc");
        const before = resp.body.ptr;
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &.{ .path = "/", .sub_filter_match = "zzz", .sub_filter_replacement = "Y", .sub_filter_once = true };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expect(resp.body.ptr == before);
    }
}
