const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const eventfd = @import("eventfd.zig");
const connection = @import("connection.zig");
const sockets = @import("sockets.zig");
const http_parser = @import("../http/parser.zig");
const http_response = @import("../http/response.zig");

const max_events = 1024;
/// Largest request body the echo response can hold: the response (head + body)
/// must fit into the 16 KiB send buffer alongside the status line and headers.
const max_echo_body = 16 * 1024 - 1024;

/// Connection protocol handled by a reactor.
pub const Mode = enum {
    /// Raw byte echo (Milestone 1/2 semantics).
    echo,
    /// HTTP/1.1: parse requests, respond with the request body echoed.
    http,
};

const HttpSession = struct {
    parser: http_parser.Parser,
    req: http_parser.Request,
    /// A response is queued in the send buffer and the fd is armed for
    /// EPOLLOUT until it has been fully flushed.
    writing: bool = false,
    /// Close the connection once the current response has been flushed
    /// (errors, and requests that asked for Connection: close).
    close_after_write: bool = false,
};

/// A single-reactor worker: its own thread, its own epoll instance and its own
/// connection registry, wired for the echo protocol (identical semantics to the
/// Milestone 1 single-threaded server). Inbound connections are handed over
/// from any thread via `attach`, which queues the connection behind a mutex and
/// pokes the loop with an eventfd; the reactor thread then registers the fd and
/// owns it exclusively from that point on, so the connection map and all
/// epoll_ctl calls for a given fd are confined to this thread.
pub const Reactor = struct {
    allocator: std.mem.Allocator,
    id: usize,
    mode: Mode,
    ep: epoll.Epoll,
    wakeup: eventfd.EventFd,
    connections: std.AutoHashMap(posix.fd_t, *connection.Connection),
    http_sessions: std.AutoHashMap(posix.fd_t, HttpSession),
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    pending: std.ArrayList(*connection.Connection),
    pending_lock: std.Thread.Mutex,
    /// Total connections this reactor has registered, ever. Bumped on the
    /// reactor thread when a pending connection is added to the registry;
    /// monotonic, so tests can assert dispatch happened without racing
    /// connection reaping.
    registered: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, id: usize, mode: Mode) !Reactor {
        var self = Reactor{
            .allocator = allocator,
            .id = id,
            .mode = mode,
            .ep = try epoll.Epoll.create(),
            .wakeup = try eventfd.EventFd.create(),
            .connections = std.AutoHashMap(posix.fd_t, *connection.Connection).init(allocator),
            .http_sessions = std.AutoHashMap(posix.fd_t, HttpSession).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .pending = .empty,
            .pending_lock = .{},
            .registered = std.atomic.Value(usize).init(0),
        };
        errdefer self.ep.close();
        self.ep.add(self.wakeup.fd, epoll.Events.In, self.wakeup.fd) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.pending.deinit(self.allocator);
        };
        return self;
    }

    /// The reactor thread must have been stopped and joined before deinit.
    pub fn deinit(self: *Reactor) void {
        // Tear down connections while the epoll fd is still open: they deregister
        // via epoll_ctl DEL, which would EBADF-panic on a closed epoll fd.
        self.closeAllConnections();
        self.ep.close();
        self.wakeup.close();
        self.connections.deinit();
        self.http_sessions.deinit();
        self.pending.deinit(self.allocator);
    }

    pub fn start(self: *Reactor) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, reactorLoop, .{self});
    }

    /// Ask the reactor to stop; the loop exits after the next wakeup or
    /// epoll_wait timeout. Call `join` afterwards.
    pub fn stop(self: *Reactor) void {
        self.running.store(false, .release);
        self.wakeup.write();
    }

    pub fn join(self: *Reactor) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Hand a new connection to this reactor. Safe to call from any thread.
    pub fn attach(self: *Reactor, conn: *connection.Connection) void {
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        self.pending.append(self.allocator, conn) catch {
            conn.close();
            conn.destroy();
            return;
        };
        self.wakeup.write();
    }

    pub fn countConnections(self: *const Reactor) usize {
        return self.connections.count();
    }

    fn reactorLoop(self: *Reactor) void {
        sockets.pinToCpu(self.id);
        var events: [max_events]linux.epoll_event = undefined;
        while (self.running.load(.acquire)) {
            const n = self.ep.wait(&events, 100) catch continue;
            for (events[0..n]) |ev| {
                self.handleEvent(ev.events, @intCast(ev.data.ptr));
            }
        }
        // Drain anything still queued so deinit can free it deterministically,
        // even if a connection arrived between the last wakeup and stop.
        self.wakeup.read();
        self.drainPending();
    }

    fn handleEvent(self: *Reactor, events: u32, fd: posix.fd_t) void {
        if (fd == self.wakeup.fd) {
            self.wakeup.read();
            self.drainPending();
            return;
        }

        if (self.mode == .http) {
            self.handleHttpEvent(events, fd);
            return;
        }

        const conn = self.connections.get(fd) orelse return;

        if (events & (epoll.Events.Error | epoll.Events.Hangup) != 0) {
            self.removeConnection(fd);
            return;
        }

        if (events & epoll.Events.In != 0) {
            const n = conn.recv() catch |e| {
                // WouldBlock on an edge-triggered fd is a no-op, all other
                // errors tear the connection down.
                if (e != error.WouldBlock) self.removeConnection(fd);
                return;
            };
            if (n == 0) {
                self.removeConnection(fd);
                return;
            }
            self.onMessage(conn) catch {
                self.removeConnection(fd);
            };
        }

        if (events & epoll.Events.Out != 0) {
            if (conn.send_buf.availableRead() > 0) {
                _ = conn.send() catch {
                    self.removeConnection(fd);
                    return;
                };
            }
            if (conn.send_buf.availableRead() == 0) {
                self.ep.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd) catch {};
            }
        }
    }

    /// HTTP/1.1 event handling. The connection's read and write sides are
    /// independent: reads drain into recv_buf (edge-triggered, so everything
    /// available is consumed), requests are parsed and answered, and responses
    /// are queued in the send buffer and flushed on EPOLLOUT.
    fn handleHttpEvent(self: *Reactor, events: u32, fd: posix.fd_t) void {
        if (events & (epoll.Events.Error | epoll.Events.Hangup) != 0) {
            self.removeConnection(fd);
            return;
        }

        if (events & epoll.Events.In != 0) {
            const conn = self.connections.get(fd) orelse return;
            while (true) {
                const n = conn.recv() catch |e| switch (e) {
                    error.WouldBlock => break,
                    // Buffer full: request cannot complete in memory; processHttp
                    // turns this into a 431.
                    error.BufferFull => break,
                    else => {
                        self.removeConnection(fd);
                        return;
                    },
                };
                if (n == 0) {
                    self.removeConnection(fd);
                    return;
                }
            }
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (!session.writing) self.processHttp(fd);
        }

        if (events & epoll.Events.Out != 0) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (session.writing) self.flushHttp(fd);
        }
    }

    /// Parse and answer whatever is buffered. Runs until the buffer holds no
    /// complete request, a response is partially flushed (waiting for
    /// EPOLLOUT), or the connection is torn down. Called on the reactor thread
    /// only; every iteration re-fetches state because processing may remove
    /// the connection.
    fn processHttp(self: *Reactor, fd: posix.fd_t) void {
        while (true) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            const conn = self.connections.get(fd) orelse return;
            if (session.writing) return;

            const outcome = session.parser.parse(conn.recv_buf, &session.req);
            switch (outcome) {
                .incomplete => {
                    // The buffer can hold the whole request, so an incomplete
                    // parse with a full buffer can never finish: header flood
                    // or oversized body.
                    if (conn.recv_buf.availableWrite() == 0) {
                        self.respondAndClose(fd, .header_too_large);
                    }
                    return;
                },
                .bad_request => {
                    self.respondAndClose(fd, .bad_request);
                    return;
                },
                .header_too_large => {
                    self.respondAndClose(fd, .header_too_large);
                    return;
                },
                .unsupported => {
                    self.respondAndClose(fd, .not_implemented);
                    return;
                },
                .out_of_memory => {
                    self.respondAndClose(fd, .internal_error);
                    return;
                },
                .complete => {
                    if (session.req.body.len > max_echo_body) {
                        self.respondAndClose(fd, .payload_too_large);
                        return;
                    }
                    var resp = http_response.Response.init(.ok);
                    if (session.req.body.len > 0) resp.setBody(session.req.body);
                    resp.setHeader(
                        "Connection",
                        if (session.req.keep_alive) "keep-alive" else "close",
                    );
                    conn.send_buf.compact();
                    resp.writeToBuffer(conn.send_buf) catch {
                        self.removeConnection(fd);
                        return;
                    };
                    session.close_after_write = !session.req.keep_alive;
                    session.writing = true;
                    self.flushHttp(fd);
                    if (!self.connections.contains(fd)) return;
                    const sess = self.http_sessions.getPtr(fd) orelse return;
                    if (!sess.writing) continue; // flushed fully; next pipelined request
                    // Partially flushed: re-arm EPOLLOUT (epoll_ctl MOD
                    // re-evaluates readiness, so this delivers the event).
                    self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
                    return;
                },
            }
        }
    }

    /// Write queued response bytes until the socket would block. When the send
    /// buffer is drained: close if requested, otherwise reset the session and
    /// immediately process any pipelined data already buffered.
    fn flushHttp(self: *Reactor, fd: posix.fd_t) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        while (conn.send_buf.availableRead() > 0) {
            const n = conn.send() catch |e| {
                if (e == error.WouldBlock) break;
                self.removeConnection(fd);
                return;
            };
            if (n == 0) break;
        }

        if (conn.send_buf.availableRead() > 0) {
            // Socket buffer full; the next EPOLLOUT edge (socket became
            // writable again) will continue the flush.
            return;
        }

        if (session.close_after_write) {
            // Discard unread receive data so close() sends FIN instead of RST
            // (the client may still be sending the request body).
            drainRecv(conn, 64 * 1024);
            self.removeConnection(fd);
            return;
        }

        session.writing = false;
        session.parser.reset();
        session.req.reset();
        // Nothing to send: wait for the next request without spurious
        // EPOLLOUT edges.
        self.ep.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd) catch {};
        self.processHttp(fd);
    }

    /// Read and discard up to `max` bytes from the socket.
    fn drainRecv(conn: *connection.Connection, max: usize) void {
        var buf: [4096]u8 = undefined;
        var left = max;
        while (left > 0) {
            const n = posix.read(conn.fd, buf[0..@min(left, buf.len)]) catch break;
            if (n == 0) break;
            left -= n;
        }
    }

    /// Queue an error response and close the connection after it is flushed.
    fn respondAndClose(self: *Reactor, fd: posix.fd_t, status: http_response.Status) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        var resp = http_response.Response.init(status);
        resp.setBody(status.reasonPhrase());
        resp.setHeader("Connection", "close");
        conn.send_buf.compact();
        resp.writeToBuffer(conn.send_buf) catch {
            self.removeConnection(fd);
            return;
        };
        session.close_after_write = true;
        session.writing = true;
        self.flushHttp(fd);
    }

    /// Echo semantics identical to the Milestone 1 server: whatever was read is
    /// copied into the send buffer and the fd is armed for writability.
    fn onMessage(self: *Reactor, conn: *connection.Connection) !void {
        const data = conn.recv_buf.peek();
        if (data.len > 0) {
            _ = conn.send_buf.writeSlice(data);
            conn.recv_buf.reset();
            try self.ep.modify(
                conn.fd,
                epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered,
                conn.fd,
            );
        }
    }

    /// Pop the queue of connections handed over from other threads and register
    /// them with this reactor's epoll and registry. Only runs on the reactor
    /// thread (via the wakeup or at loop exit), so the map has a single owner.
    ///
    /// The queue is *moved* out of the shared list under the lock rather than
    /// copied: a concurrent `attach` may reallocate the list's backing array
    /// (freeing the old one), so any slice captured earlier would be a
    /// use-after-free. `toOwnedSlice` transfers ownership of the allocation to
    /// this thread; the caller frees it.
    fn drainPending(self: *Reactor) void {
        self.pending_lock.lock();
        if (self.pending.items.len == 0) {
            self.pending_lock.unlock();
            return;
        }
        const items = self.pending.toOwnedSlice(self.allocator) catch {
            self.pending_lock.unlock();
            return;
        };
        self.pending_lock.unlock();
        defer self.allocator.free(items);

        for (items) |conn| {
            self.ep.add(conn.fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, conn.fd) catch {
                conn.close();
                conn.destroy();
                continue;
            };
            if (self.connections.put(conn.fd, conn)) |_| {
                _ = self.registered.fetchAdd(1, .monotonic);
            } else |_| {
                self.ep.remove(conn.fd) catch {};
                conn.close();
                conn.destroy();
                continue;
            }
            if (self.mode == .http) {
                var session = HttpSession{
                    .parser = http_parser.Parser.init(self.allocator),
                    .req = http_parser.Request.init(self.allocator),
                };
                if (self.http_sessions.put(conn.fd, session)) |_| {
                } else |_| {
                    session.parser.deinit();
                    session.req.deinit();
                    self.ep.remove(conn.fd) catch {};
                    conn.close();
                    conn.destroy();
                }
            }
        }
    }

    fn removeConnection(self: *Reactor, fd: posix.fd_t) void {
        if (self.connections.fetchRemove(fd)) |kv| {
            const conn = kv.value;
            self.ep.remove(fd) catch {};
            conn.close();
            conn.destroy();
        }
        if (self.http_sessions.fetchRemove(fd)) |kv| {
            var sess = kv.value;
            sess.parser.deinit();
            sess.req.deinit();
        }
    }

    fn closeAllConnections(self: *Reactor) void {
        self.drainPending();
        var it = self.connections.valueIterator();
        while (it.next()) |c| {
            const conn = c.*;
            self.ep.remove(conn.fd) catch {};
            conn.close();
            conn.destroy();
        }
        self.connections.clearRetainingCapacity();
        var sit = self.http_sessions.valueIterator();
        while (sit.next()) |s| {
            s.parser.deinit();
            s.req.deinit();
        }
        self.http_sessions.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn readUntil(sock: posix.fd_t, buf: []u8, expected_len: usize, timeout_ms: u64) !usize {
    var total: usize = 0;
    const start = std.time.Instant.now() catch return error.Timeout;
    while (total < expected_len) {
        if ((std.time.Instant.now() catch return error.Timeout).since(start) > timeout_ms * std.time.ns_per_ms) {
            return error.Timeout;
        }
        // Read at most the remaining need; the socket may deliver more (e.g.
        // the next pipelined response) and the leftover stays buffered.
        const n = posix.read(sock, buf[total..expected_len]) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return error.Eof;
        total += n;
    }
    return total;
}

fn writeAll(sock: posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = posix.write(sock, remaining) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        remaining = remaining[n..];
    }
}

