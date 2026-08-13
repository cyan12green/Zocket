const std = @import("std");
const posix = std.posix;
const buffer = @import("buffer.zig");
const timer_wheel = @import("timer_wheel.zig");

/// A connection owns its transport buffers inline (16 KiB read + write
/// embedded in the struct), so one allocation covers the whole object; the
/// reactor's connection pool (`ConnectionPool`) recycles the struct so
/// steady-state connections cost zero allocations. The buffers switch to
/// heap storage only when a request body forces a recv-buffer grow (bounded
/// by `max_recv_buffer`); that capacity is retained for reuse.
pub const Connection = struct {
    /// Upper bound for receive-buffer growth (per connection). Requests that
    /// still do not fit are rejected by the reactor's buffer-full path.
    pub const max_recv_buffer = 16 * 1024 * 1024;
    pub const default_buf_size = buffer.Buffer.default_size;

    fd: posix.fd_t = -1,
    allocator: std.mem.Allocator,
    /// Buffers as values: `data` points at the embedded storage below (or a
    /// heap allocation after a grow).
    recv_buf: buffer.Buffer,
    send_buf: buffer.Buffer,
    read_storage: [default_buf_size]u8 = undefined,
    write_storage: [default_buf_size]u8 = undefined,
    /// Idle-timeout timer slot (Milestone 5). Armed by the reactor when the
    /// connection is registered and re-armed on every recv; the reactor's
    /// timer wheel unlinks and fires it when the connection goes idle.
    timer: timer_wheel.TimerEntry = .{},
    /// Wheel tick the idle timer was last armed at (Milestone 14 follow-up):
    /// lets the reactor skip the rearm when back-to-back recvs fall in the
    /// same tick.
    timer_last_tick: u64 = 0,
    /// IPv4 address of the peer, in network byte order (Milestone 12; set by
    /// the accept path for the proxy module's X-Forwarded-For/X-Real-IP).
    peer_ip: [4]u8 = .{ 0, 0, 0, 0 },
    /// True when this object came from a reactor connection pool (free-list
    /// link in `next`); external connections (tests, attach path) destroy
    /// themselves on close.
    from_pool: bool = false,
    /// A ring read is in flight for this connection (io_uring backend).
    read_pending: bool = false,
    /// A ring write is in flight (echo mode; HTTP mode uses session.writing).
    write_pending: bool = false,
    /// The iovec array of the in-flight ring write (echo mode).
    write_iovs: [1]posix.iovec_const = undefined,
    /// Close deferred until the pending ring read is cancelled.
    closing: bool = false,
    /// Free-list link used while the connection is pooled.
    next: ?*Connection = null,

    /// Cold path: one allocation for the whole connection.
    pub fn create(allocator: std.mem.Allocator, fd: posix.fd_t) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .allocator = allocator,
            .recv_buf = buffer.Buffer.fromSlice(&conn.read_storage),
            .send_buf = buffer.Buffer.fromSlice(&conn.write_storage),
        };
        return conn;
    }

    /// Free everything (grown buffers + the struct itself).
    pub fn destroy(self: *Connection) void {
        self.recv_buf.deinitData(self.allocator);
        self.send_buf.deinitData(self.allocator);
        self.allocator.destroy(self);
    }

    /// Reset for pooling: the buffers keep their capacity (grown ones stay
    /// warm), timer/state are cleared.
    pub fn reset(self: *Connection) void {
        self.fd = -1;
        self.recv_buf.reset();
        self.send_buf.reset();
        self.timer = .{};
        self.timer_last_tick = 0;
        self.peer_ip = .{ 0, 0, 0, 0 };
        self.read_pending = false;
        self.write_pending = false;
        self.closing = false;
        self.next = null;
    }

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    pub fn recv(self: *Connection) !usize {
        const available = self.recv_buf.availableWrite();
        if (available == 0) {
            self.recv_buf.compact();
            if (self.recv_buf.availableWrite() == 0) {
                if (self.recv_buf.data.len < max_recv_buffer) {
                    // Request larger than the default buffer (e.g. a big body):
                    // grow instead of rejecting, up to the per-connection cap.
                    // Doubling lands exactly on the cap (powers of two), so the
                    // buffer can never exceed it; at the cap recv returns
                    // BufferFull and the reactor rejects the request.
                    try self.recv_buf.grow(self.allocator, @min(max_recv_buffer, self.recv_buf.data.len * 2));
                    std.debug.assert(self.recv_buf.data.len <= max_recv_buffer);
                } else {
                    return error.BufferFull;
                }
            }
        }

        const slice = self.recv_buf.data[self.recv_buf.write_pos..];
        const n = posix.read(self.fd, slice) catch |e| return e;
        if (n > 0) {
            self.recv_buf.write_pos += @intCast(n);
        }
        return n;
    }

    pub fn send(self: *Connection) !usize {
        if (self.send_buf.availableRead() == 0) {
            return 0;
        }

        const slice = self.send_buf.peek();
        const n = posix.write(self.fd, slice) catch |e| return e;
        if (n > 0) {
            self.send_buf.read_pos += @intCast(n);
            self.send_buf.compact();
        }
        return n;
    }

    pub fn enqueue(self: *Connection, data: []const u8) void {
        _ = self.send_buf.writeSlice(data);
    }
};

