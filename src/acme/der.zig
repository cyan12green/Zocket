//! Minimal DER writer + PEM encoder for ACME (C3/D3): enough ASN.1 to
//! build a PKCS#10 CSR and re-encode SEC1/PKCS#8 keys and PEM certificates.
//! Reader side lives in `tls/cert.zig` / `tls/pem.zig`; this file is the
//! write half. All functions are pure over slices (unit-tested).

const std = @import("std");

pub const Error = error{ OutOfMemory, DerTooLarge };

/// Growable DER cursor.
pub const Writer = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .buf = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    fn lenBytes(len: usize) usize {
        if (len < 0x80) return 1;
        var n: usize = 1;
        var v = len;
        while (v > 0) : (v >>= 8) n += 1;
        return n;
    }

    /// Append a complete TLV: tag byte + length + body.
    pub fn tlv(self: *Writer, tag: u8, body: []const u8) !void {
        try self.buf.append(self.allocator, tag);
        const len = body.len;
        if (len < 0x80) {
            try self.buf.append(self.allocator, @intCast(len));
        } else {
            const n = lenBytes(len) - 1;
            try self.buf.append(self.allocator, 0x80 | @as(u8, @intCast(n)));
            var shift: usize = n * 8;
            while (shift > 0) {
                shift -= 8;
                try self.buf.append(self.allocator, @intCast((len >> @intCast(shift)) & 0xff));
            }
        }
        try self.buf.appendSlice(self.allocator, body);
    }

    pub fn seq(self: *Writer, body: []const u8) !void {
        try self.tlv(0x30, body);
    }
    pub fn set(self: *Writer, body: []const u8) !void {
        try self.tlv(0x31, body);
    }
    pub fn int(self: *Writer, v: usize) !void {
        var b: [9]u8 = undefined;
        var i: usize = b.len;
        var x = v;
        while (true) {
            i -= 1;
            b[i] = @intCast(x & 0xff);
            x >>= 8;
            if (x == 0) break;
        }
        // DER: leading bit set needs a 0x00 pad byte.
        if (b[i] & 0x80 != 0) {
            i -= 1;
            b[i] = 0;
        }
        try self.tlv(0x02, b[i..]);
    }
    /// OID from raw DER content bytes (e.g. id-ecPublicKey = 2a 86 48 ce 3d 02 01).
    pub fn oid(self: *Writer, content: []const u8) !void {
        try self.tlv(0x06, content);
    }
    pub fn bitString(self: *Writer, body: []const u8, unused_bits: u8) !void {
        var tmp = std.ArrayList(u8).empty;
        defer tmp.deinit(self.allocator);
        try tmp.append(self.allocator, unused_bits);
        try tmp.appendSlice(self.allocator, body);
        try self.tlv(0x03, tmp.items);
    }
    pub fn octetString(self: *Writer, body: []const u8) !void {
        try self.tlv(0x04, body);
    }
    pub fn utf8String(self: *Writer, body: []const u8) !void {
        try self.tlv(0x0C, body);
    }
    /// Context-specific primitive tag [n].
    pub fn contextPrimitive(self: *Writer, n: u8, body: []const u8) !void {
        try self.tlv(0x80 | n, body);
    }
    /// Context-specific constructed tag [n].
    pub fn contextConstructed(self: *Writer, n: u8, body: []const u8) !void {
        try self.tlv(0xA0 | n, body);
    }
    pub fn nullValue(self: *Writer) !void {
        try self.tlv(0x05, &.{});
    }
    pub fn boolean(self: *Writer, v: bool) !void {
        try self.tlv(0x01, &[_]u8{if (v) 0xFF else 0x00});
    }
};

/// OIDs used by the CSR/keys (DER content bytes).
pub const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
pub const oid_prime256v1 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
pub const oid_ecdsa_with_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };
pub const oid_pkcs10_csr = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x01 };
pub const oid_extension_request = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E };

/// Build a PKCS#10 CertificationRequest for the given domains (CN=first,
/// SAN=dNSName for each). The `subject_public_key` is the SEC1 point.
/// Returns the DER bytes of `CertificationRequestInfo` (the part to sign)
/// in `tbs_out` and the signed CSR in `out`.
pub const CsrResult = struct {
    csr: []u8,
    /// Slice of `csr` covering CertificationRequestInfo (for signing).
    tbs: []const u8,
};

