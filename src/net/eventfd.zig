const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Non-blocking eventfd used to wake a reactor thread (or an accept loop) out
/// of epoll_wait. Reads and writes are best-effort; the counter is drained on
/// read and bumped by 1 on each write.
pub const EventFd = struct {
    fd: posix.fd_t,

    pub fn create() !EventFd {
        const fd = try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        return .{ .fd = fd };
    }

    pub fn close(self: EventFd) void {
        posix.close(self.fd);
    }

    /// Signal the fd. Non-blocking write of one 8-byte counter value; if the
    /// counter is already saturated this is a no-op.
    pub fn write(self: EventFd) void {
        const value: u64 = 1;
        _ = posix.write(self.fd, std.mem.asBytes(&value)) catch {};
    }

    /// Drain the counter, resetting it to 0 so the fd stops reporting readable.
    pub fn read(self: EventFd) void {
        var value: u64 = 0;
        _ = posix.read(self.fd, std.mem.asBytes(&value)) catch {};
    }
};

const testing = std.testing;

test "eventfd write/read round-trip" {
    const ev = try EventFd.create();
    defer ev.close();

    ev.write();
    var value: u64 = 0;
    const n = try posix.read(ev.fd, std.mem.asBytes(&value));
    try testing.expectEqual(8, n);
    try testing.expectEqual(1, value);

    var drained: u64 = 0;
    try testing.expectError(error.WouldBlock, posix.read(ev.fd, std.mem.asBytes(&drained)));
}

test "eventfd multiple writes coalesce into one counter" {
    const ev = try EventFd.create();
    defer ev.close();

    ev.write();
    ev.write();
    ev.write();

    var value: u64 = 0;
    try testing.expectEqual(8, (try posix.read(ev.fd, std.mem.asBytes(&value))));
    try testing.expectEqual(3, value);
}