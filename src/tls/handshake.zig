//! TLS 1.3 server handshake messages (RFC 8446): ClientHello parsing,
//! ServerHello / HelloRetryRequest / EncryptedExtensions / Certificate /
//! CertificateVerify / Finished construction, ALPN negotiation and suite
//! selection. The state machine that drives these lives in session.zig.

const std = @import("std");
const tls = std.crypto.tls;
const cert_mod = @import("cert.zig");

pub const Error = error{
    TlsIllegalParameter,
    TlsDecodeError,
    TlsUnexpectedMessage,
    UnsupportedCipherSuite,
    UnsupportedGroup,
    UnsupportedSignatureScheme,
    NoUsableKeyShare,
    OutOfMemory,
};

pub const handshake_header_len = 4;

/// Key-exchange group supported by the server (M17: X25519 only; the std
/// client and curl both offer it, so HRR is the fallback for the rest).
pub const x25519_group: u16 = 0x001d;

/// Cipher suites the server offers (RFC 8446 §B.4, ordered by preference).
pub const supported_cipher_suites = [_]u16{
    0x1301, // TLS_AES_128_GCM_SHA256
    0x1303, // TLS_CHACHA20_POLY1305_SHA256
    0x1302, // TLS_AES_256_GCM_SHA384
};

/// Signature schemes the server supports, ordered by preference. Only the
/// certificate's curve applies (the others are advertised but never chosen
/// without a matching cert).
pub const supported_signature_schemes = [_]u16{
    0x0403, // ecdsa_secp256r1_sha256
    0x0503, // ecdsa_secp384r1_sha384
};

/// The negotiated parameters of one handshake.
pub const Negotiated = struct {
    cipher_suite: u16,
    /// The client's ECDHE key share (32 bytes for x25519).
    key_share: []const u8,
    /// ALPN protocol selected (or empty when the client sent none).
    alpn: []const u8 = "",
    /// The certificate's signature scheme for CertificateVerify.
    signature_scheme: u16,
};

/// What the server parsed out of a ClientHello, with the raw bytes needed
/// to reproduce the transcript hash.
pub const ClientHello = struct {
    legacy_session_id: []const u8 = &.{},
    cipher_suites: []const u8 = &.{},
    /// Client key shares: (group, share) pairs.
    key_shares: []const KeyShare = &.{},
    supported_groups: []const u8 = &.{},
    signature_algorithms: []const u8 = &.{},
    alpn: []const u8 = &.{},
    has_supported_versions_13: bool = false,
    random: [32]u8 = undefined,
    /// PSK resumption (M18): the session-ticket identity and the binder, as
    /// well as the psk_key_exchange_modes list. Empty when the client sent
    /// no pre_shared_key.
    psk_identity: []const u8 = &.{},
    psk_binder: []const u8 = &.{},
    psk_modes: []const u8 = &.{},
    /// Absolute offsets (into the full handshake message, header included)
    /// for the pre_shared_key extension: where its length field starts and
    /// where the binders begin. Used to rebuild the truncated ClientHello
    /// for binder verification (RFC 8446 §4.2.11.2).
    psk_ext_len_pos: usize = 0,
    psk_binders_pos: usize = 0,

    pub const KeyShare = struct {
        group: u16,
        data: []const u8,
    };
};

