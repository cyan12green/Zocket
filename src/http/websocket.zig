//! RFC 6455 websocket support: the server side of the HTTP/1.1 Upgrade
//! handshake and the frame codec used once the connection has switched.
//!
//! Scope: handshake digest (§4.2.2), client-frame decoding (§5.2)
//! with mandatory client masking, server-frame encoding, and the 101
//! Switching Protocols head. Fragmentation (§5.4) is rejected rather than
//! reassembled — allowed for endpoints — and control-frame payloads are
//! capped at 125 bytes per §5.5.

const std = @import("std");

/// The fixed GUID every websocket handshake digest mixes in (RFC 6455 §1.3).
pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Frame opcodes (RFC 6455 §5.2).
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    /// Control frames carry protocol metadata, never message data (§5.5).
    pub fn isControl(op: Opcode) bool {
        return switch (op) {
            .close, .ping, .pong => true,
            else => false,
        };
    }
};

/// A decoded frame header + payload view. `payload` points INTO the buffer
/// `decode` ran on (client payloads are unmaked in place), valid until that
/// buffer moves or is refilled.
pub const Frame = struct {
    fin: bool = false,
    opcode: Opcode = .continuation,
    payload: []const u8 = &.{},
    /// Header bytes + payload length: consume this much from the stream.
    total_len: usize = 0,
};

pub const DecodeResult = enum { ok, incomplete, malformed };

/// base64(SHA-1(key || GUID)) — the Sec-WebSocket-Accept value a server must
/// answer with (RFC 6455 §4.2.2 step 5). Returns the written slice of `out`
/// (always 28 bytes for standard base64 of a 20-byte SHA-1).
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var digest: [20]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// True when `proto` names the websocket protocol (case-insensitive token).
pub fn isWebsocketProto(proto: []const u8) bool {
    const trimmed = std.mem.trim(u8, proto, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "websocket");
}

/// The complete 101 Switching Protocols response head. When `proto` is
/// websocket and the client sent its key, the Sec-WebSocket-Accept digest is
/// included so real ws clients accept the handshake. Returns null when `buf`
/// does not fit the head.
pub fn upgradeHead(proto: []const u8, ws_key: []const u8, buf: []u8) ?[]const u8 {
    var used: usize = 0;
    used += put(buf[used..], "HTTP/1.1 101 Switching Protocols\r\n") orelse return null;
    used += (std.fmt.bufPrint(buf[used..], "Upgrade: {s}\r\n", .{std.mem.trim(u8, proto, " \t")}) catch return null).len;
    used += put(buf[used..], "Connection: Upgrade\r\n") orelse return null;
    if (isWebsocketProto(proto) and ws_key.len > 0) {
        var accept_buf: [28]u8 = undefined;
        const accept = acceptKey(ws_key, &accept_buf);
        // 101 responses carry neither Content-Length nor a body (RFC 9110
        // §9.4.2): the connection speaks the new protocol immediately after.
        used += (std.fmt.bufPrint(buf[used..], "Sec-WebSocket-Accept: {s}\r\n", .{accept}) catch return null).len;
    }
    used += put(buf[used..], "\r\n") orelse return null;
    return buf[0..used];
}

