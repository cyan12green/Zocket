//! TCP stream proxy with SNI preread routing (C3, v1).
//!
//! L4 `stream { server { listen; proxy_pass; sni; } }` support: accept a TCP
//! connection, MSG_PEEK the first bytes, route on the ClientHello SNI via
//! `selectSni` (exact, then `*.suffix` wildcard, then the default), dial
//! the backend and `relayPair` both directions until EOF or the idle
//! timeout. v1 runs one thread per connection (fine for modest counts;
//! reactor-integrated L4 rides the Stage-2 upstream seam).

const std = @import("std");
const sys = @import("../sys.zig");
const sni_mod = @import("sni.zig");

/// One SNI route inside a stream server block.
pub const SniRoute = struct {
    /// Exact name ("api.example.com") or wildcard ("*.example.com").
    pattern: []const u8,
    /// Backend sockaddr (resolved at config load; literals or resolver).
    addr: [16]u8,
    addr_len: u32,
};

/// Select the backend index for `name`: exact match first, then the
/// longest `*.suffix` wildcard, else null (caller uses the default).
/// Pure (unit-tested).
pub fn selectSni(routes: []const SniRoute, name: []const u8) ?usize {
    for (routes, 0..) |r, i| {
        if (!std.mem.startsWith(u8, r.pattern, "*.")) {
            if (std.ascii.eqlIgnoreCase(r.pattern, name)) return i;
        }
    }
    var best: ?usize = null;
    var best_len: usize = 0;
    for (routes, 0..) |r, i| {
        if (!std.mem.startsWith(u8, r.pattern, "*.")) continue;
        const suffix = r.pattern[1..]; // ".example.com"
        if (name.len > suffix.len and std.ascii.eqlIgnoreCase(name[name.len - suffix.len ..], suffix)) {
            if (suffix.len > best_len) {
                best_len = suffix.len;
                best = i;
            }
        }
    }
    return best;
}

/// Copy both directions between two blocking fds until either side EOFs
/// (or errors / the idle deadline passes). Single-threaded poll loop.
pub fn relayPair(a: std.posix.fd_t, b: std.posix.fd_t, idle_ms: i32) void {
    var buf_a: [8192]u8 = undefined;
    var buf_b: [8192]u8 = undefined;
    var pa: usize = 0; // bytes staged a->b
    var pb: usize = 0; // bytes staged b->a
    var oa: usize = 0; // consumed offset a->b
    var ob: usize = 0; // consumed offset b->a
    var iters: usize = 0;
    while (true) {
        iters += 1;
        var pfds = [_]std.posix.pollfd{
            .{ .fd = a, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = b, .events = std.posix.POLL.IN, .revents = 0 },
        };
        // Only poll OUT when we hold staged bytes for that direction.
        if (pa > oa) pfds[1].events |= std.posix.POLL.OUT;
        if (pb > ob) pfds[0].events |= std.posix.POLL.OUT;
        const ready = std.posix.poll(&pfds, idle_ms) catch {
            return;
        };
        if (ready == 0) return; // idle timeout
        // Flush staged bytes first.
        if (pa > oa and (pfds[1].revents & std.posix.POLL.OUT) != 0) {
            const n = sys.write(b, buf_a[oa..pa]) catch return;
            oa += n;
            if (oa == pa) {
                oa = 0;
                pa = 0;
            }
        }
        if (pb > ob and (pfds[0].revents & std.posix.POLL.OUT) != 0) {
            const n = sys.write(a, buf_b[ob..pb]) catch return;
            ob += n;
            if (ob == pb) {
                ob = 0;
                pb = 0;
            }
        }
        if ((pfds[0].revents & std.posix.POLL.IN) != 0 and pa < buf_a.len) {
            const n = std.posix.read(a, buf_a[pa..]) catch return;
            if (n == 0) return; // client EOF
            pa += n;
            // Opportunistic immediate forward.
            const m = sys.write(b, buf_a[oa..pa]) catch return;
            oa += m;
            if (oa == pa) {
                oa = 0;
                pa = 0;
            }
        }
        if ((pfds[1].revents & std.posix.POLL.IN) != 0 and pb < buf_b.len) {
            const n = std.posix.read(b, buf_b[pb..]) catch return;
            if (n == 0) return; // upstream EOF
            pb += n;
            const m = sys.write(a, buf_b[ob..pb]) catch return;
            ob += m;
            if (ob == pb) {
                ob = 0;
                pb = 0;
            }
        }
        // HUP/ERR end the relay; POLLNVAL too (a peer closed under us —
        // polling a dead fd would otherwise spin forever; NVAL is absent
        // from std.posix.POLL in this snapshot, hence the literal).
        const done_mask = std.posix.POLL.HUP | std.posix.POLL.ERR | 0x020;
        if ((pfds[0].revents & done_mask) != 0) return;
        if ((pfds[1].revents & done_mask) != 0) return;
    }
}

