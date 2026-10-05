//! `allow` / `deny` — CIDR access control in the access phase.
//!
//!   allow 192.168.1.0/24;
//!   allow 10.0.0.5;
//!   deny all;
//!
//! First matching rule in declaration order wins; no match allows (nginx
//! semantics). Evaluated against `ctx.client_ip` — behind a CDN/LB combine
//! with `set_real_ip_from` (realip module, post_read) so the decision sees
//! the real client instead of the proxy peer. A deny answers 403 directly.
const std = @import("std");
const registry = @import("../registry.zig");
const router_mod = @import("../router.zig");
const sockets_mod = @import("../../net/sockets.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const access = registry.Module{
    .name = "access",
    .phase = .access,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    for (route.access_rules) |rule| {
        if (!sockets_mod.cidrContains(rule.cidr, ctx.client_ip)) continue;
        if (rule.allow) return .pass;
        ctx.resp.status = .forbidden;
        ctx.resp.body = registry.Status.forbidden.reasonPhrase();
        return .handled;
    }
    return .pass;
}

const testing = std.testing;

fn v4(s: []const u8) [16]u8 {
    return sockets_mod.parseIp(s).?;
}

test "access: no rules allows everything" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
}

test "access: first match wins, deny answers 403" {
    const rules = [_]router_mod.AccessRule{
        .{ .allow = true, .cidr = sockets_mod.parseCidr("192.168.1.0/24").? },
        .{ .allow = false, .cidr = sockets_mod.parseCidr("all").? },
    };
    const route = registry.Route{ .path = "/", .access_rules = &rules };
    // In-network: allowed.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        ctx.client_ip = v4("192.168.1.50");
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
    // Outside: falls to `deny all` -> 403.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        ctx.client_ip = v4("203.0.113.7");
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(registry.Status.forbidden, resp.status);
    }
}

test "access: order matters — earlier deny beats later allow" {
    const rules = [_]router_mod.AccessRule{
        .{ .allow = false, .cidr = sockets_mod.parseCidr("10.0.0.0/8").? },
        .{ .allow = true, .cidr = sockets_mod.parseCidr("all").? },
    };
    const route = registry.Route{ .path = "/", .access_rules = &rules };
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    ctx.client_ip = v4("10.9.9.9");
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.forbidden, resp.status);
}

test "access: exact host rule and zero peer" {
    const rules = [_]router_mod.AccessRule{
        .{ .allow = true, .cidr = sockets_mod.parseCidr("10.0.0.5").? },
        .{ .allow = false, .cidr = sockets_mod.parseCidr("all").? },
    };
    const route = registry.Route{ .path = "/", .access_rules = &rules };
    // Unknown peer (zeroes): denied by the catch-all.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        try testing.expectEqual(Action.handled, try run(&ctx));
    }
    // Exact host: allowed.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        ctx.client_ip = v4("10.0.0.5");
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
}
