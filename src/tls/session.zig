//! TLS 1.3 server session (RFC 8446) — the state machine that drives the
//! handshake and record layer for one connection. Generic over the AEAD,
//! the record-hash, the signature-hash and the ECDSA curve so every
//! (cipher, certificate) combination compiles down to its exact types.
//!
//! Buffering model (M17): raw ciphertext accumulates in `in_buf`; records
//! are decrypted IN PLACE within it (ciphertext region becomes plaintext,
//! no copy); handshake messages assemble in `handshake_buf`; application
//! plaintext is copied into `plaintext_out` for the caller; ciphertext
//! ready to send sits in `out_buf` (drained with `takeOut`). The reactor
//! integration (M18) wires these to the connection buffers.

const std = @import("std");
const tls = std.crypto.tls;
const cert_mod = @import("cert.zig");
const handshake_mod = @import("handshake.zig");
const record_mod = @import("record.zig");
const keyschedule_mod = @import("keyschedule.zig");
const tickets_mod = @import("tickets.zig");
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
        /// Resumed session master secret (from a validated ticket, M18).
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
            std.crypto.random.bytes(&self.our_random);
            const kp = X25519.KeyPair.generate();
            self.x25519_secret = kp.secret_key;
            self.x25519_public = kp.public_key;
            return self;
        }

        pub fn deinit(self: *Self) void {
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

            // PSK resumption (M18): open the ticket, require psk_dhe_ke
            // mode, and verify the binder over the truncated ClientHello.
            var resumed_psk: ?[]const u8 = null;
            if (hello.psk_identity.len > 0) {
                // PSK resumption (M18): the first ClientHello carries a
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

            if (!resumed) {
            const n_cert = handshake_mod.buildCertificate(&msg, self.creds.cert_der) catch
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

        fn onClientFinished(self: *Self, message: []const u8) Error!void {
            if (self.stage != .waiting_finished)
                return self.fail(error.TlsUnexpectedMessage, .unexpected_message);
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
/// curve. M17 supports the four common combinations; the union dispatches to
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

// The definitive M17 interop test: the std TLS 1.3 client performs a full
// handshake against our server session over a socketpair, then both sides
// exchange application data encrypted in both directions. Any mismatch in
// the key schedule, transcript, records or signatures fails here.
test "TLS 1.3 handshake and round trip against the std client" {
    const allocator = std.heap.page_allocator;
    var creds = try cert_mod.loadCredentials(allocator, testdata.cert_pem, testdata.key_pem);
    defer allocator.free(creds.cert_der);

    const pair = try std.posix.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(pair[1]);

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
                        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
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
                const n = std.posix.write(fd, remaining) catch |e| switch (e) {
                    error.WouldBlock => {
                        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
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
    var threaded = std.Io.Threaded.init(allocator);
    const io = threaded.io();
    const stream = std.Io.net.Stream{ .socket = .{ .handle = pair[1], .address = undefined } };
    var client_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var client_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &client_read_buf);
    var writer = stream.writer(io, &client_write_buf);
    var entropy: [176]u8 = undefined;
    std.crypto.random.bytes(&entropy);
    var client = std.crypto.tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
        .entropy = &entropy,
        .realtime_now_seconds = 0,
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
    std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
    stop.store(true, .release);
    std.posix.close(pair[0]);
    server_thread.join();
    try testing.expect(server_err == null);
}
