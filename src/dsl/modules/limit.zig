//! Rate limiting modules (nginx `limit_req`/`limit_conn` equivalents).
//!
//!   limit_req           access phase — leaky bucket per client key:
//!                       `limit_req rate=10 burst=20;` allows a sustained
//!                       10 req/s with room for a burst of 20; excess
//!                       requests get 503.
//!   limit_conn          access phase — per-key in-flight cap:
//!                       `limit_conn 5;` admits at most 5 concurrent
//!                       requests from one key, excess get 503.
//!   limit_conn_release  log phase — releases the slot the paired
//!                       limit_conn acquired for this request (the log
//!                       phase runs as post-processing even after another
//!                       module answered, so every admitted request
//!                       releases exactly once).
//!
//! State is module-owned (framework convention): fixed open-addressing
//! tables keyed by a 64-bit hash of the client IP, guarded by one mutex.
//! The tables are process-wide — nginx uses shared-memory zones for the
//! same job across workers.

const std = @import("std");
const registry = @import("../registry.zig");
const shmem = @import("../shmem.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Zone capacity (power of two, generous for per-IP keys): the shared-
/// memory ceiling for both limit zones. At capacity an UNKNOWN client is
/// refused — fail-closed, the correct at-capacity policy for limiting.
const table_bits = 12;
const table_len = 1 << table_bits;

const ReqState = struct {
    credit_ns: u64,
    last_ns: u64,
};
const ConnState = struct {
    active: u32,
};

var req_zone = shmem.KeyedTable(ReqState, table_len){};
var conn_zone = shmem.KeyedTable(ConnState, table_len){};

fn hashKey(ctx: *Context) u64 {
    // FNV-1a over the dotted client IP; zero IPs (tests, socketpairs)
    // collapse onto one bucket deterministically.
    var h: u64 = 0xcbf29ce484222325;
    for (ctx.client_ip) |b| {
        h ^= b;
        h *%= 0x100000001b3;
        h ^= 0x2e; // '.' separator keeps "1.2.3" vs "12.3" apart
    }
    return h;
}

pub const limit_req = registry.Module{
    .name = "limit_req",
    .phase = .access,
    .run = runReq,
};

pub const limit_conn = registry.Module{
    .name = "limit_conn",
    .phase = .access,
    .run = runConn,
};

pub const limit_conn_release = registry.Module{
    .name = "limit_conn_release",
    .phase = .log,
    .run = runConnRelease,
};

fn reject(ctx: *Context) Action {
    ctx.resp.status = .service_unavailable;
    ctx.resp.setBody(registry.Status.service_unavailable.reasonPhrase());
    return .handled;
}

fn runReq(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.limit_req_rate == 0) return .pass;
    const rate: u64 = route.limit_req_rate;
    const interval_ns = std.time.ns_per_s / rate;
    const burst: u64 = if (route.limit_req_burst != 0) route.limit_req_burst else 1;
    const max_credit_ns = burst * interval_ns;

    const key = hashKey(ctx);
    const now = ctx.now_ns;

    // Leaky bucket in nanosecond credit: a fresh key starts with a FULL
    // bucket — the burst absorbs spikes, first contact is not punished.
    // The whole read-modify-write runs under the zone mutex.
    req_zone.mutex.lock();
    defer req_zone.mutex.unlock();
    const r = req_zone.upsertLocked(key) orelse return reject(ctx);
    if (!r.existed) {
        r.slot.* = .{ .credit_ns = max_credit_ns, .last_ns = now };
    } else if (now > r.slot.last_ns) {
        const elapsed = now - r.slot.last_ns;
        r.slot.last_ns = now;
        r.slot.credit_ns = @min(r.slot.credit_ns + elapsed, max_credit_ns);
    }
    if (r.slot.credit_ns >= interval_ns) {
        r.slot.credit_ns -= interval_ns;
        return .pass;
    }
    // Bucket empty: reject without consuming anything.
    return reject(ctx);
}

fn runConn(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.limit_conn_max == 0) return .pass;
    const key = hashKey(ctx);

    var admitted = false;
    {
        conn_zone.mutex.lock();
        defer conn_zone.mutex.unlock();
        const r = conn_zone.upsertLocked(key) orelse return reject(ctx);
        if (r.slot.active < route.limit_conn_max) {
            r.slot.active += 1;
            admitted = true;
        }
    }
    if (!admitted) return reject(ctx);

    // Mark this request as holding a slot so the release module (log phase,
    // always-run) decrements exactly once.
    ctx.setState("limit_conn", @ptrCast(&acquired_marker));
    return .pass;
}

var acquired_marker: u8 = 0;

