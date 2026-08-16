//! TLS 1.3 record layer (RFC 8446 §5): framing, AEAD encryption/decryption,
//! in-place decrypt (the buffer holding the ciphertext also receives the
//! plaintext — no copy on the read path), and the TLS 1.3 nonce construction
//! (fixed IV XOR sequence number). Comptime-generic over the AEAD so the
//! handshake and application traffic both use the same code.

const std = @import("std");
const tls = std.crypto.tls;

pub const header_len = 5;
pub const max_plaintext_len = tls.max_ciphertext_inner_record_len;
/// The record header: content type, legacy version, length.
pub fn writeHeader(out: *[header_len]u8, content_type: u8, len: u16) void {
    out[0] = content_type;
    out[1] = 0x03;
    out[2] = 0x03;
    std.mem.writeInt(u16, out[3..5], len, .big);
}

/// TLS 1.3 nonce: fixed_iv XOR (0^pad || sequence, big-endian).
pub fn nonce(fixed_iv: []const u8, seq: u64) [12]u8 {
    var n: [12]u8 = undefined;
    @memcpy(n[0 .. 12 - 8], fixed_iv[0 .. 12 - 8]);
    // The sequence number is XORed in big-endian (RFC 8446 §5.3).
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, seq, .big);
    const V = @Vector(12, u8);
    const operand: V = ([1]u8{0} ** (12 - 8)) ++ seq_bytes;
    return @as(V, fixed_iv[0..12].*) ^ operand;
}

/// Encrypt `plaintext` (which must end with the inner content type byte, TLS
/// 1.3 style) as a single record. Writes header + ciphertext + tag into
/// `out` (needs plaintext.len + 5 + tag length bytes); returns the total
/// length. `plaintext` may not alias `out`.
pub fn encrypt(
    comptime Aead: type,
    key: [Aead.key_length]u8,
    iv: [Aead.nonce_length]u8,
    seq: u64,
    inner_content_type: u8,
    plaintext: []const u8,
    out: []u8,
) !usize {
    const tag_len = Aead.tag_length;
    if (plaintext.len + header_len + tag_len > out.len) return error.TlsRecordOverflow;
    // Fragment || inner content type (TLS 1.3, RFC 8446 §5.2).
    var buf: [max_plaintext_len + 1]u8 = undefined;
    if (plaintext.len + 1 > buf.len) return error.TlsRecordOverflow;
    @memcpy(buf[0..plaintext.len], plaintext);
    buf[plaintext.len] = inner_content_type;
    const fragment = buf[0 .. plaintext.len + 1];

    const n = nonce(&iv, seq);
    var hdr: [header_len]u8 = undefined;
    writeHeader(&hdr, @intFromEnum(tls.ContentType.application_data), @intCast(fragment.len + tag_len));
    var full: [header_len + max_plaintext_len + 1 + 16]u8 = undefined;
    @memcpy(full[0..header_len], &hdr);
    @memcpy(full[header_len..][0..fragment.len], fragment);
    const ct = full[header_len .. header_len + fragment.len];
    const tag: *[tag_len]u8 = full[header_len + fragment.len ..][0..tag_len];
    Aead.encrypt(ct, tag, fragment, &hdr, n, key);
    @memcpy(out[0..header_len], &hdr);
    @memcpy(out[header_len..][0..ct.len], ct);
    @memcpy(out[header_len + ct.len ..][0..tag_len], tag);
    return header_len + ct.len + tag_len;
}

/// Decrypt one record in place: `record` must be the full record (header +
/// ciphertext + tag) and receives the plaintext fragment + inner content
/// type. Returns the plaintext slice (into `record`) and the inner content
/// type. The header must not be overwritten before the tag check (it is the
/// AEAD AAD), so the plaintext starts at `record[header_len..]`.
pub fn decryptInPlace(
    comptime Aead: type,
    key: [Aead.key_length]u8,
    iv: [Aead.nonce_length]u8,
    seq: u64,
    record: []u8,
) !struct { plaintext: []u8, content_type: u8 } {
    const tag_len = Aead.tag_length;
    if (record.len < header_len + tag_len) return error.TlsRecordOverflow;
    const record_len: usize = std.mem.readInt(u16, record[3..5], .big);
    if (record.len < header_len + record_len) return error.TlsConnectionTruncated;
    if (record_len > tls.max_ciphertext_len) return error.TlsRecordOverflow;
    const body = record[header_len .. header_len + record_len];
    const ciphertext = body[0 .. body.len - tag_len];
    var tag: [tag_len]u8 = undefined;
    @memcpy(&tag, body[body.len - tag_len ..]);
    const plaintext = record[header_len .. header_len + ciphertext.len];
    const aad = record[0..header_len];
    Aead.decrypt(plaintext, ciphertext, tag, aad, nonce(&iv, seq), key) catch
        return error.TlsBadRecordMac;
    const content_type = plaintext[plaintext.len - 1];
    return .{ .plaintext = plaintext[0 .. plaintext.len - 1], .content_type = content_type };
}

/// Encrypt-to-buffer convenience used by the handshake layer: `out` receives
/// the record bytes; `pending` bytes (up to a full record) are flushed first.
const testing = std.testing;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

test "record: encrypt then decrypt round-trips the fragment and content type" {
    var key: [Aes128Gcm.key_length]u8 = undefined;
    var iv: [Aes128Gcm.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&key);
    std.crypto.random.bytes(&iv);
    const fragment = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" ++ "0123456789abcdef";
    var out: [256]u8 = undefined;
    const n = try encrypt(Aes128Gcm, key, iv, 0, @intFromEnum(tls.ContentType.handshake), fragment, &out);
    try testing.expectEqual(@as(usize, fragment.len + 1 + 5 + 16), n);

    const got = try decryptInPlace(Aes128Gcm, key, iv, 0, out[0..n]);
    try testing.expectEqualStrings(fragment, got.plaintext);
    try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.handshake)), got.content_type);
}

test "record: sequence numbers produce distinct nonces" {
    const n0 = nonce(&[_]u8{0} ** 12, 0);
    const n1 = nonce(&[_]u8{0} ** 12, 1);
    try testing.expect(!std.mem.eql(u8, &n0, &n1));
}

test "record: wrong key fails the MAC" {
    var key: [Aes128Gcm.key_length]u8 = undefined;
    var other: [Aes128Gcm.key_length]u8 = undefined;
    var iv: [Aes128Gcm.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&key);
    std.crypto.random.bytes(&other);
    std.crypto.random.bytes(&iv);
    var out: [128]u8 = undefined;
    const n = try encrypt(Aes128Gcm, key, iv, 7, 0, "hello", &out);
    try testing.expectError(error.TlsBadRecordMac, decryptInPlace(Aes128Gcm, other, iv, 7, out[0..n]));
    // And a wrong sequence number fails too (replay protection).
    try testing.expectError(error.TlsBadRecordMac, decryptInPlace(Aes128Gcm, key, iv, 8, out[0..n]));
}

test "record: truncated and oversized records fail cleanly" {
    var key: [Aes128Gcm.key_length]u8 = undefined;
    var iv: [Aes128Gcm.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&key);
    std.crypto.random.bytes(&iv);
    var out: [128]u8 = undefined;
    const n = try encrypt(Aes128Gcm, key, iv, 0, 0, "hello", &out);
    try testing.expectError(error.TlsConnectionTruncated, decryptInPlace(Aes128Gcm, key, iv, 0, out[0 .. n - 2]));
    try testing.expectError(error.TlsRecordOverflow, decryptInPlace(Aes128Gcm, key, iv, 0, out[0..3]));
}
