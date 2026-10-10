//! TLS 1.3 server session (RFC 8446) — the state machine that drives the
//! handshake and record layer for one connection. Generic over the AEAD,
//! the record-hash, the signature-hash and the ECDSA curve so every
//! (cipher, certificate) combination compiles down to its exact types.
//!
//! Buffering model: raw ciphertext accumulates in `in_buf`; records
//! are decrypted IN PLACE within it (ciphertext region becomes plaintext,
//! no copy); handshake messages assemble in `handshake_buf`; application
//! plaintext is copied into `plaintext_out` for the caller; ciphertext
//! ready to send sits in `out_buf` (drained with `takeOut`). The reactor
//! The connection layer wires these to the connection buffers.

const std = @import("std");
const compat = @import("../compat.zig");
const tls = std.crypto.tls;
const cert_mod = @import("cert.zig");
const handshake_mod = @import("handshake.zig");
const record_mod = @import("record.zig");
const keyschedule_mod = @import("keyschedule.zig");
const tickets_mod = @import("tickets.zig");
const mtls_mod = @import("mtls.zig");
const X25519 = std.crypto.dh.X25519;

pub const Error = error{
    TlsIllegalParameter,
    TlsDecodeError,
    TlsUnexpectedMessage,
    TlsBadRecordMac,
    TlsRecordOverflow,
    TlsConnectionTruncated,
    TlsAlert,
    UnsupportedCipherSuite,
    NoUsableKeyShare,
    OutOfMemory,
};

pub const Stage = enum {
    waiting_hello,
    sent_hrr,
    encrypted_flight,
    waiting_finished,
    application,
    closed,
};

const max_plaintext = tls.max_ciphertext_inner_record_len;

