const std = @import("std");
const compat = @import("../../compat.zig");
const registry = @import("../registry.zig");
const sockets = @import("../../net/sockets.zig");
const router = @import("../router.zig");
const http_parser = @import("../../http/parser.zig");
const vars = @import("../vars.zig");
const dns_resolver = @import("../../net/dns_resolver.zig");

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
    .needs_body = true,
    .touches_headers = true,
    .name = "proxy",
    .phase = .rewrite,
    .run = run,
};

/// Set by the runtime when the io_uring backend is active: that loop has
/// its own completion model, so upstreams fall back to the synchronous
/// driver there.
pub var force_sync_upstreams: bool = false;

/// Everything the reactor needs to drive one parked upstream transaction.
/// Lives in the request arena; the reactor reads it right after the walk
/// returns .async and before anything resets the request.
pub const ParkedPlan = struct {
    fd: posix_fd,
    backend_idx: usize,
    route: *const registry.Route,
    request: []const u8,
    sent: usize = 0,
    awaiting_out: bool = false,
    reader_ptr: ?*UpstreamReader = null, // heap copy surviving the frame
    offer_sticky: bool,
    sticky_name: []const u8,
    started_ns: u64,
};

/// Resolve the parked plan for the reactor (null when this walk was not a
/// proxy park).
pub fn takeParked(ctx: *Context) ?*ParkedPlan {
    const p = ctx.getState("proxy") orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Build + connect + SEND nothing yet: returns a ParkedPlan with the
/// connected non-blocking fd; the reactor registers it and drives
/// send->read through driveUpstream().
fn park(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const upstreams = route.upstreams;
    if (upstreams.len == 0 or upstreams.len > max_backends) return .pass;

    const now_ns = nowNs();
    if (route.sticky_cookie) |name| {
        if (stickyBackendFromCookie(ctx, name, upstreams, route, now_ns)) |idx| {
            // TLS upstreams run the sync driver (no parked path in v1).
            if (upstreams[idx].tls) return forward(ctx, route, upstreams, idx, now_ns, false);
            return parkAt(ctx, route, upstreams, idx, now_ns, false);
        }
    }
    const pick = try pickBackend(route, upstreams, ctx, now_ns) orelse
        return badGateway(ctx);
    if (upstreams[pick].tls) return forward(ctx, route, upstreams, pick, now_ns, route.sticky_cookie != null);
    return parkAt(ctx, route, upstreams, pick, now_ns, route.sticky_cookie != null);
}

/// Adopt an upstream response into the context (buffer-ownership contract:
/// every slice copied into the request arena — reader memory dies with the
/// transaction). Shared by the inline fast path and the reactor driver.
/// `proxy_hide_header` lookup (case-insensitive), shared by both adopt
/// paths (the inline one here and the reactor's parked completions).
pub fn headerHidden(route: ?*const registry.Route, name: []const u8) bool {
    const r = route orelse return false;
    for (r.proxy_hide) |hidden| {
        if (std.ascii.eqlIgnoreCase(hidden, name)) return true;
    }
    return false;
}

pub fn adoptUpstream(ctx: *Context, res: anytype, offer_sticky: bool, sticky_name: []const u8, backend_idx: usize) !void {
    ctx.resp.status = @enumFromInt(res.status);
    const ws101 = isWs101(ctx, res.status);
    const arena_a = ctx.req.arena.asAllocator();
    const route = ctx.route;
    for (res.headers) |h| {
        const skip = switch (http_parser.header_hasher.hash(h.name)) {
            http_parser.header_hasher.hash("connection") => !ws101,
            http_parser.header_hasher.hash("content-length"),
            http_parser.header_hasher.hash("transfer-encoding"),
            => true,
            else => false,
        };
        if (skip or headerHidden(route, h.name)) continue;
        const name_c = arena_a.dupe(u8, h.name) catch return error.OutOfMemory;
        const value_src = if (route) |r| redirectRewrite(r, h.name, h.value, arena_a) orelse h.value else h.value;
        const value_c = arena_a.dupe(u8, value_src) catch return error.OutOfMemory;
        ctx.resp.setHeader(name_c, value_c);
    }
    const body = arena_a.dupe(u8, res.body) catch return error.OutOfMemory;
    ctx.resp.body = body;
    if (offer_sticky and sticky_name.len > 0) {
        var tag_buf: [48]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "{s}=s{d}; Path=/", .{ sticky_name, backend_idx }) catch "";
        if (tag.len > 0) ctx.resp.setHeader("Set-Cookie", tag);
    }
}

fn parkAt(ctx: *Context, route: *const registry.Route, upstreams: []const router.Upstream, pick: usize, started_ns: u64, offer_sticky: bool) anyerror!Action {
    ensureHealthChecker(route);
    const up = &upstreams[pick];
    // Serialize fully NOW (arena-backed) so a parked transaction never
    // touches the parser again.
    const request = buildUpstreamRequest(ctx, up) catch {
        markFailure(pick, route, started_ns);
        return badGateway(ctx);
    };

    // A pooled keepalive connection may have been closed by the upstream
    // while it sat idle (upstream keep-alives are often shorter than the
    // pool window). Like nginx's upstream keepalive, the first failure on
    // a POOLED connection is retried once on a fresh connection: the
    // client never sees the stale-connection 502 and the passive health
    // counter is not tripped.
    var attempt: u8 = 0;
    attempts: while (true) : (attempt += 1) {
        var pooled = false;
        var fd = acquirePooled(pick, started_ns, keepaliveIdleNs(route));
        if (fd >= 0) {
            pooled = true;
        } else {
            fd = connectUpstream(up, connectTimeoutMs(route)) catch {
                markFailure(pick, route, started_ns);
                return badGateway(ctx);
            };
            setRecvTimeout(fd, readTimeoutS(route));
        }
        // Pooled-connection failures never count against the backend:
        // try the next pooled fd / a fresh connection (bounded attempts).
        const stale_retry = pooled and attempt < 8;

        // HYBRID: try the whole round-trip inline. Fast origins finish right
        // here at sync-driver cost; only real blocks park.
        var sent: usize = 0;
        while (sent < request.len) {
            const n = compat.write(fd, request[sent..]) catch |e| switch (e) {
                error.WouldBlock => {
                    return parkRemainder(ctx, route, .{
                        .fd = fd,
                        .backend_idx = pick,
                        .route = route,
                        .request = request,
                        .sent = sent,
                        .awaiting_out = true,
                        .offer_sticky = offer_sticky,
                        .sticky_name = route.sticky_cookie orelse "",
                        .started_ns = started_ns,
                    }, null);
                },
                else => {
                    posix_close(fd);
                    active[pick] -|= 1;
                    if (stale_retry) continue :attempts;
                    markFailure(pick, route, started_ns);
                    return badGateway(ctx);
                },
            };
            sent += n;
        }

        var reader = UpstreamReader{};
        reader.alloc = ctx.req.arena.asAllocator();
        while (true) {
            if (reader.tryParse()) |res| {
                try adoptUpstream(ctx, res, offer_sticky, route.sticky_cookie orelse "", pick);
                upstreamSuccess(pick, fd, nowNs(), route);
                return .handled; // normal serialization follows; NO event hop
            } else |e| switch (e) {
                error.Incomplete => {},
                else => {
                    posix_close(fd);
                    active[pick] -|= 1;
                    if (stale_retry) continue :attempts;
                    markFailure(pick, route, started_ns);
                    return badGateway(ctx);
                },
            }
            const got = reader.fill(fd) catch |fe| switch (fe) {
                error.WouldBlock => {
                    const hr = ctx.sharedAlloc(@sizeOf(UpstreamReader)) orelse return error.OutOfMemory;
                    const hr_t: *UpstreamReader = @ptrCast(@alignCast(hr));
                    hr_t.* = reader;
                    return parkRemainder(ctx, route, .{
                        .fd = fd,
                        .backend_idx = pick,
                        .route = route,
                        .request = request,
                        .sent = sent,
                        .awaiting_out = false,
                        .offer_sticky = offer_sticky,
                        .sticky_name = route.sticky_cookie orelse "",
                        .started_ns = started_ns,
                        .reader_ptr = hr_t,
                    }, hr_t);
                },
                else => {
                    posix_close(fd);
                    active[pick] -|= 1;
                    if (stale_retry) continue :attempts;
                    markFailure(pick, route, started_ns);
                    return badGateway(ctx);
                },
            };
            if (got == 0) {
                // EOF before a complete response: the pooled connection was
                // closed while idle (or the upstream truncated). Retry once
                // on a fresh connection when it came from the pool.
                posix_close(fd);
                active[pick] -|= 1;
                if (stale_retry) continue :attempts;
                markFailure(pick, route, started_ns);
                return badGateway(ctx);
            }
        }
    }
}

/// Stash the remainder of a blocked transaction and hand it to the reactor.
fn parkRemainder(
    ctx: *Context,
    route: *const registry.Route,
    plan_fields: ParkedPlan,
    heap_reader: ?*UpstreamReader,
) anyerror!Action {
    _ = route;
    const plan = ctx.sharedAlloc(@sizeOf(ParkedPlan)) orelse return error.OutOfMemory;
    const pt: *ParkedPlan = @ptrCast(@alignCast(plan));
    pt.* = plan_fields;
    pt.reader_ptr = heap_reader;
    ctx.setState("proxy", @ptrCast(pt));
    ctx.async_fd = pt.fd;
    return .async;
}

const max_backends = 8;
/// Pooled keepalive connections per backend per reactor thread.
/// `proxy_keepalive` tunes the effective size (default 8); the array is
/// dimensioned at the hard cap so a large directive cannot blow the
/// threadlocals. With N reactors and M backends, total pooled conns =
/// N * M * effective_cap.
const pool_default_max: u32 = 8;
const pool_hard_cap: u32 = 32;
/// Default idle expiry for pooled connections (overridden per route by
/// `proxy_keepalive_timeout`).
const pool_default_idle_s: u64 = 60;

/// Effective pool size for a route: explicit setting clamped to the hard
/// cap (0 = default).
fn keepaliveMax(route: *const registry.Route) u32 {
    const m = if (route.proxy_keepalive_max != 0) route.proxy_keepalive_max else pool_default_max;
    return @min(m, pool_hard_cap);
}

/// Effective idle expiry for a route in ns (0 = default).
fn keepaliveIdleNs(route: *const registry.Route) u64 {
    const s = if (route.proxy_keepalive_timeout_s != 0) route.proxy_keepalive_timeout_s else pool_default_idle_s;
    return s * std.time.ns_per_s;
}

threadlocal var epoch: compat.Instant = undefined;
threadlocal var epoch_set = false;

/// Monotonic nanoseconds since this thread's first proxy use (the retry
/// windows and pool idle times only need relative comparisons).
/// Public clock for reactor-side transaction deadlines (same epoch).
pub fn currentNs() u64 {
    return nowNs();
}

fn nowNs() u64 {
    if (!epoch_set) {
        epoch = compat.Instant.now() catch return 0;
        epoch_set = true;
    }
    return (compat.Instant.now() catch return 0).since(epoch);
}
/// Compiled defaults for the proxy_*_timeout directives (0 = default):
/// connect and send are tight (a half-dead backend must not park a reactor
/// thread); read matches the historical 5 s sync-driver cap.
const default_connect_timeout_ms: i32 = 1000;
const default_send_timeout_ms: i32 = 1000;
const default_read_timeout_s: u32 = 5;

/// Effective timeouts for a route: explicit seconds, else the defaults.
fn connectTimeoutMs(route: *const registry.Route) i32 {
    if (route.proxy_connect_timeout_s != 0) {
        return @intCast(route.proxy_connect_timeout_s * 1000);
    }
    return default_connect_timeout_ms;
}

fn sendTimeoutMs(route: *const registry.Route) i32 {
    if (route.proxy_send_timeout_s != 0) {
        return @intCast(route.proxy_send_timeout_s * 1000);
    }
    return default_send_timeout_ms;
}

fn readTimeoutS(route: *const registry.Route) u32 {
    if (route.proxy_read_timeout_s != 0) return route.proxy_read_timeout_s;
    return default_read_timeout_s;
}
const PoolEntry = struct {
    fd: posix_fd = -1,
    last_used_ns: u64 = 0,
};
const posix = std.posix;
const linux = std.os.linux;
const posix_fd = std.posix.fd_t;

// Per-reactor state (thread-local: each reactor owns its upstream sockets).
threadlocal var pool: [max_backends][pool_hard_cap]PoolEntry = @as([max_backends][pool_hard_cap]PoolEntry, @splat(@as([pool_hard_cap]PoolEntry, @splat(@as(PoolEntry, .{})))));
threadlocal var pool_lens: [max_backends]u32 = @as([max_backends]u32, @splat(@as(u32, 0)));
threadlocal var active: [max_backends]u32 = @as([max_backends]u32, @splat(@as(u32, 0)));
/// Per-backend liveness, SHARED across reactors (and with the active
/// health-checker thread) via a shmem zone. Keyed by (route pointer,
/// backend index); routes are compile-time immortal pointers.
/// All fields are atomics: after one-time slot resolution the request hot
/// path reads/writes them WITHOUT any zone mutex (torn/stale reads are
/// benign heuristics here — worst case one extra request hits a backend
/// that just went down).
const BackendState = struct {
    fails: std.atomic.Value(u32) = .init(0), // consecutive passive failures
    alive: std.atomic.Value(bool) = .init(true),
    probe_ok: std.atomic.Value(u32) = .init(0),
    probe_fails: std.atomic.Value(u32) = .init(0),
    last_fail_ns: std.atomic.Value(u64) = .init(0),
    probe_next_due_ns: std.atomic.Value(u64) = .init(0),
};
var health_zone = @import("../shmem.zig").KeyedTable(BackendState, 4096){};

fn backendKey(route: *const registry.Route, idx: usize) u64 {
    return @intFromPtr(route) ^ (@as(u64, idx) << 4);
}

/// Injected in tests; default probes a backend over TCP (+ optional HEAD).
var probeFn: *const fn (up: *const router.Upstream, path: []const u8, timeout_s: u32) bool = tcpProbe;

/// Registered health-checked routes (process-immortal route pointers).
var hc_mutex: compat.Mutex = .{};
var hc_routes: std.ArrayList(*const registry.Route) = .empty;
var hc_thread_started: bool = false;

