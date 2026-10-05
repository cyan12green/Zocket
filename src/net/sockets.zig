const std = @import("std");
const compat = @import("../compat.zig");
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
    const flags = try compat.fcntl(fd, F_GETFL, 0);
    _ = try compat.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
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
    const listener = try compat.socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0);
    errdefer compat.close(listener);
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
        try compat.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in6));
    } else {
        const addr = sockaddr_in{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, spec.port),
            .sin_addr = std.mem.nativeToBig(u32, @as(u32, @intCast(spec.addr[0])) << 24 | @as(u32, @intCast(spec.addr[1])) << 16 | @as(u32, @intCast(spec.addr[2])) << 8 | @as(u32, @intCast(spec.addr[3]))),
            .sin_zero = @as([8]u8, @splat(@as(u8, 0))),
        };
        try compat.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in));
    }
    try compat.listen(listener, @intCast(backlog));
    return listener;
}

fn createListeningSocketFlags(port: u16, backlog: usize, reuse_port: bool) !posix.fd_t {
    const listener = try compat.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    errdefer compat.close(listener);
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
        .sin_zero = @as([8]u8, @splat(@as(u8, 0))),
    };

    try compat.bind(listener, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_in));
    try compat.listen(listener, @intCast(backlog));
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
    const err = linux.errno(rc);
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
    try compat.getsockname(fd, sa_ptr, &len);
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
        // Separator between two printed groups only: never adjacent to
        // the "::" compression (it already ends/starts with colons).
        if (i > 0) {
            const prev_compressed = best_len > 0 and (i - 1) >= best_start and (i - 1) < best_start + best_len;
            if (!prev_compressed) {
                if (pos + 1 <= buf.len) buf[pos] = ':';
                pos += 1;
            }
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

const testing = std.testing;

test "sockets: fmtIp renders v4-mapped and v6 canonical forms" {
    var buf: [64]u8 = undefined;
    const v4 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
    try testing.expect(isIPv4Mapped(v4));
    try testing.expectEqualStrings("127.0.0.1", fmtIp(v4, &buf));
    const v6zero = @as([16]u8, @splat(@as(u8, 0)));
    try testing.expect(!isIPv4Mapped(v6zero));
    try testing.expectEqualStrings("::", fmtIp(v6zero, &buf));
    const loopback = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualStrings("::1", fmtIp(loopback, &buf));
    // Single zero group is NOT compressed (needs 2+).
    const single = [_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0x01, 0, 0x02, 0, 0x03, 0, 0x04, 0, 0x05 };
    try testing.expectEqualStrings("2001:db8:0:1:2:3:4:5", fmtIp(single, &buf));
    // Longest run wins; ties prefer the first (RFC 5952 §4.2.3).
    const tied = [_]u8{ 0x20, 0x01, 0, 0, 0, 0, 0, 0x01, 0, 0x02, 0, 0, 0, 0, 0, 0x03 };
    try testing.expectEqualStrings("2001::1:2:0:0:3", fmtIp(tied, &buf));
    // Short buffer truncates without crashing.
    var tiny: [4]u8 = undefined;
    _ = fmtIp(v4, &tiny);
}

test "sockets: listeners bind ephemeral ports, peers resolve" {
    const fd = try createListeningSocket(0, 8);
    defer compat.close(fd);
    const port = try boundPort(fd);
    try testing.expect(port != 0);

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    defer compat.close(pair[1]);
    // Socketpair peers are not INET: zeroes.
    try testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, peerIp(pair[0]));

    // Connected TCP peer resolves to mapped 127.0.0.1.
    const cfd = try compat.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer compat.close(cfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[2] = @intCast(port >> 8);
    addr[3] = @intCast(port & 0xff);
    addr[4] = 127;
    addr[7] = 1;
    try compat.connect(cfd, @ptrCast(&addr), 16);
    const afd = try acceptNonBlock(fd);
    defer compat.close(afd);
    const peer = peerIp(afd);
    try testing.expect(isIPv4Mapped(peer));
    var pbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1", fmtIp(peer, &pbuf));

    // No further backlog: WouldBlock, not an error.
    try testing.expectError(error.WouldBlock, acceptNonBlock(fd));

    // Socket options apply without error; NODELAY reads back set.
    setTcpNoDelay(cfd);
    var nodelay: [4]u8 = undefined;
    try compat.getsockopt(cfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &nodelay);
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, &nodelay, .little));
    setTcpCork(cfd);
    clearTcpCork(cfd);
    try setNonBlock(cfd);
    pinToCpu(0); // best-effort, must not crash
}

