const std = @import("std");

/// HTTP/2 frame layer (RFC 9113 §4 and §6).
///
/// All frame types, the 9-byte frame header, and a small encoder for the
/// server-side frames the session emits. Frame parsing is byte-exact with
/// the RFC: the length is a 24-bit value, the stream id the low 31 bits of
/// a 32-bit field.
pub const max_frame_size: u24 = 16384;
pub const default_max_frame_size: u24 = 16384;

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    /// A type byte outside 0x0..0x9 (RFC 9113 §4.1: unknown types MUST be
    /// ignored and discarded).
    unknown = 0xff,

    /// Comptime-built decode table (hash-dispatch style): type byte -> FrameType with
    /// zero branches per lookup; unknown/undefined bytes map to `.unknown`
    /// (RFC 9113 §4.1: they MUST be ignored and discarded).
    pub const decode_table: [256]FrameType = blk: {
        @setEvalBranchQuota(100000);
        var t = @as([256]FrameType, @splat(@as(FrameType, .unknown)));
        for (0..10) |i| t[i] = @enumFromInt(i);
        break :blk t;
    };

    /// Parse a type byte via the comptime decode table.
    pub fn fromByte(b: u8) FrameType {
        return decode_table[b];
    }
};

/// Flags per RFC 9113 §6.
pub const flags = struct {
    pub const end_stream = 0x1; // DATA, HEADERS
    pub const ack = 0x1; // SETTINGS, PING
    pub const end_headers = 0x4; // HEADERS, PUSH_PROMISE
    pub const padded = 0x8; // DATA, HEADERS, PUSH_PROMISE
    pub const priority = 0x20; // HEADERS
};

/// The 9-byte frame header (RFC 9113 §4.1).
pub const FrameHeader = struct {
    length: u24 = 0,
    type: FrameType = .data,
    flag_bits: u8 = 0,
    stream_id: u31 = 0,

    pub fn encode(self: FrameHeader, out: *[9]u8) void {
        out[0] = @intCast(self.length >> 16);
        out[1] = @intCast((self.length >> 8) & 0xff);
        out[2] = @intCast(self.length & 0xff);
        out[3] = @intFromEnum(self.type);
        out[4] = self.flag_bits;
        out[5] = @intCast((self.stream_id >> 24) & 0x7f);
        out[6] = @intCast((self.stream_id >> 16) & 0xff);
        out[7] = @intCast((self.stream_id >> 8) & 0xff);
        out[8] = @intCast(self.stream_id & 0xff);
    }
};

/// Parse a frame header from the connection buffer. Returns null when fewer
/// than 9 bytes are available.
pub fn parseHeader(buf: []const u8) ?FrameHeader {
    if (buf.len < 9) return null;
    const length: u24 = (@as(u24, buf[0]) << 16) | (@as(u24, buf[1]) << 8) | @as(u24, buf[2]);
    const stream_id: u31 = @intCast(((@as(u32, buf[5]) & 0x7f) << 24) | (@as(u32, buf[6]) << 16) | (@as(u32, buf[7]) << 8) | buf[8]);
    return .{
        .length = length,
        .type = FrameType.fromByte(buf[3]),
        .flag_bits = buf[4],
        .stream_id = stream_id,
    };
}

pub const Error = error{
    /// Frame length exceeds the negotiated peer max frame size.
    FrameTooLarge,
    /// A frame referenced an unknown or closed stream.
    UnknownStream,
    /// Connection-level protocol violation (RFC 9113 §5.4.1).
    ProtocolError,
};

// ---- server-side frame encoders ----

/// Append a SETTINGS frame (our settings, sent once after the preface).
pub fn writeSettings(sink: anytype, allocator: std.mem.Allocator, values: []const struct { id: u16, value: u32 }) !void {
    const payload_len: u24 = @intCast(values.len * 6);
    var hdr: [9]u8 = undefined;
    var fh = FrameHeader{ .length = payload_len, .type = .settings };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    for (values) |v| {
        var buf: [6]u8 = undefined;
        buf[0] = @intCast(v.id >> 8);
        buf[1] = @intCast(v.id & 0xff);
        buf[2] = @intCast((v.value >> 24) & 0xff);
        buf[3] = @intCast((v.value >> 16) & 0xff);
        buf[4] = @intCast((v.value >> 8) & 0xff);
        buf[5] = @intCast(v.value & 0xff);
        try sink.appendSlice(allocator, &buf);
    }
}

