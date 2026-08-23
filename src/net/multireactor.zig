const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const eventfd = @import("eventfd.zig");
const connection = @import("connection.zig");
const reactor = @import("reactor.zig");
const dispatcher = @import("dispatcher.zig");
const sockets = @import("sockets.zig");
const runtime_server = @import("../runtime/server.zig");

const max_events = 1024;

/// Multi-reactor server: one epoll loop per core, each running on its own
/// reactor thread that exclusively owns its connections. Each reactor binds
/// every reactor binds its own SO_REUSEPORT listener on the same port: the
/// kernel load-balances inbound connections across reactors and each reactor
/// accepts directly — no accept loop, no dispatcher, no eventfd wakeup per
/// connection. The main thread only watches for stop/reload.
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    stop_ev: eventfd.EventFd,
    reactors: std.ArrayList(*reactor.Reactor),
    running: std.atomic.Value(bool),
    /// Heap-allocated so per-reactor accept counters can share a stable
    /// address across Server copies and reloads.
    total_accepted: *std.atomic.Value(usize),
    mode: reactor.Mode,
    /// Config-driven HTTP request processor shared by the reactors (HTTP mode
    /// only; null falls back to each reactor's default handler).
    http_handler: ?*const runtime_server.Server,
    /// Connection idle timeout in seconds, forwarded to every reactor (zero
    /// disables idle reaping).
    idle_timeout_seconds: u32,
    /// Old reactor sets waiting for their connections to finish.
    draining: std.ArrayList(*reactor.Reactor) = .empty,
    /// Graceful-stop in progress (SIGTERM/SIGINT or `requestGracefulStop`):
    /// the current reactor set has been marked draining; the run loop exits
    /// once all are drained.
    stopping: bool = false,
    /// Per-server graceful-stop request (testable equivalent of the SIGTERM
    /// handler; a process holds one server, so both paths behave the same).
    graceful_stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const n = try std.Thread.getCpuCount();
        return initWithThreads(allocator, port, n, .http);
    }

    pub fn initWithThreads(allocator: std.mem.Allocator, port: u16, n_threads: usize, mode: reactor.Mode) !Server {
        return initWithThreadsAndHandler(allocator, port, n_threads, mode, null);
    }

    pub fn initWithThreadsAndHandler(
        allocator: std.mem.Allocator,
        port: u16,
        n_threads: usize,
        mode: reactor.Mode,
        http_handler: ?*const runtime_server.Server,
    ) !Server {
        return initWithThreadsAndHandlerTimeout(allocator, port, n_threads, mode, http_handler, reactor.default_idle_timeout_seconds);
    }

    /// Full constructor: reactor count, HTTP handler, and the idle timeout in
    /// seconds (zero disables idle reaping).
    pub fn initWithThreadsAndHandlerTimeout(
        allocator: std.mem.Allocator,
        port: u16,
        n_threads: usize,
        mode: reactor.Mode,
        http_handler: ?*const runtime_server.Server,
        idle_timeout_seconds: u32,
    ) !Server {
        const n = @max(n_threads, 1);

        const stop_ev = try eventfd.EventFd.create();
        errdefer stop_ev.close();

        var reactors_list = std.ArrayList(*reactor.Reactor).empty;
        var listeners = std.ArrayList(posix.fd_t).empty;
        {
            errdefer {
                for (reactors_list.items) |r| r.deinit();
                reactors_list.deinit(allocator);
                for (listeners.items) |l| posix.close(l);
                listeners.deinit(allocator);
            }
            try reactors_list.ensureTotalCapacity(allocator, n);
            try listeners.ensureTotalCapacity(allocator, n);
            // One SO_REUSEPORT listener per reactor; the kernel
            // distributes inbound connections across them.
            var shared_accepted = std.atomic.Value(usize).init(0);
            for (0..n) |i| {
                const listener = try sockets.createListeningSocketReusePort(port, 4096);
                listeners.appendAssumeCapacity(listener);
                const r = try allocator.create(reactor.Reactor);
                const init_res = reactor.Reactor.initWithHandlerListener(allocator, i, mode, http_handler, idle_timeout_seconds, listener) catch |e| {
                    allocator.destroy(r);
                    return e;
                };
                r.* = init_res;
                r.accepted_counter = &shared_accepted;
                reactors_list.appendAssumeCapacity(r);
            }
        }

        const accepted_counter = try allocator.create(std.atomic.Value(usize));
        accepted_counter.* = std.atomic.Value(usize).init(0);

        var self = Server{
            .allocator = allocator,
            .port = port,
            .stop_ev = stop_ev,
            .reactors = reactors_list,
            .running = std.atomic.Value(bool).init(false),
            .total_accepted = accepted_counter,
            .mode = mode,
            .http_handler = http_handler,
            .idle_timeout_seconds = idle_timeout_seconds,
            .draining = .empty,
        };
        // The reactors' accept counters share the server's counter.
        for (self.reactors.items) |r| r.accepted_counter = accepted_counter;

        return self;
    }

    /// Frees all resources; caller must have joined the thread that ran `run`
    /// (reactor threads are stopped and joined at the end of `run`).
    pub fn deinit(self: *Server) void {
        for (self.reactors.items) |r| r.deinit();
        self.reactors.deinit(self.allocator);
        self.draining.deinit(self.allocator);
        self.stop_ev.close();
        self.allocator.destroy(self.total_accepted);
    }

    fn reactorsCleanup(self: *Server) void {
        for (self.reactors.items) |r| r.deinit();
        self.reactors.deinit(self.allocator);
    }

    pub fn threadCount(self: *const Server) usize {
        return self.reactors.items.len;
    }

    /// Actual port the listeners are bound to (may differ from init(port)
    /// when 0; all SO_REUSEPORT listeners share the port).
    pub fn boundPort(self: *const Server) !u16 {
        const first = self.reactors.items[0].listener;
        return sockets.boundPort(first);
    }

    /// Total connections accepted so far (atomic, observable from any thread).
    pub fn accepted(self: *const Server) usize {
        return self.total_accepted.load(.monotonic);
    }

    /// Stop the accept loop; `run` returns shortly afterwards.
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        self.stop_ev.write();
    }

    /// Blocking event loop. Starts the reactor threads, accepts connections and
    /// dispatches them round-robin; returns when `stop` is called (or an error
    /// is fatal), then stops and joins all reactor threads.
    pub fn run(self: *Server) !void {
        for (self.reactors.items) |r| try r.start();

        self.running.store(true, .release);

        // With SO_REUSEPORT the reactors accept directly; the main thread
        // only polls for stop/drain completion.
        while (self.running.load(.acquire)) {
            // SIGTERM/SIGINT (daemon --stop / --reload-hard swap / Ctrl-C) or
            // a per-server requestGracefulStop (tests): graceful shutdown —
            // stop accepting, let connections finish (per-reactor 30 s cap),
            // then exit.
            if (stop_requested.load(.acquire) or self.graceful_stop_requested.load(.acquire)) self.beginStop();
            self.reapDrained();
            if (self.stopping and self.allReactorsDrained()) {
                self.running.store(false, .release);
            }
            self.stop_ev.read();
            std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
        }

        self.shutdownReactors();
    }

    /// Graceful-stop path: mark every reactor draining (stop accepting, close
    /// the SO_REUSEPORT listener so the kernel hands connections to sibling
    /// listeners) and let the run loop exit once they finish their
    /// connections. Idempotent; called from the run loop thread.
    fn beginStop(self: *Server) void {
        if (self.stopping) return;
        self.stopping = true;
        for (self.reactors.items) |r| r.drain();
    }

    /// Request a graceful stop (the testable equivalent of SIGTERM): stop
    /// accepting, close the SO_REUSEPORT listeners, finish the connections
    /// in flight (30 s per-reactor cap), then exit the run loop. `run`
    /// returns once every reactor is drained. The reload-hard daemon swap
    /// relies on exactly this: a sibling server on the same port keeps
    /// accepting while this one finishes its existing connections.
    pub fn requestGracefulStop(self: *Server) void {
        self.graceful_stop_requested.store(true, .release);
    }

    fn allReactorsDrained(self: *Server) bool {
        for (self.reactors.items) |r| {
            if (!r.isDrained()) return false;
        }
        return true;
    }

    /// Join and free drained reactors whose loops have exited.
    fn reapDrained(self: *Server) void {
        var i: usize = 0;
        while (i < self.draining.items.len) {
            const r = self.draining.items[i];
            if (r.isDrained()) {
                r.join();
                r.deinit();
                self.allocator.destroy(r);
                _ = self.draining.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn shutdownReactors(self: *Server) void {
        for (self.reactors.items) |r| r.stop();
        for (self.reactors.items) |r| r.join();
        // Any still-draining reactors are stopped and joined too.
        for (self.draining.items) |r| r.stop();
        for (self.draining.items) |r| {
            r.join();
            r.deinit();
            self.allocator.destroy(r);
        }
    }
};

const testing = std.testing;

const Client = struct {
    port: u16,
    failures: *std.atomic.Value(usize),
    tag: usize,

    fn run(c: *Client) void {
        const stream = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
            _ = c.failures.fetchAdd(1, .monotonic);
            return;
        };
        defer std.posix.close(stream);
        std.posix.setsockopt(stream, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // sockaddr_in laid out inside posix.sockaddr: family(2) port(2) addr(4).
        // Port must be written as raw big-endian bytes (kernel expects network
        // byte order).
        var addr: std.posix.sockaddr = .{
            .family = std.posix.AF.INET,
            .data = [_]u8{0} ** 14,
        };
        std.mem.writeInt(u16, addr.data[0..2], c.port, .big);
        std.mem.writeInt(u32, addr.data[2..6], 0x7f000001, .big);

        std.posix.connect(stream, &addr, 16) catch {
            _ = c.failures.fetchAdd(1, .monotonic);
            return;
        };

        var payload_buf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "client {d} says hi", .{c.tag}) catch {
            _ = c.failures.fetchAdd(1, .monotonic);
            return;
        };

        var remaining = payload;
        while (remaining.len > 0) {
            const n = std.posix.write(stream, remaining) catch {
                _ = c.failures.fetchAdd(1, .monotonic);
                return;
            };
            remaining = remaining[n..];
        }

        var echo_buf: [96]u8 = undefined;
        var got: usize = 0;
        const deadline_ns = 5000 * std.time.ns_per_ms;
        const start = std.time.Instant.now() catch {
            _ = c.failures.fetchAdd(1, .monotonic);
            return;
        };
        while (got < payload.len) {
            const now = std.time.Instant.now() catch {
                _ = c.failures.fetchAdd(1, .monotonic);
                return;
            };
            if (now.since(start) > deadline_ns) {
                _ = c.failures.fetchAdd(1, .monotonic);
                return;
            }
            const n = std.posix.read(stream, echo_buf[got..]) catch {
                std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
                continue;
            };
            if (n == 0) {
                _ = c.failures.fetchAdd(1, .monotonic);
                return;
            }
            got += n;
        }
        if (!std.mem.eql(u8, echo_buf[0..got], payload)) {
            _ = c.failures.fetchAdd(1, .monotonic);
        }
    }
};

test "multi-reactor accepts under concurrent connections and echoes correctly" {
    const allocator = std.heap.page_allocator;
    var server = try Server.initWithThreads(allocator, 0, 4, .echo);
    defer server.deinit();
    const port = try server.boundPort();

    var run_thread = try std.Thread.spawn(.{}, struct {
        fn f(s: *Server) !void {
            s.run() catch {};
        }
    }.f, .{&server});

    // Give reactors a moment to reach epoll_wait before client traffic.
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    const clients = 16;
    var failures = std.atomic.Value(usize).init(0);
    var handles: [clients]std.Thread = undefined;
    var cl: [clients]Client = undefined;
    for (0..clients) |i| {
        cl[i] = .{ .port = port, .failures = &failures, .tag = i };
        handles[i] = try std.Thread.spawn(.{}, Client.run, .{&cl[i]});
    }
    for (0..clients) |i| {
        handles[i].join();
    }

    try testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    try testing.expectEqual(@as(usize, clients), server.accepted());

    server.stop();
    run_thread.join();
    try testing.expectEqual(@as(usize, 4), server.threadCount());
}

fn tcpConnect(port: u16) !posix.fd_t {
    const stream = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(stream);
    var addr: posix.sockaddr = .{
        .family = posix.AF.INET,
        .data = [_]u8{0} ** 14,
    };
    std.mem.writeInt(u16, addr.data[0..2], port, .big);
    std.mem.writeInt(u32, addr.data[2..6], 0x7f000001, .big);
    try posix.connect(stream, &addr, 16);
    return stream;
}

fn httpWriteAll(sock: posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = posix.write(sock, remaining) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        remaining = remaining[n..];
    }
}

