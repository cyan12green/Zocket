//! Async DNS resolver: A-record lookup with TTL cache + refresh thread.
//!
//! One detached thread per process (health-checker precedent) owns all
//! network I/O, so reactor threads never block on DNS. Upstreams register
//! their mutable `Upstream` records with a hostname; the thread resolves at
//! registration (synchronously, so startup fails fast on garbage) and
//! re-resolves at TTL expiry, swapping `sockaddr` bytes in place.
//!
//! Wire format lives in `dns.zig`. Nameservers come from the `resolver`
//! directive (Config) or `/etc/resolv.conf` at first use. IPv4 only in v1
//! (the proxy dial path is IPv4-only); AAAA answers are never requested.
const std = @import("std");
const compat = @import("../compat.zig");
const posix = std.posix;
const linux = std.os.linux;
const dns = @import("dns.zig");
const sockets = @import("sockets.zig");
const router = @import("../dsl/router.zig");

/// Per-query UDP timeout (ms) and attempts per nameserver.
pub const query_timeout_ms: i32 = 1000;
pub const attempts_per_server: usize = 2;
/// TTL clamp: never cache longer than this, never shorter than this.
/// (Floor keeps a flapping authoritative from hot-looping us.)
pub const ttl_max_s: u32 = 3600;
pub const ttl_min_s: u32 = 5;
/// Refresh cadence of the background thread.
pub const refresh_interval_ns: u64 = 5 * std.time.ns_per_s;
/// CNAME chase depth per lookup.
pub const max_cname_depth: usize = 4;
/// Hostname cache capacity (distinct names; LRU-ish eviction by expiry).
pub const cache_cap = 256;

pub const ResolveError = error{
    NameError,
    Timeout,
    NoServers,
    Truncated,
    OutOfMemory,
};

/// One cached answer: up to 4 IPv4 addresses + wall-relative expiry on the
/// resolver's monotonic clock.
pub const Entry = struct {
    addrs: [4][4]u8 = @as([4][4]u8, @splat(@as([4]u8, .{ 0, 0, 0, 0 }))),
    count: usize = 0,
    expires_ns: u64 = 0,
};

/// Nameserver list (IPv4 addrs in network order... stored mapped like the
/// rest of the tree for one compare shape).
pub const Servers = struct {
    addrs: [3][16]u8 = @as([3][16]u8, @splat(@as([16]u8, @splat(@as(u8, 0))))),
    len: usize = 0,
};

var servers: Servers = .{};
var servers_set = false;
var servers_mutex = compat.Mutex{};

/// Parse `/etc/resolv.conf` content: `nameserver <ipv4>` lines (first 3
/// win; v6 and garbage skipped in v1). Pure (unit-tested).
pub fn parseResolvConf(text: []const u8) Servers {
    var out = Servers{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "nameserver")) continue;
        const rest = std.mem.trim(u8, line["nameserver".len..], " \t");
        // Bare token only (trailing comments invalidate the line).
        if (std.mem.indexOfAny(u8, rest, " \t#") != null) continue;
        const ip = sockets.parseIpv4(rest) orelse continue;
        if (out.len < out.addrs.len) {
            out.addrs[out.len] = ip;
            out.len += 1;
        }
    }
    return out;
}

/// Effective nameservers right now: explicit ones, else resolv.conf.
/// Empty when neither yields any (no network path at all).
pub fn currentServers() Servers {
    return getServers();
}

/// Explicit nameservers (the `resolver` directive). Overrides resolv.conf.
pub fn setServers(addrs: []const [16]u8) void {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    servers.len = 0;
    for (addrs) |a| {
        if (servers.len < servers.addrs.len) {
            servers.addrs[servers.len] = a;
            servers.len += 1;
        }
    }
    servers_set = true;
}

fn getServers() Servers {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    if (servers_set) return servers;
    // Lazy default: /etc/resolv.conf, once.
    const data = compat.readFileAlloc(std.heap.page_allocator, "/etc/resolv.conf", 64 * 1024) catch return servers;
    defer std.heap.page_allocator.free(data);
    servers = parseResolvConf(data);
    servers_set = true;
    return servers;
}

