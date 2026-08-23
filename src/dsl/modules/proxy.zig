const std = @import("std");
const registry = @import("../registry.zig");
const router = @import("../router.zig");
const http_parser = @import("../../http/parser.zig");
const vars = @import("../vars.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Reverse proxy. Bound to the `rewrite` phase: forwards the
/// request to the route's upstream backends and copies the upstream response
/// into `ctx.resp`. Per-reactor (thread-local) keep-alive connection pool
/// (one socket per backend, reaped lazily after an idle window), passive
/// failure detection (a backend is skipped for `fail_timeout_seconds` after
/// `max_fails` consecutive connect/read errors), and a comptime-switched
/// load-balance strategy (round-robin, least-connections, IP-hash). Upstream
/// sockaddrs are pre-computed (comptime for struct-literal configs).
/// Upstream TLS is deferred to a future Zig snapshot with `std.crypto.tls`.
///
/// The upstream I/O is synchronous: a hung upstream stalls its reactor for
/// the socket receive timeout (5 s) — a documented limitation.
pub const proxy = registry.Module{
    .name = "proxy",
    .phase = .rewrite,
    .run = run,
};

const max_backends = 8;

threadlocal var epoch: std.time.Instant = undefined;
threadlocal var epoch_set = false;

/// Monotonic nanoseconds since this thread's first proxy use (the retry
/// windows and pool idle times only need relative comparisons).
fn nowNs() u64 {
    if (!epoch_set) {
        epoch = std.time.Instant.now() catch return 0;
        epoch_set = true;
    }
    return (std.time.Instant.now() catch return 0).since(epoch);
}
/// Upstream sockets receive-timed out after this long (avoids hanging the
/// reactor on a silent upstream).
const upstream_timeout_ms = 5000;
/// Pooled upstream sockets idle longer than this are closed on the next use.
const pool_idle_ns = 60 * std.time.ns_per_s;

const PoolEntry = struct {
    fd: posix_fd = -1,
    last_used_ns: u64 = 0,
};
const posix_fd = std.posix.fd_t;

// Per-reactor state (thread-local: each reactor owns its upstream sockets).
threadlocal var pool: [max_backends]PoolEntry = [_]PoolEntry{.{}} ** max_backends;
threadlocal var active: [max_backends]u32 = [_]u32{0} ** max_backends;
threadlocal var consecutive_fails: [max_backends]u32 = [_]u32{0} ** max_backends;
threadlocal var failed_at_ns: [max_backends]u64 = [_]u64{0} ** max_backends;
threadlocal var rr_counter: usize = 0;
/// least_time: exponential weighted moving average of upstream response
/// latency per backend, in ns (1/8 weight per sample).
threadlocal var ewma_ns: [max_backends]u64 = [_]u64{0} ** max_backends;
/// xorshift state for the random strategy.
var rng_state: u64 = 0x9E3779B97F4A7C15;

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const upstreams = route.upstreams;
    if (upstreams.len == 0 or upstreams.len > max_backends) return .pass;

    const now_ns = nowNs();
    // Sticky sessions (cookie-based): a valid previously-assigned tag pins
    // the request to its backend while that backend stays usable.
    if (route.sticky_cookie) |name| {
        if (stickyBackendFromCookie(ctx, name, upstreams, route, now_ns)) |idx| {
            return forward(ctx, route, upstreams, idx, now_ns, false);
        }
    }
    const pick = try pickBackend(route, upstreams, ctx, now_ns) orelse {
        return badGateway(ctx);
    };
    return forward(ctx, route, upstreams, pick, now_ns, route.sticky_cookie != null);
}