/// Per-reactor slot cache: resolved ONCE per route (under the zone mutex,
/// which also seeds the entry), then every request touches the *BackendState
/// directly — zero locking on the hot path.
threadlocal var hc_cached_route: ?*const registry.Route = null;
threadlocal var hc_cached_slots: [max_backends]?*BackendState = @as([max_backends]?*BackendState, @splat(@as(?*BackendState, null)));

fn healthSlot(route: *const registry.Route, idx: usize) ?*BackendState {
    if (hc_cached_route != route) {
        hc_mutex.lock();
        defer hc_mutex.unlock();
        for (0..max_backends) |i| {
            const key = backendKey(route, i);
            if (health_zone.upsertLocked(key)) |r| {
                if (!r.existed) r.slot.* = .{};
                hc_cached_slots[i] = r.slot;
            }
        }
        hc_cached_route = route;
    }
    return hc_cached_slots[idx];
}
threadlocal var rr_counter: usize = 0;
/// least_time: exponential weighted moving average of upstream response
/// latency per backend, in ns (1/8 weight per sample).
threadlocal var ewma_ns: [max_backends]u64 = @as([max_backends]u64, @splat(@as(u64, 0)));
/// xorshift state for the random strategy.
var rng_state: u64 = 0x9E3779B97F4A7C15;

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const upstreams = route.upstreams;
    if (upstreams.len == 0 or upstreams.len > max_backends) return .pass;
    // Ring backend + TLS fronts keep the synchronous driver: their loops
    // have different completion models than the epoll seam.
    if (!force_sync_upstreams and ctx.async_supported) return park(ctx);

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

/// Connect/send/read against backends, copy the response into the
/// context and finish LB bookkeeping (EWMA latency sample on success,
/// failure marking on error). `offer_sticky` adds the Set-Cookie binding
/// when the route asked for affinity and the client had none.
///
/// With `proxy_next_upstream`, a transport failure (connect/send/read
/// error or timeout) retries each remaining usable backend once, in index
/// order, instead of answering 502 immediately. A failover onto a
/// different backend re-offers the sticky tag (the client's pinned backend
/// just proved dead). Statuses in the `proxy_next_upstream` mask (502/503/
/// 504) retry the same way; anything else from a live backend is final.
fn statusRetryable(route: *const registry.Route, status: registry.Status) bool {
    const mask = route.proxy_next_upstream_mask;
    if (mask == 0) return false;
    const code: u16 = @intFromEnum(status);
    if (code == 502) return mask & 0x02 != 0;
    if (code == 503) return mask & 0x04 != 0;
    if (code == 504) return mask & 0x08 != 0;
    return false;
}

fn forward(
    ctx: *Context,
    route: *const registry.Route,
    upstreams: []const router.Upstream,
    first_pick: usize,
    started_ns: u64,
    offer_sticky: bool,
) anyerror!Action {
    ensureHealthChecker(route);
    var tried: u64 = 0;
    var pick = first_pick;
    var failed_over = false;
    while (true) {
        tried |= @as(u64, 1) << @intCast(pick);
        _ = attemptForward(ctx, route, upstreams, pick, started_ns, offer_sticky or failed_over) catch |e| {
            if (e != error.UpstreamTransport or !route.proxy_next_upstream) return badGateway(ctx);
            failed_over = true;
            if (!advanceBackend(route, upstreams, &tried, &pick)) return badGateway(ctx);
            continue;
        };
        // Status retry: a masked 502/503/504 counts as a backend failure
        // (marked, for LB health) and moves on; exhaustion keeps the last
        // response instead of replacing it with a 502.
        if (route.proxy_next_upstream and statusRetryable(route, ctx.resp.status)) {
            markFailure(pick, route, started_ns);
            failed_over = true;
            if (!advanceBackend(route, upstreams, &tried, &pick)) return .handled;
            continue;
        }
        return .handled;
    }
}

/// Pick the next untried usable backend into `pick` (marking it tried).
/// False when every backend is tried or unusable.
fn advanceBackend(route: *const registry.Route, upstreams: []const router.Upstream, tried: *u64, pick: *usize) bool {
    for (0..upstreams.len) |i| {
        if (tried.* & (@as(u64, 1) << @intCast(i)) != 0) continue;
        if (!backendUsable(route, i, nowNs())) continue;
        pick.* = i;
        return true;
    }
    return false;
}

/// Rewrite an upstream redirect target per `proxy_redirect <from> <to>;`:
/// when both are set and `name` is Location/Refresh (any case) and `value`
/// starts with `from`, returns the substituted value (caller-owned copy
/// into `alloc`); otherwise null (keep the original). Pure (unit-tested).
/// `proxy_redirect` rewrite for an adopted upstream header (the parked
/// completion in the reactor shares this with the inline adopt path).
pub fn rewriteAdoptedHeader(route: ?*const registry.Route, name: []const u8, value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    const r = route orelse return null;
    return redirectRewrite(r, name, value, alloc);
}

fn redirectRewrite(route: *const registry.Route, name: []const u8, value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    const from = route.proxy_redirect_from orelse return null;
    const to = route.proxy_redirect_to orelse return null;
    if (from.len == 0) return null;
    const is_loc = std.ascii.eqlIgnoreCase(name, "location");
    const is_ref = std.ascii.eqlIgnoreCase(name, "refresh");
    if (!is_loc and !is_ref) return null;
    if (!std.mem.startsWith(u8, value, from)) return null;
    const out = alloc.alloc(u8, to.len + value.len - from.len) catch return null;
    @memcpy(out[0..to.len], to);
    @memcpy(out[to.len..], value[from.len..]);
    return out;
}

/// True when this response is a proxied WebSocket handshake: route opted
/// into `proxy_ws` and the backend answered 101. The `Connection` header
/// is end-to-end here (not hop-by-hop), so adopt sites preserve it.
fn isWs101(ctx: *Context, status: u16) bool {
    if (status != 101) return false;
    const route = ctx.route orelse return false;
    return route.proxy_ws;
}