/// Monotonic ns on the resolver epoch (expiry comparisons only).
var epoch: compat.Instant = undefined;
var epoch_set = false;

fn nowNs() u64 {
    if (!epoch_set) {
        epoch = compat.Instant.now() catch return 0;
        epoch_set = true;
    }
    return (compat.Instant.now() catch return 0).since(epoch);
}

fn serverSockaddr(ip: [16]u8, port: u16, out: *[16]u8) void {
    // AF_INET sockaddr_in laid out in the 16-byte generic slot: family,
    // port (big-endian), then the 4 mapped octets.
    out.* = std.mem.zeroes([16]u8);
    out[0] = 2;
    out[2] = @intCast(port >> 8);
    out[3] = @intCast(port & 0xff);
    @memcpy(out[4..8], ip[12..16]);
}

/// Exchange one query/response with one server. Returns the raw response
/// length in `resp_buf`.
fn exchange(server: [16]u8, port: u16, query: []const u8, resp_buf: []u8) ResolveError!usize {
    const fd = compat.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0) catch return error.Timeout;
    defer compat.close(fd);
    var sa: [16]u8 align(@alignOf(u16)) = undefined;
    serverSockaddr(server, port, &sa);
    compat.connect(fd, @ptrCast(&sa), 16) catch return error.Timeout;
    var attempt: usize = 0;
    while (attempt < attempts_per_server) : (attempt += 1) {
        _ = compat.write(fd, query) catch return error.Timeout;
        var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&pfds, query_timeout_ms) catch return error.Timeout;
        if (ready == 0) continue;
        const n = posix.read(fd, resp_buf) catch continue;
        if (n == 0) continue;
        return n;
    }
    return error.Timeout;
}

/// Resolve `name` to A records right now (blocking): tries each server in
/// turn, follows in-response CNAMEs by re-querying (depth-capped).
/// Returns the addresses + clamped TTL.
pub fn resolveBlocking(name: []const u8, srv: Servers, port: u16) ResolveError!struct { addrs: [4][4]u8, count: usize, ttl_s: u32 } {
    if (srv.len == 0) return error.NoServers;
    var qname_buf: [256]u8 = undefined;
    var qname: []const u8 = name;
    // Strip one trailing dot (presentation form); the codec wants bare names.
    if (qname.len > 0 and qname[qname.len - 1] == '.') qname = qname[0 .. qname.len - 1];
    if (qname.len == 0 or qname.len > 253) return error.NameError;
    var depth: usize = 0;
    // CNAME chase staging: resp (and its cname_buf) dies at the end of
    // each server iteration, so the target is copied here before break.
    var chase_buf: [256]u8 = undefined;
    while (depth <= max_cname_depth) : (depth += 1) {
        if (qname.len >= qname_buf.len) return error.NameError;
        @memcpy(qname_buf[0..qname.len], qname);
        const current: []const u8 = qname_buf[0..qname.len];
        var si: usize = 0;
        while (si < srv.len) : (si += 1) {
            var id_bytes: [2]u8 = undefined;
            compat.randomBytes(&id_bytes);
            const id = std.mem.readInt(u16, &id_bytes, .big);
            var qbuf: [512]u8 = undefined;
            const qlen = dns.buildQuery(id, current, dns.qtype_a, &qbuf);
            if (qlen == 0) return error.NameError;
            var rbuf: [4096]u8 = undefined;
            const rlen = exchange(srv.addrs[si], port, qbuf[0..qlen], &rbuf) catch continue;
            const resp = dns.parseResponse(rbuf[0..rlen], id, dns.qtype_a) orelse continue;
            if (resp.rcode == dns.rcode_name_error) return error.NameError;
            if (resp.rcode != dns.rcode_ok) continue;
            if (resp.addrs_len > 0) {
                var out: [4][4]u8 = @as([4][4]u8, @splat(@as([4]u8, .{ 0, 0, 0, 0 })));
                const n = @min(resp.addrs_len, out.len);
                @memcpy(out[0..n], resp.addrs[0..n]);
                const ttl = @min(@max(if (resp.min_ttl_seen) resp.min_ttl else 60, ttl_min_s), ttl_max_s);
                return .{ .addrs = out, .count = n, .ttl_s = ttl };
            }
            if (resp.cname) |target| {
                // Chase within the depth budget (new query, same servers).
                if (target.len == 0 or target.len >= chase_buf.len) return error.NameError;
                @memcpy(chase_buf[0..target.len], target);
                qname = chase_buf[0..target.len];
                break;
            }
            // NODATA (no error, no answers): try the next server.
        } else {
            // All servers exhausted without answers or CNAME: suspicious
            // but not an NXDOMAIN — report timeout so callers can retry.
            return error.Timeout;
        }
    }
    return error.NameError;
}

