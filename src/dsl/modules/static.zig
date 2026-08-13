const std = @import("std");
const posix = std.posix;
const registry = @import("../registry.zig");
const cache_mod = @import("cache.zig");
const mime = @import("../../http/mime.zig");
const parser = @import("../../http/parser.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Static file serving (Milestone 10). Bound to the `content` phase. Two
/// paths:
/// - **Disk** (runtime config): `root` (+ optional `index` file, `autoindex`)
///   on the route. The decoded request target is resolved against the root;
///   `..` segments and symlink escapes are blocked; files are stat'ed for
///   ETag (`"mtime-size"`), Last-Modified, Content-Type (M6 MIME table) and
///   Content-Length; single ranges yield 206, unsatisfiable ones 416,
///   multi-range requests fall back to the full 200; conditional requests
///   (If-None-Match / If-Modified-Since) yield 304.
/// - **Comptime embedded** (struct-literal configs): a route `embed` path is
///   baked into .rodata at compile time (`@embedFile`) and served with zero
///   disk I/O and an effective infinite cache lifetime.
pub const static = registry.Module{
    .name = "static",
    .phase = .content,
    .run = run,
};

const max_path = std.fs.max_path_bytes;
const Stat = std.fs.File.Stat;

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.embed != null) return serveEmbedded(ctx, route);
    if (route.root == null) return .pass;
    return serveDisk(ctx, route);
}

// ---- Comptime embedded path ----

fn serveEmbedded(ctx: *Context, route: *const registry.Route) !Action {
    const bytes = route.embed_bytes;
    var resp = ctx.resp;
    resp.status = .ok;
    resp.body = bytes; // .rodata: never owned, never freed
    resp.setHeader("Content-Type", mime.mimeForPath(route.embed.?));
    // The embedded file cannot change: effectively infinite cache lifetime.
    resp.setHeader("Cache-Control", "public, max-age=31536000");
    resp.setHeader("Accept-Ranges", "bytes");

    // Stable entity tag from the content itself.
    var etag_buf: [32]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"{x}\"", .{contentHash(bytes)}) catch "";
    resp.setHeaderFmt("ETag", "{s}", .{etag});
    ctx.etag = etag;
    return .handled;
}