pub fn Session(
    comptime A: type,
    comptime RecordHash: type,
    comptime SigHash: type,
    comptime Ecdsa: type,
    comptime signature_scheme: u16,
) type {
    const Suite = keyschedule_mod.Suite(A, RecordHash);
    const Secrets = keyschedule_mod.Secrets(Suite);
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        creds: *const cert_mod.Credentials,
        secrets: Secrets = undefined,
        /// Key-schedule transcript: reset after a HelloRetryRequest (RFC
        /// 8446 §4.1.2 — the second ClientHello replaces the first; the
        /// traffic secrets derive from ClientHello2 onwards).
        key_transcript: RecordHash = .init(.{}),
        /// Finished/CertificateVerify transcript: always includes every
        /// handshake message (ClientHello1 and the HRR included).
        full_transcript: RecordHash = .init(.{}),
        /// The signature transcript (same messages, its own hash type).
        sig_transcript: SigHash = .init(.{}),
        stage: Stage = .waiting_hello,
        /// Resumed session master secret (from a validated session ticket).
        psk: [64]u8 = undefined,
        psk_len: usize = 0,
        /// Ticket nonce counter for NewSessionTicket issuance.
        ticket_nonce: u8 = 0,
        our_random: [32]u8 = undefined,
        legacy_session_id: [32]u8 = undefined,
        sid_len: usize = 0,
        x25519_secret: [32]u8 = undefined,
        x25519_public: [32]u8 = undefined,
        read_seq: u64 = 0,
        write_seq: u64 = 0,
        /// The client's records are encrypted once we send the ServerHello.
        encrypted_read: bool = false,
        cipher_suite: u16 = 0,
        alpn: []const u8 = "",
        /// Client sent status_request (carried from the final ClientHello;
        /// second hello after HRR wins, like the rest of negotiation).
        status_requested: bool = false,
        /// mTLS progress: Certificate seen (chain verified) and
        /// CertificateVerify seen (signature verified). Both required
        /// before Finished when the credentials ask for client certs.
        client_cert_seen: bool = false,
        client_cert_ok: bool = false,
        /// Verified client leaf DER (allocator-owned copy for the
        /// connection lifetime; empty until the chain verifies).
        client_leaf: []const u8 = &.{},
        in_buf: std.ArrayList(u8) = .empty,
        handshake_buf: std.ArrayList(u8) = .empty,
        out_buf: std.ArrayList(u8) = .empty,
        plaintext_out: std.ArrayList(u8) = .empty,
        last_alert: ?u8 = null,

        pub fn init(allocator: std.mem.Allocator, creds: *const cert_mod.Credentials) Self {
            var self = Self{
                .allocator = allocator,
                .creds = creds,
            };
            compat.randomBytes(&self.our_random);
            var seed: [X25519.seed_length]u8 = undefined;
            compat.randomBytes(&seed);
            const kp = X25519.KeyPair.generateDeterministic(seed);
            self.x25519_secret = kp.secret_key;
            self.x25519_public = kp.public_key;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.client_leaf.len > 0) self.allocator.free(self.client_leaf);
            self.in_buf.deinit(self.allocator);
            self.handshake_buf.deinit(self.allocator);
            self.out_buf.deinit(self.allocator);
            self.plaintext_out.deinit(self.allocator);
        }

        pub fn currentStage(self: *const Self) Stage {
            return self.stage;
        }

        pub fn negotiatedAlpn(self: *const Self) []const u8 {
            return self.alpn;
        }

        pub fn alert(self: *const Self) ?u8 {
            return self.last_alert;
        }

        /// Append wire bytes and process as much as possible.
        pub fn feed(self: *Self, bytes: []const u8) Error!void {
            self.in_buf.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
            try self.processInput();
        }

        /// Copy pending ciphertext out and clear the buffer.
        pub fn takeOut(self: *Self, buf: []u8) usize {
            const n = @min(buf.len, self.out_buf.items.len);
            @memcpy(buf[0..n], self.out_buf.items[0..n]);
            std.mem.copyForwards(u8, self.out_buf.items, self.out_buf.items[n..]);
            self.out_buf.items.len -= n;
            return n;
        }

        /// Zero-copy access to pending ciphertext (the reactor drains it
        /// straight into its send buffer). Valid until the next takeOut/
        /// consumeOut/write.
        pub fn takeOutSlice(self: *Self) []const u8 {
            return self.out_buf.items;
        }

        /// Advance past `n` bytes of out_buf (must match what the caller
        /// drained from takeOutSlice).
        pub fn consumeOut(self: *Self, n: usize) void {
            std.debug.assert(n <= self.out_buf.items.len);
            std.mem.copyForwards(u8, self.out_buf.items, self.out_buf.items[n..]);
            self.out_buf.items.len -= n;
        }

        /// Export the server->client application traffic key/IV for kTLS
        /// TX offload (`net/ktls.zig`). `key_out`/`iv_out` receive the raw
        /// bytes (sized by the caller; 32/12 covers every suite); returns
        /// the wire suite + the next TX record sequence (== records sent
        /// so far — the kernel continues numbering from there). Null when
        /// the session has no application keys yet (pre-Finished).
        pub fn exportTxKeys(self: *const Self, key_out: []u8, iv_out: []u8) ?struct { suite: u16, seq: u64 } {
            if (self.stage != .application) return null;
            const klen = self.secrets.server_application_key.len;
            const ivlen = self.secrets.server_application_iv.len;
            if (key_out.len < klen or iv_out.len < ivlen) return null;
            @memcpy(key_out[0..klen], &self.secrets.server_application_key);
            @memcpy(iv_out[0..ivlen], &self.secrets.server_application_iv);
            return .{ .suite = self.cipher_suite, .seq = self.write_seq };
        }

        /// Copy pending application plaintext out and clear the buffer.
        pub fn takePlaintext(self: *Self, buf: []u8) usize {
            const n = @min(buf.len, self.plaintext_out.items.len);
            @memcpy(buf[0..n], self.plaintext_out.items[0..n]);
            std.mem.copyForwards(u8, self.plaintext_out.items, self.plaintext_out.items[n..]);
            self.plaintext_out.items.len -= n;
            return n;
        }

        /// Zero-copy access to pending application plaintext (the reactor
        /// hands it to the h2 session directly). Valid until the next
        /// takePlaintext/consumePlaintext/feed.
        pub fn plaintextSlice(self: *Self) []const u8 {
            return self.plaintext_out.items;
        }

        /// Advance past `n` bytes of plaintext (must match what the caller
        /// consumed from plaintextSlice).
        pub fn consumePlaintext(self: *Self, n: usize) void {
            std.debug.assert(n <= self.plaintext_out.items.len);
            std.mem.copyForwards(u8, self.plaintext_out.items, self.plaintext_out.items[n..]);
            self.plaintext_out.items.len -= n;
        }

        /// Encrypt application data and queue it for sending.
        pub fn write(self: *Self, plaintext: []const u8) Error!void {
            if (self.stage != .application) return error.TlsUnexpectedMessage;
            var offset: usize = 0;
            while (offset < plaintext.len) {
                const chunk = @min(plaintext.len - offset, max_plaintext);
                // The record holds the fragment, the inner content-type byte,
                // the 5-byte header and the AEAD tag (RFC 8446 §5.2).
                var rec: [max_plaintext + 1 + 5 + 16]u8 = undefined;
                const n = record_mod.encrypt(A, self.secrets.server_application_key, self.secrets.server_application_iv, self.write_seq, @intFromEnum(tls.ContentType.application_data), plaintext[offset .. offset + chunk], &rec) catch
                    return error.TlsRecordOverflow;
                self.write_seq += 1;
                self.out_buf.appendSlice(self.allocator, rec[0..n]) catch return error.OutOfMemory;
                offset += chunk;
            }
        }

        /// Queue a close_notify alert.
        pub fn shutdown(self: *Self) Error!void {
            if (self.stage == .closed) return;
            self.stage = .closed;
            try self.emitAlert(tls.Alert.Description.close_notify);
        }

        // ---- internals ----

        fn fail(self: *Self, err: Error, comptime description: tls.Alert.Description) Error {
            self.last_alert = @intFromEnum(description);
            _ = self.emitAlert(description) catch {};
            return err;
        }

        fn emitAlert(self: *Self, comptime description: tls.Alert.Description) Error!void {
            const alert_payload = [_]u8{ @intFromEnum(tls.Alert.Level.fatal), @intFromEnum(description) };
            var hdr: [5]u8 = undefined;
            record_mod.writeHeader(&hdr, @intFromEnum(tls.ContentType.alert), alert_payload.len);
            self.out_buf.appendSlice(self.allocator, &hdr) catch return error.OutOfMemory;
            self.out_buf.appendSlice(self.allocator, &alert_payload) catch return error.OutOfMemory;
        }

        fn emitCleartextRecord(self: *Self, content_type: u8, payload: []const u8) Error!void {
            var hdr: [5]u8 = undefined;
            record_mod.writeHeader(&hdr, content_type, @intCast(payload.len));
            self.out_buf.appendSlice(self.allocator, &hdr) catch return error.OutOfMemory;
            self.out_buf.appendSlice(self.allocator, payload) catch return error.OutOfMemory;
        }

        fn hashMessage(self: *Self, message: []const u8) void {
            self.key_transcript.update(message);
            self.full_transcript.update(message);
            self.sig_transcript.update(message);
        }

        /// Hash a message into the full/signature transcripts only (used for
        /// ClientHello1 and the HRR, which the key schedule must not see).
        fn hashMessageFullOnly(self: *Self, message: []const u8) void {
            self.full_transcript.update(message);
            self.sig_transcript.update(message);
        }

        /// Encrypt a handshake message into one or more records. The caller
        /// hashes the message first (the transcript covers messages, not
        /// records; the Finished must be hashed after its verify data is
        /// computed).
        fn emitEncryptedHandshake(self: *Self, message: []const u8) Error!void {
            var offset: usize = 0;
            while (offset < message.len) {
                const chunk = @min(message.len - offset, max_plaintext);
                // Inner content-type byte included (RFC 8446 §5.2).
                var rec: [max_plaintext + 1 + 5 + 16]u8 = undefined;
                const n = record_mod.encrypt(A, self.secrets.server_handshake_key, self.secrets.server_handshake_iv, self.write_seq, @intFromEnum(tls.ContentType.handshake), message[offset .. offset + chunk], &rec) catch
                    return error.TlsRecordOverflow;
                self.write_seq += 1;
                self.out_buf.appendSlice(self.allocator, rec[0..n]) catch return error.OutOfMemory;
                offset += chunk;
            }
        }

        fn processInput(self: *Self) Error!void {
            var pos: usize = 0;
            while (true) {
                if (self.in_buf.items.len - pos < 5) break;
                const hdr = self.in_buf.items[pos..][0..5];
                const content_type: u8 = hdr[0];
                const rec_len: usize = std.mem.readInt(u16, hdr[3..5], .big);
                if (rec_len > tls.max_ciphertext_len) return self.fail(error.TlsRecordOverflow, .record_overflow);
                if (self.in_buf.items.len - pos < 5 + rec_len) break;

                switch (content_type) {
                    @intFromEnum(tls.ContentType.change_cipher_spec) => {
                        // RFC 8446 §5: CCS must be ignored.
                    },
                    @intFromEnum(tls.ContentType.alert) => {
                        const payload = self.in_buf.items[pos + 5 .. pos + 5 + rec_len];
                        if (rec_len < 2) return self.fail(error.TlsDecodeError, .decode_error);
                        self.last_alert = payload[1];
                        if (payload[0] == @intFromEnum(tls.Alert.Level.warning) and
                            payload[1] == @intFromEnum(tls.Alert.Description.close_notify))
                        {
                            self.stage = .closed;
                        } else {
                            return error.TlsAlert;
                        }
                    },
                    @intFromEnum(tls.ContentType.handshake) => {
                        if (self.encrypted_read) return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
                        const payload = self.in_buf.items[pos + 5 .. pos + 5 + rec_len];
                        self.handshake_buf.appendSlice(self.allocator, payload) catch return error.OutOfMemory;
                        try self.processHandshakeBuffer();
                    },
                    @intFromEnum(tls.ContentType.application_data) => {
                        if (!self.encrypted_read) return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
                        try self.processEncryptedRecord(pos);
                    },
                    else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
                }

                pos += 5 + rec_len;
            }
            // One shift per batch instead of per record: the processed prefix
            // is discarded and the partial tail stays for the next feed.
            if (pos > 0) {
                std.mem.copyForwards(u8, self.in_buf.items, self.in_buf.items[pos..]);
                self.in_buf.items.len -= pos;
            }
        }

        /// Decrypt the current record in place (its body in `in_buf` becomes
        /// the plaintext) and dispatch by stage.
        fn processEncryptedRecord(self: *Self, pos: usize) Error!void {
            const rec_len: usize = std.mem.readInt(u16, self.in_buf.items[pos + 3 ..][0..2], .big);
            const record = self.in_buf.items[pos .. pos + 5 + rec_len];
            const key, const iv = switch (self.stage) {
                .waiting_finished => .{ self.secrets.client_handshake_key, self.secrets.client_handshake_iv },
                .application => .{ self.secrets.client_application_key, self.secrets.client_application_iv },
                else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
            };
            const got = record_mod.decryptInPlace(A, key, iv, self.read_seq, record) catch |e| switch (e) {
                error.TlsBadRecordMac => return self.fail(error.TlsBadRecordMac, .bad_record_mac),
                error.TlsRecordOverflow => return self.fail(error.TlsRecordOverflow, .record_overflow),
                error.TlsConnectionTruncated => return self.fail(error.TlsConnectionTruncated, .record_overflow),
            };
            self.read_seq += 1;
            switch (self.stage) {
                .waiting_finished => {
                    if (got.content_type != @intFromEnum(tls.ContentType.handshake))
                        return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
                    self.handshake_buf.appendSlice(self.allocator, got.plaintext) catch return error.OutOfMemory;
                    try self.processHandshakeBuffer();
                },
                .application => {
                    switch (got.content_type) {
                        @intFromEnum(tls.ContentType.application_data) => {
                            self.plaintext_out.appendSlice(self.allocator, got.plaintext) catch return error.OutOfMemory;
                        },
                        @intFromEnum(tls.ContentType.alert) => {
                            // close_notify (the only alert expected in the
                            // application phase).
                            if (got.plaintext.len >= 2 and
                                got.plaintext[0] == @intFromEnum(tls.Alert.Level.warning) and
                                got.plaintext[1] == @intFromEnum(tls.Alert.Description.close_notify))
                            {
                                self.stage = .closed;
                            } else {
                                return error.TlsAlert;
                            }
                        },
                        else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
                    }
                },
                else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
            }
        }

        /// Assemble and dispatch complete handshake messages from the buffer.
        fn processHandshakeBuffer(self: *Self) Error!void {
            while (self.handshake_buf.items.len >= 4) {
                const msg_len: usize = std.mem.readInt(u24, self.handshake_buf.items[1..4], .big);
                if (4 + msg_len > self.handshake_buf.items.len) return;
                const message = self.handshake_buf.items[0 .. 4 + msg_len];
                switch (self.handshake_buf.items[0]) {
                    0x01 => try self.onClientHello(message),
                    0x0b => try self.onClientCertificate(message),
                    0x0f => try self.onClientCertificateVerify(message),
                    0x14 => try self.onClientFinished(message),
                    else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
                }
                std.mem.copyForwards(u8, self.handshake_buf.items, self.handshake_buf.items[4 + msg_len ..]);
                self.handshake_buf.items.len -= 4 + msg_len;
            }
        }

        fn onClientHello(self: *Self, message: []const u8) Error!void {
            switch (self.stage) {
                .waiting_hello, .sent_hrr => {},
                else => return self.fail(error.TlsUnexpectedMessage, .unexpected_message),
            }
            const hello = handshake_mod.parseClientHello(message[4..]) catch |e| switch (e) {
                error.TlsIllegalParameter => return self.fail(error.TlsIllegalParameter, .illegal_parameter),
                error.TlsDecodeError => return self.fail(error.TlsDecodeError, .decode_error),
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(error.TlsIllegalParameter, .illegal_parameter),
            };
            if (!hello.has_supported_versions_13)
                return self.fail(error.TlsIllegalParameter, .protocol_version);
            const suite = handshake_mod.selectCipherSuite(hello.cipher_suites) orelse
                return self.fail(error.UnsupportedCipherSuite, .handshake_failure);
            self.cipher_suite = suite;
            if (self.sid_len == 0) {
                self.sid_len = @min(hello.legacy_session_id.len, 32);
                @memcpy(self.legacy_session_id[0..self.sid_len], hello.legacy_session_id[0..self.sid_len]);
            }

            const share = handshake_mod.selectKeyShare(&hello) orelse {
                // No x25519 share: HelloRetryRequest, then the client resends
                // with an x25519 share (RFC 8446 §4.1.3). ClientHello1 and
                // the HRR stay in the full/signature transcripts (they cover
                // the Finished); the key schedule is reset at ClientHello2.
                if (self.stage == .sent_hrr) return self.fail(error.NoUsableKeyShare, .handshake_failure);
                self.hashMessageFullOnly(message);
                var sh: [256]u8 = undefined;
                const n = handshake_mod.buildServerHello(&sh, tls.hello_retry_request_sequence, hello.legacy_session_id, suite, true, null, null) catch
                    return error.OutOfMemory;
                self.hashMessageFullOnly(sh[0..n]);
                try self.emitCleartextRecord(@intFromEnum(tls.ContentType.handshake), sh[0..n]);
                self.key_transcript = .init(.{});
                self.stage = .sent_hrr;
                return;
            };
            if (share.len != 32) return self.fail(error.TlsIllegalParameter, .illegal_parameter);

            // ECDHE with the client's x25519 share.
            const ecdhe = X25519.scalarmult(self.x25519_secret, share[0..32].*) catch
                return self.fail(error.TlsIllegalParameter, .illegal_parameter);

            // ALPN is negotiated on the (final) ClientHello.
            if (self.stage == .waiting_hello) {
                self.alpn = handshake_mod.selectAlpn(hello.alpn) orelse "";
            }
            self.status_requested = hello.status_requested;

            // PSK resumption: open the ticket, require psk_dhe_ke
            // mode, and verify the binder over the truncated ClientHello.
            var resumed_psk: ?[]const u8 = null;
            if (hello.psk_identity.len > 0) {
                // PSK resumption: the first ClientHello carries a
                // session ticket. Require psk_dhe_ke mode, open the ticket,
                // derive the PSK from the resumption master secret and the
                // ticket nonce, then verify the binder over the truncated
                // ClientHello (RFC 8446 §4.2.11.2, §7.2).
                if (self.stage != .waiting_hello)
                    return self.fail(error.TlsIllegalParameter, .illegal_parameter);
                var modes_ok = false;
                for (hello.psk_modes) |m| {
                    if (m == 0x01) modes_ok = true; // psk_dhe_ke
                }
                if (!modes_ok) return self.fail(error.TlsIllegalParameter, .illegal_parameter);
                var secret: [64]u8 = undefined;
                const n = tickets_mod.open(hello.psk_identity, &secret) orelse
                    return self.fail(error.TlsIllegalParameter, .illegal_parameter);
                const empty_hash = tls.emptyHash(RecordHash);
                const nonce_byte = [1]u8{0};
                var psk_bytes: [RecordHash.digest_length]u8 = undefined;
                var secret_arr: [RecordHash.digest_length]u8 = undefined;
                @memcpy(&secret_arr, secret[0..n]);
                const psk_full = tls.hkdfExpandLabel(Suite.Hkdf, secret_arr, "resumption", nonce_byte[0..], RecordHash.digest_length);
                @memcpy(&psk_bytes, &psk_full);
                const early = Suite.Hkdf.extract(&[1]u8{0}, &psk_bytes);
                const binder_key = tls.hkdfExpandLabel(Suite.Hkdf, early, "res binder", &empty_hash, Suite.finished_key_length);
                // The PskBinderEntry is computed like a Finished message: the
                // binder key is expanded with the "finished" label first
                // (RFC 8446 §4.2.11.2, matching openssl's tls_psk_do_binder).
                const finished_key = tls.hkdfExpandLabel(Suite.Hkdf, binder_key, "finished", "", Suite.finished_key_length);
                var truncated: [16 * 1024]u8 = undefined;
                const tlen = handshake_mod.truncatedClientHello(message, &hello, &truncated);
                if (tlen == 0) return self.fail(error.TlsDecodeError, .decode_error);
                var trunc_hash: [RecordHash.digest_length]u8 = undefined;
                RecordHash.hash(truncated[0..tlen], &trunc_hash, .{});
                const expected = Secrets.verifyData(finished_key, trunc_hash);
                if (hello.psk_binder.len != expected.len or !std.mem.eql(u8, hello.psk_binder, &expected))
                    return self.fail(error.TlsIllegalParameter, .illegal_parameter);
                @memcpy(self.psk[0..psk_bytes.len], &psk_bytes);
                self.psk_len = psk_bytes.len;
                resumed_psk = self.psk[0..psk_bytes.len];
            }

            // The key-schedule transcript is fresh (no HRR) or was reset:
            // hash this ClientHello into it, then the ServerHello — the
            // handshake traffic secrets derive from the transcript hash
            // through the ServerHello (RFC 8446 §7.1; the std client and
            // openssl both do this).
            self.hashMessage(message);
            var sh: [512]u8 = undefined;
            // RFC 8446 §4.2.8.1: when the PSK is accepted, the ServerHello
            // must carry the pre_shared_key extension selecting the identity.
            const psk_selected: ?u16 = if (resumed_psk != null) 0 else null;
            const n = handshake_mod.buildServerHello(&sh, self.our_random, self.legacy_session_id[0..self.sid_len], suite, false, &self.x25519_public, psk_selected) catch
                return error.OutOfMemory;
            self.hashMessage(sh[0..n]);
            const hello_hash = self.key_transcript.peek();
            self.secrets.deriveHandshake(&ecdhe, hello_hash, resumed_psk);

            // ServerHello (cleartext), then a change_cipher_spec record
            // (middlebox compatibility, RFC 8446 §5 — the std client and
            // openssl both switch to encrypted reading on it), then the
            // encrypted flight.
            try self.emitCleartextRecord(@intFromEnum(tls.ContentType.handshake), sh[0..n]);
            try self.emitCleartextRecord(@intFromEnum(tls.ContentType.change_cipher_spec), &.{0x01});
            self.encrypted_read = true;
            self.stage = .encrypted_flight;
            try self.sendFlight(resumed_psk != null);
        }

        /// EncryptedExtensions, (Certificate, CertificateVerify — omitted on
        /// PSK resumption), Finished.
        fn sendFlight(self: *Self, resumed: bool) Error!void {
            var msg: [16 * 1024]u8 = undefined;

            const n_ee = handshake_mod.buildEncryptedExtensions(&msg, if (self.alpn.len > 0) self.alpn else null) catch
                return error.OutOfMemory;
            self.hashMessage(msg[0..n_ee]);
            try self.emitEncryptedHandshake(msg[0..n_ee]);

            // mTLS: ask for a client certificate (fresh handshakes only;
            // resumption authenticates via the ticket-bound PSK instead).
            if (!resumed and self.creds.verify_client) {
                const n_cr = handshake_mod.buildCertificateRequest(&msg) catch
                    return error.OutOfMemory;
                self.hashMessage(msg[0..n_cr]);
                try self.emitEncryptedHandshake(msg[0..n_cr]);
            }

            if (!resumed) {
                // OCSP stapling (C3): the client asked via status_request
                // and startup loaded a validated response — staple it in
                // the CertificateEntry. Anything else sends the
                // byte-identical unstapled flight.
                const staple: []const u8 = if (self.status_requested and self.creds.ocsp_der.len > 0)
                    self.creds.ocsp_der
                else
                    &.{};
                const n_cert = handshake_mod.buildCertificate(&msg, self.creds.cert_der, staple) catch
                    return error.OutOfMemory;
                self.hashMessage(msg[0..n_cert]);
                try self.emitEncryptedHandshake(msg[0..n_cert]);

                // CertificateVerify: ECDSA over the signature transcript (up to
                // and including Certificate).
                // RFC 8446 §4.4.3: the signature is over the transcript hash
                // prefixed with the signature context string.
                const sig_transcript_hash = self.sig_transcript.peek();
                const sig_msg_len = 64 + "TLS 1.3, server CertificateVerify".len + 1 + SigHash.digest_length;
                var sig_msg: [64 + "TLS 1.3, server CertificateVerify".len + 1 + 64]u8 = undefined;
                @memset(sig_msg[0..64], ' ');
                @memcpy(sig_msg[64 .. 64 + "TLS 1.3, server CertificateVerify".len], "TLS 1.3, server CertificateVerify");
                sig_msg[64 + "TLS 1.3, server CertificateVerify".len] = 0;
                @memcpy(sig_msg[64 + "TLS 1.3, server CertificateVerify".len + 1 ..][0..SigHash.digest_length], &sig_transcript_hash);
                var sig_digest: [SigHash.digest_length]u8 = undefined;
                SigHash.hash(sig_msg[0..sig_msg_len], &sig_digest, .{});
                var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
                const sig_len = self.signEcdsa(&sig_buf, &sig_digest) catch
                    return self.fail(error.TlsIllegalParameter, .internal_error);
                // Self-check: the signature must verify against the public key
                // derived from the certificate's secret (catches key/cert
                // mismatches and transcript bugs before the client does).
                {
                    const sk = Ecdsa.SecretKey.fromBytes(self.creds.key.secret_key[0..Ecdsa.SecretKey.encoded_length].*) catch unreachable;
                    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch unreachable;
                    const sig2 = Ecdsa.Signature.fromDer(sig_buf[0..sig_len]) catch unreachable;
                    sig2.verifyPrehashed(sig_digest, kp.public_key) catch {
                        return self.fail(error.TlsIllegalParameter, .internal_error);
                    };
                }
                const n_cv = handshake_mod.buildCertificateVerify(&msg, signature_scheme, sig_buf[0..sig_len]) catch
                    return error.OutOfMemory;
                self.hashMessage(msg[0..n_cv]);
                try self.emitEncryptedHandshake(msg[0..n_cv]);
            }

            // Finished: HMAC over the full transcript (up to and including
            // CertificateVerify, excluding the Finished itself).
            const finished_digest = self.full_transcript.peek();
            const verify_data = Secrets.verifyData(self.secrets.server_finished_key, finished_digest);
            const n_f = handshake_mod.buildFinished(&msg, &verify_data) catch
                return error.OutOfMemory;
            self.hashMessage(msg[0..n_f]);
            try self.emitEncryptedHandshake(msg[0..n_f]);

            // Application traffic secrets derive from the transcript up to
            // (and including) the server Finished — the client's Finished is
            // NOT part of it, so derive now, before the client's Finished is
            // hashed.
            const app_hash = self.full_transcript.peek();
            self.secrets.deriveApplication(app_hash);
            self.stage = .waiting_finished;
        }

        /// NewSessionTicket (RFC 8446 §4.6.1): a post-handshake handshake
        /// message encrypted with the application traffic keys (write_seq 0
        /// is the first application record). The ticket carries the
        /// resumption master secret (RFC 8446 §7.2), derived from the master
        /// secret and the transcript through the client's Finished; the
        /// resuming client derives the PSK from it with the ticket nonce.
        fn issueTicket(self: *Self) Error!void {
            const transcript = self.full_transcript.peek();
            var resumption_master: [RecordHash.digest_length]u8 = undefined;
            var ms_arr: [RecordHash.digest_length]u8 = undefined;
            @memcpy(&ms_arr, &self.secrets.master_secret);
            const rms = tls.hkdfExpandLabel(Suite.Hkdf, ms_arr, "res master", transcript[0..], RecordHash.digest_length);
            @memcpy(&resumption_master, &rms);
            var msg: [tickets_mod.max_ticket_len + 32]u8 = undefined;
            const n = tickets_mod.buildNewSessionTicket(&msg, &resumption_master, self.ticket_nonce) catch
                return error.OutOfMemory;
            self.ticket_nonce +%= 1;
            var rec: [16 * 1024 + 5 + 16]u8 = undefined;
            const m = record_mod.encrypt(A, self.secrets.server_application_key, self.secrets.server_application_iv, self.write_seq, @intFromEnum(tls.ContentType.handshake), msg[0..n], &rec) catch
                return error.TlsRecordOverflow;
            self.write_seq += 1;
            self.out_buf.appendSlice(self.allocator, rec[0..m]) catch return error.OutOfMemory;
        }

        /// Client Certificate (mTLS): chain-verify the leaf against the
        /// startup client-CA bundle and retain it for the CertificateVerify
        /// step. Only valid in waiting_finished when we asked (verify_client
        /// and not resumed); anything else is fail-closed.
        fn onClientCertificate(self: *Self, message: []const u8) Error!void {
            if (self.stage != .waiting_finished or !self.creds.verify_client)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
            if (self.client_cert_seen)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
            self.hashMessage(message);
            const bundle = self.creds.client_ca orelse
                return self.fail(error.TlsIllegalParameter, .internal_error);
            var certs: [8][]const u8 = undefined;
            const n = mtls_mod.parseClientCertificate(message[4..], &certs) catch
                return self.fail(error.TlsDecodeError, .decode_error);
            const now = compat.clock_gettime(std.posix.CLOCK.REALTIME) catch
                return self.fail(error.TlsIllegalParameter, .internal_error);
            mtls_mod.verifyChain(bundle, certs[0], certs[1..n], now.sec) catch
                return self.fail(error.TlsDecodeError, .unknown_ca);
            self.client_leaf = self.allocator.dupe(u8, certs[0]) catch return error.OutOfMemory;
            self.client_cert_seen = true;
        }

        /// Client CertificateVerify (mTLS): the signature must cover the
        /// transcript through the client Certificate under our scheme.
        fn onClientCertificateVerify(self: *Self, message: []const u8) Error!void {
            if (self.stage != .waiting_finished or !self.creds.verify_client or !self.client_cert_seen)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
            if (self.client_cert_ok)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
            const cv = mtls_mod.parseCertificateVerify(message[4..]) catch
                return self.fail(error.TlsDecodeError, .decode_error);
            if (cv.scheme != signature_scheme)
                return self.fail(error.TlsIllegalParameter, .illegal_parameter);
            const digest = self.sig_transcript.peek();
            mtls_mod.verifySignature(Ecdsa, self.client_leaf, &digest, cv.sig) catch
                return self.fail(error.TlsDecodeError, .bad_certificate);
            self.hashMessage(message);
            self.client_cert_ok = true;
        }

        fn onClientFinished(self: *Self, message: []const u8) Error!void {
            if (self.stage != .waiting_finished)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
            // mTLS: no verified client signature, no application data.
            // Resumed (PSK) sessions skip client auth by design.
            if (self.creds.verify_client and self.psk_len == 0 and !self.client_cert_ok)
                return self.fail(error.TlsUnexpectedMessage, .certificate_required);
            // The client's Finished verify_data covers the transcript up to
            // (and including) the server's Finished — NOT the client's own
            // Finished (RFC 8446 §4.4.4). Compute the expected value first,
            // then hash the message into the transcript.
            const finished_digest = self.full_transcript.peek();
            const expected = Secrets.verifyData(self.secrets.client_finished_key, finished_digest);
            if (message.len != 4 + expected.len or !std.mem.eql(u8, message[4..], &expected))
                return self.fail(error.TlsDecodeError, .decrypt_error);
            self.hashMessage(message);
            // RFC 8446 §5.3: the record sequence numbers reset to zero at
            // each key change (the std client resets both counters when the
            // application keys take over).
            self.read_seq = 0;
            self.write_seq = 0;
            self.stage = .application;
            // Issue a NewSessionTicket (post-handshake, encrypted with the
            // application keys) so future connections can resume.
            try self.issueTicket();
        }

        /// ECDSA (DER) signature of `digest` with the certificate key.
        fn signEcdsa(self: *Self, buf: []u8, digest: []const u8) Error!usize {
            // The key length is comptime per curve (32 for P-256, 48 for
            // P-384); cert.zig guarantees it matches the secret length.
            const sk = Ecdsa.SecretKey.fromBytes(self.creds.key.secret_key[0..Ecdsa.SecretKey.encoded_length].*) catch
                return error.TlsIllegalParameter;
            const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch
                return error.TlsIllegalParameter;
            var digest_arr: [SigHash.digest_length]u8 = undefined;
            @memcpy(&digest_arr, digest);
            const sig = kp.signPrehashed(digest_arr, null) catch
                return error.TlsIllegalParameter;
            var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
            const der = sig.toDer(&der_buf);
            @memcpy(buf[0..der.len], der);
            return der.len;
        }
    };
}

