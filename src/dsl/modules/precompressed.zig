//! Precompressed content serving (nginx `gzip_static` equivalent). Content
//! phase: when the route declares `precompressed gz;` and the client sent
//! `Accept-Encoding: gzip`, a request for `/a.css` is answered from
//! `/a.css.gz` on disk with `Content-Encoding: gzip` — zero runtime
//! compression cost. No `.gz` twin (or no client support) passes through to
//! the next module in the chain, typically static.
//!
//! Config:
//!   location /assets/ {
//!       root testdata;
//!       precompressed gz;
//!       content static;
//!   }

const std = @import("std");
const posix = std.posix;
const sys = @import("../../sys.zig");
const registry = @import("../registry.zig");
const mime_mod = @import("../../http/mime.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Refuse to buffer a precompressed body larger than this (the .gz twin of
/// a huge file would eat the request arena; static serves those directly).
const max_buffered = 8 * 1024 * 1024;

pub const precompressed = registry.Module{
    .name = "precompressed",
    .phase = .content,
    .run = run,
};

/// One servable encoding: disk suffix + wire token, best-first.
const Codec = struct {
    suffix: []const u8,
    token: []const u8,
    encoding: []const u8,
};

const codecs = [_]Codec{
    .{ .suffix = ".br", .token = "br", .encoding = "br" },
    .{ .suffix = ".zst", .token = "zstd", .encoding = "zstd" },
    .{ .suffix = ".gz", .token = "gzip", .encoding = "gzip" },
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const root = route.root orelse return .pass;
    const accepted = acceptedEncodings(ctx);

    // Path-safety: the same rules the static module applies — decoded
    // target must be relative and free of traversal.
    const target = ctx.req.decoded_target;
    if (target.len == 0 or target[0] == '/') return .pass;
    if (std.mem.indexOf(u8, target, "..") != null) return .pass;
    if (target.len + 4 > 512) return .pass;

    // Best-first among the enabled codecs the client accepts (nginx serves
    // each static twin independently; here one module covers all three).
    // Both sets are comptime/app-config data reduced to bit compares: the
    // old token-string compares ran per codec per request.
    for (codecs, 0..) |c, i| {
        if (!codecEnabledAt(route, i)) continue;
        if (!accepted.hasAt(i)) continue;
        if (tryTwin(ctx, root, target, c)) return .handled;
    }
    return .pass;
}

/// Codec enabled for this route, by `codecs` index (br, zstd, gzip).
fn codecEnabledAt(route: *const registry.Route, i: usize) bool {
    return switch (i) {
        0 => route.precompressed_br,
        1 => route.precompressed_zstd,
        2 => route.precompressed,
        else => false,
    };
}

const Accepted = struct {
    /// Bit i set = `codecs[i]` accepted by the client.
    bits: u3 = 0,
    fn hasAt(self: Accepted, i: usize) bool {
        return (self.bits & (@as(u3, 1) << @intCast(i))) != 0;
    }
};

fn acceptedEncodings(ctx: *Context) Accepted {
    var out = Accepted{};
    const ae = ctx.req.header("accept-encoding") orelse return out;
    var it = std.mem.splitScalar(u8, ae, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t");
        if (std.ascii.startsWithIgnoreCase(tok, "gzip")) {
            out.bits |= 1 << 2;
        } else if (std.ascii.startsWithIgnoreCase(tok, "br")) {
            out.bits |= 1 << 0;
        } else if (std.ascii.startsWithIgnoreCase(tok, "zstd")) {
            out.bits |= 1 << 1;
        }
    }
    return out;
}

fn tryTwin(ctx: *Context, root: []const u8, target: []const u8, c: Codec) bool {
    var path_buf: [520]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ root, target, c.suffix }) catch return false;

    const file = sys.openFile(path) catch return false; // no twin
    defer sys.close(file);
    const stat = sys.fstat(file) catch return false;
    if (stat.kind != .file) return false;
    if (stat.size > max_buffered) return false;

    const bytes = ctx.sharedAlloc(@intCast(stat.size)) orelse return false;
    var filled: usize = 0;
    while (filled < bytes.len) {
        const n = posix.read(file, bytes[filled..]) catch return false;
        if (n == 0) break;
        filled += n;
    }
    if (filled != bytes.len) return false;

    ctx.resp.status = .ok;
    ctx.resp.body = bytes;
    ctx.resp.setHeader("Content-Encoding", c.encoding);
    ctx.resp.setHeader("Vary", "Accept-Encoding");
    // Content-Type describes the ORIGINAL representation (strip suffix).
    ctx.resp.setHeader("Content-Type", mime_mod.mimeForPath(target));
    return true;
}

const Request = registry.Request;
const Response = registry.Response;
const testing = std.testing;

test "no accept-encoding or no gz twin passes through" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    _ = req.addHeaderParsed("Accept-Encoding", "identity") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata" };
    try testing.expectEqual(Action.pass, try run(&ctx));

    // gzip accepted but the twin does not exist.
    _ = req.addHeaderParsed("Accept-Encoding", "gzip") catch unreachable;
    req.decoded_target = "notes.md"; // testdata/notes.md exists; notes.md.gz does not
    try testing.expectEqual(Action.pass, try run(&ctx));
}