test "reactor startup and shutdown" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    // Explicit stop-then-join (LIFO defers would do this at scope exit; doing
    // it here keeps assertions below race-free).
    r.stop();
    r.join();
    try testing.expectEqual(@as(?std.Thread, null), r.thread);
    try testing.expectEqual(0, r.countConnections());
}

test "reactor echoes a connection attached from another thread" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn); // reactor takes ownership of conn incl. fd pair[1]

    const msg = "hello reactor echo";
    try writeAll(pair[0], msg);

    var buf: [64]u8 = undefined;
    const n = try readUntil(pair[0], &buf, msg.len, 3000);
    try testing.expectEqualStrings(msg, buf[0..n]);

    // Attach a second connection through the queue to make sure each pending
    // item is registered independently.
    const pair2 = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair2[0]);
    try sockets.setNonBlock(pair2[0]);
    try sockets.setNonBlock(pair2[1]);
    const conn2 = try connection.Connection.create(allocator, pair2[1]);
    r.attach(conn2);

    const msg2 = "second";
    try writeAll(pair2[0], msg2);
    var buf2: [16]u8 = undefined;
    const n2 = try readUntil(pair2[0], &buf2, msg2.len, 3000);
    try testing.expectEqualStrings(msg2, buf2[0..n2]);

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 2), r.countConnections());
}

