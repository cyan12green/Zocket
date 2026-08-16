//! Certificate and ECDSA private-key loading for the TLS server (M17:
//! ECDSA P-256 / P-384 only — std.crypto has no RSA). Reads PEM files,
//! parses the DER structures needed to extract the signing key:
//! - "CERTIFICATE": passed through verbatim (the client verifies the chain;
//!   M17 sends the first certificate).
//! - "EC PRIVATE KEY": SEC1 ECPrivateKey (RFC 5915).
//! - "PRIVATE KEY": PKCS#8 PrivateKeyInfo wrapping the SEC1 structure.

const std = @import("std");
const pem = @import("pem.zig");

pub const Curve = enum {
    p256,
    p384,

    /// Signature scheme to advertise in the handshake (RFC 8446 §4.2.3).
    pub fn signatureScheme(self: Curve) u16 {
        return switch (self) {
            .p256 => 0x0403, // ecdsa_secp256r1_sha256
            .p384 => 0x0503, // ecdsa_secp384r1_sha384
        };
    }

    /// The EC parameters OID (bare value, without the DER TLV header).
    pub fn paramsOid(self: Curve) []const u8 {
        return switch (self) {
            // 1.2.840.10045.3.1.7
            .p256 => &.{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 },
            // 1.3.132.0.34
            .p384 => &.{ 0x2b, 0x81, 0x04, 0x00, 0x22 },
        };
    }
};

pub const Error = error{
    InvalidKey,
    UnsupportedCurve,
    KeyNotFound,
    CertificateNotFound,
    OutOfMemory,
    InvalidPemHeader,
    InvalidBase64,
    MissingEndMarker,
};

pub const KeyPair = struct {
    curve: Curve,
    /// Raw big-endian private scalar (32 or 48 bytes).
    secret_key: [48]u8 = undefined,
    secret_len: usize = 0,
};

pub const Credentials = struct {
    /// The DER certificate bytes (first certificate of the chain).
    cert_der: []const u8,
    key: KeyPair,
};

/// Minimal DER reader (only what the key formats need: lengths, OIDs,
/// octet strings, bit strings, and context-specific tags).
const Der = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readByte(self: *Der) Error!u8 {
        if (self.pos >= self.buf.len) return error.InvalidKey;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readLen(self: *Der) Error!usize {
        const first = try self.readByte();
        if (first < 0x80) return first;
        const n: usize = first & 0x7f;
        if (n == 0 or n > 4) return error.InvalidKey;
        var len: usize = 0;
        for (0..n) |_| len = (len << 8) | (try self.readByte());
        return len;
    }

    /// Read a TLV: returns the tag and the value slice.
    fn readTlv(self: *Der) Error!struct { tag: u8, value: []const u8 } {
        const tag = try self.readByte();
        const len = try self.readLen();
        if (self.pos + len > self.buf.len) return error.InvalidKey;
        const value = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return .{ .tag = tag, .value = value };
    }

    fn eof(self: *const Der) bool {
        return self.pos >= self.buf.len;
    }
};

/// Extract the private scalar from a SEC1 ECPrivateKey DER (RFC 5915):
/// SEQUENCE { INTEGER version, OCTET STRING privateKey, [0] parameters OID
/// OPTIONAL, [1] publicKey OPTIONAL }.
fn parseSec1(der: []const u8, curve: Curve, out: *KeyPair) Error!void {
    var d = Der{ .buf = der };
    const seq = try d.readTlv();
    if (seq.tag != 0x30) return error.InvalidKey;
    var inner = Der{ .buf = seq.value };
    // version (INTEGER 1)
    const ver = try inner.readTlv();
    if (ver.tag != 0x02) return error.InvalidKey;
    // privateKey (OCTET STRING)
    const priv = try inner.readTlv();
    if (priv.tag != 0x04) return error.InvalidKey;
    const expected_len: usize = switch (curve) {
        .p256 => 32,
        .p384 => 48,
    };
    // SEC1 allows the private key with or without leading zeros; require the
    // canonical length (openssl emits canonical).
    if (priv.value.len != expected_len) return error.InvalidKey;
    out.curve = curve;
    @memcpy(out.secret_key[0..expected_len], priv.value);
    out.secret_len = expected_len;
}