/// Per-reactor connection pool (nginx-style recycling): connections are
/// acquired on accept and released on close; once warm, accept/close costs
/// zero allocations and zero syscalls for the connection objects. Bounded
/// by `max_pooled`; overflow connections are destroyed outright.
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    free: ?*Connection = null,
    count: usize = 0,
    max_pooled: usize = 1024,

    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConnectionPool) void {
        while (self.free) |c| {
            self.free = c.next;
            c.destroy();
        }
        self.count = 0;
    }

    /// Take a connection off the free list, or cold-create one.
    pub fn acquire(self: *ConnectionPool, fd: posix.fd_t) !*Connection {
        if (self.free) |c| {
            self.free = c.next;
            c.next = null;
            c.fd = fd;
            return c;
        }
        const c = try Connection.create(self.allocator, fd);
        c.from_pool = true;
        return c;
    }

    /// Return a connection to the pool (resetting it for reuse) or destroy
    /// it when the pool is full.
    pub fn release(self: *ConnectionPool, c: *Connection) void {
        c.reset();
        if (self.count >= self.max_pooled) {
            c.destroy();
            return;
        }
        c.next = self.free;
        self.free = c;
        self.count += 1;
    }

    pub fn pooledCount(self: *const ConnectionPool) usize {
        return self.count;
    }
};

const testing = std.testing;

test "connection embeds its buffers" {
    const allocator = testing.allocator;
    const conn = try Connection.create(allocator, 99);
    defer conn.destroy();
    try testing.expectEqual(@as(usize, 16384), conn.recv_buf.data.len);
    try testing.expectEqual(@as(usize, 16384), conn.send_buf.data.len);
    try testing.expect(!conn.recv_buf.owns_data);
    _ = conn.recv_buf.writeSlice("hello");
    try testing.expectEqualStrings("hello", conn.recv_buf.peek());
}

test "connection buffer grow switches to heap and retains capacity" {
    const allocator = testing.allocator;
    const conn = try Connection.create(allocator, 99);
    defer conn.destroy();
    try conn.recv_buf.grow(allocator, 65536);
    try testing.expectEqual(@as(usize, 65536), conn.recv_buf.data.len);
    try testing.expect(conn.recv_buf.owns_data);
}

test "connection pool recycles without allocation" {
    const allocator = testing.allocator;
    var pool = ConnectionPool.init(allocator);
    defer pool.deinit();

    const c1 = try pool.acquire(11);
    try testing.expect(c1.from_pool);
    try testing.expectEqual(@as(posix.fd_t, 11), c1.fd);
    _ = c1.recv_buf.writeSlice("data");
    pool.release(c1);
    try testing.expectEqual(@as(usize, 1), pool.pooledCount());
    try testing.expectEqual(@as(posix.fd_t, -1), c1.fd);

    // Acquire again: same object, buffers warm (capacity kept).
    const c2 = try pool.acquire(22);
    try testing.expect(c1 == c2);
    try testing.expectEqual(@as(posix.fd_t, 22), c2.fd);
    try testing.expectEqual(@as(usize, 0), c2.recv_buf.availableRead());
    try testing.expectEqual(@as(usize, 0), c2.recv_buf.availableWrite() - 16384);
    pool.release(c2);
}