/// Parse a ClientHello message body (without the 4-byte handshake header).
pub fn parseClientHello(body: []const u8) Error!ClientHello {
    var d = tls.Decoder.fromTheirSlice(@constCast(body));
    var out = ClientHello{};
    d.ensure(2 + 32 + 1) catch return error.TlsDecodeError;
    const legacy_version = d.decode(u16);
    if (legacy_version != 0x0301 and legacy_version != 0x0303) return error.TlsIllegalParameter;
    out.random = d.array(32).*;
    const sid_len = d.decode(u8);
    d.ensure(sid_len) catch return error.TlsDecodeError;
    out.legacy_session_id = d.slice(sid_len);
    d.ensure(2) catch return error.TlsDecodeError;
    const suites_len = d.decode(u16);
    if (suites_len == 0 or suites_len % 2 != 0) return error.TlsIllegalParameter;
    d.ensure(suites_len) catch return error.TlsDecodeError;
    out.cipher_suites = d.slice(suites_len);
    d.ensure(1) catch return error.TlsDecodeError;
    const comp_len = d.decode(u8);
    d.ensure(comp_len) catch return error.TlsDecodeError;
    d.skip(comp_len);
    if (!d.eof()) {
        d.ensure(2) catch return error.TlsDecodeError;
        const ext_len = d.decode(u16);
        var all = d.sub(ext_len) catch return error.TlsDecodeError;
        while (!all.eof()) {
            all.ensure(2 + 2) catch return error.TlsDecodeError;
            const ext_type_pos = all.idx;
            const et = all.decode(tls.ExtensionType);
            const len = all.decode(u16);
            var ext = all.sub(len) catch return error.TlsDecodeError;
            switch (et) {
                .supported_versions => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const list_len = ext.decode(u8);
                    ext.ensure(list_len) catch return error.TlsDecodeError;
                    const list = ext.slice(list_len);
                    // 0x0304 = TLS 1.3, listed as a u16.
                    var i: usize = 0;
                    while (i + 1 < list.len) : (i += 2) {
                        const v = std.mem.readInt(u16, list[i..][0..2], .big);
                        if (v == 0x0304) out.has_supported_versions_13 = true;
                    }
                },
                .supported_groups => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const list_len = ext.decode(u16);
                    ext.ensure(list_len) catch return error.TlsDecodeError;
                    out.supported_groups = ext.slice(list_len);
                },
                .key_share => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const list_len = ext.decode(u16);
                    ext.ensure(list_len) catch return error.TlsDecodeError;
                    const list = ext.slice(list_len);
                    var sub = tls.Decoder.fromTheirSlice(@constCast(list));
                    var shares = std.ArrayList(ClientHello.KeyShare).empty;
                    defer shares.deinit(std.heap.page_allocator);
                    while (!sub.eof()) {
                        sub.ensure(4) catch return error.TlsDecodeError;
                        const group = sub.decode(u16);
                        const share_len = sub.decode(u16);
                        sub.ensure(share_len) catch return error.TlsDecodeError;
                        const data = sub.slice(share_len);
                        shares.append(std.heap.page_allocator, .{ .group = group, .data = data }) catch
                            return error.OutOfMemory;
                    }
                    out.key_shares = shares.toOwnedSlice(std.heap.page_allocator) catch return error.OutOfMemory;
                },
                .pre_shared_key => {
                    // RFC 8446 §4.2.11: identities then binders; the binders
                    // are the last bytes of the extension.
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const ids_len = ext.decode(u16);
                    ext.ensure(ids_len) catch return error.TlsDecodeError;
                    const ids = ext.slice(ids_len);
                    // First identity: u16 len + bytes + u32 obfuscated age.
                    if (ids.len >= 2) {
                        const id_len = std.mem.readInt(u16, ids[0..2], .big);
                        if (ids.len >= 2 + id_len + 4) {
                            out.psk_identity = ids[2 .. 2 + id_len];
                        }
                    }
                    // Bind list: u16 len + binders (u8 len + bytes each).
                    if (!ext.eof()) {
                        ext.ensure(2) catch return error.TlsDecodeError;
                        const binders_len = ext.decode(u16);
                        ext.ensure(binders_len) catch return error.TlsDecodeError;
                        const binders = ext.slice(binders_len);
                        if (binders.len >= 2) {
                            const b_len: usize = binders[0];
                            if (binders.len >= 1 + b_len) {
                                out.psk_binder = binders[1 .. 1 + b_len];
                            }
                        }
                        // Absolute offsets into the full handshake message
                        // (4-byte header + body): the extensions list starts
                        // after the fixed ClientHello fields.
                        // The extensions list starts after the u16 list-length
                        // field; ext_type_pos indexes within the list.
                        const body_ext_base = 2 + 32 + 1 + sid_len + 2 + suites_len + 1 + comp_len + 2;
                        const ext_type_abs = 4 + body_ext_base + ext_type_pos;
                        out.psk_ext_len_pos = ext_type_abs + 2;
                        // The binders list (u16 length + entries) is the last
                        // `2 + binders_len` bytes of the extension.
                        out.psk_binders_pos = out.psk_ext_len_pos + 2 + (len - 2 - binders_len);
                    }
                },
                .psk_key_exchange_modes => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const modes_len = ext.decode(u8);
                    ext.ensure(modes_len) catch return error.TlsDecodeError;
                    out.psk_modes = ext.slice(modes_len);
                },
                .signature_algorithms => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const list_len = ext.decode(u16);
                    ext.ensure(list_len) catch return error.TlsDecodeError;
                    out.signature_algorithms = ext.slice(list_len);
                },
                .application_layer_protocol_negotiation => {
                    ext.ensure(2) catch return error.TlsDecodeError;
                    const list_len = ext.decode(u16);
                    ext.ensure(list_len) catch return error.TlsDecodeError;
                    out.alpn = ext.slice(list_len);
                },
                else => {},
            }
        }
    }
    return out;
}