/// FNV-1a of the content, hex-encoded (embedded ETag base).
fn contentHash(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ---- Disk path ----

const Meta = struct {
    size: u64,
    mtime_secs: u64,
    is_dir: bool,
};

fn serveDisk(ctx: *Context, route: *const registry.Route) !Action {
    // Strip the route prefix: "/static/hello.txt" on a "/static" route
    // resolves to root + "/hello.txt".
    var target = ctx.req.decoded_target;
    if (std.mem.startsWith(u8, target, route.path)) {
        target = target[route.path.len..];
    }
    if (!pathIsSafe(target)) {
        return notFound(ctx);
    }

    // JSON configs carry a root fd: resolve against it with
    // openat2(RESOLVE_BENEATH) — one syscall, kernel-enforced containment
    // (no per-request open + realpath pair, no TOCTOU). Comptime routes and
    // openat2-less environments fall back to the stack-path + realpath
    // check (serveDiskLegacy).
    if (route.root_fd >= 0) {
        return serveDiskBeneath(ctx, route, target);
    }

    return serveDiskLegacy(ctx, route, target);
}

fn serveDiskLegacy(ctx: *Context, route: *const registry.Route, target: []const u8) !Action {
    const root = route.root orelse return .pass;
    // Resolved path on the stack (no per-request allocation, nginx-style).
    var full_buf: [max_path]u8 = undefined;
    const used = buildFullPath(&full_buf, root, target) orelse return notFound(ctx);
    const full = full_buf[0..used];

    // The resolved root realpath anchors the symlink-escape check. JSON
    // configs precompute it at load (route.root_real); comptime routes fall
    // back to a per-request realpath.
    var root_real_buf: [max_path]u8 = undefined;
    const root_real = if (route.root_real) |rr|
        rr
    else
        std.fs.cwd().realpath(root, &root_real_buf) catch return notFound(ctx);

    const meta = statPath(full) catch {
        return notFound(ctx);
    };

    if (meta.is_dir) {
        // Directory: serve the configured index file, else autoindex.
        if (route.index) |index_file| {
            var idx_buf: [max_path]u8 = undefined;
            const idx_used = buildFullPath(&idx_buf, full, index_file) orelse return notFound(ctx);
            const idx_path = idx_buf[0..idx_used];
            const idx_meta = statPath(idx_path) catch {
                return if (route.autoindex) autoindexPath(ctx, full) else notFound(ctx);
            };
            if (idx_meta.is_dir) {
                return if (route.autoindex) autoindexPath(ctx, full) else notFound(ctx);
            }
            return serveFile(ctx, idx_path, idx_meta, root_real);
        }
        if (route.autoindex) return autoindexPath(ctx, full);
        return notFound(ctx);
    }

    return serveFile(ctx, full, meta, root_real);
}

/// root + "/" + target into `buf`; null when it would not fit.
fn buildFullPath(buf: []u8, root: []const u8, target: []const u8) ?usize {
    if (root.len + 1 + target.len > buf.len) return null;
    @memcpy(buf[0..root.len], root);
    var used = root.len;
    if (target.len > 0) {
        if (used == 0 or buf[used - 1] != '/') {
            buf[used] = '/';
            used += 1;
        }
        @memcpy(buf[used .. used + target.len], target);
        used += target.len;
    }
    return used;
}

// ---- openat2(RESOLVE_BENEATH) fast path (JSON configs) ----

const linux = std.os.linux;
const SYS_openat2 = linux.SYS.openat2;
const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_BENEATH: u64 = 0x08;
const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

/// Open `path` (relative, no leading slash) against `dirfd`, refusing to
/// follow anything that escapes it: ".." segments and symlink escapes are
/// rejected by the kernel. `error.Unsupported` when openat2 is not
/// available (pre-5.6 kernels, seccomp-filtered sandboxes) — callers fall
/// back to the realpath check.
fn openat2Beneath(dirfd: posix.fd_t, path: []const u8) error{ Unsupported, NotFound }!posix.fd_t {
    const how = OpenHow{
        .flags = 0, // O_RDONLY
        .mode = 0,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS,
    };
    // openat2 has no length parameter: the path must be NUL-terminated, and
    // request targets are slices into the request buffer (not terminated).
    var path_buf: [max_path + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.NotFound;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const rc = linux.syscall4(SYS_openat2, @intCast(dirfd), @intFromPtr(&path_buf), @intFromPtr(&how), @sizeOf(OpenHow));
    const err = posix.errno(rc);
    return switch (err) {
        .SUCCESS => @intCast(rc),
        .NOSYS, .INVAL => error.Unsupported,
        else => error.NotFound,
    };
}

fn statFd(fd: posix.fd_t) error{ NotFound, AccessDenied, Unexpected }!Meta {
    const st = (std.fs.File{ .handle = fd }).stat() catch |e| switch (e) {
        error.AccessDenied => return error.AccessDenied,
        else => return error.Unexpected,
    };
    return .{
        .size = st.size,
        .mtime_secs = @intCast(@max(0, @divTrunc(st.mtime.nanoseconds, std.time.ns_per_s))),
        .is_dir = st.kind == .directory,
    };
}

fn serveDiskBeneath(ctx: *Context, route: *const registry.Route, target: []const u8) !Action {
    var rel = target;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) rel = ".";

    // openat2 unavailable (old kernel / sandbox): fall back to the legacy
    // realpath path for this request.
    const fd = openat2Beneath(route.root_fd, rel) catch |e| switch (e) {
        error.Unsupported => return serveDiskLegacy(ctx, route, target),
        error.NotFound => return notFound(ctx),
    };
    const meta = statFd(fd) catch |e| {
        std.debug.print("beneath: statFd failed {}\n", .{e});
        posix.close(fd);
        return notFound(ctx);
    };

    if (meta.is_dir) {
        // Directory: serve the configured index file, else autoindex.
        if (route.index) |index_file| {
            var idx_buf: [max_path]u8 = undefined;
            const idx_rel = buildRelPath(&idx_buf, rel, index_file) orelse {
                posix.close(fd);
                return notFound(ctx);
            };
            const idx_fd = openat2Beneath(route.root_fd, idx_buf[0..idx_rel]) catch {
                posix.close(fd);
                return if (route.autoindex) autoindex(ctx, fd, rel) else notFound(ctx);
            };
            const idx_meta = statFd(idx_fd) catch {
                posix.close(fd);
                posix.close(idx_fd);
                return notFound(ctx);
            };
            if (idx_meta.is_dir) {
                posix.close(idx_fd);
                return if (route.autoindex) autoindex(ctx, fd, rel) else notFound(ctx);
            }
            posix.close(fd);
            return serveFd(ctx, idx_fd, idx_meta, idx_buf[0..idx_rel]);
        }
        if (route.autoindex) return autoindex(ctx, fd, rel);
        posix.close(fd);
        return notFound(ctx);
    }

    return serveFd(ctx, fd, meta, rel);
}

/// rel + "/" + sub into `buf`; null when it would not fit.
fn buildRelPath(buf: []u8, rel: []const u8, sub: []const u8) ?usize {
    if (rel.len + 1 + sub.len > buf.len) return null;
    @memcpy(buf[0..rel.len], rel);
    var used = rel.len;
    if (used == 0 or buf[used - 1] != '/') {
        buf[used] = '/';
        used += 1;
    }
    @memcpy(buf[used .. used + sub.len], sub);
    return used + sub.len;
}

/// Block `..` segments (run on the percent-decoded target) and NUL bytes.
fn pathIsSafe(target: []const u8) bool {
    if (std.mem.indexOfScalar(u8, target, 0) != null) return false;
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn statPath(path: []const u8) error{ NotFound, AccessDenied, Unexpected }!Meta {
    var meta: Stat = undefined;
    if (std.fs.cwd().statFile(path)) |st| {
        meta = st;
    } else |e| switch (e) {
        error.FileNotFound, error.NotDir => return error.NotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return error.Unexpected,
    }
    return .{
        .size = meta.size,
        .mtime_secs = @intCast(@max(0, @divTrunc(meta.mtime.nanoseconds, std.time.ns_per_s))),
        .is_dir = meta.kind == .directory,
    };
}

/// Symlink escape check: the fully-resolved file must live under the route
/// root (compared as realpaths).
fn realpathWithinRoot(path: []const u8, root_real: []const u8) bool {
    var file_buf: [max_path]u8 = undefined;
    const file_real = std.fs.cwd().realpath(path, &file_buf) catch return false;
    if (file_real.len < root_real.len) return false;
    if (!std.mem.eql(u8, file_real[0..root_real.len], root_real)) return false;
    // Boundary: the file must be the root itself or directly under it.
    return file_real.len == root_real.len or file_real[root_real.len] == '/';
}

fn serveFile(ctx: *Context, path: []const u8, meta: Meta, root_real: []const u8) !Action {
    if (!realpathWithinRoot(path, root_real)) return notFound(ctx);
    const file = std.fs.cwd().openFile(path, .{}) catch return notFound(ctx);
    return serveFd(ctx, file.handle, meta, path);
}

/// Shared file-response logic (conditional GETs, ranges, sendfile handoff).
/// Takes ownership of `fd`: closes it on early returns, transfers it to the
/// response on success.
fn serveFd(ctx: *Context, fd: posix.fd_t, meta: Meta, mime_path: []const u8) !Action {
    var resp = ctx.resp;
    var transferred = false;
    defer if (!transferred) posix.close(fd);

    // Entity metadata for the conditional-GET / cache machinery.
    var scratch: [160]u8 = undefined;
    const etag = std.fmt.bufPrint(&scratch, "\"{d}-{d}\"", .{ meta.mtime_secs, meta.size }) catch return error.InternalError;
    ctx.etag = etag;
    const lm = cache_mod.formatHttpDate(meta.mtime_secs, scratch[etag.len..]) orelse return error.InternalError;
    ctx.last_modified = lm;

    // Conditional requests: 304 when the client's copy is current.
    if (ctx.req.header("if-none-match")) |inm| {
        if (cache_mod.etagMatches(inm, etag)) return notModified(ctx);
    }
    if (ctx.req.header("if-modified-since")) |ims| {
        const since = cache_mod.parseHttpDate(ims) orelse return .pass;
        if (meta.mtime_secs <= since) return notModified(ctx);
    }

    resp.status = .ok;
    resp.setHeader("Content-Type", mime.mimeForPath(mime_path));
    resp.setHeaderFmt("ETag", "{s}", .{etag});
    resp.setHeaderFmt("Last-Modified", "{s}", .{lm});
    resp.setHeader("Accept-Ranges", "bytes");

    // Range requests: single satisfiable range -> 206, multiple -> full 200,
    // valid-but-unsatisfiable -> 416.
    var offset: u64 = 0;
    var length: u64 = meta.size;
    if (ctx.req.header("range")) |range_value| {
        switch (parseRange(range_value, meta.size)) {
            .full => {},
            .unsatisfiable => {
                resp.status = .range_not_satisfiable;
                resp.body = registry.Status.range_not_satisfiable.reasonPhrase();
                resp.setHeaderFmt("Content-Range", "bytes */{d}", .{meta.size});
                return .handled;
            },
            .single => |r| {
                offset = r.offset;
                length = r.length;
                resp.status = .partial_content;
                resp.setHeaderFmt("Content-Range", "bytes {d}-{d}/{d}", .{ offset, offset + length - 1, meta.size });
            },
        }
    }

    // Milestone 14: push the body from the file straight into the socket.
    // sendfile for every size (like nginx): one kernel copy, no userspace
    // buffer, no per-request allocation. The reactor takes ownership of
    // the fd.
    resp.body_from_file = true;
    resp.file_fd = fd;
    resp.file_offset = offset;
    resp.file_len = length;
    transferred = true;
    return .handled;
}

fn notFound(ctx: *Context) Action {
    ctx.resp.status = .not_found;
    ctx.resp.body = registry.Status.not_found.reasonPhrase();
    return .handled;
}

fn notModified(ctx: *Context) Action {
    ctx.resp.status = .not_modified;
    ctx.resp.body = &.{};
    return .handled;
}

/// Minimal HTML directory listing (autoindex). Takes the open directory fd
/// (path-based callers open it first); the caller keeps ownership.
fn autoindex(ctx: *Context, dir_fd: posix.fd_t, display_target: []const u8) !Action {
    var dir = std.fs.Dir{ .fd = dir_fd };

    var out = std.ArrayList(u8).empty;
    const allocator = ctx.allocator orelse return .pass;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "<html><head><title>Index of ");
    try out.appendSlice(allocator, display_target);
    try out.appendSlice(allocator, "</title></head><body><ul>");

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ entry.name, if (entry.kind == .directory) "/" else "" }) catch continue;
        try out.appendSlice(allocator, "<li><a href=\"");
        try out.appendSlice(allocator, display_target);
        if (display_target.len == 0 or display_target[display_target.len - 1] != '/') {
            try out.append(allocator, '/');
        }
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "\">");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "</a></li>");
    }
    try out.appendSlice(allocator, "</ul></body></html>");

    ctx.resp.status = .ok;
    ctx.resp.body = try out.toOwnedSlice(allocator);
    ctx.resp.body_owned = true;
    ctx.resp.setHeader("Content-Type", "text/html");
    return .handled;
}

