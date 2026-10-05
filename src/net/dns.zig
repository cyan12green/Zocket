//! Minimal DNS codec (RFC 1035, UDP): query building + response parsing.
//!
//! Scope is deliberately narrow: A-record lookup with CNAME chasing inside
//! a single response, TTL extraction, and name-compression decoding. No
//! TCP fallback (truncated responses are retried against the next server),
//! no DNSSEC, no AAAA (the proxy dial path is IPv4-only in v1). Used by
//! the resolver thread (`dns_resolver.zig`); the wire format here is also
//! what the loopback-stub tests speak.
//!
//! All parsing is bounds-checked and returns null on garbage — a hostile
//! or broken server must never panic the resolver thread.
const std = @import("std");

/// DNS header flags we send: recursion-desired, opcode 0.
pub const flags_rd: u16 = 0x0100;
/// Query types / classes.
pub const qtype_a: u16 = 1;
pub const qtype_cname: u16 = 5;
pub const qclass_in: u16 = 1;
/// Response codes.
pub const rcode_ok: u8 = 0;
pub const rcode_name_error: u8 = 3;

/// Build a query for `name` (dotted, no trailing dot) into `out`.
/// Returns the packet length, or 0 when the name doesn't fit.
pub fn buildQuery(id: u16, name: []const u8, qtype: u16, out: []u8) usize {
    var pos: usize = 0;
    if (out.len < 12) return 0;
    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], flags_rd, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big); // QDCOUNT
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    pos = 12;
    // Labels.
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return 0;
        if (pos + 1 + label.len + 4 > out.len) return 0;
        out[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(out[pos..][0..label.len], label);
        pos += label.len;
    }
    out[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, out[pos..][0..2], qtype, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], qclass_in, .big);
    pos += 2;
    return pos;
}

/// Expand a possibly-compressed name at `off` into dotted form in `out`.
/// Returns the expanded length, or null on garbage/loops. `depth` bounds
/// pointer chasing (compression loops are hostile input).
pub fn expandName(packet: []const u8, off: usize, out: []u8) ?usize {
    var pos = off;
    var out_len: usize = 0;
    var depth: usize = 0;
    while (true) {
        if (pos >= packet.len) return null;
        const len = packet[pos];
        if (len & 0xC0 == 0xC0) {
            if (pos + 1 >= packet.len) return null;
            const target = (@as(usize, len & 0x3F) << 8) | packet[pos + 1];
            if (target >= packet.len) return null;
            depth += 1;
            if (depth > 8) return null;
            pos = target;
            continue;
        }
        if (len == 0) break;
        if (len > 63 or pos + 1 + len > packet.len) return null;
        if (out_len > 0) {
            if (out_len >= out.len) return null;
            out[out_len] = '.';
            out_len += 1;
        }
        if (out_len + len > out.len) return null;
        @memcpy(out[out_len..][0..len], packet[pos + 1 ..][0..len]);
        out_len += len;
        pos += 1 + len;
    }
    return out_len;
}

/// Skip one possibly-compressed name at `off`; returns the offset just
/// past it (following the ORIGINAL encoding, not jump targets).
pub fn skipName(packet: []const u8, off: usize) ?usize {
    var pos = off;
    var depth: usize = 0;
    while (true) {
        if (pos >= packet.len) return null;
        const len = packet[pos];
        if (len & 0xC0 == 0xC0) {
            if (pos + 1 >= packet.len) return null;
            return pos + 2;
        }
        if (len == 0) return pos + 1;
        if (len > 63 or pos + 1 + len > packet.len) return null;
        pos += 1 + len;
        depth += 1;
        if (depth > 128) return null;
    }
}

/// Parsed response: answers relevant to one query (A targets + CNAME hop),
/// plus the response code and the minimum TTL seen.
pub const Response = struct {
    rcode: u8 = 0,
    /// IPv4 addresses from A records (in answer order).
    addrs: [8][4]u8 = @as([8][4]u8, @splat(@as([4]u8, .{ 0, 0, 0, 0 }))),
    addrs_len: usize = 0,
    /// First CNAME target seen (dotted, packet-independent copy in cname_buf).
    cname: ?[]const u8 = null,
    cname_buf: [256]u8 = undefined,
    /// Minimum TTL across A/CNAME records (0 when none seen).
    min_ttl: u32 = 0,
    min_ttl_seen: bool = false,
};

