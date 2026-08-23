const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 2048;

const AF_INET: u16 = 2;
const SOCK_STREAM: u32 = 1;
const SOCK_CLOEXEC: u32 = 524288;
const SOL_SOCKET: u32 = 1;
const SO_REUSEADDR: u32 = 2;

/// Linux native (no BSD `sin_len`) internet socket address, 16 bytes. The
/// The stdlib's older code defined the BSD-layout struct with a leading `sin_len`
/// byte which shifted the family field and broke `bind` on Linux.
const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8,
};

pub fn setNonBlock(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, F_GETFL, 0);
    _ = try posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/// Create a non-blocking IPv4 TCP listener bound to 127.0.0.1:port with
/// SO_REUSEADDR, listening on the given backlog.
pub fn createListeningSocket(port: u16, backlog: usize) !posix.fd_t {
    return createListeningSocketFlags(port, backlog, false);
}

/// Like `createListeningSocket`, but with SO_REUSEPORT the
/// kernel load-balances inbound connections across every listener on the
/// port, letting each reactor accept directly.
pub fn createListeningSocketReusePort(port: u16, backlog: usize) !posix.fd_t {
    return createListeningSocketFlags(port, backlog, true);
}

fn createListeningSocketFlags(port: u16, backlog: usize, reuse_port: bool) !posix.fd_t {
    const listener = try posix.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    errdefer posix.close(listener);
    try posix.setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (reuse_port) {
        try posix.setsockopt(listener, SOL_SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try setNonBlock(listener);

    const addr = sockaddr_in{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, port),
        // 127.0.0.1: memory bytes 7f 00 00 01.
        .sin_addr = std.mem.nativeToBig(u32, 0x7f000001),
        .sin_zero = [_]u8{0} ** 8,
    };

    try posix.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in));
    try posix.listen(listener, @intCast(backlog));
    return listener;
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    FdQuotaExceeded,
    SystemResources,
    NotListening,
    Unexpected,
};

/// Raw accept4 wrapper.
///
/// std.posix.accept cannot be used with this Zig snapshot: its declared
/// `AcceptError` set omits `error.SocketNotListening` which its own body emits
/// (`.INVAL => return error.SocketNotListening`), so any call site fails to
/// type-check. Accept with SOCK.NONBLOCK | SOCK.CLOEXEC.
pub fn acceptNonBlock(listener: posix.fd_t) AcceptError!posix.fd_t {
    const flags: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const rc = linux.accept4(listener, null, null, flags);
    const err = posix.errno(rc);
    return switch (err) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        // Retried by the caller's accept drain loop; treat like WouldBlock so
        // the loop keeps draining the remaining backlog.
        .INTR => error.WouldBlock,
        .CONNABORTED => error.ConnectionAborted,
        .MFILE => error.FdQuotaExceeded,
        .NFILE => error.FdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .INVAL => error.NotListening,
        else => error.Unexpected,
    };
}

/// Resolve the actual bound port of a listening socket (useful when binding
/// with port 0 for tests).
pub fn boundPort(fd: posix.fd_t) !u16 {
    var addr: sockaddr_in = undefined;
    var len: posix.socklen_t = @sizeOf(sockaddr_in);
    try posix.getsockname(fd, @as(*posix.sockaddr, @ptrCast(&addr)), &len);
    return std.mem.bigToNative(u16, addr.sin_port);
}

/// Pin the calling thread to a single CPU from the allowed set.
/// Best-effort: failure (e.g. sandboxed environment) is ignored.
pub fn pinToCpu(cpu: usize) void {
    const set_full = posix.sched_getaffinity(0) catch return;
    var set: posix.cpu_set_t = undefined;
    @memset(std.mem.asBytes(&set), 0);
    var seen: usize = 0;
    var target: ?usize = null;
    for (set_full, 0..) |word, word_idx| {
        var bit_idx: usize = 0;
        var w = word;
        while (w != 0) : (w >>= 1) {
            if (w & 1 != 0) {
                if (seen == cpu) {
                    target = word_idx * 64 + bit_idx;
                    break;
                }
                seen += 1;
            }
            bit_idx += 1;
        }
        if (target != null) break;
    }
    const cpu_idx = target orelse return;
    set[cpu_idx / 64] |= @as(usize, 1) << @intCast(cpu_idx % 64);
    linux.sched_setaffinity(0, &set) catch {};
}
/// IPv4 address of the peer (network byte order), or zeroes for non-INET
/// peers (socketpairs in tests). Used for proxy headers.
pub fn peerIp(fd: posix.fd_t) [4]u8 {
    var addr: sockaddr_in = undefined;
    var len: posix.socklen_t = @sizeOf(sockaddr_in);
    if (posix.getpeername(fd, @as(*posix.sockaddr, @ptrCast(&addr)), &len)) |_| {
        if (addr.sin_family == AF_INET) {
            return std.mem.toBytes(addr.sin_addr);
        }
    } else |_| {}
    return .{ 0, 0, 0, 0 };
}

/// Enable TCP_NODELAY on a connected socket (accepted connections).
/// nginx (default), Caddy and Bun all enable it; without it, small
/// two-part responses can stall on the Nagle/delayed-ACK interlock.
pub fn setTcpNoDelay(fd: posix.fd_t) void {
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
}