fn put(dst: []u8, src: []const u8) ?usize {
    if (src.len > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Decode one client frame from the front of `buf`. Client-to-server frames
/// MUST be masked (§5.1); the payload is unmasked in place and `frame.payload`
/// borrows the buffer. Reserved bits (RSV1-3) must be zero — no extensions are
/// negotiated — and control payloads stay within 125 bytes.
pub fn decode(buf: []u8, frame: *Frame) DecodeResult {
    return decodeImpl(buf, frame, true);
}

/// Same as `decode` for server-side (unmasked) frames — used by tests to
/// round-trip encoded frames and available for raw-pipe use cases.
pub fn decodeUnmaskedOk(buf: []u8, frame: *Frame) DecodeResult {
    return decodeImpl(buf, frame, false);
}

fn decodeImpl(buf: []u8, frame: *Frame, require_mask: bool) DecodeResult {
    if (buf.len < 2) return .incomplete;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = b0 & 0x80 != 0;
    const rsv: u8 = b0 & 0x70;
    const opcode_raw: u4 = @truncate(b0);
    const masked = b1 & 0x80 != 0;
    var payload_len: u64 = b1 & 0x7F;

    if (rsv != 0) return .malformed;
    const opcode: Opcode = @enumFromInt(opcode_raw);

    var header_len: usize = 2;
    switch (payload_len) {
        126 => {
            if (buf.len < 4) return .incomplete;
            payload_len = std.mem.readInt(u16, buf[2..4], .big);
            header_len = 4;
        },
        127 => {
            if (buf.len < 10) return .incomplete;
            payload_len = std.mem.readInt(u64, buf[2..10], .big);
            header_len = 10;
        },
        else => {},
    }

    // Control frames are small by definition (§5.5) and must be FIN (§5.5.1).
    if (opcode.isControl()) {
        if (payload_len > 125 or !fin) return .malformed;
    }

    var mask_key: [4]u8 = undefined;
    if (masked) {
        if (buf.len < header_len + 4) return .incomplete;
        @memcpy(&mask_key, buf[header_len..][0..4]);
        header_len += 4;
    } else if (require_mask) {
        // Every client frame must be masked (§5.1); a bare frame from the
        // wire is a protocol violation.
        return .malformed;
    }

    if (payload_len > buf.len - header_len) return .incomplete;
    const plen: usize = @intCast(payload_len);
    const payload = buf[header_len..][0..plen];
    if (masked) {
        for (payload, 0..) |*c, i| c.* ^= mask_key[i % 4];
    }

    frame.* = .{
        .fin = fin,
        .opcode = opcode,
        .payload = payload,
        .total_len = header_len + plen,
    };
    return .ok;
}

/// Encode a server-to-client frame head (never masked) into `buf` (at least
/// 10 bytes); returns the written prefix. Payload bytes follow separately.
pub fn encodeHead(opcode: Opcode, payload_len: usize, buf: *[10]u8) []const u8 {
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (payload_len < 126) {
        buf[1] = @intCast(payload_len);
        return buf[0..2];
    }
    if (payload_len <= 0xFFFF) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        return buf[0..4];
    }
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], payload_len, .big);
    return buf[0..10];
}

test "acceptKey matches the RFC 6455 section 1.3 example" {
    var out: [28]u8 = undefined;
    const got = acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "upgradeHead carries proto, connection and the accept digest, no body framing" {
    var buf: [160]u8 = undefined;
    const head = upgradeHead("websocket", "dGhlIHNhbXBsZSBub25jZQ==", &buf) orelse return error.NoSpace;
    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n",
        head,
    );
}

test "upgradeHead skips the digest for non-websocket protocols" {
    var buf: [160]u8 = undefined;
    const head = upgradeHead("h2c", "", &buf) orelse return error.NoSpace;
    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\n",
        head,
    );
    try std.testing.expect(isWebsocketProto("WebSocket"));
    try std.testing.expect(!isWebsocketProto("h2c"));
}

test "decode reads the spec's masked Hello frame" {
    // RFC 6455 §5.7: a masked text frame carrying "Hello".
    const wire = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var buf = wire;
    var frame = Frame{};
    try std.testing.expectEqual(DecodeResult.ok, decode(&buf, &frame));
    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqual(@as(usize, wire.len), frame.total_len);
    try std.testing.expectEqualStrings("Hello", frame.payload);
}

