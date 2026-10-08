//! Mutual TLS client-certificate verification (C3): chain + signature
//! checks for the CertificateRequest flight. The session emits
//! CertificateRequest (handshake.zig) when `Credentials.verify_client`
//! is set; the client's Certificate/CertificateVerify messages land here:
//! the leaf must chain to the configured client-CA bundle ( intermediates
//! the client sends are tried as well) and the signature must verify over
//! the session transcript under the "client CertificateVerify" context.
//! Every failure is fail-closed (alert, no application data).

const std = @import("std");
const Certificate = std.crypto.Certificate;

pub const Error = error{
    MtlsDecodeError,
    MtlsChainInvalid,
    MtlsSignatureInvalid,
    MtlsCurveMismatch,
    OutOfMemory,
};

/// Verify `leaf_der` chains to `bundle` at `now_sec`: directly, or via one
/// of the presented `intermediates` (which must itself chain to the bundle).
pub fn verifyChain(bundle: *const Certificate.Bundle, leaf_der: []const u8, intermediates: []const []const u8, now_sec: i64) Error!void {
    const leaf = Certificate.parse(.{ .buffer = leaf_der, .index = 0 }) catch return error.MtlsDecodeError;
    const now_i64: i64 = now_sec;
    bundle.verify(leaf, now_i64) catch |e| switch (e) {
        error.CertificateIssuerNotFound => {
            // Try each presented intermediate as the issuer (which must
            // itself verify against the bundle).
            for (intermediates) |ider| {
                const im = Certificate.parse(.{ .buffer = ider, .index = 0 }) catch continue;
                leaf.verify(im, now_i64) catch continue;
                bundle.verify(im, now_i64) catch continue;
                return;
            }
            return error.MtlsChainInvalid;
        },
        else => return error.MtlsChainInvalid,
    };
}

/// Verify a client's CertificateVerify signature: ECDSA over
/// (64 spaces ++ "TLS 1.3, client CertificateVerify" ++ 0x00 ++ digest)
/// with the leaf's P-curve public key. `digest` is the session's signature
/// transcript hash (SigHash-sized); `sig_der` the message's DER signature.
pub fn verifySignature(comptime Ecdsa: type, leaf_der: []const u8, digest: []const u8, sig_der: []const u8) Error!void {
    const leaf = Certificate.parse(.{ .buffer = leaf_der, .index = 0 }) catch return error.MtlsDecodeError;
    if (leaf.pub_key_algo != .X9_62_id_ecPublicKey) return error.MtlsCurveMismatch;
    const point = leaf.pubKey();
    const pubkey = Ecdsa.PublicKey.fromSec1(point) catch return error.MtlsCurveMismatch;
    const sig = Ecdsa.Signature.fromDer(sig_der) catch return error.MtlsSignatureInvalid;
    // Recreate the signed content (RFC 8446 §4.4.3, client context).
    const context = "TLS 1.3, client CertificateVerify";
    if (digest.len != Ecdsa.Hash.digest_length) return error.MtlsSignatureInvalid;
    var msg: [64 + context.len + 1 + 64]u8 = undefined;
    if (64 + context.len + 1 + digest.len > msg.len) return error.MtlsSignatureInvalid;
    @memset(msg[0..64], ' ');
    @memcpy(msg[64 .. 64 + context.len], context);
    msg[64 + context.len] = 0;
    @memcpy(msg[64 + context.len + 1 ..][0..digest.len], digest);
    var h: [Ecdsa.Hash.digest_length]u8 = undefined;
    Ecdsa.Hash.hash(msg[0 .. 64 + context.len + 1 + digest.len], &h, .{});
    sig.verifyPrehashed(h, pubkey) catch return error.MtlsSignatureInvalid;
}

/// Parse one client Certificate message body (after the 4-byte header):
/// context + certificate_list; returns slices into the input (leaf first).
/// Empty list is an error here — the session maps it to the
/// certificate_required alert when verification is on.
pub fn parseClientCertificate(body: []const u8, out: [][]const u8) Error!usize {
    if (body.len < 1) return error.MtlsDecodeError;
    const ctx_len: usize = body[0];
    if (1 + ctx_len + 3 > body.len) return error.MtlsDecodeError;
    var pos = 1 + ctx_len;
    const list_len = (@as(usize, body[pos]) << 16) | (@as(usize, body[pos + 1]) << 8) | body[pos + 2];
    pos += 3;
    if (pos + list_len != body.len) return error.MtlsDecodeError;
    const end = pos + list_len;
    var n: usize = 0;
    while (pos < end) {
        if (pos + 3 + 2 > end) return error.MtlsDecodeError;
        const cert_len = (@as(usize, body[pos]) << 16) | (@as(usize, body[pos + 1]) << 8) | body[pos + 2];
        pos += 3;
        if (pos + cert_len + 2 > end) return error.MtlsDecodeError;
        if (n >= out.len) return error.MtlsDecodeError;
        out[n] = body[pos .. pos + cert_len];
        n += 1;
        pos += cert_len;
        const ext_len = (@as(usize, body[pos]) << 8) | body[pos + 1];
        pos += 2;
        if (pos + ext_len > end) return error.MtlsDecodeError;
        pos += ext_len;
    }
    if (n == 0) return error.MtlsDecodeError;
    return n;
}

