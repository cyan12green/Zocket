//! Kernel TLS offload (C3): crypto_info builders, probe and enable
//! helpers for TX (and RX) offload of AES-GCM/ChaCha20-Poly1305 suites.
//!
//! ABI (verified against a running kernel — a `setsockopt(SOL_TLS, ...)`
//! crypto_info is accepted only at the exact per-cipher length, and the
//! field order is the TLS 1.2 one even for TLS 1.3):
//!
//!     info{version:u16le = 0x0304, cipher:u16le} ++ iv[8] ++ key[key_len]
//!         ++ salt[4] ++ rec_seq[8]
//!
//! `iv[8]` is the second half of the 12-byte TLS 1.3 traffic IV (the
//! static explicit-nonce base) and `salt[4]` the first half (the salt).
//! The kernel builds the nonce as `salt || (iv XOR rec_seq)`, so the
//! record sequence number goes in big-endian (RFC 8446 §5.3). The cipher
//! ids are the kernel's, not the wire's: 51 (AES-128-GCM), 52
//! (AES-256-GCM), 54 (ChaCha20-Poly1305).
//!
//! Activation (per-connection cutover in the reactor) rides on `probe()`:
//! kernels without kTLS fail closed into the userspace record layer —
//! `configure()` returns false and the session keeps encrypting. The
//! ULP attach itself is a `SOL_TCP`/`TCP_ULP` option and needs an
//! established socket, so the probe connects a loopback pair.

const std = @import("std");
const sys = @import("../sys.zig");

pub const SOL_TLS: u32 = 282;
pub const SOL_TCP: u32 = 6;
pub const TLS_TX: u32 = 1;
pub const TLS_RX: u32 = 2;
pub const TCP_ULP: u32 = 31;

pub const VERSION_1_3: u16 = 0x0304;
pub const CIPHER_AES_GCM_128: u16 = 51;
pub const CIPHER_AES_GCM_256: u16 = 52;
/// Kernel cipher id for ChaCha20-Poly1305 (linux/tls.h), not the TLS 1.3
/// wire value 0x1303.
pub const CIPHER_CHACHA20_POLY1305: u16 = 54;

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

/// Exact crypto_info length the kernel expects for a cipher.
pub fn cryptoInfoLen(cipher: u16) usize {
    const klen = keyLen(cipher);
    if (klen == 0) return 0;
    return 4 + 8 + klen + 4 + 8;
}

/// Fill `out` with the crypto_info the kernel expects. The field order is
/// the TLS 1.2 one — the kernel keeps it for TLS 1.3 as well (verified
/// against the running kernel: a crypto_info is accepted only at exactly
/// this length, and the kernel reads the explicit nonce as
/// `iv[8] XOR rec_seq[8]`):
///
///     info{version:u16le, cipher:u16le} ++ iv[8] ++ key[key_len]
///         ++ salt[4] ++ rec_seq[8]
///
/// `iv12` is the 12-byte TLS 1.3 traffic IV: bytes 0..4 are the salt
/// (the `salt` field), bytes 4..12 the static explicit-nonce base (the
/// `iv` field). The record sequence number goes in big-endian, matching
/// RFC 8446 §5.3.
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

/// True when this kernel does kTLS (the "tls" ULP attaches to an
/// established TCP socket). Cached per process — one loopback connect and
/// one syscall, then a stable answer.
var probe_cache: ?bool = null;

pub fn probe() bool {
    if (probe_cache) |v| return v;
    const v = probeOnce();
    probe_cache = v;
    return v;
}