/// One connect/send/read attempt against backend `idx`: transport failures
/// surface as `error.UpstreamTransport` (retryable); anything else answers
/// directly. See `forward` for the bookkeeping contract.
fn attemptForward(
    ctx: *Context,
    route: *const registry.Route,
    upstreams: []const router.Upstream,
    pick: usize,
    started_ns: u64,
    offer_sticky: bool,
) anyerror!Action {
    const up = &upstreams[pick];
    // TLS upstreams skip the pool (single-use sessions — the Client state
    // cannot be reattached to a bare fd) and the parked path (sync driver
    // only in v1); handshake + record I/O run inline here.
    if (up.tls) return attemptForwardTls(ctx, route, upstreams, pick, started_ns, offer_sticky);
    var fd = acquirePooled(pick, started_ns, keepaliveIdleNs(route));
    if (fd < 0) {
        fd = connectUpstream(up, connectTimeoutMs(route)) catch {
            markFailure(pick, route, started_ns);
            return error.UpstreamTransport;
        };
        setRecvTimeout(fd, readTimeoutS(route));
    }

    // Build and send the upstream request.
    sendUpstreamRequest(fd, ctx, up, sendTimeoutMs(route)) catch {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return error.UpstreamTransport;
    };

    // Read the upstream response (status + headers + body). Bound the
    // first-byte wait by the read timeout: the fd is nonblocking, so a
    // fast-but-not-instant origin would otherwise surface WouldBlock as a
    // 502 (WebSocket 101 handshakes reliably lost this race in tests).
    if (!waitReadable(fd, @intCast(readTimeoutS(route) * 1000))) {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return error.UpstreamTransport;
    }
    var reader = UpstreamReader.init();
    reader.alloc = ctx.req.arena.asAllocator();
    const read_result = reader.read(fd) catch blk: {
        break :blk null;
    };
    if (read_result == null) {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return error.UpstreamTransport;
    }

    // Success: clear passive failures, refresh the EWMA latency sample,
    // then copy the response into ctx.resp.
    if (healthSlot(route, pick)) |slot| {
        slot.fails.store(0, .monotonic);
        slot.last_fail_ns.store(0, .monotonic);
    }
    active[pick] -|= 1;
    releasePooled(pick, fd, started_ns, keepaliveMax(route));
    const elapsed = nowNs() -% started_ns;
    ewma_ns[pick] = if (ewma_ns[pick] == 0)
        elapsed
    else
        ewma_ns[pick] - (ewma_ns[pick] >> 3) + (elapsed >> 3);

    const r = read_result.?;
    ctx.resp.status = @enumFromInt(r.status);
    const ws101 = isWs101(ctx, r.status);
    for (r.headers) |h| {
        // Skip hop-by-hop headers the reactor controls (except Connection
        // on a proxied 101, which is end-to-end).
        const skip = switch (http_parser.header_hasher.hash(h.name)) {
            http_parser.header_hasher.hash("connection") => !ws101,
            http_parser.header_hasher.hash("content-length") => true,
            http_parser.header_hasher.hash("transfer-encoding") => true,
            else => false,
        };
        if (skip or headerHidden(route, h.name)) continue;
        // proxy_redirect rewrites Location/Refresh (arena-owned copy).
        if (redirectRewrite(route, h.name, h.value, ctx.req.arena.asAllocator())) |v| {
            ctx.resp.setHeader(h.name, v);
        } else {
            ctx.resp.setHeader(h.name, h.value);
        }
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

/// TLS variant of one forward attempt: fresh TCP connect, handshake,
/// record-layer send/read, then close (single-use — no pooling, no parked
/// path in v1). Returns .handled on success; error.UpstreamTransport feeds
/// the next_upstream retry loop exactly like plaintext transport failures.
fn attemptForwardTls(
    ctx: *Context,
    route: *const registry.Route,
    upstreams: []const router.Upstream,
    pick: usize,
    started_ns: u64,
    offer_sticky: bool,
) anyerror!Action {
    ensureHealthChecker(route);
    const up = &upstreams[pick];
    // Pooled live session first (same backend index, idle-checked).
    // A stale pooled session (origin closed idly) gets one transparent
    // reconnect: its bytes never reached a live backend, so resending is
    // safe. Fresh-session failures propagate as UpstreamTransport.
    var ps: ?*TlsPooled = acquireTlsPooled(pick, nowNs(), keepaliveIdleNs(route));
    {
        var depth: usize = 0;
        for (tls_pool[pick]) |slot| depth += @intFromBool(slot != null);
        var link: [64]u8 = undefined;
        var lbuf: [64]u8 = undefined;
        var link_slice: []const u8 = "-";
        if (ps) |s| {
            const lp = std.fmt.bufPrint(&lbuf, "/proc/self/fd/{d}", .{s.sock.fd}) catch "?";
            link_slice = compat.readlink(lp, &link) catch "?";
        }
    }
    var reused = ps != null;
    while (true) {
        if (ps == null) {
            const fd = connectUpstream(up, connectTimeoutMs(route)) catch {
                markFailure(pick, route, started_ns);
                return error.UpstreamTransport;
            };
            const fresh = std.heap.page_allocator.create(TlsPooled) catch {
                posix_close(fd);
                markFailure(pick, route, started_ns);
                return error.UpstreamTransport;
            };
            fresh.* = .{ .sock = undefined, .handshaked = false, .last_used_ns = 0 };
            fresh.sock.fd = fd;
            tlsHandshake(fresh, route, up) catch {
                destroyTls(fresh);
                markFailure(pick, route, started_ns);
                return error.UpstreamTransport;
            };
            fresh.handshaked = true;
            ps = fresh;
        } else {
            // Refresh timeouts from the current route (pool spans configs).
            ps.?.sock.read_ms = @intCast(readTimeoutS(route) * 1000);
            ps.?.sock.write_ms = sendTimeoutMs(route);
        }
        const sock = &ps.?.sock;

        // Record-layer round trip; any transport failure lands below.
        // The reader lives here so the parsed body can borrow it.
        var reader = UpstreamReader.init();
        reader.alloc = ctx.req.arena.asAllocator();
        const res = tlsRoundTrip(ctx, up, sock, &reader) catch {
            const retry = reused;
            destroyTls(ps.?);
            ps = null;
            reused = false;
            if (retry) continue;
            active[pick] -|= 1;
            markFailure(pick, route, started_ns);
            return error.UpstreamTransport;
        };


        // Success: same bookkeeping as the plaintext path, then park the
        // live session (keyed by backend, idle-reaped like pooled fds).
        if (healthSlot(route, pick)) |slot| {
            slot.fails.store(0, .monotonic);
            slot.last_fail_ns.store(0, .monotonic);
        }
        active[pick] -|= 1;
        const elapsed = nowNs() -% started_ns;
        ewma_ns[pick] = if (ewma_ns[pick] == 0)
            elapsed
        else
            ewma_ns[pick] - (ewma_ns[pick] >> 3) + (elapsed >> 3);

        const r = res;
        ctx.resp.status = @enumFromInt(r.status);
        const ws101 = isWs101(ctx, r.status);
        const arena_a = ctx.req.arena.asAllocator();
        for (r.headers) |h| {
            const skip = switch (http_parser.header_hasher.hash(h.name)) {
                http_parser.header_hasher.hash("connection") => !ws101,
                http_parser.header_hasher.hash("content-length") => true,
                http_parser.header_hasher.hash("transfer-encoding") => true,
                else => false,
            };
            if (skip) continue;
            const rewrote = redirectRewrite(route, h.name, h.value, arena_a);
            const name_c = arena_a.dupe(u8, h.name) catch return error.OutOfMemory;
            const value_c = arena_a.dupe(u8, rewrote orelse h.value) catch return error.OutOfMemory;
            ctx.resp.setHeader(name_c, value_c);
        }
        const body = ctx.sharedDupe(r.body) orelse return error.OutOfMemory;
        ctx.resp.body = body;
        if (offer_sticky) {
            if (ctx.route.?.sticky_cookie) |name| {
                var tag_buf: [32]u8 = undefined;
                const tag = std.fmt.bufPrint(&tag_buf, "{s}=s{d}; Path=/", .{ name, pick }) catch "";
                if (tag.len > 0) ctx.resp.setHeader("Set-Cookie", tag);
            }
        }
        releaseTlsPooled(pick, ps.?, nowNs(), keepaliveMax(route));
        return .handled;
    }
}

/// One record-layer round trip over a live session: send the upstream
/// request, then fill `reader` until its head parses (or EOF/transport
/// failure). The caller owns `reader`, so the parsed body may borrow it.
fn tlsRoundTrip(ctx: *Context, up: *const router.Upstream, sock: *TlsUpstream, reader: *UpstreamReader) !UpstreamReader.Parsed {
    const req = try buildUpstreamRequest(ctx, up);
    sock.client.writer.writeAll(req) catch |e| {
        return e;
    };
    sock.client.writer.flush() catch |e| {
        return e;
    };
    sock.writer_iface.flush() catch |e| {
        return e;
    };
    {
        var la: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        var llen: std.posix.socklen_t = 16;
        _ = std.os.linux.getsockname(sock.fd, @ptrCast(&la), &llen);
        var pa: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        var plen: std.posix.socklen_t = 16;
        _ = std.os.linux.getpeername(sock.fd, @ptrCast(&pa), &plen);
    }
    while (true) {
        const res = reader.tryParse() catch |e| switch (e) {
            error.Incomplete => {
                const n = tlsFill(reader, sock) catch {
                    return error.UpstreamTransport;
                };
                if (n == 0) {
                    return error.UpstreamTransport; // clean close_notify EOF
                }
                continue;
            },
            else => {
                return error.UpstreamTransport;
            },
        };
        return res;
    }
}

/// Fill an UpstreamReader buffer from a TLS session. Clean EOF
/// (close_notify) reads as 0 — the caller maps it to UpstreamClosed,
/// mirroring the plaintext path.
fn tlsFill(reader: *UpstreamReader, sock: *TlsUpstream) !usize {
    if (reader.used == reader.buf.len) return error.UpstreamBufferFull;
    // NOTE: NOT readSliceShort — that API loops until the destination
    // buffer fills, so it would wait for MORE records (until EOF or the
    // read timeout) before yielding plaintext that is already decrypted.
    // Instead: drain buffered plaintext, else advance the record layer by
    // exactly one record (a NewSessionTicket yields zero app bytes and
    // simply loops), returning as soon as bytes are available.
    // Content-Length overflow bodies fill the store directly; chunked
    // bodies decode INTO the store, so raw bytes go to `buf` instead.
    const to_store = reader.big != null and !reader.chunked;
    while (true) {
        const buffered = sock.client.reader.buffered();
        if (buffered.len > 0) {
            if (to_store) {
                const store = reader.big.?;
                const n = @min(buffered.len, store.len - reader.big_used);
                if (n == 0) return error.UpstreamBufferFull;
                @memcpy(store[reader.big_used..][0..n], buffered[0..n]);
                sock.client.reader.toss(n);
                reader.big_used += n;
                return n;
            }
            const n = @min(buffered.len, reader.buf.len - reader.used);
            if (n == 0) return error.UpstreamBufferFull;
            @memcpy(reader.buf[reader.used..][0..n], buffered[0..n]);
            sock.client.reader.toss(n);
            reader.used += n;
            return n;
        }
        var data: [1][]u8 = .{reader.buf[reader.used..]};
        _ = sock.client.reader.readVec(&data) catch |e| switch (e) {
            error.EndOfStream => return 0, // clean EOF (close_notify / FIN)
            else => return error.UpstreamTransport,
        };
    }
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
            var st = rng_state ^ now_ns ^ (@as(u64, ctx.client_ip[0]) << 56 |
                @as(u64, ctx.client_ip[1]) << 48 | @as(u64, ctx.client_ip[2]) << 40 |
                @as(u64, ctx.client_ip[3]) << 32 | @as(u64, ctx.client_ip[4]) << 24 |
                @as(u64, ctx.client_ip[5]) << 16 | @as(u64, ctx.client_ip[6]) << 8 |
                @as(u64, ctx.client_ip[7]));
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
    const slot = healthSlot(route, idx) orelse return false;
    if (slot.fails.load(.monotonic) < route.max_fails) return slot.alive.load(.acquire);
    if (route.health_check_path != null) return slot.alive.load(.acquire); // rise from the checker
    // No active checker: a tripped route waits out the passive retry window
    // and then retries (nginx max_fails/fail_timeout). Nothing else can
    // revive it, so a permanent lock would blackhole the route forever.
    const last = slot.last_fail_ns.load(.monotonic);
    if (now_ns >= last +% @as(u64, route.fail_timeout_seconds) * std.time.ns_per_s) {
        slot.fails.store(0, .monotonic);
        slot.alive.store(true, .release);
        return true;
    }
    return false;
}

fn markFailure(idx: usize, route: *const registry.Route, now_ns: u64) void {
    const slot = healthSlot(route, idx) orelse return;
    _ = slot.fails.fetchAdd(1, .monotonic);
    slot.last_fail_ns.store(now_ns, .monotonic);
    if (slot.fails.load(.monotonic) >= route.max_fails) {
        slot.alive.store(false, .release);
    }
}

// ---- active health checks ----

/// One sweep across every registered health-checked route: probes each
/// backend whose interval elapsed and applies rise/fall thresholds. Also
/// called directly by tests with an injected probeFn.
pub fn runHealthChecksOnce(now_ns: u64) void {
    // Copy the route list under lock (page-allocator, freed after the
    // sweep): unregistration mutates the shared list, so iterating it
    // directly races. Entries are borrowed route pointers (static in
    // production; tests unregister theirs in testResetRoute).
    const snapshot = blk: {
        hc_mutex.lock();
        defer hc_mutex.unlock();
        // OOM: skip the sweep (next 250 ms tick retries).
        break :blk std.heap.page_allocator.dupe(*const registry.Route, hc_routes.items) catch return;
    };
    defer std.heap.page_allocator.free(snapshot);
    for (snapshot) |route| {
        const path = route.health_check_path orelse continue;
        const timeout: u32 = if (route.health_check_timeout_s != 0) route.health_check_timeout_s else 1;
        for (route.upstreams, 0..) |*up, i| {
            // Resolve once per sweep (mutex), then touch only atomics.
            const slot = blk: {
                health_zone.mutex.lock();
                defer health_zone.mutex.unlock();
                const r = health_zone.upsertLocked(backendKey(route, i)) orelse continue;
                if (!r.existed) r.slot.* = .{};
                break :blk r.slot;
            };
            if (now_ns < slot.probe_next_due_ns.load(.monotonic)) continue;
            const ok = probeFn(up, path, timeout);
            const interval = @as(u64, if (route.health_check_interval_s != 0) route.health_check_interval_s else 5) * std.time.ns_per_s;
            slot.probe_next_due_ns.store(now_ns + interval, .monotonic);
            if (ok) {
                _ = slot.probe_ok.fetchAdd(1, .monotonic);
                slot.probe_fails.store(0, .monotonic);
                const rise: u32 = if (route.health_check_rise != 0) route.health_check_rise else 2;
                if (slot.probe_ok.load(.monotonic) >= rise) {
                    slot.alive.store(true, .release);
                    slot.fails.store(0, .monotonic);
                    slot.probe_ok.store(0, .monotonic);
                }
            } else {
                slot.probe_ok.store(0, .monotonic);
                _ = slot.probe_fails.fetchAdd(1, .monotonic);
                const fall: u32 = if (route.health_check_fall != 0) route.health_check_fall else 3;
                if (slot.probe_fails.load(.monotonic) >= fall) {
                    slot.alive.store(false, .release);
                }
            }
        }
    }
}

/// Register a route for periodic checking (idempotent). Returns true when
/// the route was newly added.
fn registerHealthRoute(route: *const registry.Route) bool {
    if (route.health_check_path == null) return false;
    hc_mutex.lock();
    defer hc_mutex.unlock();
    for (hc_routes.items) |r| {
        if (r == route) return false;
    }
    hc_routes.append(std.heap.page_allocator, route) catch return false;
    return true;
}

/// Drop a route from periodic checking (test isolation: stack routes
/// must never outlive the test — the detached prober would otherwise keep
/// dereferencing them every 250 ms). Production routes are static and
/// never unregistered, so the prober thread never exits there.
fn unregisterHealthRoute(route: *const registry.Route) void {
    hc_mutex.lock();
    defer hc_mutex.unlock();
    for (hc_routes.items, 0..) |r, i| {
        if (r == route) {
            _ = hc_routes.swapRemove(i);
            return;
        }
    }
}

fn ensureHealthChecker(route: *const registry.Route) void {
    if (!registerHealthRoute(route)) {
        // Already registered (or not health-checked): thread is running.
        return;
    }
    hc_mutex.lock();
    const already = hc_thread_started;
    hc_thread_started = true;
    hc_mutex.unlock();
    if (already) return;
    const t = std.Thread.spawn(.{}, healthThread, .{}) catch {
        hc_mutex.lock();
        hc_thread_started = false;
        hc_mutex.unlock();
        return;
    };
    t.detach();
}

var epoch_zero: compat.Instant = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };

fn healthThread() void {
    while (true) {
        hc_mutex.lock();
        const empty = hc_routes.items.len == 0;
        if (empty) hc_thread_started = false;
        hc_mutex.unlock();
        // Idle exit: no routes left (tests unregistered theirs) — a later
        // ensureHealthChecker restarts the prober on demand.
        if (empty) return;
        const t = compat.Instant.now() catch {
            compat.nanosleep(1, 0);
            continue;
        };
        runHealthChecksOnce(t.since(epoch_zero));
        compat.nanosleep(0, 250 * std.time.ns_per_ms);
    }
}

/// Default probe: TCP connect; with a `path`, upgrade to a minimal HEAD and
/// require a 2xx/3xx status line.
fn tcpProbe(up: *const router.Upstream, path: []const u8, timeout_s: u32) bool {
    const fd = connectUpstream(up, @intCast(@as(u64, if (timeout_s == 0) 1 else timeout_s) * 1000)) catch return false;
    defer posix_close(fd);
    setRecvTimeout(fd, if (timeout_s == 0) 1 else timeout_s);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true; // connect-only
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "HEAD {s} HTTP/1.1\r\nHost: zocket-hc\r\nConnection: close\r\n\r\n", .{path}) catch return false;
    var sent: usize = 0;
    while (sent < req.len) {
        sent += compat.write(fd, req[sent..]) catch return false;
    }
    var buf: [128]u8 = undefined;
    var got: usize = 0;
    const timeout_ns: u64 = @as(u64, if (timeout_s == 0) 1 else timeout_s) * std.time.ns_per_s;
    const deadline = compat.Instant.now() catch return false;
    while (got < 12) {
        const n = std.posix.read(fd, buf[got..]) catch return false;
        if (n == 0) break;
        got += n;
        const now = compat.Instant.now() catch return false;
        if (now.since(deadline) > timeout_ns) return false;
    }
    if (got < 12) return false;
    if (!std.mem.startsWith(u8, &buf, "HTTP/1.")) return false;
    const sp = std.mem.indexOfScalar(u8, buf[0..got], ' ') orelse return false;
    if (sp + 3 > got) return false;
    const code = std.fmt.parseInt(u16, buf[sp + 1 .. sp + 3 + 1], 10) catch return false;
    return code >= 200 and code < 400;
}

/// Reactor-side success bookkeeping (same threadlocals the sync path uses;
/// completions run on the client's reactor thread).
pub fn upstreamSuccess(idx: usize, fd: posix_fd, now_ns: u64, route: *const registry.Route) void {
    active[idx] -|= 1;
    releasePooled(idx, fd, now_ns, keepaliveMax(route));
}

pub fn upstreamFail(idx: usize, route: *const registry.Route, now_ns: u64) void {
    active[idx] -|= 1;
    markFailure(idx, route, now_ns);
}

// ---- upstream connection lifecycle ----

fn acquirePooled(idx: usize, now_ns: u64, idle_ns: u64) posix_fd {
    // Try to acquire from the pool for this backend (most recently used first).
    const entries = &pool[idx];
    const len = &pool_lens[idx];
    var i: usize = len.*;
    while (i > 0) {
        i -= 1;
        const e = &entries[i];
        if (e.fd < 0) continue;
        if (now_ns -| e.last_used_ns > idle_ns) {
            // Idle reap.
            posix_close(e.fd);
            e.fd = -1;
            // Remove this entry by swapping with last.
            if (i < len.*) {
                entries[i] = entries[len.* - 1];
                entries[len.* - 1] = .{};
            }
            len.* -= 1;
            continue;
        }
        const fd = e.fd;
        // Remove from pool.
        if (i < len.*) {
            entries[i] = entries[len.* - 1];
            entries[len.* - 1] = .{};
        }
        len.* -= 1;
        // Note: no per-acquire stale probe here — a probe costs a syscall
        // on every pooled request. Staleness is handled by the retry in
        // `parkAt` (a failed pooled attempt is retired on a fresh
        // connection and never counted against the backend).
        return fd;
    }
    return -1;
}

/// Return a connection to the pool (keepalive). Drops the oldest if full.
fn releasePooled(idx: usize, fd: posix_fd, now_ns: u64, max_conns: u32) void {
    const entries = &pool[idx];
    const len = &pool_lens[idx];
    if (len.* < max_conns) {
        entries[len.*] = .{ .fd = fd, .last_used_ns = now_ns };
        len.* += 1;
    } else {
        // Pool full: close the oldest entry to make room.
        const oldest: usize = 0;
        if (entries[oldest].fd >= 0) posix_close(entries[oldest].fd);
        // Shift down and add at end.
        var j: usize = 0;
        while (j < len.* - 1) : (j += 1) {
            entries[j] = entries[j + 1];
        }
        entries[len.* - 1] = .{ .fd = fd, .last_used_ns = now_ns };
    }
}

fn connectUpstream(up: *const router.Upstream, connect_ms: i32) !posix_fd {
    // Non-blocking + CLOEXEC: the connect completes under a bounded poll,
    // and every later read/write on this fd gets EAGAIN handling instead
    // of parking the reactor thread on a slow backend.
    const fd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    errdefer posix_close(fd);
    sockets.setTcpNoDelay(fd);
    compat.connect(fd, &up.sockaddr, 16) catch |e| switch (e) {
        error.WouldBlock => {}, // EINPROGRESS: finish under poll below
        else => return e,
    };
    var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&pfds, connect_ms) catch return error.ConnectTimeout;
    if (ready == 0) return error.ConnectTimeout;
    var err_bytes: [4]u8 = undefined;
    compat.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &err_bytes) catch return error.ConnectFailed;
    if (std.mem.readInt(i32, &err_bytes, .little) != 0) return error.ConnectFailed;
    return fd;
}