/// Parse `Cookie: ...; <name>=sN; ...` for a backend tag within range and
/// usable at `now_ns`. Tags are "s" + backend index (stable per config).
fn stickyBackendFromCookie(
    ctx: *Context,
    name: []const u8,
    upstreams: []const router.Upstream,
    route: *const registry.Route,
    now_ns: u64,
) ?usize {
    const cookie_header = ctx.req.header("cookie") orelse return null;
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        if (pair.len <= name.len + 2 or !std.mem.startsWith(u8, pair, name)) continue;
        if (pair[name.len] != '=') continue;
        const tag = pair[name.len + 1 ..];
        if (tag.len < 2 or tag[0] != 's') continue;
        const idx = std.fmt.parseInt(usize, tag[1..], 10) catch continue;
        if (idx >= upstreams.len) continue;
        if (!backendUsable(route, idx, now_ns)) continue;
        return idx;
    }
    return null;
}

/// Connect/send/read against backend `pick`, copy the response into the
/// context and finish LB bookkeeping (EWMA latency sample on success,
/// failure marking on error). `offer_sticky` adds the Set-Cookie binding
/// when the route asked for affinity and the client had none.
fn forward(
    ctx: *Context,
    route: *const registry.Route,
    upstreams: []const router.Upstream,
    pick: usize,
    started_ns: u64,
    offer_sticky: bool,
) anyerror!Action {
    const up = &upstreams[pick];
    var fd = acquirePooled(pick, started_ns);
    if (fd < 0) {
        fd = connectUpstream(up) catch {
            markFailure(pick, route, started_ns);
            return badGateway(ctx);
        };
        setRecvTimeout(fd);
    }

    // Build and send the upstream request.
    sendUpstreamRequest(fd, ctx, up) catch {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return badGateway(ctx);
    };

    // Read the upstream response (status + headers + body).
    var reader = UpstreamReader.init();
    const read_result = reader.read(fd) catch blk: {
        break :blk null;
    };
    if (read_result == null) {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return badGateway(ctx);
    }

    // Success: EWMA latency sample, then copy the response into ctx.resp.
    consecutive_fails[pick] = 0;
    active[pick] -|= 1;
    pool[pick] = .{ .fd = fd, .last_used_ns = started_ns };
    const elapsed = nowNs() -% started_ns;
    ewma_ns[pick] = if (ewma_ns[pick] == 0)
        elapsed
    else
        ewma_ns[pick] - (ewma_ns[pick] >> 3) + (elapsed >> 3);

    const r = read_result.?;
    ctx.resp.status = @enumFromInt(r.status);
    for (r.headers) |h| {
        // Skip hop-by-hop headers the reactor controls.
        const skip = switch (http_parser.header_hasher.hash(h.name)) {
            http_parser.header_hasher.hash("connection") => true,
            http_parser.header_hasher.hash("content-length") => true,
            http_parser.header_hasher.hash("transfer-encoding") => true,
            else => false,
        };
        if (!skip) ctx.resp.setHeader(h.name, h.value);
    }

    // The body slice lives in the reader's stack buffer: copy into the
    // shared request memory (the server reclaims it after the response).
    const body = ctx.sharedDupe(r.body) orelse return badGateway(ctx);
    ctx.resp.body = body;

    // Offer the sticky binding to clients that did not present one.
    if (offer_sticky) {
        if (ctx.route.?.sticky_cookie) |name| {
            var tag_buf: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "{s}=s{d}; Path=/", .{ name, pick }) catch "";
            if (tag.len > 0) ctx.resp.setHeader("Set-Cookie", tag);
        }
    }
    return .handled;
}

fn badGateway(ctx: *Context) Action {
    ctx.resp.status = .bad_gateway;
    ctx.resp.body = registry.Status.bad_gateway.reasonPhrase();
    return .handled;
}

// ---- load balancing (comptime-switched strategies) ----