// ---- cache + refresh thread ----

var cache_mutex = compat.Mutex{};
var cache_keys: [cache_cap][]const u8 = @as([cache_cap][]const u8, @splat(@as([]const u8, "")));
var cache_vals: [cache_cap]Entry = undefined;
var cache_filled: usize = 0;

/// Look up a cached entry (null on miss/expiry). Exposed for tests and the
/// status surface; the proxy hot path reads its own sockaddr instead.
pub fn lookupCached(name: []const u8, now_ns: u64) ?Entry {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    var i: usize = 0;
    while (i < cache_filled) : (i += 1) {
        if (std.mem.eql(u8, cache_keys[i], name)) {
            if (now_ns >= cache_vals[i].expires_ns) return null;
            return cache_vals[i];
        }
    }
    return null;
}

fn storeCached(name: []const u8, entry: Entry) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    var i: usize = 0;
    while (i < cache_filled) : (i += 1) {
        if (std.mem.eql(u8, cache_keys[i], name)) {
            cache_vals[i] = entry;
            return;
        }
    }
    if (cache_filled < cache_cap) {
        cache_keys[cache_filled] = name;
        cache_vals[cache_filled] = entry;
        cache_filled += 1;
    }
    // At capacity: drop the refresh (fail-open on stale sockaddr bytes the
    // upstream already holds; a miss here never breaks serving).
}

/// A registered hostname: mutable upstream records to rewrite on refresh.
/// `host` aliases the Upstream.host slice (config-lifetime memory); `rec`
/// points at heap-owned Upstream copies (never .rodata — refresh writes).
const Registration = struct {
    host: []const u8,
    recs: [8]*router.Upstream,
    recs_len: usize = 0,
};

var reg_mutex = compat.Mutex{};
var registrations: [64]Registration = undefined;
var registrations_len: usize = 0;
var refresh_started = false;

/// Register a mutable upstream record for background refresh. The first
/// registration spawns the detached refresh thread.
pub fn registerUpstream(host: []const u8, rec: *router.Upstream) void {
    reg_mutex.lock();
    // Coalesce by hostname.
    for (registrations[0..registrations_len]) |*r| {
        if (std.mem.eql(u8, r.host, host)) {
            if (r.recs_len < r.recs.len) {
                r.recs[r.recs_len] = rec;
                r.recs_len += 1;
            }
            reg_mutex.unlock();
            return;
        }
    }
    if (registrations_len < registrations.len) {
        registrations[registrations_len] = .{ .host = host, .recs = undefined, .recs_len = 0 };
        registrations[registrations_len].recs[0] = rec;
        registrations[registrations_len].recs_len = 1;
        registrations_len += 1;
    }
    const already = refresh_started;
    refresh_started = true;
    reg_mutex.unlock();
    if (already) return;
    const th = std.Thread.spawn(.{}, refreshThread, .{}) catch return;
    th.detach();
}

/// Rewrite one record's sockaddr from an A answer: family becomes AF_INET,
/// the port is stamped from the record (family-0 records carry zero port
/// bytes — only the `.port` field), and the 4 address bytes move in.
fn writeSockaddr(rec: *router.Upstream, octets: [4]u8) void {
    rec.sockaddr.family = posix.AF.INET;
    std.mem.writeInt(u16, rec.sockaddr.data[0..2], rec.port, .big);
    @memcpy(rec.sockaddr.data[2..6], &octets);
}