/// Pick the cipher suite: the first suite in OUR preference order that the
/// client offered (RFC 8446 §4.1.1: server preference).
pub fn selectCipherSuite(client_suites: []const u8) ?u16 {
    for (supported_cipher_suites) |ours| {
        var i: usize = 0;
        while (i + 1 < client_suites.len) : (i += 2) {
            const suite = std.mem.readInt(u16, client_suites[i..][0..2], .big);
            if (suite == ours) return suite;
        }
    }
    return null;
}

/// Pick the client's x25519 key share, if offered.
pub fn selectKeyShare(hello: *const ClientHello) ?[]const u8 {
    for (hello.key_shares) |ks| {
        if (ks.group == x25519_group) return ks.data;
    }
    return null;
}

/// Build the ServerHello (or HelloRetryRequest when `hrr` is true, RFC 8446
/// §4.1.3: same structure, keyshare extension without the share).
pub fn buildServerHello(
    out: []u8,
    random: [32]u8,
    legacy_session_id: []const u8,
    cipher_suite: u16,
    hrr: bool,
    keyshare: ?[]const u8,
    psk_selected: ?u16,
) !usize {
    var pos: usize = 0;
    // handshake header: type + length (patched below)
    out[pos] = 0x02; // server_hello
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    out[pos] = 0x03;
    out[pos + 1] = 0x03; // legacy_version
    pos += 2;
    @memcpy(out[pos..][0..32], &random);
    pos += 32;
    out[pos] = @intCast(legacy_session_id.len);
    pos += 1;
    @memcpy(out[pos..][0..legacy_session_id.len], legacy_session_id);
    pos += legacy_session_id.len;
    std.mem.writeInt(u16, out[pos..][0..2], cipher_suite, .big);
    pos += 2;
    out[pos] = 0x00; // legacy_compression_method
    pos += 1;
    // extensions
    const ext_len_at = pos;
    pos += 2;
    // supported_versions: 0x0304
    std.mem.writeInt(u16, out[pos..][0..2], 0x002b, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 2, .big);
    pos += 2;
    out[pos] = 0x03;
    out[pos + 1] = 0x04;
    pos += 2;
    // key_share
    std.mem.writeInt(u16, out[pos..][0..2], 0x0033, .big);
    pos += 2;
    if (hrr) {
        // HRR: the keyshare extension carries only the selected group.
        std.mem.writeInt(u16, out[pos..][0..2], 2, .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], x25519_group, .big);
        pos += 2;
    } else {
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(2 + 2 + keyshare.?.len), .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], x25519_group, .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(keyshare.?.len), .big);
        pos += 2;
        @memcpy(out[pos..][0..keyshare.?.len], keyshare.?);
        pos += keyshare.?.len;
    }
    // pre_shared_key: must be the last extension; selects the accepted PSK
    // identity by index (RFC 8446 §4.2.8.1).
    if (psk_selected) |selected| {
        std.mem.writeInt(u16, out[pos..][0..2], 0x0029, .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], 2, .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], selected, .big);
        pos += 2;
    }
    std.mem.writeInt(u16, out[ext_len_at..][0..2], @intCast(pos - ext_len_at - 2), .big);
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);
    return pos;
}

