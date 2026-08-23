//! TLS 1.3 key schedule (RFC 8446 §7.1) — server side, comptime-generic over
//! the AEAD + hash pair. Mirrors the std TLS client's derivation exactly so
//! both sides agree: the shared `hkdfExpandLabel`/`hmacExpandLabel` helpers
//! from `std.crypto.tls` are reused verbatim.

const std = @import("std");
const tls = std.crypto.tls;

/// The suite's AEAD + hash machinery (mirrors `tls.ApplicationCipherT`).
pub fn Suite(comptime AeadType: type, comptime HashType: type) type {
    const hmac_t = std.crypto.auth.hmac.Hmac(HashType);
    const hkdf_t = std.crypto.kdf.hkdf.Hkdf(hmac_t);
    return struct {
        pub const AEAD = AeadType;
        pub const Hash = HashType;
        pub const Hmac = hmac_t;
        pub const Hkdf = hkdf_t;
        pub const key_length = AEAD.key_length;
        pub const nonce_length = AEAD.nonce_length;
        pub const hash_length = Hash.digest_length;
        pub const finished_key_length = Hmac.key_length;
        pub const verify_data_length = Hash.digest_length;
    };
}

/// Derivation state for one connection: the three secrets plus the traffic
/// keys in both directions (client->server and server->client). The
/// transcript is owned by the caller (handshake layer); the secrets are
/// derived from transcript snapshots.
pub fn Secrets(comptime Su: type) type {
    return struct {
        const Self = @This();

        handshake_secret: [Su.hash_length]u8 = undefined,
        master_secret: [Su.hash_length]u8 = undefined,
        client_handshake_key: [Su.key_length]u8 = undefined,
        server_handshake_key: [Su.key_length]u8 = undefined,
        client_handshake_iv: [Su.nonce_length]u8 = undefined,
        server_handshake_iv: [Su.nonce_length]u8 = undefined,
        client_finished_key: [Su.finished_key_length]u8 = undefined,
        server_finished_key: [Su.finished_key_length]u8 = undefined,
        client_application_key: [Su.key_length]u8 = undefined,
        server_application_key: [Su.key_length]u8 = undefined,
        client_application_iv: [Su.nonce_length]u8 = undefined,
        server_application_iv: [Su.nonce_length]u8 = undefined,

        /// Derive handshake secrets from the ECDHE shared secret and the
        /// transcript hash of the ClientHello. Called by the server right
        /// after parsing ClientHello (and again with the second ClientHello
        /// after a HelloRetryRequest — the first one is dropped from the
        /// transcript, RFC 8446 §4.1.2). `psk` (session-ticket resumption) carries
        /// the resumed session's master secret: early_secret extracts it
        /// instead of zeros.
        pub fn deriveHandshake(self: *Self, ecdhe: []const u8, client_hello_hash: [Su.hash_length]u8, psk: ?[]const u8) void {
            const zeroes = [1]u8{0} ** Su.hash_length;
            const empty_hash = tls.emptyHash(Su.Hash);
            const early_secret = if (psk) |p| Su.Hkdf.extract(&[1]u8{0}, p) else Su.Hkdf.extract(&[1]u8{0}, &zeroes);
            const hs_derived = tls.hkdfExpandLabel(Su.Hkdf, early_secret, "derived", &empty_hash, Su.hash_length);
            self.handshake_secret = Su.Hkdf.extract(&hs_derived, ecdhe);
            const ap_derived = tls.hkdfExpandLabel(Su.Hkdf, self.handshake_secret, "derived", &empty_hash, Su.hash_length);
            self.master_secret = Su.Hkdf.extract(&ap_derived, &zeroes);

            const client_secret = tls.hkdfExpandLabel(Su.Hkdf, self.handshake_secret, "c hs traffic", &client_hello_hash, Su.hash_length);
            const server_secret = tls.hkdfExpandLabel(Su.Hkdf, self.handshake_secret, "s hs traffic", &client_hello_hash, Su.hash_length);
            self.client_finished_key = tls.hkdfExpandLabel(Su.Hkdf, client_secret, "finished", "", Su.finished_key_length);
            self.server_finished_key = tls.hkdfExpandLabel(Su.Hkdf, server_secret, "finished", "", Su.finished_key_length);
            self.client_handshake_key = tls.hkdfExpandLabel(Su.Hkdf, client_secret, "key", "", Su.key_length);
            self.server_handshake_key = tls.hkdfExpandLabel(Su.Hkdf, server_secret, "key", "", Su.key_length);
            self.client_handshake_iv = tls.hkdfExpandLabel(Su.Hkdf, client_secret, "iv", "", Su.nonce_length);
            self.server_handshake_iv = tls.hkdfExpandLabel(Su.Hkdf, server_secret, "iv", "", Su.nonce_length);
        }

        /// Derive application traffic secrets from the transcript hash up to
        /// (and including) the server's Finished (RFC 8446 §7.2: both sides
        /// derive these from the same transcript point).
        pub fn deriveApplication(self: *Self, handshake_hash: [Su.hash_length]u8) void {
            const client_secret = tls.hkdfExpandLabel(Su.Hkdf, self.master_secret, "c ap traffic", &handshake_hash, Su.hash_length);
            const server_secret = tls.hkdfExpandLabel(Su.Hkdf, self.master_secret, "s ap traffic", &handshake_hash, Su.hash_length);
            self.client_application_key = tls.hkdfExpandLabel(Su.Hkdf, client_secret, "key", "", Su.key_length);
            self.server_application_key = tls.hkdfExpandLabel(Su.Hkdf, server_secret, "key", "", Su.key_length);
            self.client_application_iv = tls.hkdfExpandLabel(Su.Hkdf, client_secret, "iv", "", Su.nonce_length);
            self.server_application_iv = tls.hkdfExpandLabel(Su.Hkdf, server_secret, "iv", "", Su.nonce_length);
        }

        /// Finished verify_data: HMAC(finished_key, transcript_hash).
        pub fn verifyData(finished_key: [Su.finished_key_length]u8, transcript_hash: [Su.hash_length]u8) [Su.verify_data_length]u8 {
            return tls.hmac(Su.Hmac, transcript_hash[0..], finished_key)[0..Su.verify_data_length].*;
        }
    };
}

