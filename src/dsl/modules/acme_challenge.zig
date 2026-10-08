//! ACME http-01 challenge responder (C3 auto-HTTPS): serves
//! `/.well-known/acme-challenge/<token>` from a bounded process-wide table
//! (`acmePutChallenge`, called by the renewal loop / tests). Bind
//! explicitly: `location /.well-known/acme-challenge/ { acme_challenge; }`.
//! Unknown tokens 404; the table holds 64 entries (failing closed on
//! overflow — a busy CA retry is cheaper than unbounded memory).

const std = @import("std");
const registry = @import("../registry.zig");
const compat = @import("../../compat.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const acme_challenge = registry.Module{
    .name = "acme_challenge",
    .phase = .content,
    .run = run,
};

const max_tokens = 64;
const Entry = struct {
    token: [128]u8 = undefined,
    token_len: usize = 0,
    key_auth: [256]u8 = undefined,
    key_auth_len: usize = 0,
    used: bool = false,
};

var table_mutex = compat.Mutex{};
var table: [max_tokens]Entry = @as([max_tokens]Entry, @splat(Entry{}));

/// Publish a challenge response (renewal loop). False when the table is
/// full — the caller retries the order later.
pub fn putChallenge(token: []const u8, key_auth: []const u8) bool {
    if (token.len == 0 or token.len > 128 or key_auth.len == 0 or key_auth.len > 256) return false;
    table_mutex.lock();
    defer table_mutex.unlock();
    // Replace same-token entries first (idempotent re-post).
    for (&table) |*e| {
        if (e.used and e.token_len == token.len and std.mem.eql(u8, e.token[0..e.token_len], token)) {
            @memcpy(e.key_auth[0..key_auth.len], key_auth);
            e.key_auth_len = key_auth.len;
            return true;
        }
    }
    for (&table) |*e| {
        if (!e.used) {
            @memcpy(e.token[0..token.len], token);
            e.token_len = token.len;
            @memcpy(e.key_auth[0..key_auth.len], key_auth);
            e.key_auth_len = key_auth.len;
            e.used = true;
            return true;
        }
    }
    return false;
}

pub fn clearChallenge(token: []const u8) void {
    table_mutex.lock();
    defer table_mutex.unlock();
    for (&table) |*e| {
        if (e.used and e.token_len == token.len and std.mem.eql(u8, e.token[0..e.token_len], token)) {
            e.used = false;
            e.token_len = 0;
            e.key_auth_len = 0;
        }
    }
}

fn lookup(token: []const u8) ?[]const u8 {
    table_mutex.lock();
    defer table_mutex.unlock();
    for (&table) |*e| {
        if (e.used and e.token_len == token.len and std.mem.eql(u8, e.token[0..e.token_len], token)) {
            return e.key_auth[0..e.key_auth_len];
        }
    }
    return null;
}

const prefix = "/.well-known/acme-challenge/";

fn run(ctx: *Context) anyerror!Action {
    const target = if (ctx.req.decoded_target.len > 0) ctx.req.decoded_target else ctx.req.target;
    if (!std.mem.startsWith(u8, target, prefix)) return .pass;
    const token = target[prefix.len..];
    // Query strings never belong on a challenge URL.
    const clean = if (std.mem.indexOfScalar(u8, token, '?')) |i| token[0..i] else token;
    const key_auth = lookup(clean) orelse {
        ctx.resp.status = .not_found;
        ctx.resp.body = registry.Status.not_found.reasonPhrase();
        return .handled;
    };
    const body = ctx.sharedDupe(key_auth) orelse return error.OutOfMemory;
    ctx.resp.status = .ok;
    ctx.resp.body = body;
    ctx.resp.setHeader("Content-Type", "text/plain");
    return .handled;
}

/// Test isolation: empty the table (challenge state is process-wide and
/// tests share it).
pub fn testReset() void {
    table_mutex.lock();
    defer table_mutex.unlock();
    for (&table) |*e| e.used = false;
}

const testing = std.testing;

test "acme challenge serves published tokens and 404s the rest" {
    testReset();
    try testing.expect(putChallenge("tok123", "tok123.thumb"));
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/.well-known/acme-challenge/tok123";
    req.decoded_target = "/.well-known/acme-challenge/tok123";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("tok123.thumb", resp.body);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.method = .get;
    req2.target = "/.well-known/acme-challenge/nope";
    req2.decoded_target = "/.well-known/acme-challenge/nope";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(Action.handled, try run(&ctx2));
    try testing.expectEqual(registry.Status.not_found, resp2.status);

    // Outside the prefix: pass-through.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.method = .get;
    req3.target = "/other";
    req3.decoded_target = "/other";
    var resp3 = registry.Response.init(.ok);
    var ctx3 = Context{ .req = &req3, .resp = &resp3 };
    try testing.expectEqual(Action.pass, try run(&ctx3));

    clearChallenge("tok123");
    testReset();
}

test "acme challenge table rejects overflow and bad sizes" {
    testReset();
    try testing.expect(!putChallenge("", "x"));
    try testing.expect(!putChallenge("t", ""));
    const big = @as([300]u8, @splat('a'));
    try testing.expect(!putChallenge(&big, "x"));
    testReset();
}