/// Attach the "tls" ULP to `fd`. The option lives at SOL_TCP/TCP_ULP and
/// the kernel requires an established socket (it returns ENOTCONN on a
/// fresh one). Returns false when the kernel has no TLS ULP.
pub fn attachUlp(fd: std.posix.fd_t) bool {
    const ulp = "tls\x00";
    const rc = std.os.linux.setsockopt(fd, SOL_TCP, TCP_ULP, ulp, @intCast(ulp.len));
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn probeOnce() bool {
    // Loopback pair: the client socket is ESTABLISHED once connect()
    // returns, which is all the ULP attach needs.
    const lfd = sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return false;
    defer sys.close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2; // AF_INET
    addr[4] = 127;
    addr[7] = 1;
    try_ignore_bind: {
        sys.bind(lfd, @ptrCast(&addr), 16) catch break :try_ignore_bind;
    }
    sys.listen(lfd, 1) catch return false;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    var len: std.posix.socklen_t = 16;
    sys.getsockname(lfd, @ptrCast(&bound), &len) catch return false;
    // Port is big-endian in bytes 2..4 of the sockaddr.
    const port: u16 = (@as(u16, bound[2]) << 8) | @as(u16, bound[3]);
    const cfd = sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return false;
    defer sys.close(cfd);
    var caddr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    caddr[0] = 2;
    caddr[4] = 127;
    caddr[7] = 1;
    caddr[2] = @intCast(port >> 8);
    caddr[3] = @intCast(port & 0xff);
    sys.connect(cfd, @ptrCast(&caddr), 16) catch return false;
    return attachUlp(cfd);
}

/// Install the crypto_info for one direction. The ULP must already be
/// attached (`attachUlp`); the kernel rejects crypto_info without it.
/// Returns false when the kernel refuses (cipher unsupported, wrong
/// length) — the caller then keeps the userspace record layer.
pub fn configure(fd: std.posix.fd_t, direction: u32, suite: u16, key: []const u8, iv12: []const u8, rec_seq: u64) bool {
    if (direction != TLS_TX and direction != TLS_RX) return false;
    if (cipherForSuite(suite) == null) return false;
    var info: [4 + 8 + 32 + 4 + 8]u8 = undefined;
    const n = buildCryptoInfo(&info, suite, key, iv12, rec_seq) orelse return false;
    const rc = std.os.linux.setsockopt(fd, SOL_TLS, direction, info[0..n].ptr, @intCast(n));
    return std.os.linux.errno(rc) == .SUCCESS;
}

/// Full offload cutover for one direction: attach the ULP, then install
/// the keys. A failed attach leaves the socket untouched (userspace
/// keeps encrypting); a failed crypto_info install is fatal for the
/// socket (the ULP is already attached) and the caller must close it.
pub fn cutover(
    fd: std.posix.fd_t,
    direction: u32,
    suite: u16,
    key: []const u8,
    iv12: []const u8,
    rec_seq: u64,
) bool {
    if (!probe()) return false;
    if (!attachUlp(fd)) return false;
    return configure(fd, direction, suite, key, iv12, rec_seq);
}

const testing = std.testing;


test "ktls cipher mapping covers our suites" {
    try testing.expectEqual(@as(?u16, 51), cipherForSuite(0x1301));
    try testing.expectEqual(@as(?u16, 52), cipherForSuite(0x1302));
    // The kernel's ChaCha id is 54 (linux/tls.h), not the wire value.
    try testing.expectEqual(@as(?u16, 54), cipherForSuite(0x1303));
    try testing.expectEqual(@as(?u16, null), cipherForSuite(0x1305));
    try testing.expectEqual(@as(usize, 16), keyLen(51));
    try testing.expectEqual(@as(usize, 32), keyLen(52));
}

test "ktls crypto_info layout matches the kernel's ABI" {
    var out: [64]u8 = undefined;
    const key = @as([16]u8, @splat(@as(u8, 0x11)));
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
    const n = buildCryptoInfo(&out, 0x1301, &key, &iv, 0x0102030405060708).?;
    // info(4) + iv[8] + key[16] + salt[4] + rec_seq[8] — the kernel
    // accepts a crypto_info only at exactly this length.
    try testing.expectEqual(@as(usize, 4 + 8 + 16 + 4 + 8), n);
    try testing.expectEqual(@as(usize, 40), cryptoInfoLen(51));
    try testing.expectEqual(@as(usize, 56), cryptoInfoLen(52));
    // info: version LE + cipher LE.
    try testing.expectEqual(@as(u16, 0x0304), std.mem.readInt(u16, out[0..2], .little));
    try testing.expectEqual(@as(u16, 51), std.mem.readInt(u16, out[2..4], .little));
    // iv[8] = IV[4..12] (the static explicit-nonce base).
    try testing.expectEqualSlices(u8, iv[4..12], out[4..12]);
    // key, salt = IV[0..4], rec_seq big-endian (RFC 8446 §5.3).
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
    const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try sys.bind(lfd, @ptrCast(&addr), 16);
    try sys.listen(lfd, 1);
    if (!a) {
        // No kTLS here: configure fails closed (userspace keeps working).
        const key = @as([16]u8, @splat(@as(u8, 0x11)));
        const iv = @as([12]u8, @splat(@as(u8, 0x22)));
        try testing.expect(!configure(lfd, TLS_TX, 0x1301, &key, &iv, 0));
    }
}

test "ktls installs the crypto_info the kernel accepts" {
    if (!probe()) return error.SkipZigTest;
    // Established loopback pair; the kernel validates the crypto_info
    // length and cipher at setsockopt time, so a successful install is
    // proof that the layout is byte-exact.
    const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try sys.bind(lfd, @ptrCast(&addr), 16);
    try sys.listen(lfd, 1);
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    var len: std.posix.socklen_t = 16;
    try sys.getsockname(lfd, @ptrCast(&bound), &len);
    const port: u16 = (@as(u16, bound[2]) << 8) | @as(u16, bound[3]);
    const cfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(cfd);
    var caddr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    caddr[0] = 2;
    caddr[4] = 127;
    caddr[7] = 1;
    caddr[2] = @intCast(port >> 8);
    caddr[3] = @intCast(port & 0xff);
    try sys.connect(cfd, @ptrCast(&caddr), 16);

    try testing.expect(attachUlp(cfd));
    const key = @as([16]u8, @splat(@as(u8, 0x11)));
    const iv = @as([12]u8, @splat(@as(u8, 0x22)));
    try testing.expect(configure(cfd, TLS_TX, 0x1301, &key, &iv, 0));
    try testing.expect(configure(cfd, TLS_RX, 0x1301, &key, &iv, 0));
    // A wrong-length crypto_info is rejected by the kernel: our builder
    // must never produce one.
    try testing.expect(!configure(cfd, TLS_TX, 0x1305, &key, &iv, 0));
}

test "ktls: the kernel encrypts the server's records with the exported keys" {
    if (!probe()) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session_mod = @import("../tls/session.zig");
    const cert_mod = @import("../tls/cert.zig");
    const testdata = @import("../tls/testdata.zig");
    const sockets = @import("sockets.zig");

    // TCP loopback pair (kTLS needs a TCP socket).
    const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try sys.bind(lfd, @ptrCast(&addr), 16);
    try sys.listen(lfd, 1);
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    var len: std.posix.socklen_t = 16;
    try sys.getsockname(lfd, @ptrCast(&bound), &len);
    const port: u16 = (@as(u16, bound[2]) << 8) | @as(u16, bound[3]);
    const cfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(cfd);
    var caddr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    caddr[0] = 2;
    caddr[4] = 127;
    caddr[7] = 1;
    caddr[2] = @intCast(port >> 8);
    caddr[3] = @intCast(port & 0xff);
    try sys.connect(cfd, @ptrCast(&caddr), 16);
    const sfd = try sockets.acceptNonBlock(lfd);
    defer sys.close(sfd);

    // A receive timeout keeps a broken handshake from hanging the suite.
    const rtimeout = std.mem.toBytes(@as(i64, 10) * std.time.ns_per_s);
    _ = std.os.linux.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &rtimeout, rtimeout.len);
    _ = std.os.linux.setsockopt(sfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &rtimeout, rtimeout.len);

    // Our server session against the std TLS 1.3 client. The server side
    // runs in a thread: the std client finishes its handshake while it is
    // blocked reading the response, so the server must be able to consume
    // the client's Finished in the meantime.
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    const Server = session_mod.Session(
        std.crypto.aead.aes_gcm.Aes128Gcm,
        std.crypto.hash.sha2.Sha256,
        std.crypto.hash.sha2.Sha256,
        std.crypto.sign.ecdsa.EcdsaP256Sha256,
        0x0403,
    );

    const Shared = struct {
        key: [32]u8 = undefined,
        iv: [12]u8 = undefined,
        suite: u16 = 0,
        seq: u64 = 0,
        keys_ready: std.atomic.Value(bool) = .init(false),
        cutover_done: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,
    };
    var shared = Shared{};

    const ServerThread = struct {
        fn run(fd: std.posix.fd_t, c: *const cert_mod.Credentials, sh: *Shared) void {
            var session = Server.init(allocator, c);
            defer session.deinit();
            var buf: [16 * 1024]u8 = undefined;
            var out: [16 * 1024]u8 = undefined;
            while (true) {
                // The accepted socket is non-blocking: poll it.
                const n = std.posix.read(fd, &buf) catch |e| switch (e) {
                    error.WouldBlock => {
                        sys.nanosleep(0, 1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => {
                        sh.err = e;
                        return;
                    },
                };
                if (n == 0) return;
                session.feed(buf[0..n]) catch |e| {
                    sh.err = e;
                    return;
                };
                if (session.currentStage() == .application) {
                    // Echo the client's payload back (userspace encryption,
                    // before the cutover) so its pending read completes.
                    const p = session.takePlaintext(&buf);
                    if (p > 0) {
                        session.write(buf[0..p]) catch |e| {
                            sh.err = e;
                            return;
                        };
                    }
                    // Hand the TX material to the main thread, flush
                    // everything pending, then wait for the cutover before
                    // touching the socket again.
                    const exported = session.exportTxKeys(&sh.key, &sh.iv).?;
                    sh.suite = exported.suite;
                    sh.seq = exported.seq;
                    sh.keys_ready.store(true, .release);
                    const m = session.takeOut(&out);
                    if (m > 0) _ = sys.write(fd, out[0..m]) catch {};
                    while (!sh.cutover_done.load(.acquire)) {
                        sys.nanosleep(0, 1 * std.time.ns_per_ms);
                    }
                    return;
                }
                const m = session.takeOut(&out);
                if (m > 0) _ = sys.write(fd, out[0..m]) catch {};
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ sfd, &creds, &shared });
    defer server_thread.join();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stream = std.Io.net.Stream{ .socket = .{ .handle = cfd, .address = undefined } };
    var client_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var client_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &client_read_buf);
    var writer = stream.writer(io, &client_write_buf);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    sys.randomBytes(&entropy);
    var client = try std.crypto.tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = 0 },
    });

    // The client speaks first: its ClientHello goes into the socket, the
    // server session answers with its flight and echoes the payload.
    try client.writer.writeAll("ping");
    try client.writer.flush();
    try writer.interface.flush();

    // The echo completes the client's pending read.
    var resp: [4]u8 = undefined;
    _ = try client.reader.readSliceAll(&resp);
    try testing.expectEqualStrings("ping", &resp);

    // Wait for the server thread to hand over the TX material.
    var waited: usize = 0;
    while (!shared.keys_ready.load(.acquire)) {
        sys.nanosleep(0, 1 * std.time.ns_per_ms);
        waited += 1;
        if (waited > 5_000) return error.HandshakeTimeout;
    }
    if (shared.err) |e| return e;

    // The cutover: install the exported keys in the kernel.
    try testing.expect(attachUlp(sfd));
    try testing.expect(configure(sfd, TLS_TX, shared.suite, shared.key[0..], &shared.iv, shared.seq));
    shared.cutover_done.store(true, .release);

    // After the cutover the server writes PLAINTEXT: the kernel encrypts
    // it, and the client must decrypt it with the keys it derived.
    const payload = "kernel-encrypted";
    _ = try sys.write(sfd, payload);
    var got: [64]u8 = undefined;
    _ = try client.reader.readSliceAll(got[0..payload.len]);
    try testing.expectEqualStrings(payload, got[0..payload.len]);
}
