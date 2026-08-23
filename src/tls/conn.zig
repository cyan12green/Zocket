//! TLS connection wrapper: an `AnySession` behind a small dispatch
//! layer so the reactor never deals with the concrete (cipher, curve)
//! instantiation. The variant is chosen after the first ClientHello is
//! buffered (its cipher-suite list decides the suite; the certificate curve
//! decides the signature scheme), then the buffered bytes are handed to the
//! real session.

const std = @import("std");
const session_mod = @import("session.zig");
const handshake_mod = @import("handshake.zig");
const cert_mod = @import("cert.zig");
const tls = std.crypto.tls;

pub const Error = session_mod.Error;
pub const Stage = session_mod.Stage;

/// Instantiate the concrete session for a negotiated cipher suite and
/// certificate curve.
pub fn sessionFor(creds: *const cert_mod.Credentials, suite: u16) session_mod.AnySession {
    const curve = creds.key.curve;
    return switch (suite) {
        0x1301 => switch (curve) { // AES_128_GCM_SHA256
            .p256 => .{ .aes128_p256 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes128Gcm,
                std.crypto.hash.sha2.Sha256,
                std.crypto.hash.sha2.Sha256,
                std.crypto.sign.ecdsa.EcdsaP256Sha256,
                0x0403,
            ).init(std.heap.page_allocator, creds) },
            .p384 => .{ .aes128_p384 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes128Gcm,
                std.crypto.hash.sha2.Sha256,
                std.crypto.hash.sha2.Sha384,
                std.crypto.sign.ecdsa.EcdsaP384Sha384,
                0x0503,
            ).init(std.heap.page_allocator, creds) },
        },
        0x1303 => switch (curve) { // CHACHA20_POLY1305_SHA256
            .p256 => .{ .chacha_p256 = session_mod.Session(
                std.crypto.aead.chacha_poly.ChaCha20Poly1305,
                std.crypto.hash.sha2.Sha256,
                std.crypto.hash.sha2.Sha256,
                std.crypto.sign.ecdsa.EcdsaP256Sha256,
                0x0403,
            ).init(std.heap.page_allocator, creds) },
            .p384 => .{ .chacha_p384 = session_mod.Session(
                std.crypto.aead.chacha_poly.ChaCha20Poly1305,
                std.crypto.hash.sha2.Sha256,
                std.crypto.hash.sha2.Sha384,
                std.crypto.sign.ecdsa.EcdsaP384Sha384,
                0x0503,
            ).init(std.heap.page_allocator, creds) },
        },
        0x1302 => switch (curve) { // AES_256_GCM_SHA384
            .p256 => .{ .aes256_p256 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes256Gcm,
                std.crypto.hash.sha2.Sha384,
                std.crypto.hash.sha2.Sha256,
                std.crypto.sign.ecdsa.EcdsaP256Sha256,
                0x0403,
            ).init(std.heap.page_allocator, creds) },
            .p384 => .{ .aes256_p384 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes256Gcm,
                std.crypto.hash.sha2.Sha384,
                std.crypto.hash.sha2.Sha384,
                std.crypto.sign.ecdsa.EcdsaP384Sha384,
                0x0503,
            ).init(std.heap.page_allocator, creds) },
        },
        else => unreachable,
    };
}

/// Parse just the ClientHello's cipher-suite list out of a handshake record
/// BODY (handshake type byte + 4-byte header + ClientHello message) so the
/// concrete session can be chosen before the handshake proper.
pub fn pickSuiteFromRecord(record_body: []const u8) ?u16 {
    if (record_body.len < 5) return null;
    if (record_body[0] != 0x01) return null; // client_hello handshake type
    const body = record_body[4..];
    // legacy_version(2) random(32) session_id_len(1)
    if (body.len < 35) return null;
    const sid_len: usize = body[34];
    if (body.len < 35 + sid_len + 2) return null;
    const suites_len: usize = std.mem.readInt(u16, body[35 + sid_len ..][0..2], .big);
    if (body.len < 35 + sid_len + 2 + suites_len) return null;
    return handshake_mod.selectCipherSuite(body[35 + sid_len + 2 ..][0..suites_len]);
}

