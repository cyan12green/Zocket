//! Minimal DER OCSP Response parser (C3): extracts the response status
//! and the first SingleResponse's cert status for stapling decisions.
//! Only what the server needs (RFC 6960 §4.2):
//!   OCSPResponse ::= SEQUENCE { responseStatus ENUMERATED,
//!     responseBytes [0] EXPLICIT { responseType OID,
//!       response OCTET STRING (BasicOCSPResponse) } OPTIONAL }
//!   BasicOCSPResponse ::= SEQUENCE { tbsResponseData ::= SEQUENCE {
//!     ... responses SEQUENCE OF SingleResponse ::= SEQUENCE {
//!       reqCert CertID, certStatus CHOICE { good[0], revoked[1],
//!       unknown[2] }, ... } } }
//! Unknown/incomplete input is an error — the caller fails closed (no
//! staple) rather than stapling garbage.

const std = @import("std");

pub const ResponseStatus = enum(u8) {
    successful = 0,
    malformed_request = 1,
    internal_error = 2,
    try_later = 3,
    sig_required = 5,
    unauthorized = 6,
    _,
};

pub const CertStatus = enum {
    good,
    revoked,
    unknown,
};

pub const Parsed = struct {
    status: ResponseStatus,
    cert: CertStatus,
};

pub const Error = error{
    OcspDecodeError,
    OcspNotSuccessful,
};

const Der = struct {
    buf: []const u8,
    pos: usize = 0,

    fn eof(self: *const Der) bool {
        return self.pos >= self.buf.len;
    }

    fn readByte(self: *Der) Error!u8 {
        if (self.pos >= self.buf.len) return error.OcspDecodeError;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readLen(self: *Der) Error!usize {
        const b = try self.readByte();
        if (b & 0x80 == 0) return b;
        const n: usize = b & 0x7F;
        if (n == 0 or n > 4) return error.OcspDecodeError;
        var len: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) len = (len << 8) | try self.readByte();
        return len;
    }

    fn expect(self: *Der, tag: u8) Error![]const u8 {
        const t = try self.readByte();
        if (t != tag) return error.OcspDecodeError;
        const len = try self.readLen();
        if (self.pos + len > self.buf.len) return error.OcspDecodeError;
        const s = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    fn sub(self: *Der, tag: u8) Error!Der {
        return .{ .buf = try self.expect(tag) };
    }
};

/// Parse a DER OCSPResponse; errors on anything but a successful response
/// with at least one SingleResponse (fail closed: no staple).
pub fn parseResponse(der: []const u8) Error!Parsed {
    var top = Der{ .buf = der };
    var seq = try top.sub(0x30); // SEQUENCE
    const status_b = try seq.sub(0x0A); // ENUMERATED
    if (status_b.buf.len != 1) return error.OcspDecodeError;
    const status: ResponseStatus = @enumFromInt(status_b.buf[0]);
    if (status != .successful) return error.OcspNotSuccessful;
    if (seq.eof()) return error.OcspDecodeError;
    // responseBytes [0] EXPLICIT.
    const rb = try seq.sub(0xA0);
    var rbs_wrap = Der{ .buf = rb.buf };
    const rbytes_seq = try rbs_wrap.sub(0x30); // ResponseBytes SEQUENCE
    // responseType OID + response OCTET STRING (skip OID value check:
    // any inner BasicOCSPResponse shape parses the same).
    var inner = Der{ .buf = rbytes_seq.buf };
    _ = try inner.expect(0x06); // OID
    const basic_der = try inner.expect(0x04); // OCTET STRING
    var basic = Der{ .buf = basic_der };
    var bseq = try basic.sub(0x30); // BasicOCSPResponse
    var tbs = try bseq.sub(0x30); // tbsResponseData
    // Skip version [0], responderID (choice), producedAt: walk to the
    // `responses` SEQUENCE by consuming fields in order. responderID is
    // [1] name or [2] keyHash — both context-constructed; skip by tag.
    if (!tbs.eof() and tbs.buf[tbs.pos] == 0xA0) _ = try tbs.expect(0xA0); // version
    if (tbs.eof()) return error.OcspDecodeError;
    const rid_tag = try tbs.readByte();
    if (rid_tag != 0xA1 and rid_tag != 0xA2) return error.OcspDecodeError;
    const rid_len = try tbs.readLen();
    if (tbs.pos + rid_len > tbs.buf.len) return error.OcspDecodeError;
    tbs.pos += rid_len;
    _ = try tbs.expect(0x18); // producedAt GeneralizedTime
    const responses = try tbs.sub(0x30); // SEQUENCE OF SingleResponse
    var rs = Der{ .buf = responses.buf };
    var single = try rs.sub(0x30); // first SingleResponse
    _ = try single.sub(0x30); // reqCert CertID (skip contents)
    if (single.eof()) return error.OcspDecodeError;
    const cs_tag = try single.readByte();
    const cs_len = try single.readLen();
    if (single.pos + cs_len > single.buf.len) return error.OcspDecodeError;
    single.pos += cs_len;
    const cert: CertStatus = switch (cs_tag) {
        0x80 => .good, // [0] IMPLICIT NULL-ish (empty)
        0xA1 => .revoked, // [1] EXPLICIT
        0x82 => .unknown, // [2] IMPLICIT
        else => return error.OcspDecodeError,
    };
    return .{ .status = status, .cert = cert };
}

/// Build a minimal DER OCSPResponse with one SingleResponse (test helper).
pub fn buildResponse(allocator: std.mem.Allocator, cert_status: CertStatus) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    // SingleResponse body: CertID (empty seq) + certStatus + thisUpdate.
    var single = std.ArrayList(u8).empty;
    defer single.deinit(allocator);
    try single.appendSlice(allocator, &.{ 0x30, 0x00 }); // reqCert (empty)
    switch (cert_status) {
        .good => try single.appendSlice(allocator, &.{ 0x80, 0x00 }),
        .revoked => try single.appendSlice(allocator, &.{ 0xA1, 0x03, 0x18, 0x0F, 0x32, 0x30, 0x32, 0x36 }), // rough time
        .unknown => try single.appendSlice(allocator, &.{ 0x82, 0x00 }),
    }
    try single.appendSlice(allocator, &.{ 0x18, 0x0F, 0x32, 0x30, 0x32, 0x36, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A }); // thisUpdate
    // responses SEQ
    var responses = std.ArrayList(u8).empty;
    defer responses.deinit(allocator);
    try appendTlv(&responses, allocator, 0x30, single.items);
    // tbs: version omitted, responderID [2] keyHash(4), producedAt, responses
    var tbs = std.ArrayList(u8).empty;
    defer tbs.deinit(allocator);
    try tbs.appendSlice(allocator, &.{ 0xA2, 0x06, 0x04, 0x04, 0xDE, 0xAD, 0xBE, 0xEF });
    try tbs.appendSlice(allocator, &.{ 0x18, 0x0F, 0x32, 0x30, 0x32, 0x36, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A });
    try appendTlv(&tbs, allocator, 0x30, responses.items);
    // tbsResponseData SEQ { responderID, producedAt, responses }.
    var tbs_seq = std.ArrayList(u8).empty;
    defer tbs_seq.deinit(allocator);
    try appendTlv(&tbs_seq, allocator, 0x30, tbs.items);
    // BasicOCSPResponse SEQ { tbs } (signatureAlg/certs/signature omitted:
    // the parser stops after the first SingleResponse).
    var basic = std.ArrayList(u8).empty;
    defer basic.deinit(allocator);
    try appendTlv(&basic, allocator, 0x30, tbs_seq.items);
    // ResponseBytes SEQ { OID, OCTET STRING basic }
    var rbytes = std.ArrayList(u8).empty;
    defer rbytes.deinit(allocator);
    try rbytes.appendSlice(allocator, &.{ 0x06, 0x09, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, 0x01 }); // id-pkix-ocsp-basic
    try appendTlv(&rbytes, allocator, 0x04, basic.items);
    var rbwrap = std.ArrayList(u8).empty;
    defer rbwrap.deinit(allocator);
    try appendTlv(&rbwrap, allocator, 0x30, rbytes.items);
    // OCSPResponse SEQ { ENUMERATED 0, [0] rbwrap }
    try out.appendSlice(allocator, &.{ 0x30, 0x00 }); // placeholder header
    try out.appendSlice(allocator, &.{ 0x0A, 0x01, 0x00 });
    try appendTlv(&out, allocator, 0xA0, rbwrap.items);
    // Fix outer length.
    const body_len = out.items.len - 2;
    if (body_len < 128) {
        out.items[1] = @intCast(body_len);
    } else {
        // Long form (unlikely at these sizes; keep the helper total).
        return error.OcspDecodeError;
    }
    return out.toOwnedSlice(allocator);
}