/// Append a PING ACK frame (payload copied from the received PING).
pub fn writePingAck(sink: anytype, allocator: std.mem.Allocator, payload: []const u8) !void {
    var hdr: [9]u8 = undefined;
    var fh = FrameHeader{ .length = 8, .type = .ping, .flag_bits = flags.ack };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    try sink.appendSlice(allocator, payload);
}

/// Append a GOAWAY frame (RFC 9113 §6.8).
pub fn writeGoaway(sink: anytype, allocator: std.mem.Allocator, last_stream: u31, err_code: u32, debug: []const u8) !void {
    const payload_len: u24 = @intCast(8 + debug.len);
    var hdr: [9]u8 = undefined;
    var fh = FrameHeader{ .length = payload_len, .type = .goaway };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    var buf: [8]u8 = undefined;
    buf[0] = @intCast((last_stream >> 24) & 0x7f);
    buf[1] = @intCast((last_stream >> 16) & 0xff);
    buf[2] = @intCast((last_stream >> 8) & 0xff);
    buf[3] = @intCast(last_stream & 0xff);
    buf[4] = @intCast((err_code >> 24) & 0xff);
    buf[5] = @intCast((err_code >> 16) & 0xff);
    buf[6] = @intCast((err_code >> 8) & 0xff);
    buf[7] = @intCast(err_code & 0xff);
    try sink.appendSlice(allocator, &buf);
    try sink.appendSlice(allocator, debug);
}

/// Append a RST_STREAM frame.
pub fn writeRstStream(sink: anytype, allocator: std.mem.Allocator, stream_id: u31, err_code: u32) !void {
    var hdr: [9]u8 = undefined;
    var fh = FrameHeader{ .length = 4, .type = .rst_stream, .stream_id = stream_id };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((err_code >> 24) & 0xff);
    buf[1] = @intCast((err_code >> 16) & 0xff);
    buf[2] = @intCast((err_code >> 8) & 0xff);
    buf[3] = @intCast(err_code & 0xff);
    try sink.appendSlice(allocator, &buf);
}

/// Append a WINDOW_UPDATE frame (RFC 9113 §6.9).
pub fn writeWindowUpdate(sink: anytype, allocator: std.mem.Allocator, stream_id: u31, increment: u32) !void {
    var hdr: [9]u8 = undefined;
    var fh = FrameHeader{ .length = 4, .type = .window_update, .stream_id = stream_id };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((increment >> 24) & 0x7f);
    buf[1] = @intCast((increment >> 16) & 0xff);
    buf[2] = @intCast((increment >> 8) & 0xff);
    buf[3] = @intCast(increment & 0xff);
    try sink.appendSlice(allocator, &buf);
}

/// Append a HEADERS frame (RFC 9113 §6.2): the HPACK block split at
/// `max_frame_size`-minus-9 boundaries into HEADERS + CONTINUATION frames.
pub fn writeHeaders(sink: anytype, allocator: std.mem.Allocator, stream_id: u31, hpack_block: []const u8, end_stream: bool, max_frame: u24) !void {
    const first_chunk = @min(hpack_block.len, max_frame);
    var hdr: [9]u8 = undefined;
    var flags_bits: u8 = flags.end_headers;
    if (end_stream) flags_bits |= flags.end_stream;
    var fh = FrameHeader{ .length = @intCast(first_chunk), .type = .headers, .flag_bits = flags_bits, .stream_id = stream_id };
    fh.encode(&hdr);
    try sink.appendSlice(allocator, &hdr);
    try sink.appendSlice(allocator, hpack_block[0..first_chunk]);
    var off = first_chunk;
    while (off < hpack_block.len) {
        const chunk = @min(hpack_block.len - off, max_frame);
        var cfh = FrameHeader{ .length = @intCast(chunk), .type = .continuation, .flag_bits = if (off + chunk >= hpack_block.len) flags.end_headers else 0, .stream_id = stream_id };
        cfh.encode(&hdr);
        try sink.appendSlice(allocator, &hdr);
        try sink.appendSlice(allocator, hpack_block[off .. off + chunk]);
        off += chunk;
    }
}