test "decode reports incomplete for truncated frames" {
    var buf = [_]u8{ 0x81, 0x85, 0x01, 0x02 };
    var frame = Frame{};
    try std.testing.expectEqual(DecodeResult.incomplete, decode(&buf, &frame));

    // 16-bit length announced but payload missing.
    var big = [_]u8{ 0x82, 0xFE, 0x01, 0x00, 0xAA, 0xBB, 0xCC, 0xDD } ++ [_]u8{0} ** 200;
    big[2] = 0x01;
    big[3] = 0x00;
    try std.testing.expectEqual(DecodeResult.incomplete, decode(big[0 .. 8 + 100], &frame));
}

test "decode rejects reserved bits, bare frames and oversized control frames" {
    var frame = Frame{};

    // RSV1 set.
    var rsv = [_]u8{ 0xC1, 0x85, 0, 0, 0, 0 } ++ [_]u8{0} ** 5;
    try std.testing.expectEqual(DecodeResult.malformed, decode(&rsv, &frame));

    // Unmasked client frame (§5.1 violation).
    var bare = [_]u8{ 0x81, 0x05 } ++ "Hello".*;
    try std.testing.expectEqual(DecodeResult.malformed, decode(&bare, &frame));
    try std.testing.expectEqual(DecodeResult.ok, decodeUnmaskedOk(&bare, &frame));

    // Control frame with a 200-byte payload (cap is 125).
    var huge_ping = [_]u8{ 0x89, 0xFE, 0x00, 0xC8, 0, 0, 0, 0 } ++ [_]u8{0} ** 200;
    try std.testing.expectEqual(DecodeResult.malformed, decode(&huge_ping, &frame));

    // Fragmented ping (FIN clear on a control frame).
    var frag_ping = [_]u8{ 0x09, 0x80, 0, 0, 0, 0 };
    try std.testing.expectEqual(DecodeResult.malformed, decode(&frag_ping, &frame));
}

test "decode handles 16-bit and 64-bit payload lengths" {
    var frame = Frame{};

    // Server-encoded (unmasked ok) 300-byte binary frame -> 16-bit length.
    var buf: [4 + 300]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 126;
    std.mem.writeInt(u16, buf[2..4], 300, .big);
    @memset(buf[4..], 0xAB);
    try std.testing.expectEqual(DecodeResult.ok, decodeUnmaskedOk(&buf, &frame));
    try std.testing.expectEqual(@as(usize, 304), frame.total_len);
    try std.testing.expectEqual(@as(usize, 300), frame.payload.len);
    try std.testing.expectEqual(@as(u8, 0xAB), frame.payload[299]);

    // 70000-byte payload -> 64-bit length.
    var heap = try std.testing.allocator.alloc(u8, 10 + 70000);
    defer std.testing.allocator.free(heap);
    heap[0] = 0x82;
    heap[1] = 127;
    std.mem.writeInt(u64, heap[2..10], 70000, .big);
    @memset(heap[10..], 0xCD);
    try std.testing.expectEqual(DecodeResult.ok, decodeUnmaskedOk(heap, &frame));
    try std.testing.expectEqual(@as(usize, 70010), frame.total_len);
    try std.testing.expectEqual(@as(usize, 70000), frame.payload.len);
}

test "encodeHead produces frames decode can read back" {
    var frame = Frame{};
    inline for (.{ 5, 125, 126, 65535, 65536 }) |len| {
        var head_buf: [10]u8 = undefined;
        var storage: [65536]u8 = undefined;
        const head = encodeHead(.binary, len, &head_buf);
        const payload = storage[0..len];
        @memset(payload, 0x42);
        var wire: [65546]u8 = undefined;
        @memcpy(wire[0..head.len], head);
        @memcpy(wire[head.len..][0..payload.len], payload);
        try std.testing.expectEqual(DecodeResult.ok, decodeUnmaskedOk(wire[0 .. head.len + payload.len], &frame));
        try std.testing.expectEqual(len, frame.total_len - head.len);
        try std.testing.expectEqual(@as(usize, len), frame.payload.len);
        try std.testing.expectEqual(Opcode.binary, frame.opcode);
        try std.testing.expect(frame.fin);
    }
}