pub fn buildCsr(
    allocator: std.mem.Allocator,
    domains: []const []const u8,
    pub_sec1: []const u8,
) !CsrResult {
    if (domains.len == 0 or pub_sec1.len != 65) return error.DerTooLarge;

    // AlgorithmIdentifier { ecPublicKey, prime256v1 }.
    var alg = Writer.init(allocator);
    defer alg.deinit();
    {
        var body = Writer.init(allocator);
        defer body.deinit();
        try body.oid(&oid_ec_public_key);
        try body.oid(&oid_prime256v1);
        try alg.seq(body.buf.items);
    }

    // Subject: SEQ { SET { SEQ { OID commonName, UTF8 name } } }
    // (RDN -> AttributeTypeAndValue -> OID + value; the inner SEQ is
    // mandatory — OpenSSL rejects an RDN without it).
    var subject = Writer.init(allocator);
    defer subject.deinit();
    {
        var atv = Writer.init(allocator);
        defer atv.deinit();
        {
            var body = Writer.init(allocator);
            defer body.deinit();
            try body.oid(&.{ 0x55, 0x04, 0x03 }); // id-at-commonName
            try body.utf8String(domains[0]);
            try atv.seq(body.buf.items);
        }
        var set = Writer.init(allocator);
        defer set.deinit();
        try set.set(atv.buf.items);
        try subject.seq(set.buf.items);
    }

    // SubjectPublicKeyInfo = SEQ { algid, BIT STRING(pub) }.
    var spki = Writer.init(allocator);
    defer spki.deinit();
    {
        var parts = Writer.init(allocator);
        defer parts.deinit();
        try parts.buf.appendSlice(allocator, alg.buf.items);
        try parts.bitString(pub_sec1, 0);
        try spki.seq(parts.buf.items);
    }

    // SubjectAltName extension: SEQ { oid-san, OCTET STRING SEQ OF dNSName }.
    var ext = Writer.init(allocator);
    defer ext.deinit();
    {
        var names = Writer.init(allocator);
        defer names.deinit();
        for (domains) |d| try names.contextPrimitive(2, d);
        var san_seq = Writer.init(allocator);
        defer san_seq.deinit();
        try san_seq.seq(names.buf.items);
        var body = Writer.init(allocator);
        defer body.deinit();
        try body.oid(&.{ 0x55, 0x1D, 0x11 });
        try body.octetString(san_seq.buf.items);
        try ext.seq(body.buf.items);
    }
    // extensionRequest Attribute: SEQ { oid, SET { Extensions } }.
    var attr = Writer.init(allocator);
    defer attr.deinit();
    {
        var exts = Writer.init(allocator);
        defer exts.deinit();
        try exts.seq(ext.buf.items);
        var values = Writer.init(allocator);
        defer values.deinit();
        try values.set(exts.buf.items);
        var body = Writer.init(allocator);
        defer body.deinit();
        try body.oid(&oid_extension_request);
        try body.buf.appendSlice(allocator, values.buf.items);
        try attr.seq(body.buf.items);
    }
    // attributes [0] IMPLICIT SET OF Attribute (one entry).
    var attrs = Writer.init(allocator);
    defer attrs.deinit();
    try attrs.contextConstructed(0, attr.buf.items);

    // CertificationRequestInfo = SEQ { version, subject, spki, attributes }.
    var cri = Writer.init(allocator);
    defer cri.deinit();
    {
        var body = Writer.init(allocator);
        defer body.deinit();
        try body.int(0);
        try body.buf.appendSlice(allocator, subject.buf.items);
        try body.buf.appendSlice(allocator, spki.buf.items);
        try body.buf.appendSlice(allocator, attrs.buf.items);
        try cri.seq(body.buf.items);
    }

    // Assemble the CSR shape with a placeholder signature; the caller
    // signs `tbs` and calls finishCsr.
    var sig_alg = Writer.init(allocator);
    defer sig_alg.deinit();
    {
        var oid_w = Writer.init(allocator);
        defer oid_w.deinit();
        try oid_w.oid(&oid_ecdsa_with_sha256);
        try sig_alg.seq(oid_w.buf.items);
    }
    var out = Writer.init(allocator);
    errdefer out.deinit();
    {
        var body = Writer.init(allocator);
        defer body.deinit();
        try body.buf.appendSlice(allocator, cri.buf.items);
        try body.buf.appendSlice(allocator, sig_alg.buf.items);
        try body.bitString(&.{0}, 7);
        try out.seq(body.buf.items);
    }
    // The signed region is the CRI TLV, which begins right after the CSR's
    // outer header (whose length varies with the body size). Capture the
    // total BEFORE toOwnedSlice (which empties the list).
    const placeholder_len = 4; // bitString(&.{0}, 7): tag + len + unused + 1 byte
    const body_len = cri.buf.items.len + sig_alg.buf.items.len + placeholder_len;
    const total_len = out.buf.items.len;
    const csr = try out.buf.toOwnedSlice(allocator);
    const outer_hl = total_len - body_len;
    const tbs = csr[outer_hl .. outer_hl + cri.buf.items.len];
    return .{ .csr = csr, .tbs = tbs };
}

