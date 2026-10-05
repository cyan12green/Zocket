//! `gunzip` — inflate gzipped responses for clients that don't want gzip.
//!
//!   gunzip on;
//!
//! A response filter (runs after every outcome): when the final response
//! carries `Content-Encoding: gzip` but the client did NOT send
//! `Accept-Encoding: gzip`, the body is inflated in place and the
//! Content-Encoding header removed (nginx `gunzip` semantics). Everything
//! else passes through untouched: gzip-accepting clients, non-gzip bodies,
//! empty bodies, sendfile (`body_from_file`) bodies, and corrupt payloads
//! (left as-is — a broken origin stays visible instead of becoming a 500).
const std = @import("std");
const registry = @import("../registry.zig");
const gzip_mod = @import("gzip.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const gunzip = registry.Module{
    .touches_headers = true,
    .name = "gunzip",
    // Legacy marker only: filters run after the walk, ordered per route.
    .phase = .log,
    .kind = .filter,
    .run = run,
    .directives = &.{"gunzip"},
};

fn run(ctx: *Context) anyerror!Action {
    // A client advertising gzip wants the bytes as they are.
    if (ctx.req.header("accept-encoding")) |ae| {
        if (gzip_mod.acceptsToken(ae, "gzip")) return .pass;
    }
    if (!isGzipEncoded(ctx.resp)) return .pass;
    if (ctx.resp.body_from_file) return .pass; // v1: memory bodies only
    if (ctx.resp.body.len == 0) return .pass;
    // Decompress straight into the shared request memory (reclaimed with
    // the request; no ownership handoff like the gzip filter's path).
    const plain = gzip_mod.gzipDecompress(ctx.req.arena.asAllocator(), ctx.resp.body) catch return .pass;
    ctx.resp.body = plain;
    _ = ctx.resp.removeHeader("Content-Encoding");
    return .pass;
}

/// True when the response claims `Content-Encoding: gzip` (sole value,
/// case-insensitive; multi-coding responses are out of scope).
fn isGzipEncoded(resp: *const registry.Response) bool {
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) {
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "gzip");
        }
    }
    return false;
}

const testing = std.testing;

fn gzipBody(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return gzip_mod.gzipCompress(allocator, raw);
}

test "gunzip: inflates for clients without Accept-Encoding" {
    const raw = "hello gunzip world, hello again and again and again";
    const compressed = try gzipBody(testing.allocator, raw);
    defer testing.allocator.free(compressed);
    try testing.expect(compressed.len < raw.len + 18); // sanity: actually gzipped

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    resp.body = compressed;
    resp.setHeader("Content-Encoding", "gzip");
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings(raw, resp.body);
    // Content-Encoding gone (headers scanned by name below).
    for (resp.headers[0..resp.header_count]) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Content-Encoding"));
    }
}

test "gunzip: leaves gzip-accepting clients and plain bodies alone" {
    const raw = "plain body here";
    // Client accepts gzip: untouched even though encoded.
    {
        const compressed = try gzipBody(testing.allocator, raw);
        defer testing.allocator.free(compressed);
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        _ = req.addHeaderParsed("Accept-Encoding", "gzip, deflate") catch unreachable;
        var resp = registry.Response.init(.ok);
        resp.body = compressed;
        resp.setHeader("Content-Encoding", "gzip");
        var ctx = Context{ .req = &req, .resp = &resp };
        _ = try run(&ctx);
        try testing.expectEqualStrings(compressed, resp.body);
        try testing.expectEqual(@as(usize, 1), resp.header_count);
    }
    // Not encoded: untouched (no Accept-Encoding at all).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.body = raw;
        resp.setHeader("Content-Type", "text/plain");
        var ctx = Context{ .req = &req, .resp = &resp };
        _ = try run(&ctx);
        try testing.expectEqualStrings(raw, resp.body);
    }
}

test "gunzip: corrupt payloads and file bodies pass through" {
    // Corrupt gzip: left as-is (visible origin error, not a 500).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.body = "this is not gzip data at all............";
        resp.setHeader("Content-Encoding", "gzip");
        var ctx = Context{ .req = &req, .resp = &resp };
        _ = try run(&ctx);
        try testing.expectEqualStrings("this is not gzip data at all............", resp.body);
        try testing.expectEqual(@as(usize, 1), resp.header_count);
    }
    // Sendfile body: out of scope, untouched.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.body_from_file = true;
        resp.setHeader("Content-Encoding", "gzip");
        var ctx = Context{ .req = &req, .resp = &resp };
        _ = try run(&ctx);
        try testing.expect(resp.body_from_file);
    }
    // Empty body with the header: nothing to inflate.
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        resp.body = "";
        resp.setHeader("Content-Encoding", "gzip");
        var ctx = Context{ .req = &req, .resp = &resp };
        _ = try run(&ctx);
        try testing.expectEqual(@as(usize, 0), resp.body.len);
    }
}
