const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Thin wrapper over std's io_uring for the reactor: connection reads and
/// writes are submitted to the ring and completed in batches, so there is
/// no EAGAIN drain probe and no per-request write syscall. The ring's own
/// fd is epoll-registered: it is readable whenever completions are ready,
/// which lets the existing epoll loop stay in charge of accept, wakeup and
/// timers.
pub const IoRing = struct {
    ring: linux.IoUring = undefined,
    inited: bool = false,

    pub const completion_batch = 128;

    pub const Completion = struct {
        user_data: u64,
        result: i32,
    };

    /// Tags in the high bits of user_data: the low 32 bits are the fd.
    pub const poll_tag: u64 = 1 << 63;
    pub const cancel_tag: u64 = 1 << 61;

    pub fn init() !IoRing {
        var self = IoRing{};
        self.ring = linux.IoUring.init(1024, 0) catch return error.RingInitFailed;
        self.inited = true;
        return self;
    }

    pub fn deinit(self: *IoRing) void {
        if (self.inited) self.ring.deinit();
    }

    pub fn ringFd(self: *const IoRing) posix.fd_t {
        return self.ring.fd;
    }

    /// Queue a read into `buf` for `fd` (user_data = fd). The buffer must
    /// stay valid until the completion arrives.
    pub fn submitRead(self: *IoRing, fd: posix.fd_t, buf: []u8) !void {
        _ = try self.ring.read(@as(u64, @intCast(fd)), fd, .{ .buffer = buf }, 0);
    }

    /// Queue a writev of `iovs` (user_data = fd | write_tag).
    pub fn submitWritev(self: *IoRing, fd: posix.fd_t, iovs: []const posix.iovec_const) !void {
        _ = try self.ring.writev(@as(u64, @intCast(fd)) | write_tag, fd, iovs, 0);
    }

    /// Queue a POLLOUT wait (user_data = fd | poll_tag): used to resume
    /// sendfile when the socket is not writable.
    pub fn submitPollOut(self: *IoRing, fd: posix.fd_t) !void {
        _ = try self.ring.poll_add(@as(u64, @intCast(fd)) | poll_tag, fd, linux.POLL.OUT);
    }

    /// Cancel the pending op tagged `fd` (a connection's in-flight read);
    /// the cancel's own completion arrives tagged cancel_tag.
    pub fn submitCancel(self: *IoRing, fd: posix.fd_t) !void {
        _ = try self.ring.cancel(@as(u64, @intCast(fd)) | cancel_tag, @as(u64, @intCast(fd)), 0);
    }

    pub const write_tag: u64 = 1 << 62;

    pub fn submit(self: *IoRing) !void {
        _ = try self.ring.submit();
    }

    /// Drain ready completions into `out`; returns the count. When `wait`,
    /// blocks until at least one completion is available.
    pub fn drain(self: *IoRing, out: []Completion, wait: bool) !usize {
        // When the CQ overflowed, the kernel parks completions in an
        // internal list until an enter(GETEVENTS) flushes them back; never
        // skip that flush (it is what copy_cqes does below).
        if (self.ring.cq_ready() == 0 and !self.ring.cq_ring_needs_flush() and !wait) return 0;
        var cqes: [completion_batch]linux.io_uring_cqe = undefined;
        const n = try self.ring.copy_cqes(&cqes, if (wait) 1 else 0);
        var count: usize = 0;
        for (cqes[0..n]) |cqe| {
            out[count] = .{ .user_data = cqe.user_data, .result = cqe.res };
            count += 1;
        }
        // copy_cqes already advances the CQ head - do not advance again.
        return count;
    }
};

const testing = std.testing;

test "io_uring read/write on a socketpair" {
    var ring = IoRing.init() catch return error.SkipZigTest;
    defer ring.deinit();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);
    try posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(posix.timeval{ .sec = 1, .usec = 0 }));

    var buf: [64]u8 = undefined;
    try ring.submitRead(pair[1], &buf);
    try ring.submit();

    // No data yet: the read must stay pending (no EAGAIN).
    var comps: [4]IoRing.Completion = undefined;
    try testing.expectEqual(@as(usize, 0), try ring.drain(&comps, false));

    _ = try posix.write(pair[0], "hello");
    const n = try ring.drain(&comps, true);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 5), comps[0].result);
    try testing.expectEqual(@as(u64, @intCast(pair[1])), comps[0].user_data);
    try testing.expectEqualStrings("hello", buf[0..5]);
}
