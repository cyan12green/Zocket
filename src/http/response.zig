const std = @import("std");
const buffer_mod = @import("../net/buffer.zig");

const posix_fd = std.posix.fd_t;

pub const Status = enum(u16) {
    ok = 200,
    partial_content = 206,
    moved_permanently = 301,
    found = 302,
    not_modified = 304,
    forbidden = 403,
    range_not_satisfiable = 416,
    bad_request = 400,
    not_found = 404,
    payload_too_large = 413,
    header_too_large = 431,
    internal_error = 500,
    not_implemented = 501,
    bad_gateway = 502,

    pub fn reasonPhrase(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .partial_content => "Partial Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .not_modified => "Not Modified",
            .forbidden => "Forbidden",
            .range_not_satisfiable => "Range Not Satisfiable",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .payload_too_large => "Payload Too Large",
            .header_too_large => "Request Header Fields Too Large",
            .internal_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
        };
    }
};

pub const max_headers = 8;

/// digits4[i] holds the 4 ASCII digits of i (0..9999) packed so that a
/// little-endian write of the u32 produces "dddd" in memory order:
/// byte0 = thousands, byte1 = hundreds, byte2 = tens, byte3 = units.
const digits4_table = blk: {
    @setEvalBranchQuota(100_000);
    var t: [10000]u32 = undefined;
    for (0..10000) |i| {
        const d0: u32 = i % 10;
        const d1: u32 = (i / 10) % 10;
        const d2: u32 = (i / 100) % 10;
        const d3: u32 = i / 1000;
        t[i] = @as(u32, '0' + d3) |
            (@as(u32, '0' + d2) << 8) |
            (@as(u32, '0' + d1) << 16) |
            (@as(u32, '0' + d0) << 24);
    }
    break :blk t;
};

/// Number of decimal digits of `v` (>= 1). Used for sizing headers without
/// running any format machinery.
pub fn digitCount(v: u64) usize {
    var n: usize = 1;
    var p: u64 = 10;
    while (p <= v) : (p *= 10) {
        n += 1;
        if (p > std.math.maxInt(u64) / 10) break;
    }
    return n;
}

/// Write the decimal representation of `v` into `buf` starting at `pos`,
/// returning the position just past the digits. Caller guarantees space
/// (digitCount(v) bytes). 4 digits per step via the lookup table; the
/// leading block (1..4 digits) is written without leading zeros.
pub fn formatUInt(buf: []u8, pos: usize, v: u64) usize {
    const n = digitCount(v);
    var i = pos + n;
    var x = v;
    while (x >= 10000) : (x /= 10000) {
        i -= 4;
        std.mem.writeInt(u32, buf[i..][0..4], digits4_table[@intCast(x % 10000)], .little);
    }
    const r: u32 = @intCast(x);
    const block = digits4_table[r];
    if (r >= 1000) {
        i -= 4;
        std.mem.writeInt(u32, buf[i..][0..4], block, .little);
    } else if (r >= 100) {
        i -= 3;
        buf[i] = @truncate(block >> 8);
        buf[i + 1] = @truncate(block >> 16);
        buf[i + 2] = @truncate(block >> 24);
    } else if (r >= 10) {
        i -= 2;
        buf[i] = @truncate(block >> 16);
        buf[i + 1] = @truncate(block >> 24);
    } else {
        i -= 1;
        buf[i] = @truncate(block >> 24);
    }
    return pos + n;
}

/// Reason phrase for an arbitrary status code (comptime templates): known
/// codes map to their phrases, unknown ones to the generic fallback.
pub fn reasonPhraseForCode(comptime code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "Unknown",
    };
}

