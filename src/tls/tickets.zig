//! TLS 1.3 session tickets (M18, RFC 8446 §4.6.1): stateless
//! NewSessionTicket issuance and PSK resumption. The ticket payload is the
//! connection's master secret, AES-128-GCM encrypted under a per-process
//! random key (the reactor never stores session state — any of its workers
//! can decrypt any ticket). 0-RTT early data is NOT enabled: tickets are
//! usable for 1-RTT resumption only.

const std = @import("std");
const tls = std.crypto.tls;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

pub const lifetime_seconds: u32 = 3600;

/// The process-global ticket encryption key, generated on first use
/// (multi-reactor safe: all reactors share the process).
var g_key: ?[Aes128Gcm.key_length]u8 = null;
var g_key_iv: ?[Aes128Gcm.nonce_length]u8 = null;

fn key() *const [Aes128Gcm.key_length]u8 {
    if (g_key == null) {
        var k: [Aes128Gcm.key_length]u8 = undefined;
        std.crypto.random.bytes(&k);
        g_key = k;
    }
    return &g_key.?;
}

fn iv() *const [Aes128Gcm.nonce_length]u8 {
    if (g_key_iv == null) {
        var k: [Aes128Gcm.nonce_length]u8 = undefined;
        std.crypto.random.bytes(&k);
        g_key_iv = k;
    }
    return &g_key_iv.?;
}

pub const max_ticket_len = 64;

/// Encrypt `master_secret` into a self-contained ticket: the nonce is
/// prefixed so the server can reopen any returned ticket (stateless). The
/// nonce is also the AEAD AAD.
pub fn seal(master_secret: []const u8, nonce: [8]u8, out: []u8) !usize {
    if (8 + master_secret.len + Aes128Gcm.tag_length > out.len) return error.OutOfMemory;
    @memcpy(out[0..8], &nonce);
    var n: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(n[0..8], &nonce);
    @memset(n[8..], 0);
    const ct = out[8 .. 8 + master_secret.len];
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(ct, &tag, master_secret, &nonce, n, key().*);
    @memcpy(out[8 + master_secret.len ..][0..tag.len], &tag);
    return 8 + master_secret.len + tag.len;
}

/// Open a ticket (nonce read from its prefix), returning the master secret
/// (into `out`). Null on any integrity failure.
pub fn open(ticket: []const u8, out: []u8) ?usize {
    if (ticket.len < 8 + Aes128Gcm.tag_length) return null;
    const nonce = ticket[0..8];
    const body = ticket[8..];
    if (body.len - Aes128Gcm.tag_length > out.len) return null;
    var n: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(n[0..8], nonce);
    @memset(n[8..], 0);
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, body[body.len - Aes128Gcm.tag_length ..]);
    Aes128Gcm.decrypt(out[0 .. body.len - Aes128Gcm.tag_length], body[0 .. body.len - Aes128Gcm.tag_length], tag, nonce, n, key().*) catch return null;
    return body.len - Aes128Gcm.tag_length;
}

/// Build a NewSessionTicket handshake message (RFC 8446 §4.6.1) into `out`;
/// returns the message length (including the 4-byte handshake header).
/// The ticket encrypts `master_secret`; `ticket_nonce` distinguishes
/// tickets issued for the same session.
pub fn buildNewSessionTicket(
    out: []u8,
    master_secret: []const u8,
    ticket_nonce: u8,
) !usize {
    var pos: usize = 0;
    out[pos] = 0x04; // new_session_ticket
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    std.mem.writeInt(u32, out[pos..][0..4], lifetime_seconds, .big);
    pos += 4;
    var age_add: [4]u8 = undefined;
    std.crypto.random.bytes(&age_add);
    @memcpy(out[pos..][0..4], &age_add);
    pos += 4;
    out[pos] = 1; // ticket_nonce length
    pos += 1;
    out[pos] = ticket_nonce;
    pos += 1;
    // ticket (encrypted master secret; self-contained nonce)
    var nonce: [8]u8 = undefined;
    @memcpy(nonce[0..4], &age_add);
    nonce[4] = ticket_nonce;
    @memset(nonce[5..], 0);
    const ticket_len = try seal(master_secret, nonce, out[pos + 2 ..]);
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(ticket_len), .big);
    pos += 2 + ticket_len;
    std.mem.writeInt(u16, out[pos..][0..2], 0, .big); // extensions
    pos += 2;
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);
    return pos;
}

const testing = std.testing;

test "tickets: seal/open round trip" {
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);
    var ticket: [max_ticket_len]u8 = undefined;
    const n = try seal(&secret, .{ 1, 2, 3, 4, 5, 6, 7, 8 }, &ticket);
    var opened: [32]u8 = undefined;
    const m = open(ticket[0..n], &opened) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 32), m);
    try testing.expectEqualSlices(u8, &secret, &opened);
}

test "tickets: tampering and wrong nonce fail" {
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);
    var ticket: [max_ticket_len]u8 = undefined;
    const n = try seal(&secret, .{ 0, 0, 0, 0, 0, 0, 0, 1 }, &ticket);
    ticket[12] ^= 0xff;
    var opened: [32]u8 = undefined;
    try testing.expect(open(ticket[0..n], &opened) == null);
    ticket[12] ^= 0xff;
    // A ticket with a corrupted nonce prefix fails too.
    ticket[0] ^= 0xff;
    try testing.expect(open(ticket[0..n], &opened) == null);
}

test "tickets: NewSessionTicket message is well-formed" {
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);
    var msg: [128]u8 = undefined;
    const n = try buildNewSessionTicket(&msg, &secret, 0);
    try testing.expectEqual(@as(u8, 0x04), msg[0]);
    const body_len: usize = std.mem.readInt(u24, msg[1..4], .big);
    try testing.expectEqual(@as(usize, n - 4), body_len);
    try testing.expect(msg[4 + 4 + 4] == 1); // ticket_nonce length
}