/// Path-based autoindex (comptime-route fallback): open the dir, delegate,
/// close.
fn autoindexPath(ctx: *Context, dir_path: []const u8) !Action {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return notFound(ctx);
    defer dir.close();
    return autoindex(ctx, dir.fd, ctx.req.decoded_target);
}

// ---- Range parsing (RFC 9110 §14.2) ----

const Range = union(enum) {
    /// No range or a syntactically invalid / multi-range header: serve the
    /// full 200 response (multipart ranges are deferred).
    full,
    /// A valid but unsatisfiable range: 416.
    unsatisfiable,
    single: struct { offset: u64, length: u64 },
};

fn parseRange(value: []const u8, size: u64) Range {
    const bytes_prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, bytes_prefix)) return .full;
    const spec = value[bytes_prefix.len..];
    // Multiple ranges -> full 200 (multipart deferred).
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .full;

    var i: usize = 0;
    while (i < spec.len and spec[i] == ' ') i += 1;
    if (i >= spec.len) return .full;

    if (spec[i] == '-') {
        // Suffix range: last N bytes.
        const n = parseDigits(spec[i + 1 ..]) orelse return .full;
        if (n == 0) return .unsatisfiable;
        if (n >= size) return .{ .single = .{ .offset = 0, .length = size } };
        return .{ .single = .{ .offset = size - n, .length = n } };
    }

    const lo = parseDigits(spec[i..]) orelse return .full;
    var j = i;
    while (j < spec.len and std.ascii.isDigit(spec[j])) j += 1;
    if (j >= spec.len or spec[j] != '-') return .full;
    if (j + 1 >= spec.len) {
        // "bytes=N-": from N to the end.
        if (lo >= size) return .unsatisfiable;
        return .{ .single = .{ .offset = lo, .length = size - lo } };
    }
    const hi = parseDigits(spec[j + 1 ..]) orelse return .full;
    if (hi < lo) return .unsatisfiable;
    if (lo >= size) return .unsatisfiable;
    const end = @min(hi, size - 1);
    return .{ .single = .{ .offset = lo, .length = end - lo + 1 } };
}