/// Resolve + register one hostname record synchronously (startup path):
/// on success the sockaddr is filled and the record joins background
/// refresh; on failure the record stays unresolved (family 0 → fast 502 /
/// next-upstream) and refresh keeps retrying. Never fails.
pub fn resolveAndRegister(host: []const u8, rec: *router.Upstream, srv: Servers, port: u16) void {
    if (resolveBlocking(host, srv, port)) |res| {
        if (res.count > 0) {
            writeSockaddr(rec, res.addrs[0]);
            storeCached(host, .{
                .addrs = res.addrs,
                .count = res.count,
                .expires_ns = nowNs() + @as(u64, res.ttl_s) * std.time.ns_per_s,
            });
        }
    } else |_| {}
    registerUpstream(host, rec);
}

fn refreshOnce(now_ns: u64) void {
    refreshOnceWith(getServers(), 53, now_ns);
}

/// Refresh with explicit servers/port (the production call is
/// refreshOnce; tests inject a loopback stub here).
pub fn refreshOnceWith(srv: Servers, port: u16, now_ns: u64) void {
    if (srv.len == 0) return;
    // Snapshot the due hosts; resolve WITHOUT holding reg_mutex (network
    // I/O under a lock shared with registration would stall it).
    var due: [64][]const u8 = undefined;
    var due_len: usize = 0;
    reg_mutex.lock();
    for (registrations[0..registrations_len]) |*r| {
        if (lookupCached(r.host, now_ns) != null) continue;
        if (due_len < due.len) {
            due[due_len] = r.host;
            due_len += 1;
        }
    }
    reg_mutex.unlock();
    for (due[0..due_len]) |host| {
        const res = resolveBlocking(host, srv, port) catch continue;
        if (res.count == 0) continue;
        const entry = Entry{
            .addrs = res.addrs,
            .count = res.count,
            .expires_ns = now_ns + @as(u64, res.ttl_s) * std.time.ns_per_s,
        };
        storeCached(host, entry);
        reg_mutex.lock();
        for (registrations[0..registrations_len]) |*r| {
            if (!std.mem.eql(u8, r.host, host)) continue;
            for (r.recs[0..r.recs_len]) |rec| writeSockaddr(rec, res.addrs[0]);
        }
        reg_mutex.unlock();
    }
}

fn refreshThread() void {
    while (true) {
        compat.nanosleep(5, 0);
        refreshOnce(nowNs());
    }
}

const testing = std.testing;

test "resolver parses resolv.conf nameservers" {
    const s = parseResolvConf(
        \\# comment
        \\nameserver 8.8.8.8
        \\nameserver 1.1.1.1 # trailing comment kills the line
        \\nameserver 2001:4860:4860::8888
        \\nameserver not-an-ip
        \\options ndots:1
        \\
    );
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(sockets.parseIpv4("8.8.8.8").?, s.addrs[0]);
    try testing.expectEqual(@as(usize, 0), parseResolvConf("").len);
}

/// Loopback stub DNS server: answers from a canned table. Speaks raw UDP
/// (linux syscalls; the client side uses the connected-UDP exchange).
/// Public so the proxy's hostname end-to-end test can resolve against it
/// instead of duplicating a stub; production never constructs one.
pub const Stub = struct {
    fd: posix.fd_t,
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start() !*Stub {
        const self = try testing.allocator.create(Stub);
        const fd = try compat.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
        var sa: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        sa[0] = 2;
        sa[4] = 127;
        sa[7] = 1;
        try compat.bind(fd, @ptrCast(&sa), 16);
        var slen: posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try compat.getsockname(fd, @ptrCast(&bound), &slen);
        self.* = .{ .fd = fd, .port = (@as(u16, bound[2]) << 8) | bound[3] };
        const t = try std.Thread.spawn(.{}, runFn, .{self});
        t.detach();
        return self;
    }

    fn runFn(self: *Stub) void {
        var qbuf: [512]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var src: linux.sockaddr = undefined;
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr);
            const rc = linux.recvfrom(self.fd, qbuf[0..].ptr, qbuf.len, 0, &src, &slen);
            if (linux.errno(rc) != .SUCCESS) {
                compat.nanosleep(0, 5 * std.time.ns_per_ms);
                continue;
            }
            const qlen: usize = @intCast(rc);
            var rbuf: [512]u8 = undefined;
            const rlen = buildStubReply(qbuf[0..qlen], &rbuf) orelse continue;
            _ = linux.sendto(self.fd, rbuf[0..].ptr, rlen, 0, &src, slen);
        }
    }

    pub fn stopStub(self: *Stub) void {
        self.stop.store(true, .release);
        compat.close(self.fd);
        testing.allocator.destroy(self);
    }
};

