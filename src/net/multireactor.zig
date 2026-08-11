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

/// Multi-reactor server (README Milestone 2): one epoll loop per core, each
/// running on its own reactor thread that exclusively owns its connections.
/// The calling thread owns the single listener socket, drains inbound
/// connections and hands each one to a reactor through the round-robin
/// `Dispatcher`. Connection dispatch is queue-based (reactor-local mutex +
/// eventfd wakeup), so no locks are ever taken in the reactor's event path.
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    listener: posix.fd_t,
    main_ep: epoll.Epoll,
    stop_ev: eventfd.EventFd,
    reactors: std.ArrayList(*reactor.Reactor),
    dispatch: dispatcher.Dispatcher,
    running: std.atomic.Value(bool),
    total_accepted: std.atomic.Value(usize),
    mode: reactor.Mode,
    /// Config-driven HTTP request processor shared by the reactors (HTTP mode
    /// only; null falls back to each reactor's default handler).
    http_handler: ?*const runtime_server.Server,

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
        const n = @max(n_threads, 1);

        const listener = try sockets.createListeningSocket(port, 4096);
        errdefer posix.close(listener);

        const main_ep = try epoll.Epoll.create();
        errdefer main_ep.close();

        const stop_ev = try eventfd.EventFd.create();
        errdefer stop_ev.close();

        var reactors_list = std.ArrayList(*reactor.Reactor).empty;
        // Fix the backing storage up front so reactor addresses stay stable
        // for the dispatcher pointers.
        {
            errdefer {
                for (reactors_list.items) |r| r.deinit();
                reactors_list.deinit(allocator);
            }
            try reactors_list.ensureTotalCapacity(allocator, n);
            for (0..n) |i| {
                const r = try allocator.create(reactor.Reactor);
                const init_res = reactor.Reactor.initWithHandler(allocator, i, mode, http_handler) catch |e| {
                    allocator.destroy(r);
                    return e;
                };
                r.* = init_res;
                reactors_list.appendAssumeCapacity(r);
            }
        }

        var self = Server{
            .allocator = allocator,
            .port = port,
            .listener = listener,
            .main_ep = main_ep,
            .stop_ev = stop_ev,
            .reactors = reactors_list,
            .dispatch = dispatcher.Dispatcher.init(reactors_list.items),
            .running = std.atomic.Value(bool).init(false),
            .total_accepted = std.atomic.Value(usize).init(0),
            .mode = mode,
            .http_handler = http_handler,
        };

        self.main_ep.add(self.listener, epoll.Events.In | epoll.Events.EdgeTriggered, self.listener) catch |e| {
            self.reactorsCleanup();
            return e;
        };
        self.main_ep.add(self.stop_ev.fd, epoll.Events.In, self.stop_ev.fd) catch |e| {
            self.reactorsCleanup();
            return e;
        };

        return self;
    }

    /// Frees all resources; caller must have joined the thread that ran `run`
    /// (reactor threads are stopped and joined at the end of `run`).
    pub fn deinit(self: *Server) void {
        for (self.reactors.items) |r| r.deinit();
        self.reactors.deinit(self.allocator);
        self.main_ep.close();
        self.stop_ev.close();
        posix.close(self.listener);
    }

    fn reactorsCleanup(self: *Server) void {
        for (self.reactors.items) |r| r.deinit();
        self.reactors.deinit(self.allocator);
    }

    pub fn threadCount(self: *const Server) usize {
        return self.reactors.items.len;
    }

    /// Actual port the listener is bound to (may differ from init(port) when 0).
    pub fn boundPort(self: *const Server) !u16 {
        return sockets.boundPort(self.listener);
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
        var events: [max_events]linux.epoll_event = undefined;

        while (self.running.load(.acquire)) {
            const n = self.main_ep.wait(&events, 100) catch continue;
            for (events[0..n]) |ev| {
                const fd: posix.fd_t = @intCast(ev.data.ptr);
                if (fd == self.stop_ev.fd) {
                    self.stop_ev.read();
                    self.running.store(false, .release);
                    break;
                }
                if (fd == self.listener) {
                    if (ev.events & epoll.Events.In == 0) continue;
                    try self.drainAccepts();
                }
            }
        }

        self.shutdownReactors();
    }

    fn drainAccepts(self: *Server) !void {
        while (true) {
            const conn_fd = sockets.acceptNonBlock(self.listener) catch |e| {
                if (e == error.WouldBlock) return;
                return e;
            };
            _ = self.total_accepted.fetchAdd(1, .monotonic);

            const conn = connection.Connection.create(self.allocator, conn_fd) catch |e| {
                posix.close(conn_fd);
                return e;
            };
            self.dispatch.pick().attach(conn);
        }
    }

    fn shutdownReactors(self: *Server) void {
        for (self.reactors.items) |r| r.stop();
        for (self.reactors.items) |r| r.join();
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
test "multi-reactor HTTP with JSON config echoes via the pipeline" {
    const allocator = std.heap.page_allocator;
    const json =
        \\{ "routes": [
        \\    { "path": "/echo", "match": "prefix", "modules": { "content": "echo" } }
        \\  ] }
    ;
    var cfg = try runtime_server.Config.fromJson(allocator, json);
    defer cfg.deinit(allocator);
    try cfg.validate(runtime_server.default_registry);
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
    const want = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 12\r\n\r\nhello-e2e-ok";
    const n1 = try httpReadUntil(sock, &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n1]);

    // A second request on the same keep-alive connection.
    try httpWriteAll(sock, "GET /echo HTTP/1.1\r\n\r\n");
    const want2 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";
    const n2 = try httpReadUntil(sock, &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // No matching route: default 404, connection stays alive.
    try httpWriteAll(sock, "GET /nope HTTP/1.1\r\n\r\n");
    const want_404 = "HTTP/1.1 404 Not Found\r\nConnection: keep-alive\r\nContent-Length: 9\r\n\r\nNot Found";
    const n3 = try httpReadUntil(sock, &buf, want_404.len, 3000);
    try testing.expectEqualStrings(want_404, buf[0..n3]);

    server.stop();
    run_thread.join();
}