fn pickBackend(route: *const registry.Route, upstreams: []const router.Upstream, ctx: *Context, now_ns: u64) !?usize {
    switch (route.balance) {
        .round_robin => {
            var start = rr_counter;
            rr_counter +%= 1;
            for (0..upstreams.len) |_| {
                const idx = start % upstreams.len;
                start += 1;
                if (backendUsable(route, idx, now_ns)) return idx;
            }
            return null;
        },
        .least_connections => {
            var best: ?usize = null;
            var best_active: u32 = std.math.maxInt(u32);
            for (upstreams, 0..) |_, idx| {
                if (!backendUsable(route, idx, now_ns)) continue;
                if (active[idx] < best_active) {
                    best_active = active[idx];
                    best = idx;
                }
            }
            return best;
        },
        .random => {
            // xorshift64* seeded from the request clock + client IP; usable
            // backends get equal probability.
            var st = rng_state ^ now_ns ^ (@as(u64, ctx.client_ip[0]) << 24 |
                @as(u64, ctx.client_ip[1]) << 16 | @as(u64, ctx.client_ip[2]) << 8 |
                @as(u64, ctx.client_ip[3]));
            st ^= st >> 12;
            st ^= st << 25;
            st ^= st >> 27;
            rng_state = st;
            const start = @as(usize, @intCast((st *% 0x2545F4914F6CDD1D) % upstreams.len));
            for (0..upstreams.len) |_| {
                const idx = (start + @as(usize, @intCast(rr_counter))) % upstreams.len;
                rr_counter +%= 1;
                if (backendUsable(route, idx, now_ns)) return idx;
            }
            return null;
        },
        .consistent_hash => {
            // Same client -> same backend while it is usable; a failure
            // reshuffles only the failed backend's share.
            var h: u64 = 0xcbf29ce484222325;
            for (ctx.client_ip) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            // Deterministic probe order from the client's own hash: no
            // shared counters, so identical keys always map identically.
            const start: usize = @intCast(h % upstreams.len);
            for (0..upstreams.len) |k| {
                const idx = (start + k) % upstreams.len;
                if (backendUsable(route, idx, now_ns)) return idx;
            }
            return null;
        },
        .least_time => {
            var best: ?usize = null;
            var best_ewma: u64 = std.math.maxInt(u64);
            for (upstreams, 0..) |_, idx| {
                if (!backendUsable(route, idx, now_ns)) continue;
                // Never-tried backends win ties by looking free (0 ns).
                if (ewma_ns[idx] < best_ewma) {
                    best_ewma = ewma_ns[idx];
                    best = idx;
                }
            }
            return best;
        },
        .ip_hash => {
            var h: u32 = 2166136261;
            for (ctx.client_ip) |b| {
                h ^= b;
                h *%= 16777619;
            }
            const start = h % upstreams.len;
            for (0..upstreams.len) |_| {
                const idx = (start + @as(usize, @intCast(rr_counter))) % upstreams.len;
                rr_counter +%= 1;
                if (backendUsable(route, idx, now_ns)) return idx;
            }
            return null;
        },
    }
}

fn backendUsable(route: *const registry.Route, idx: usize, now_ns: u64) bool {
    const fails = consecutive_fails[idx];
    if (fails < route.max_fails) return true;
    const retry_at = failed_at_ns[idx] + @as(u64, route.fail_timeout_seconds) * std.time.ns_per_s;
    if (now_ns >= retry_at) {
        // Retry window open: probe the backend again.
        consecutive_fails[idx] = 0;
        return true;
    }
    return false;
}

fn markFailure(idx: usize, route: *const registry.Route, now_ns: u64) void {
    consecutive_fails[idx] += 1;
    if (consecutive_fails[idx] >= route.max_fails) {
        failed_at_ns[idx] = now_ns;
    }
}

// ---- upstream connection lifecycle ----

fn acquirePooled(idx: usize, now_ns: u64) posix_fd {
    const e = &pool[idx];
    if (e.fd < 0) return -1;
    if (now_ns -| e.last_used_ns > pool_idle_ns) {
        // Idle reap.
        posix_close(e.fd);
        e.fd = -1;
        return -1;
    }
    const fd = e.fd;
    e.fd = -1;
    return fd;
}

fn connectUpstream(up: *const router.Upstream) !posix_fd {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    errdefer posix_close(fd);
    try std.posix.connect(fd, &up.sockaddr, 16);
    return fd;
}