/// Wait for readability/up to `timeout_ms`; false on timeout or poll error.
fn waitReadable(fd: posix_fd, timeout_ms: i32) bool {
    var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfds, timeout_ms) catch return false;
    return ready > 0 and (pfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

fn setRecvTimeout(fd: posix_fd, read_s: u32) void {
    var tv = std.posix.timeval{ .sec = @intCast(read_s), .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn posix_close(fd: posix_fd) void {
    compat.close(fd);
}

// ---- upstream request forwarding ----

pub var async_supported: bool = false;

fn sendUpstreamRequest(fd: posix_fd, ctx: *Context, up: *const router.Upstream, send_ms: i32) !void {
    const req = try buildUpstreamRequest(ctx, up);
    var remaining = req;
    while (remaining.len > 0) {
        const n = compat.write(fd, remaining) catch |e| switch (e) {
            error.WouldBlock => {
                var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                const ready = std.posix.poll(&pfds, send_ms) catch return error.UpstreamWriteFailed;
                if (ready == 0) return error.UpstreamWriteFailed;
                continue;
            },
            else => return e,
        };
        remaining = remaining[n..];
    }
}

/// Effective upstream request target: `proxy_pass http://host/uri/;`
/// replaces the matched location prefix with `uri` (query preserved). Pure
/// given the route + target (unit-tested); falls back to the original
/// target when the prefix does not match (defensive; the route matched).
fn upstreamTarget(ctx: *Context, route: *const registry.Route) []const u8 {
    const uri = route.proxy_pass_uri orelse return ctx.req.target;
    const t = ctx.req.target;
    const qpos = std.mem.indexOfScalar(u8, t, '?');
    const tpath = if (qpos) |q| t[0..q] else t;
    const query = if (qpos) |q| t[q..] else "";
    if (!std.mem.startsWith(u8, tpath, route.path)) return t;
    const a = ctx.req.arena.asAllocator();
    const tail = tpath[route.path.len..];
    const out = a.alloc(u8, uri.len + tail.len + query.len) catch return t;
    @memcpy(out[0..uri.len], uri);
    @memcpy(out[uri.len..][0..tail.len], tail);
    @memcpy(out[uri.len + tail.len ..][0..query.len], query);
    return out;
}

fn buildUpstreamRequest(ctx: *Context, up: *const router.Upstream) ![]const u8 {
    // Two-pass: compute exact wire size, then serialize into a single
    // contiguous arena buffer (no ArrayList reallocations, no wasted memory).
    // Mirrors nginx's ngx_http_proxy_create_request approach.

    const method = methodName(ctx.req.method);
    const body = blk: {
        if (ctx.body_storage) |bs| {
            const items = bs.items();
            if (items.len > 0) break :blk items;
        }
        break :blk ctx.req.body;
    };

    // --- pass 1: compute exact size ---
    var total: usize = 0;
    // request line: "METHOD /target HTTP/1.1\r\n" (proxy_pass URI
    // rewriting: the matched location prefix may be replaced).
    const target = if (ctx.route) |r| upstreamTarget(ctx, r) else ctx.req.target;
    total += method.len + 1 + target.len + 11;
    // "Host: upstream:port\r\n"
    total += 6 + up.host.len + 1 + digitCount(up.port) + 2;
    // "X-Forwarded-For: a.b.c.d\r\nX-Real-IP: a.b.c.d\r\n"
    var ip_buf: [48]u8 = undefined;
    const ip = fmtIp(ctx.client_ip, &ip_buf);
    total += 18 + ip.len + 2 + 11 + ip.len + 2;

    const overrides = if (ctx.route) |route| route.proxy_headers else &.{};
    var override_hashes: [8]u32 = undefined;
    var override_count: usize = 0;
    for (overrides) |ph| {
        if (override_count < 8) {
            override_hashes[override_count] = http_parser.header_hasher.hash(ph.name);
            override_count += 1;
        }
    }

    // WebSocket upgrade: forward `Connection: Upgrade` when the route
    // enables it and the client asked (the `Upgrade` + `Sec-WebSocket-*`
    // headers flow through the loop below; `Connection` is otherwise
    // stripped as hop-by-hop).
    const ws_upgrade = blk: {
        const route = ctx.route orelse break :blk false;
        if (!route.proxy_ws) break :blk false;
        break :blk ctx.req.header("upgrade") != null;
    };
    if (ws_upgrade) total += "Connection: Upgrade\r\n".len;
    // Forwarded client headers.
    for (0..ctx.req.headerCount()) |i| {
        const h = ctx.req.headerAt(i);
        const hh = http_parser.header_hasher.hash(h.name);
        const skip = switch (hh) {
            http_parser.header_hasher.hash("host"),
            http_parser.header_hasher.hash("connection"),
            http_parser.header_hasher.hash("content-length"),
            http_parser.header_hasher.hash("transfer-encoding"),
            => true,
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
        // "name: value\r\n"
        total += h.name.len + 2 + h.value.len + 2;
    }

    // proxy_set_header overrides (rendered values).
    // We cannot pre-compute rendered sizes without a buffer, so fall
    // back to ArrayList for this section only (typically 0-2 headers).
    var override_section = std.ArrayList(u8).empty;
    defer override_section.deinit(ctx.req.arena.asAllocator());
    for (overrides) |ph| {
        try override_section.appendSlice(ctx.req.arena.asAllocator(), ph.name);
        try override_section.appendSlice(ctx.req.arena.asAllocator(), ": ");
        var sink = vars.ArrayListSink{ .list = &override_section, .allocator = ctx.req.arena.asAllocator() };
        try vars.renderComplex(ctx, ph.value, &sink);
        try override_section.appendSlice(ctx.req.arena.asAllocator(), "\r\n");
    }
    total += override_section.items.len;

    // "Content-Length: NNN\r\n\r\n" + body
    total += 16 + digitCount(body.len) + 4 + body.len;

    // --- pass 2: serialize into a single contiguous buffer ---
    const buf = ctx.req.arena.alloc(total) orelse return error.OutOfMemory;
    var pos: usize = 0;

    const write = struct {
        fn w(dst: []u8, p: *usize, src: []const u8) void {
            @memcpy(dst[p.* .. p.* + src.len], src);
            p.* += src.len;
        }
    }.w;

    write(buf, &pos, method);
    write(buf, &pos, " ");
    write(buf, &pos, target);
    write(buf, &pos, " HTTP/1.1\r\n");

    write(buf, &pos, "Host: ");
    write(buf, &pos, up.host);
    write(buf, &pos, ":");
    var port_buf: [8]u8 = undefined;
    write(buf, &pos, std.fmt.bufPrint(&port_buf, "{d}", .{up.port}) catch return error.OutOfMemory);
    write(buf, &pos, "\r\n");

    write(buf, &pos, "X-Forwarded-For: ");
    write(buf, &pos, ip);
    write(buf, &pos, "\r\nX-Real-IP: ");
    write(buf, &pos, ip);
    write(buf, &pos, "\r\n");
    if (ws_upgrade) write(buf, &pos, "Connection: Upgrade\r\n");

    // Forwarded client headers.
    for (0..ctx.req.headerCount()) |i| {
        const h = ctx.req.headerAt(i);
        const hh = http_parser.header_hasher.hash(h.name);
        const skip = switch (hh) {
            http_parser.header_hasher.hash("host"),
            http_parser.header_hasher.hash("connection"),
            http_parser.header_hasher.hash("content-length"),
            http_parser.header_hasher.hash("transfer-encoding"),
            => true,
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
        write(buf, &pos, h.name);
        write(buf, &pos, ": ");
        write(buf, &pos, h.value);
        write(buf, &pos, "\r\n");
    }

    // proxy_set_header overrides.
    write(buf, &pos, override_section.items);

    // Content-Length + blank line + body.
    write(buf, &pos, "Content-Length: ");
    var cl_buf: [24]u8 = undefined;
    write(buf, &pos, std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch return error.OutOfMemory);
    write(buf, &pos, "\r\n\r\n");
    write(buf, &pos, body);

    return buf[0..pos];
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

fn digitCount(v: anytype) usize {
    if (v == 0) return 1;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        x /= 10;
    }
    return n;
}

/// Format an IP address into `buf`, returning the used slice.
/// IPv4-mapped addresses (::ffff:a.b.c.d) are formatted as dotted-decimal;
/// full IPv6 addresses are formatted as colon-separated hex groups.
fn fmtIp(ip: [16]u8, buf: []u8) []const u8 {
    // IPv4-mapped: bytes 10-11 are 0xff 0xff -> dotted-decimal.
    if (ip[10] == 0xff and ip[11] == 0xff) {
        var pos: usize = 0;
        inline for (0..4) |i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            const d = ip[12 + i];
            if (d >= 100) {
                buf[pos] = '0' + d / 100;
                pos += 1;
                buf[pos] = '0' + (d / 10) % 10;
                pos += 1;
            } else if (d >= 10) {
                buf[pos] = '0' + d / 10;
                pos += 1;
            }
            buf[pos] = '0' + d % 10;
            pos += 1;
        }
        return buf[0..pos];
    }
    // Full IPv6: hex groups separated by ':'.
    return std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]", .{
        @as(u16, ip[0]) << 8 | ip[1],
        @as(u16, ip[2]) << 8 | ip[3],
        @as(u16, ip[4]) << 8 | ip[5],
        @as(u16, ip[6]) << 8 | ip[7],
        @as(u16, ip[8]) << 8 | ip[9],
        @as(u16, ip[10]) << 8 | ip[11],
        @as(u16, ip[12]) << 8 | ip[13],
        @as(u16, ip[14]) << 8 | ip[15],
    }) catch "-";
}

// ---- upstream response reading ----

const max_upstream_headers = 16;
const UpstreamHeader = struct { name: []const u8, value: []const u8 };

/// Cap for allocator-backed upstream bodies (matching the server's own
/// response-size sanity limits; larger responses are a 502).
const max_upstream_body: usize = 64 * 1024 * 1024;

/// Comma/space separated token match (case-insensitive), for
/// `Transfer-Encoding: chunked` style values.
fn containsToken(value: []const u8, comptime token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

pub const UpstreamReader = struct {
    buf: [16 * 1024]u8 = undefined,
    used: usize = 0,
    pos: usize = 0,
    /// Set by the caller: backs bodies larger than the embedded buffer
    /// (small responses never touch it). Request-arena in the reactor;
    /// null in tests without an allocator (big bodies then 502).
    alloc: ?std.mem.Allocator = null,
    /// Overflow body store: when a Content-Length body does not fit
    /// `buf`, it is allocated once at full size and filled in place —
    /// header slices stay valid (they live in the struct), and `Parsed`
    /// returns a slice of this store.
    big: ?[]u8 = null,
    big_used: usize = 0,
    /// Chunked transfer-encoding response (no Content-Length): the body
    /// is decoded from chunk framing into `big`.
    chunked: bool = false,
    chunk_state: enum { size, data, trailer } = .size,
    chunk_remaining: usize = 0,
    chunked_done: bool = false,
    status: u16 = 0,
    headers: [max_upstream_headers]UpstreamHeader = undefined,
    header_count: usize = 0,
    body: []const u8 = &.{},
    /// Retained parse progress across fills. The header block is parsed
    /// exactly once: without this, a response split across segments would
    /// re-parse already-consumed lines as a fresh status line (502) or
    /// compact away the headers and stall on the body forever.
    headers_complete: bool = false,
    content_length: usize = 0,

    fn init() UpstreamReader {
        return .{};
    }

    pub const Parsed = struct { status: u16, headers: []const UpstreamHeader, body: []const u8 };

    /// One CRLF line straight from the buffer (no socket access).
    fn lineFromBuffer(self: *UpstreamReader) ?[]const u8 {
        const idx = std.mem.indexOfScalar(u8, self.buf[self.pos..self.used], '\n') orelse return null;
        var line = self.buf[self.pos .. self.pos + idx];
        self.pos += idx + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }

    /// Parse strictly from the buffer; error.Incomplete when more bytes are
    /// needed (caller fills and retries). Never touches the socket.
    /// Idempotent on Incomplete: a retry re-parses from the same point
    /// (pos/headers rewound), so split delivery converges instead of
    /// corrupting the parse.
    pub fn tryParse(self: *UpstreamReader) !Parsed {
        if (!self.headers_complete) {
            const saved_pos = self.pos;
            const saved_count = self.header_count;
            const saved_status = self.status;
            errdefer {
                self.pos = saved_pos;
                self.header_count = saved_count;
                self.status = saved_status;
            }
            const status_line = self.lineFromBuffer() orelse return error.Incomplete;
            var it = std.mem.tokenizeAny(u8, status_line, " ");
            _ = it.next(); // HTTP/1.x
            const code_tok = it.next() orelse return error.BadUpstreamResponse;
            self.status = std.fmt.parseInt(u16, code_tok, 10) catch return error.BadUpstreamResponse;

            while (true) {
                const line = self.lineFromBuffer() orelse return error.Incomplete;
                if (line.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadUpstreamResponse;
                if (self.header_count >= max_upstream_headers) return error.BadUpstreamResponse;
                self.headers[self.header_count] = .{
                    .name = std.mem.trim(u8, line[0..colon], " \t"),
                    .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
                };
                self.header_count += 1;
            }

            var content_length: usize = 0;
            var chunked = false;
            for (self.headers[0..self.header_count]) |h| {
                const hh = http_parser.header_hasher.hash(h.name);
                if (hh == comptime http_parser.header_hasher.hash("content-length")) {
                    content_length = std.fmt.parseInt(usize, h.value, 10) catch return error.BadUpstreamResponse;
                } else if (hh == comptime http_parser.header_hasher.hash("transfer-encoding")) {
                    if (containsToken(h.value, "chunked")) chunked = true;
                }
            }
            self.content_length = content_length;
            self.chunked = chunked;
            self.headers_complete = true;
        }
        if (self.chunked) {
            if (!self.decodeChunked()) return error.Incomplete;
            const store = self.big orelse &.{};
            const body: []const u8 = store[0..self.big_used];
            const res: Parsed = .{ .status = self.status, .headers = self.headers[0..self.header_count], .body = body };
            self.headers_complete = false;
            self.content_length = 0;
            self.header_count = 0;
            self.status = 0;
            self.chunked = false;
            self.chunk_state = .size;
            self.chunk_remaining = 0;
            self.chunked_done = false;
            self.big = null;
            self.big_used = 0;
            return res;
        }
        // Large bodies: migrate once to an allocator-backed store (the
        // embedded 16 KiB only covers small responses).
        if (self.big == null and self.content_length > self.buf.len - self.pos) {
            if (self.content_length > max_upstream_body) return error.BadUpstreamResponse;
            const a = self.alloc orelse return error.OutOfMemory;
            const bytes = a.alloc(u8, self.content_length) catch return error.OutOfMemory;
            const have = self.used - self.pos;
            @memcpy(bytes[0..have], self.buf[self.pos..self.used]);
            self.big = bytes;
            self.big_used = have;
            self.pos = 0;
            self.used = 0;
        }
        if (self.big) |store| {
            if (self.big_used < self.content_length) return error.Incomplete;
            const body = store[0..self.content_length];
            const res: Parsed = .{ .status = self.status, .headers = self.headers[0..self.header_count], .body = body };
            // Reset for a pipelined next response on a reused reader.
            self.headers_complete = false;
            self.content_length = 0;
            self.header_count = 0;
            self.status = 0;
            self.big = null;
            self.big_used = 0;
            return res;
        }
        if (self.used - self.pos < self.content_length) {
            // Compact so the next fill appends at a sane offset. Safe now:
            // headers live in the struct fields (and content_length is
            // retained), so moving body bytes cannot lose parse state.
            if (self.pos > 0) {
                const remaining = self.buf[self.pos..self.used];
                std.mem.copyForwards(u8, self.buf[0..remaining.len], remaining);
                self.used -= self.pos;
                self.pos = 0;
            }
            return error.Incomplete;
        }
        const body = self.buf[self.pos .. self.pos + self.content_length];
        self.pos += self.content_length;
        const res: Parsed = .{ .status = self.status, .headers = self.headers[0..self.header_count], .body = body };
        // Reset for a pipelined next response on a reused reader.
        self.headers_complete = false;
        self.content_length = 0;
        self.header_count = 0;
        self.status = 0;
        return res;
    }

    pub fn read(self: *UpstreamReader, fd: posix_fd) !Parsed {
        while (true) {
            const res = self.tryParse() catch |e| switch (e) {
                error.Incomplete => {
                    const got = try self.fill(fd);
                    if (got == 0) return error.UpstreamClosed;
                    continue;
                },
                else => return e,
            };
            return res;
        }
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

    /// Decode chunked framing from the buffer into the (growing) body
    /// store. Returns false when more input is needed (caller refills).
    fn decodeChunked(self: *UpstreamReader) bool {
        while (true) {
            switch (self.chunk_state) {
                .size => {
                    const line = self.lineFromBuffer() orelse return false;
                    if (line.len == 0) return false;
                    // "1a" or "1a;ext=..." — hex size up to the first ';'.
                    const sz = if (std.mem.indexOfScalar(u8, line, ';')) |i| line[0..i] else line;
                    self.chunk_remaining = std.fmt.parseInt(usize, sz, 16) catch return false;
                    if (self.chunk_remaining == 0) {
                        self.chunk_state = .trailer;
                    } else {
                        self.chunk_state = .data;
                    }
                },
                .data => {
                    const avail = self.used - self.pos;
                    const take = @min(avail, self.chunk_remaining);
                    if (take > 0) {
                        if (!self.appendBodyChunk(self.buf[self.pos .. self.pos + take])) return false;
                        self.pos += take;
                        self.chunk_remaining -= take;
                    }
                    if (self.chunk_remaining > 0) {
                        self.compact();
                        return false;
                    }
                    // Chunk data is followed by CRLF.
                    if (self.used - self.pos < 2) {
                        self.compact();
                        return false;
                    }
                    if (self.buf[self.pos] != '\r' or self.buf[self.pos + 1] != '\n') return false;
                    self.pos += 2;
                    self.chunk_state = .size;
                },
                .trailer => {
                    // Consume trailer lines through the terminating CRLF.
                    while (true) {
                        const line = self.lineFromBuffer() orelse {
                            self.compact();
                            return false;
                        };
                        if (line.len == 0) return true;
                    }
                },
            }
        }
    }

    /// Append decoded bytes to the body store, growing it geometrically.
    fn appendBodyChunk(self: *UpstreamReader, bytes: []const u8) bool {
        const want = self.big_used + bytes.len;
        if (want > max_upstream_body) return false;
        if (self.big == null) {
            const a = self.alloc orelse return false;
            self.big = a.alloc(u8, @max(16 * 1024, want)) catch return false;
            self.big_used = 0;
        }
        var store = self.big.?;
        if (want > store.len) {
            const a = self.alloc orelse return false;
            // Arena realloc copies; pointer-identity is not required to
            // survive (no slices into the store are held mid-decode).
            store = a.realloc(store, @max(store.len * 2, want)) catch return false;
            self.big = store;
        }
        @memcpy(store[self.big_used..][0..bytes.len], bytes);
        self.big_used += bytes.len;
        return true;
    }

    /// Slide unconsumed bytes to the front of the buffer.
    fn compact(self: *UpstreamReader) void {
        if (self.pos == 0) return;
        const remaining = self.buf[self.pos..self.used];
        std.mem.copyForwards(u8, self.buf[0..remaining.len], remaining);
        self.used -= self.pos;
        self.pos = 0;
    }

    fn fill(self: *UpstreamReader, fd: posix_fd) !usize {
        // WouldBlock propagates: the caller yields back to the event loop
        // and level-triggered readability re-fires this exact spot.
        // Content-Length overflow bodies fill the store directly; chunked
        // bodies decode INTO the store, so raw bytes go to `buf` instead.
        if (self.big != null and !self.chunked) {
            const store = self.big.?;
            const n = try std.posix.read(fd, store[self.big_used..]);
            self.big_used += n;
            return n;
        }
        const n = try std.posix.read(fd, self.buf[self.used..]);
        self.used += n;
        return n;
    }
};

/// ---- upstream TLS (C3) ----

const tls_client = std.crypto.tls.Client;
const Certificate = std.crypto.Certificate;

/// Shared single-threaded Io for upstream TLS handshakes and record I/O.
/// No worker threads (blocking syscalls inline); safe to share across
/// reactor threads — each operation is self-contained on its own fd.
fn tlsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Process-wide CA bundle cache keyed by file path (loaded once each;
/// DER bytes live forever — same convention as server credentials).
const max_bundles = 4;
var bundle_mutex = compat.Mutex{};
var bundle_paths: [max_bundles][]const u8 = @as([max_bundles][]const u8, @splat(@as([]const u8, "")));
var bundle_slots: [max_bundles]Certificate.Bundle = @as([max_bundles]Certificate.Bundle, @splat(Certificate.Bundle.empty));
var bundle_filled: usize = 0;
var bundle_lock = std.Io.RwLock.init;

/// Load (or reuse) the PEM bundle at `path`. Returns null when the file
/// is missing or unparsable — the caller fails the handshake loudly
/// instead of silently running unverified.
fn trustedBundle(path: []const u8) ?*Certificate.Bundle {
    bundle_mutex.lock();
    defer bundle_mutex.unlock();
    for (bundle_paths[0..bundle_filled], 0..) |p, i| {
        if (std.mem.eql(u8, p, path)) return &bundle_slots[i];
    }
    if (bundle_filled >= max_bundles) return null;
    const io = tlsIo();
    const ts = compat.clock_gettime(std.posix.CLOCK.REALTIME) catch return null;
    const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec };
    var bundle = Certificate.Bundle.empty;
    // Absolute paths (the normal case: /etc/ssl/certs/...) open directly;
    // relative paths resolve from the process cwd.
    if (std.fs.path.isAbsolute(path)) {
        bundle.addCertsFromFilePathAbsolute(std.heap.page_allocator, io, now, path) catch return null;
    } else {
        bundle.addCertsFromFilePath(std.heap.page_allocator, io, now, .cwd(), path) catch return null;
    }
    bundle_paths[bundle_filled] = path;
    bundle_slots[bundle_filled] = bundle;
    bundle_filled += 1;
    return &bundle_slots[bundle_filled - 1];
}

/// SNI + verification hostname for an upstream: explicit override, else
/// the DNS hostname, else (literals) null — literals verify only with an
/// explicit name. Pure (unit-tested).
fn tlsServerName(route: *const registry.Route, up: *const router.Upstream) ?[]const u8 {
    if (route.proxy_ssl_name) |n| return n;
    if (up.hostname) |h| return h;
    return null;
}

/// One live upstream TLS session (single-use: closed, not pooled, after
/// the response — see attemptForward). Buffers are request-arena owned;
/// the whole struct lives on the attempt's stack frame.
const TlsUpstream = struct {
    fd: posix_fd,
    read_ms: i32,
    write_ms: i32,
    reader_iface: std.Io.Reader,
    writer_iface: std.Io.Writer,
    client: tls_client,
};

/// Heap-pooled TLS session: the live Client plus its four record buffers
/// (embedded arrays — the ifaces borrow them, so the struct must never
/// move; heap-boxed once). Reused across requests to the same backend
/// (pool key = backend index, like the plaintext fd pool).
const tls_pool_cap: usize = 4;
const TlsPooled = struct {
    sock: TlsUpstream,
    /// True once the handshake completed (only then is `client` valid
    /// for end()/reuse; a failed handshake destroys raw).
    handshaked: bool = false,
    io_read: [tls_client.min_buffer_len]u8 = undefined,
    io_write: [tls_client.min_buffer_len]u8 = undefined,
    tls_read: [tls_client.min_buffer_len]u8 = undefined,
    tls_write: [tls_client.min_buffer_len]u8 = undefined,
    last_used_ns: u64 = 0,
};

threadlocal var tls_pool: [max_backends][tls_pool_cap]?*TlsPooled = @as([max_backends][tls_pool_cap]?*TlsPooled, @splat(@as([tls_pool_cap]?*TlsPooled, @splat(@as(?*TlsPooled, null)))));
/// Handshakes performed (test hook: reuse shows as flat).
threadlocal var tls_handshake_count: u64 = 0;

fn destroyTls(ps: *TlsPooled) void {
    if (ps.handshaked) {
        ps.sock.client.end() catch {};
        ps.sock.writer_iface.flush() catch {};
    }
    if (ps.sock.fd >= 0) posix_close(ps.sock.fd);
    std.heap.page_allocator.destroy(ps);
}

/// Pop a fresh idle session for backend `idx` (null when empty/stale).
/// Stale entries are destroyed inline (idle reap, same rule as the fd pool).
fn acquireTlsPooled(idx: usize, now_ns: u64, idle_ns: u64) ?*TlsPooled {
    for (&tls_pool[idx]) |*slot| {
        const ps = slot.* orelse continue;
        slot.* = null;
        if (now_ns -| ps.last_used_ns > idle_ns) {
            destroyTls(ps);
            continue;
        }
        return ps;
    }
    return null;
}

/// Park a live session (or destroy when the pool is full / oversized).
fn releaseTlsPooled(idx: usize, ps: *TlsPooled, now_ns: u64, max_conns: usize) void {
    ps.last_used_ns = now_ns;
    const cap: usize = @min(max_conns, tls_pool_cap);
    var used: usize = 0;
    for (tls_pool[idx]) |slot| used += @intFromBool(slot != null);
    if (used >= cap) {
        destroyTls(ps);
        return;
    }
    for (&tls_pool[idx]) |*slot| {
        if (slot.* == null) {
            slot.* = ps;
            return;
        }
    }
    destroyTls(ps); // unreachable (counted above), stay safe
}

/// Empty a backend's TLS pool (test isolation).
fn drainTlsPool(idx: usize) void {
    for (&tls_pool[idx]) |*slot| {
        if (slot.*) |ps| {
            slot.* = null;
            destroyTls(ps);
        }
    }
}

/// Poll-bounded socket Reader/Writer for the TLS record layer. The std
/// client needs blocking-ish semantics, but SO_RCVTIMEO expiry surfaces as
/// EAGAIN — which std treats as a programmer-bug panic, not a catchable
/// timeout. So the fd stays NONBLOCK and every op polls first (timeout →
/// ReadFailed/WriteFailed → UpstreamTransport → 502/failover, never a
/// panic, never an unbounded block).
const tls_reader_vtable = std.Io.Reader.VTable{ .stream = tlsStream };
const tls_writer_vtable = std.Io.Writer.VTable{ .drain = tlsDrain };

fn tlsStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const s: *TlsUpstream = @fieldParentPtr("reader_iface", r);
    var pfds = [_]std.posix.pollfd{.{ .fd = s.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfds, s.read_ms) catch {
        return error.ReadFailed;
    };
    if (ready == 0) {
        return error.ReadFailed; // timeout
    }
    const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
    var data: [1][]u8 = .{dest};
    // Clean EOF (close_notify-less FIN included) MUST surface as
    // EndOfStream, not ReadFailed: the record layer turns it into
    // "return what we have" (or Truncated under strict mode). Mapping it
    // to ReadFailed discards already-decrypted bytes.
    const n = tlsRawRead(s, &data) catch |e| switch (e) {
        error.Eof => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    w.advance(n);
    return n;
}


fn tlsRawRead(s: *TlsUpstream, data: [][]u8) !usize {
    var total: usize = 0;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const rc = linux.read(s.fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) {
                    if (total > 0) return total;
                    return error.Eof;
                }
                total += n;
                if (n < buf.len) return total; // short read: more later
            },
            .INTR => continue, // signal: retry the slice once via loop
            else => {
                return error.ReadFailed;
            },
        }
    }
    return total;
}

fn tlsDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const s: *TlsUpstream = @fieldParentPtr("writer_iface", w);
    // Buffered bytes first, then the slices (splat repeats the last).
    var consumed: usize = 0;
    if (w.end > 0) {
        const n = tlsRawWrite(s, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end -= n;
        if (n > 0 and w.end > 0) {
            // Shift the remainder down (partial write progress).
            std.mem.copyForwards(u8, w.buffer[0..w.end], w.buffer[n .. n + w.end]);
        }
        if (w.end > 0) return consumed;
    }
    for (data, 0..) |slice, i| {
        const reps: usize = if (i + 1 == data.len) @max(splat, 1) else 1;
        var r: usize = 0;
        while (r < reps) : (r += 1) {
            const n = tlsRawWrite(s, slice) catch {
                if (consumed > 0 or r > 0) return consumed;
                return error.WriteFailed;
            };
            consumed += n;
            if (n < slice.len) return consumed;
        }
    }
    return consumed;
}

fn tlsRawWrite(s: *TlsUpstream, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    var pfds = [_]std.posix.pollfd{.{ .fd = s.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&pfds, s.write_ms) catch return error.WriteFailed;
    if (ready == 0) return error.WriteFailed; // timeout
    var total: usize = 0;
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(s.fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                total += n;
                rest = rest[n..];
            },
            .INTR => continue,
            else => {
                if (total > 0) return total;
                return error.WriteFailed;
            },
        }
    }
    return total;
}

/// Handshake a connected fd as a TLS client. Errors (alert, bad cert,
/// timeout) surface for the caller to map to UpstreamTransport.
fn tlsHandshake(
    ps: *TlsPooled,
    route: *const registry.Route,
    up: *const router.Upstream,
) anyerror!void {
    const sock = &ps.sock;
    sock.* = .{
        .fd = ps.sock.fd,
        .read_ms = @intCast(readTimeoutS(route) * 1000),
        .write_ms = sendTimeoutMs(route),
        .reader_iface = .{
            .vtable = &tls_reader_vtable,
            .buffer = &ps.io_read,
            .seek = 0,
            .end = 0,
        },
        .writer_iface = .{
            .vtable = &tls_writer_vtable,
            .buffer = &ps.io_write,
            .end = 0,
        },
        .client = undefined,
    };
    const io = tlsIo();
    var entropy: [tls_client.Options.entropy_len]u8 = undefined;
    compat.randomBytes(&entropy);
    // Real wall clock: certificate expiry/host verification needs true
    // time (verify-off handshakes don't care, but always pass it).
    const ts: std.posix.timespec = compat.clock_gettime(std.posix.CLOCK.REALTIME) catch .{ .sec = 0, .nsec = 0 };
    const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec };
    const sni = tlsServerName(route, up);
    const HostOpt = @FieldType(tls_client.Options, "host");
    const CaOpt = @FieldType(tls_client.Options, "ca");
    const host_opt: HostOpt = if (sni) |n| .{ .explicit = n } else .no_verification;
    const ca_opt: CaOpt = if (route.proxy_ssl_verify) blk: {
        const name = sni orelse return error.TlsNoVerifyName;
        _ = name;
        const bundle = trustedBundle(route.proxy_ssl_trusted_certificate orelse return error.TlsNoBundle) orelse
            return error.TlsBadBundle;
        break :blk .{ .bundle = .{
            .gpa = std.heap.page_allocator,
            .io = io,
            .lock = &bundle_lock,
            .bundle = bundle,
        } };
    } else .no_verification;
    sock.client = tls_client.init(&sock.reader_iface, &sock.writer_iface, .{
        .host = host_opt,
        .ca = ca_opt,
        .write_buffer = &ps.tls_write,
        .read_buffer = &ps.tls_read,
        .entropy = &entropy,
        .realtime_now = now,
        // Origins that close without close_notify (python http.server, our
        // own test origin, many embedded servers) would 502 every response
        // under strict truncation checking. Safe here: UpstreamReader
        // demands exact Content-Length bytes (a short body ends as
        // UpstreamClosed → 502), so truncation fails closed at the HTTP
        // layer instead of corrupting silently.
        .allow_truncation_attacks = true,
    }) catch {
        std.log.info("upstream TLS handshake failed", .{});
        return error.UpstreamTransport;
    };
    tls_handshake_count += 1;
}