/// Instantiate the right concrete session for a cipher suite and certificate
/// curve. Four common combinations are supported; the union dispatches to
/// the exact comptime types.
pub const AnySession = union(enum) {
    aes128_p256: Session(std.crypto.aead.aes_gcm.Aes128Gcm, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha256, std.crypto.sign.ecdsa.EcdsaP256Sha256, 0x0403),
    chacha_p256: Session(std.crypto.aead.chacha_poly.ChaCha20Poly1305, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha256, std.crypto.sign.ecdsa.EcdsaP256Sha256, 0x0403),
    aes256_p256: Session(std.crypto.aead.aes_gcm.Aes256Gcm, std.crypto.hash.sha2.Sha384, std.crypto.hash.sha2.Sha256, std.crypto.sign.ecdsa.EcdsaP256Sha256, 0x0403),
    aes128_p384: Session(std.crypto.aead.aes_gcm.Aes128Gcm, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha384, std.crypto.sign.ecdsa.EcdsaP384Sha384, 0x0503),
    aes256_p384: Session(std.crypto.aead.aes_gcm.Aes256Gcm, std.crypto.hash.sha2.Sha384, std.crypto.hash.sha2.Sha384, std.crypto.sign.ecdsa.EcdsaP384Sha384, 0x0503),
    chacha_p384: Session(std.crypto.aead.chacha_poly.ChaCha20Poly1305, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha384, std.crypto.sign.ecdsa.EcdsaP384Sha384, 0x0503),
};

