const std = @import("std");
const registry = @import("../registry.zig");
const parser = @import("../../http/parser.zig");
const flate = std.compress.flate;
const Io = std.Io;

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Only bodies at least this large are compressed (nginx's gzip_min_length
/// default); tiny bodies rarely shrink and waste a compression pass.
pub const min_compress_bytes = 20;

/// Gzip response transform. Bound to the `log` phase,
/// which the pipeline runs as post-processing after the content module has
/// produced the response. When the client sent `Accept-Encoding: gzip`, the
/// body is compressed with `std.compress.flate` (gzip container) into an
/// allocator-owned buffer, `Content-Encoding: gzip` and `Vary:
/// Accept-Encoding` are set, and the body is replaced. Skipped when the body
/// is too small, already encoded, or does not shrink.
pub const gzip = registry.Module{
    .name = "gzip",
    // Legacy marker only: filters run after the walk, ordered per route.
    .phase = .log,
    .kind = .filter,
    .run = run,
    .directives = &.{"gzip"},
};

fn run(ctx: *Context) anyerror!Action {
    const accept = ctx.req.header("accept-encoding") orelse return .pass;
    if (!acceptsToken(accept, "gzip")) return .pass;

    const body = ctx.resp.body;
    if (body.len < min_compress_bytes) return .pass;
    if (ctx.resp.status == .not_modified) return .pass;
    if (hasHeader(ctx.resp, "content-encoding")) return .pass;

    // Compression output goes into the shared request memory: the server
    // reclaims it with the rest of the request at response end (no
    // body_owned handoff, no free on the non-shrinking path).
    const compressed = try gzipCompressShared(ctx, body);
    if (compressed.len >= body.len) return .pass; // sent raw
    ctx.resp.body = compressed;
    ctx.resp.setHeader("Content-Encoding", "gzip");
    ctx.resp.setHeader("Vary", "Accept-Encoding");
    return .pass;
}

fn hasHeader(resp: *registry.Response, comptime name: []const u8) bool {
    for (resp.headers[0..resp.header_count]) |h| {
        if (parser.header_hasher.hash(h.name) == comptime parser.header_hasher.hash(name)) return true;
    }
    return false;
}

/// True if a comma-separated header value (with optional `;` parameters)
/// contains the given token. Token matching is a hash compare.
fn acceptsToken(value: []const u8, comptime token: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, value, ",");
    while (tokens.next()) |t| {
        var tok = std.mem.trim(u8, t, " \t");
        if (std.mem.indexOfScalar(u8, tok, ';')) |semi| tok = tok[0..semi];
        if (tok.len > 0 and parser.header_hasher.hash(tok) == comptime parser.header_hasher.hash(token)) {
            return true;
        }
    }
    return false;
}

/// Compress into the context's shared request memory (arena-backed; the
/// server reclaims it when the response completes).
pub fn gzipCompressShared(ctx: *Context, input: []const u8) ![]const u8 {
    const arena = ctx.req.arena.asAllocator();
    var list = std.ArrayList(u8).empty;
    // Pre-size so the allocating writer's buffer is non-empty at init.
    try list.ensureTotalCapacity(arena, 1024);
    var out = Io.Writer.Allocating.fromArrayList(arena, &list);

    const window = flate.max_window_len;
    var deflate_buf: [window * 2]u8 = undefined;
    const usable = window + @min(input.len, window);
    var deflate_w = try flate.Compress.init(
        &out.writer,
        deflate_buf[0..usable],
        .gzip,
        flate.Compress.Options.fastest,
    );
    try deflate_w.writer.writeAll(input);
    try deflate_w.writer.flush();
    const written = out.written();
    const copy = ctx.sharedAlloc(written.len) orelse return error.OutOfMemory;
    @memcpy(copy, written);
    return copy;
}

/// Compress `input` into a fresh allocator-owned allocation (test helper).
pub fn gzipCompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    // Pre-size so the allocating writer's buffer is non-empty at init.
    try list.ensureTotalCapacity(allocator, 1024);
    var out = Io.Writer.Allocating.fromArrayList(allocator, &list);

    const window = flate.max_window_len;
    var deflate_buf: [window * 2]u8 = undefined;
    const usable = window + @min(input.len, window);
    var deflate_w = try flate.Compress.init(
        &out.writer,
        deflate_buf[0..usable],
        .gzip,
        flate.Compress.Options.fastest,
    );
    try deflate_w.writer.writeAll(input);
    try deflate_w.writer.flush();
    var owned = out.toArrayList();
    return owned.toOwnedSlice(allocator);
}