/// IP literal parsers (shared by conf `listen` and the access/realip
/// CIDR machinery). v4 yields IPv4-mapped IPv6 (`::ffff:a.b.c.d`), so one
/// 16-byte compare covers both families.

pub fn parseIpv4(s: []const u8) ?[16]u8 {
    var result: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 };
    var i: usize = 0;
    var octet_idx: usize = 0;
    while (octet_idx < 4) : (octet_idx += 1) {
        if (i >= s.len) return null;
        var val: u16 = 0;
        var digits: usize = 0;
        while (i < s.len and s[i] != '.') : (i += 1) {
            if (s[i] < '0' or s[i] > '9') return null;
            val = val * 10 + (s[i] - '0');
            digits += 1;
        }
        if (digits == 0 or val > 255) return null;
        result[12 + octet_idx] = @intCast(val);
        if (octet_idx < 3) {
            if (i >= s.len or s[i] != '.') return null;
            i += 1;
        }
    }
    if (i != s.len) return null;
    return result;
}

/// Parse an IPv6 address literal. Returns the 16-byte address in
/// network byte order, or null on failure. Supports full form, compressed
/// (::), and IPv4-mapped (::ffff:a.b.c.d).
pub fn parseIpv6(s: []const u8) ?[16]u8 {
    // Handle the :: compression by splitting on "::" and parsing both sides.
    if (std.mem.indexOf(u8, s, "::")) |dbl| {
        const left_str = s[0..dbl];
        const right_str = s[dbl + 2 ..];
        // Count groups on each side.
        var left_groups: usize = 0;
        if (left_str.len > 0) {
            var tmp = left_str;
            while (std.mem.indexOfScalar(u8, tmp, ':')) |pos| {
                left_groups += 1;
                tmp = tmp[pos + 1 ..];
            }
            left_groups += 1; // last group
        }
        var right_groups: usize = 0;
        if (right_str.len > 0) {
            var tmp = right_str;
            while (std.mem.indexOfScalar(u8, tmp, ':')) |pos| {
                right_groups += 1;
                tmp = tmp[pos + 1 ..];
            }
            right_groups += 1;
        }
        const missing = 8 - left_groups - right_groups;
        if (missing < 0) return null;
        var result: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var idx: usize = 0;
        // Parse left groups.
        if (left_str.len > 0) {
            idx = parseIpv6Groups(left_str, &result, 0);
        }
        // Fill compressed groups with zeros.
        for (0..missing * 2) |_| {
            if (idx < 16) {
                result[idx] = 0;
                idx += 1;
            }
        }
        // Parse right groups.
        if (right_str.len > 0) {
            _ = parseIpv6Groups(right_str, &result, idx);
        }
        return result;
    }
    // No :: — parse up to 8 hex groups.
    var result: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = parseIpv6Groups(s, &result, 0);
    return result;
}

/// Parse hex groups from an IPv6 address string into `result` starting at
/// byte offset `start`. Returns the number of bytes written.
fn parseIpv6Groups(s: []const u8, result: *[16]u8, start: usize) usize {
    var pos = start;
    var i: usize = 0;
    while (i < s.len) {
        // Read up to 4 hex chars.
        var val: u16 = 0;
        var digits: usize = 0;
        while (i < s.len and s[i] != ':') : (i += 1) {
            const c = s[i];
            const d = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return 0;
            val = val * 16 + d;
            digits += 1;
        }
        if (digits > 0 and pos + 1 < 16) {
            result[pos] = @intCast(val >> 8);
            result[pos + 1] = @intCast(val & 0xff);
            pos += 2;
        }
        if (i < s.len and s[i] == ':') i += 1;
    }
    return pos;
}


/// A CIDR prefix over the 16-byte address space (v4 stored mapped).
pub const Cidr = struct {
    addr: [16]u8 = @as([16]u8, @splat(@as(u8, 0))),
    bits: u8 = 0,
};

/// Parse `all`, a bare IP literal, or `addr/bits`. `all` is the /0 catch-all.
/// Bare v4 defaults to /32, bare v6 to /128. Returns null on garbage.
pub fn parseCidr(s: []const u8) ?Cidr {
    if (std.mem.eql(u8, s, "all")) return .{ .bits = 0 };
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        const addr = parseIp(s[0..slash]) orelse return null;
        const bits = std.fmt.parseInt(u8, s[slash + 1 ..], 10) catch return null;
        const max: u8 = if (isIPv4Mapped(addr)) 32 else 128;
        if (bits > max) return null;
        return .{ .addr = addr, .bits = bits };
    }
    const addr = parseIp(s) orelse return null;
    return .{ .addr = addr, .bits = if (isIPv4Mapped(addr)) 32 else 128 };
}