const testing = std.testing;
const testdata = @import("testdata.zig");
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const TestSession = Session(Aes128Gcm, Sha256, Sha256, EcdsaP256, 0x0403);

// Definitive interop test: the std TLS 1.3 client performs a full
// handshake against our server session over a socketpair, then both sides
// exchange application data encrypted in both directions. Any mismatch in
// the key schedule, transcript, records or signatures fails here.
test "TLS 1.3 handshake and round trip against the std client" {
    const allocator = std.heap.page_allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);

    const pair = try compat.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer compat.close(pair[1]);

    var server_err: ?Error = null;
    var stop = std.atomic.Value(bool).init(false);

    const ServerThread = struct {
        fn run(fd: std.posix.fd_t, c: *const cert_mod.Credentials, err_out: *?Error, stop_flag: *std.atomic.Value(bool)) void {
            var session = TestSession.init(allocator, c);
            defer session.deinit();
            var buf: [16 * 1024]u8 = undefined;
            var out: [16 * 1024]u8 = undefined;
            while (!stop_flag.load(.acquire)) {
                const n = std.posix.read(fd, &buf) catch |e| switch (e) {
                    error.WouldBlock => {
                        compat.nanosleep(0, 1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => break,
                };
                if (n == 0) break;
                session.feed(buf[0..n]) catch |e| {
                    err_out.* = e;
                    return;
                };
                // Reply to the client's close_notify with our own, then exit.
                if (session.currentStage() == .closed) {
                    session.shutdown() catch {};
                    const m0 = session.takeOut(&out);
                    if (m0 > 0) writeAll(fd, out[0..m0]) catch return;
                    return;
                }
                const m = session.takeOut(&out);
                if (m > 0) writeAll(fd, out[0..m]) catch return;
                // Echo any application plaintext back to the client.
                if (session.currentStage() == .application) {
                    const p = session.takePlaintext(&buf);
                    if (p > 0) {
                        session.write(buf[0..p]) catch |e| {
                            err_out.* = e;
                            return;
                        };
                        const m2 = session.takeOut(&out);
                        if (m2 > 0) writeAll(fd, out[0..m2]) catch return;
                    }
                }
            }
        }

        fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
            var remaining = bytes;
            while (remaining.len > 0) {
                const n = compat.write(fd, remaining) catch |e| switch (e) {
                    error.WouldBlock => {
                        compat.nanosleep(0, 1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e,
                };
                remaining = remaining[n..];
            }
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ pair[0], &creds, &server_err, &stop });
    defer stop.store(true, .release);

    // ---- std TLS 1.3 client ----
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stream = std.Io.net.Stream{ .socket = .{ .handle = pair[1], .address = undefined } };
    var client_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var client_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &client_read_buf);
    var writer = stream.writer(io, &client_write_buf);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    compat.randomBytes(&entropy);
    var client = std.crypto.tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = 0 },
    }) catch |e| {
        stop.store(true, .release);
        server_thread.join();
        if (server_err) |se| std.debug.print("server error: {s}\n", .{@errorName(se)});
        return e;
    };

    // Round trip: client -> server -> client.
    try client.writer.writeAll("hello tls 1.3!");
    try client.writer.flush();
    // The std client's flush only advances the socket writer's buffer; the
    // socket writer must be flushed too (std.http does both).
    try writer.interface.flush();
    var resp: [64]u8 = undefined;
    const msg = "hello tls 1.3!";
    try client.reader.readSliceAll(resp[0..msg.len]);
    try testing.expectEqualStrings(msg, resp[0..msg.len]);

    // Graceful shutdown: close_notify both ways. (end() also only advances
    // the socket writer's buffer — flush it.)
    try client.end();
    try writer.interface.flush();
    compat.nanosleep(0, 20 * std.time.ns_per_ms);
    stop.store(true, .release);
    compat.close(pair[0]);
    server_thread.join();
    try testing.expect(server_err == null);
}

/// Test-only record/message framing: cleartext TLS records carrying one
/// handshake message.
fn testRecord(content_type: u8, payload: []const u8, out: []u8) []u8 {
    out[0] = content_type;
    out[1] = 0x03;
    out[2] = 0x03;
    std.mem.writeInt(u16, out[3..5], @intCast(payload.len), .big);
    @memcpy(out[5..][0..payload.len], payload);
    return out[0 .. 5 + payload.len];
}

fn testHsMsg(msg_type: u8, body: []const u8, out: []u8) []u8 {
    out[0] = msg_type;
    std.mem.writeInt(u24, out[1..4], @intCast(body.len), .big);
    @memcpy(out[4..][0..body.len], body);
    return out[0 .. 4 + body.len];
}