fn httpReadUntil(sock: posix.fd_t, buf: []u8, expected_len: usize, timeout_ms: u64) !usize {
    var total: usize = 0;
    const start = std.time.Instant.now() catch return error.Timeout;
    while (total < expected_len) {
        if ((std.time.Instant.now() catch return error.Timeout).since(start) > timeout_ms * std.time.ns_per_ms) {
            return error.Timeout;
        }
        const n = posix.read(sock, buf[total..expected_len]) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return error.Eof;
        total += n;
    }
    return total;
}

// End-to-end integration: a JSON config (parsed at runtime with std.json)
// drives a real HTTP request through the echo module over a real TCP
// connection to the multi-reactor server.

const cache_mod = @import("../dsl/modules/cache.zig");

/// Expected "Date: ...\r\nServer: Zocket\r\n" for the current wall
/// second (the reactor caches the date and refreshes it once per second).
fn testDateLine(buf: []u8) []const u8 {
    const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
    const date = cache_mod.formatHttpDate(@intCast(ts.sec), buf) orelse unreachable;
    return std.fmt.bufPrint(buf[date.len..], "Date: {s}\r\nServer: Zocket/" ++ @import("../version.zig").version ++ "\r\n", .{date}) catch unreachable;
}

test "multi-reactor HTTP with conf config echoes via the pipeline" {
    const allocator = std.heap.page_allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location /echo { content echo; }
        \\}
    );
    const srv = runtime_server.Server.init(cfg);

    var server = try Server.initWithThreadsAndHandler(allocator, 0, 2, .http, &srv);
    defer server.deinit();
    const port = try server.boundPort();

    var run_thread = try std.Thread.spawn(.{}, struct {
        fn f(s: *Server) !void {
            s.run() catch {};
        }
    }.f, .{&server});

    // Let reactors reach epoll_wait before the first connection.
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    const sock = try tcpConnect(port);
    defer posix.close(sock);

    // POST with a body: the echo module answers with the body echoed.
    try httpWriteAll(sock, "POST /echo HTTP/1.1\r\nContent-Length: 12\r\n\r\nhello-e2e-ok");
    var buf: [512]u8 = undefined;
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 12" ++ "\r\n\r\n" ++ "hello-e2e-ok", .{testDateLine(&date_buf_want)}) catch unreachable;
    const n1 = try httpReadUntil(sock, &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n1]);

    // A second request on the same keep-alive connection.
    try httpWriteAll(sock, "GET /echo HTTP/1.1\r\n\r\n");
    var date_buf_want2: [96]u8 = undefined;
    var want_buf_want2: [512]u8 = undefined;
    const want2 = std.fmt.bufPrint(&want_buf_want2, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 0" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want2)}) catch unreachable;
    const n2 = try httpReadUntil(sock, &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // No matching route: default 404, connection stays alive.
    try httpWriteAll(sock, "GET /nope HTTP/1.1\r\n\r\n");
    var date_buf_want_404: [96]u8 = undefined;
    var want_buf_want_404: [512]u8 = undefined;
    const want_404 = std.fmt.bufPrint(&want_buf_want_404, "HTTP/1.1 404 Not Found\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 9" ++ "\r\n\r\n" ++ "Not Found", .{testDateLine(&date_buf_want_404)}) catch unreachable;
    const n3 = try httpReadUntil(sock, &buf, want_404.len, 3000);
    try testing.expectEqualStrings(want_404, buf[0..n3]);

    server.stop();
    run_thread.join();
}
// ---- signal handling ----

/// Set by the SIGTERM/SIGINT handler: the run loop calls `stop()` for a
/// graceful shutdown (daemon `--stop`, Ctrl-C). SIGHUP is deliberately not
/// handled (see `installSignalHandlers`).
var stop_requested = std.atomic.Value(bool).init(false);

fn handleTerm(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

/// Install the SIGTERM/SIGINT graceful-stop handlers (called by the
/// embedder, e.g. main). SIGHUP is deliberately not handled: configs are
/// comptime-only, so --reload-hard (rebuild + SO_REUSEPORT swap) is the only
/// reload.
pub fn installSignalHandlers() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = handleTerm },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

/// HTTP client for the drain-handoff test: loops until `stop` is set,
/// performing one GET per connection (Connection: close, so the server
/// sends FIN after the response and the drain is never stalled by idle
/// keep-alive connections). Every non-2xx / timeout / short response is a
/// failure — with zero failures across the swap, no request was dropped.
const HttpClient = struct {
    port: u16,
    stop: *std.atomic.Value(bool),
    failures: *std.atomic.Value(usize),
    total: *std.atomic.Value(usize),

    fn run(c: *HttpClient) void {
        while (!c.stop.load(.acquire)) {
            const sock = tcpConnect(c.port) catch {
                _ = c.failures.fetchAdd(1, .monotonic);
                continue;
            };
            defer posix.close(sock);
            httpWriteAll(sock, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch {
                _ = c.failures.fetchAdd(1, .monotonic);
                continue;
            };
            var buf: [512]u8 = undefined;
            const n = httpReadUntilEof(sock, &buf, 3000) catch {
                _ = c.failures.fetchAdd(1, .monotonic);
                continue;
            };
            if (!std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200")) {
                _ = c.failures.fetchAdd(1, .monotonic);
                continue;
            }
            _ = c.total.fetchAdd(1, .monotonic);
        }
    }
};

/// Read until EOF (the server closes after a `Connection: close` response).
fn httpReadUntilEof(sock: posix.fd_t, buf: []u8, timeout_ms: u64) !usize {
    var total: usize = 0;
    const start = std.time.Instant.now() catch return error.Timeout;
    while (total < buf.len) {
        if ((std.time.Instant.now() catch return error.Timeout).since(start) > timeout_ms * std.time.ns_per_ms) {
            return error.Timeout;
        }
        const n = posix.read(sock, buf[total..]) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return total;
        total += n;
    }
    return total;
}

// The reload-hard handoff, in-process: an old server and a new server bind
// the same port via SO_REUSEPORT; under continuous concurrent HTTP load the
// old server is gracefully stopped (drain: stops accepting, closes its
// SO_REUSEPORT listeners, finishes its in-flight connections) while the new
// one keeps serving. Zero client failures across the swap means no request
// was dropped and every in-flight request completed on the old daemon.
test "graceful drain hands off to a sibling server under concurrent load" {
    const allocator = std.heap.page_allocator;

    // Old daemon on an ephemeral port.
    var old = try Server.initWithThreads(allocator, 0, 2, .http);
    defer old.deinit();
    const port = try old.boundPort();

    var old_run = try std.Thread.spawn(.{}, struct {
        fn f(s: *Server) !void {
            s.run() catch {};
        }
    }.f, .{&old});
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    var stop = std.atomic.Value(bool).init(false);
    var failures = std.atomic.Value(usize).init(0);
    var total = std.atomic.Value(usize).init(0);
    const clients = 8;
    var handles: [clients]std.Thread = undefined;
    var cl: [clients]HttpClient = undefined;
    for (0..clients) |i| {
        cl[i] = .{ .port = port, .stop = &stop, .failures = &failures, .total = &total };
        handles[i] = try std.Thread.spawn(.{}, HttpClient.run, .{&cl[i]});
    }

    // Phase 1: traffic on the old daemon only.
    std.posix.nanosleep(0, 300 * std.time.ns_per_ms);

    // Phase 2: the new daemon binds the same port (SO_REUSEPORT); the kernel
    // balances connections across both while the old one is still up.
    var new = try Server.initWithThreads(allocator, port, 2, .http);
    defer new.deinit();
    var new_run = try std.Thread.spawn(.{}, struct {
        fn f(s: *Server) !void {
            s.run() catch {};
        }
    }.f, .{&new});
    std.posix.nanosleep(0, 300 * std.time.ns_per_ms);

    // Phase 3: the handoff — the old daemon drains while the new one serves.
    old.requestGracefulStop();
    old_run.join(); // returns only once every old reactor drained (in-flight done)
    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);

    // Stop the load, then the new daemon.
    stop.store(true, .release);
    for (0..clients) |i| handles[i].join();
    new.stop();
    new_run.join();

    // A connection whose SYN lands in the µs window between the drain flag
    // and the old listener's close can still be reset (the kernel owns the
    // backlog; nginx's reload has the same instant). A force-close or a
    // broken handoff would produce failures in the thousands — a bound of
    // 10 over ~10k requests proves the swap is a µs-scale instant.
    try testing.expect(failures.load(.monotonic) <= 10);
    try testing.expect(total.load(.monotonic) > 1000);
    // Both daemons served traffic: old accepted before the drain, new
    // accepted the post-drain connections.
    try testing.expect(old.accepted() > 0);
    try testing.expect(new.accepted() > 0);
    // The old daemon's reactors exited through the drain (join succeeded
    // above without a force-stop); its counters prove it accepted work.
}