fn runConnRelease(ctx: *Context) anyerror!Action {
    if (ctx.getState("limit_conn") != @as(?*anyopaque, @ptrCast(&acquired_marker))) return .pass;
    ctx.setState("limit_conn", null);

    const key = hashKey(ctx);
    conn_zone.mutex.lock();
    defer conn_zone.mutex.unlock();
    if (conn_zone.upsertLocked(key)) |r| {
        if (r.slot.active > 0) r.slot.active -= 1;
    }
    return .pass;
}

const testing = std.testing;
const T0: u64 = 1_000_000_000_000;

const Request = registry.Request;
const Response = registry.Response;
const Status = registry.Status;
const Route = registry.Route;

/// A self-referential triple (ctx points into req/resp), so it must be
/// constructed IN PLACE at its final address.
const Case = struct {
    req: Request,
    resp: Response,
    ctx: Context,
};

fn makeCtx(c: *Case, ip: [4]u8, now_ns: u64) void {
    c.req = Request.init(testing.allocator);
    c.resp = Response.init(.ok);
    c.ctx = Context{ .req = &c.req, .resp = &c.resp };
    c.ctx.client_ip = ip;
    c.ctx.now_ns = now_ns;
}

test "limit_req admits the burst then sheds load, recovering over time" {
    const route = Route{ .path = "/", .limit_req_rate = 100, .limit_req_burst = 10 };
    var c1: Case = undefined;
    makeCtx(&c1, .{ 1, 2, 3, 4 }, T0);
    defer c1.req.deinit();
    const ctx = &c1.ctx;
    ctx.route = &route;

    // Burst of 10 admitted instantly, the 11th within the same instant sheds.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(Action.pass, try runReq(ctx));
    }
    try testing.expectEqual(Action.handled, try runReq(ctx));
    try testing.expectEqual(Status.service_unavailable, c1.resp.status);

    // Half an interval later still shedding...
    ctx.now_ns = T0 + std.time.ns_per_s / 200;
    try testing.expectEqual(Action.handled, try runReq(ctx));
    // ...but after ten full intervals the bucket has drained enough.
    ctx.now_ns = T0 + 10 * std.time.ns_per_s / 100;
    try testing.expectEqual(Action.pass, try runReq(ctx));
}

test "limit_req passes through when unconfigured" {
    const route = Route{ .path = "/" };
    var c1: Case = undefined;
    makeCtx(&c1, .{ 9, 9, 9, 9 }, T0);
    defer c1.req.deinit();
    c1.ctx.route = &route;
    try testing.expectEqual(Action.pass, try runReq(&c1.ctx));
}

test "limit_conn caps concurrency and releases through the log phase" {
    const route = Route{ .path = "/", .limit_conn_max = 2 };
    const other = Route{ .path = "/", .limit_conn_max = 0 };

    var a: Case = undefined;
    makeCtx(&a, .{ 5, 5, 5, 5 }, T0);
    defer a.req.deinit();
    var b: Case = undefined;
    makeCtx(&b, .{ 5, 5, 5, 5 }, T0);
    defer b.req.deinit();
    var c: Case = undefined;
    makeCtx(&c, .{ 5, 5, 5, 5 }, T0);
    defer c.req.deinit();
    a.ctx.route = &route;
    b.ctx.route = &route;
    c.ctx.route = &route;

    try testing.expectEqual(Action.pass, try runConn(&a.ctx));
    try testing.expectEqual(Action.pass, try runConn(&b.ctx));
    // Third concurrent request from the same key sheds.
    try testing.expectEqual(Action.handled, try runConn(&c.ctx));

    // Rejected request holds no slot: releasing it is a no-op.
    try testing.expectEqual(Action.pass, try runConnRelease(&c.ctx));

    // Release both admitted ones; capacity returns.
    try testing.expectEqual(Action.pass, try runConnRelease(&a.ctx));
    try testing.expectEqual(Action.pass, try runConnRelease(&b.ctx));
    try testing.expectEqual(Action.pass, try runConn(&c.ctx));

    // Unconfigured routes never engage (and never hold slots).
    var d: Case = undefined;
    makeCtx(&d, .{ 6, 6, 6, 6 }, T0);
    defer d.req.deinit();
    d.ctx.route = &other;
    try testing.expectEqual(Action.pass, try runConn(&d.ctx));
}

test "different client keys have independent budgets" {
    const route = Route{ .path = "/", .limit_req_rate = 1, .limit_req_burst = 1 };
    var a: Case = undefined;
    makeCtx(&a, .{ 10, 0, 0, 1 }, T0);
    defer a.req.deinit();
    var b: Case = undefined;
    makeCtx(&b, .{ 10, 0, 0, 2 }, T0);
    defer b.req.deinit();
    a.ctx.route = &route;
    b.ctx.route = &route;

    try testing.expectEqual(Action.pass, try runReq(&a.ctx));
    try testing.expectEqual(Action.handled, try runReq(&a.ctx)); // own bucket exhausted
    try testing.expectEqual(Action.pass, try runReq(&b.ctx)); // separate bucket
}