/// Canned table: test→A 10.99.99.99 (TTL 100000, exercises the clamp);
/// alias→CNAME test + its A; missing→NXDOMAIN; anything else NODATA.
fn buildStubReply(query: []const u8, out: []u8) ?usize {
    if (query.len < 12) return null;
    const id = std.mem.readInt(u16, query[0..2], .big);
    const qend = dns.skipName(query, 12) orelse return null;
    if (qend + 4 > query.len) return null;
    var qname: [256]u8 = undefined;
    const qn_len = dns.expandName(query, 12, &qname) orelse return null;
    const qn = qname[0..qn_len];
    // Header: echo ID; question echoed verbatim at offset 12.
    std.mem.writeInt(u16, out[0..2], id, .big);
    const qlen = qend + 4 - 12;
    @memcpy(out[12 .. 12 + qlen], query[12 .. qend + 4]);
    var pos: usize = 12 + qlen;
    var ancount: u16 = 0;
    const emit_a = struct {
        fn call(o: []u8, p: usize, ttl: u32, a: u8, b: u8, c: u8, d: u8) usize {
            // NAME=ptr to question, A/IN/ttl/4/addr.
            o[p] = 0xC0;
            o[p + 1] = 12;
            std.mem.writeInt(u16, o[p + 2 ..][0..2], dns.qtype_a, .big);
            std.mem.writeInt(u16, o[p + 4 ..][0..2], dns.qclass_in, .big);
            std.mem.writeInt(u32, o[p + 6 ..][0..4], ttl, .big);
            std.mem.writeInt(u16, o[p + 10 ..][0..2], 4, .big);
            o[p + 12] = a;
            o[p + 13] = b;
            o[p + 14] = c;
            o[p + 15] = d;
            return p + 16;
        }
    }.call;
    if (std.mem.eql(u8, qn, "test")) {
        pos = emit_a(out, pos, 100000, 10, 99, 99, 99);
        ancount = 1;
    } else if (std.mem.eql(u8, qn, "loopback")) {
        pos = emit_a(out, pos, 60, 127, 0, 0, 1);
        ancount = 1;
    } else if (std.mem.eql(u8, qn, "alias")) {
        // CNAME alias -> test (TTL 60), then the A (TTL 60).
        out[pos] = 0xC0;
        out[pos + 1] = 12;
        std.mem.writeInt(u16, out[pos + 2 ..][0..2], dns.qtype_cname, .big);
        std.mem.writeInt(u16, out[pos + 4 ..][0..2], dns.qclass_in, .big);
        std.mem.writeInt(u32, out[pos + 6 ..][0..4], 60, .big);
        const t = [_]u8{ 4, 't', 'e', 's', 't', 0 };
        std.mem.writeInt(u16, out[pos + 10 ..][0..2], @intCast(t.len), .big);
        @memcpy(out[pos + 12 ..][0..t.len], &t);
        pos += 12 + t.len;
        pos = emit_a(out, pos, 60, 10, 99, 99, 99);
        ancount = 2;
    } else if (std.mem.eql(u8, qn, "missing")) {
        std.mem.writeInt(u16, out[2..4], 0x8183, .big); // NXDOMAIN
        std.mem.writeInt(u16, out[4..6], 1, .big);
        std.mem.writeInt(u16, out[6..8], 0, .big);
        std.mem.writeInt(u16, out[8..10], 0, .big);
        std.mem.writeInt(u16, out[10..12], 0, .big);
        return pos;
    } else {
        // NODATA: rcode 0, no answers.
    }
    std.mem.writeInt(u16, out[2..4], 0x8180, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], ancount, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    return pos;
}