/// Parse a response to query `id`/`qtype`. Never panics on garbage.
pub fn parseResponse(packet: []const u8, id: u16, qtype: u16) ?Response {
    if (packet.len < 12) return null;
    if (std.mem.readInt(u16, packet[0..2], .big) != id) return null;
    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags >> 15) != 1) return null; // must be a response (QR)
    const rcode: u8 = @truncate(flags & 0x0F);
    const qd = std.mem.readInt(u16, packet[4..6], .big);
    const an = std.mem.readInt(u16, packet[6..8], .big);
    var resp = Response{ .rcode = rcode };
    if (rcode != rcode_ok) return resp; // NXDOMAIN etc: no answers expected
    var pos: usize = 12;
    // Skip questions (each: name + qtype + qclass). qd is normally 1, but
    // walk however many claim to be there.
    var qi: usize = 0;
    while (qi < qd) : (qi += 1) {
        pos = skipName(packet, pos) orelse return null;
        if (pos + 4 > packet.len) return null;
        pos += 4;
    }
    // Walk answers (name + type + class + ttl + rdlen + rdata).
    var ai: usize = 0;
    while (ai < an) : (ai += 1) {
        pos = skipName(packet, pos) orelse return null;
        if (pos + 10 > packet.len) return null;
        const atype = std.mem.readInt(u16, packet[pos..][0..2], .big);
        // const aclass = ... (ignored: IN expected, garbage tolerated)
        const ttl = std.mem.readInt(u32, packet[pos + 4 ..][0..4], .big);
        const rdlen = std.mem.readInt(u16, packet[pos + 8 ..][0..2], .big);
        pos += 10;
        if (pos + rdlen > packet.len) return null;
        const rdata = packet[pos..][0..rdlen];
        if (atype == qtype_a and qtype == qtype_a and rdlen == 4) {
            if (resp.addrs_len < resp.addrs.len) {
                @memcpy(&resp.addrs[resp.addrs_len], rdata[0..4]);
                resp.addrs_len += 1;
            }
            if (!resp.min_ttl_seen or ttl < resp.min_ttl) {
                resp.min_ttl = ttl;
                resp.min_ttl_seen = true;
            }
        } else if (atype == qtype_cname and resp.cname == null) {
            // A corrupt CNAME encoding skips the name but still counts
            // its TTL (one bad record must not lose valid siblings).
            if (expandName(packet, pos, &resp.cname_buf)) |n| {
                resp.cname = resp.cname_buf[0..n];
            }
            if (!resp.min_ttl_seen or ttl < resp.min_ttl) {
                resp.min_ttl = ttl;
                resp.min_ttl_seen = true;
            }
        }
        pos += rdlen;
    }
    return resp;
}

const testing = std.testing;

test "dns codec builds a well-formed A query" {
    var out: [512]u8 = undefined;
    const n = buildQuery(0x1234, "example.com", qtype_a, &out);
    try testing.expect(n > 12);
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, out[0..2], .big));
    try testing.expectEqual(flags_rd, std.mem.readInt(u16, out[2..4], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[4..6], .big));
    // QNAME encoding: 7example3com0.
    try testing.expectEqual(@as(u8, 7), out[12]);
    try testing.expectEqualStrings("example", out[13..20]);
    try testing.expectEqual(@as(u8, 3), out[20]);
    try testing.expectEqual(@as(u16, qtype_a), std.mem.readInt(u16, out[n - 4 ..][0..2], .big));
    try testing.expectEqual(@as(u16, qclass_in), std.mem.readInt(u16, out[n - 2 ..][0..2], .big));
    // Rejects empty labels and tiny buffers.
    try testing.expectEqual(@as(usize, 0), buildQuery(1, "bad..name", qtype_a, &out));
    var tiny: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), buildQuery(1, "a.bc", qtype_a, &tiny));
}

test "dns codec parses an A response with compression" {
    // Canned response for "example.com" A (id 0x1234, TTL 300):
    // question echoed + one answer with a compression pointer to QNAME.
    var pkt: [512]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u16, pkt[0..2], 0x1234, .big);
    std.mem.writeInt(u16, pkt[2..4], 0x8180, .big); // response, RD+RA, rcode 0
    std.mem.writeInt(u16, pkt[4..6], 1, .big);
    std.mem.writeInt(u16, pkt[6..8], 1, .big);
    std.mem.writeInt(u16, pkt[8..10], 0, .big);
    std.mem.writeInt(u16, pkt[10..12], 0, .big);
    pos = 12;
    // Question bytes only (buildQuery's 12-byte header is rebuilt above,
    // so splice in just the QNAME+QTYPE+QCLASS tail).
    var qtmp: [64]u8 = undefined;
    const qn = buildQuery(0x1234, "example.com", qtype_a, &qtmp);
    @memcpy(pkt[pos..][0 .. qn - 12], qtmp[12..qn]);
    pos += qn - 12;
    // Answer: NAME=ptr to 12, TYPE A, CLASS IN, TTL 300, RDLEN 4, 93.184.216.34.
    pkt[pos] = 0xC0;
    pkt[pos + 1] = 12;
    pos += 2;
    std.mem.writeInt(u16, pkt[pos..][0..2], qtype_a, .big);
    pos += 2;
    std.mem.writeInt(u16, pkt[pos..][0..2], qclass_in, .big);
    pos += 2;
    std.mem.writeInt(u32, pkt[pos..][0..4], 300, .big);
    pos += 4;
    std.mem.writeInt(u16, pkt[pos..][0..2], 4, .big);
    pos += 2;
    pkt[pos] = 93;
    pkt[pos + 1] = 184;
    pkt[pos + 2] = 216;
    pkt[pos + 3] = 34;
    pos += 4;
    const resp = parseResponse(pkt[0..pos], 0x1234, qtype_a).?;
    try testing.expectEqual(rcode_ok, resp.rcode);
    try testing.expectEqual(@as(usize, 1), resp.addrs_len);
    try testing.expectEqual([4]u8{ 93, 184, 216, 34 }, resp.addrs[0]);
    try testing.expectEqual(@as(u32, 300), resp.min_ttl);
}