/// Peek up to 4 KiB (MSG_PEEK: bytes stay queued), extract SNI, and return
/// the selected route index (or default_idx when no SNI / no match).
/// Pure I/O helper (unit-tested over socketpairs).
pub fn peekRoute(fd: std.posix.fd_t, routes: []const SniRoute, default_idx: usize) usize {
    var buf: [4096]u8 = undefined;
    // MSG_PEEK = 0x2: bytes stay queued for the relay handoff.
    const rc = std.os.linux.recvfrom(fd, &buf, buf.len, 0x2, null, null);
    const n: usize = switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return default_idx,
    };
    if (n == 0) return default_idx;
    const name = sni_mod.peekServerName(buf[0..n]) orelse return default_idx;
    return selectSni(routes, name) orelse default_idx;
}

const testing = std.testing;

fn mkRoute(pattern: []const u8) SniRoute {
    return .{ .pattern = pattern, .addr = std.mem.zeroes([16]u8), .addr_len = 0 };
}

test "sni routing prefers exact over wildcard over default" {
    const routes = [_]SniRoute{ mkRoute("*.example.com"), mkRoute("api.example.com"), mkRoute("*.sub.example.com") };
    try testing.expectEqual(@as(?usize, 1), selectSni(&routes, "api.example.com"));
    try testing.expectEqual(@as(?usize, 0), selectSni(&routes, "other.example.com"));
    try testing.expectEqual(@as(?usize, 2), selectSni(&routes, "a.sub.example.com"));
    try testing.expectEqual(@as(?usize, null), selectSni(&routes, "unrelated.org"));
    // Case-insensitive.
    try testing.expectEqual(@as(?usize, 1), selectSni(&routes, "API.EXAMPLE.COM"));
    // Bare suffix without a label is not a wildcard match.
    try testing.expectEqual(@as(?usize, null), selectSni(&routes, "example.com"));
}

test "peekRoute falls back on plain HTTP" {
    const pair = try sys.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    _ = try sys.write(pair[1], "GET / HTTP/1.1\r\n\r\n");
    const routes = [_]SniRoute{mkRoute("a.example")};
    try testing.expectEqual(@as(usize, 7), peekRoute(pair[0], &routes, 7));
}

test "peekRoute selects on a ClientHello SNI" {
    const pair = try sys.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const hello = try sni_mod.buildClientHello(testing.allocator, "api.example.com");
    defer testing.allocator.free(hello);
    _ = try sys.write(pair[1], hello);
    const routes = [_]SniRoute{ mkRoute("other.example"), mkRoute("api.example.com") };
    try testing.expectEqual(@as(usize, 1), peekRoute(pair[0], &routes, 0));
    // Bytes are still queued (PEEK): a plain read sees the full hello.
    var back: [8192]u8 = undefined;
    const n = try std.posix.read(pair[0], &back);
    try testing.expectEqual(hello.len, n);
}

/// shutdown(2) both directions (wakes threads blocked in poll/read;
/// close() alone neither interrupts them nor — for a racing poll — avoids
/// a POLLNVAL spin). Best-effort: test teardown only.
fn shutdownBoth(fd: std.posix.fd_t) void {
    const rc = std.os.linux.shutdown(fd, 2); // SHUT_RDWR
    _ = std.os.linux.errno(rc);
}

