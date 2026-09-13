const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 2048;

const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const SOCK_STREAM: u32 = 1;
const SOCK_CLOEXEC: u32 = 524288;
const SOL_SOCKET: u32 = 1;
const SO_REUSEADDR: u32 = 2;

/// Linux native (no BSD `sin_len`) internet socket address, 16 bytes. The
/// stdlib's older code defined the BSD-layout struct with a leading `sin_len`
/// byte which shifted the family field and broke `bind` on Linux.
const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8,
};

/// Linux native IPv6 socket address, 28 bytes (no `sin6_len`).
const sockaddr_in6 = extern struct {
    sin6_family: u16,
    sin6_port: u16,
    sin6_flowinfo: u32,
    sin6_addr: [16]u8,
    sin6_scope_id: u32,
};

/// Address family of a listening socket, used to create the right socket type.
pub const AddressFamily = enum { ipv4, ipv6 };

/// Full listen specification passed through config → multireactor → sockets.
pub const ListenSpec = struct {
    family: AddressFamily = .ipv4,
    /// Bind address: first 4 bytes used for IPv4 (network byte order),
    /// first 16 bytes used for IPv6 (network byte order). All-zero means
    /// bind to the wildcard address ([::] for IPv6, 0.0.0.0 for IPv4).
    addr: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    port: u16 = 0,
    /// When true, the IPv6 socket has IPV6_V6ONLY=1 (no IPv4-mapped
    /// addresses). When false (default), the IPv6 socket is dual-stack.
    ipv6_only: bool = false,
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

/// Create a listening socket from a full ListenSpec with SO_REUSEADDR and
/// optional SO_REUSEPORT. Dual-stack (IPv6 with IPV6_V6ONLY=0) is the
/// default when family is .ipv6.
pub fn createListeningSocketFromSpec(spec: ListenSpec, backlog: usize, reuse_port: bool) !posix.fd_t {
    const family: u16 = if (spec.family == .ipv6) AF_INET6 else AF_INET;
    const listener = try posix.socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0);
    errdefer posix.close(listener);
    try posix.setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (reuse_port) {
        try posix.setsockopt(listener, SOL_SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    // IPv6 dual-stack control: when ipv6_only is false (default), the socket
    // accepts both IPv4 and IPv6 connections via IPv4-mapped addresses.
    if (spec.family == .ipv6) {
        const v6only: c_int = if (spec.ipv6_only) 1 else 0;
        try posix.setsockopt(listener, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, &std.mem.toBytes(v6only));
    }
    try setNonBlock(listener);

    if (spec.family == .ipv6) {
        const addr = sockaddr_in6{
            .sin6_family = AF_INET6,
            .sin6_port = std.mem.nativeToBig(u16, spec.port),
            .sin6_flowinfo = 0,
            .sin6_addr = spec.addr,
            .sin6_scope_id = 0,
        };
        try posix.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in6));
    } else {
        const addr = sockaddr_in{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, spec.port),
            .sin_addr = std.mem.nativeToBig(u32, @as(u32, @intCast(spec.addr[0])) << 24 | @as(u32, @intCast(spec.addr[1])) << 16 | @as(u32, @intCast(spec.addr[2])) << 8 | @as(u32, @intCast(spec.addr[3]))),
            .sin_zero = [_]u8{0} ** 8,
        };
        try posix.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in));
    }
    try posix.listen(listener, @intCast(backlog));
    return listener;
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
/// with port 0 for tests). Works for both IPv4 and IPv6 sockets.
pub fn boundPort(fd: posix.fd_t) !u16 {
    // Use a raw buffer large enough for either sockaddr_in (16 bytes) or
    // sockaddr_in6 (28 bytes).
    var buf: [28]u8 align(@alignOf(u16)) = undefined;
    var len: posix.socklen_t = 28;
    const sa_ptr: *posix.sockaddr = @ptrCast(&buf);
    try posix.getsockname(fd, sa_ptr, &len);
    const family: u16 = @intCast(@as(u16, sa_ptr.family));
    if (family == AF_INET6) {
        const addr: *const sockaddr_in6 = @ptrCast(@alignCast(&buf));
        return std.mem.bigToNative(u16, addr.sin6_port);
    }
    const addr: *const sockaddr_in = @ptrCast(@alignCast(&buf));
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

/// Extract the peer IP from a connected socket and return it as a 16-byte
/// address. For IPv4 connections the address is stored as an IPv4-mapped
/// IPv6 address (`::ffff:a.b.c.d`) in bytes 12–15 (network byte order).
/// For IPv6 connections the full 16-byte address is returned.
/// Returns zeroes for non-INET peers (socketpairs in tests).
pub fn peerIp(fd: posix.fd_t) [16]u8 {
    // Probe with a raw buffer large enough for either sockaddr type.
    var buf: [28]u8 align(@alignOf(u16)) = undefined;
    var len: posix.socklen_t = 28;
    const sa_ptr: *posix.sockaddr = @ptrCast(&buf);
    if (posix.getpeername(fd, sa_ptr, &len)) |_| {
        const family: u16 = @intCast(@as(u16, sa_ptr.family));
        if (family == AF_INET6) {
            const addr: *const sockaddr_in6 = @ptrCast(@alignCast(&buf));
            return addr.sin6_addr;
        }
        if (family == AF_INET) {
            const addr: *const sockaddr_in = @ptrCast(@alignCast(&buf));
            // Return as IPv4-mapped IPv6: ::ffff:a.b.c.d
            const bytes = std.mem.toBytes(addr.sin_addr);
            return .{
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0xff, 0xff,
                bytes[0], bytes[1], bytes[2], bytes[3],
            };
        }
    } else |_| {}
    return .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}

/// Format a 16-byte IP address (stored as IPv4-mapped or raw IPv6) into
/// `buf` and return the formatted string. IPv4-mapped addresses are printed
/// as dotted-decimal; pure IPv6 is printed in RFC 5952 canonical form.
pub fn fmtIp(ip: [16]u8, buf: []u8) []const u8 {
    if (isIPv4Mapped(ip)) {
        // Dotted-decimal for IPv4-mapped addresses.
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[12], ip[13], ip[14], ip[15] }) catch "-";
    }
    // Full IPv6: hex groups separated by ':', canonical form.
    return fmtIpv6(ip, buf);
}

