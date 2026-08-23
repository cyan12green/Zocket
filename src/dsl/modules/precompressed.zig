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

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const root = route.root orelse return .pass;
    if (!acceptsGzip(ctx)) return .pass;

    // Path-safety: the same rules the static module applies — decoded
    // target must be relative and free of traversal.
    const target = ctx.req.decoded_target;
    if (target.len == 0 or target[0] == '/') return .pass;
    if (std.mem.indexOf(u8, target, "..") != null) return .pass;
    if (target.len + 3 > 512) return .pass;

    var path_buf: [520]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.gz", .{ root, target }) catch return .pass;

    const file = std.fs.cwd().openFile(path, .{}) catch return .pass; // no twin
    defer file.close();
    const stat = file.stat() catch return .pass;
    if (stat.kind != .file) return .pass;
    if (stat.size > max_buffered) return .pass;

    const bytes = ctx.sharedAlloc(@intCast(stat.size)) orelse return error.OutOfMemory;
    var filled: usize = 0;
    while (filled < bytes.len) {
        const n = file.read(bytes[filled..]) catch return .pass;
        if (n == 0) break;
        filled += n;
    }
    if (filled != bytes.len) return .pass;

    ctx.resp.status = .ok;
    ctx.resp.body = bytes;
    ctx.resp.setHeader("Content-Encoding", "gzip");
    ctx.resp.setHeader("Vary", "Accept-Encoding");
    // Content-Type describes the ORIGINAL representation (strip ".gz").
    ctx.resp.setHeader("Content-Type", mime_mod.mimeForPath(target));
    return .handled;
}

fn acceptsGzip(ctx: *Context) bool {
    const ae = ctx.req.header("accept-encoding") orelse return false;
    var it = std.mem.splitScalar(u8, ae, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t");
        if (std.ascii.startsWithIgnoreCase(tok, "gzip")) return true; // gzip / gzip;q=..
    }
    return false;
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
    defer std.fs.cwd().deleteFile("testdata/hello.txt.gz") catch {};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "hello.txt";
    _ = req.addHeaderParsed("Accept-Encoding", "gzip;q=1.0") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .root = "testdata" };

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
    const raw = try std.fs.cwd().readFileAlloc(src, allocator, .limited(1 << 20));
    defer allocator.free(raw);
    const compressed = try gzip_mod.gzipCompress(allocator, raw);
    defer allocator.free(compressed);
    try std.fs.cwd().writeFile(.{ .sub_path = dst, .data = compressed });
}