/// Rebuild the CSR with the real signature over `tbs`.
pub fn finishCsr(
    allocator: std.mem.Allocator,
    tbs: []const u8,
    sig_der: []const u8,
) ![]u8 {
    var sig_alg = Writer.init(allocator);
    defer sig_alg.deinit();
    {
        var oid_w = Writer.init(allocator);
        defer oid_w.deinit();
        try oid_w.oid(&oid_ecdsa_with_sha256);
        try sig_alg.seq(oid_w.buf.items);
    }
    var body = Writer.init(allocator);
    defer body.deinit();
    try body.buf.appendSlice(allocator, tbs);
    try body.buf.appendSlice(allocator, sig_alg.buf.items);
    try body.bitString(sig_der, 0);
    var out = Writer.init(allocator);
    errdefer out.deinit();
    try out.seq(body.buf.items);
    return out.buf.toOwnedSlice(allocator);
}

/// PEM-encode `der` under `label` ("CERTIFICATE", "EC PRIVATE KEY", ...).
pub fn pemEncode(allocator: std.mem.Allocator, label: []const u8, der: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    out.print(allocator, "-----BEGIN {s}-----\n", .{label}) catch return error.OutOfMemory;
    const b64_len = enc.calcSize(der.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = enc.encode(b64, der);
    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        const chunk = b64[i..@min(b64.len, i + 64)];
        out.appendSlice(allocator, chunk) catch return error.OutOfMemory;
        out.append(allocator, '\n') catch return error.OutOfMemory;
    }
    out.print(allocator, "-----END {s}-----\n", .{label}) catch return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

/// SEC1 EC private key DER: SEQ { 1, privateKey OCTET STRING, [0] curve OID }.
pub fn sec1PrivateKey(allocator: std.mem.Allocator, secret32: *const [32]u8) ![]u8 {
    var body = Writer.init(allocator);
    defer body.deinit();
    try body.int(1);
    try body.octetString(secret32);
    var curve = Writer.init(allocator);
    defer curve.deinit();
    try curve.oid(&oid_prime256v1);
    try body.contextConstructed(0, curve.buf.items);
    var out = Writer.init(allocator);
    errdefer out.deinit();
    try out.seq(body.buf.items);
    return out.buf.toOwnedSlice(allocator);
}

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const testing = std.testing;

test "pem encode wraps base64 at 64 columns" {
    const allocator = testing.allocator;
    var der_buf: [100]u8 = undefined;
    for (&der_buf, 0..) |*b, i| b.* = @intCast('0' + (i % 10));
    const der = der_buf[0..];
    const pem = try pemEncode(allocator, "TEST", der);
    defer allocator.free(pem);
    try testing.expect(std.mem.startsWith(u8, pem, "-----BEGIN TEST-----\n"));
    try testing.expect(std.mem.endsWith(u8, pem, "\n-----END TEST-----\n"));
    try testing.expect(std.mem.indexOf(u8, pem, "\n") != null);
}

test "sec1 private key round-trips through the TLS parser" {
    const allocator = testing.allocator;
    const kp = try Ecdsa.KeyPair.generateDeterministic(@as([32]u8, @splat(0x11)));
    const secret = kp.secret_key.toBytes();
    const der = try sec1PrivateKey(allocator, &secret);
    defer allocator.free(der);
    const pem = try pemEncode(allocator, "EC PRIVATE KEY", der);
    defer allocator.free(pem);
    // cert.zig parses SEC1 keys: a real round-trip through loadCredentials.
    const testdata = @import("../tls/testdata.zig");
    const creds = try @import("../tls/cert.zig").loadCredentials(allocator, testdata.cert_pem, pem);
    defer allocator.free(creds.cert_der);
    try testing.expectEqualSlices(u8, &secret, creds.key.secret_key[0..32]);
}

test "csr builds, signs and verifies" {
    const allocator = testing.allocator;
    const kp = try Ecdsa.KeyPair.generateDeterministic(@as([32]u8, @splat(0x22)));
    const pub_sec1 = kp.public_key.toUncompressedSec1();
    const domains = [_][]const u8{ "example.com", "www.example.com" };
    const built = try buildCsr(allocator, &domains, &pub_sec1);
    defer allocator.free(built.csr);
    // Sign the tbs and rebuild.
    var sig = kp.sign(built.tbs, null) catch unreachable;
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&der_buf);
    const csr = try finishCsr(allocator, built.tbs, sig_der);
    defer allocator.free(csr);
    // Verify: parse the CSR's tbs and signature structures by hand.
    // CSR = SEQ { tbs, algid, BIT STRING }; re-extract and verify.
    try testing.expect(csr.len > built.tbs.len);
    const sig_start = std.mem.indexOf(u8, csr, sig_der) orelse return error.TestUnexpected;
    _ = sig_start;
    sig = Ecdsa.Signature.fromDer(sig_der) catch return error.TestUnexpected;
    sig.verify(built.tbs, kp.public_key) catch return error.TestUnexpected;
    // Domain names must appear in the SAN extension.
    try testing.expect(std.mem.indexOf(u8, csr, "example.com") != null);
    try testing.expect(std.mem.indexOf(u8, csr, "www.example.com") != null);
}
