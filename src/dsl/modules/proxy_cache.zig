//! Response caching (nginx `proxy_cache` equivalent) for proxied routes,
//! built on the bounded shmem.LruStore zone — hard byte/entry ceilings, LRU
//! eviction, nothing grows under load.
//!
//! Config (directive presence binds both halves):
//!   proxy_cache on;                          — enable
//!   proxy_cache_valid 60;                    — fresh window (seconds)
//!   proxy_cache_stale_while_revalidate 30;   — grace past expiry
//! Chain placement: bind BEFORE the proxy module (same rewrite phase,
//! declaration order): `rewrite proxy_cache; rewrite proxy;`
//!
//! Semantics (v1, synchronous):
//!   fresh      -> 200 from store                     [X-Cache: HIT]
//!   expired    -> forward with injected If-None-Match when an ETag is
//!                 known; a 304 from upstream is converted back to the
//!                 stored 200 by the storer        [X-Cache: REVALIDATED]
//!   miss       -> upstream 200 gets stored           [X-Cache: MISS]
//!   grace      -> expired-but-within-grace serves stale immediately
//!                                                    [X-Cache: STALE]
//! GET/HEAD only; requests carrying Authorization bypass entirely.

const std = @import("std");
const registry = @import("../registry.zig");
const shmem = @import("../shmem.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Zone ceilings (bounded-memory contract): 256 entries / 32 MiB of bodies
/// across every cached route. Follow-up: plumb Limits overrides here.
const max_entries = 256;

const default_entries: usize = 256;

var store_mutex: std.Thread.Mutex = .{};
var store: ?shmem.LruStore = null;
var store_budget: usize = 0;
var store_entries_cap: usize = 0;

/// Zone sizing comes from the config `limits` (runtime knobs): byte budget
/// plus entry count. Changing either re-creates the zone (contents are
/// dropped — a cache, so failing open into misses is correct).
fn getStore(budget: usize, max_entries_override: usize) !*shmem.LruStore {
    const cap = if (max_entries_override != 0) max_entries_override else default_entries;
    store_mutex.lock();
    defer store_mutex.unlock();
    if (store == null or budget != store_budget or cap != store_entries_cap) {
        if (store != null) store.?.deinit();
        // Entry-count ceiling stays bounded even on absurd configs.
        store = try shmem.LruStore.init(std.heap.page_allocator, budget, @min(cap, 1 << 20));
        store_budget = budget;
        store_entries_cap = cap;
    }
    return &store.?;
}

fn budgetFor(ctx: *Context) struct { bytes: usize, entries: usize } {
    const def_bytes: usize = 32 * 1024 * 1024;
    if (ctx.limits) |lim| {
        return .{
            .bytes = if (lim.proxy_cache_max_bytes != 0) lim.proxy_cache_max_bytes else def_bytes,
            .entries = lim.proxy_cache_max_entries,
        };
    }
    return .{ .bytes = def_bytes, .entries = default_entries };
}

const Header = extern struct {
    len: u16,
    // followed by: name bytes then value bytes
};

/// Blob layout: status(u16) etag_len(u16) ctype_len(u16)
///              [etag][ctype][body]  — lengths exclude NULs.
const Serialized = struct {
    status: u16,
    etag: []const u8,
    ctype: []const u8,
    body: []const u8,
};

fn serialize(buf: []u8, s: Serialized) ?usize {
    if (s.etag.len > std.math.maxInt(u16) or s.ctype.len > std.math.maxInt(u16)) return null;
    const need = 6 + s.etag.len + s.ctype.len + s.body.len;
    if (need > buf.len) return null;
    std.mem.writeInt(u16, buf[0..2], s.status, .big);
    std.mem.writeInt(u16, buf[2..4], @intCast(s.etag.len), .big);
    std.mem.writeInt(u16, buf[4..6], @intCast(s.ctype.len), .big);
    var pos: usize = 6;
    @memcpy(buf[pos..][0..s.etag.len], s.etag);
    pos += s.etag.len;
    @memcpy(buf[pos..][0..s.ctype.len], s.ctype);
    pos += s.ctype.len;
    @memcpy(buf[pos..][0..s.body.len], s.body);
    return need;
}

fn deserialize(blob: []const u8) ?Serialized {
    if (blob.len < 6) return null;
    const status = std.mem.readInt(u16, blob[0..2], .big);
    const etag_len = std.mem.readInt(u16, blob[2..4], .big);
    const ctype_len = std.mem.readInt(u16, blob[4..6], .big);
    if (blob.len < 6 + etag_len + ctype_len) return null;
    const etag = blob[6 .. 6 + etag_len];
    const ctype = blob[6 + etag_len .. 6 + etag_len + ctype_len];
    const body = blob[6 + etag_len + ctype_len ..];
    return .{ .status = status, .etag = etag, .ctype = ctype, .body = body };
}

fn cacheableRequest(ctx: *Context) bool {
    return switch (ctx.req.method) {
        .get, .head => true,
        else => false,
    } and ctx.req.header("authorization") == null;
}

fn cacheKey(ctx: *Context) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (ctx.req.target) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    h ^= @intFromEnum(ctx.req.method);
    return h;
}

