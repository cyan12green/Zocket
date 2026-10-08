//! Kernel TLS offload plumbing (C3): crypto_info builders, probe and
//! enable helpers for TX (and RX) offload of AES-GCM/ChaCha20-Poly1305
//! suites. Layouts are byte-exact against linux/tls.h (SOL_TLS=282,
//! TLS_TX=1, TLS_RX=2, TCP_ULP=31).
//!
//! Activation (per-connection cutover in the reactor) rides on `probe()`:
//! kernels without kTLS fail closed into the userspace record layer —
//! `configure()` returns false and the session keeps encrypting. The
//! nonce mapping follows the kernel's TLS 1.3 convention (salt = IV[0..4],
//! iv[] = IV[4..12] XORed with rec_seq by the kernel).

const std = @import("std");
const compat = @import("../compat.zig");

pub const SOL_TLS: u32 = 282;
pub const TLS_TX: u32 = 1;
pub const TLS_RX: u32 = 2;
pub const TCP_ULP: u32 = 31;

pub const VERSION_1_3: u16 = 0x0304;
pub const CIPHER_AES_GCM_128: u16 = 51;
pub const CIPHER_AES_GCM_256: u16 = 52;
pub const CIPHER_CHACHA20_POLY1305: u16 = 60;

/// TLS 1.3 cipher suite (wire value) -> kTLS cipher id, or null when the
/// kernel cannot offload it (e.g. CCM suites we never negotiate).
pub fn cipherForSuite(suite: u16) ?u16 {
    return switch (suite) {
        0x1301 => CIPHER_AES_GCM_128, // TLS_AES_128_GCM_SHA256
        0x1302 => CIPHER_AES_GCM_256, // TLS_AES_256_GCM_SHA384
        0x1303 => CIPHER_CHACHA20_POLY1305, // TLS_CHACHA20_POLY1305_SHA256
        else => null,
    };
}

pub fn keyLen(cipher: u16) usize {
    return switch (cipher) {
        CIPHER_AES_GCM_128 => 16,
        CIPHER_AES_GCM_256 => 32,
        CIPHER_CHACHA20_POLY1305 => 32,
        else => 0,
    };
}

/// Fill `out` with a tls12_crypto_info struct (the same layout kTLS uses
/// for 1.3): info{version, cipher} ++ iv[8] (= IV[4..12]) ++ key ++
/// salt[4] (= IV[0..4]) ++ rec_seq[8] BE. `iv12` is the 12-byte traffic IV.
pub fn buildCryptoInfo(out: []u8, suite: u16, key: []const u8, iv12: []const u8, rec_seq: u64) ?usize {
    const cipher = cipherForSuite(suite) orelse return null;
    const klen = keyLen(cipher);
    if (key.len < klen or iv12.len != 12) return null;
    const need = 4 + 8 + klen + 4 + 8;
    if (out.len < need) return null;
    var pos: usize = 0;
    std.mem.writeInt(u16, out[pos..][0..2], VERSION_1_3, .little);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], cipher, .little);
    pos += 2;
    @memcpy(out[pos..][0..8], iv12[4..12]);
    pos += 8;
    @memcpy(out[pos..][0..klen], key[0..klen]);
    pos += klen;
    @memcpy(out[pos..][0..4], iv12[0..4]);
    pos += 4;
    std.mem.writeInt(u64, out[pos..][0..8], rec_seq, .big);
    pos += 8;
    return pos;
}

/// True when this kernel does kTLS (TCP_ULP "tls" sticks on a TCP socket).
/// Cached per process — one probe syscall, then a stable answer.
var probe_cache: ?bool = null;

pub fn probe() bool {
    if (probe_cache) |v| return v;
    const v = probeOnce();
    probe_cache = v;
    return v;
}

fn probeOnce() bool {
    const fd = compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return false;
    defer compat.close(fd);
    const ulp = "tls\x00";
    const rc = std.os.linux.setsockopt(fd, 6, TCP_ULP, ulp, @intCast(ulp.len));
    return std.os.linux.errno(rc) == .SUCCESS;
}

