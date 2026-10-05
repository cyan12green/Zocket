//! `realip` — restore the real client IP behind trusted proxies.
//!
//!   set_real_ip_from 10.0.0.0/8;
//!   set_real_ip_from 192.168.1.1;
//!   real_ip_header X-Forwarded-For;   (default)
//!   real_ip_recursive on;             (default off)
//!
//! Bound to `post_read` (before every access-phase decision): when the
//! connection peer matches a trusted prefix, `ctx.client_ip` is replaced
//! from the header. Without this, `allow`/`deny`, `limit_req` and `ip_hash`
//! all see the LB/CDN peer instead of the client.
//!
//! Selection mirrors nginx: `off` takes the LAST header entry (the claim
//! of the nearest proxy); `on` walks right-to-left past entries that are
//! themselves trusted proxies and takes the first untrusted one (the
//! leftmost client when the whole chain is trusted). Unparseable entries
//! are skipped; when nothing parses, the peer address is kept.
const std = @import("std");
const registry = @import("../registry.zig");
const router_mod = @import("../router.zig");
const sockets_mod = @import("../../net/sockets.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const realip = registry.Module{
    .name = "realip",
    .phase = .post_read,
    .run = run,
};

/// Default header when the route sets none.
pub const default_header = "X-Forwarded-For";

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.realip_from.len == 0) return .pass;
    // Untrusted peer: the header is hearsay, ignore it.
    if (!trusted(route, ctx.client_ip)) return .pass;

    const header_name = route.real_ip_header orelse default_header;
    const raw = headerValue(ctx, header_name) orelse return .pass;
    if (route.real_ip_recursive) {
        if (lastUntrusted(route, raw)) |ip| ctx.client_ip = ip;
    } else {
        if (lastEntry(raw)) |ip| ctx.client_ip = ip;
    }
    return .pass;
}

fn trusted(route: *const registry.Route, peer: [16]u8) bool {
    for (route.realip_from) |cidr| {
        if (sockets_mod.cidrContains(cidr, peer)) return true;
    }
    return false;
}

/// Runtime-name header lookup (first occurrence wins, case-insensitive).
/// `Request.header` needs a comptime name; the configured header is runtime.
fn headerValue(ctx: *Context, name: []const u8) ?[]const u8 {
    for (ctx.req.slots[0..ctx.req.header_count]) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, name)) return s.value;
    }
    return null;
}

/// Rightmost parseable header entry (nginx `recursive off`).
fn lastEntry(raw: []const u8) ?[16]u8 {
    var it = std.mem.splitScalar(u8, raw, ',');
    var best: ?[16]u8 = null;
    while (it.next()) |part| {
        const seg = std.mem.trim(u8, part, " \t");
        if (seg.len == 0) continue;
        if (sockets_mod.parseIp(seg)) |ip| best = ip;
    }
    return best;
}

/// Right-to-left walk past trusted entries (nginx `recursive on`): the
/// first untrusted entry from the right; when the whole chain is trusted,
/// the leftmost (original client).
fn lastUntrusted(route: *const registry.Route, raw: []const u8) ?[16]u8 {
    // Buffer the chain (headers are short; 16 entries is plenty) so the
    // walk runs right-to-left.
    var entries: [16][16]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const seg = std.mem.trim(u8, part, " \t");
        if (seg.len == 0) continue;
        const ip = sockets_mod.parseIp(seg) orelse continue;
        if (n < entries.len) {
            entries[n] = ip;
            n += 1;
        }
    }
    if (n == 0) return null;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (!trusted(route, entries[i])) return entries[i];
    }
    return entries[0];
}

const testing = std.testing;

fn reqWith(hdrs: []const struct { n: []const u8, v: []const u8 }) registry.Request {
    var req = registry.Request.init(testing.allocator);
    for (hdrs) |h| _ = req.addHeaderParsed(h.n, h.v) catch unreachable;
    return req;
}

test "realip: untrusted peer keeps its address" {
    var req = reqWith(&.{.{ .n = "X-Forwarded-For", .v = "203.0.113.9" }});
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const from = [_]router_mod.Cidr{sockets_mod.parseCidr("10.0.0.0/8").?};
    const route = registry.Route{ .path = "/", .realip_from = &from };
    ctx.route = &route;
    ctx.client_ip = sockets_mod.parseIp("198.51.100.3").?;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(sockets_mod.parseIp("198.51.100.3").?, ctx.client_ip);
}

test "realip: trusted peer takes the last entry by default" {
    var req = reqWith(&.{.{ .n = "X-Forwarded-For", .v = "203.0.113.9, 10.0.0.2" }});
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const from = [_]router_mod.Cidr{sockets_mod.parseCidr("10.0.0.0/8").?};
    const route = registry.Route{ .path = "/", .realip_from = &from };
    ctx.route = &route;
    ctx.client_ip = sockets_mod.parseIp("10.0.0.1").?;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(sockets_mod.parseIp("10.0.0.2").?, ctx.client_ip);
}

test "realip: recursive walks past trusted proxies to the client" {
    var req = reqWith(&.{.{ .n = "X-Forwarded-For", .v = "203.0.113.9, 10.0.0.2, 10.0.0.3" }});
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const from = [_]router_mod.Cidr{sockets_mod.parseCidr("10.0.0.0/8").?};
    const route = registry.Route{ .path = "/", .realip_from = &from, .real_ip_recursive = true };
    ctx.route = &route;
    ctx.client_ip = sockets_mod.parseIp("10.0.0.1").?;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(sockets_mod.parseIp("203.0.113.9").?, ctx.client_ip);
}

test "realip: recursive takes the rightmost untrusted entry" {
    // Spoofed middle: the rightmost untrusted entry wins, not the
    // leftmost client claim.
    var req = reqWith(&.{.{ .n = "X-Forwarded-For", .v = "10.9.9.9, 203.0.113.8, 10.0.0.2" }});
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const from = [_]router_mod.Cidr{sockets_mod.parseCidr("10.0.0.0/8").?};
    const route = registry.Route{ .path = "/", .realip_from = &from, .real_ip_recursive = true };
    ctx.route = &route;
    ctx.client_ip = sockets_mod.parseIp("10.0.0.1").?;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(sockets_mod.parseIp("203.0.113.8").?, ctx.client_ip);
}

test "realip: custom header, garbage entries and missing header" {
    const from = [_]router_mod.Cidr{sockets_mod.parseCidr("all").?};
    // Custom header respected.
    {
        var req = reqWith(&.{.{ .n = "X-Real-IP", .v = "203.0.113.5" }});
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        const route = registry.Route{ .path = "/", .realip_from = &from, .real_ip_header = "X-Real-IP" };
        ctx.route = &route;
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expectEqual(sockets_mod.parseIp("203.0.113.5").?, ctx.client_ip);
    }
    // Garbage entries skipped; missing header keeps the peer.
    {
        var req = reqWith(&.{.{ .n = "X-Forwarded-For", .v = "bogus, 203.0.113.6, " }});
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        const route = registry.Route{ .path = "/", .realip_from = &from };
        ctx.route = &route;
        ctx.client_ip = sockets_mod.parseIp("10.0.0.1").?;
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expectEqual(sockets_mod.parseIp("203.0.113.6").?, ctx.client_ip);
    }
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        const route = registry.Route{ .path = "/", .realip_from = &from };
        ctx.route = &route;
        ctx.client_ip = sockets_mod.parseIp("10.0.0.1").?;
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expectEqual(sockets_mod.parseIp("10.0.0.1").?, ctx.client_ip);
    }
}