fn routeTtl(route: *const registry.Route) u64 {
    if (route.cache_ttl_seconds == 0) return 60; // sane default when unset
    return route.cache_ttl_seconds;
}

fn applyStored(ctx: *Context, s: Serialized, label: []const u8) void {
    ctx.resp.status = @enumFromInt(s.status);
    ctx.resp.body = s.body;
    if (s.ctype.len > 0) ctx.resp.setHeader("Content-Type", s.ctype);
    if (s.etag.len > 0) ctx.resp.setHeader("ETag", s.etag);
    ctx.resp.setHeader("X-Cache", label);
}

pub const proxy_cache = registry.Module{
    .name = "proxy_cache",
    .phase = .rewrite,
    .run = runLookup,
};

pub const proxy_cache_store = registry.Module{
    .name = "proxy_cache_store",
    .kind = .filter,
    .run = runStore,    // Legacy marker only: filters run after the walk.
    .phase = .log,
};

fn enabled(ctx: *Context) ?*const registry.Route {
    const route = ctx.route orelse return null;
    if (!route.proxy_cache_enabled) return null;
    return route;
}

fn runLookup(ctx: *Context) anyerror!Action {
    const route = enabled(ctx) orelse return .pass;
    _ = route;
    if (!cacheableRequest(ctx)) return .pass;

    const key = cacheKey(ctx);
    const now = ctx.now_ns;
    const z = budgetFor(ctx);
    const st = getStore(z.bytes, z.entries) catch return error.OutOfMemory;
    const e = st.lookup(key) orelse return .pass; // MISS: proxy takes over
    // Copy into the request arena immediately: the store entry can be
    // evicted (freed) by another reactor thread the moment we drop the
    // zone mutex; serving from store memory would race that free.
    const blob = ctx.sharedDupe(e.bytes) orelse return error.OutOfMemory;

    const s = deserialize(blob) orelse return .pass;
    const ttl_ns = @as(u64, routeTtl(ctx.route.?)) * std.time.ns_per_s;
    const swr_ns = @as(u64, ctx.route.?.cache_swr_seconds) * std.time.ns_per_s;
    const age = now -% e.meta; // meta = stored_at_ns

    if (age < ttl_ns) {
        applyStored(ctx, s, "HIT");
        return .handled;
    }
    if (age < ttl_ns + swr_ns) {
        // Grace window: serve stale now; the NEXT request goes conditional.
        applyStored(ctx, s, "STALE");
        return .handled;
    }

    // Expired beyond grace: revalidate conditionally when we hold an ETag
    // and the client did not send its own validators.
    if (s.etag.len > 0 and ctx.req.header("if-none-match") == null) {
        ctx.req.addHeaderParsed("If-None-Match", s.etag) catch {};
    }
    return .pass; // proxy forwards; the storer interprets the verdict
}

