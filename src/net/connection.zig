const std = @import("std");
const posix = std.posix;
const buffer = @import("buffer.zig");
const timer_wheel = @import("timer_wheel.zig");

pub const Connection = struct {
    /// Upper bound for receive-buffer growth (per connection). Requests that
    /// still do not fit are rejected by the reactor's buffer-full path.
    pub const max_recv_buffer = 16 * 1024 * 1024;

    fd: posix.fd_t,
    recv_buf: *buffer.Buffer,
    send_buf: *buffer.Buffer,
    allocator: std.mem.Allocator,
    /// Idle-timeout timer slot (Milestone 5). Armed by the reactor when the
    /// connection is registered and re-armed on every recv; the reactor's
    /// timer wheel unlinks and fires it when the connection goes idle.
    timer: timer_wheel.TimerEntry = .{},
    /// IPv4 address of the peer, in network byte order (Milestone 12; set by
    /// the accept path for the proxy module's X-Forwarded-For/X-Real-IP).
    peer_ip: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn create(allocator: std.mem.Allocator, fd: posix.fd_t) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .recv_buf = try buffer.Buffer.init(allocator),
            .send_buf = try buffer.Buffer.init(allocator),
            .allocator = allocator,
        };
        return conn;
    }

    pub fn destroy(self: *Connection) void {
        self.recv_buf.deinit(self.allocator);
        self.send_buf.deinit(self.allocator);
        self.allocator.destroy(self);
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