/// Minimal TLS 1.3 ClientHello body advertising 0x1301 with supported_versions
/// and supported_groups but NO key share (drives the HelloRetryRequest path).
fn testHrrHelloBody(out: []u8) []u8 {
    var pos: usize = 0;
    out[pos] = 0x03;
    out[pos + 1] = 0x03;
    pos += 2;
    @memset(out[pos..][0..32], 0xAB);
    pos += 32;
    out[pos] = 0; // session id
    pos += 1;
    out[pos] = 0;
    out[pos + 1] = 2; // one suite
    out[pos + 2] = 0x13;
    out[pos + 3] = 0x01;
    pos += 4;
    out[pos] = 1;
    out[pos + 1] = 0; // compression
    pos += 2;
    const ext_at = pos;
    pos += 2;
    // supported_versions: TLS 1.3.
    out[pos] = 0x00;
    out[pos + 1] = 0x2b;
    out[pos + 2] = 0x00;
    out[pos + 3] = 0x03;
    out[pos + 4] = 0x02;
    out[pos + 5] = 0x03;
    out[pos + 6] = 0x04;
    pos += 7;
    // supported_groups: x25519.
    out[pos] = 0x00;
    out[pos + 1] = 0x0a;
    out[pos + 2] = 0x00;
    out[pos + 3] = 0x04;
    out[pos + 4] = 0x00;
    out[pos + 5] = 0x02;
    out[pos + 6] = 0x00;
    out[pos + 7] = 0x1d;
    pos += 8;
    std.mem.writeInt(u16, out[ext_at..][0..2], @intCast(pos - ext_at - 2), .big);
    return out[0..pos];
}

test "session: missing key share triggers HelloRetryRequest, twice fails" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    var body_buf: [256]u8 = undefined;
    const body = testHrrHelloBody(&body_buf);
    var msg_buf: [320]u8 = undefined;
    const msg = testHsMsg(0x01, body, &msg_buf);
    var rec_buf: [340]u8 = undefined;
    const rec = testRecord(@intFromEnum(tls.ContentType.handshake), msg, &rec_buf);
    // Split delivery: a partial record waits without error.
    try sess.feed(rec[0..3]);
    try testing.expectEqual(Stage.waiting_hello, sess.currentStage());
    try sess.feed(rec[3..]);
    try testing.expectEqual(Stage.sent_hrr, sess.currentStage());
    // The HRR ServerHello is cleartext handshake.
    try testing.expect(sess.takeOutSlice().len > 0);
    try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.handshake)), sess.takeOutSlice()[0]);
    // A second ClientHello still without a share is fatal.
    try testing.expectError(error.NoUsableKeyShare, sess.feed(rec));
    try testing.expect(sess.alert() != null);
}

test "session: legacy ClientHello version is rejected" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    // TLS 1.1 legacy_version with an otherwise minimal body.
    var body: [41]u8 = undefined;
    body[0] = 0x03;
    body[1] = 0x02;
    @memset(body[2..34], 0);
    body[34] = 0;
    body[35] = 0;
    body[36] = 2;
    body[37] = 0x13;
    body[38] = 0x01;
    body[39] = 1;
    body[40] = 0;
    var msg_buf: [64]u8 = undefined;
    const msg = testHsMsg(0x01, &body, &msg_buf);
    var rec_buf: [80]u8 = undefined;
    try testing.expectError(error.TlsIllegalParameter, sess.feed(testRecord(@intFromEnum(tls.ContentType.handshake), msg, &rec_buf)));
    try testing.expect(sess.alert() != null);
}

test "session: unknown record types and premature app data fail" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    var rec_buf: [16]u8 = undefined;
    try testing.expectError(error.TlsUnexpectedMessage, sess.feed(testRecord(0x99, &.{}, &rec_buf)));
    try testing.expect(sess.alert() != null);
    var sess2 = TestSession.init(testing.allocator, &creds);
    defer sess2.deinit();
    try testing.expectError(error.TlsUnexpectedMessage, sess2.feed(testRecord(@intFromEnum(tls.ContentType.application_data), &.{}, &rec_buf)));
    // Oversized record lengths are rejected once the record is buffered.
    // (Fresh session: a failed feed leaves its bytes buffered for retry.)
    var sess3 = TestSession.init(testing.allocator, &creds);
    defer sess3.deinit();
    const big_len: usize = tls.max_ciphertext_len + 1;
    const big_rec = try testing.allocator.alloc(u8, 5 + big_len);
    defer testing.allocator.free(big_rec);
    @memset(big_rec, 0);
    big_rec[0] = @intFromEnum(tls.ContentType.handshake);
    big_rec[1] = 0x03;
    big_rec[2] = 0x03;
    std.mem.writeInt(u16, big_rec[3..5], @intCast(big_len), .big);
    try testing.expectError(error.TlsRecordOverflow, sess3.feed(big_rec));
}

test "session: change_cipher_spec is ignored, alerts drive the stage" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    var rec_buf: [16]u8 = undefined;
    // CCS: no error, no output, stage unchanged.
    try sess.feed(testRecord(@intFromEnum(tls.ContentType.change_cipher_spec), &.{0x01}, &rec_buf));
    try testing.expectEqual(Stage.waiting_hello, sess.currentStage());
    try testing.expectEqual(@as(usize, 0), sess.takeOutSlice().len);
    // Truncated alert record.
    try testing.expectError(error.TlsDecodeError, sess.feed(testRecord(@intFromEnum(tls.ContentType.alert), &.{0x01}, &rec_buf)));
    // Fatal alert from the peer surfaces as TlsAlert.
    var sess2 = TestSession.init(testing.allocator, &creds);
    defer sess2.deinit();
    try testing.expectError(error.TlsAlert, sess2.feed(testRecord(@intFromEnum(tls.ContentType.alert), &.{ 0x02, 0x0a }, &rec_buf)));
    // Warning close_notify moves a fresh session to closed, quietly.
    var sess3 = TestSession.init(testing.allocator, &creds);
    defer sess3.deinit();
    try sess3.feed(testRecord(@intFromEnum(tls.ContentType.alert), &.{ 0x01, 0x00 }, &rec_buf));
    try testing.expectEqual(Stage.closed, sess3.currentStage());
}

test "session: unexpected handshake messages fail cleanly" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    var msg_buf: [32]u8 = undefined;
    var rec_buf: [48]u8 = undefined;
    // A ServerHello arriving before any ClientHello.
    const sh = testHsMsg(0x02, "hello", &msg_buf);
    try testing.expectError(error.TlsUnexpectedMessage, sess.feed(testRecord(@intFromEnum(tls.ContentType.handshake), sh, &rec_buf)));
    // A Finished arriving before the handshake ran.
    var sess2 = TestSession.init(testing.allocator, &creds);
    defer sess2.deinit();
    const fin = testHsMsg(0x14, &.{}, &msg_buf);
    try testing.expectError(error.TlsUnexpectedMessage, sess2.feed(testRecord(@intFromEnum(tls.ContentType.handshake), fin, &rec_buf)));
}

test "session: write/shutdown/take APIs before the handshake completes" {
    var creds = try cert_mod.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds.cert_der);
    var sess = TestSession.init(testing.allocator, &creds);
    defer sess.deinit();
    // Nothing buffered yet.
    var tmp: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), sess.takeOut(&tmp));
    try testing.expectEqual(@as(usize, 0), sess.takePlaintext(&tmp));
    try testing.expectEqual(@as(usize, 0), sess.plaintextSlice().len);
    sess.consumeOut(0);
    sess.consumePlaintext(0);
    try testing.expectEqualStrings("", sess.negotiatedAlpn());
    // Application data cannot be sent pre-handshake.
    try testing.expectError(error.TlsUnexpectedMessage, sess.write("hello"));
    // Shutdown queues a close_notify alert; twice is a no-op the second time.
    try sess.shutdown();
    try testing.expectEqual(Stage.closed, sess.currentStage());
    const drained = sess.takeOut(&tmp);
    try testing.expect(drained > 0);
    try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.alert)), tmp[0]);
    try sess.shutdown();
    try testing.expectEqual(@as(usize, 0), sess.takeOut(&tmp));
}

/// mTLS message-level tests: drive the client-auth handlers directly with
/// the real fixture chain (no network). The session is placed in
/// waiting_finished — the handlers only need the transcript hashes and the
/// startup bundle, never traffic keys.
fn mtlsTestCreds(allocator: std.mem.Allocator) !struct {
    creds: cert_mod.Credentials,
    bundle: std.crypto.Certificate.Bundle,
    leaf_der: []const u8,
} {
    const pem_mod = @import("pem.zig");
    const creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    errdefer allocator.free(creds.cert_der);
    var ca_buf: [4096]u8 = undefined;
    const ca_len = (try pem_mod.decodeFirst(testdata.client_ca_pem, "CERTIFICATE", &ca_buf)) orelse
        return error.TestUnexpected;
    var bundle = std.crypto.Certificate.Bundle.empty;
    errdefer bundle.deinit(allocator);
    const now_sec: i64 = 1_800_000_000;
    const start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(allocator, ca_buf[0..ca_len]);
    try bundle.parseCert(allocator, start, now_sec);
    var leaf_buf: [4096]u8 = undefined;
    const leaf_len = (try pem_mod.decodeFirst(testdata.client_cert_pem, "CERTIFICATE", &leaf_buf)) orelse
        return error.TestUnexpected;
    const leaf_der = try allocator.dupe(u8, leaf_buf[0..leaf_len]);
    errdefer allocator.free(leaf_der);
    return .{ .creds = creds, .bundle = bundle, .leaf_der = leaf_der };
}

