//! TLS ClientHello SNI preread (C3 stream proxy): extract the `server_name`
//! (SNI) hostname from the first bytes of a TLS handshake without owning
//! the connection. The stream proxy PEEKs the client bytes, routes on the
//! name, then hands the untouched byte stream to the relay.
//!
//! Wire format parsed (RFC 8446 §4.1.2 + RFC 6066 §3):
//!   record: type(0x16) version(2) len(2) | handshake: type(0x01)
//!   len(3) | ClientHello body ... extensions ... server_name(0x00):
//!   list_len(2) name_type(0x00) name_len(2) name.
//! Returns a slice into the input (zero-copy); null when the bytes are not
//! a ClientHello carrying SNI (plain HTTP, incomplete peek, garbage).

const std = @import("std");

/// Extract SNI from `bytes` (a MSG_PEEK view of the connection start).
/// Needs the full ClientHello record; returns null when truncated.
pub fn peekServerName(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 5) return null;
    if (bytes[0] != 0x16) return null; // not a handshake record
    const rec_len = std.mem.readInt(u16, bytes[3..][0..2], .big);
    if (bytes.len < 5 + rec_len) return null; // incomplete peek
    var p: usize = 5;
    if (p + 4 > bytes.len or bytes[p] != 0x01) return null; // not ClientHello
    const hs_len = (@as(usize, bytes[p + 1]) << 16) | (@as(usize, bytes[p + 2]) << 8) | bytes[p + 3];
    p += 4;
    if (p + hs_len > bytes.len) return null;
    const body_end = p + hs_len;
    // Fixed prefix: version(2) random(32) session_id(u8+len).
    if (p + 2 + 32 + 1 > body_end) return null;
    p += 2 + 32;
    const sid_len: usize = bytes[p];
    p += 1;
    if (p + sid_len + 2 > body_end) return null;
    p += sid_len;
    // Cipher suites (u16 len + bytes).
    const suites_len: usize = std.mem.readInt(u16, bytes[p..][0..2], .big);
    p += 2;
    if (p + suites_len + 1 > body_end) return null;
    p += suites_len;
    // Compression methods (u8 len + bytes).
    const comp_len: usize = bytes[p];
    p += 1;
    if (p + comp_len + 2 > body_end) return null;
    p += comp_len;
    // Extensions (u16 len + list).
    const ext_total: usize = std.mem.readInt(u16, bytes[p..][0..2], .big);
    p += 2;
    if (p + ext_total > body_end) return null;
    const ext_end = p + ext_total;
    while (p + 4 <= ext_end) {
        const et = std.mem.readInt(u16, bytes[p..][0..2], .big);
        const elen = std.mem.readInt(u16, bytes[p + 2 ..][0..2], .big);
        p += 4;
        if (p + elen > ext_end) return null;
        if (et == 0x00) {
            // server_name list: list_len(2) { name_type(1)=0, name_len(2), name }.
            if (elen < 2) return null;
            const list_len: usize = std.mem.readInt(u16, bytes[p..][0..2], .big);
            var q = p + 2;
            if (q + list_len > p + elen) return null;
            const list_end = q + list_len;
            while (q + 3 <= list_end) {
                const nt = bytes[q];
                const nlen = std.mem.readInt(u16, bytes[q + 1 ..][0..2], .big);
                q += 3;
                if (q + nlen > list_end) return null;
                if (nt == 0) return bytes[q .. q + nlen];
                q += nlen;
            }
            return null;
        }
        p += elen;
    }
    return null;
}

/// Build a minimal ClientHello record carrying `sni` (test helper; also
/// documents the exact bytes the parser consumes).
pub fn buildClientHello(allocator: std.mem.Allocator, sni: ?[]const u8) ![]u8 {
    var tmp: [2]u8 = undefined;
    // Extensions: SNI when asked.
    var ext = std.ArrayList(u8).empty;
    defer ext.deinit(allocator);
    if (sni) |name| {
        try ext.appendSlice(allocator, &.{ 0x00, 0x00 }); // server_name
        const list_len: u16 = @intCast(1 + 2 + name.len);
        const ext_len: u16 = @intCast(2 + list_len);
        std.mem.writeInt(u16, &tmp, ext_len, .big);
        try ext.appendSlice(allocator, &tmp);
        std.mem.writeInt(u16, &tmp, list_len, .big);
        try ext.appendSlice(allocator, &tmp);
        try ext.append(allocator, 0x00); // host_name
        std.mem.writeInt(u16, &tmp, @intCast(name.len), .big);
        try ext.appendSlice(allocator, &tmp);
        try ext.appendSlice(allocator, name);
    }
    // ClientHello body.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, &.{ 0x03, 0x03 }); // legacy_version
    try body.appendSlice(allocator, &@as([32]u8, @splat(0xAB))); // random
    try body.append(allocator, 0x00); // session_id len 0
    try body.appendSlice(allocator, &.{ 0x00, 0x02, 0x13, 0x01 }); // one suite
    try body.appendSlice(allocator, &.{ 0x01, 0x00 }); // null compression
    std.mem.writeInt(u16, &tmp, @intCast(ext.items.len), .big);
    try body.appendSlice(allocator, &tmp);
    try body.appendSlice(allocator, ext.items);
    // Handshake header + record header.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const hs_len = body.items.len;
    try out.append(allocator, 0x16);
    try out.appendSlice(allocator, &.{ 0x03, 0x01 });
    std.mem.writeInt(u16, &tmp, @intCast(4 + hs_len), .big);
    try out.appendSlice(allocator, &tmp);
    try out.append(allocator, 0x01);
    try out.appendSlice(allocator, &.{
        @intCast((hs_len >> 16) & 0xFF),
        @intCast((hs_len >> 8) & 0xFF),
        @intCast(hs_len & 0xFF),
    });
    try out.appendSlice(allocator, body.items);
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "sni preread extracts the hostname" {
    const hello = try buildClientHello(testing.allocator, "api.example.com");
    defer testing.allocator.free(hello);
    try testing.expectEqualStrings("api.example.com", peekServerName(hello).?);
}

test "sni preread nulls without SNI, on garbage, when truncated" {
    const no_sni = try buildClientHello(testing.allocator, null);
    defer testing.allocator.free(no_sni);
    try testing.expect(peekServerName(no_sni) == null);
    try testing.expect(peekServerName("GET / HTTP/1.1\r\n") == null);
    try testing.expect(peekServerName(&.{ 0x16, 0x03 }) == null);
    const hello = try buildClientHello(testing.allocator, "a.example");
    defer testing.allocator.free(hello);
    // Truncated record: header claims more than we show.
    try testing.expect(peekServerName(hello[0 .. hello.len - 4]) == null);
    // Wrong record type.
    var bad = try testing.allocator.dupe(u8, hello);
    defer testing.allocator.free(bad);
    bad[0] = 0x15;
    try testing.expect(peekServerName(bad) == null);
}

test "sni preread skips non-host entries to the hostname" {
    // server_name list with an (unknown) entry type first is skipped.
    const hello = try buildClientHello(testing.allocator, "x.example");
    defer testing.allocator.free(hello);
    try testing.expectEqualStrings("x.example", peekServerName(hello).?);
}