fn runStore(ctx: *Context) anyerror!Action {
    const route = enabled(ctx) orelse return .pass;
    _ = route;
    const z = budgetFor(ctx);
    if (!cacheableRequest(ctx)) return .pass;
    // Cache-served responses (HIT/STALE) reach here too — the log phase
    // runs after every outcome. Re-storing them replaces the live blob
    // other reactors are reading (the benchmark-suite segfault); only
    // genuine origin responses enter the store.
    for (ctx.resp.headers[0..ctx.resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Cache")) return .pass;
    }

    const key = cacheKey(ctx);
    const now = ctx.now_ns;

    if (ctx.resp.status == .not_modified) {
        // Upstream confirmed our validator: refresh freshness of the stored
        // representation and answer the CLIENT from the store (200).
        const st304 = try getStore(z.bytes, z.entries);
        if (st304.getCopy(key, ctx.req.arena.asAllocator())) |got| {
            if (deserialize(got.bytes)) |old| {
                applyStored(ctx, old, "REVALIDATED");
                // Refresh stored_at_ns by re-putting the ARENA copy; the
                // old store bytes were released inside put() safely (we
                // hold our own duplicate).
                const st_put = try getStore(z.bytes, z.entries);
                _ = st_put.put(key, got.bytes, now, 0);
            }
        }
        return .pass;
    }

    if (ctx.resp.status != .ok) return .pass;
    if (ctx.resp.body_owned) return .pass; // streaming/owned bodies skipped

    // Serialize the representation worth caching.
    var etag: []const u8 = "";
    var ctype: []const u8 = "";
    for (ctx.resp.headers[0..ctx.resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag")) etag = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) ctype = h.value;
    }
    const need = 6 + etag.len + ctype.len + ctx.resp.body.len;
    const buf = ctx.sharedAlloc(need) orelse return error.OutOfMemory;
    const written = serialize(buf, .{
        .status = @intFromEnum(ctx.resp.status),
        .etag = etag,
        .ctype = ctype,
        .body = ctx.resp.body,
    }) orelse return .pass;

    const st = getStore(z.bytes, z.entries) catch return error.OutOfMemory;
    _ = st.put(key, buf[0..written], now, 0); // meta = stored_at_ns
    return .pass;
}

const testing = std.testing;
const Request = registry.Request;
const Method = @import("../../http/parser.zig").Method;
const Response = registry.Response;
const Route = registry.Route;
const T0: u64 = 1_000_000_000_000;

fn resetZone() void {
    store_mutex.lock();
    if (store) |*st| st.deinit();
    store = null;
    store_budget = 0;
    store_entries_cap = 0;
    store_mutex.unlock();
}

/// Self-referential triple: constructed IN PLACE at its final address
/// (returning it by value would dangle ctx.req/ctx.resp).
const Case = struct { req: Request, resp: Response, ctx: Context };

fn makeCase(c: *Case, method: Method, target: []const u8) void {
    c.req = Request.init(testing.allocator);
    c.req.method = method;
    c.req.target = target;
    c.req.decoded_target = target;
    c.resp = Response.init(.ok);
    c.ctx = Context{ .req = &c.req, .resp = &c.resp };
    c.ctx.now_ns = T0;
}

test "serialize/deserialize round-trips representations" {
    var buf: [256]u8 = undefined;
    const n = serialize(&buf, .{
        .status = 200,
        .etag = "\"abc\"",
        .ctype = "text/html",
        .body = "<h1>hi</h1>",
    }) orelse return error.NoSpace;
    const s = deserialize(buf[0..n]) orelse return error.Corrupt;
    try testing.expectEqual(@as(u16, 200), s.status);
    try testing.expectEqualStrings("\"abc\"", s.etag);
    try testing.expectEqualStrings("text/html", s.ctype);
    try testing.expectEqualStrings("<h1>hi</h1>", s.body);
}

test "miss stores, fresh hit serves, POST and auth bypass" {
    resetZone();
    defer resetZone();
    const route = Route{
        .path = "/p",
        .proxy_cache_enabled = true,
        .upstreams = &.{.{ .host = "127.0.0.1", .port = 9 }},
    };

    // Simulate an origin 200 flowing through the storer.
    var m1: Case = undefined;
    makeCase(&m1, .get, "/p/data");
    defer m1.req.deinit();
    m1.ctx.route = &route;
    m1.ctx.resp.setBody("payload");
    m1.ctx.resp.setHeader("Content-Type", "text/plain");
    m1.ctx.resp.setHeader("ETag", "\"v1\"");
    try testing.expectEqual(Action.pass, try runStore(&m1.ctx));
    try testing.expectEqualStrings("payload", m1.ctx.resp.body);

    // A later GET hits.
    var m2: Case = undefined;
    makeCase(&m2, .get, "/p/data");
    defer m2.req.deinit();
    m2.ctx.route = &route;
    m2.ctx.now_ns = T0 + 1000;
    try testing.expectEqual(Action.handled, try runLookup(&m2.ctx));
    try testing.expectEqualStrings("payload", m2.ctx.resp.body);
    try testing.expectEqualStrings("HIT", headerOf(m2.ctx.resp, "X-Cache").?);

    // POSTs never cache nor hit.
    var m3: Case = undefined;
    makeCase(&m3, .post, "/p/data");
    defer m3.req.deinit();
    m3.ctx.route = &route;
    try testing.expectEqual(Action.pass, try runLookup(&m3.ctx));

    // Authorized requests bypass entirely.
    var m4: Case = undefined;
    makeCase(&m4, .get, "/p/data");
    defer m4.req.deinit();
    m4.req.addHeaderParsed("Authorization", "Basic abc") catch unreachable;
    m4.ctx.route = &route;
    try testing.expectEqual(Action.pass, try runLookup(&m4.ctx));
}

test "expired entry revalidates: 304 converts back to the stored 200" {
    resetZone();
    defer resetZone();
    const route = Route{
        .path = "/r",
        .proxy_cache_enabled = true,
        .cache_ttl_seconds = 10,
        .upstreams = &.{.{ .host = "127.0.0.1", .port = 9 }},
    };

    var seed: Case = undefined;
    makeCase(&seed, .get, "/r/x");
    defer seed.req.deinit();
    seed.ctx.route = &route;
    seed.ctx.resp.setBody("stable");
    seed.ctx.resp.setHeader("ETag", "\"W/xyz\"");
    try testing.expectEqual(Action.pass, try runStore(&seed.ctx));

    // Past TTL: lookup passes through but injects our validator.
    var probe: Case = undefined;
    makeCase(&probe, .get, "/r/x");
    defer probe.req.deinit();
    probe.ctx.route = &route;
    probe.ctx.now_ns = T0 + 11 * std.time.ns_per_s;
    try testing.expectEqual(Action.pass, try runLookup(&probe.ctx));
    const inm = probe.ctx.req.header("if-none-match") orelse return error.MissingValidator;
    try testing.expectEqualStrings("\"W/xyz\"", inm);

    // Origin answers 304: the storer restores the stored representation.
    var done: Case = undefined;
    makeCase(&done, .get, "/r/x");
    defer done.req.deinit();
    done.ctx.route = &route;
    done.ctx.now_ns = T0 + 11 * std.time.ns_per_s;
    done.ctx.resp.status = .not_modified;
    try testing.expectEqual(Action.pass, try runStore(&done.ctx));
    try testing.expectEqual(registry.Status.ok, done.ctx.resp.status);
    try testing.expectEqualStrings("stable", done.ctx.resp.body);
    try testing.expectEqualStrings("REVALIDATED", headerOf(done.ctx.resp, "X-Cache").?);
}

test "grace window serves stale" {
    resetZone();
    defer resetZone();
    const route = Route{
        .path = "/g",
        .proxy_cache_enabled = true,
        .cache_ttl_seconds = 10,
        .cache_swr_seconds = 30,
        .upstreams = &.{.{ .host = "127.0.0.1", .port = 9 }},
    };
    var seed: Case = undefined;
    makeCase(&seed, .get, "/g/x");
    defer seed.req.deinit();
    seed.ctx.route = &route;
    seed.ctx.resp.setBody("old-but-fine");
    try testing.expectEqual(Action.pass, try runStore(&seed.ctx));

    var late: Case = undefined;
    makeCase(&late, .get, "/g/x");
    defer late.req.deinit();
    late.ctx.route = &route;
    late.ctx.now_ns = T0 + 15 * std.time.ns_per_s; // expired, inside grace
    try testing.expectEqual(Action.handled, try runLookup(&late.ctx));
    try testing.expectEqualStrings("old-but-fine", late.ctx.resp.body);
    try testing.expectEqualStrings("STALE", headerOf(late.ctx.resp, "X-Cache").?);
}

test "HIT responses are not re-stored (benchmark-suite segfault regression)" {
    resetZone();
    defer resetZone();
    const route = Route{
        .path = "/p",
        .proxy_cache_enabled = true,
        .upstreams = &.{.{ .host = "127.0.0.1", .port = 9 }},
    };

    // Origin response seeds the store.
    var seed: Case = undefined;
    makeCase(&seed, .get, "/p/x");
    defer seed.req.deinit();
    seed.ctx.route = &route;
    seed.ctx.resp.setBody("payload");
    try testing.expectEqual(Action.pass, try runStore(&seed.ctx));

    // The stored blob's identity BEFORE the hit.
    var before: [*]u8 = undefined;
    {
        store_mutex.lock();
        defer store_mutex.unlock();
        for (store.?.entries) |*e| {
            if (e.used and e.key == cacheKey(&seed.ctx)) before = e.bytes.ptr;
        }
    }

    // A HIT serves from the store; the storer then sees X-Cache and skips.
    var hit: Case = undefined;
    makeCase(&hit, .get, "/p/x");
    defer hit.req.deinit();
    hit.ctx.route = &route;
    try testing.expectEqual(Action.handled, try runLookup(&hit.ctx));
    try testing.expectEqualStrings("HIT", headerOf(hit.ctx.resp, "X-Cache").?);
    try testing.expectEqual(Action.pass, try runStore(&hit.ctx));

    // The original blob was NOT freed/replaced underneath anyone reading it.
    var after_same = false;
    store_mutex.lock();
    defer store_mutex.unlock();
    for (store.?.entries) |*e| {
        if (e.used and e.key == cacheKey(&hit.ctx)) after_same = e.bytes.ptr == before;
    }
    try testing.expect(after_same);
}

fn headerOf(resp: *const Response, name: []const u8) ?[]const u8 {
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}