/// EncryptedExtensions: the ALPN extension when one was negotiated.
pub fn buildEncryptedExtensions(out: []u8, alpn: ?[]const u8) !usize {
    var pos: usize = 0;
    out[pos] = 0x08;
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    const ext_len_at = pos;
    pos += 2;
    if (alpn) |proto| {
        std.mem.writeInt(u16, out[pos..][0..2], 0x0010, .big);
        pos += 2;
        // Extension content: list length(2) + entry length(1) + protocol.
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(3 + proto.len), .big);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(1 + proto.len), .big);
        pos += 2;
        out[pos] = @intCast(proto.len);
        pos += 1;
        @memcpy(out[pos..][0..proto.len], proto);
        pos += proto.len;
    }
    std.mem.writeInt(u16, out[ext_len_at..][0..2], @intCast(pos - ext_len_at - 2), .big);
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);
    return pos;
}

/// Certificate message with a single certificate entry (the leaf; M17 sends
/// no chain and no extensions).
pub fn buildCertificate(out: []u8, cert_der: []const u8) !usize {
    var pos: usize = 0;
    out[pos] = 0x0b;
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    out[pos] = 0x00; // certificate_request_context (empty)
    pos += 1;
    // certificate_list length
    const list_len_at = pos;
    pos += 3;
    // one CertificateEntry: cert_data + empty extensions
    std.mem.writeInt(u24, out[pos..][0..3], @intCast(cert_der.len), .big);
    pos += 3;
    @memcpy(out[pos..][0..cert_der.len], cert_der);
    pos += cert_der.len;
    std.mem.writeInt(u16, out[pos..][0..2], 0, .big); // extensions (empty)
    pos += 2;
    std.mem.writeInt(u24, out[list_len_at..][0..3], @intCast(pos - list_len_at - 3), .big);
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);
    return pos;
}

/// CertificateVerify: ECDSA (DER) over the transcript hash so far.
/// `signature_scheme` must match the certificate curve.
pub fn buildCertificateVerify(
    out: []u8,
    signature_scheme: u16,
    signature: []const u8,
) !usize {
    var pos: usize = 0;
    out[pos] = 0x0f;
    pos += 1;
    const len_at = pos;
    pos += 3;
    const body_at = pos;
    std.mem.writeInt(u16, out[pos..][0..2], signature_scheme, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(signature.len), .big);
    pos += 2;
    @memcpy(out[pos..][0..signature.len], signature);
    pos += signature.len;
    std.mem.writeInt(u24, out[len_at..][0..3], @intCast(pos - body_at), .big);
    return pos;
}

/// Finished: verify_data = HMAC(finished_key, transcript hash).
pub fn buildFinished(out: []u8, verify_data: []const u8) !usize {
    var pos: usize = 0;
    out[pos] = 0x14;
    pos += 1;
    std.mem.writeInt(u24, out[pos..][0..3], @intCast(verify_data.len), .big);
    pos += 3;
    @memcpy(out[pos..][0..verify_data.len], verify_data);
    pos += verify_data.len;
    return pos;
}

/// Select the ALPN protocol: the first client preference we serve
/// ("h2" or "http/1.1"). Returns the chosen protocol or null.
pub fn selectAlpn(client_alpn_list: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < client_alpn_list.len) {
        const len: usize = client_alpn_list[i];
        i += 1;
        if (i + len > client_alpn_list.len) return null;
        const proto = client_alpn_list[i .. i + len];
        if (std.mem.eql(u8, proto, "h2") or std.mem.eql(u8, proto, "http/1.1")) return proto;
        i += len;
    }
    return null;
}

/// ECDSA signature (DER) of `transcript_hash` with the given key.
pub fn signEcdsa(
    comptime Ecdsa: type,
    secret_key: []const u8,
    transcript_hash: [64]u8,
    hash_len: usize,
) Error![Ecdsa.Signature.der_encoded_length_max]u8 {
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sk = try Ecdsa.SecretKey.fromBytes(secret_key[0..secret_key.len].*);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    const sig = try Ecdsa.signPrehashed(kp, transcript_hash[0..hash_len].*, null);
    return sig.toDer(&sig_buf);
}