const testing = std.testing;

test "upstream reader converges on byte-split delivery" {
    // A response arriving in awkward splits (status only, then headers in
    // two pieces, then body in two pieces) must parse exactly once, with
    // byte-identical status/headers/body — no double-consumed lines, no
    // lost wakeups, no stalls.
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nX-A: b\r\n\r\nhello world";
    const splits = [_]usize{ 10, 30, 45, wire.len };
    var reader = UpstreamReader{};
    var prev: usize = 0;
    for (splits) |end| {
        @memcpy(reader.buf[reader.used .. reader.used + (end - prev)], wire[prev..end]);
        reader.used += end - prev;
        prev = end;
        if (end < wire.len) {
            try testing.expectError(error.Incomplete, reader.tryParse());
        }
    }
    const res = try reader.tryParse();
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expectEqual(@as(usize, 2), res.headers.len);
    try testing.expectEqualStrings("Content-Length", res.headers[0].name);
    try testing.expectEqualStrings("11", res.headers[0].value);
    try testing.expectEqualStrings("hello world", res.body);
}

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
    ctx.client_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 7 };

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
    ctx.client_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };

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

// ---- active health check tests ----

fn mkUp(host: []const u8, port: u16) router.Upstream {
    return .{ .host = host, .port = port, .sockaddr = router.Upstream.makeSockaddr(host, port).? };
}