test "reactor handles concurrent dispatch from many threads" {
    const allocator = std.heap.page_allocator; // client fds live across threads
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const producers = 8;
    const per_producer = 4;
    var handles: [producers]std.Thread = undefined;

    const Producer = struct {
        rid: *Reactor,
        alloc: std.mem.Allocator,
        failures: *std.atomic.Value(usize),

        fn run(p: *@This()) void {
            var i: usize = 0;
            while (i < per_producer) : (i += 1) {
                const pair = posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    return;
                };
                sockets.setNonBlock(pair[0]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                sockets.setNonBlock(pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                const conn = connection.Connection.create(p.alloc, pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                p.rid.attach(conn);

                var payload_buf: [64]u8 = undefined;
                const payload = std.fmt.bufPrint(&payload_buf, "from producer {d}-{d}", .{ 0, i }) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    return;
                };
                writeAll(pair[0], payload) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    return;
                };
                var echo_buf: [96]u8 = undefined;
                _ = readUntil(pair[0], &echo_buf, payload.len, 5000) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    return;
                };
                posix.close(pair[0]);
            }
        }
    };

    var failures = std.atomic.Value(usize).init(0);
    var producers_array: [producers]Producer = undefined;
    for (0..producers) |i| {
        producers_array[i] = .{ .rid = &r, .alloc = allocator, .failures = &failures };
        handles[i] = try std.Thread.spawn(.{}, Producer.run, .{&producers_array[i]});
    }
    for (0..producers) |i| {
        handles[i].join();
    }

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    // Every connection was dispatched and registered by the reactor. Live
    // connection count can be lower (producers close their client ends right
    // after the echo, and the reactor reaps the HUP), so assert on the
    // monotonic registration counter instead.
    try testing.expectEqual(@as(usize, producers * per_producer), r.registered.load(.monotonic));
}