fn parseDigits(s: []const u8) ?u64 {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) break;
        if (v > (std.math.maxInt(u64) - 9) / 10) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

const testing = std.testing;

test "path safety blocks traversal" {
    try testing.expect(pathIsSafe("/a/b/c.txt"));
    try testing.expect(pathIsSafe("/"));
    try testing.expect(!pathIsSafe("/../etc/passwd"));
    try testing.expect(!pathIsSafe("/a/../b"));
    try testing.expect(!pathIsSafe("/a/.."));
    // Decoded form: %2f becomes '/' before this check runs.
    try testing.expect(!pathIsSafe("/../../.."));
}

test "range parsing" {
    const cases = [_]struct { value: []const u8, size: u64, want: Range }{
        .{ .value = "bytes=0-4", .size = 10, .want = .{ .single = .{ .offset = 0, .length = 5 } } },
        .{ .value = "bytes=5-", .size = 10, .want = .{ .single = .{ .offset = 5, .length = 5 } } },
        .{ .value = "bytes=-3", .size = 10, .want = .{ .single = .{ .offset = 7, .length = 3 } } },
        .{ .value = "bytes=-20", .size = 10, .want = .{ .single = .{ .offset = 0, .length = 10 } } },
        .{ .value = "bytes=20-", .size = 10, .want = .unsatisfiable },
        .{ .value = "bytes=8-2", .size = 10, .want = .unsatisfiable },
        .{ .value = "bytes=-0", .size = 10, .want = .unsatisfiable },
        .{ .value = "bytes=3-99", .size = 10, .want = .{ .single = .{ .offset = 3, .length = 7 } } },
        .{ .value = "bytes=0-0", .size = 10, .want = .{ .single = .{ .offset = 0, .length = 1 } } },
        .{ .value = "bytes=1-2,4-5", .size = 10, .want = .full },
        .{ .value = "bytes=garbage", .size = 10, .want = .full },
        .{ .value = "items=0-5", .size = 10, .want = .full },
        .{ .value = "bytes=", .size = 10, .want = .full },
    };
    for (cases) |c| {
        const got = parseRange(c.value, c.size);
        switch (got) {
            .single => |r| {
                switch (c.want) {
                    .single => |w| {
                        try testing.expectEqual(w.offset, r.offset);
                        try testing.expectEqual(w.length, r.length);
                    },
                    else => try testing.expect(false),
                }
            },
            else => try testing.expectEqual(c.want, got),
        }
    }
}

