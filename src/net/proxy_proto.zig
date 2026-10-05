//! PROXY protocol (v1 text + v2 binary) header parser, haproxy spec.
//!
//! Inbound only: when a listener opts in (`listen ... proxy_protocol`),
//! the first bytes of each connection are the proxy's header, consumed
//! BEFORE any HTTP/TLS/h2 sniffing. The source address replaces the
//! connection peer IP, so `client_ip`-based decisions (allow/deny,
//! limit_req, ip_hash, access logs) see the real client.
//!
//! v1: `PROXY TCP4/TCP6 <src> <dst> <sport> <dport>\r\n`
//!     (`PROXY UNKNOWN\r\n` carries no addresses — peer kept).
//! v2: 12-byte signature + ver/cmd + fam + len16 + addresses
//!     (AF_INET/INET6 STREAM and DGRAM share the layout; UNIX ignored).
const std = @import("std");
const sockets_mod = @import("sockets.zig");

/// v2 signature: `\r\n\r\n\0\r\nQUIT\n` (12 bytes).
pub const v2_signature = "\r\n\r\n\x00\r\nQUIT\n";

/// v1 lines longer than this (incl. CRLF) are invalid per spec (107 max).
pub const v1_max_len = 107;

pub const Outcome = union(enum) {
    /// Need more bytes (never consumes).
    incomplete,
    /// Malformed: the caller must drop the connection (nginx closes it).
    invalid,
    /// Parsed: `consumed` header bytes, source `ip` (null for UNKNOWN /
    /// unsupported families — keep the socket peer).
    done: struct {
        consumed: usize,
        ip: ?[16]u8,
    },
};

pub fn parse(buf: []const u8) Outcome {
    if (buf.len == 0) return .incomplete;
    // v2 is binary: full signature present -> v2; strict prefix -> wait.
    // (A v1 line never starts with \r, so a \r-prefix can only be v2.)
    if (buf.len >= 12 and std.mem.startsWith(u8, buf, v2_signature)) {
        return parseV2(buf);
    }
    if (buf.len < 12 and std.mem.startsWith(u8, v2_signature, buf)) {
        return .incomplete;
    }
    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "PROXY")) {
        return parseV1(buf);
    }
    // Short v1 prefix: still could become "PROXY".
    if (buf.len < 5 and std.mem.startsWith(u8, "PROXY", buf)) {
        return .incomplete;
    }
    return .invalid;
}

fn parseV1(buf: []const u8) Outcome {
    const eol = std.mem.indexOf(u8, buf, "\r\n") orelse {
        if (buf.len > v1_max_len) return .invalid;
        return .incomplete;
    };
    if (eol + 2 > v1_max_len) return .invalid;
    const line = buf[0..eol];
    // `PROXY UNKNOWN` (with or without trailing fields): no addresses.
    if (std.mem.eql(u8, line, "PROXY UNKNOWN") or std.mem.startsWith(u8, line, "PROXY UNKNOWN ")) {
        return .{ .done = .{ .consumed = eol + 2, .ip = null } };
    }
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next(); // PROXY
    const proto = it.next() orelse return .invalid;
    const src = it.next() orelse return .invalid;
    _ = it.next(); // dst (validated implicitly: must exist)
    _ = it.next(); // sport
    const dport = it.next() orelse return .invalid;
    _ = dport;
    if (it.next() != null) return .invalid; // trailing garbage
    const want_v6 = std.mem.eql(u8, proto, "TCP6");
    if (!std.mem.eql(u8, proto, "TCP4") and !want_v6) return .invalid;
    const ip = sockets_mod.parseIp(src) orelse return .invalid;
    // Family must agree with the literal (v4-mapped addrs are v4).
    if (sockets_mod.isIPv4Mapped(ip) == want_v6) return .invalid;
    return .{ .done = .{ .consumed = eol + 2, .ip = ip } };
}

fn parseV2(buf: []const u8) Outcome {
    if (buf.len < 16) return .incomplete;
    const ver_cmd = buf[12];
    const fam = buf[13];
    if ((ver_cmd >> 4) != 0x2) return .invalid;
    const len = std.mem.readInt(u16, buf[14..16], .big);
    if (buf.len < 16 + len) return .incomplete;
    const cmd = ver_cmd & 0x0F;
    // Only PROXY command carries addresses; LOCAL (health checks) means
    // "use the socket peer" — same outcome as UNKNOWN.
    if (cmd != 0x01) return .{ .done = .{ .consumed = 16 + len, .ip = null } };
    const fam_hi = fam >> 4;
    const ip: ?[16]u8 = switch (fam_hi) {
        0x0 => null, // UNSPEC: keep the peer
        0x1 => blk: {
            // AF_INET: src(4) dst(4) sport(2) dport(2).
            if (len < 12) return .invalid;
            var mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 };
            @memcpy(mapped[12..16], buf[16..20]);
            break :blk mapped;
        },
        0x2 => blk: {
            // AF_INET6: src(16) dst(16) sport(2) dport(2).
            if (len < 36) return .invalid;
            var addr: [16]u8 = undefined;
            @memcpy(&addr, buf[16..32]);
            break :blk addr;
        },
        else => null, // AF_UNIX and beyond: keep the peer
    };
    return .{ .done = .{ .consumed = 16 + len, .ip = ip } };
}

const testing = std.testing;