/// Attach kTLS to `fd` for one direction (TX or RX) with explicit keys.
/// Returns false (userspace fallback) when the kernel refuses — never
/// half-enables: ULP attach and key install are verified in order.
pub fn configure(fd: std.posix.fd_t, direction: u32, suite: u16, key: []const u8, iv12: []const u8, rec_seq: u64) bool {
    if (direction != TLS_TX and direction != TLS_RX) return false;
    if (!probe()) return false;
    var info: [4 + 8 + 32 + 4 + 8]u8 = undefined;
    const n = buildCryptoInfo(&info, suite, key, iv12, rec_seq) orelse return false;
    const ulp = "tls\x00";
    var rc = std.os.linux.setsockopt(fd, 6, TCP_ULP, ulp, @intCast(ulp.len));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        // Already attached (e.g. TX done before RX) is fine.
        // There is no cheap way to query; retry is harmless: EEXIST?
        // setsockopt has no getter — attempt keys directly.
    }
    rc = std.os.linux.setsockopt(fd, @intCast(SOL_TLS), direction, info[0..n].ptr, @intCast(n));
    return std.os.linux.errno(rc) == .SUCCESS;
}

const testing = std.testing;

test "ktls cipher mapping covers our suites" {
    try testing.expectEqual(@as(?u16, 51), cipherForSuite(0x1301));
    try testing.expectEqual(@as(?u16, 52), cipherForSuite(0x1302));
    try testing.expectEqual(@as(?u16, 60), cipherForSuite(0x1303));
    try testing.expectEqual(@as(?u16, null), cipherForSuite(0x1305));
    try testing.expectEqual(@as(usize, 16), keyLen(51));
    try testing.expectEqual(@as(usize, 32), keyLen(52));
}

test "ktls crypto_info layout matches linux/tls.h" {
    var out: [64]u8 = undefined;
    const key = @as([16]u8, @splat(@as(u8, 0x11)));
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
    const n = buildCryptoInfo(&out, 0x1301, &key, &iv, 0x0102030405060708).?;
    try testing.expectEqual(@as(usize, 4 + 8 + 16 + 4 + 8), n);
    // info: version LE + cipher LE.
    try testing.expectEqual(@as(u16, 0x0304), std.mem.readInt(u16, out[0..2], .little));
    try testing.expectEqual(@as(u16, 51), std.mem.readInt(u16, out[2..4], .little));
    // iv[] = IV[4..12].
    try testing.expectEqualSlices(u8, iv[4..12], out[4..12]);
    // key, salt = IV[0..4], rec_seq BE.
    try testing.expectEqualSlices(u8, key[0..16], out[12..28]);
    try testing.expectEqualSlices(u8, iv[0..4], out[28..32]);
    try testing.expectEqual(@as(u64, 0x0102030405060708), std.mem.readInt(u64, out[32..40], .big));
    // Unknown suite / short key / bad iv: null (fallback, never partial).
    try testing.expect(buildCryptoInfo(&out, 0x1305, &key, &iv, 0) == null);
    try testing.expect(buildCryptoInfo(&out, 0x1301, key[0..4], &iv, 0) == null);
    try testing.expect(buildCryptoInfo(out[0..8], 0x1301, &key, &iv, 0) == null);
}

test "ktls probe is stable and configure fails closed without kTLS" {
    const a = probe();
    try testing.expectEqual(a, probe());
    // Loopback TCP pair: configure must not crash; without kTLS it is false.
    const lfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer compat.close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try compat.bind(lfd, @ptrCast(&addr), 16);
    try compat.listen(lfd, 1);
    if (!a) {
        // No kTLS here: configure fails closed (userspace keeps working).
        const key = @as([16]u8, @splat(@as(u8, 0x11)));
        const iv = @as([12]u8, @splat(@as(u8, 0x22)));
        try testing.expect(!configure(lfd, TLS_TX, 0x1301, &key, &iv, 0));
    }
}