test "relayPair echoes through a socketpair splice" {
    // Client <-> relay <-> echo: relayPair splices two fds; emulate with
    // two socketpairs and a relay thread, then round-trip a payload.
    const c2r = try sys.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer sys.close(c2r[0]);
    defer sys.close(c2r[1]);
    const r2e = try sys.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer sys.close(r2e[0]);
    defer sys.close(r2e[1]);
    const Args = struct { a: std.posix.fd_t, b: std.posix.fd_t };
    const T = struct {
        fn relay(args: Args) void {
            relayPair(args.a, args.b, 2000);
        }
        fn echo(fd: std.posix.fd_t) void {
            var buf: [1024]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &buf) catch {
                    break;
                };
                if (n == 0) {
                    break;
                }
                _ = sys.write(fd, buf[0..n]) catch {
                    break;
                };
            }
        }
    };
    const rargs = Args{ .a = c2r[1], .b = r2e[0] };
    const rt = try std.Thread.spawn(.{}, T.relay, .{rargs});
    const et = try std.Thread.spawn(.{}, T.echo, .{r2e[1]});
    const msg = "stream-relay round-trip";
    _ = try sys.write(c2r[0], msg);
    var out: [64]u8 = undefined;
    var got: usize = 0;
    while (got < msg.len) {
        const n = try std.posix.read(c2r[0], out[got..msg.len]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings(msg, out[0..got]);
    // Shutdown wakes the blocked readers: relay sees EOF and returns,
    // then the echoer sees EOF and returns. (close() alone does not
    // interrupt a blocking read on another thread, and closing the
    // relay's fd under its poll spins on POLLNVAL.)
    shutdownBoth(c2r[1]);
    rt.join();
    shutdownBoth(r2e[0]);
    et.join();
}

/// Runtime runner: one accept thread per stream server (C3 v1). Accepts
/// TCP, PEEKs SNI, dials the selected backend and relays both directions
/// on a per-connection thread. Threads exit on EOF/timeout; `stop()`
/// closes the listener (in-flight relays drain via the idle timeout).
pub const Server = struct {
    listen_port: u16,
    default_addr: std.posix.sockaddr,
    routes: []const RouteEntry,
    listener: std.posix.fd_t = -1,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    pub const RouteEntry = struct {
        pattern: []const u8,
        addr: std.posix.sockaddr,
        fn asSni(e: *const RouteEntry) SniRoute {
            return .{ .pattern = e.pattern, .addr = addrTo16(e.addr), .addr_len = 16 };
        }
    };

    pub fn start(listen_port: u16, default_addr: std.posix.sockaddr, routes: []const RouteEntry) !*Server {
        const self = try std.heap.page_allocator.create(Server);
        const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        errdefer sys.close(lfd);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2; // AF_INET
        addr[2] = @intCast((listen_port >> 8) & 0xFF);
        addr[3] = @intCast(listen_port & 0xFF);
        try sys.bind(lfd, @ptrCast(&addr), 16);
        try sys.listen(lfd, 64);
        self.* = .{ .listen_port = listen_port, .default_addr = default_addr, .routes = routes, .listener = lfd };
        self.thread = try std.Thread.spawn(.{}, acceptFn, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.stop_flag.store(true, .release);
        sys.close(self.listener);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }

    fn acceptFn(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]std.posix.pollfd{.{ .fd = self.listener, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 100) catch break;
            if (ready == 0) continue;
            const cfd = std.os.linux.accept4(self.listener, null, null, 0);
            if (std.os.linux.errno(cfd) != .SUCCESS) {
                if (self.stop_flag.load(.acquire)) break;
                continue;
            }
            const Conn = struct {
                cfd: std.posix.fd_t,
                srv: *Server,
                fn run(args: @This()) void {
                    serveConn(args.srv, args.cfd);
                }
            };
            const t = std.Thread.spawn(.{}, Conn.run, .{Conn{ .cfd = @intCast(cfd), .srv = self }}) catch {
                sys.close(@intCast(cfd));
                continue;
            };
            t.detach();
        }
    }

    fn serveConn(self: *Server, cfd: std.posix.fd_t) void {
        defer sys.close(cfd);
        // SNI select over a PEEK (bytes stay queued for the relay).
        var snis: [16]SniRoute = undefined;
        const n = @min(self.routes.len, snis.len);
        for (self.routes[0..n], 0..) |*r, i| snis[i] = r.asSni();
        const idx = peekRoute(cfd, snis[0..n], n); // n = default sentinel
        const addr = if (idx < n) self.routes[idx].addr else self.default_addr;
        const ufd = dialAddr(addr, 5000) orelse return;
        defer sys.close(ufd);
        relayPair(cfd, ufd, 60_000);
    }

    fn dialAddr(addr: std.posix.sockaddr, timeout_ms: i32) ?std.posix.fd_t {
        const fd = sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0) catch return null;
        errdefer sys.close(fd);
        sys.connect(fd, &addr, 16) catch |e| switch (e) {
            error.WouldBlock => {},
            else => return null,
        };
        var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&pfds, timeout_ms) catch return null;
        if (ready == 0) return null;
        // Back to blocking: the relay loop uses plain read/write.
        const flags = sys.fcntl(fd, 3, 0) catch return null; // F_GETFL
        _ = sys.fcntl(fd, 4, flags & ~@as(usize, 2048)) catch {}; // clear O_NONBLOCK
        return fd;
    }
};