/// Append a DATA frame (RFC 9113 §6.1).
pub fn writeData(sink: anytype, allocator: std.mem.Allocator, stream_id: u31, payload: []const u8, end_stream: bool, max_frame: u24) !void {
    var hdr: [9]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(payload.len - off, max_frame);
        const is_last = off + chunk >= payload.len;
        const flag_bits: u8 = if (is_last and end_stream) flags.end_stream else 0;
        var fh = FrameHeader{ .length = @intCast(chunk), .type = .data, .flag_bits = flag_bits, .stream_id = stream_id };
        fh.encode(&hdr);
        try sink.appendSlice(allocator, &hdr);
        try sink.appendSlice(allocator, payload[off .. off + chunk]);
        off += chunk;
    }
    if (payload.len == 0 and end_stream) {
        var fh = FrameHeader{ .length = 0, .type = .data, .flag_bits = flags.end_stream, .stream_id = stream_id };
        fh.encode(&hdr);
        try sink.appendSlice(allocator, &hdr);
    }
}

const testing = std.testing;

test "frame header round-trips" {
    const h = FrameHeader{ .length = 16384, .type = .headers, .flag_bits = flags.end_headers | flags.end_stream, .stream_id = 3 };
    var buf: [9]u8 = undefined;
    h.encode(&buf);
    const back = parseHeader(&buf).?;
    try testing.expectEqual(@as(u24, 16384), back.length);
    try testing.expectEqual(FrameType.headers, back.type);
    try testing.expectEqual(flags.end_headers | flags.end_stream, back.flag_bits);
    try testing.expectEqual(@as(u31, 3), back.stream_id);
}

test "writeSettings emits correct payload" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try writeSettings(&buf, testing.allocator, &.{.{ .id = 4, .value = 65536 }});
    try testing.expectEqualSlices(u8, &.{ 0, 0, 6, 0x4, 0, 0, 0, 0, 0, 0, 4, 0, 1, 0, 0 }, buf.items);
}

test "writeHeaders splits large HPACK blocks into CONTINUATION" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const block = @as([40]u8, @splat(@as(u8, 0x82))); // 40 bytes
    try writeHeaders(&buf, testing.allocator, 5, &block, true, 16);
    // First HEADERS frame: 9 header + 16 payload. Then CONTINUATION frames.
    try testing.expect(buf.items.len > 9 + 16);
    const h0 = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.headers, h0.type);
    try testing.expectEqual(@as(u24, 16), h0.length);
    try testing.expectEqual(flags.end_headers | flags.end_stream, h0.flag_bits);
    const h1 = parseHeader(buf.items[9 + 16 ..][0..9]).?;
    try testing.expectEqual(FrameType.continuation, h1.type);
}

test "frame: short buffers and unknown types" {
    try testing.expect(parseHeader(&.{ 0, 0, 1 }) == null);
    try testing.expect(parseHeader(&.{}) == null);
    try testing.expectEqual(FrameType.data, FrameType.fromByte(0x0));
    try testing.expectEqual(FrameType.continuation, FrameType.fromByte(0x9));
    try testing.expectEqual(FrameType.unknown, FrameType.fromByte(0x0a));
    try testing.expectEqual(FrameType.unknown, FrameType.fromByte(0x63));
    try testing.expectEqual(FrameType.unknown, FrameType.fromByte(0xff));
    // Stream id masks the reserved bit (RFC 9113 §4.1).
    const h = parseHeader(&.{ 0, 0, 0, 0x1, 0x5, 0x80, 0, 0, 1 }).?;
    try testing.expectEqual(FrameType.headers, h.type);
    try testing.expectEqual(@as(u31, 1), h.stream_id);
    try testing.expectEqual(@as(u8, 0x5), h.flag_bits);
}