test "mTLS handlers accept the fixture chain and signature" {
    const allocator = testing.allocator;
    var fx = try mtlsTestCreds(allocator);
    defer allocator.free(fx.creds.cert_der);
    defer fx.bundle.deinit(allocator);
    defer allocator.free(fx.leaf_der);
    var creds = fx.creds;
    creds.verify_client = true;
    creds.client_ca = &fx.bundle;

    var sess = TestSession.init(allocator, &creds);
    defer sess.deinit();
    sess.stage = .waiting_finished;

    // Client Certificate message: type + len + body(ctx 0, one leaf entry).
    var cert_msg: [8192]u8 = undefined;
    cert_msg[0] = 0x0b;
    const entry_len = 3 + fx.leaf_der.len + 2;
    const body_len = 1 + 3 + entry_len;
    std.mem.writeInt(u24, cert_msg[1..4], @intCast(body_len), .big);
    cert_msg[4] = 0x00; // context len
    std.mem.writeInt(u24, cert_msg[5..8], @intCast(entry_len), .big);
    std.mem.writeInt(u24, cert_msg[8..11], @intCast(fx.leaf_der.len), .big);
    @memcpy(cert_msg[11..][0..fx.leaf_der.len], fx.leaf_der);
    std.mem.writeInt(u16, cert_msg[11 + fx.leaf_der.len ..][0..2], 0, .big);
    try sess.onClientCertificate(cert_msg[0 .. 4 + body_len]);
    try testing.expect(sess.client_cert_seen);
    try testing.expect(!sess.client_cert_ok);

    // CertificateVerify over the transcript (now includes the Certificate).
    const digest = sess.sig_transcript.peek();
    const client_creds = try cert_mod.loadCredentials(allocator, testdata.client_cert_pem, testdata.client_key_pem);
    defer allocator.free(client_creds.cert_der);
    const sk = try EcdsaP256.SecretKey.fromBytes(client_creds.key.secret_key[0..EcdsaP256.SecretKey.encoded_length].*);
    const kp = try EcdsaP256.KeyPair.fromSecretKey(sk);
    const context = "TLS 1.3, client CertificateVerify";
    var content: [64 + context.len + 1 + 32]u8 = undefined;
    @memset(content[0..64], ' ');
    @memcpy(content[64 .. 64 + context.len], context);
    content[64 + context.len] = 0;
    @memcpy(content[64 + context.len + 1 ..], &digest);
    var h: [32]u8 = undefined;
    Sha256.hash(content[0..], &h, .{});
    const sig = try kp.signPrehashed(h, null);
    var sig_der: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const sig_slice = sig.toDer(&sig_der);
    var cv_msg: [512]u8 = undefined;
    cv_msg[0] = 0x0f;
    std.mem.writeInt(u24, cv_msg[1..4], @intCast(4 + sig_slice.len), .big);
    std.mem.writeInt(u16, cv_msg[4..6], 0x0403, .big);
    std.mem.writeInt(u16, cv_msg[6..8], @intCast(sig_slice.len), .big);
    @memcpy(cv_msg[8..][0..sig_slice.len], sig_slice);
    try sess.onClientCertificateVerify(cv_msg[0 .. 8 + sig_slice.len]);
    try testing.expect(sess.client_cert_ok);
}

test "mTLS handlers reject empty certs, stray verifies and bad signatures" {
    const allocator = testing.allocator;
    var fx = try mtlsTestCreds(allocator);
    defer allocator.free(fx.creds.cert_der);
    defer fx.bundle.deinit(allocator);
    defer allocator.free(fx.leaf_der);
    var creds = fx.creds;
    creds.verify_client = true;
    creds.client_ca = &fx.bundle;

    // Verify before Certificate: unexpected.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .waiting_finished;
        var cv: [8]u8 = .{ 0x0f, 0x00, 0x00, 0x04, 0x04, 0x03, 0x00, 0x00 };
        try testing.expectError(error.TlsUnexpectedMessage, sess.onClientCertificateVerify(&cv));
    }
    // Empty certificate list: certificate_required path (decode error ->
    // the Finished gate maps the missing cert to certificate_required).
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .waiting_finished;
        const empty_cert = [_]u8{ 0x0b, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00 };
        try testing.expectError(error.TlsDecodeError, sess.onClientCertificate(&empty_cert));
        try testing.expect(!sess.client_cert_ok);
    }
    // Stranger leaf (the server's own cert): unknown CA.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .waiting_finished;
        const leaf = fx.creds.cert_der;
        var msg: [4096]u8 = undefined;
        msg[0] = 0x0b;
        const entry_len = 3 + leaf.len + 2;
        std.mem.writeInt(u24, msg[1..4], @intCast(1 + 3 + entry_len), .big);
        msg[4] = 0x00;
        std.mem.writeInt(u24, msg[5..8], @intCast(entry_len), .big);
        std.mem.writeInt(u24, msg[8..11], @intCast(leaf.len), .big);
        @memcpy(msg[11..][0..leaf.len], leaf);
        std.mem.writeInt(u16, msg[11 + leaf.len ..][0..2], 0, .big);
        try testing.expectError(error.TlsDecodeError, sess.onClientCertificate(msg[0 .. 11 + leaf.len + 2]));
    }
}

/// The captured openssl ClientHello body (handshake.zig test vector),
/// wrapped as a handshake message + TLS record for session.feed.
fn mtlsHelloRecord(out: []u8) []u8 {
    const body = [_]u8{
        0x03, 0x03, 0xa4, 0xeb, 0x06, 0xdf, 0xbf, 0x46, 0xa1, 0xef, 0x72, 0x29,
        0xf2, 0x3e, 0x74, 0x96, 0x46, 0x78, 0x04, 0x64, 0x09, 0x93, 0x0c, 0xc8,
        0xf1, 0xbc, 0xe6, 0x46, 0xac, 0x44, 0x4b, 0xc3, 0x8b, 0xd5, 0x20, 0x51,
        0x4b, 0x50, 0x93, 0x4a, 0x05, 0x02, 0x5b, 0xb2, 0xce, 0x58, 0xe6, 0x89,
        0xfe, 0x8c, 0xd0, 0xd6, 0xac, 0x2d, 0xcc, 0x2f, 0x04, 0x51, 0xea, 0xa5,
        0x21, 0x40, 0x8d, 0x99, 0x84, 0x37, 0xa1, 0x00, 0x08, 0x13, 0x02, 0x13,
        0x03, 0x13, 0x01, 0x00, 0xff, 0x01, 0x00, 0x00, 0x99, 0x00, 0x0b, 0x00,
        0x04, 0x03, 0x00, 0x01, 0x02, 0x00, 0x0a, 0x00, 0x16, 0x00, 0x14, 0x00,
        0x1d, 0x00, 0x17, 0x00, 0x1e, 0x00, 0x19, 0x00, 0x18, 0x01, 0x00, 0x01,
        0x01, 0x01, 0x02, 0x01, 0x03, 0x01, 0x04, 0x00, 0x23, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x0e, 0x00, 0x0c, 0x02, 0x68, 0x32, 0x08, 0x68, 0x74, 0x74,
        0x70, 0x2f, 0x31, 0x2e, 0x31, 0x00, 0x16, 0x00, 0x00, 0x00, 0x17, 0x00,
        0x00, 0x00, 0x0d, 0x00, 0x1e, 0x00, 0x1c, 0x04, 0x03, 0x05, 0x03, 0x06,
        0x03, 0x08, 0x07, 0x08, 0x08, 0x08, 0x09, 0x08, 0x0a, 0x08, 0x0b, 0x08,
        0x04, 0x08, 0x05, 0x08, 0x06, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01, 0x00,
        0x2b, 0x00, 0x03, 0x02, 0x03, 0x04, 0x00, 0x2d, 0x00, 0x02, 0x01, 0x01,
        0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20, 0x37, 0xe4,
        0x6b, 0x62, 0xf7, 0x33, 0xa3, 0x0b, 0x67, 0x8f, 0x64, 0x78, 0x55, 0x92,
        0xda, 0xb4, 0x75, 0xc8, 0x3f, 0xb3, 0x6b, 0x02, 0xd2, 0x32, 0x55, 0xe2,
        0xfa, 0x9b, 0x7d, 0xe6, 0x00, 0x49,
    };
    var pos: usize = 0;
    out[pos] = 0x01; // ClientHello
    pos += 1;
    std.mem.writeInt(u24, out[pos..][0..3], body.len, .big);
    pos += 3;
    @memcpy(out[pos..][0..body.len], &body);
    pos += body.len;
    const msg_len = pos;
    // Prepend the record header by shifting (out must have 5 spare bytes).
    std.mem.copyBackwards(u8, out[5 .. 5 + msg_len], out[0..msg_len]);
    out[0] = 0x16;
    out[1] = 0x03;
    out[2] = 0x01;
    std.mem.writeInt(u16, out[3..5], @intCast(msg_len), .big);
    return out[0 .. 5 + msg_len];
}

test "mTLS verify flight carries CertificateRequest, plain flight does not" {
    const allocator = testing.allocator;
    var plain_creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(plain_creds.cert_der);
    var verify_creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(verify_creds.cert_der);
    verify_creds.verify_client = true;

    var hello_buf: [1024]u8 = undefined;
    const hello_rec = mtlsHelloRecord(&hello_buf);

    var plain = TestSession.init(allocator, &plain_creds);
    defer plain.deinit();
    try plain.feed(hello_rec);
    try testing.expectEqual(Stage.waiting_finished, plain.currentStage());

    var verify = TestSession.init(allocator, &verify_creds);
    defer verify.deinit();
    try verify.feed(hello_rec);
    try testing.expectEqual(Stage.waiting_finished, verify.currentStage());

    // Same hello in, identical messages out — except the 17-byte
    // CertificateRequest in one encrypted record (5 header + 17 + 16 tag).
    var plain_out: [32 * 1024]u8 = undefined;
    var verify_out: [32 * 1024]u8 = undefined;
    const pn = plain.takeOut(&plain_out);
    const vn = verify.takeOut(&verify_out);
    try testing.expect(pn > 0 and vn > pn);
    // One extra encrypted record: header(5) + CR message(17) + inner
    // content-type byte(1) + AEAD tag(16) = 39, plus the difference of
    // the two sessions' CertificateVerify DER lengths (ECDSA signatures
    // encode 68..72 bytes depending on leading-zero trims, so ±4).
    try testing.expect(vn > pn and vn - pn >= 35 and vn - pn <= 43);
}