/// True if the 16-byte address is an IPv4-mapped IPv6 address
/// (`::ffff:a.b.c.d` — first 10 bytes zero, bytes 10-11 = 0xff 0xff).
pub fn isIPv4Mapped(ip: [16]u8) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0 and
        ip[4] == 0 and ip[5] == 0 and ip[6] == 0 and ip[7] == 0 and
        ip[8] == 0 and ip[9] == 0 and ip[10] == 0xff and ip[11] == 0xff;
}

/// Format a 16-byte IPv6 address in RFC 5952 canonical form.
fn fmtIpv6(ip: [16]u8, buf: []u8) []const u8 {
    // Find the longest run of consecutive zero groups (for :: compression).
    var best_start: usize = 0;
    var best_len: usize = 0;
    var cur_start: usize = 0;
    var cur_len: usize = 0;
    for (0..8) |i| {
        const hi = ip[i * 2];
        const lo = ip[i * 2 + 1];
        if (hi == 0 and lo == 0) {
            if (cur_len == 0) cur_start = i;
            cur_len += 1;
            if (cur_len > best_len) {
                best_start = cur_start;
                best_len = cur_len;
            }
        } else {
            cur_len = 0;
        }
    }
    // Need at least 2 consecutive zero groups to use ::.
    if (best_len < 2) best_len = 0;

    var pos: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (best_len > 0 and i >= best_start and i < best_start + best_len) {
            if (i == best_start) {
                if (pos + 1 <= buf.len) buf[pos] = ':';
                pos += 1;
                if (pos + 1 <= buf.len) buf[pos] = ':';
                pos += 1;
            }
            i = best_start + best_len - 1; // loop will i += 1
            continue;
        }
        if (i > 0 and notCompressed(best_start, best_len, i)) {
            if (pos + 1 <= buf.len) buf[pos] = ':';
            pos += 1;
        }
        const group: u16 = @as(u16, ip[i * 2]) << 8 | ip[i * 2 + 1];
        const printed = std.fmt.bufPrint(buf[pos..], "{x}", .{group}) catch break;
        pos += printed.len;
    }
    if (pos == 0) {
        @memcpy(buf[0..2], "::");
        return buf[0..2];
    }
    return buf[0..pos];
}

fn notCompressed(best_start: usize, best_len: usize, i: usize) bool {
    return best_len == 0 or i < best_start or i >= best_start + best_len;
}

/// Enable TCP_NODELAY on a connected socket (accepted connections).
/// nginx (default), Caddy and Bun all enable it; without it, small
/// two-part responses can stall on the Nagle/delayed-ACK interlock.
pub fn setTcpNoDelay(fd: posix.fd_t) void {
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
}

/// Set TCP_CORK (Linux) to batch small writes into one segment.
/// Used around sendfile to coalesce the HTTP head + file body into a single
/// TCP segment (equivalent to nginx's tcp_nopush on). Must be cleared
/// (uncorked) after the sendfile completes to flush any buffered data.
pub fn setTcpCork(fd: posix.fd_t) void {
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.CORK, &std.mem.toBytes(@as(c_int, 1))) catch {};
}

/// Clear TCP_CORK to flush any buffered data and revert to normal write
/// semantics (TCP_NODELAY remains in effect).
pub fn clearTcpCork(fd: posix.fd_t) void {
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.CORK, &std.mem.toBytes(@as(c_int, 0))) catch {};
}