// ---- Serving tests (run from the repository root, like `zig build test`) ----

fn staticRequest(allocator: std.mem.Allocator, wire: []const u8) !struct { req: registry.Request, parser: parser.Parser, buf: *@import("../../net/buffer.zig").Buffer } {
    var req = registry.Request.init(allocator);
    var p = parser.Parser.init(allocator);
    const buffer_mod = @import("../../net/buffer.zig");
    var buf = try buffer_mod.Buffer.init(allocator);
    _ = buf.writeSlice(wire);
    try testing.expectEqual(parser.Outcome.complete, p.parse(buf, &req));
    return .{ .req = req, .parser = p, .buf = buf };
}

const Served = struct {
    req: registry.Request,
    parser: parser.Parser,
    buf: *@import("../../net/buffer.zig").Buffer,
    resp: registry.Response,
    allocator: std.mem.Allocator,

    fn deinit(s: *Served) void {
        s.req.deinit();
        s.parser.deinit();
        s.buf.deinit(s.allocator);
        if (s.resp.body_owned) s.allocator.free(s.resp.body);
    }
};

fn serveWith(allocator: std.mem.Allocator, wire: []const u8, route: *const registry.Route) !Served {
    var st = try staticRequest(allocator, wire);
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &st.req, .resp = &resp, .allocator = allocator, .route = route };
    _ = try run(&ctx);
    return .{ .req = st.req, .parser = st.parser, .buf = st.buf, .resp = resp, .allocator = allocator };
}