/// Find the curve OID in a SEC1 structure (the [0] parameters element) and
/// return it as a slice; null when absent (then the caller must know the
/// curve from context, e.g. PKCS#8).
fn sec1CurveOid(der: []const u8) Error!?[]const u8 {
    var d = Der{ .buf = der };
    const seq = try d.readTlv();
    if (seq.tag != 0x30) return error.InvalidKey;
    var inner = Der{ .buf = seq.value };
    _ = try inner.readTlv(); // version
    _ = try inner.readTlv(); // privateKey
    while (!inner.eof()) {
        const tlv = try inner.readTlv();
        if (tlv.tag == 0xa0) { // [0] parameters
            var p = Der{ .buf = tlv.value };
            const oid = try p.readTlv();
            if (oid.tag != 0x06) return error.InvalidKey;
            return oid.value;
        }
        if (tlv.tag == 0xa1) break; // [1] publicKey
    }
    return null;
}

fn curveFromOid(oid: []const u8) Error!?Curve {
    if (std.mem.eql(u8, oid, Curve.p256.paramsOid())) return .p256;
    if (std.mem.eql(u8, oid, Curve.p384.paramsOid())) return .p384;
    return null;
}

/// Parse a PKCS#8 PrivateKeyInfo: SEQUENCE { INTEGER 0, SEQUENCE { OID
/// id-ecPublicKey, OID curve }, OCTET STRING (SEC1 ECPrivateKey) }.
fn parsePkcs8(der: []const u8, out: *KeyPair) Error!void {
    var d = Der{ .buf = der };
    const seq = try d.readTlv();
    if (seq.tag != 0x30) return error.InvalidKey;
    var inner = Der{ .buf = seq.value };
    // version
    const ver = try inner.readTlv();
    if (ver.tag != 0x02) return error.InvalidKey;
    // algorithm identifier
    const alg = try inner.readTlv();
    if (alg.tag != 0x30) return error.InvalidKey;
    var alg_inner = Der{ .buf = alg.value };
    const oid = try alg_inner.readTlv();
    if (oid.tag != 0x06) return error.InvalidKey;
    // id-ecPublicKey: 1.2.840.10045.2.1
    if (!std.mem.eql(u8, oid.value, &.{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 })) {
        return error.UnsupportedCurve; // RSA or others
    }
    const curve_oid = try alg_inner.readTlv();
    if (curve_oid.tag != 0x06) return error.InvalidKey;
    const curve = (try curveFromOid(curve_oid.value)) orelse return error.UnsupportedCurve;
    // the wrapped SEC1 ECPrivateKey
    const priv_wrap = try inner.readTlv();
    if (priv_wrap.tag != 0x04) return error.InvalidKey;
    try parseSec1(priv_wrap.value, curve, out);
}

/// Load the credentials from PEM files: `cert_pem` (CERTIFICATE) and
/// `key_pem` (EC PRIVATE KEY or PRIVATE KEY). The DER slices point into
/// caller-owned buffers.
pub fn loadCredentials(
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    key_pem: []const u8,
) Error!Credentials {
    var cert_buf: [16 * 1024]u8 = undefined;
    const cert_len = (try pem.decodeFirst(cert_pem, "CERTIFICATE", &cert_buf)) orelse
        return error.CertificateNotFound;
    const cert_der = try allocator.dupe(u8, cert_buf[0..cert_len]);
    errdefer allocator.free(cert_der);

    var key_buf: [8 * 1024]u8 = undefined;
    var key: KeyPair = undefined;
    if (try pem.decodeFirst(key_pem, "EC PRIVATE KEY", &key_buf)) |key_len| {
        const curve = (try sec1CurveOid(key_buf[0..key_len])) orelse return error.UnsupportedCurve;
        key.curve = (try curveFromOid(curve)) orelse return error.UnsupportedCurve;
        try parseSec1(key_buf[0..key_len], key.curve, &key);
    } else if (try pem.decodeFirst(key_pem, "PRIVATE KEY", &key_buf)) |key_len| {
        try parsePkcs8(key_buf[0..key_len], &key);
    } else return error.KeyNotFound;
    return .{ .cert_der = cert_der, .key = key };
}

const testing = std.testing;
const testdata = @import("testdata.zig");
const tls_cert_pem = testdata.cert_pem;
const tls_key_pem = testdata.key_pem;