/// Parse a v4 or v6 literal (v6 takes precedence when both could match —
/// in practice dotted form only parses v4, colon form only v6).
pub fn parseIp(s: []const u8) ?[16]u8 {
    if (std.mem.indexOfScalar(u8, s, ':') != null) return parseIpv6(s);
    return parseIpv4(s);
}

/// True when `ip` falls inside `cidr` (prefix compare, network order).
/// v4-mapped addresses compare their last 4 bytes (a v4 /24 is bits of the
/// dotted quad, not of the leading zeroes); mismatched families only match
/// a /0.
pub fn cidrContains(cidr: Cidr, ip: [16]u8) bool {
    if (cidr.bits == 0) return true;
    const base: usize = if (isIPv4Mapped(cidr.addr)) 12 else 0;
    if (isIPv4Mapped(ip) != (base == 12)) return false;
    var bits = cidr.bits;
    var i: usize = base;
    while (bits >= 8) : (i += 1) {
        if (cidr.addr[i] != ip[i]) return false;
        bits -= 8;
    }
    if (bits > 0) {
        const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(bits));
        if ((cidr.addr[i] & mask) != (ip[i] & mask)) return false;
    }
    return true;
}

test "sockets: parseCidr covers all, bare IPs and prefixes" {
    const all = parseCidr("all").?;
    try testing.expectEqual(@as(u8, 0), all.bits);
    const v4 = parseCidr("10.1.2.3").?;
    try testing.expectEqual(@as(u8, 32), v4.bits);
    try testing.expect(isIPv4Mapped(v4.addr));
    const net24 = parseCidr("192.168.1.0/24").?;
    try testing.expectEqual(@as(u8, 24), net24.bits);
    const v6 = parseCidr("2001:db8::1").?;
    try testing.expectEqual(@as(u8, 128), v6.bits);
    const v664 = parseCidr("2001:db8::/32").?;
    try testing.expectEqual(@as(u8, 32), v664.bits);
    try testing.expect(parseCidr("10.0.0.0/33") == null); // v4 overflow
    try testing.expect(parseCidr("::/129") == null); // v6 overflow
    try testing.expect(parseCidr("not-an-ip") == null);
    try testing.expect(parseCidr("10.0.0.1/abc") == null);
    try testing.expect(parseCidr("") == null);
}

test "sockets: cidrContains matches prefixes and boundaries" {
    const net24 = parseCidr("192.168.1.0/24").?;
    try testing.expect(cidrContains(net24, parseIp("192.168.1.1").?));
    try testing.expect(cidrContains(net24, parseIp("192.168.1.254").?));
    try testing.expect(!cidrContains(net24, parseIp("192.168.2.1").?));
    try testing.expect(!cidrContains(net24, parseIp("10.0.0.1").?));
    // Partial-byte boundary: /25 splits .0-.127 / .128-.255.
    const net25 = parseCidr("192.168.1.0/25").?;
    try testing.expect(cidrContains(net25, parseIp("192.168.1.127").?));
    try testing.expect(!cidrContains(net25, parseIp("192.168.1.128").?));
    // /0 contains everything, including v6.
    try testing.expect(cidrContains(parseCidr("all").?, parseIp("8.8.8.8").?));
    try testing.expect(cidrContains(parseCidr("all").?, parseIp("::1").?));
    // v6 prefix.
    const v6net = parseCidr("2001:db8::/32").?;
    try testing.expect(cidrContains(v6net, parseIp("2001:db8::1").?));
    try testing.expect(!cidrContains(v6net, parseIp("2001:db9::1").?));
    // Exact host routes.
    try testing.expect(cidrContains(parseCidr("10.0.0.5").?, parseIp("10.0.0.5").?));
    try testing.expect(!cidrContains(parseCidr("10.0.0.5").?, parseIp("10.0.0.6").?));
    // Cross-family prefixes never match (except a /0).
    try testing.expect(!cidrContains(parseCidr("10.0.0.0/8").?, parseIp("::1").?));
    try testing.expect(!cidrContains(parseCidr("2001:db8::/32").?, parseIp("10.1.2.3").?));
}