fn headerValue(resp: *const registry.Response, comptime name: []const u8) ?[]const u8 {
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.value;
    }
    return null;
}

test "serves a disk file byte-identical with correct headers" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata" };
    var served = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer served.deinit();

    try testing.expectEqual(registry.Status.ok, served.resp.status);
    // sendfile path: the body stays in the file; the reactor pushes it.
    try testing.expectEqual(@as(usize, 19), served.resp.file_len);
    try testing.expectEqual(@as(usize, 0), served.resp.file_offset);
    try testing.expect(served.resp.body_from_file);
    try testing.expectEqualStrings("text/plain", headerValue(&served.resp, "Content-Type").?);
    try testing.expectEqualStrings("bytes", headerValue(&served.resp, "Accept-Ranges").?);
    try testing.expect(headerValue(&served.resp, "ETag") != null);
    try testing.expect(headerValue(&served.resp, "Last-Modified") != null);
}

test "serves the index file for a directory" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata", .index = "index.html" };
    var served = try serveWith(allocator, "GET /dir/ HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer served.deinit();
    try testing.expectEqual(registry.Status.ok, served.resp.status);
    try testing.expectEqual(@as(usize, 14), served.resp.file_len);
    try testing.expect(served.resp.body_from_file);
    try testing.expectEqualStrings("text/html", headerValue(&served.resp, "Content-Type").?);
    posix.close(served.resp.file_fd);
}

test "single range yields 206 with the right slice and Content-Range" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata" };
    var served = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\n\r\n", &route);
    defer served.deinit();
    try testing.expectEqual(registry.Status.partial_content, served.resp.status);
    try testing.expectEqual(@as(usize, 0), served.resp.file_offset);
    try testing.expectEqual(@as(usize, 5), served.resp.file_len);
    try testing.expectEqualStrings("bytes 0-4/19", headerValue(&served.resp, "Content-Range").?);
    posix.close(served.resp.file_fd);

    var suffix = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=-5\r\n\r\n", &route);
    defer suffix.deinit();
    try testing.expectEqual(registry.Status.partial_content, suffix.resp.status);
    try testing.expectEqual(@as(usize, 14), suffix.resp.file_offset);
    try testing.expectEqual(@as(usize, 5), suffix.resp.file_len);
    posix.close(suffix.resp.file_fd);
}

test "unsatisfiable range yields 416 with Content-Range" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata" };
    var served = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=999-\r\n\r\n", &route);
    defer served.deinit();
    try testing.expectEqual(registry.Status.range_not_satisfiable, served.resp.status);
    try testing.expectEqualStrings("bytes */19", headerValue(&served.resp, "Content-Range").?);
}