test "serves the gz twin with the original content type" {
    // Fixture: testdata/hello.txt.gz holds a tiny valid gzip of hello.txt.
    try makeTwin("testdata/hello.txt", "testdata/hello.txt.gz");
    defer sys.deleteFile("testdata/hello.txt.gz") catch {};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    _ = req.addHeaderParsed("Accept-Encoding", "gzip;q=1.0") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata", .precompressed = true };

    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    var encoding: ?[]const u8 = null;
    var ctype: ?[]const u8 = null;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) encoding = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) ctype = h.value;
    }
    try testing.expectEqualStrings("gzip", encoding.?);
    try testing.expectEqualStrings("text/plain", ctype.?);
    // The payload really is gzip magic.
    try testing.expect(resp.body.len >= 2 and resp.body[0] == 0x1f and resp.body[1] == 0x8b);
}

/// Write `<dst>` as a gzip container of `<src>`'s bytes (test fixture).
fn makeTwin(src: []const u8, dst: []const u8) !void {
    const gzip_mod = @import("gzip.zig");
    const allocator = testing.allocator;
    const raw = try sys.readFileAlloc(allocator, src, 1 << 20);
    defer allocator.free(raw);
    const compressed = try gzip_mod.gzipCompress(allocator, raw);
    defer allocator.free(compressed);
    try sys.writeFile(dst, compressed);
}

test "passes through without route, root, or a safe target" {
    // No route at all.
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Route without a root.
    ctx.route = &.{ .path = "/" };
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Unsafe or unusable targets never touch the disk.
    const bad_targets = [_][]const u8{
        "",
        "/hello.txt",
        "../escape.txt",
        "a/../b.txt",
    };
    for (bad_targets) |t| {
        var req2 = Request.init(testing.allocator);
        defer req2.deinit();
        req2.decoded_target = t;
        var resp2 = Response.init(.ok);
        var ctx2 = Context{ .req = &req2, .resp = &resp2 };
        ctx2.route = &.{ .path = "/", .root = "testdata" };
        try testing.expectEqual(Action.pass, try run(&ctx2));
    }

    // Overlong target (twin path would overflow the stack buffer).
    var req3 = Request.init(testing.allocator);
    defer req3.deinit();
    const long: [520]u8 = @as([520]u8, @splat('a'));
    req3.decoded_target = long[0..];
    var resp3 = Response.init(.ok);
    var ctx3 = Context{ .req = &req3, .resp = &resp3 };
    ctx3.route = &.{ .path = "/", .root = "testdata" };
    try testing.expectEqual(Action.pass, try run(&ctx3));
}

test "passes through without client gzip support" {
    // No Accept-Encoding header at all.
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata" };
    try testing.expectEqual(Action.pass, try run(&ctx));

    // Explicitly non-gzip encodings.
    _ = req.addHeaderParsed("Accept-Encoding", "br, zstd") catch unreachable;
    try testing.expectEqual(Action.pass, try run(&ctx));
}

test "uppercase GZIP matches case-insensitively" {
    try makeTwin("testdata/hello.txt", "testdata/hello.txt.gz");
    defer sys.deleteFile("testdata/hello.txt.gz") catch {};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    _ = req.addHeaderParsed("Accept-Encoding", "GZIP") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata", .precompressed = true };
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
}

test "br and zstd twins serve with best-first preference" {
    // Fixtures are opaque bytes (no std brotli/zstd encoders exist); the
    // module serves disk bytes verbatim with the right Content-Encoding.
    try sys.writeFile("testdata/hello.txt.br", "fake-br-payload");
    defer sys.deleteFile("testdata/hello.txt.br") catch {};
    try sys.writeFile("testdata/hello.txt.zst", "fake-zst-payload");
    defer sys.deleteFile("testdata/hello.txt.zst") catch {};

    const serve = struct {
        fn go(ae: []const u8, br: bool, zstd: bool, gz: bool) ![]const u8 {
            var req = Request.init(testing.allocator);
            defer req.deinit();
            req.decoded_target = "hello.txt";
            _ = req.addHeaderParsed("Accept-Encoding", ae) catch unreachable;
            var resp = Response.init(.ok);
            var ctx = Context{ .req = &req, .resp = &resp };
            ctx.route = &.{ .path = "/", .root = "testdata", .precompressed = gz, .precompressed_br = br, .precompressed_zstd = zstd };
            const a = try run(&ctx);
            try testing.expectEqual(Action.handled, a);
            for (resp.headers[0..resp.header_count]) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) return h.value;
            }
            return "none";
        }
    }.go;
    try makeTwin("testdata/hello.txt", "testdata/hello.txt.gz");
    defer sys.deleteFile("testdata/hello.txt.gz") catch {};
    // Best-first: br wins when accepted + enabled, even with gzip listed first.
    try testing.expectEqualStrings("br", try serve("gzip, br", true, false, true));
    try testing.expectEqualStrings("zstd", try serve("gzip, zstd", false, true, true));
    try testing.expectEqualStrings("gzip", try serve("gzip, br", false, false, true));
    // Enabled but not accepted: falls through to the next codec.
    try testing.expectEqualStrings("gzip", try serve("gzip", true, true, true));
}

test "disabled codecs never serve even when accepted" {
    try sys.writeFile("testdata/hello.txt.br", "fake-br-payload");
    defer sys.deleteFile("testdata/hello.txt.br") catch {};
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    _ = req.addHeaderParsed("Accept-Encoding", "br") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata" };
    try testing.expectEqual(Action.pass, try run(&ctx));
}
