const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const eventfd = @import("eventfd.zig");
const connection = @import("connection.zig");
const sockets = @import("sockets.zig");

const max_events = 1024;

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
    ep: epoll.Epoll,
    wakeup: eventfd.EventFd,
    connections: std.AutoHashMap(posix.fd_t, *connection.Connection),
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    pending: std.ArrayList(*connection.Connection),
    pending_lock: std.Thread.Mutex,
    /// Total connections this reactor has registered, ever. Bumped on the
    /// reactor thread when a pending connection is added to the registry;
    /// monotonic, so tests can assert dispatch happened without racing
    /// connection reaping.
    registered: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, id: usize) !Reactor {
        var self = Reactor{
            .allocator = allocator,
            .id = id,
            .ep = try epoll.Epoll.create(),
            .wakeup = try eventfd.EventFd.create(),
            .connections = std.AutoHashMap(posix.fd_t, *connection.Connection).init(allocator),
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
        const n = posix.read(sock, buf[total..]) catch {
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
    var r = try Reactor.init(allocator, 0);
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
    var r = try Reactor.init(allocator, 0);
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
    var r = try Reactor.init(allocator, 0);
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