test "frame: writeSettings empty and multiple values" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try writeSettings(&buf, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 9), buf.items.len);
    const h = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.settings, h.type);
    try testing.expectEqual(@as(u24, 0), h.length);

    buf.clearRetainingCapacity();
    try writeSettings(&buf, testing.allocator, &.{ .{ .id = 1, .value = 4096 }, .{ .id = 4, .value = 65535 } });
    try testing.expectEqual(@as(usize, 9 + 12), buf.items.len);
    const h2 = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(@as(u24, 12), h2.length);
    // Second setting: id 4, value 65535.
    try testing.expectEqualSlices(u8, &.{ 0, 4, 0, 0, 0xff, 0xff }, buf.items[9 + 6 .. 9 + 12]);
}

test "frame: writePingAck echoes the payload" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try writePingAck(&buf, testing.allocator, &payload);
    try testing.expectEqual(@as(usize, 9 + 8), buf.items.len);
    const h = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.ping, h.type);
    try testing.expectEqual(flags.ack, h.flag_bits);
    try testing.expectEqual(@as(u24, 8), h.length);
    try testing.expectEqualSlices(u8, &payload, buf.items[9..]);
}

test "frame: writeGoaway carries last-stream, code and debug data" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try writeGoaway(&buf, testing.allocator, 7, 0x1, "bye");
    const h = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.goaway, h.type);
    try testing.expectEqual(@as(u24, 8 + 3), h.length);
    try testing.expectEqual(@as(u31, 0), h.stream_id);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 7, 0, 0, 0, 1 }, buf.items[9 .. 9 + 8]);
    try testing.expectEqualSlices(u8, "bye", buf.items[9 + 8 ..]);
}

test "frame: writeRstStream and writeWindowUpdate round-trip" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try writeRstStream(&buf, testing.allocator, 3, 0x8);
    const h = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.rst_stream, h.type);
    try testing.expectEqual(@as(u31, 3), h.stream_id);
    try testing.expectEqual(@as(u24, 4), h.length);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 8 }, buf.items[9..13]);

    buf.clearRetainingCapacity();
    try writeWindowUpdate(&buf, testing.allocator, 0, 0x7fffffff);
    const w = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.window_update, w.type);
    try testing.expectEqual(@as(u31, 0), w.stream_id);
    // Reserved bit masked: 0x7fffffff encodes with top bit clear.
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0xff, 0xff, 0xff }, buf.items[9..13]);
}

test "frame: writeData chunking and empty-body edge cases" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    // Empty body without END_STREAM emits nothing.
    try writeData(&buf, testing.allocator, 1, &.{}, false, 16);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
    // Empty body with END_STREAM emits one empty DATA frame.
    try writeData(&buf, testing.allocator, 1, &.{}, true, 16);
    try testing.expectEqual(@as(usize, 9), buf.items.len);
    const h0 = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(FrameType.data, h0.type);
    try testing.expectEqual(flags.end_stream, h0.flag_bits);
    try testing.expectEqual(@as(u31, 1), h0.stream_id);

    // Multi-chunk: 40 bytes at 16/frame, END_STREAM only on the last.
    buf.clearRetainingCapacity();
    const payload = @as([40]u8, @splat(@as(u8, 0x61)));
    try writeData(&buf, testing.allocator, 1, &payload, true, 16);
    try testing.expectEqual(@as(usize, 3 * 9 + 40), buf.items.len);
    var off: usize = 0;
    var chunks: usize = 0;
    while (off + 9 <= buf.items.len) {
        const fh = parseHeader(buf.items[off..][0..9]).?;
        try testing.expectEqual(FrameType.data, fh.type);
        chunks += 1;
        const last = off + 9 + fh.length >= buf.items.len;
        if (last) {
            try testing.expectEqual(flags.end_stream, fh.flag_bits);
            try testing.expectEqual(@as(u24, 8), fh.length);
        } else {
            try testing.expectEqual(@as(u8, 0), fh.flag_bits);
        }
        off += 9 + fh.length;
    }
    try testing.expectEqual(@as(usize, 3), chunks);

    // end_stream=false: no END_STREAM anywhere.
    buf.clearRetainingCapacity();
    try writeData(&buf, testing.allocator, 1, &payload, false, 64);
    const single = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(@as(u8, 0), single.flag_bits);
    try testing.expectEqual(@as(u24, 40), single.length);
}

