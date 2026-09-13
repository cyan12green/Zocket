const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const EPOLL_CLOEXEC = 0x80000;
const EPOLLIN = 0x1;
const EPOLLOUT = 0x4;
const EPOLLET = 0x80000000;
const EPOLLHUP = 0x10;
const EPOLLERR = 0x8;
const EPOLL_CTL_ADD = 1;
const EPOLL_CTL_MOD = 3;
const EPOLL_CTL_DEL = 2;

pub const Epoll = struct {
    fd: posix.fd_t,

    pub fn create() !Epoll {
        const fd = try posix.epoll_create1(EPOLL_CLOEXEC);
        return Epoll{ .fd = fd };
    }

    pub fn close(self: Epoll) void {
        posix.close(self.fd);
    }

    pub fn add(self: Epoll, fd: posix.fd_t, events: u32, data: posix.fd_t) !void {
        var event = linux.epoll_event{
            .events = events,
            .data = .{ .ptr = @intCast(data) },
        };
        try posix.epoll_ctl(self.fd, EPOLL_CTL_ADD, fd, &event);
    }

    pub fn modify(self: Epoll, fd: posix.fd_t, events: u32, data: posix.fd_t) !void {
        var event = linux.epoll_event{
            .events = events,
            .data = .{ .ptr = @intCast(data) },
        };
        try posix.epoll_ctl(self.fd, EPOLL_CTL_MOD, fd, &event);
    }

    pub fn remove(self: Epoll, fd: posix.fd_t) !void {
        try posix.epoll_ctl(self.fd, EPOLL_CTL_DEL, fd, null);
    }

    pub fn wait(self: *Epoll, events: []linux.epoll_event, timeout_ms: i32) !usize {
        // Use the raw syscall instead of posix.epoll_wait: the Zig 0.16.0-dev
        // stdlib maps EBADF to unreachable (panic), but a reactor's epoll fd
        // may be closed by deinit() while another reactor thread is still in
        // its loop — returning an error is safer than panicking.
        const rc = linux.epoll_wait(self.fd, @ptrCast(events.ptr), @intCast(events.len), timeout_ms);
        // Raw syscall returns negated errno on error (high bit set = negative).
        if (@as(isize, @bitCast(rc)) < 0) {
            const errno_num = @as(u16, @intCast(-@as(isize, @bitCast(rc))));
            // EBADF = 9: fd was closed while the reactor was still looping.
            if (errno_num == 9) return error.BadFd;
            return error.Unexpected;
        }
        return rc;
    }
};

pub const Events = struct {
    pub const In = EPOLLIN;
    pub const Out = EPOLLOUT;
    pub const EdgeTriggered = EPOLLET;
    pub const Hangup = EPOLLHUP;
    pub const Error = EPOLLERR;
};

test "epoll create" {
    const epoll = try Epoll.create();
    defer epoll.close();
    try testing.expect(epoll.fd > 0);
}

const testing = std.testing;