/// Rebuild the truncated ClientHello (RFC 8446 §4.2.11.2) for binder
/// verification: the pre_shared_key extension's binders list is removed —
/// and, per the RFC, ALL length fields (handshake message length,
/// extensions-block length, pre_shared_key extension length) stay "as if
/// binders of the correct lengths were present", i.e. unchanged. The
/// truncated message is simply the original minus the binders bytes.
/// `message` is the full handshake message (4-byte header + body); returns
/// the truncated length.
pub fn truncatedClientHello(message: []const u8, hello: *const ClientHello, out: []u8) usize {
    const binders_pos = hello.psk_binders_pos;
    if (binders_pos > message.len or binders_pos == 0) return 0;
    const removed = message.len - binders_pos;
    if (removed == 0 or removed > message.len) return 0;
    @memcpy(out[0..binders_pos], message[0..binders_pos]);
    return binders_pos;
}

const testing = std.testing;
const tls_cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBgjCCASegAwIBAgIUJJXM/gwr5mqc1ciE50yHKkS/Fw0wCgYIKoZIzj0EAwIw
    \\FjEUMBIGA1UEAwwLem9ja2V0LXRlc3QwHhcNMjYwODE2MDQ0NTA0WhcNMzYwODEz
    \\MDQ0NTA0WjAWMRQwEgYDVQQDDAt6b2NrZXQtdGVzdDBZMBMGByqGSM49AgEGCCqG
    \\SM49AwEHA0IABGJx0GzFvloM4k/e+qhMfnR8R1fJdOyLlOCWZT61nouvYszZmOAS
    \\4WpTxVnip8mWoIqkwkCyzw6wdEOMsi+klxejUzBRMB0GA1UdDgQWBBSYhQcTp0GY
    \\6+4EE3N5x+fQPWmy6TAfBgNVHSMEGDAWgBSYhQcTp0GY6+4EE3N5x+fQPWmy6TAP
    \\BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDbwEssj3iI8328T+Rz
    \\cvFtssbDb4kbI2VrKhUcEf+SrQIhAMHLq2MogzpNGWCIKwVp+PGYfS5uT2gOJ1qx
    \\0HyJrl0O
    \\-----END CERTIFICATE-----
;

test "handshake: parses a real ClientHello" {
    // A real ClientHello captured from openssl s_client -alpn 'h2,http/1.1'
    // (x25519 keyshare, TLS 1.3 only) — body after the 4-byte handshake
    // header.
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
    const parsed = try parseClientHello(&body);
    try testing.expect(parsed.has_supported_versions_13);
    try testing.expectEqual(@as(u16, 0x1301), selectCipherSuite(parsed.cipher_suites).?);
    try testing.expectEqual(@as(usize, 1), parsed.key_shares.len);
    try testing.expectEqual(@as(u16, 0x001d), parsed.key_shares[0].group);
    try testing.expectEqual(@as(usize, 32), parsed.key_shares[0].data.len);
    try testing.expect(selectKeyShare(&parsed) != null);
    try testing.expectEqualStrings("h2", selectAlpn(parsed.alpn).?);
}

test "handshake: selectAlpn prefers h2" {
    const list = [_]u8{ 2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    try testing.expectEqualStrings("h2", selectAlpn(&list).?);
    const http11 = [_]u8{ 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    try testing.expectEqualStrings("http/1.1", selectAlpn(&http11).?);
    try testing.expectEqual(@as(?[]const u8, null), selectAlpn(&[_]u8{ 3, 'f', 'o', 'o' }));
}

test "handshake: message builders produce self-consistent frames" {
    var buf: [4096]u8 = undefined;
    const sh = try buildServerHello(&buf, [_]u8{7} ** 32, &.{ 0x20, 0x01 }, 0x1301, false, &([_]u8{1} ** 32), null);
    // type 2, valid length, ends with the keyshare
    try testing.expectEqual(@as(u8, 0x02), buf[0]);
    try testing.expect(sh < buf.len);
    const ee = try buildEncryptedExtensions(buf[sh..], "h2");
    try testing.expectEqual(@as(u8, 0x08), buf[sh]);
    const cert = try buildCertificate(buf[sh + ee ..], "certs");
    try testing.expectEqual(@as(u8, 0x0b), buf[sh + ee]);
    const f = try buildFinished(buf[sh + ee + cert ..], &([_]u8{0xaa} ** 12));
    try testing.expectEqual(@as(u8, 0x14), buf[sh + ee + cert]);
    try testing.expectEqual(@as(usize, 12 + 4), f);
}