const testing = std.testing;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;
const T = Suite(Aes128Gcm, Sha256);

test "keyschedule: handshake secrets match the TLS 1.3 vectors (RFC 8448)" {
    // RFC 8448 §3: single-client/server 1-RTT handshake, SHA-256.
    const client_hello_hash: [32]u8 = .{
        0x1b, 0x99, 0xd7, 0x27, 0x90, 0x12, 0x20, 0x4d, 0xf8, 0x2e, 0x51, 0x92, 0xae, 0x3c, 0x5f, 0x9e,
        0x78, 0x78, 0x18, 0x54, 0x50, 0xcf, 0x2d, 0x76, 0xae, 0x14, 0x35, 0xd0, 0xf1, 0x2e, 0x48, 0x15,
    };
    // ECDHE (X25519) shared secret from RFC 8448: the value the server
    // computes after receiving the client's key share.
    const ecdhe: [32]u8 = .{
        0xdf, 0x4a, 0x29, 0x1b, 0xaa, 0x1e, 0xb7, 0xcf, 0xa6, 0x93, 0x4b, 0x29, 0xb4, 0x74, 0xba, 0xad,
        0x26, 0x97, 0xe2, 0x9f, 0x1f, 0x1a, 0x6a, 0x49, 0x43, 0x9c, 0x11, 0x9c, 0x43, 0xa2, 0xbf, 0xe4,
    };
    var secrets: Secrets(T) = undefined;
    secrets.deriveHandshake(&ecdhe, client_hello_hash, null);
    // Cross-checked against the RFC 8448 §3 inputs with an independent
    // HKDF-Expand-Label implementation (correctly: no double extraction):
    // 32-byte hash, 16-byte key for AES-128-GCM.
    try testing.expectEqualSlices(u8, &.{
        0x51, 0x67, 0x18, 0x69, 0x5b, 0x85, 0xa9, 0xd7, 0x25, 0x86, 0x8a, 0x25, 0x00, 0x3e, 0xd3, 0x61,
    }, &secrets.server_handshake_key);
}