test "dns codec follows CNAME records in-response" {
    // "alias.example" CNAME "target.example" (TTL 60) + A for target.
    var pkt: [512]u8 = undefined;
    std.mem.writeInt(u16, pkt[0..2], 0x42, .big);
    std.mem.writeInt(u16, pkt[2..4], 0x8180, .big);
    std.mem.writeInt(u16, pkt[4..6], 1, .big);
    std.mem.writeInt(u16, pkt[6..8], 2, .big);
    std.mem.writeInt(u16, pkt[8..10], 0, .big);
    std.mem.writeInt(u16, pkt[10..12], 0, .big);
    var pos: usize = 12;
    // Question: alias.example (no compression here).
    const q = [_]u8{ 5, 'a', 'l', 'i', 'a', 's', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0, 0, 1, 0, 1 };
    @memcpy(pkt[pos..][0..q.len], &q);
    const qstart = pos;
    pos += q.len;
    // Answer 1: ptr->question, CNAME, TTL 60, rdata = target.example labels.
    pkt[pos] = 0xC0;
    pkt[pos + 1] = @intCast(qstart);
    pos += 2;
    std.mem.writeInt(u16, pkt[pos..][0..2], qtype_cname, .big);
    pos += 2;
    std.mem.writeInt(u16, pkt[pos..][0..2], qclass_in, .big);
    pos += 2;
    std.mem.writeInt(u32, pkt[pos..][0..4], 60, .big);
    pos += 4;
    const t = [_]u8{ 6, 't', 'a', 'r', 'g', 'e', 't', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0 };
    std.mem.writeInt(u16, pkt[pos..][0..2], @intCast(t.len), .big);
    pos += 2;
    @memcpy(pkt[pos..][0..t.len], &t);
    pos += t.len;
    // Answer 2: target.example A 10.9.9.9 TTL 60.
    @memcpy(pkt[pos..][0..t.len], &t);
    pos += t.len;
    std.mem.writeInt(u16, pkt[pos..][0..2], qtype_a, .big);
    pos += 2;
    std.mem.writeInt(u16, pkt[pos..][0..2], qclass_in, .big);
    pos += 2;
    std.mem.writeInt(u32, pkt[pos..][0..4], 60, .big);
    pos += 4;
    std.mem.writeInt(u16, pkt[pos..][0..2], 4, .big);
    pos += 2;
    pkt[pos] = 10;
    pkt[pos + 1] = 9;
    pkt[pos + 2] = 9;
    pkt[pos + 3] = 9;
    pos += 4;
    const resp = parseResponse(pkt[0..pos], 0x42, qtype_a).?;
    try testing.expectEqualStrings("target.example", resp.cname.?);
    try testing.expectEqual(@as(usize, 1), resp.addrs_len);
    try testing.expectEqual([4]u8{ 10, 9, 9, 9 }, resp.addrs[0]);
    try testing.expectEqual(@as(u32, 60), resp.min_ttl);
}

test "dns codec rejects garbage without panicking" {
    try testing.expect(parseResponse(&.{}, 1, qtype_a) == null);
    try testing.expect(parseResponse(&.{ 1, 2, 3 }, 1, qtype_a) == null);
    // Wrong ID.
    var hdr: [12]u8 = .{ 0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0 };
    try testing.expect(parseResponse(&hdr, 0x9999, qtype_a) == null);
    // Truncated question.
    hdr[0] = 0;
    hdr[1] = 2;
    var short = hdr ++ [_]u8{ 3, 'a', 'b' };
    try testing.expect(parseResponse(&short, 2, qtype_a) == null);
    // Compression loop: pointer to itself.
    var loop: [16]u8 = undefined;
    std.mem.writeInt(u16, loop[0..2], 7, .big);
    std.mem.writeInt(u16, loop[2..4], 0x8180, .big);
    std.mem.writeInt(u16, loop[4..6], 0, .big);
    std.mem.writeInt(u16, loop[6..8], 1, .big);
    std.mem.writeInt(u16, loop[8..10], 0, .big);
    std.mem.writeInt(u16, loop[10..12], 0, .big);
    loop[12] = 0xC0;
    loop[13] = 12;
    loop[14] = 0;
    loop[15] = 1;
    try testing.expect(parseResponse(&loop, 7, qtype_a) == null);
    // NXDOMAIN carries the code with no answers.
    var nx: [12]u8 = .{ 0, 3, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0 };
    const r = parseResponse(&nx, 3, qtype_a).?;
    try testing.expectEqual(rcode_name_error, r.rcode);
    try testing.expectEqual(@as(usize, 0), r.addrs_len);
}