/// Decompress a gzip payload into a fresh allocation (test helper; the
/// reverse-proxy module will reuse it later).
pub fn gzipDecompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var in_reader: Io.Reader = .fixed(input);
    var list = std.ArrayList(u8).empty;
    try list.ensureTotalCapacity(allocator, 1024);
    var out = Io.Writer.Allocating.fromArrayList(allocator, &list);

    const window = flate.max_window_len;
    var dc_buf: [window * 2]u8 = undefined;
    var decomp = flate.Decompress.init(&in_reader, .gzip, dc_buf[0..window]);
    var copy_buf: [4096]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&copy_buf) catch return error.CorruptGzip;
        if (n == 0) break;
        try out.writer.writeAll(copy_buf[0..n]);
    }
    var owned = out.toArrayList();
    return owned.toOwnedSlice(allocator);
}

const testing = std.testing;

fn parseAcceptRequest(allocator: std.mem.Allocator, accept: []const u8) !struct { req: registry.Request, parser: parser.Parser, buf: *@import("../../net/buffer.zig").Buffer } {
    var req = registry.Request.init(allocator);
    var p = parser.Parser.init(allocator);
    const buffer_mod = @import("../../net/buffer.zig");
    var buf = try buffer_mod.Buffer.init(allocator);
    var wire_buf: [256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nAccept-Encoding: {s}\r\nContent-Length: 0\r\n\r\n", .{accept}) catch unreachable;
    _ = buf.writeSlice(wire);
    try testing.expectEqual(parser.Outcome.complete, p.parse(buf, &req));
    return .{ .req = req, .parser = p, .buf = buf };
}

test "gzip compresses a compressible body and round-trips" {
    const allocator = testing.allocator;
    const body = "the quick brown fox jumps over the lazy dog. " ** 4;

    var ctx_state = try parseAcceptRequest(allocator, "gzip, br");
    defer ctx_state.req.deinit();
    defer ctx_state.parser.deinit();
    defer ctx_state.buf.deinit(allocator);

    var resp = registry.Response.init(.ok);
    resp.setBody(body);
    var ctx = Context{ .req = &ctx_state.req, .resp = &resp, .allocator = allocator };

    try testing.expectEqual(Action.pass, try run(&ctx));
    // The compressed body lives in the shared request memory (arena-backed,
    // reclaimed by the server) — nothing to free here.
    try testing.expect(!resp.body_owned);
    try testing.expect(resp.body.len < body.len);

    var found_encoding = false;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.mem.eql(u8, h.name, "Content-Encoding")) {
            try testing.expectEqualStrings("gzip", h.value);
            found_encoding = true;
        }
    }
    try testing.expect(found_encoding);

    const round = try gzipDecompress(allocator, resp.body);
    defer allocator.free(round);
    try testing.expectEqualStrings(body, round);
}

test "gzip skips tiny bodies, absent accept headers, 304s and non-shrinking bodies" {
    const allocator = testing.allocator;

    // Tiny body: below the threshold.
    {
        var st = try parseAcceptRequest(allocator, "gzip");
        defer st.req.deinit();
        defer st.parser.deinit();
        defer st.buf.deinit(allocator);
        var resp = registry.Response.init(.ok);
        resp.setBody("small");
        var ctx = Context{ .req = &st.req, .resp = &resp, .allocator = allocator };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expect(!resp.body_owned);
    }
    // Accept-Encoding without gzip.
    {
        var st = try parseAcceptRequest(allocator, "br");
        defer st.req.deinit();
        defer st.parser.deinit();
        defer st.buf.deinit(allocator);
        var resp = registry.Response.init(.ok);
        resp.setBody("a body that is long enough to compress well " ** 2);
        var ctx = Context{ .req = &st.req, .resp = &resp, .allocator = allocator };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expect(!resp.body_owned);
    }
    // 304 responses are never compressed.
    {
        var st = try parseAcceptRequest(allocator, "gzip");
        defer st.req.deinit();
        defer st.parser.deinit();
        defer st.buf.deinit(allocator);
        var resp = registry.Response.init(.not_modified);
        resp.setBody("a body that is long enough to compress well " ** 2);
        var ctx = Context{ .req = &st.req, .resp = &resp, .allocator = allocator };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expect(!resp.body_owned);
    }
    // Incompressible body: sent raw.
    {
        var st = try parseAcceptRequest(allocator, "gzip");
        defer st.req.deinit();
        defer st.parser.deinit();
        defer st.buf.deinit(allocator);
        // A pseudo-random body that flate cannot shrink.
        var body: [400]u8 = undefined;
        var seed: u64 = 0x12345678;
        for (&body) |*b| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            b.* = @truncate(seed >> 33);
        }
        var resp = registry.Response.init(.ok);
        resp.setBody(body[0..]);
        var ctx = Context{ .req = &st.req, .resp = &resp, .allocator = allocator };
        try testing.expectEqual(Action.pass, try run(&ctx));
        try testing.expect(!resp.body_owned);
        try testing.expectEqualStrings(body[0..], resp.body);
    }
}