fn appendTlv(list: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: u8, body: []const u8) !void {
    try list.append(allocator, tag);
    if (body.len < 128) {
        try list.append(allocator, @intCast(body.len));
    } else if (body.len < 256) {
        try list.appendSlice(allocator, &.{ 0x81, @intCast(body.len) });
    } else {
        try list.appendSlice(allocator, &.{ 0x82, @intCast(body.len >> 8), @intCast(body.len & 0xFF) });
    }
    try list.appendSlice(allocator, body);
}

const testing = std.testing;

test "ocsp parses good/revoked/unknown single responses" {
    for ([_]struct { s: CertStatus, want: CertStatus }{
        .{ .s = .good, .want = .good },
        .{ .s = .revoked, .want = .revoked },
        .{ .s = .unknown, .want = .unknown },
    }) |c| {
        const der = try buildResponse(testing.allocator, c.s);
        defer testing.allocator.free(der);
        const p = try parseResponse(der);
        try testing.expectEqual(ResponseStatus.successful, p.status);
        try testing.expectEqual(c.want, p.cert);
    }
}

test "ocsp rejects garbage and truncated input" {
    try testing.expectError(error.OcspDecodeError, parseResponse("not der"));
    try testing.expectError(error.OcspDecodeError, parseResponse(&.{ 0x30, 0x03, 0x0A, 0x01, 0x00 }));
    const der = try buildResponse(testing.allocator, .good);
    defer testing.allocator.free(der);
    try testing.expectError(error.OcspDecodeError, parseResponse(der[0 .. der.len - 5]));
}