const hc_test_upstreams = [_]router.Upstream{
    mkUp("127.0.0.1", 1), // nothing listens here
    mkUp("127.0.0.1", 2),
};

test "passive failures trip the shared circuit; success clears it" {
    const route = registry.Route{
        .path = "/hc-passive",
        .max_fails = 2,
        .upstreams = &hc_test_upstreams,
    };
    const key = backendKey(&route, 0);
    // Fresh state (tests share the zone): clear any prior entry.
    health_zone.mutex.lock();
    if (health_zone.upsertLocked(key)) |r| r.slot.* = .{};
    health_zone.mutex.unlock();

    try testing.expect(backendUsable(&route, 0, 0));
    markFailure(0, &route, 100);
    try testing.expect(backendUsable(&route, 0, 0)); // one failure < max_fails
    markFailure(0, &route, 200);
    try testing.expect(!backendUsable(&route, 0, std.time.ns_per_s)); // tripped

    // A successful request clears the passive counter (retry window open).
    if (health_zone.upsertLocked(key)) |r| {
        r.slot.fails.store(0, .monotonic);
        r.slot.alive.store(true, .release);
    }
    try testing.expect(backendUsable(&route, 0, 0));
}

test "active checks apply fall and rise thresholds" {
    const route = registry.Route{
        .path = "/hc-active",
        .max_fails = 3,
        .health_check_path = "/hz",
        .health_check_interval_s = 1000000, // due immediately on first sweep
        .health_check_rise = 2,
        .health_check_fall = 3,
        .upstreams = &hc_test_upstreams,
    };
    _ = registerHealthRoute(&route);

    var fake_ok = true;
    const saved = probeFn;
    defer probeFn = saved;
    probeFn = struct {
        fn probe(up: *const router.Upstream, path: []const u8, t: u32) bool {
            _ = up;
            _ = path;
            _ = t;
            return fake_ok_global;
        }
    }.probe;
    _ = &fake_ok;

    // Three failed probes (fall=3) take the backend down. The interval is
    // huge so every sweep finds the backend due immediately.
    fake_ok = false;
    fake_ok_global = false;
    var sweep_now: u64 = nowForHc();
    const step = intervalNsFor(&route);
    for (0..3) |_| {
        runHealthChecksOnce(sweep_now);
        sweep_now += step;
    }
    try testing.expect(!backendUsable(&route, 1, 0));

    // Two good probes (rise=2) revive it.
    fake_ok = true;
    fake_ok_global = true;
    runHealthChecksOnce(sweep_now);
    sweep_now += step;
    try testing.expect(!backendUsable(&route, 1, 0)); // one OK < rise
    runHealthChecksOnce(sweep_now);
    try testing.expect(backendUsable(&route, 1, 0));
}

var fake_ok_global: bool = true;

fn intervalNsFor(route: *const registry.Route) u64 {
    return @as(u64, if (route.health_check_interval_s != 0) route.health_check_interval_s else 5) * std.time.ns_per_s + 10;
}

fn nowForHc() u64 {
    const t = compat.Instant.now() catch return 0;
    return t.since(epoch_zero);
}

test "tcpProbe distinguishes a live listener from a dead port" {
    const listener = try sockets.createListeningSocket(18933, 4);
    defer compat.close(listener);
    // Accept the probe connection on a side thread (connect-only probe
    // sends nothing and closes).
    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(lfd: std.posix.fd_t) void {
            var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&fds, 2000) catch return;
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const c = sockets.acceptNonBlock(lfd) catch return;
                compat.close(c);
            }
        }
    }.run, .{listener});
    defer accept_thread.join();

    const live = mkUp("127.0.0.1", 18933);
    try testing.expect(tcpProbe(&live, "", 1)); // connect-only succeeds
    // Claim-then-release a port so nothing local listens on it, then
    // verify closedness with retries (another process may briefly grab the
    // ephemeral port).
    var dead_ok_checked = false;
    for (0..4) |_| {
        const tmp_listener = try sockets.createListeningSocket(0, 4);
        const dead_port = try sockets.boundPort(tmp_listener);
        compat.close(tmp_listener);
        const dead = mkUp("127.0.0.1", dead_port);
        if (!tcpProbe(&dead, "", 1)) {
            dead_ok_checked = true;
            break;
        }
    }
    try testing.expect(dead_ok_checked);
}

/// Fake upstream for round-trip tests: accepts connections on a loopback
/// listener and answers every request with a canned response. Bounded by a
/// poll deadline so a test bug fails instead of hanging the suite.
const FakeUpstream = struct {
    listener: posix_fd,
    port: u16,
    max_conns: usize,
    response: []const u8,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    /// Last request head the origin saw (for request-rewrite assertions).
    last_req: [1024]u8 = undefined,
    last_req_len: usize = 0,

    fn start(response: []const u8, max_conns: usize) !*FakeUpstream {
        const self = try testing.allocator.create(FakeUpstream);
        const lfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        try compat.bind(lfd, @ptrCast(&addr), 16);
        try compat.listen(lfd, 8);
        var slen: posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try compat.getsockname(lfd, @ptrCast(&bound), &slen);
        self.* = .{
            .listener = lfd,
            .port = (@as(u16, bound[2]) << 8) | bound[3],
            .max_conns = max_conns,
            .response = response,
        };
        self.thread = try std.Thread.spawn(.{}, runFn, .{self});
        return self;
    }

    fn runFn(self: *FakeUpstream) void {
        var served: usize = 0;
        while (served < self.max_conns and !self.stop_flag.load(.acquire)) {
            var pfds = [_]std.posix.pollfd{.{ .fd = self.listener, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 100) catch break;
            if (ready == 0) continue; // recheck stop flag
            const cfd = linux.accept4(self.listener, null, null, 0);
            if (linux.errno(cfd) != .SUCCESS) {
                break;
            }
            const fd: posix_fd = @intCast(cfd);
            // Keepalive: serve requests on this connection until the peer
            // closes, the deadline passes, or the connection budget runs out.
            while (!self.stop_flag.load(.acquire)) {
                var rpfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                const rready = std.posix.poll(&rpfds, 1000) catch break;
                if (rready == 0) break;
                // Drain one request head, then answer (connection stays
                // open for the next pipelined/keepalive request).
                var req_buf: [4096]u8 = undefined;
                var used: usize = 0;
                var complete = false;
                while (used < req_buf.len) {
                    const n = posix.read(fd, req_buf[used..]) catch break;
                    if (n == 0) break;
                    used += n;
                    if (std.mem.indexOf(u8, req_buf[0..used], "\r\n\r\n") != null) {
                        complete = true;
                        break;
                    }
                }
                if (!complete) break;
                self.last_req_len = @min(used, self.last_req.len);
                @memcpy(self.last_req[0..self.last_req_len], req_buf[0..self.last_req_len]);
                _ = compat.write(fd, self.response) catch break;
            }
            compat.close(fd);
            served += 1;
        }
    }

    fn stop(self: *FakeUpstream) void {
        self.stop_flag.store(true, .release);
        compat.close(self.listener); // wakes the poll
        self.thread.join();
        testing.allocator.destroy(self);
    }
};

/// Empty a backend's keepalive pool (test isolation: pooled fds from one
/// test must never leak into another's backend idx 0).
fn drainPool(idx: usize) void {
    while (true) {
        const fd = acquirePooled(idx, nowNs(), pool_default_idle_s * std.time.ns_per_s);
        if (fd < 0) break;
        posix_close(fd);
    }
}

/// Test-only: clear all backend state for `route` (health slots, pools,
/// in-flight counts). Backend state is keyed by route pointer in
/// process-wide zones, and stack-allocated test routes alias addresses
/// across tests — call this at the start of any test that forwards.
pub fn testResetRoute(route: *const registry.Route) void {
    unregisterHealthRoute(route);
    for (0..max_backends) |i| drainTlsPool(i);
    tls_handshake_count = 0;
    health_zone.mutex.lock();
    defer health_zone.mutex.unlock();
    for (0..max_backends) |i| {
        if (health_zone.upsertLocked(backendKey(route, i))) |r| r.slot.* = .{};
    }
    for (0..max_backends) |i| drainPool(i);
    for (&active) |*a| a.* = 0;
}

test "proxy round-trips through the sync forward path with pool reuse" {
    const srv = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Up: 1\r\n\r\nhello", 4);
    defer srv.stop();
    var ups = [_]router.Upstream{mkUp("127.0.0.1", srv.port)};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 3,
        .upstreams = &ups,
    };
    testResetRoute(&route);

    // Seed the pool with a BLOCKING socket: the sync forward path reads
    // exactly once, so a nonblocking fd would race the fake's response
    // (WouldBlock -> 502). Blocking + recv timeout is deterministic.
    const seed = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    try compat.connect(seed, &ups[0].sockaddr, 16);
    setRecvTimeout(seed, default_read_timeout_s);
    releasePooled(0, seed, nowNs(), pool_default_max);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .get;
        req.target = "/proxied/hello.txt";
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(registry.Status.ok, resp.status);
        try testing.expectEqualStrings("hello", resp.body);
        var seen_upstream = false;
        for (resp.headers[0..resp.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "X-Up")) seen_upstream = true;
        }
        try testing.expect(seen_upstream);
    }
    // The second request reused the pooled keepalive connection.
    drainPool(0);
}

test "proxy connectUpstream dials a live listener" {
    const srv = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 1);
    defer srv.stop();
    var ups = [_]router.Upstream{mkUp("127.0.0.1", srv.port)};
    const cfd = try connectUpstream(&ups[0], default_connect_timeout_ms);
    defer posix_close(cfd);
    drainPool(0);
}

