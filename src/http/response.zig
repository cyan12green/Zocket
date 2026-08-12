const std = @import("std");
const buffer_mod = @import("../net/buffer.zig");

pub const Status = enum(u16) {
    ok = 200,
    partial_content = 206,
    not_modified = 304,
    range_not_satisfiable = 416,
    bad_request = 400,
    not_found = 404,
    payload_too_large = 413,
    header_too_large = 431,
    internal_error = 500,
    not_implemented = 501,

    pub fn reasonPhrase(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .partial_content => "Partial Content",
            .not_modified => "Not Modified",
            .range_not_satisfiable => "Range Not Satisfiable",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .payload_too_large => "Payload Too Large",
            .header_too_large => "Request Header Fields Too Large",
            .internal_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
        };
    }
};

pub const max_headers = 8;

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

    /// Exact number of bytes `write` will emit. Uses the same format strings
    /// as `write`, so the two can never drift.
    pub fn wireSize(self: *const Response) usize {
        var size: usize = std.fmt.count("HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(self.status),
            self.status.reasonPhrase(),
        });
        for (self.headers[0..self.header_count]) |h| {
            size += std.fmt.count("{s}: {s}\r\n", .{ h.name, h.value });
        }
        size += std.fmt.count("Content-Length: {d}\r\n", .{self.body.len});
        size += 2; // terminating blank line
        size += self.body.len;
        return size;
    }

    /// Serialize the response into any sink exposing
    /// `writeAll([]const u8) !void`.
    pub fn write(self: *const Response, sink: anytype) !void {
        var scratch: [96]u8 = undefined;
        try sink.writeAll(try std.fmt.bufPrint(&scratch, "HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(self.status),
            self.status.reasonPhrase(),
        }));
        for (self.headers[0..self.header_count]) |h| {
            try sink.writeAll(try std.fmt.bufPrint(&scratch, "{s}: {s}\r\n", .{ h.name, h.value }));
        }
        try sink.writeAll(try std.fmt.bufPrint(&scratch, "Content-Length: {d}\r\n\r\n", .{self.body.len}));
        try sink.writeAll(self.body);
    }

    /// Serialize into a connection send buffer. Fails with `error.BufferFull`
    /// (leaving the buffer untouched) if it does not fit; callers should
    /// compact or grow first.
    pub fn writeToBuffer(self: *const Response, buf: *buffer_mod.Buffer) !void {
        try self.write(BufferSink{ .buf = buf });
    }

    /// Serialize only the head (status line + headers + blank line) into a
    /// connection send buffer. `Content-Length` still reflects the body
    /// length, but the body bytes are not written — the HEAD method response
    /// (RFC 9110 §9.3.2). Same framing and sizes as `write`, minus the body.
    pub fn writeHeadToBuffer(self: *const Response, buf: *buffer_mod.Buffer) !void {
        var scratch: [96]u8 = undefined;
        const sink = BufferSink{ .buf = buf };
        try sink.writeAll(try std.fmt.bufPrint(&scratch, "HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(self.status),
            self.status.reasonPhrase(),
        }));
        for (self.headers[0..self.header_count]) |h| {
            try sink.writeAll(try std.fmt.bufPrint(&scratch, "{s}: {s}\r\n", .{ h.name, h.value }));
        }
        try sink.writeAll(try std.fmt.bufPrint(&scratch, "Content-Length: {d}\r\n\r\n", .{self.body.len}));
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
