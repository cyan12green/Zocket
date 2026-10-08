//! ACME JWS (C3 auto-HTTPS): ES256 compact signing/verification for the
//! RFC 8555 message layer (newOrder/challenge/finalize). JWK thumbprints
//! (RFC 7638, SHA-256 over the canonical EC JWK) back the http-01
//! keyAuthorization the challenge module serves. The CA exchange loop
//! (account → order → poll → download → install) rides on top next.

const std = @import("std");

pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// base64url-no-pad encode (RFC 8555 uses unpadded base64url throughout).
pub fn b64urlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(data.len));
    const wrote = enc.encode(out, data);
    std.debug.assert(wrote.len == out.len);
    return out;
}

/// Sign `payload_b64` under `protected_b64` (both already base64url):
/// compact = protected.payload.sig. `secret32` is the P-256 scalar.
pub fn signCompact(allocator: std.mem.Allocator, secret32: *const [32]u8, protected_b64: []const u8, payload_b64: []const u8) ![]u8 {
    const sk = try Ecdsa.SecretKey.fromBytes(secret32.*);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    var msg = std.ArrayList(u8).empty;
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, protected_b64);
    try msg.append(allocator, '.');
    try msg.appendSlice(allocator, payload_b64);
    var h: [32]u8 = undefined;
    Ecdsa.Hash.hash(msg.items, &h, .{});
    const sig = try kp.signPrehashed(h, null);
    var der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_sig = sig.toDer(&der);
    // JWS needs raw R||S, not DER: parse back through fixed bytes.
    const raw = sig.toBytes();
    const sig_b64 = try b64urlEncode(allocator, &raw);
    defer allocator.free(sig_b64);
    _ = der_sig;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, msg.items);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, sig_b64);
    return out.toOwnedSlice(allocator);
}

/// Verify a compact JWS with the account public key (SEC1 uncompressed);
/// returns the decoded payload (allocator-owned) on success.
pub fn verifyCompact(allocator: std.mem.Allocator, pub_sec1: []const u8, compact: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, compact, '.');
    const prot = it.next() orelse return error.BadJws;
    const pay = it.next() orelse return error.BadJws;
    const sig = it.next() orelse return error.BadJws;
    if (it.next() != null) return error.BadJws;
    const pubkey = Ecdsa.PublicKey.fromSec1(pub_sec1) catch return error.BadJws;
    var sig_raw: [64]u8 = undefined;
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig) catch return error.BadJws;
    if (sig_len != 64) return error.BadJws;
    std.base64.url_safe_no_pad.Decoder.decode(&sig_raw, sig) catch return error.BadJws;
    const ecdsa_sig = Ecdsa.Signature.fromBytes(sig_raw);
    var msg = std.ArrayList(u8).empty;
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, prot);
    try msg.append(allocator, '.');
    try msg.appendSlice(allocator, pay);
    var h: [32]u8 = undefined;
    Ecdsa.Hash.hash(msg.items, &h, .{});
    ecdsa_sig.verifyPrehashed(h, pubkey) catch return error.BadJws;
    // Decode payload.
    const dec = std.base64.url_safe_no_pad.Decoder;
    const plen = dec.calcSizeForSlice(pay) catch return error.BadJws;
    const payload = try allocator.alloc(u8, plen);
    errdefer allocator.free(payload);
    dec.decode(payload, pay) catch {
        allocator.free(payload);
        return error.BadJws;
    };
    return payload;
}

/// RFC 7638 JWK thumbprint for a P-256 SEC1 key: base64url(SHA-256 of
/// `{"crv":"P-256","kty":"EC","x":"..","y":".."}` with 32-byte big-endian
/// coordinates, no whitespace).
pub fn thumbprint(pub_sec1: []const u8) ![43]u8 {
    if (pub_sec1.len != 65 or pub_sec1[0] != 0x04) return error.BadKey;
    const hex = std.fmt.bytesToHex(pub_sec1[1..33], .lower);
    _ = hex;
    var canon: [128]u8 = undefined;
    var pos: usize = 0;
    const head = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"";
    @memcpy(canon[pos..][0..head.len], head);
    pos += head.len;
    const b64 = std.base64.url_safe_no_pad.Encoder;
    pos += b64.encode(canon[pos..], pub_sec1[1..33]).len;
    const mid = "\",\"y\":\"";
    @memcpy(canon[pos..][0..mid.len], mid);
    pos += mid.len;
    pos += b64.encode(canon[pos..], pub_sec1[33..65]).len;
    canon[pos] = '"';
    pos += 1;
    canon[pos] = '}';
    pos += 1;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canon[0..pos], &digest, .{});
    var out: [43]u8 = undefined;
    _ = b64.encode(&out, &digest);
    return out;
}

const testing = std.testing;

test "jws es256 signs and verifies, rejects tampering" {
    const allocator = testing.allocator;
    const seed = @as([32]u8, @splat(@as(u8, 0x77)));
    const sk = try Ecdsa.SecretKey.fromBytes(seed);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    const pub_sec1 = kp.public_key.toUncompressedSec1();
    const prot = try b64urlEncode(allocator, "{\"alg\":\"ES256\"}");
    defer allocator.free(prot);
    const pay = try b64urlEncode(allocator, "{\"order\":1}");
    defer allocator.free(pay);
    const compact = try signCompact(allocator, &seed, prot, pay);
    defer allocator.free(compact);
    const payload = try verifyCompact(allocator, &pub_sec1, compact);
    defer allocator.free(payload);
    try testing.expectEqualStrings("{\"order\":1}", payload);
    // Tampered payload fails.
    var bad = try allocator.dupe(u8, compact);
    defer allocator.free(bad);
    bad[bad.len - 3] ^= 0x01;
    try testing.expectError(error.BadJws, verifyCompact(allocator, &pub_sec1, bad));
}

test "jwk thumbprint matches a Python-hashlib cross-check" {
    // P-256 JWK; expected value computed independently with Python
    // hashlib (RFC 7638 §3 canonical form).
    const x_b64 = "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7iM";
    const y_b64 = "4EtlI1YrXY4iTJu5RTc8uz5A__vG4GgpTz9UEz5v2vM";
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&x, x_b64);
    try std.base64.url_safe_no_pad.Decoder.decode(&y, y_b64);
    var sec1: [65]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1..33], &x);
    @memcpy(sec1[33..65], &y);
    const tp = try thumbprint(&sec1);
    try testing.expectEqualStrings("QRr9UDIXDxAm-JAlBeO1YPt4DeQt1n9Q4GdAC2D1PZo", &tp);
}