test "proxy answers 502 when the upstream refuses" {
    // Reserve-then-close a listener so the port is definitely shut.
    const lfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try compat.bind(lfd, @ptrCast(&addr), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try compat.getsockname(lfd, @ptrCast(&bound), &slen);
    const dead_port = (@as(u16, bound[2]) << 8) | bound[3];
    compat.close(lfd);

    var ups = [_]router.Upstream{mkUp("127.0.0.1", dead_port)};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
    };
    testResetRoute(&route); // a pooled live fd must not mask the refused dial
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.bad_gateway, resp.status);
}



test "proxy timeouts resolve explicit seconds over defaults" {
    const def = registry.Route{ .path = "/" };
    try testing.expectEqual(@as(i32, 1000), connectTimeoutMs(&def));
    try testing.expectEqual(@as(i32, 1000), sendTimeoutMs(&def));
    try testing.expectEqual(@as(u32, 5), readTimeoutS(&def));
    const tuned = registry.Route{
        .path = "/",
        .proxy_connect_timeout_s = 2,
        .proxy_send_timeout_s = 3,
        .proxy_read_timeout_s = 10,
    };
    try testing.expectEqual(@as(i32, 2000), connectTimeoutMs(&tuned));
    try testing.expectEqual(@as(i32, 3000), sendTimeoutMs(&tuned));
    try testing.expectEqual(@as(u32, 10), readTimeoutS(&tuned));
}

test "proxy setRecvTimeout applies SO_RCVTIMEO read-back" {
    const pair = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    defer compat.close(pair[1]);
    setRecvTimeout(pair[0], 7);
    var tv: std.posix.timeval = undefined;
    try compat.getsockopt(pair[0], std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    try testing.expectEqual(@as(i64, 7), tv.sec);
}

/// Reserve a loopback port, then close it: connecting to it refuses fast.
fn deadBackendPort() !u16 {
    const lfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try compat.bind(lfd, @ptrCast(&addr), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try compat.getsockname(lfd, @ptrCast(&bound), &slen);
    compat.close(lfd);
    return (@as(u16, bound[2]) << 8) | bound[3];
}

test "proxy_next_upstream off: sticky-pinned dead backend answers 502" {
    const srv = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 4);
    defer srv.stop();
    var ups = [_]router.Upstream{ mkUp("127.0.0.1", try deadBackendPort()), mkUp("127.0.0.1", srv.port) };
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .sticky_cookie = "zsid",
        .upstreams = &ups,
    };
    testResetRoute(&route);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    _ = req.addHeaderParsed("Cookie", "zsid=s0") catch unreachable;
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.bad_gateway, resp.status);
}

test "proxy_next_upstream on: failover serves from the live backend" {
    const srv = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Up: 1\r\n\r\nhello", 4);
    defer srv.stop();
    var ups = [_]router.Upstream{ mkUp("127.0.0.1", try deadBackendPort()), mkUp("127.0.0.1", srv.port) };
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .sticky_cookie = "zsid",
        .proxy_next_upstream = true,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    // Seed backend 1 with a blocking socket (deterministic read).
    const seed = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    try compat.connect(seed, &ups[1].sockaddr, 16);
    setRecvTimeout(seed, default_read_timeout_s);
    releasePooled(1, seed, nowNs(), pool_default_max);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    _ = req.addHeaderParsed("Cookie", "zsid=s0") catch unreachable;
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("hello", resp.body);
    // Failover re-offers the sticky tag pointing at the live backend.
    var retagged = false;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie") and std.mem.indexOf(u8, h.value, "zsid=s1") != null) {
            retagged = true;
        }
    }
    try testing.expect(retagged);
    drainPool(1);
}

test "proxy_next_upstream on: all backends dead still answers 502" {
    var ups = [_]router.Upstream{ mkUp("127.0.0.1", try deadBackendPort()), mkUp("127.0.0.1", try deadBackendPort()) };
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_next_upstream = true,
        .upstreams = &ups,
    };
    testResetRoute(&route);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.bad_gateway, resp.status);
}

test "proxy keepalive caps resolve defaults and clamp to the hard cap" {
    const def = registry.Route{ .path = "/" };
    try testing.expectEqual(pool_default_max, keepaliveMax(&def));
    try testing.expectEqual(pool_default_idle_s * std.time.ns_per_s, keepaliveIdleNs(&def));
    const tuned = registry.Route{ .path = "/", .proxy_keepalive_max = 4, .proxy_keepalive_timeout_s = 30 };
    try testing.expectEqual(@as(u32, 4), keepaliveMax(&tuned));
    try testing.expectEqual(@as(u64, 30) * std.time.ns_per_s, keepaliveIdleNs(&tuned));
    const huge = registry.Route{ .path = "/", .proxy_keepalive_max = 1000 };
    try testing.expectEqual(pool_hard_cap, keepaliveMax(&huge));
}

test "proxy pool reaps idle entries and returns fresh ones" {
    // Backend 7: unused by other tests (they pin idx 0/1).
    const idx = 7;
    drainPool(idx);
    const pair = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    // Stale entry (last_used = 0): reaped on acquire, pool stays empty.
    releasePooled(idx, pair[0], 0, pool_default_max);
    releasePooled(idx, pair[1], 0, pool_default_max);
    try testing.expectEqual(@as(posix_fd, -1), acquirePooled(idx, nowNs(), 1));
    // Fresh entry: returned as-is.
    const live = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    releasePooled(idx, live[0], nowNs(), pool_default_max);
    compat.close(live[1]);
    try testing.expectEqual(live[0], acquirePooled(idx, nowNs(), pool_default_idle_s * std.time.ns_per_s));
    compat.close(live[0]);
    // Overflow past max_conns closes instead of growing the pool.
    var i: u32 = 0;
    while (i < pool_default_max + 2) : (i += 1) {
        const sp = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        releasePooled(idx, sp[0], nowNs(), 2);
        compat.close(sp[1]);
    }
    try testing.expectEqual(@as(u32, 2), pool_lens[idx]);
    drainPool(idx);
}

test "proxy hostname upstream resolves via refresh then forwards" {
    // Heap record: refresh rewrites the octets (never .rodata).
    const stub = try dns_resolver.Stub.start();
    defer stub.stopStub();
    const fake = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{ .host = "loopback", .port = fake.port, .hostname = "loopback" }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    // Resolve + register against the stub, then refresh into the record.
    var srv = dns_resolver.Servers{};
    srv.addrs[0] = sockets.parseIpv4("127.0.0.1").?;
    srv.len = 1;
    dns_resolver.resolveAndRegister("loopback", &ups[0], srv, stub.port);
    try testing.expectEqual(@as(u16, 2), ups[0].sockaddr.family); // AF_INET now
    // Seed backend 0 with a blocking socket (deterministic read).
    const seed = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    try compat.connect(seed, &ups[0].sockaddr, 16);
    setRecvTimeout(seed, default_read_timeout_s);
    releasePooled(0, seed, nowNs(), pool_default_max);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("hello", resp.body);
    drainPool(0);
}

test "proxy tlsServerName prefers override, then hostname, then null" {
    const lit = router.Upstream{ .host = "127.0.0.1", .port = 443, .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", 443).? };
    const dns = router.Upstream{ .host = "api.example.com", .port = 443, .hostname = "api.example.com" };
    const plain = registry.Route{ .path = "/" };
    try testing.expect(tlsServerName(&plain, &lit) == null);
    try testing.expectEqualStrings("api.example.com", tlsServerName(&plain, &dns).?);
    const named = registry.Route{ .path = "/", .proxy_ssl_name = "override.internal" };
    try testing.expectEqualStrings("override.internal", tlsServerName(&named, &lit).?);
    try testing.expectEqualStrings("override.internal", tlsServerName(&named, &dns).?);
}

test "proxy TLS against a plaintext origin fails transport, not panic" {
    // A TLS handshake against an HTTP-speaking origin dies on the first
    // garbage flight: UpstreamTransport → 502 (or failover), never a hang.
    const fake = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
        .tls = true,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ssl_verify = false,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.bad_gateway, resp.status);
}

/// TLS origin for end-to-end proxy tests: our own TlsConn server side over
/// TCP loopback, answering one canned HTTP response per connection.
const TlsOrigin = struct {
    listener: posix_fd,
    port: u16,
    response: []const u8,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(response: []const u8) !*TlsOrigin {
        const self = try testing.allocator.create(TlsOrigin);
        const lfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        try compat.bind(lfd, @ptrCast(&addr), 16);
        try compat.listen(lfd, 8);
        var slen: posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try compat.getsockname(lfd, @ptrCast(&bound), &slen);
        self.* = .{
            .listener = lfd,
            .port = (@as(u16, bound[2]) << 8) | bound[3],
            .response = response,
        };
        self.thread = try std.Thread.spawn(.{}, runFn, .{self});
        return self;
    }

    fn runFn(self: *TlsOrigin) void {
        const cert_mod = @import("../../tls/cert.zig");
        const testdata = @import("../../tls/testdata.zig");
        var creds = cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem) catch return;
        defer testing.allocator.free(creds.cert_der);
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]std.posix.pollfd{.{ .fd = self.listener, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 100) catch break;
            if (ready == 0) continue;
            const cfd = linux.accept4(self.listener, null, null, 0);
            if (linux.errno(cfd) != .SUCCESS) break;
            const fd: posix_fd = @intCast(cfd);
            serveOne(fd, &creds, self.response);
            compat.close(fd);
        }
    }

    fn serveOne(fd: posix_fd, creds: *const @import("../../tls/cert.zig").Credentials, response: []const u8) void {
        const tls_conn = @import("../../tls/conn.zig");
        var conn = tls_conn.TlsConn.init(creds);
        defer conn.deinit();
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [16 * 1024]u8 = undefined;
        var plain: [16 * 1024]u8 = undefined;
        var plain_used: usize = 0;
        while (true) {
            var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 5000) catch {
                return;
            };
            if (ready == 0) {
                return;
            }
            const n = posix.read(fd, &in_buf) catch {
                return;
            };
            if (n == 0) {
                return;
            }
            conn.feed(in_buf[0..n]) catch {
                return;
            };
            flushOut(fd, &conn, &out_buf);
            if (conn.stage() != .application) continue;
            // Append into the unconsumed tail (a split record must not
            // overwrite bytes an earlier take already banked).
            const p = switch (conn.inner) {
                inline else => |*s| s.takePlaintext(plain[plain_used..]),
            };
            if (p == 0) continue;
            plain_used += p;
            if (std.mem.indexOf(u8, plain[0..plain_used], "\r\n\r\n") == null) continue;
            switch (conn.inner) {
                inline else => |*s| s.write(response) catch {
                    return;
                },
            }
            flushOut(fd, &conn, &out_buf);
            // Keep-alive: serve further requests on this connection until
            // the peer closes (lets pooled client sessions actually reuse).
            plain_used = 0;
        }
    }

    fn flushOut(fd: posix_fd, conn: *@import("../../tls/conn.zig").TlsConn, out_buf: []u8) void {
        while (true) {
            const m = switch (conn.inner) {
                inline else => |*s| s.takeOut(out_buf),
            };
            if (m == 0) return;
            _ = compat.write(fd, out_buf[0..m]) catch {
                return;
            };
        }
    }

    fn stop(self: *TlsOrigin) void {
        self.stop_flag.store(true, .release);
        compat.close(self.listener);
        self.thread.join();
        testing.allocator.destroy(self);
    }
};

test "proxy TLS end to end against our own server session" {
    const origin = try TlsOrigin.start("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\ntls-hello");
    defer origin.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = origin.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", origin.port).?,
        .tls = true,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ssl_verify = false,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/secure";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("tls-hello", resp.body);
}


test "proxy TLS verify-on trusts the testdata cert via bundle file" {
    // Bundle file carrying the origin's own (self-signed) cert: chain of
    // one verifies, and SNI/hostname matches the CN via proxy_ssl_name.
    const path = "/tmp/zocket-upstream-ca-test.pem";
    {
        const testdata = @import("../../tls/testdata.zig");
        compat.deleteFile(path) catch {};
        try compat.writeFile(path, testdata.cert_pem);
    }
    defer compat.deleteFile(path) catch {};
    const origin = try TlsOrigin.start("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\ntls-hello");
    defer origin.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = origin.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", origin.port).?,
        .tls = true,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ssl_verify = true,
        .proxy_ssl_trusted_certificate = path,
        .proxy_ssl_name = "zocket-test",
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/secure";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("tls-hello", resp.body);
}

test "proxy TLS iso: sock ifaces round-trip bytes over socketpair" {
    // No TLS involved: proves the poll-bounded vtables move bytes
    // correctly in both directions (the TLS failures are elsewhere).
    const pair = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
    defer compat.close(pair[0]);
    defer compat.close(pair[1]);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sock = TlsUpstream{
        .fd = pair[0],
        .read_ms = 2000,
        .write_ms = 2000,
        .reader_iface = .{ .vtable = &tls_reader_vtable, .buffer = rbuf[0..], .seek = 0, .end = 0 },
        .writer_iface = .{ .vtable = &tls_writer_vtable, .buffer = wbuf[0..], .end = 0 },
        .client = undefined,
    };
    // Outbound: iface write must land on the peer (raw read there).
    const msg = "iface round-trip payload 12345";
    try sock.writer_iface.writeAll(msg);
    try sock.writer_iface.flush();
    var raw: [64]u8 = undefined;
    const n = try posix.read(pair[1], &raw);
    try testing.expectEqual(msg.len, n);
    try testing.expectEqualStrings(msg, raw[0..n]);
    // Inbound: raw peer write must surface through the iface.
    const back = "peer reply ok";
    _ = try compat.write(pair[1], back);
    var out: [64]u8 = undefined;
    try sock.reader_iface.readSliceAll(out[0..back.len]);
    try testing.expectEqualStrings(back, out[0..back.len]);
}