const http_ok_empty = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";

test "reactor serves HTTP with keep-alive and body echo" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Request 1: simple GET, keep-alive default.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n1]);

    // Request 2 on the same connection: POST, body echoed.
    try writeAll(pair[0], "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    const want2 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 5\r\n\r\nhello";
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // Request 3: Connection: close -> response then EOF.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    const want3 = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    const n3 = try readUntil(pair[0], &buf, want3.len, 3000);
    try testing.expectEqualStrings(want3, buf[0..n3]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}

test "reactor HTTP handles pipelined requests in one write" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(
        pair[0],
        "POST /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nA" ++
            "POST /b HTTP/1.1\r\nContent-Length: 1\r\n\r\nB",
    );
    var buf: [512]u8 = undefined;
    const want_a = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 1\r\n\r\nA";
    const want_b = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 1\r\n\r\nB";
    const n1 = try readUntil(pair[0], &buf, want_a.len, 3000);
    try testing.expectEqualStrings(want_a, buf[0..n1]);
    const n2 = try readUntil(pair[0], &buf, want_b.len, 3000);
    try testing.expectEqualStrings(want_b, buf[0..n2]);
}

test "reactor HTTP error paths respond and close" {
    const allocator = testing.allocator;
    const cases = [_]struct { wire: []const u8, want: []const u8 }{
        .{
            .wire = "BREW / HTTP/1.1\r\n\r\n",
            .want = "HTTP/1.1 501 Not Implemented\r\nConnection: close\r\nContent-Length: 15\r\n\r\nNot Implemented",
        },
        .{
            .wire = "GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n",
            .want = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 11\r\n\r\nBad Request",
        },
        .{
            .wire = "GET / HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
            .want = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 11\r\n\r\nBad Request",
        },
    };
    for (cases) |c| {
        var r = try Reactor.init(allocator, 0, .http);
        defer r.deinit();
        try r.start();
        defer r.join();
        defer r.stop();

        const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);

        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);

        try writeAll(pair[0], c.wire);
        var buf: [512]u8 = undefined;
        const n = try readUntil(pair[0], &buf, c.want.len, 3000);
        try testing.expectEqualStrings(c.want, buf[0..n]);
        // Error responses close the connection.
        try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));

        r.stop();
        r.join();
    }
}

test "reactor HTTP oversized body yields 413 and closes" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    var body = [_]u8{'x'} ** (max_echo_body + 1);
    var wire_buf: [max_echo_body + 256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try writeAll(pair[0], wire);
    // Body arrives in a second chunk to exercise the partial-body path.
    std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
    try writeAll(pair[0], &body);

    const want = "HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\nContent-Length: 17\r\n\r\nPayload Too Large";
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}