test "resolver answers A, CNAME, NXDOMAIN and NODATA from the stub" {
    const stub = try Stub.start();
    defer stub.stopStub();
    // The stub's ephemeral port is plumbed by rebinding the exchange path:
    // resolveBlocking takes the port explicitly for exactly this reason.
    var srv = Servers{};
    srv.addrs[0] = sockets.parseIpv4("127.0.0.1").?;
    srv.len = 1;

    const a = try resolveBlocking("test", srv, stub.port);
    try testing.expectEqual(@as(usize, 1), a.count);
    try testing.expectEqual([4]u8{ 10, 99, 99, 99 }, a.addrs[0]);
    // Stub TTL 100000 clamps to the 3600 ceiling.
    try testing.expectEqual(@as(u32, 3600), a.ttl_s);

    const c = try resolveBlocking("alias", srv, stub.port);
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqual([4]u8{ 10, 99, 99, 99 }, c.addrs[0]);
    try testing.expectEqual(@as(u32, 60), c.ttl_s);

    try testing.expectError(error.NameError, resolveBlocking("missing", srv, stub.port));
    // NODATA (rcode 0, no answers, no CNAME) surfaces as Timeout so
    // callers retry rather than caching a negative.
    try testing.expectError(error.Timeout, resolveBlocking("other", srv, stub.port));
}

test "resolver resolveAndRegister fills sockaddr, caches and registers" {
    const stub = try Stub.start();
    defer stub.stopStub();
    var srv = Servers{};
    srv.addrs[0] = sockets.parseIpv4("127.0.0.1").?;
    srv.len = 1;
    var rec = router.Upstream{ .host = "test", .port = 8001, .hostname = "test" };
    try testing.expectEqual(@as(u16, 0), rec.sockaddr.family);
    resolveAndRegister("test", &rec, srv, stub.port);
    try testing.expectEqual(@as(u16, 2), rec.sockaddr.family); // AF_INET
    try testing.expect(std.mem.eql(u8, &[_]u8{ 10, 99, 99, 99 }, rec.sockaddr.data[2..6]));
    // Startup prime cached it (refresh skips a fresh entry).
    try testing.expect(lookupCached("test", nowNs()) != null);
}

test "resolver times out against a dead port and rejects empty server lists" {
    // Reserve-then-close a UDP port so nothing answers on it.
    const fd = try compat.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    var sa: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    sa[0] = 2;
    sa[4] = 127;
    sa[7] = 1;
    try compat.bind(fd, @ptrCast(&sa), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try compat.getsockname(fd, @ptrCast(&bound), &slen);
    const dead = (@as(u16, bound[2]) << 8) | bound[3];
    compat.close(fd);

    var srv = Servers{};
    srv.addrs[0] = sockets.parseIpv4("127.0.0.1").?;
    srv.len = 1;
    try testing.expectError(error.Timeout, resolveBlocking("test", srv, dead));
    try testing.expectError(error.NoServers, resolveBlocking("test", Servers{}, dead));
    try testing.expectError(error.NameError, resolveBlocking("", srv, dead));
}

test "resolver cache honors expiry and stores answers" {
    const now = nowNs();
    const name = "cache-unit-test.invalid";
    try testing.expect(lookupCached(name, now) == null);
    storeCached(name, .{
        .addrs = .{ .{ 1, 2, 3, 4 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
        .count = 1,
        .expires_ns = now + 60 * std.time.ns_per_s,
    });
    const hit = lookupCached(name, now).?;
    try testing.expectEqual(@as(usize, 1), hit.count);
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, hit.addrs[0]);
    // Expired: miss.
    try testing.expect(lookupCached(name, now + 61 * std.time.ns_per_s) == null);
}