test "frame: writeHeaders without END_STREAM omits the flag" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const block = @as([40]u8, @splat(@as(u8, 0x82)));
    try writeHeaders(&buf, testing.allocator, 5, &block, false, 16);
    const h0 = parseHeader(buf.items[0..9]).?;
    try testing.expectEqual(flags.end_headers, h0.flag_bits);
    // Last CONTINUATION still carries END_HEADERS.
    var off: usize = 0;
    var last_flags: u8 = 0;
    var last_type = FrameType.headers;
    while (off + 9 <= buf.items.len) {
        const fh = parseHeader(buf.items[off..][0..9]).?;
        last_flags = fh.flag_bits;
        last_type = fh.type;
        off += 9 + fh.length;
    }
    try testing.expectEqual(FrameType.continuation, last_type);
    try testing.expectEqual(flags.end_headers, last_flags);
    // Small block: single HEADERS, no CONTINUATION.
    buf.clearRetainingCapacity();
    try writeHeaders(&buf, testing.allocator, 5, &.{0x82}, true, 16384);
    try testing.expectEqual(@as(usize, 10), buf.items.len);
}

test "frame: max length and stream id round-trip" {
    const h = FrameHeader{ .length = 0xffffff, .type = .goaway, .flag_bits = 0xff, .stream_id = 0x7fffffff };
    var buf: [9]u8 = undefined;
    h.encode(&buf);
    const back = parseHeader(&buf).?;
    try testing.expectEqual(@as(u24, 0xffffff), back.length);
    try testing.expectEqual(@as(u31, 0x7fffffff), back.stream_id);
    try testing.expectEqual(@as(u8, 0xff), back.flag_bits);
}

test "frame: exact chunk boundaries and high-bit payload values" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    // A block exactly max_frame wide is one HEADERS frame, no CONTINUATION.
    const exact = @as([16]u8, @splat(@as(u8, 0x82)));
    try writeHeaders(&buf, testing.allocator, 7, &exact, false, 16);
    try testing.expectEqual(@as(usize, 9 + 16), buf.items.len);
    // One byte more spills a 1-byte CONTINUATION with END_HEADERS.
    buf.clearRetainingCapacity();
    const over = @as([17]u8, @splat(@as(u8, 0x82)));
    try writeHeaders(&buf, testing.allocator, 7, &over, true, 16);
    try testing.expectEqual(@as(usize, 2 * 9 + 17), buf.items.len);
    const c = parseHeader(buf.items[9 + 16 ..][0..9]).?;
    try testing.expectEqual(FrameType.continuation, c.type);
    try testing.expectEqual(@as(u24, 1), c.length);
    try testing.expectEqual(flags.end_headers, c.flag_bits);

    // Encoders carry all-ones payload fields byte-exactly.
    buf.clearRetainingCapacity();
    try writeSettings(&buf, testing.allocator, &.{.{ .id = 0xffff, .value = 0xffffffff }});
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, buf.items[9..]);
    buf.clearRetainingCapacity();
    try writeRstStream(&buf, testing.allocator, 0x7fffffff, 0xffffffff);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, buf.items[9..]);
    buf.clearRetainingCapacity();
    try writeWindowUpdate(&buf, testing.allocator, 0x7fffffff, 0);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buf.items[9..]);

    // GOAWAY without debug data still carries the 8-byte body.
    buf.clearRetainingCapacity();
    try writeGoaway(&buf, testing.allocator, 0, 0, "");
    try testing.expectEqual(@as(usize, 9 + 8), buf.items.len);
}