/// Minimal HTTP/1.1 response builder. Content-Length is always written, so
/// serialization is unambiguous and keep-alive safe. The full response is
/// serialized as one contiguous block (head + body) into the send buffer, so a
/// single write() flushes it — the writev optimization is deferred until the
/// body needs to stay zero-copy.
pub const Response = struct {
    status: Status,
    body: []const u8 = &.{},
    headers: [max_headers]Header = undefined,
    header_count: usize = 0,
    /// True when `body` was allocated by a module (e.g. gzip) and the caller
    /// must free it after serialising.
    body_owned: bool = false,
    /// Scratch space for module-generated header values (e.g. formatted
    /// `Cache-Control: max-age=N`). Valid until the response is serialised;
    /// the response itself lives on the caller's stack for the request.
    scratch: [96]u8 = undefined,
    scratch_used: usize = 0,
    /// sendfile body (Milestone 14): when set, the body is pushed from the
    /// file directly into the socket instead of being copied through
    /// userspace. The caller (reactor) takes ownership of `file_fd`.
    body_from_file: bool = false,
    file_fd: posix_fd = -1,
    file_offset: u64 = 0,
    file_len: u64 = 0,

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub fn init(status: Status) Response {
        return .{ .status = status };
    }

    /// Set a header, appending it to the header list. The parser's
    /// `header_hasher` is available for dedup (`setHeader` + hash compare)
    /// where the caller controls header names; the pipeline's order tests
    /// rely on append semantics, so no implicit dedup happens here.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
        std.debug.assert(self.header_count < max_headers);
        self.headers[self.header_count] = .{ .name = name, .value = value };
        self.header_count += 1;
    }

    /// Set a header whose value is formatted into the response's scratch
    /// space (safe: the response outlives the write). Drops the header if the
    /// scratch is exhausted.
    pub fn setHeaderFmt(self: *Response, comptime name: []const u8, comptime fmt: []const u8, args: anytype) void {
        const value = std.fmt.bufPrint(self.scratch[self.scratch_used..], fmt, args) catch return;
        self.scratch_used += value.len;
        self.setHeader(name, value);
    }

    pub fn setBody(self: *Response, body: []const u8) void {
        self.body = body;
    }

    /// Exact number of bytes `write` will emit. Pure arithmetic: no format
    /// machinery, and no second formatting pass at write time.
    pub fn wireSize(self: *const Response) usize {
        return self.headWireSize(self.body.len) + self.body.len;
    }

    /// Size of the head only (status line + headers + Content-Length +
    /// blank line), for HEAD and sendfile bodies whose bytes never sit in
    /// `body`.
    fn headWireSize(self: *const Response, content_length: usize) usize {
        var size: usize = 9 + // "HTTP/1.1 "
            digitCount(@intFromEnum(self.status)) + 1 + self.status.reasonPhrase().len + 2;
        for (self.headers[0..self.header_count]) |h| {
            size += h.name.len + 2 + h.value.len + 2;
        }
        size += 16 + digitCount(content_length) + 4; // "Content-Length: " + digits + "\r\n\r\n"
        return size;
    }

    /// Single-pass head serialisation over any sink exposing
    /// `writeAll([]const u8) !void`. Integers go through `formatUInt` (no
    /// format-string machinery, no separate sizing pass).
    fn writeHeadTo(self: *const Response, sink: anytype, content_length: usize) !void {
        var num: [24]u8 = undefined;
        try sink.writeAll("HTTP/1.1 ");
        try sink.writeAll(num[0..formatUInt(&num, 0, @intFromEnum(self.status))]);
        try sink.writeAll(" ");
        try sink.writeAll(self.status.reasonPhrase());
        try sink.writeAll("\r\n");
        for (self.headers[0..self.header_count]) |h| {
            try sink.writeAll(h.name);
            try sink.writeAll(": ");
            try sink.writeAll(h.value);
            try sink.writeAll("\r\n");
        }
        try sink.writeAll("Content-Length: ");
        try sink.writeAll(num[0..formatUInt(&num, 0, content_length)]);
        try sink.writeAll("\r\n\r\n");
    }

    /// Serialize the response into any sink exposing
    /// `writeAll([]const u8) !void`.
    pub fn write(self: *const Response, sink: anytype) !void {
        try self.writeHeadTo(sink, self.body.len);
        try sink.writeAll(self.body);
    }

    /// Serialize into a connection send buffer. Fails with `error.BufferFull`
    /// (leaving the buffer untouched) if it does not fit; callers should
    /// compact or grow first. One capacity check for the whole response, then
    /// raw memcpy writes — no per-segment checks, no format machinery.
    pub fn writeToBuffer(self: *const Response, buf: *buffer_mod.Buffer) !void {
        const needed = self.wireSize();
        if (needed > buf.availableWrite()) return error.BufferFull;
        try self.write(RawSink{ .buf = buf });
    }

    /// Serialize only the head (status line + headers + blank line) into a
    /// connection send buffer. `Content-Length` still reflects the body
    /// length, but the body bytes are not written — the HEAD method response
    /// (RFC 9110 §9.3.2). Same framing and sizes as `write`, minus the body.
    pub fn writeHeadToBuffer(self: *const Response, buf: *buffer_mod.Buffer) !void {
        return writeHeadToBufferWithLength(self, buf, self.body.len);
    }

    /// Head-only serialisation with an explicit Content-Length (sendfile
    /// bodies, whose bytes never sit in `body`).
    pub fn writeHeadToBufferWithLength(self: *const Response, buf: *buffer_mod.Buffer, content_length: usize) !void {
        const needed = self.headWireSize(content_length);
        if (needed > buf.availableWrite()) return error.BufferFull;
        try self.writeHeadTo(RawSink{ .buf = buf }, content_length);
    }
};

/// Adapter writing into a net buffer. Errors instead of silently truncating
/// (Buffer.writeSlice returns the partial count).
pub const BufferSink = struct {
    buf: *buffer_mod.Buffer,

    pub fn writeAll(self: BufferSink, bytes: []const u8) !void {
        if (bytes.len > self.buf.availableWrite()) return error.BufferFull;
        _ = self.buf.writeSlice(bytes);
    }
};