/// Parse a CertificateVerify body: signature_scheme u16 + DER signature.
pub fn parseCertificateVerify(body: []const u8) Error!struct { scheme: u16, sig: []const u8 } {
    if (body.len < 4) return error.MtlsDecodeError;
    const scheme = (@as(u16, body[0]) << 8) | body[1];
    const sig_len = (@as(usize, body[2]) << 8) | body[3];
    if (4 + sig_len != body.len) return error.MtlsDecodeError;
    return .{ .scheme = scheme, .sig = body[4..] };
}

const testing = std.testing;

test "mtls parses a client Certificate message" {
    // context("") + list [ one entry: cert "ABCD", no extensions ].
    const body = [_]u8{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x04, 'A', 'B', 'C', 'D', 0x00, 0x00 };
    var out: [4][]const u8 = undefined;
    const n = try parseClientCertificate(&body, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, "ABCD", out[0]);
    try testing.expectError(error.MtlsDecodeError, parseClientCertificate(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }, &out));
}

test "mtls parses a CertificateVerify message" {
    const body = [_]u8{ 0x04, 0x03, 0x00, 0x02, 0xAA, 0xBB };
    const cv = try parseCertificateVerify(&body);
    try testing.expectEqual(@as(u16, 0x0403), cv.scheme);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, cv.sig);
    try testing.expectError(error.MtlsDecodeError, parseCertificateVerify(&[_]u8{ 0x04, 0x03, 0x00 }));
}

test "mtls verifies the fixture chain and rejects strangers" {
    const testdata = @import("testdata.zig");
    const pem = @import("pem.zig");
    // Decode fixture PEMs to DER.
    var ca_buf: [4096]u8 = undefined;
    const ca_len = (try pem.decodeFirst(testdata.client_ca_pem, "CERTIFICATE", &ca_buf)) orelse return error.TestUnexpected;
    var leaf_buf: [4096]u8 = undefined;
    const leaf_len = (try pem.decodeFirst(testdata.client_cert_pem, "CERTIFICATE", &leaf_buf)) orelse return error.TestUnexpected;
    // Bundle with just the CA.
    var bundle = Certificate.Bundle.empty;
    defer bundle.deinit(testing.allocator);
    const now: std.Io.Timestamp = .{ .nanoseconds = 1_800_000_000 * 1_000_000_000 };
    _ = now;
    const now_sec: i64 = 1_800_000_000; // ~2027, inside fixture validity
    // Append CA DER into the bundle the way addCertsFromFile does.
    const start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(testing.allocator, ca_buf[0..ca_len]);
    try bundle.parseCert(testing.allocator, start, now_sec);
    try verifyChain(&bundle, leaf_buf[0..leaf_len], &.{}, now_sec);
    // The server's own (self-signed, different subject) cert is a stranger.
    var other_buf: [4096]u8 = undefined;
    const other_len = (try pem.decodeFirst(testdata.cert_pem, "CERTIFICATE", &other_buf)) orelse return error.TestUnexpected;
    try testing.expectError(error.MtlsChainInvalid, verifyChain(&bundle, other_buf[0..other_len], &.{}, now_sec));
}

test "mtls verifies a client signature round-trip" {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const testdata = @import("testdata.zig");
    const cert_mod = @import("cert.zig");
    // The fixture client key signs; the fixture leaf verifies — the real
    // pair openssl generated, not a self-made key.
    const creds = try cert_mod.loadCredentials(testing.allocator, testdata.client_cert_pem, testdata.client_key_pem);
    defer testing.allocator.free(creds.cert_der);
    // Real flow: the signer hashes (pad ++ context ++ 0x00 ++ digest)
    // and pre-signs that hash; the verifier recomputes it from `digest`.
    const digest = @as([32]u8, @splat(@as(u8, 0xAA)));
    const context = "TLS 1.3, client CertificateVerify";
    var content: [64 + context.len + 1 + 32]u8 = undefined;
    @memset(content[0..64], ' ');
    @memcpy(content[64 .. 64 + context.len], context);
    content[64 + context.len] = 0;
    @memcpy(content[64 + context.len + 1 ..], &digest);
    var h: [32]u8 = undefined;
    Ecdsa.Hash.hash(&content, &h, .{});
    const sk = try Ecdsa.SecretKey.fromBytes(creds.key.secret_key[0..Ecdsa.SecretKey.encoded_length].*);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    const sig = try kp.signPrehashed(h, null);
    var der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_sig = sig.toDer(&der);
    try verifySignature(Ecdsa, creds.cert_der, &digest, der_sig);
    // Wrong digest fails.
    const other = @as([32]u8, @splat(@as(u8, 0xBB)));
    try testing.expectError(error.MtlsSignatureInvalid, verifySignature(Ecdsa, creds.cert_der, &other, der_sig));
    // Garbage signature fails.
    try testing.expectError(error.MtlsSignatureInvalid, verifySignature(Ecdsa, creds.cert_der, &digest, &[_]u8{ 0x30, 0x03, 0x02, 0x01, 0x01 }));
}