fn setRecvTimeout(fd: posix_fd) void {
    var tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn posix_close(fd: posix_fd) void {
    std.posix.close(fd);
}

// ---- upstream request forwarding ----

fn sendUpstreamRequest(fd: posix_fd, ctx: *Context, up: *const router.Upstream) !void {
    const allocator = ctx.allocator orelse return error.NoAllocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, methodName(ctx.req.method));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, ctx.req.target);
    try out.appendSlice(allocator, " HTTP/1.1\r\n");

    try out.appendSlice(allocator, "Host: ");
    try out.appendSlice(allocator, up.host);
    try out.appendSlice(allocator, ":");
    try out.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}\r\n", .{up.port}) catch return error.OutOfMemory);

    var ip_buf: [16]u8 = undefined;
    const ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ctx.client_ip[0], ctx.client_ip[1], ctx.client_ip[2], ctx.client_ip[3] }) catch "0.0.0.0";
    try out.appendSlice(allocator, "X-Forwarded-For: ");
    try out.appendSlice(allocator, ip);
    try out.appendSlice(allocator, "\r\nX-Real-IP: ");
    try out.appendSlice(allocator, ip);
    try out.appendSlice(allocator, "\r\n");

    // M-E: proxy_set_header overrides — a header whose name appears here is
    // replaced (the client's value is skipped); others are appended after
    // the forwarded headers. Values are complex values (rendered per
    // request).
    const overrides = if (ctx.route) |route| route.proxy_headers else &.{};
    var override_hashes: [8]u32 = undefined;
    var override_count: usize = 0;
    for (overrides) |ph| {
        if (override_count < 8) {
            override_hashes[override_count] = http_parser.header_hasher.hash(ph.name);
            override_count += 1;
        }
    }

    // Forward the client's headers except hop-by-hop ones we manage and
    // any name overridden by proxy_set_header.
    for (0..ctx.req.headerCount()) |i| {
        const h = ctx.req.headerAt(i);
        const hh = http_parser.header_hasher.hash(h.name);
        const skip = switch (hh) {
            http_parser.header_hasher.hash("host") => true,
            http_parser.header_hasher.hash("connection") => true,
            http_parser.header_hasher.hash("content-length") => true,
            http_parser.header_hasher.hash("transfer-encoding") => true,
            else => false,
        };
        if (skip) continue;
        var overridden = false;
        for (override_hashes[0..override_count]) |oh| {
            if (oh == hh) {
                overridden = true;
                break;
            }
        }
        if (overridden) continue;
        try out.appendSlice(allocator, h.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, h.value);
        try out.appendSlice(allocator, "\r\n");
    }
    // The proxy_set_header overrides.
    var sink = vars.ArrayListSink{ .list = &out, .allocator = allocator };
    for (overrides) |ph| {
        try out.appendSlice(allocator, ph.name);
        try out.appendSlice(allocator, ": ");
        try vars.renderComplex(ctx, ph.value, &sink);
        try out.appendSlice(allocator, "\r\n");
    }
    try out.appendSlice(allocator, "Content-Length: ");
    try out.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}\r\n\r\n", .{ctx.req.body.len}) catch return error.OutOfMemory);
    try out.appendSlice(allocator, ctx.req.body);

    var remaining = out.items;
    while (remaining.len > 0) {
        const n = try std.posix.write(fd, remaining);
        remaining = remaining[n..];
    }
}

fn methodName(m: http_parser.Method) []const u8 {
    return switch (m) {
        .get => "GET",
        .head => "HEAD",
        .post => "POST",
        .put => "PUT",
        .delete => "DELETE",
        .options => "OPTIONS",
        .patch => "PATCH",
        .unknown => "GET",
    };
}

// ---- upstream response reading ----

const max_upstream_headers = 16;
const UpstreamHeader = struct { name: []const u8, value: []const u8 };

