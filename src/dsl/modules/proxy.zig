const std = @import("std");
const registry = @import("../registry.zig");
const sockets = @import("../../net/sockets.zig");
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
        if (stickyBackendFromCookie(ctx, name, upstreams, route, now_ns)) |idx|
            return parkAt(ctx, route, upstreams, idx, now_ns, false);
    }
    const pick = try pickBackend(route, upstreams, ctx, now_ns) orelse
        return badGateway(ctx);
    return parkAt(ctx, route, upstreams, pick, now_ns, route.sticky_cookie != null);
}

/// Adopt an upstream response into the context (buffer-ownership contract:
/// every slice copied into the request arena — reader memory dies with the
/// transaction). Shared by the inline fast path and the reactor driver.
pub fn adoptUpstream(ctx: *Context, res: anytype, offer_sticky: bool, sticky_name: []const u8, backend_idx: usize) !void {
    ctx.resp.status = @enumFromInt(res.status);
    const arena_a = ctx.req.arena.asAllocator();
    for (res.headers) |h| {
        const skip = switch (http_parser.header_hasher.hash(h.name)) {
            http_parser.header_hasher.hash("connection"),
            http_parser.header_hasher.hash("content-length"),
            http_parser.header_hasher.hash("transfer-encoding"),
            => true,
            else => false,
        };
        if (skip) continue;
        const name_c = arena_a.dupe(u8, h.name) catch return error.OutOfMemory;
        const value_c = arena_a.dupe(u8, h.value) catch return error.OutOfMemory;
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
    var fd = acquirePooled(pick, started_ns);
    if (fd < 0) {
        fd = connectUpstream(up) catch {
            markFailure(pick, route, started_ns);
            return badGateway(ctx);
        };
        setRecvTimeout(fd);
    }
    // Serialize fully NOW (arena-backed) so a parked transaction never
    // touches the parser again.
    const request = buildUpstreamRequest(ctx, up) catch {
        posix_close(fd);
        active[pick] -|= 1;
        markFailure(pick, route, started_ns);
        return badGateway(ctx);
    };

    // HYBRID: try the whole round-trip inline. Fast origins finish right
    // here at sync-driver cost; only real blocks park.
    var sent: usize = 0;
    while (sent < request.len) {
        const n = std.posix.write(fd, request[sent..]) catch |e| switch (e) {
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
                markFailure(pick, route, started_ns);
                return badGateway(ctx);
            },
        };
        sent += n;
    }

    var reader = UpstreamReader{};
    while (true) {
        if (reader.tryParse()) |res| {
            try adoptUpstream(ctx, res, offer_sticky, route.sticky_cookie orelse "", pick);
            upstreamSuccess(pick, fd, nowNs());
            return .handled; // normal serialization follows; NO event hop
        } else |e| switch (e) {
            error.Incomplete => {},
            else => {
                posix_close(fd);
                active[pick] -|= 1;
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
                markFailure(pick, route, started_ns);
                return badGateway(ctx);
            },
        };
        if (got == 0) {
            posix_close(fd);
            active[pick] -|= 1;
            markFailure(pick, route, started_ns);
            return badGateway(ctx);
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

threadlocal var epoch: std.time.Instant = undefined;
threadlocal var epoch_set = false;

/// Monotonic nanoseconds since this thread's first proxy use (the retry
/// windows and pool idle times only need relative comparisons).
/// Public clock for reactor-side transaction deadlines (same epoch).
pub fn currentNs() u64 {
    return nowNs();
}

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
const posix = std.posix;
const posix_fd = std.posix.fd_t;

// Per-reactor state (thread-local: each reactor owns its upstream sockets).
threadlocal var pool: [max_backends]PoolEntry = [_]PoolEntry{.{}} ** max_backends;
threadlocal var active: [max_backends]u32 = [_]u32{0} ** max_backends;
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
var hc_mutex: std.Thread.Mutex = .{};
var hc_routes: std.ArrayList(*const registry.Route) = .empty;
var hc_thread_started: bool = false;

/// Per-reactor slot cache: resolved ONCE per route (under the zone mutex,
/// which also seeds the entry), then every request touches the *BackendState
/// directly — zero locking on the hot path.
threadlocal var hc_cached_route: ?*const registry.Route = null;
threadlocal var hc_cached_slots: [max_backends]?*BackendState = [_]?*BackendState{null} ** max_backends;

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
threadlocal var ewma_ns: [max_backends]u64 = [_]u64{0} ** max_backends;
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
    ensureHealthChecker(route);
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

    // Success: clear passive failures, refresh the EWMA latency sample,
    // then copy the response into ctx.resp.
    if (healthSlot(route, pick)) |slot| {
        slot.fails.store(0, .monotonic);
        slot.last_fail_ns.store(0, .monotonic);
    }
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
    const slot = healthSlot(route, idx) orelse return false;
    if (!slot.alive.load(.acquire)) return false; // only the checker revives
    if (slot.fails.load(.monotonic) < route.max_fails) return true;
    if (route.health_check_path != null) return false; // wait for rise
    // No active checker: honor the passive retry window.
    const last = slot.last_fail_ns.load(.monotonic);
    if (now_ns >= last +% @as(u64, route.fail_timeout_seconds) * std.time.ns_per_s) {
        slot.fails.store(0, .monotonic);
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
    hc_mutex.lock();
    const snapshot = hc_routes.items;
    hc_mutex.unlock();
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

var epoch_zero: std.time.Instant = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };

fn healthThread() void {
    while (true) {
        const t = std.time.Instant.now() catch {
            std.posix.nanosleep(1, 0);
            continue;
        };
        runHealthChecksOnce(t.since(epoch_zero));
        std.posix.nanosleep(0, 250 * std.time.ns_per_ms);
    }
}

/// Default probe: TCP connect; with a `path`, upgrade to a minimal HEAD and
/// require a 2xx/3xx status line.
fn tcpProbe(up: *const router.Upstream, path: []const u8, timeout_s: u32) bool {
    const fd = connectUpstream(up) catch return false;
    defer posix_close(fd);
    setRecvTimeout(fd);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true; // connect-only
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "HEAD {s} HTTP/1.1\r\nHost: zocket-hc\r\nConnection: close\r\n\r\n", .{path}) catch return false;
    var sent: usize = 0;
    while (sent < req.len) {
        sent += std.posix.write(fd, req[sent..]) catch return false;
    }
    var buf: [128]u8 = undefined;
    var got: usize = 0;
    const timeout_ns: u64 = @as(u64, if (timeout_s == 0) 1 else timeout_s) * std.time.ns_per_s;
    const deadline = std.time.Instant.now() catch return false;
    while (got < 12) {
        const n = std.posix.read(fd, buf[got..]) catch return false;
        if (n == 0) break;
        got += n;
        const now = std.time.Instant.now() catch return false;
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
pub fn upstreamSuccess(idx: usize, fd: posix_fd, now_ns: u64) void {
    active[idx] -|= 1;
    pool[idx] = .{ .fd = fd, .last_used_ns = now_ns };
}

pub fn upstreamFail(idx: usize, route: *const registry.Route, now_ns: u64) void {
    active[idx] -|= 1;
    markFailure(idx, route, now_ns);
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

/// Connect timeout for upstream sockets (bounded so a half-dead backend
/// cannot park a reactor thread indefinitely).
const upstream_connect_timeout_ms: i32 = 1000;

fn connectUpstream(up: *const router.Upstream) !posix_fd {
    // Non-blocking + CLOEXEC: the connect completes under a bounded poll,
    // and every later read/write on this fd gets EAGAIN handling instead
    // of parking the reactor thread on a slow backend.
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    errdefer posix_close(fd);
    sockets.setTcpNoDelay(fd);
    std.posix.connect(fd, &up.sockaddr, 16) catch |e| switch (e) {
        error.WouldBlock => {}, // EINPROGRESS: finish under poll below
        else => return e,
    };
    var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&pfds, upstream_connect_timeout_ms) catch return error.ConnectTimeout;
    if (ready == 0) return error.ConnectTimeout;
    var err_bytes: [4]u8 = undefined;
    std.posix.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &err_bytes) catch return error.ConnectFailed;
    if (std.mem.readInt(i32, &err_bytes, .little) != 0) return error.ConnectFailed;
    return fd;
}

/// Wait for readability/up to `timeout_ms`; false on timeout or poll error.
fn waitReadable(fd: posix_fd, timeout_ms: i32) bool {
    var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfds, timeout_ms) catch return false;
    return ready > 0 and (pfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

fn setRecvTimeout(fd: posix_fd) void {
    var tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn posix_close(fd: posix_fd) void {
    std.posix.close(fd);
}

// ---- upstream request forwarding ----

pub var async_supported: bool = false;

fn sendUpstreamRequest(fd: posix_fd, ctx: *Context, up: *const router.Upstream) !void {
    const req = try buildUpstreamRequest(ctx, up);
    var remaining = req;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch |e| switch (e) {
            error.WouldBlock => {
                var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                const ready = std.posix.poll(&pfds, upstream_connect_timeout_ms) catch return error.UpstreamWriteFailed;
                if (ready == 0) return error.UpstreamWriteFailed;
                continue;
            },
            else => return e,
        };
        remaining = remaining[n..];
    }
}

fn buildUpstreamRequest(ctx: *Context, up: *const router.Upstream) ![]const u8 {
    // The shared request memory is a bump arena: building here costs no
    // malloc/free pairs and everything dies with the response (page_allocator
    // here meant an mmap+munmap pair PER REQUEST).
    const allocator = ctx.req.arena.asAllocator();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, methodName(ctx.req.method));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, ctx.req.target);
    try out.appendSlice(allocator, " HTTP/1.1\r\n");

    try out.appendSlice(allocator, "Host: ");
    try out.appendSlice(allocator, up.host);
    var port_buf: [8]u8 = undefined;
    try out.appendSlice(allocator, ":");
    try out.appendSlice(allocator, std.fmt.bufPrint(&port_buf, "{d}\r\n", .{up.port}) catch return error.OutOfMemory);

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
    var cl_buf: [24]u8 = undefined;
    try out.appendSlice(allocator, "Content-Length: ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&cl_buf, "{d}\r\n\r\n", .{ctx.req.body.len}) catch return error.OutOfMemory);
    try out.appendSlice(allocator, ctx.req.body);
    return out.items;
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

pub const UpstreamReader = struct {
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
    pub fn tryParse(self: *UpstreamReader) !Parsed {
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
        for (self.headers[0..self.header_count]) |h| {
            if (http_parser.header_hasher.hash(h.name) == comptime http_parser.header_hasher.hash("content-length")) {
                content_length = std.fmt.parseInt(usize, h.value, 10) catch return error.BadUpstreamResponse;
            }
        }
        if (self.used - self.pos < content_length) {
            // Compact so the next fill appends at a sane offset.
            if (self.pos > 0) {
                const remaining = self.buf[self.pos..self.used];
                std.mem.copyForwards(u8, self.buf[0..remaining.len], remaining);
                self.used -= self.pos;
                self.pos = 0;
            }
            return error.Incomplete;
        }
        const body = self.buf[self.pos .. self.pos + content_length];
        self.pos += content_length;
        return .{ .status = self.status, .headers = self.headers[0..self.header_count], .body = body };
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

    fn fill(self: *UpstreamReader, fd: posix_fd) !usize {
        // WouldBlock propagates: the caller yields back to the event loop
        // and level-triggered readability re-fires this exact spot.
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
    const t = std.time.Instant.now() catch return 0;
    return t.since(epoch_zero);
}

test "tcpProbe distinguishes a live listener from a dead port" {
    const listener = try sockets.createListeningSocket(18933, 4);
    defer posix.close(listener);
    // Accept the probe connection on a side thread (connect-only probe
    // sends nothing and closes).
    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(lfd: std.posix.fd_t) void {
            var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&fds, 2000) catch return;
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const c = sockets.acceptNonBlock(lfd) catch return;
                posix.close(c);
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
        posix.close(tmp_listener);
        const dead = mkUp("127.0.0.1", dead_port);
        if (!tcpProbe(&dead, "", 1)) {
            dead_ok_checked = true;
            break;
        }
    }
    try testing.expect(dead_ok_checked);
}