test "mTLS Finished without a client cert fails closed" {
    const allocator = testing.allocator;
    var verify_creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(verify_creds.cert_der);
    verify_creds.verify_client = true;

    var hello_buf: [1024]u8 = undefined;
    const hello_rec = mtlsHelloRecord(&hello_buf);
    var sess = TestSession.init(allocator, &verify_creds);
    defer sess.deinit();
    try sess.feed(hello_rec);
    try testing.expectEqual(Stage.waiting_finished, sess.currentStage());
    // A Finished with no preceding Certificate/CertificateVerify trips the
    // gate (certificate_required), never reaching application data.
    const fake_finished = [_]u8{ 0x14, 0x00, 0x00, 0x0C, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    try testing.expectError(error.TlsUnexpectedMessage, sess.onClientFinished(&fake_finished));
    try testing.expect(sess.last_alert != null);
}

test "session exportTxKeys hands out TX material in application stage" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    var sess = TestSession.init(allocator, &creds);
    defer sess.deinit();
    var key: [32]u8 = undefined;
    var iv: [12]u8 = undefined;
    // Pre-handshake: nothing to export.
    try testing.expect(sess.exportTxKeys(&key, &iv) == null);
    // Post-handshake states export (stage forced; keys may be unwritten
    // but the shape contract holds — suite tag + sequence counter).
    sess.stage = .application;
    sess.cipher_suite = 0x1301;
    const exp = sess.exportTxKeys(&key, &iv).?;
    try testing.expectEqual(@as(u16, 0x1301), exp.suite);
    try testing.expectEqual(@as(u64, 0), exp.seq);
    // Undersized buffers: null, never partial.
    var tiny: [4]u8 = undefined;
    try testing.expect(sess.exportTxKeys(&tiny, &iv) == null);
}

test "all six cipher suites complete the server flight" {
    // Variant coverage: each Session monomorphization carries its own
    // blocks; feeding the same captured ClientHello through every suite
    // exercises each variant's hello/keyshake/flight path (P-384 suites
    // use the secp384r1 fixtures).
    const allocator = testing.allocator;
    var creds256 = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds256.cert_der);
    var creds384 = try cert_mod.loadCredentials(allocator, testdata.cert384_pem, testdata.key384_pem);
    defer allocator.free(creds384.cert_der);
    const S256a = Session(std.crypto.aead.aes_gcm.Aes128Gcm, Sha256, Sha256, EcdsaP256, 0x0403);
    const S256b = Session(std.crypto.aead.chacha_poly.ChaCha20Poly1305, Sha256, Sha256, EcdsaP256, 0x0403);
    const S256c = Session(std.crypto.aead.aes_gcm.Aes256Gcm, std.crypto.hash.sha2.Sha384, Sha256, EcdsaP256, 0x0403);
    const EcdsaP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
    const S384a = Session(std.crypto.aead.aes_gcm.Aes128Gcm, Sha256, std.crypto.hash.sha2.Sha384, EcdsaP384, 0x0503);
    const S384b = Session(std.crypto.aead.aes_gcm.Aes256Gcm, std.crypto.hash.sha2.Sha384, std.crypto.hash.sha2.Sha384, EcdsaP384, 0x0503);
    const S384c = Session(std.crypto.aead.chacha_poly.ChaCha20Poly1305, Sha256, std.crypto.hash.sha2.Sha384, EcdsaP384, 0x0503);
    inline for (.{
        .{ S256a, &creds256 },
        .{ S256b, &creds256 },
        .{ S256c, &creds256 },
        .{ S384a, &creds384 },
        .{ S384b, &creds384 },
        .{ S384c, &creds384 },
    }) |pair| {
        var hello_buf: [1024]u8 = undefined;
        const rec = mtlsHelloRecord(&hello_buf);
        var sess = pair[0].init(allocator, pair[1]);
        defer sess.deinit();
        try sess.feed(rec);
        try testing.expectEqual(Stage.waiting_finished, sess.currentStage());
        var out: [32 * 1024]u8 = undefined;
        try testing.expect(sess.takeOut(&out) > 0);
    }
}

test "session: application writes chunk into framed records" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    var sess = TestSession.init(allocator, &creds);
    defer sess.deinit();
    sess.stage = .application;
    @memset(sess.secrets.server_application_key[0..], 0x5A);
    @memset(sess.secrets.server_application_iv[0..], 0xA5);

    const payload = try allocator.alloc(u8, 2 * max_plaintext + 7);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    try sess.write(payload);
    // Two full records and a tail record; the sequence advanced with them.
    try testing.expectEqual(@as(u64, 3), sess.write_seq);

    const wire = try allocator.alloc(u8, payload.len + 3 * (5 + 1 + 16));
    defer allocator.free(wire);
    const n = sess.takeOut(wire);
    try testing.expectEqual(wire.len, n);
    var off: usize = 0;
    var seq: u64 = 0;
    var got: usize = 0;
    while (off < n) : (seq += 1) {
        const rec_len: usize = std.mem.readInt(u16, wire[off + 3 ..][0..2], .big);
        try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.application_data)), wire[off]);
        const dec = try record_mod.decryptInPlace(Aes128Gcm, sess.secrets.server_application_key, sess.secrets.server_application_iv, seq, wire[off..][0 .. 5 + rec_len]);
        try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.application_data)), dec.content_type);
        try testing.expectEqualSlices(u8, payload[got..][0..dec.plaintext.len], dec.plaintext);
        got += dec.plaintext.len;
        off += 5 + rec_len;
    }
    try testing.expectEqual(@as(usize, 3), seq);
    try testing.expectEqual(payload.len, got);
    // An empty write produces no record and does not advance the sequence.
    try sess.write("");
    try testing.expectEqual(@as(u64, 3), sess.write_seq);
    try testing.expectEqual(@as(usize, 0), sess.takeOutSlice().len);
}

/// Encrypt one record straight into `sess.in_buf` and dispatch it through
/// `processEncryptedRecord` (the stage/content-type matrix without framing).
fn feedEncryptedRecord(sess: *TestSession, key: [16]u8, iv: [12]u8, seq: u64, inner: u8, payload: []const u8) !void {
    var rec: [max_plaintext + 1 + 5 + 16]u8 = undefined;
    const n = try record_mod.encrypt(Aes128Gcm, key, iv, seq, inner, payload, &rec);
    sess.in_buf.clearRetainingCapacity();
    try sess.in_buf.appendSlice(testing.allocator, rec[0..n]);
    try sess.processEncryptedRecord(0);
}

test "session: encrypted records dispatch by stage and inner content type" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    const hs_key = @as([16]u8, @splat(0x11));
    const hs_iv = @as([12]u8, @splat(0x22));
    const ap_key = @as([16]u8, @splat(0x33));
    const ap_iv = @as([12]u8, @splat(0x44));
    const app_data = @intFromEnum(tls.ContentType.application_data);
    const hs = @intFromEnum(tls.ContentType.handshake);
    const alert = @intFromEnum(tls.ContentType.alert);

    // No keys exist before the ServerHello: any encrypted record is refused.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        try testing.expectError(error.TlsUnexpectedMessage, feedEncryptedRecord(&sess, hs_key, hs_iv, 0, app_data, "x"));
    }
    // waiting_finished: handshake fragments assemble, app data is refused.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .waiting_finished;
        sess.secrets.client_handshake_key = hs_key;
        sess.secrets.client_handshake_iv = hs_iv;
        try testing.expectError(error.TlsUnexpectedMessage, feedEncryptedRecord(&sess, hs_key, hs_iv, 0, app_data, "early"));
        // The decrypt consumed seq 0 even though the inner type was wrong.
        try feedEncryptedRecord(&sess, hs_key, hs_iv, 1, hs, "ab");
        try testing.expectEqual(@as(usize, 2), sess.handshake_buf.items.len);
        try testing.expectEqual(@as(u64, 2), sess.read_seq);
        // A bad MAC (wrong key) fails without consuming the sequence.
        try testing.expectError(error.TlsBadRecordMac, feedEncryptedRecord(&sess, ap_key, hs_iv, 2, hs, "ab"));
        try testing.expectEqual(@as(u64, 2), sess.read_seq);
        // A body too short to carry a tag is a record overflow.
        sess.in_buf.clearRetainingCapacity();
        try sess.in_buf.appendSlice(allocator, &.{ app_data, 0x03, 0x03, 0x00, 0x00 });
        try testing.expectError(error.TlsRecordOverflow, sess.processEncryptedRecord(0));
    }
    // application: data, close_notify, fatal alerts, stray handshake.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .application;
        sess.secrets.client_application_key = ap_key;
        sess.secrets.client_application_iv = ap_iv;
        try feedEncryptedRecord(&sess, ap_key, ap_iv, 0, app_data, "ping");
        try testing.expectEqualStrings("ping", sess.plaintext_out.items);
        try feedEncryptedRecord(&sess, ap_key, ap_iv, 1, alert, &.{ 0x01, 0x00 });
        try testing.expectEqual(Stage.closed, sess.currentStage());
        // A fatal alert in the application phase surfaces as TlsAlert.
        sess.stage = .application;
        try testing.expectError(error.TlsAlert, feedEncryptedRecord(&sess, ap_key, ap_iv, 2, alert, &.{ 0x02, 0x28 }));
        // Post-handshake messages other than a NewSessionTicket are refused.
        sess.stage = .application;
        try testing.expectError(error.TlsUnexpectedMessage, feedEncryptedRecord(&sess, ap_key, ap_iv, 3, hs, "x"));
    }
    // An oversized length field maps the record layer's overflow.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .application;
        const big: usize = tls.max_ciphertext_len + 1;
        const buf = try allocator.alloc(u8, 5 + big);
        defer allocator.free(buf);
        @memset(buf, 0);
        var hdr: [5]u8 = undefined;
        record_mod.writeHeader(&hdr, app_data, @intCast(big));
        @memcpy(buf[0..5], &hdr);
        sess.in_buf.clearRetainingCapacity();
        try sess.in_buf.appendSlice(allocator, buf);
        try testing.expectError(error.TlsRecordOverflow, sess.processEncryptedRecord(0));
    }
}

test "session: late and malformed ClientHellos fail closed" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    var sess = TestSession.init(allocator, &creds);
    defer sess.deinit();
    // A ClientHello after the handshake left the hello stages.
    sess.stage = .waiting_finished;
    var hello_buf: [1024]u8 = undefined;
    const rec = mtlsHelloRecord(&hello_buf);
    try testing.expectError(error.TlsUnexpectedMessage, sess.onClientHello(rec[5..]));
    // A truncated body maps the parser's decode error onto a fatal alert.
    var sess2 = TestSession.init(allocator, &creds);
    defer sess2.deinit();
    var msg_buf: [8]u8 = undefined;
    const msg = testHsMsg(0x01, "ab", &msg_buf);
    try testing.expectError(error.TlsDecodeError, sess2.onClientHello(msg));
    try testing.expect(sess2.alert() != null);
}