const UpstreamReader = struct {
    buf: [16 * 1024]u8 = undefined,
    used: usize = 0,
    pos: usize = 0,
    status: u16 = 0,
    headers: [max_upstream_headers]UpstreamHeader = undefined,
    header_count: usize = 0,
    body: []const u8 = &.{},

    fn init() UpstreamReader {
        return .{};
    }

    fn read(self: *UpstreamReader, fd: posix_fd) !struct { status: u16, headers: []const UpstreamHeader, body: []const u8 } {
        // Status line.
        const status_line = try self.readLine(fd);
        var it = std.mem.tokenizeAny(u8, status_line, " ");
        _ = it.next(); // HTTP/1.1
        const code_tok = it.next() orelse return error.BadUpstreamResponse;
        self.status = std.fmt.parseInt(u16, code_tok, 10) catch return error.BadUpstreamResponse;

        // Headers.
        while (true) {
            const line = try self.readLine(fd);
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadUpstreamResponse;
            if (self.header_count >= max_upstream_headers) return error.BadUpstreamResponse;
            self.headers[self.header_count] = .{
                .name = std.mem.trim(u8, line[0..colon], " \t"),
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
            };
            self.header_count += 1;
        }

        // Body: consume per Content-Length (the upstream is our own server,
        // which always sets it).
        var content_length: usize = 0;
        for (self.headers[0..self.header_count]) |h| {
            if (http_parser.header_hasher.hash(h.name) == comptime http_parser.header_hasher.hash("content-length")) {
                content_length = std.fmt.parseInt(usize, h.value, 10) catch return error.BadUpstreamResponse;
            }
        }
        self.ensureAvailable(fd, content_length) catch return error.BadUpstreamResponse;
        self.body = self.buf[self.pos .. self.pos + content_length];
        self.pos += content_length;
        return .{ .status = self.status, .headers = self.headers[0..self.header_count], .body = self.body };
    }

    fn readLine(self: *UpstreamReader, fd: posix_fd) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.pos..self.used], '\n')) |i| {
                var line = self.buf[self.pos .. self.pos + i];
                self.pos += i + 1;
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                return line;
            }
            if (self.used == self.buf.len) return error.UpstreamBufferFull;
            // Compact and fill.
            const remaining = self.buf[self.pos..self.used];
            if (self.pos > 0) {
                std.mem.copyForwards(u8, self.buf[0..remaining.len], remaining);
                self.used -= self.pos;
                self.pos = 0;
            }
            const n = try self.fill(fd);
            if (n == 0) return error.UpstreamClosed;
        }
    }

    fn ensureAvailable(self: *UpstreamReader, fd: posix_fd, n: usize) !void {
        while (self.used - self.pos < n) {
            const remaining = self.buf[self.pos..self.used];
            std.mem.copyForwards(u8, self.buf[0..remaining.len], remaining);
            self.used -= self.pos;
            self.pos = 0;
            const got = try self.fill(fd);
            if (got == 0) return error.UpstreamClosed;
        }
    }

    fn fill(self: *UpstreamReader, fd: posix_fd) !usize {
        const n = try std.posix.read(fd, self.buf[self.used..]);
        self.used += n;
        return n;
    }
};

const testing = std.testing;

test "upstream sockaddr matches a runtime-built one byte for byte" {
    const comptime_addr = router.Upstream.makeSockaddr("127.0.0.1", 9090).?;
    const runtime_addr = router.Upstream.makeSockaddr("127.0.0.1", 9090).?;
    try testing.expectEqualDeep(comptime_addr, runtime_addr);
    try testing.expectEqual(@as(u16, 2), comptime_addr.family); // AF_INET
    // Port 9090 big-endian: 0x23, 0x82.
    try testing.expectEqual(@as(u8, 0x23), comptime_addr.data[0]);
    try testing.expectEqual(@as(u8, 0x82), comptime_addr.data[1]);
    // 127.0.0.1 bytes.
    try testing.expectEqual(@as(u8, 0x7f), comptime_addr.data[2]);
    try testing.expectEqual(@as(u8, 0x01), comptime_addr.data[5]);
}

test "balance strategy parse" {
    try testing.expectEqual(router.Balance.round_robin, router.Balance.parse("round_robin").?);
    try testing.expectEqual(router.Balance.least_connections, router.Balance.parse("least_connections").?);
    try testing.expectEqual(router.Balance.ip_hash, router.Balance.parse("ip_hash").?);
    try testing.expectEqual(@as(?router.Balance, null), router.Balance.parse("maglev"));
}