pub const TlsConn = struct {
    inner: session_mod.AnySession,
    /// Bytes buffered before the concrete variant is known (the first
    /// ClientHello record), or while a variant has been chosen but the
    /// caller keeps feeding (drained each feed).
    pending: std.ArrayList(u8) = .empty,
    /// True once `inner` is the real session (not the placeholder).
    chosen: bool = false,

    pub fn init(c: *const cert_mod.Credentials) TlsConn {
        // Placeholder: the curve matches the cert so the record/key-schedule
        // machinery has the right shape; replaced at first feed.
        return .{ .inner = switch (c.key.curve) {
            .p256 => .{ .aes128_p256 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes128Gcm,
                std.crypto.hash.sha2.Sha256,
                std.crypto.hash.sha2.Sha256,
                std.crypto.sign.ecdsa.EcdsaP256Sha256,
                0x0403,
            ).init(std.heap.page_allocator, c) },
            .p384 => .{ .aes256_p384 = session_mod.Session(
                std.crypto.aead.aes_gcm.Aes256Gcm,
                std.crypto.hash.sha2.Sha384,
                std.crypto.hash.sha2.Sha384,
                std.crypto.sign.ecdsa.EcdsaP384Sha384,
                0x0503,
            ).init(std.heap.page_allocator, c) },
        } };
    }

    pub fn deinit(self: *TlsConn) void {
        self.pending.deinit(std.heap.page_allocator);
        switch (self.inner) {
            inline else => |*s| s.deinit(),
        }
    }

    /// Feed wire bytes. The first call buffers until a complete ClientHello
    /// record is available, picks the concrete session, then feeds
    /// everything through.
    pub fn feed(self: *TlsConn, bytes: []const u8) Error!void {
        if (!self.chosen) {
            self.pending.appendSlice(std.heap.page_allocator, bytes) catch return error.OutOfMemory;
            if (self.pending.items.len < 5) return;
            const rec_len: usize = std.mem.readInt(u16, self.pending.items[3..5], .big);
            if (self.pending.items.len < 5 + rec_len) return;
            const c = self.creds();
            const suite = pickSuiteFromRecord(self.pending.items[5 .. 5 + rec_len]) orelse
                return error.UnsupportedCipherSuite;
            const next = sessionFor(c, suite);
            switch (self.inner) {
                inline else => |*s| s.deinit(),
            }
            self.inner = next;
            self.chosen = true;
            // Hand the buffered record to the real session. The pending
            // allocation stays until the connection closes (one ClientHello-
            // sized buffer per connection; freed once by deinit).
            // The pending allocation stays intact until TlsConn.deinit frees
            // it (items must not be cleared — deinit frees items[0..capacity]).
            const taken = self.pending.items;
            switch (self.inner) {
                inline else => |*s| return s.feed(taken),
            }
        }
        switch (self.inner) {
            inline else => |*s| return s.feed(bytes),
        }
    }

    fn creds(self: *const TlsConn) *const cert_mod.Credentials {
        return switch (self.inner) {
            inline else => |*s| s.creds,
        };
    }

    /// Mutable access to the underlying AnySession (the reactor needs it for
    /// the response path).
    pub fn getPtr(self: *TlsConn) *session_mod.AnySession {
        return &self.inner;
    }

    pub fn stage(self: *const TlsConn) Stage {
        return switch (self.inner) {
            inline else => |*s| s.currentStage(),
        };
    }

    pub fn alpn(self: *const TlsConn) []const u8 {
        return switch (self.inner) {
            inline else => |*s| s.negotiatedAlpn(),
        };
    }

    pub fn takeOut(self: *TlsConn, buf: []u8) usize {
        return switch (self.inner) {
            inline else => |*s| s.takeOut(buf),
        };
    }

    pub fn takeOutSlice(self: *TlsConn) []const u8 {
        return switch (self.inner) {
            inline else => |*s| s.takeOutSlice(),
        };
    }

    pub fn consumeOut(self: *TlsConn, n: usize) void {
        switch (self.inner) {
            inline else => |*s| s.consumeOut(n),
        }
    }

    pub fn takePlaintext(self: *TlsConn, buf: []u8) usize {
        return switch (self.inner) {
            inline else => |*s| s.takePlaintext(buf),
        };
    }

    pub fn plaintextSlice(self: *TlsConn) []const u8 {
        return switch (self.inner) {
            inline else => |*s| s.plaintextSlice(),
        };
    }

    pub fn consumePlaintext(self: *TlsConn, n: usize) void {
        switch (self.inner) {
            inline else => |*s| s.consumePlaintext(n),
        }
    }

    pub fn write(self: *TlsConn, plaintext: []const u8) Error!void {
        switch (self.inner) {
            inline else => |*s| return s.write(plaintext),
        }
    }

    pub fn shutdown(self: *TlsConn) Error!void {
        switch (self.inner) {
            inline else => |*s| return s.shutdown(),
        }
    }
};