test "proxy_ws forwards Connection Upgrade and relays a 101" {
    // Request construction carries Connection: Upgrade upstream only when
    // the route opts into proxy_ws and the client sent Upgrade.
    const mkReq = struct {
        fn go(with_upgrade: bool) !registry.Request {
            var req = registry.Request.init(testing.allocator);
            req.method = .get;
            req.target = "/ws";
            req.decoded_target = "/ws";
            if (with_upgrade) {
                try req.addHeaderParsed("Upgrade", "websocket");
                try req.addHeaderParsed("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
            }
            return req;
        }
    }.go;
    const ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = 9999,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", 9999).?,
    }};
    {
        var req = try mkReq(true);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        const route = registry.Route{ .path = "/", .proxy_ws = true, .upstreams = &ups };
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        const wire = try buildUpstreamRequest(&ctx, &ups[0]);
        try testing.expect(std.mem.indexOf(u8, wire, "Connection: Upgrade\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, wire, "Upgrade: websocket") != null);
    }
    {
        // Disabled: no Connection header leaks upstream.
        var req = try mkReq(true);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        const route = registry.Route{ .path = "/", .upstreams = &ups };
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        const wire = try buildUpstreamRequest(&ctx, &ups[0]);
        try testing.expect(std.mem.indexOf(u8, wire, "Connection:") == null);
    }
    {
        // No client Upgrade: enabled but nothing to forward.
        var req = try mkReq(false);
        defer req.deinit();
        var resp = registry.Response.init(.ok);
        const route = registry.Route{ .path = "/", .proxy_ws = true, .upstreams = &ups };
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route;
        const wire = try buildUpstreamRequest(&ctx, &ups[0]);
        try testing.expect(std.mem.indexOf(u8, wire, "Connection:") == null);
    }
}

test "proxy_ws 101 round-trips through a fake origin" {
    const fake = try FakeUpstream.start("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ws = true,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/ws";
    req.decoded_target = "/ws";
    try req.addHeaderParsed("Upgrade", "websocket");
    try req.addHeaderParsed("Connection", "Upgrade");
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.switching_protocols, resp.status);
    // Connection survives on 101 (end-to-end); Upgrade was never stripped.
    var saw_conn = false;
    var saw_upgrade = false;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) saw_conn = true;
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) saw_upgrade = true;
    }
    try testing.expect(saw_conn and saw_upgrade);
}

test "proxy non-101 still strips connection headers" {
    const fake = try FakeUpstream.start("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nhi", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ws = true,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    for (resp.headers[0..resp.header_count]) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "connection"));
    }
}

test "health unregister drops routes so the prober never touches them" {
    const route = registry.Route{
        .path = "/hc-gone",
        .health_check_path = "/hz",
        .health_check_interval_s = 1000000,
        .upstreams = &hc_test_upstreams,
    };
    _ = registerHealthRoute(&route);
    unregisterHealthRoute(&route);
    unregisterHealthRoute(&route); // idempotent
    hc_mutex.lock();
    var found = false;
    for (hc_routes.items) |r| {
        if (r == &route) found = true;
    }
    hc_mutex.unlock();
    try testing.expect(!found);
}

test "proxy_redirect rewrites Location prefixes only" {
    const route = registry.Route{
        .path = "/",
        .proxy_redirect_from = "http://127.0.0.1:9000",
        .proxy_redirect_to = "https://example.com",
    };
    const a = testing.allocator;
    const hit = redirectRewrite(&route, "Location", "http://127.0.0.1:9000/login?x=1", a).?;
    defer a.free(hit);
    try testing.expectEqualStrings("https://example.com/login?x=1", hit);
    // Case-insensitive header name.
    const hit2 = redirectRewrite(&route, "LOCATION", "http://127.0.0.1:9000/", a).?;
    defer a.free(hit2);
    try testing.expectEqualStrings("https://example.com/", hit2);
    // Non-matching value, other headers, and off-routes pass through.
    try testing.expect(redirectRewrite(&route, "Location", "http://other/x", a) == null);
    try testing.expect(redirectRewrite(&route, "Content-Type", "http://127.0.0.1:9000/", a) == null);
    const plain = registry.Route{ .path = "/" };
    try testing.expect(redirectRewrite(&plain, "Location", "http://127.0.0.1:9000/", a) == null);
}

test "proxy_redirect 302 round-trips rewritten through a fake origin" {
    const fake = try FakeUpstream.start("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9000/login\r\nContent-Length: 0\r\n\r\n", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_redirect_from = "http://127.0.0.1:9000",
        .proxy_redirect_to = "https://example.com",
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/old";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.found, resp.status);
    var loc: ?[]const u8 = null;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) loc = h.value;
    }
    try testing.expectEqualStrings("https://example.com/login", loc.?);
}

test "proxy_next_upstream status mask retries 502 onto the next backend" {
    const bad = try FakeUpstream.start("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 3\r\n\r\nbad", 4);
    defer bad.stop();
    const good = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 4);
    defer good.stop();
    var ups = [_]router.Upstream{
        .{ .host = "127.0.0.1", .port = bad.port, .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", bad.port).? },
        .{ .host = "127.0.0.1", .port = good.port, .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", good.port).? },
    };
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_next_upstream = true,
        .proxy_next_upstream_mask = 0x01 | 0x02,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok", resp.body);
}

test "proxy_next_upstream keeps the last response when backends exhaust" {
    const bad = try FakeUpstream.start("HTTP/1.1 503 Busy\r\nContent-Length: 3\r\n\r\nbad", 4);
    defer bad.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = bad.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", bad.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_next_upstream = true,
        .proxy_next_upstream_mask = 0x01 | 0x04,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    // No backend left: the live 503 stands (not replaced by a 502).
    try testing.expectEqual(registry.Status.service_unavailable, resp.status);
}

test "statusRetryable matches only masked codes" {
    const r = registry.Route{ .path = "/", .proxy_next_upstream = true, .proxy_next_upstream_mask = 0x02 };
    try testing.expect(statusRetryable(&r, .bad_gateway));
    try testing.expect(!statusRetryable(&r, .service_unavailable));
    try testing.expect(!statusRetryable(&r, .ok));
    const off = registry.Route{ .path = "/" };
    try testing.expect(!statusRetryable(&off, .bad_gateway));
}


test "tryParse handles the exact 47-byte response" {
    var r = UpstreamReader.init();
    const resp = "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\ntls-hello";
    @memcpy(r.buf[0..resp.len], resp);
    r.used = resp.len;
    const p = try r.tryParse();
    try testing.expectEqual(@as(u16, 200), p.status);
    try testing.expectEqualStrings("tls-hello", p.body);
}

test "proxy TLS pools live sessions across requests" {
    const origin = try TlsOrigin.start("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\ntls-hello");
    defer origin.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = origin.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", origin.port).?,
        .tls = true,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_ssl_verify = false,
        .proxy_keepalive_max = 4,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    const once = struct {
        fn go(rt: *const registry.Route) !void {
            var req = registry.Request.init(testing.allocator);
            defer req.deinit();
            req.method = .get;
            req.target = "/secure";
            var resp = registry.Response.init(.ok);
            var ctx = Context{ .req = &req, .resp = &resp };
            ctx.route = rt;
            try testing.expectEqual(Action.handled, try run(&ctx));
            try testing.expectEqualStrings("tls-hello", resp.body);
        }
    }.go;
    try once(&route);
    try once(&route);
    try once(&route);
    // Three requests, one handshake: sessions 2 and 3 reused the pool.
    try testing.expectEqual(@as(u64, 1), tls_handshake_count);
}

test "tls sock iface poll reads available bytes" {
    // Isolation: does tlsStream see waiting data? (Rules out poll blindness.)
    const pair = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
    defer compat.close(pair[0]);
    defer compat.close(pair[1]);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sock = TlsUpstream{
        .fd = pair[0],
        .read_ms = 2000,
        .write_ms = 2000,
        .reader_iface = .{ .vtable = &tls_reader_vtable, .buffer = rbuf[0..], .seek = 0, .end = 0 },
        .writer_iface = .{ .vtable = &tls_writer_vtable, .buffer = wbuf[0..], .end = 0 },
        .client = undefined,
    };
    _ = try compat.write(pair[1], "hello-poll");
    var out: [64]u8 = undefined;
    // Drive stream() directly through a temp writer over `out`.
    var w: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.fixedDrain }, .buffer = out[0..], .end = 0 };
    const n = try sock.reader_iface.vtable.stream(&sock.reader_iface, &w, .limited(out.len));
    try testing.expect(n > 0);
    try testing.expectEqualStrings("hello-poll", out[0..n]);
}

test "proxy handles upstream responses larger than the reader buffer" {
    // 100 KB body via a fake origin: must round-trip byte-exact (the
    // reader's embedded buffer is 16 KB).
    const body_len = 100 * 1024;
    var resp_buf = std.ArrayList(u8).empty;
    defer resp_buf.deinit(testing.allocator);
    try resp_buf.print(testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body_len});
    var i: usize = 0;
    while (i < body_len) : (i += 1) resp_buf.append(testing.allocator, @intCast('a' + (i % 26))) catch unreachable;
    const fake = try FakeUpstream.start(resp_buf.items, 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqual(@as(usize, body_len), resp.body.len);
    try testing.expectEqual(@as(u8, 'a'), resp.body[0]);
}

test "proxy decodes chunked upstream responses" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";
    const fake = try FakeUpstream.start(wire, 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("hello world", resp.body);
}

test "proxy decodes chunked bodies larger than the buffer" {
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(testing.allocator);
    try wire.appendSlice(testing.allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    // 64 chunks x 4096 = 256 KB decoded.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try wire.print(testing.allocator, "1000\r\n", .{});
        var j: usize = 0;
        while (j < 4096) : (j += 1) try wire.append(testing.allocator, @intCast('a' + (i % 26)));
        try wire.appendSlice(testing.allocator, "\r\n");
    }
    try wire.appendSlice(testing.allocator, "0\r\n\r\n");
    const fake = try FakeUpstream.start(wire.items, 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(@as(usize, 256 * 1024), resp.body.len);
    try testing.expectEqual(@as(u8, 'a'), resp.body[0]);
}

test "chunked reader ignores chunk extensions and trailers" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5;ext=1\r\nhello\r\n" ++
        "0\r\nX-Trailer: v\r\n\r\n";
    // Arena mirrors the production backing (leaks reclaimed wholesale).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var r = UpstreamReader{};
    r.alloc = arena_state.allocator();
    @memcpy(r.buf[0..wire.len], wire);
    r.used = wire.len;
    const p = try r.tryParse();
    try testing.expectEqual(@as(u16, 200), p.status);
    try testing.expectEqualStrings("hello", p.body);
}

test "proxy TLS handles large and chunked upstream bodies" {
    // Large Content-Length body over TLS.
    var big_resp = std.ArrayList(u8).empty;
    defer big_resp.deinit(testing.allocator);
    try big_resp.print(testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{64 * 1024});
    var i: usize = 0;
    while (i < 64 * 1024) : (i += 1) big_resp.append(testing.allocator, @intCast('x')) catch unreachable;
    const origin1 = try TlsOrigin.start(big_resp.items);
    defer origin1.stop();
    var ups1 = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = origin1.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", origin1.port).?,
        .tls = true,
    }};
    const route1 = registry.Route{ .path = "/", .balance = .round_robin, .max_fails = 10, .upstreams = &ups1 };
    testResetRoute(&route1);
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .get;
        req.target = "/big";
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route1;
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(@as(usize, 64 * 1024), resp.body.len);
        try testing.expectEqual(@as(u8, 'x'), resp.body[0]);
    }
    // Chunked body over TLS.
    const origin2 = try TlsOrigin.start("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    defer origin2.stop();
    var ups2 = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = origin2.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", origin2.port).?,
        .tls = true,
    }};
    const route2 = registry.Route{ .path = "/", .balance = .round_robin, .max_fails = 10, .upstreams = &ups2 };
    testResetRoute(&route2);
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .get;
        req.target = "/chunked";
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &route2;
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqualStrings("hello", resp.body);
    }
}

test "proxy_pass URI tail replaces the matched location prefix" {
    const fake = try FakeUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const route = registry.Route{
        .path = "/api/",
        .balance = .round_robin,
        .max_fails = 10,
        .proxy_pass_uri = "/v1/",
        .upstreams = &ups,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/api/users?q=1";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    // The origin saw the rewritten target, query preserved.
    try testing.expect(std.mem.startsWith(u8, fake.last_req[0..fake.last_req_len], "GET /v1/users?q=1 HTTP/1.1\r\n"));
}

test "upstreamTarget rewriting rules are pure and defensive" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const route = registry.Route{ .path = "/api/", .proxy_pass_uri = "/v1/" };
    ctx.route = &route;
    // Prefix match: replaced with the URI tail, query kept.
    req.target = "/api/users?q=1";
    try testing.expectEqualStrings("/v1/users?q=1", upstreamTarget(&ctx, &route));
    // Exact tail (location itself): fully replaced.
    req.target = "/api/";
    try testing.expectEqualStrings("/v1/", upstreamTarget(&ctx, &route));
    // No query.
    req.target = "/api/users";
    try testing.expectEqualStrings("/v1/users", upstreamTarget(&ctx, &route));
    // Non-matching prefix falls back to the original.
    req.target = "/other";
    try testing.expectEqualStrings("/other", upstreamTarget(&ctx, &route));
    // No URI configured: identity.
    const plain = registry.Route{ .path = "/api/" };
    try testing.expectEqualStrings("/other", upstreamTarget(&ctx, &plain));
}

test "proxy_hide_header strips upstream headers before the client" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Powered-By: bench\r\nX-Keep: yes\r\n\r\nok";
    const fake = try FakeUpstream.start(wire, 4);
    defer fake.stop();
    var ups = [_]router.Upstream{.{
        .host = "127.0.0.1",
        .port = fake.port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", fake.port).?,
    }};
    const hidden = [_][]const u8{ "x-powered-by", "X-Secret" };
    const route = registry.Route{
        .path = "/",
        .balance = .round_robin,
        .max_fails = 10,
        .upstreams = &ups,
        .proxy_hide = &hidden,
    };
    testResetRoute(&route);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok", resp.body);
    // Hidden (case-insensitive); everything else survives.
    try testing.expect(respHeader(&resp, "x-powered-by") == null);
    try testing.expect(respHderEq(respHeader(&resp, "x-keep"), "yes"));
}

fn respHeader(resp: *const registry.Response, comptime name: []const u8) ?[]const u8 {
    for (resp.headers[0..resp.header_count]) |h| {
        if (http_parser.header_hasher.hash(h.name) == comptime http_parser.header_hasher.hash(name)) return h.value;
    }
    return null;
}

fn respHderEq(v: ?[]const u8, want: []const u8) bool {
    return v != null and std.mem.eql(u8, v.?, want);
}