/// The PSK ClientHello built by `testPskHello`.
const TestPskHello = struct {
    msg: []u8,
    /// Offset of the psk_key_exchange_modes list length byte.
    modes_at: usize,
    /// Offset of the first PskBinderEntry byte.
    binder_at: usize,
};

/// Build a ClientHello with an x25519 share, psk_dhe_ke and `ticket` as the
/// PSK identity; the binder is derived exactly like the server does
/// (RFC 8446 §4.2.11.2) from the sealed resumption master secret `rms`.
fn testPskHello(out: []u8, ticket: []const u8, rms: [32]u8) TestPskHello {
    var pos: usize = 0;
    out[pos] = 0x01; // client_hello
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    out[pos] = 0x03;
    out[pos + 1] = 0x03;
    pos += 2;
    @memset(out[pos..][0..32], 0xCD);
    pos += 32;
    out[pos] = 0; // session id
    pos += 1;
    out[pos] = 0;
    out[pos + 1] = 2; // cipher suites
    pos += 2;
    out[pos] = 0x13;
    out[pos + 1] = 0x01;
    pos += 2;
    out[pos] = 1; // compression
    pos += 1;
    out[pos] = 0;
    pos += 1;
    const ext_len_at = pos;
    pos += 2;
    const ext_at = pos;
    // supported_versions
    std.mem.writeInt(u16, out[pos..][0..2], 0x002b, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 3, .big);
    pos += 2;
    out[pos] = 2;
    pos += 1;
    std.mem.writeInt(u16, out[pos..][0..2], 0x0304, .big);
    pos += 2;
    // supported_groups
    std.mem.writeInt(u16, out[pos..][0..2], 0x000a, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 4, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 2, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], handshake_mod.x25519_group, .big);
    pos += 2;
    // key_share: one x25519 share
    std.mem.writeInt(u16, out[pos..][0..2], 0x0033, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 38, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 36, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], handshake_mod.x25519_group, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 32, .big);
    pos += 2;
    @memset(out[pos..][0..32], 0x42);
    pos += 32;
    // psk_key_exchange_modes: psk_dhe_ke
    std.mem.writeInt(u16, out[pos..][0..2], 0x002d, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 2, .big);
    pos += 2;
    const modes_at = pos;
    out[pos] = 1;
    pos += 1;
    out[pos] = 0x01;
    pos += 1;
    // pre_shared_key: one identity + one binder
    std.mem.writeInt(u16, out[pos..][0..2], 0x0029, .big);
    pos += 2;
    const psk_len_at = pos;
    pos += 2;
    const psk_body_at = pos;
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(2 + ticket.len + 4), .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(ticket.len), .big);
    pos += 2;
    @memcpy(out[pos..][0..ticket.len], ticket);
    pos += ticket.len;
    std.mem.writeInt(u32, out[pos..][0..4], 0, .big);
    pos += 4;
    const binders_len_at = pos;
    std.mem.writeInt(u16, out[pos..][0..2], 33, .big);
    pos += 2;
    out[pos] = 32;
    pos += 1;
    const binder_at = pos;
    @memset(out[pos..][0..32], 0);
    pos += 32;
    std.mem.writeInt(u16, out[psk_len_at..][0..2], @intCast(pos - psk_body_at), .big);
    std.mem.writeInt(u16, out[ext_len_at..][0..2], @intCast(pos - ext_at), .big);
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);

    // Binder: expand the sealed secret with the (zero) ticket nonce, then
    // sign the truncated ClientHello up to the binders list.
    const Suite = keyschedule_mod.Suite(Aes128Gcm, Sha256);
    const empty_hash = tls.emptyHash(Sha256);
    const nonce_byte = [1]u8{0};
    const psk_full = tls.hkdfExpandLabel(Suite.Hkdf, rms, "resumption", &nonce_byte, 32);
    const psk_bytes: [32]u8 = psk_full;
    const early = Suite.Hkdf.extract(&[1]u8{0}, &psk_bytes);
    const binder_key = tls.hkdfExpandLabel(Suite.Hkdf, early, "res binder", &empty_hash, Suite.finished_key_length);
    const finished_key = tls.hkdfExpandLabel(Suite.Hkdf, binder_key, "finished", "", Suite.finished_key_length);
    var trunc_hash: [32]u8 = undefined;
    Sha256.hash(out[0..binders_len_at], &trunc_hash, .{});
    const binder = keyschedule_mod.Secrets(Suite).verifyData(finished_key, trunc_hash);
    @memcpy(out[binder_at..][0..32], &binder);

    return .{ .msg = out[0..pos], .modes_at = modes_at, .binder_at = binder_at };
}

test "session: PSK resumption resumes without a certificate" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    var sess = TestSession.init(allocator, &creds);
    defer sess.deinit();

    var rms: [32]u8 = undefined;
    @memset(&rms, 0x7C);
    var ticket: [tickets_mod.max_ticket_len]u8 = undefined;
    const ticket_len = try tickets_mod.seal(&rms, .{ 1, 2, 3, 4, 5, 6, 7, 8 }, &ticket);

    var msg_buf: [1024]u8 = undefined;
    const hello = testPskHello(&msg_buf, ticket[0..ticket_len], rms);
    try sess.onClientHello(hello.msg);
    try testing.expectEqual(Stage.waiting_finished, sess.currentStage());
    try testing.expectEqual(@as(usize, 32), sess.psk_len);

    // ServerHello is cleartext and selects the PSK identity (the last
    // extension, RFC 8446 §4.2.8.1).
    var out: [32 * 1024]u8 = undefined;
    const n = sess.takeOut(&out);
    try testing.expect(n > 0);
    try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.handshake)), out[0]);
    const sh_len: usize = std.mem.readInt(u16, out[3..5], .big);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x29, 0x00, 0x02, 0x00, 0x00 }, out[5 + sh_len - 6 ..][0..6]);
    var off = 5 + sh_len;
    try testing.expectEqual(@as(u8, @intFromEnum(tls.ContentType.change_cipher_spec)), out[off]);
    const ccs_len: usize = std.mem.readInt(u16, out[off + 3 ..][0..2], .big);
    off += 5 + ccs_len;

    // The resumed flight decrypts to EncryptedExtensions + Finished only:
    // no Certificate / CertificateVerify.
    var msgs: [512]u8 = undefined;
    var mn: usize = 0;
    var seq: u64 = 0;
    while (off < n) : (seq += 1) {
        const rec_len: usize = std.mem.readInt(u16, out[off + 3 ..][0..2], .big);
        const dec = try record_mod.decryptInPlace(Aes128Gcm, sess.secrets.server_handshake_key, sess.secrets.server_handshake_iv, seq, out[off..][0 .. 5 + rec_len]);
        @memcpy(msgs[mn..][0..dec.plaintext.len], dec.plaintext);
        mn += dec.plaintext.len;
        off += 5 + rec_len;
    }
    var p: usize = 0;
    var types: [4]u8 = undefined;
    var tn: usize = 0;
    while (p + 4 <= mn) {
        const ml: usize = std.mem.readInt(u24, msgs[p + 1 ..][0..3], .big);
        types[tn] = msgs[p];
        tn += 1;
        p += 4 + ml;
    }
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x14 }, types[0..tn]);

    // The client Finished completes the resumed handshake and a
    // NewSessionTicket goes out under the application keys.
    const Suite = keyschedule_mod.Suite(Aes128Gcm, Sha256);
    const verify = keyschedule_mod.Secrets(Suite).verifyData(sess.secrets.client_finished_key, sess.full_transcript.peek());
    var fin_msg: [64]u8 = undefined;
    const fin = testHsMsg(0x14, &verify, &fin_msg);
    var fin_rec: [128]u8 = undefined;
    const enc = try record_mod.encrypt(Aes128Gcm, sess.secrets.client_handshake_key, sess.secrets.client_handshake_iv, 0, @intFromEnum(tls.ContentType.handshake), fin, &fin_rec);
    try sess.feed(fin_rec[0..enc]);
    try testing.expectEqual(Stage.application, sess.currentStage());
    try testing.expectEqual(@as(u64, 1), sess.write_seq); // the ticket record
    try testing.expect(sess.takeOutSlice().len > 0);
}

test "session: PSK resumption rejects bad binders, modes and tickets" {
    const allocator = testing.allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);
    var rms: [32]u8 = undefined;
    @memset(&rms, 0x7C);
    var ticket: [tickets_mod.max_ticket_len]u8 = undefined;
    const ticket_len = try tickets_mod.seal(&rms, .{ 9, 9, 9, 9, 9, 9, 9, 9 }, &ticket);

    // A tampered binder fails the HMAC over the truncated ClientHello.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        var buf: [1024]u8 = undefined;
        const hello = testPskHello(&buf, ticket[0..ticket_len], rms);
        buf[hello.binder_at] ^= 0xFF;
        try testing.expectError(error.TlsIllegalParameter, sess.onClientHello(hello.msg));
    }
    // psk_ke (no forward secrecy) is not accepted.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        var buf: [1024]u8 = undefined;
        const hello = testPskHello(&buf, ticket[0..ticket_len], rms);
        buf[hello.modes_at + 1] = 0x02;
        try testing.expectError(error.TlsIllegalParameter, sess.onClientHello(hello.msg));
    }
    // A ticket we never sealed cannot be opened.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        var buf: [1024]u8 = undefined;
        const junk = @as([40]u8, @splat(@as(u8, 0xAA)));
        const hello = testPskHello(&buf, &junk, rms);
        try testing.expectError(error.TlsIllegalParameter, sess.onClientHello(hello.msg));
    }
    // A PSK offered on the second hello after an HRR is illegal.
    {
        var sess = TestSession.init(allocator, &creds);
        defer sess.deinit();
        sess.stage = .sent_hrr;
        var buf: [1024]u8 = undefined;
        const hello = testPskHello(&buf, ticket[0..ticket_len], rms);
        try testing.expectError(error.TlsIllegalParameter, sess.onClientHello(hello.msg));
    }
}