test "cert: loads the ECDSA P-256 test credentials" {
    var creds = try loadCredentials(testing.allocator, tls_cert_pem, tls_key_pem);
    defer testing.allocator.free(creds.cert_der);
    try testing.expectEqual(Curve.p256, creds.key.curve);
    try testing.expectEqual(@as(usize, 32), creds.key.secret_len);
    try testing.expect(creds.cert_der.len > 100);
}

test "cert: PKCS#8 keys parse too" {
    // openssl pkcs8 -topk8 -nocrypt of the same key.
    const pkcs8 =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgwsnZmQRBLfXBHPMz
        \\vALA9AR75nw1zU60F+DjSvLB3QOhRANCAARicdBsxb5aDOJP3vqoTH50fEdXyXTs
        \\i5TglmU+tZ6Lr2LM2ZjgEuFqU8VZ4qfJlqCKpMJAss8OsHRDjLIvpJcX
        \\-----END PRIVATE KEY-----
    ;
    var creds = try loadCredentials(testing.allocator, tls_cert_pem, pkcs8);
    defer testing.allocator.free(creds.cert_der);
    try testing.expectEqual(Curve.p256, creds.key.curve);
    try testing.expectEqualSlices(u8, &.{ 0xc2, 0xc9, 0xd9, 0x99, 0x04, 0x41, 0x2d, 0xf5, 0xc1, 0x1c, 0xf3, 0x33, 0xbc, 0x02, 0xc0, 0xf4, 0x04, 0x7b, 0xe6, 0x7c, 0x35, 0xcd, 0x4e, 0xb4, 0x17, 0xe0, 0xe3, 0x4a, 0xf2, 0xc1, 0xdd, 0x03 }, creds.key.secret_key[0..32]);
}

test "cert: RSA and garbage keys are rejected" {
    const rsa_key =
        \\-----BEGIN PRIVATE KEY-----
        \\MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAO4zAC8qTf5cq8Ee
        \\YCVGiEWkttI27HRIaj78EkcnGGjZmONuMZ2ExFAdxAQG/OotTmB0tg7wkuWN7l5m
        \\9PGNvVOtpZmYliogrGvibGV+fgonUu31grW2ZzFn+17HfK9wrr8l3d148yF3wExq
        \\WQ6wBpXOkSX4stc/fGyodilKOhzVAgMBAAECgYAx+5G2U/I5xchkpbMXH03JD18t
        \\jUjgvbFNtic/tvxwQ/jJAH54xztKdHSFQ9IecZNYuiTZzbGFadrzBDex2EQ5uzSx
        \\eVUqUBdrngYitfVfXh2BknvXSOWFBh5U0PK/5vQKstInP2Oh7zzjPhvGmcq6gqcW
        \\Vgw2TLxGIbQYTAyRoQJBAPy7ReAZ976sZWnq266VEpcxvFNxC01LnMH2xC1on9IN
        \\ty3uG6YtRF325a3ijQPyscVNz9Imtyg34JAjaeAR0G8CQQDxR515hAWbmfGFIcRD
        \\Uwzxb2J680CWJGfnVUQXLrPZ08iMUsDAjPM8qCUnaJGm/VK8PVx1bfY5xSn97Bob
        \\SUD7AkEAxZz5Kh2j5eeO9J67X2sYujgddXEy0SGKVO/KvWbNcMVgsf04iVtj1cU0
        \\Gh7G/ItMDWamVUAIft4SLSJDqvzC6QJBAMB6+zuHgNnDE5O7flCfHoI084FWMT4V
        \\yPYZZXqA/WVWuHSJR8/UIe9PzGQF3bwz9x7IbMwZbwZjLb6t7Z268KUCQCHfg4jl
        \\PM/pNRJ13aupRPB6lzqH5ClSYqxV3Pmdk7SM6XaxfunGhJ2dLF/GMM2HAvKxAozB
        \\7xvtq+ObrJZbyQI=
        \\-----END PRIVATE KEY-----
    ;
    try testing.expectError(error.UnsupportedCurve, loadCredentials(testing.allocator, tls_cert_pem, rsa_key));
    try testing.expectError(error.KeyNotFound, loadCredentials(testing.allocator, tls_cert_pem, "not a key"));
    try testing.expectError(error.CertificateNotFound, loadCredentials(testing.allocator, "no cert", tls_key_pem));
}