fn addrTo16(addr: std.posix.sockaddr) [16]u8 {
    var out: [16]u8 = std.mem.zeroes([16]u8);
    out[0] = @intCast(addr.family & 0xFF);
    out[1] = @intCast((addr.family >> 8) & 0xFF);
    const n: usize = @min(addr.data.len, 14);
    @memcpy(out[2..][0..n], addr.data[0..n]);
    return out;
}

test "stream server relays TCP to the default backend" {
    // Backend: single-shot TCP echo on loopback.
    const Echo = struct {
        lfd: std.posix.fd_t = -1,
        port: u16 = 0,
        stop_flag: std.atomic.Value(bool) = .init(false),
        thread: std.Thread = undefined,
        fn start(self: *@This()) !void {
            const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
            errdefer sys.close(lfd);
            var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
            addr[0] = 2;
            addr[4] = 127;
            addr[7] = 1;
            try sys.bind(lfd, @ptrCast(&addr), 16);
            try sys.listen(lfd, 8);
            var slen: std.posix.socklen_t = 16;
            var bound: [16]u8 align(@alignOf(u16)) = undefined;
            try sys.getsockname(lfd, @ptrCast(&bound), &slen);
            self.lfd = lfd;
            self.port = (@as(u16, bound[2]) << 8) | bound[3];
            self.thread = try std.Thread.spawn(.{}, acceptFn, .{self});
        }
        fn acceptFn(self: *@This()) void {
            while (!self.stop_flag.load(.acquire)) {
                var pfds = [_]std.posix.pollfd{.{ .fd = self.lfd, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&pfds, 100) catch break;
                if (ready == 0) continue;
                const cfd = std.os.linux.accept4(self.lfd, null, null, 0);
                if (std.os.linux.errno(cfd) != .SUCCESS) break;
                const fd: std.posix.fd_t = @intCast(cfd);
                var buf: [1024]u8 = undefined;
                const n = std.posix.read(fd, &buf) catch {
                    sys.close(fd);
                    continue;
                };
                _ = sys.write(fd, buf[0..n]) catch {};
                sys.close(fd);
            }
        }
        fn stop(self: *@This()) void {
            self.stop_flag.store(true, .release);
            sys.close(self.lfd);
            self.thread.join();
        }
        fn sockaddr(self: *const @This()) std.posix.sockaddr {
            var sa = std.posix.sockaddr{ .family = std.posix.AF.INET, .data = @as([14]u8, @splat(@as(u8, 0))) };
            std.mem.writeInt(u16, sa.data[0..2], self.port, .big);
            sa.data[2] = 127;
            sa.data[5] = 1;
            return sa;
        }
    };
    var echo = Echo{};
    try echo.start();
    defer echo.stop();
    // Stream front with no SNI routes: everything hits the default.
    const srv = try Server.start(0, echo.sockaddr(), &.{});
    defer srv.stop();
    // Discover the ephemeral listen port.
    var slen: std.posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try sys.getsockname(srv.listener, @ptrCast(&bound), &slen);
    const sport: u16 = (@as(u16, bound[2]) << 8) | bound[3];
    try testing.expect(sport != 0);
    // Client round-trip through the relay.
    const cfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(cfd);
    var sa: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    sa[0] = 2;
    sa[2] = @intCast((sport >> 8) & 0xFF);
    sa[3] = @intCast(sport & 0xFF);
    sa[4] = 127;
    sa[7] = 1;
    try sys.connect(cfd, @ptrCast(&sa), 16);
    const msg = "stream-e2e-payload";
    _ = try sys.write(cfd, msg);
    var out: [64]u8 = undefined;
    var got: usize = 0;
    while (got < msg.len) {
        var pfds = [_]std.posix.pollfd{.{ .fd = cfd, .events = std.posix.POLL.IN, .revents = 0 }};
        try testing.expect(try std.posix.poll(&pfds, 5000) > 0);
        const n = try std.posix.read(cfd, out[got..msg.len]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings(msg, out[0..got]);
}
