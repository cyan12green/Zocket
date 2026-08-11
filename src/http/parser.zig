const std = @import("std");
const buffer_mod = @import("../net/buffer.zig");

const ascii = std.ascii;
const mem = std.mem;

pub const max_headers = 32;
/// Cap on the size of a single request-line or header line (RFC 7230 has no
/// hard limit; this bounds parser memory and maps to HTTP 431).
pub const max_line_bytes = 8192;

pub const Method = enum {
    get,
    head,
    post,
    put,
    delete,
    options,
    patch,
    unknown,
};

pub const Version = struct {
    major: u8,
    minor: u8,
};

/// Outcome of one parse() call. `.incomplete` means "need more bytes, call
/// again after recv". On `.complete` the parser has consumed the request from
/// the buffer and is ready for the next pipelined request; `req.body` is a
/// zero-copy slice into the buffer and is only valid until the connection's
/// next recv/compact.
pub const Outcome = union(enum) {
    incomplete,
    complete,
    bad_request, // 400
    header_too_large, // 431
    unsupported, // 501 (bad version, unknown method, chunked, ...)
    out_of_memory,
};

const Slot = struct {
    name_off: u32,
    name_len: u32,
    value_off: u32,
    value_len: u32,
};

/// A parsed HTTP/1.x request. Header names/values are copied into private
/// storage owned by this struct (safe against buffer compaction); the body is
/// a zero-copy view into the connection buffer.
pub const Request = struct {
    method: Method,
    target: []const u8,
    version: Version,
    keep_alive: bool,
    content_length: usize,
    body: []const u8,

    allocator: std.mem.Allocator,
    storage: std.ArrayList(u8),
    slots: [max_headers]Slot = undefined,
    header_count: usize = 0,
    transfer_chunked: bool = false,

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = .unknown,
            .target = "",
            .version = .{ .major = 1, .minor = 1 },
            .keep_alive = true,
            .content_length = 0,
            .body = &.{},
            .allocator = allocator,
            .storage = .empty,
        };
    }

    pub fn deinit(self: *Request) void {
        self.storage.deinit(self.allocator);
    }

    /// Prepare the struct for the next request on the same connection.
    pub fn reset(self: *Request) void {
        self.method = .unknown;
        self.target = "";
        self.version = .{ .major = 1, .minor = 1 };
        self.keep_alive = true;
        self.content_length = 0;
        self.body = &.{};
        self.storage.clearRetainingCapacity();
        self.header_count = 0;
        self.transfer_chunked = false;
    }

    pub fn headerCount(self: *const Request) usize {
        return self.header_count;
    }

    /// Case-insensitive lookup of a header value (first occurrence wins).
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.slots[0..self.header_count]) |s| {
            const n = self.storage.items[s.name_off..][0..s.name_len];
            if (ascii.eqlIgnoreCase(n, name)) {
                return self.storage.items[s.value_off..][0..s.value_len];
            }
        }
        return null;
    }

    /// Value of the i-th header in arrival order.
    pub fn headerAt(self: *const Request, i: usize) struct { name: []const u8, value: []const u8 } {
        const s = self.slots[i];
        return .{
            .name = self.storage.items[s.name_off..][0..s.name_len],
            .value = self.storage.items[s.value_off..][0..s.value_len],
        };
    }

    fn addHeader(self: *Request, name: []const u8, value: []const u8) error{ Malformed, HeaderCountExceeded, OutOfMemory }!void {
        if (self.header_count >= max_headers) return error.HeaderCountExceeded;

        const n = mem.trim(u8, name, " \t");
        const v = mem.trim(u8, value, " \t");
        if (n.len == 0) return error.Malformed;

        if (ascii.eqlIgnoreCase(n, "content-length")) {
            self.content_length = std.fmt.parseInt(usize, v, 10) catch return error.Malformed;
        } else if (ascii.eqlIgnoreCase(n, "transfer-encoding")) {
            if (containsIgnoreCase(v, "chunked")) self.transfer_chunked = true;
        }

        const name_off = self.storage.items.len;
        try self.storage.appendSlice(self.allocator, n);
        const value_off = self.storage.items.len;
        try self.storage.appendSlice(self.allocator, v);

        self.slots[self.header_count] = .{
            .name_off = @intCast(name_off),
            .name_len = @intCast(n.len),
            .value_off = @intCast(value_off),
            .value_len = @intCast(v.len),
        };
        self.header_count += 1;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn parseMethod(tok: []const u8) Method {
    if (ascii.eqlIgnoreCase(tok, "GET")) return .get;
    if (ascii.eqlIgnoreCase(tok, "HEAD")) return .head;
    if (ascii.eqlIgnoreCase(tok, "POST")) return .post;
    if (ascii.eqlIgnoreCase(tok, "PUT")) return .put;
    if (ascii.eqlIgnoreCase(tok, "DELETE")) return .delete;
    if (ascii.eqlIgnoreCase(tok, "OPTIONS")) return .options;
    if (ascii.eqlIgnoreCase(tok, "PATCH")) return .patch;
    return .unknown;
}

fn parseVersion(tok: []const u8) ?Version {
    const http_prefix = "HTTP/";
    if (!mem.startsWith(u8, tok, http_prefix)) return null;
    const rest = tok[http_prefix.len..];
    const dot = mem.indexOfScalar(u8, rest, '.') orelse return null;
    if (dot == 0 or dot + 1 >= rest.len) return null;
    const major = std.fmt.parseInt(u8, rest[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u8, rest[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

/// Incremental HTTP/1.x request parser. State lives here across recv calls;
/// the connection buffer is used as the accumulation buffer (partial lines
/// stay in the buffer; this parser never blocks).
///
/// Ownership contract:
/// - The parser advances the buffer's read position as it consumes complete
///   lines / the body; the connection handler must not touch the buffer's read
///   position while a request is being parsed.
/// - On `.complete`, `req.body` is a slice into the buffer, valid until the
///   next recv/compact on that buffer.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    state: State = .request_line,
    line: std.ArrayList(u8),
    body_remaining: usize = 0,

    const State = enum { request_line, headers, body };

    const LineError = error{ TooLong, OutOfMemory };

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .line = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.allocator);
    }

    /// Reset parse state for the next request (keep-alive / pipelining).
    pub fn reset(self: *Parser) void {
        self.state = .request_line;
        self.line.clearRetainingCapacity();
        self.body_remaining = 0;
    }

    fn lineErrorToOutcome(e: LineError) Outcome {
        return switch (e) {
            error.TooLong => .header_too_large,
            error.OutOfMemory => .out_of_memory,
        };
    }

    pub fn parse(self: *Parser, buf: *buffer_mod.Buffer, req: *Request) Outcome {
        while (true) switch (self.state) {
            .request_line => {
                const line = (self.readLine(buf) catch |e| return lineErrorToOutcome(e)) orelse return .incomplete;
                switch (line) {
                    .line_data => |l| {
                        // Lenient: skip stray empty lines before the request line.
                        if (l.len == 0) continue;
                        if (self.parseRequestLine(l, req)) |err| return err;
                        self.state = .headers;
                        // clearRetainingCapacity memsets the memory; only call
                        // it after the line slice has been consumed.
                        self.line.clearRetainingCapacity();
                    },
                }
            },
            .headers => {
                const line = (self.readLine(buf) catch |e| return lineErrorToOutcome(e)) orelse return .incomplete;
                switch (line) {
                    .line_data => |l| {
                        if (l.len == 0) {
                            // End of headers.
                            if (req.transfer_chunked) return .unsupported;
                            finalizeKeepAlive(req);
                            if (req.content_length > 0) {
                                self.body_remaining = req.content_length;
                                self.state = .body;
                                continue;
                            }
                            req.body = &.{};
                            self.reset();
                            return .complete;
                        }
                        if (mem.indexOfScalar(u8, l, ':')) |colon| {
                            req.addHeader(l[0..colon], l[colon + 1 ..]) catch |err| {
                                return switch (err) {
                                    error.Malformed => .bad_request,
                                    error.HeaderCountExceeded => .header_too_large,
                                    error.OutOfMemory => .out_of_memory,
                                };
                            };
                        } else {
                            return .bad_request;
                        }
                        // clearRetainingCapacity memsets the memory; only call
                        // it after the line slice has been consumed.
                        self.line.clearRetainingCapacity();
                    },
                }
            },
            .body => {
                if (buf.availableRead() >= self.body_remaining) {
                    req.body = buf.peek()[0..self.body_remaining];
                    buf.consume(self.body_remaining);
                    self.reset();
                    return .complete;
                }
                return .incomplete;
            },
        };
    }

    fn parseRequestLine(self: *Parser, line: []const u8, req: *Request) ?Outcome {
        var it = mem.tokenizeAny(u8, line, " \t");
        const method_tok = it.next() orelse return .bad_request;
        const target_tok = it.next() orelse return .bad_request;
        const version_tok = it.next() orelse return .bad_request;

        req.method = parseMethod(method_tok);
        if (req.method == .unknown) return .unsupported;

        const version = parseVersion(version_tok) orelse return .unsupported;
        if (version.major != 1) return .unsupported;
        req.version = version;

        const target_off = req.storage.items.len;
        req.storage.appendSlice(self.allocator, target_tok) catch return .out_of_memory;
        req.target = req.storage.items[target_off..];
        return null;
    }

    const Line = union(enum) {
        line_data: []const u8,
    };

    /// Read one line (terminated by '\n', tolerating a preceding '\r') from the
    /// buffer, accumulating partial lines internally. The returned slice is
    /// only valid until the caller clears `self.line` (or the next readLine).
    fn readLine(self: *Parser, buf: *buffer_mod.Buffer) LineError!?Line {
        const avail = buf.peek();
        if (mem.indexOfScalar(u8, avail, '\n')) |i| {
            var line = avail[0..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (self.line.items.len + line.len > max_line_bytes) return error.TooLong;
            try self.line.appendSlice(self.allocator, line);
            buf.consume(i + 1);
            // The '\r' may have arrived in a previous chunk (TCP split between
            // the '\r' and '\n' of a terminator); strip it from the accumulated
            // line as well.
            const items = self.line.items;
            if (items.len > 0 and items[items.len - 1] == '\r') {
                return .{ .line_data = items[0 .. items.len - 1] };
            }
            return .{ .line_data = items };
        }
        if (self.line.items.len + avail.len > max_line_bytes) return error.TooLong;
        try self.line.appendSlice(self.allocator, avail);
        buf.consume(avail.len);
        return null;
    }
};

fn finalizeKeepAlive(req: *Request) void {
    var close = false;
    var keep = false;
    for (0..req.headerCount()) |i| {
        const h = req.headerAt(i);
        if (!ascii.eqlIgnoreCase(h.name, "connection")) continue;
        var tokens = mem.tokenizeAny(u8, h.value, ",");
        while (tokens.next()) |t| {
            const tok = mem.trim(u8, t, " \t");
            if (ascii.eqlIgnoreCase(tok, "close")) close = true;
            if (ascii.eqlIgnoreCase(tok, "keep-alive")) keep = true;
        }
    }
    const default_keep = req.version.major == 1 and req.version.minor >= 1;
    req.keep_alive = if (default_keep) !close else keep;
}

const testing = std.testing;

fn fill(allocator: std.mem.Allocator, bytes: []const u8) !*buffer_mod.Buffer {
    const buf = try buffer_mod.Buffer.init(allocator);
    _ = buf.writeSlice(bytes);
    return buf;
}

test "simple GET request" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqual(Method.get, req.method);
    try testing.expectEqualStrings("/", req.target);
    try testing.expectEqual(@as(u8, 1), req.version.major);
    try testing.expectEqual(@as(u8, 1), req.version.minor);
    try testing.expect(req.keep_alive);
    try testing.expectEqual(@as(usize, 0), req.content_length);
    try testing.expectEqualStrings("example.com", req.header("host").?);
    try testing.expectEqual(@as(usize, 1), req.headerCount());
    try testing.expectEqual(@as(usize, 0), req.body.len);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "POST request with body" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqual(Method.post, req.method);
    try testing.expectEqualStrings("/submit", req.target);
    try testing.expectEqual(@as(usize, 5), req.content_length);
    try testing.expectEqualStrings("hello", req.body);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "body may contain CRLFCRLF (length-based, not line-based)" {
    const allocator = testing.allocator;
    const body = "ab\r\n\r\ncd";
    var wire_buf: [128]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const buf = try fill(allocator, wire);
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings(body, req.body);
}

test "incremental feeding at every byte boundary" {
    const allocator = testing.allocator;
    const wire = "POST /inc HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello";

    var split: usize = 0;
    while (split < wire.len) : (split += 1) {
        const buf = try fill(allocator, wire[0..split]);
        defer buf.deinit(allocator);

        var req = Request.init(allocator);
        defer req.deinit();
        var parser = Parser.init(allocator);
        defer parser.deinit();

        try testing.expectEqual(Outcome.incomplete, parser.parse(buf, &req));
        _ = buf.writeSlice(wire[split..]);
        try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
        try testing.expectEqualStrings("/inc", req.target);
        try testing.expectEqualStrings("hello", req.body);
    }
}

test "pipelined requests on one buffer" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("/a", req.target);

    req.reset();
    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("/b", req.target);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "keep-alive semantics" {
    const allocator = testing.allocator;
    const cases = [_]struct { wire: []const u8, keep: bool }{
        .{ .wire = "GET / HTTP/1.1\r\n\r\n", .keep = true }, // 1.1 default
        .{ .wire = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .keep = false },
        .{ .wire = "GET / HTTP/1.1\r\nConnection: keep-alive, upgrade\r\n\r\n", .keep = true },
        .{ .wire = "GET / HTTP/1.0\r\n\r\n", .keep = false }, // 1.0 default
        .{ .wire = "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", .keep = true },
        .{ .wire = "GET / HTTP/1.0\r\nConnection: CLOSE\r\n\r\n", .keep = false },
    };
    for (cases) |c| {
        const buf = try fill(allocator, c.wire);
        defer buf.deinit(allocator);
        var req = Request.init(allocator);
        defer req.deinit();
        var parser = Parser.init(allocator);
        defer parser.deinit();
        try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
        try testing.expectEqual(c.keep, req.keep_alive);
    }
}

test "header value trimming and case-insensitive lookup" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET / HTTP/1.1\r\nhOsT:   Example.com  \r\nX-A: 1\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("Example.com", req.header("HOST").?);
    try testing.expectEqualStrings("1", req.header("x-a").?);
    try testing.expectEqual(@as(?[]const u8, null), req.header("missing"));
}

test "bare LF line endings tolerated" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET / HTTP/1.1\nHost: x\n\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("/", req.target);
    try testing.expectEqualStrings("x", req.header("host").?);
}

test "malformed request line and headers yield 400" {
    const allocator = testing.allocator;
    const bad_wires = [_][]const u8{
        "GET\r\n\r\n", // missing target + version
        "GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
        "GET / HTTP/1.1\r\n: novalue\r\n\r\n",
    };
    for (bad_wires) |wire| {
        const buf = try fill(allocator, wire);
        defer buf.deinit(allocator);
        var req = Request.init(allocator);
        defer req.deinit();
        var parser = Parser.init(allocator);
        defer parser.deinit();
        try testing.expectEqual(Outcome.bad_request, parser.parse(buf, &req));
    }
}

test "unsupported protocol, method, and chunked encoding yield 501" {
    const allocator = testing.allocator;
    const bad_wires = [_][]const u8{
        "GET / HTTP/2.0\r\n\r\n",
        "BREW / HTTP/1.1\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
    };
    for (bad_wires) |wire| {
        const buf = try fill(allocator, wire);
        defer buf.deinit(allocator);
        var req = Request.init(allocator);
        defer req.deinit();
        var parser = Parser.init(allocator);
        defer parser.deinit();
        try testing.expectEqual(Outcome.unsupported, parser.parse(buf, &req));
    }
}

test "oversized header line yields 431" {
    const allocator = testing.allocator;
    const big_value = "x" ** (max_line_bytes + 100);
    var wire_buf: [max_line_bytes + 256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "GET / HTTP/1.1\r\nX-Big: {s}\r\n\r\n", .{big_value}) catch unreachable;

    const buf = try fill(allocator, wire);
    defer buf.deinit(allocator);
    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();
    try testing.expectEqual(Outcome.header_too_large, parser.parse(buf, &req));
}

test "header count cap yields 431" {
    const allocator = testing.allocator;
    var wire_buf: [4096]u8 = undefined;
    var used: usize = 0;
    const prefix = "GET / HTTP/1.1\r\n";
    @memcpy(wire_buf[0..prefix.len], prefix);
    used += prefix.len;
    for (0..max_headers + 1) |i| {
        const s = std.fmt.bufPrint(wire_buf[used..], "X-H{d}: {d}\r\n", .{ i, i }) catch unreachable;
        used += s.len;
    }
    @memcpy(wire_buf[used .. used + 2], "\r\n");
    used += 2;

    const buf = try fill(allocator, wire_buf[0..used]);
    defer buf.deinit(allocator);
    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();
    try testing.expectEqual(Outcome.header_too_large, parser.parse(buf, &req));
}

test "partial body across recv boundaries" {
    const allocator = testing.allocator;
    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    // Headers announce 10 body bytes; only 4 arrive.
    const buf = try fill(allocator, "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabcd");
    defer buf.deinit(allocator);
    try testing.expectEqual(Outcome.incomplete, parser.parse(buf, &req));
    try testing.expectEqual(@as(usize, 4), buf.availableRead());

    _ = buf.writeSlice("efghij");
    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("abcdefghij", req.body);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}