test "conditional GET yields 304 on a matching If-None-Match" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata" };
    // First: learn the ETag from a normal request.
    var first = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    const etag = headerValue(&first.resp, "ETag").?;
    try testing.expect(first.resp.body_from_file);
    posix.close(first.resp.file_fd);

    var wire_buf: [256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-None-Match: {s}\r\n\r\n", .{etag}) catch unreachable;
    var second = try serveWith(allocator, wire, &route);
    defer second.deinit();
    try testing.expectEqual(registry.Status.not_modified, second.resp.status);
    try testing.expectEqual(@as(usize, 0), second.resp.body.len);

    defer first.deinit();
}

test "traversal and missing files yield 404" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/", .root = "testdata" };
    var trav = try serveWith(allocator, "GET /../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer trav.deinit();
    try testing.expectEqual(registry.Status.not_found, trav.resp.status);

    var missing = try serveWith(allocator, "GET /nope.txt HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer missing.deinit();
    try testing.expectEqual(registry.Status.not_found, missing.resp.status);
}

test "embedded asset serves byte-identical content with infinite cache" {
    const allocator = testing.allocator;
    const route = registry.Route{ .path = "/robots.txt", .embed = "testdata/hello.txt", .embed_bytes = @import("embeds").embed("testdata/hello.txt") };
    var served = try serveWith(allocator, "GET /robots.txt HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer served.deinit();
    try testing.expectEqual(registry.Status.ok, served.resp.status);
    // Byte-identical to the disk file.
    try testing.expectEqualStrings(@import("embeds").embed("testdata/hello.txt"), served.resp.body);
    try testing.expectEqualStrings("public, max-age=31536000", headerValue(&served.resp, "Cache-Control").?);
    try testing.expect(!served.resp.body_owned);
}

test "openat2 fast path serves beneath the root fd and blocks symlink escapes" {
    const allocator = testing.allocator;
    var dir = std.fs.cwd().openDir("testdata", .{}) catch return error.SkipZigTest;
    defer dir.close();
    const route = registry.Route{
        .path = "/",
        .root = "testdata",
        .root_real = "testdata",
        .root_fd = dir.fd,
    };

    // The fast path needs openat2; skip in environments that block it
    // (pre-5.6 kernels, seccomp-filtered test sandboxes).
    const probe = openat2Beneath(dir.fd, "hello.txt") catch |e| switch (e) {
        error.Unsupported => return error.SkipZigTest,
        error.NotFound => return error.SkipZigTest,
    };
    posix.close(probe);

    var served = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer served.deinit();
    try testing.expectEqual(registry.Status.ok, served.resp.status);
    try testing.expectEqual(@as(usize, 19), served.resp.file_len);
    try testing.expect(served.resp.body_from_file);
    try testing.expectEqualStrings("text/plain", headerValue(&served.resp, "Content-Type").?);
    posix.close(served.resp.file_fd);

    // A symlink inside the root pointing outside must be refused by the
    // kernel (RESOLVE_BENEATH), same as the legacy realpath check.
    const link_path = "testdata/link-escape-tmp";
    std.fs.cwd().symLink("/etc/hostname", link_path, .{}) catch return error.SkipZigTest;
    defer std.fs.cwd().deleteFile(link_path) catch {};
    var escaped = try serveWith(allocator, "GET /link-escape-tmp HTTP/1.1\r\nHost: x\r\n\r\n", &route);
    defer escaped.deinit();
    try testing.expectEqual(registry.Status.not_found, escaped.resp.status);

    // Range through the fast path still slices.
    var ranged = try serveWith(allocator, "GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\n\r\n", &route);
    defer ranged.deinit();
    try testing.expectEqual(registry.Status.partial_content, ranged.resp.status);
    try testing.expectEqual(@as(usize, 0), ranged.resp.file_offset);
    try testing.expectEqual(@as(usize, 5), ranged.resp.file_len);
    posix.close(ranged.resp.file_fd);
}