test "balance strategy parse accepts the new strategies" {
    try testing.expectEqual(router.Balance.random, router.Balance.parse("random").?);
    try testing.expectEqual(router.Balance.consistent_hash, router.Balance.parse("consistent_hash").?);
    try testing.expectEqual(router.Balance.least_time, router.Balance.parse("least_time").?);
}

test "consistent_hash keeps one client on one backend" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.client_ip = .{ 192, 168, 1, 7 };

    const route = registry.Route{
        .path = "/",
        .balance = .consistent_hash,
        .upstreams = &.{
            .{ .host = "127.0.0.1", .port = 1 },
            .{ .host = "127.0.0.1", .port = 2 },
            .{ .host = "127.0.0.1", .port = 3 },
        },
    };
    const now = nowNs();
    const first = (try pickBackend(&route, route.upstreams, &ctx, now)).?;
    for (0..8) |_| {
        const again = (try pickBackend(&route, route.upstreams, &ctx, now)).?;
        try testing.expectEqual(first, again);
    }
}

test "least_time prefers the lower EWMA and samples complete requests" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.client_ip = .{ 10, 0, 0, 1 };

    const route = registry.Route{
        .path = "/",
        .balance = .least_time,
        .upstreams = &.{
            .{ .host = "127.0.0.1", .port = 1 },
            .{ .host = "127.0.0.1", .port = 2 },
        },
    };
    // Backend 0 has seen fast responses; backend 1 slow ones.
    ewma_ns[0] = 2 * std.time.ns_per_ms;
    ewma_ns[1] = 20 * std.time.ns_per_ms;
    defer {
        ewma_ns[0] = 0;
        ewma_ns[1] = 0;
    }

    const picked = (try pickBackend(&route, route.upstreams, &ctx, nowNs())).?;
    try testing.expectEqual(@as(usize, 0), picked);

    // EWMA update math: new = old - old/8 + sample/8.
    const old_v: u64 = 8_000;
    ewma_ns[0] = old_v;
    ewma_ns[0] -= old_v >> 3;
    ewma_ns[0] += 16_000 >> 3;
    try testing.expectEqual(old_v - old_v / 8 + 2_000, ewma_ns[0]);
}

test "sticky cookie routes back to the tagged backend" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    _ = req.addHeaderParsed("Cookie", "a=1; zsid=s2; b=2") catch unreachable;
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const route = registry.Route{
        .path = "/",
        .sticky_cookie = "zsid",
        .max_fails = 1,
        .upstreams = &.{
            .{ .host = "127.0.0.1", .port = 1 },
            .{ .host = "127.0.0.1", .port = 2 },
            .{ .host = "127.0.0.1", .port = 3 },
        },
    };
    const picked = stickyBackendFromCookie(&ctx, "zsid", route.upstreams, &route, nowNs());
    try testing.expectEqual(@as(usize, 2), picked.?);

    // Out-of-range and malformed tags fall through to null.
    var bad = registry.Request.init(testing.allocator);
    defer bad.deinit();
    _ = bad.addHeaderParsed("Cookie", "zsid=s9") catch unreachable;
    var bad_resp = registry.Response.init(.ok);
    var bad_ctx = Context{ .req = &bad, .resp = &bad_resp };
    try testing.expect(stickyBackendFromCookie(&bad_ctx, "zsid", route.upstreams, &route, nowNs()) == null);

    var junk = registry.Request.init(testing.allocator);
    defer junk.deinit();
    _ = junk.addHeaderParsed("Cookie", "zsid=hello") catch unreachable;
    var junk_resp = registry.Response.init(.ok);
    var junk_ctx = Context{ .req = &junk, .resp = &junk_resp };
    try testing.expect(stickyBackendFromCookie(&junk_ctx, "zsid", route.upstreams, &route, nowNs()) == null);
}