test "proxy_proto: v1 TCP4 parses and reports consumed bytes" {
    const line = "PROXY TCP4 192.168.0.1 192.168.0.11 56324 443\r\nGET / HTTP/1.1\r\n";
    switch (parse(line)) {
        .done => |d| {
            try testing.expectEqual(@as(usize, 47), d.consumed);
            try testing.expectEqual(sockets_mod.parseIp("192.168.0.1").?, d.ip.?);
        },
        else => return error.ExpectedDone,
    }
}

test "proxy_proto: v1 TCP6 and UNKNOWN forms" {
    const v6 = "PROXY TCP6 2001:db8::1 2001:db8::2 1234 80\r\n";
    switch (parse(v6)) {
        .done => |d| {
            try testing.expectEqual(sockets_mod.parseIp("2001:db8::1").?, d.ip.?);
            try testing.expectEqual(@as(usize, v6.len), d.consumed);
        },
        else => return error.ExpectedDone,
    }
    switch (parse("PROXY UNKNOWN\r\n")) {
        .done => |d| try testing.expect(d.ip == null),
        else => return error.ExpectedDone,
    }
    switch (parse("PROXY UNKNOWN 1.2.3.4 5.6.7.8 1 2\r\n")) {
        .done => |d| try testing.expect(d.ip == null),
        else => return error.ExpectedDone,
    }
}

test "proxy_proto: v1 rejects garbage and oversize lines" {
    try testing.expect(parse("GET / HTTP/1.1\r\n") == .invalid);
    try testing.expect(parse("PROXY TCP4 999.1.1.1 2.2.2.2 1 2\r\n") == .invalid);
    try testing.expect(parse("PROXY TCP4 1.1.1.1\r\n") == .invalid); // truncated fields
    try testing.expect(parse("PROXY TCP4 1.1.1.1 2.2.2.2 1 2 3\r\n") == .invalid); // trailing
    try testing.expect(parse("PROXY SCTP 1.1.1.1 2.2.2.2 1 2\r\n") == .invalid);
    // Family/literal mismatch.
    try testing.expect(parse("PROXY TCP4 ::1 ::2 1 2\r\n") == .invalid);
    try testing.expect(parse("PROXY TCP6 1.1.1.1 2.2.2.2 1 2\r\n") == .invalid);
    // Split delivery: incomplete until CRLF.
    try testing.expect(parse("PROXY TCP4 1.1") == .incomplete);
    try testing.expect(parse("PR") == .incomplete);
    try testing.expect(parse("") == .incomplete);
    // Overlong without CRLF.
    var long: [120]u8 = undefined;
    @memset(&long, 'A');
    @memcpy(long[0..5], "PROXY");
    try testing.expect(parse(&long) == .invalid);
}

test "proxy_proto: v2 binary round-trips v4 and v6" {
    var hdr: [28]u8 = undefined;
    @memcpy(hdr[0..12], v2_signature);
    hdr[12] = 0x21; // v2 + PROXY
    hdr[13] = 0x11; // AF_INET + STREAM
    std.mem.writeInt(u16, hdr[14..16], 12, .big);
    hdr[16] = 192;
    hdr[17] = 168;
    hdr[18] = 0;
    hdr[19] = 7; // src 192.168.0.7
    @memset(hdr[20..24], 0); // dst
    std.mem.writeInt(u16, hdr[24..26], 56324, .big);
    std.mem.writeInt(u16, hdr[26..28], 443, .big);
    switch (parse(&hdr)) {
        .done => |d| {
            try testing.expectEqual(@as(usize, 28), d.consumed);
            try testing.expectEqual(sockets_mod.parseIp("192.168.0.7").?, d.ip.?);
        },
        else => return error.ExpectedDone,
    }
    // Truncated v2 header: incomplete, not invalid.
    switch (parse(hdr[0..14])) {
        .incomplete => {},
        else => return error.ExpectedIncomplete,
    }
    // Bad version nibble.
    var bad = hdr;
    bad[12] = 0x11;
    try testing.expect(parse(&bad) == .invalid);
    // LOCAL command: keep the peer.
    var local = hdr;
    local[12] = 0x20;
    switch (parse(&local)) {
        .done => |d| try testing.expect(d.ip == null),
        else => return error.ExpectedDone,
    }
}

test "proxy_proto: split v2 signature waits, non-signature CR fails" {
    try testing.expect(parse(v2_signature[0..6]) == .incomplete);
    try testing.expect(parse(v2_signature[0..11]) == .incomplete);
    try testing.expect(parse("\r\nXYZrestofjunk") == .invalid);
    try testing.expect(parse("\n\n\n\n\n\n\n\n\n\n\n\n\n") == .invalid);
}

test "proxy_proto: v2 UNSPEC and short lengths" {
    var hdr: [16]u8 = undefined;
    @memcpy(hdr[0..12], v2_signature);
    hdr[12] = 0x21;
    hdr[13] = 0x00; // UNSPEC
    std.mem.writeInt(u16, hdr[14..16], 0, .big);
    switch (parse(&hdr)) {
        .done => |d| {
            try testing.expectEqual(@as(usize, 16), d.consumed);
            try testing.expect(d.ip == null);
        },
        else => return error.ExpectedDone,
    }
    // AF_INET claiming fewer than 12 bytes: invalid.
    var short = hdr;
    short[13] = 0x11;
    std.mem.writeInt(u16, short[14..16], 4, .big);
    var with4: [20]u8 = undefined;
    @memcpy(with4[0..16], short[0..16]);
    @memset(with4[16..20], 0);
    try testing.expect(parse(&with4) == .invalid);
}