/// Sink for the send-buffer path after `writeToBuffer` has done its single
/// capacity check: writes are raw memcpy's with no per-segment checks.
const RawSink = struct {
    buf: *buffer_mod.Buffer,

    pub fn writeAll(self: RawSink, bytes: []const u8) !void {
        const pos = self.buf.write_pos;
        @memcpy(self.buf.data[pos..][0..bytes.len], bytes);
        self.buf.write_pos = pos + bytes.len;
    }
};

/// Adapter writing into a managed byte list (test / debugging helper).
pub const ListSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: ListSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const testing = std.testing;

fn serialize(allocator: std.mem.Allocator, resp: *const Response) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try resp.write(ListSink{ .list = &list, .allocator = allocator });
    const out = try allocator.dupe(u8, list.items);
    return out;
}

test "200 response with no body is byte-exact" {
    const allocator = testing.allocator;
    var resp = Response.init(.ok);
    const out = try serialize(allocator, &resp);
    defer allocator.free(out);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", out);
    try testing.expectEqual(out.len, resp.wireSize());
}

test "response with headers and body is byte-exact" {
    const allocator = testing.allocator;
    var resp = Response.init(.ok);
    resp.setHeader("Content-Type", "text/plain");
    resp.setHeader("Connection", "keep-alive");
    resp.setBody("hello http");
    const out = try serialize(allocator, &resp);
    defer allocator.free(out);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhello http",
        out,
    );
    try testing.expectEqual(out.len, resp.wireSize());
}

test "all statuses produce correct code and reason phrase" {
    const allocator = testing.allocator;
    const cases = [_]struct { status: Status, want: []const u8 }{
        .{ .status = .ok, .want = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .bad_request, .want = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .not_found, .want = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .payload_too_large, .want = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .header_too_large, .want = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .internal_error, .want = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n" },
        .{ .status = .not_implemented, .want = "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n" },
    };
    for (cases) |c| {
        var resp = Response.init(c.status);
        const out = try serialize(allocator, &resp);
        defer allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        try testing.expectEqual(out.len, resp.wireSize());
    }
}

test "body with CRLF and multi-byte content is written verbatim" {
    const allocator = testing.allocator;
    const body = "line1\r\nline2\r\n\x00\x01\xff";
    var resp = Response.init(.ok);
    resp.setBody(body);
    const out = try serialize(allocator, &resp);
    defer allocator.free(out);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 17\r\n\r\n" ++ body,
        out,
    );
    try testing.expectEqual(out.len, resp.wireSize());
}

test "writeToBuffer produces identical bytes" {
    const allocator = testing.allocator;
    var resp = Response.init(.bad_request);
    resp.setBody("nope");
    const want = try serialize(allocator, &resp);
    defer allocator.free(want);

    const buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit(allocator);
    try resp.writeToBuffer(buf);
    try testing.expectEqualStrings(want, buf.peek());
    try testing.expectEqual(want.len, buf.availableRead());
}

test "writeToBuffer fails cleanly when the buffer is too small" {
    const allocator = testing.allocator;
    var resp = Response.init(.ok);
    resp.setBody("payload that cannot fit");

    const buf = try buffer_mod.Buffer.initFixed(allocator, 16);
    defer buf.deinit(allocator);
    try testing.expectError(error.BufferFull, resp.writeToBuffer(buf));
    // Nothing was written.
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
    try testing.expectEqual(@as(usize, 0), buf.write_pos);
}

test "writeHeadToBuffer writes head only with full Content-Length" {
    const allocator = testing.allocator;
    var resp = Response.init(.ok);
    resp.setHeader("Connection", "keep-alive");
    resp.setBody("the body that must not be sent");

    const buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit(allocator);
    try resp.writeHeadToBuffer(buf);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 30\r\n\r\n",
        buf.peek(),
    );
    // Head-only serialization is exactly the full wire size minus the body.
    try testing.expectEqual(resp.wireSize() - resp.body.len, buf.availableRead());
}

test "wireSize matches written bytes across configurations" {
    const allocator = testing.allocator;
    var resp = Response.init(.header_too_large);
    resp.setHeader("X-A", "1");
    resp.setHeader("X-B", "two");
    resp.setBody("12345");
    const out = try serialize(allocator, &resp);
    defer allocator.free(out);
    try testing.expectEqual(out.len, resp.wireSize());

    var resp2 = Response.init(.not_implemented);
    resp2.setBody("");
    const out2 = try serialize(allocator, &resp2);
    defer allocator.free(out2);
    try testing.expectEqual(out2.len, resp2.wireSize());
    try testing.expectEqualStrings("HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n", out2);
}
