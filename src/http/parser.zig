const std = @import("std");
const buffer_mod = @import("../net/buffer.zig");
const header_dfa_mod = @import("header_dfa.zig");

const ascii = std.ascii;
const mem = std.mem;

pub const max_headers = 32;
/// Cap on the size of a single request-line or header line (RFC 7230 has no
/// hard limit; this bounds parser memory and maps to HTTP 431).
pub const max_line_bytes = 8192;
/// Cap on the assembled body of a chunked request. Chunked bodies are copied
/// out of the connection buffer (unlike Content-Length bodies, which are
/// zero-copy), so this bounds the memory a single request can claim.
pub const max_chunked_body = 64 * 1024;

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

/// FNV-1a (32-bit) over lower-cased bytes (Milestone 8). Header names and
/// values hash case-insensitively, so a comptime-known name's hash is a
/// compile-time constant and slot matching reduces to an integer compare.
/// `known` is the header-name set whose hashes must be collision-free; the
/// comptime assertion below makes a collision a compile error.
pub const header_hasher = struct {
    pub fn hash(name: []const u8) u32 {
        var h: u32 = 2166136261;
        for (name) |c| {
            h ^= ascii.toLower(c);
            h *%= 16777619;
        }
        return h;
    }

    /// The known header-name set: lookups for these are hash-matched.
    pub const known = [_][]const u8{
        "host",
        "content-type",
        "content-length",
        "transfer-encoding",
        "connection",
        "accept-encoding",
        "if-none-match",
        "if-modified-since",
        "range",
        "accept",
        "user-agent",
        "cookie",
        "authorization",
        "referer",
        "upgrade",
        "expect",
    };

    /// True if `h` is the hash of one of the known names.
    pub fn isKnownHash(h: u32) bool {
        inline for (known) |n| {
            if (hash(n) == h) return true;
        }
        return false;
    }

    comptime {
        // A collision among the known names would make hash-matched lookup
        // ambiguous: a compile error, not a runtime bug. The hashes are
        // computed once (comptime branch budget) and compared pairwise.
        const known_hashes: [known.len]u32 = blk: {
            var out: [known.len]u32 = undefined;
            for (known, 0..) |n, i| out[i] = hash(n);
            break :blk out;
        };
        for (known_hashes, 0..) |a, i| {
            for (known_hashes[i + 1 ..]) |b| {
                if (a == b) @compileError("header name hash collision in known set");
            }
        }
    }
};

/// Identity of a known header name, produced by the comptime header DFA
/// (`header_dfa`). The wire name is classified once during parsing and the
/// tag is stored in the slot, so special handling and lookups reduce to an
/// integer compare — the state-machine form of the Milestone-8 hash lookup.
pub const HeaderTag = enum(u16) {
    unknown = 0,
    host,
    content_type,
    content_length,
    transfer_encoding,
    connection,
    accept_encoding,
    if_none_match,
    if_modified_since,
    range,
    accept,
    user_agent,
    cookie,
    authorization,
    referer,
    upgrade,
    expect,

    /// Tag for a comptime-known header name (compile-time constant used in
    /// `Request.header` lookups). Unknown names yield `.unknown`.
    pub fn of(comptime name: []const u8) HeaderTag {
        return @enumFromInt(header_dfa.classify(name));
    }
};

/// The comptime-built classification DFA over the known header-name set.
/// One transition-table lookup per byte; terminal state is the exact tag.
pub const header_dfa = header_dfa_mod.build(&.{
    .{ .name = "host", .tag = @intFromEnum(HeaderTag.host) },
    .{ .name = "content-type", .tag = @intFromEnum(HeaderTag.content_type) },
    .{ .name = "content-length", .tag = @intFromEnum(HeaderTag.content_length) },
    .{ .name = "transfer-encoding", .tag = @intFromEnum(HeaderTag.transfer_encoding) },
    .{ .name = "connection", .tag = @intFromEnum(HeaderTag.connection) },
    .{ .name = "accept-encoding", .tag = @intFromEnum(HeaderTag.accept_encoding) },
    .{ .name = "if-none-match", .tag = @intFromEnum(HeaderTag.if_none_match) },
    .{ .name = "if-modified-since", .tag = @intFromEnum(HeaderTag.if_modified_since) },
    .{ .name = "range", .tag = @intFromEnum(HeaderTag.range) },
    .{ .name = "accept", .tag = @intFromEnum(HeaderTag.accept) },
    .{ .name = "user-agent", .tag = @intFromEnum(HeaderTag.user_agent) },
    .{ .name = "cookie", .tag = @intFromEnum(HeaderTag.cookie) },
    .{ .name = "authorization", .tag = @intFromEnum(HeaderTag.authorization) },
    .{ .name = "referer", .tag = @intFromEnum(HeaderTag.referer) },
    .{ .name = "upgrade", .tag = @intFromEnum(HeaderTag.upgrade) },
    .{ .name = "expect", .tag = @intFromEnum(HeaderTag.expect) },
});

comptime {
    // The DFA and the hash-based known set must agree on every name.
    for (header_hasher.known) |n| {
        if (HeaderTag.of(n) == .unknown) {
            @compileError("header name in hasher known-set is missing from the DFA: " ++ n);
        }
    }
}

pub const Version = struct {
    major: u8,
    minor: u8,
};

/// Outcome of one parse() call. `.incomplete` means "need more bytes, call
/// again after recv". On `.complete` the parser has consumed the request from
/// the buffer and is ready for the next pipelined request; `req.body` is a
/// zero-copy slice into the buffer (Content-Length bodies) or into
/// `req.body_storage` (chunked bodies) and is only valid until the connection's
/// next recv/compact or the next request.
pub const Outcome = union(enum) {
    incomplete,
    complete,
    bad_request, // 400
    header_too_large, // 431
    payload_too_large, // 413 (chunked body over max_chunked_body)
    unsupported, // 501 (bad version, unknown method, ...)
    out_of_memory,
};

const Slot = struct {
    name_off: u32,
    name_len: u32,
    value_off: u32,
    value_len: u32,
    /// DFA-classified identity of the header name (comptime lookup
    /// structure): lookups compare tags (integers) with no string
    /// verification for known names.
    tag: HeaderTag,
};

/// A parsed HTTP/1.x request. Header names/values are copied into private
/// storage owned by this struct (safe against buffer compaction); the body is
/// a zero-copy view into the connection buffer (Content-Length) or into
/// `body_storage` (chunked).
pub const Request = struct {
    method: Method,
    target: []const u8,
    /// Percent-decoded target (query string stripped, `+` not converted).
    /// Targets without escapes alias the `target` bytes (zero-copy).
    decoded_target: []const u8,
    /// Slice of the request line from `?` onwards (including the `?`), or
    /// empty when the target has no query string.
    query_string: []const u8,
    version: Version,
    keep_alive: bool,
    content_length: usize,
    body: []const u8,

    allocator: std.mem.Allocator,
    storage: std.ArrayList(u8),
    /// Assembly buffer for chunked request bodies (Content-Length bodies are
    /// zero-copy views into the connection buffer instead).
    body_storage: std.ArrayList(u8),
    slots: [max_headers]Slot = undefined,
    header_count: usize = 0,
    transfer_chunked: bool = false,

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = .unknown,
            .target = "",
            .decoded_target = "",
            .query_string = "",
            .version = .{ .major = 1, .minor = 1 },
            .keep_alive = true,
            .content_length = 0,
            .body = &.{},
            .allocator = allocator,
            .storage = .empty,
            .body_storage = .empty,
        };
    }

    pub fn deinit(self: *Request) void {
        self.storage.deinit(self.allocator);
        self.body_storage.deinit(self.allocator);
    }

    /// Prepare the struct for the next request on the same connection.
    pub fn reset(self: *Request) void {
        self.method = .unknown;
        self.target = "";
        self.decoded_target = "";
        self.query_string = "";
        self.version = .{ .major = 1, .minor = 1 };
        self.keep_alive = true;
        self.content_length = 0;
        self.body = &.{};
        self.storage.clearRetainingCapacity();
        self.body_storage.clearRetainingCapacity();
        self.header_count = 0;
        self.transfer_chunked = false;
    }

    pub fn headerCount(self: *const Request) usize {
        return self.header_count;
    }

    /// Case-insensitive lookup of a header value (first occurrence wins).
    /// `name` is a comptime literal: for known names its DFA tag is a
    /// compile-time constant, so the scan compares one tag per slot and is
    /// exact (the DFA classified the wire name at parse time). Unknown names
    /// fall back to a case-insensitive string scan.
    pub fn header(self: *const Request, comptime name: []const u8) ?[]const u8 {
        const target_tag = comptime HeaderTag.of(name);
        if (target_tag != .unknown) {
            for (self.slots[0..self.header_count]) |s| {
                if (s.tag == target_tag) {
                    return self.storage.items[s.value_off..][0..s.value_len];
                }
            }
            return null;
        }
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

        // Known-name detection is a DFA walk (comptime lookup structure):
        // one table lookup per byte, terminal state is the exact tag.
        const tag: HeaderTag = @enumFromInt(header_dfa.classify(n));
        switch (tag) {
            .content_length => {
                self.content_length = std.fmt.parseInt(usize, v, 10) catch return error.Malformed;
            },
            .transfer_encoding => {
                if (valueHasChunked(v)) self.transfer_chunked = true;
            },
            else => {},
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
            .tag = tag,
        };
        self.header_count += 1;
    }
};

/// True if a Transfer-Encoding value lists `chunked` (comma-separated;
/// `;`-parameters on a token are tolerated). Token matching is a hash
/// compare against the comptime `chunked` hash (Milestone 8).
fn valueHasChunked(value: []const u8) bool {
    var tokens = mem.tokenizeAny(u8, value, ",");
    while (tokens.next()) |t| {
        var tok = mem.trim(u8, t, " \t");
        if (mem.indexOfScalar(u8, tok, ';')) |semi| tok = tok[0..semi];
        if (tok.len > 0 and header_hasher.hash(tok) == comptime header_hasher.hash("chunked")) {
            return true;
        }
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

/// Comptime `%XX` hex decode table: hex value of a byte, or 0xff when the
/// byte is not a hex digit.
const hex_value: [256]u8 = blk: {
    var table = [_]u8{0xff} ** 256;
    for ("0123456789abcdefABCDEF") |c| {
        const v = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else
            c - 'A' + 10;
        table[c] = v;
    }
    break :blk table;
};

/// Percent-decode `src` into `dst` (which must hold `src.len` bytes).
/// Returns null on a malformed escape (`%` not followed by two hex digits).
/// `+` is left as-is (it only means space in form encodings, not in targets).
fn percentDecode(src: []const u8, dst: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '%') {
            if (i + 2 >= src.len) return null;
            const hi = hex_value[src[i + 1]];
            const lo = hex_value[src[i + 2]];
            if (hi == 0xff or lo == 0xff) return null;
            dst[o] = hi * 16 + lo;
            i += 3;
        } else {
            dst[o] = c;
            i += 1;
        }
        o += 1;
    }
    return dst[0..o];
}

/// Parse a chunk-size line: an optional hex size (RFC 9112 allows leading
/// `+`; extensions after `;` are tolerated and dropped).
fn parseChunkSize(line: []const u8) error{BadChunkSize}!usize {
    var size: usize = 0;
    var saw_digit = false;
    for (line) |c| {
        if (c == ';') break;
        const v = hex_value[c];
        if (v == 0xff) {
            // Extension or whitespace terminates the size.
            if (c == ' ' or c == '\t') break;
            return error.BadChunkSize;
        }
        // v <= 15, so this is exactly the size*16+v > maxInt(usize) test.
        if (size > (std.math.maxInt(usize) - 15) / 16) return error.BadChunkSize;
        size = size * 16 + v;
        saw_digit = true;
    }
    if (!saw_digit) return error.BadChunkSize;
    return size;
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

    const State = enum {
        request_line,
        headers,
        body,
        chunk_size,
        chunk_data,
        chunk_crlf,
        chunk_trailers,
    };

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
                            // End of headers. The accumulated line (possibly a
                            // split CRLF remnant) is dead; clear it so the
                            // chunked states never see stale bytes.
                            self.line.clearRetainingCapacity();
                            finalizeKeepAlive(req);
                            if (req.transfer_chunked) {
                                self.state = .chunk_size;
                                self.body_remaining = 0;
                                continue;
                            }
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
            .chunk_size => {
                const line = (self.readLine(buf) catch |e| return lineErrorToOutcome(e)) orelse return .incomplete;
                switch (line) {
                    .line_data => |l| {
                        const size = parseChunkSize(l) catch return .bad_request;
                        self.line.clearRetainingCapacity();
                        if (size == 0) {
                            self.state = .chunk_trailers;
                            continue;
                        }
                        if (size > max_chunked_body or req.body_storage.items.len + size > max_chunked_body) {
                            return .payload_too_large;
                        }
                        self.body_remaining = size;
                        self.state = .chunk_data;
                        continue;
                    },
                }
            },
            .chunk_data => {
                // Copy the chunk payload out of the connection buffer: the
                // next chunk's size line and CRLFs interrupt it, so the body
                // cannot stay zero-copy.
                const have = buf.availableRead();
                const take = @min(have, self.body_remaining);
                if (take > 0) {
                    req.body_storage.appendSlice(req.allocator, buf.peek()[0..take]) catch return .out_of_memory;
                    buf.consume(take);
                    self.body_remaining -= take;
                }
                if (self.body_remaining > 0) return .incomplete;
                self.body_remaining = 2; // the CRLF terminating the chunk
                self.state = .chunk_crlf;
                continue;
            },
            .chunk_crlf => {
                if (buf.availableRead() < self.body_remaining) return .incomplete;
                // Lenient about the exact line ending (consistent with
                // readLine); the two bytes are discarded either way.
                buf.consume(self.body_remaining);
                self.state = .chunk_size;
                continue;
            },
            .chunk_trailers => {
                const line = (self.readLine(buf) catch |e| return lineErrorToOutcome(e)) orelse return .incomplete;
                switch (line) {
                    .line_data => |l| {
                        if (l.len == 0) {
                            // Trailer headers are dropped: the request is
                            // complete once the empty trailer line is read.
                            req.body = req.body_storage.items;
                            self.line.clearRetainingCapacity();
                            self.reset();
                            return .complete;
                        }
                        self.line.clearRetainingCapacity();
                        continue;
                    },
                }
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

        // Query string split: everything from `?` onwards (including it).
        var query_off: ?usize = null;
        var path_len = target_tok.len;
        if (mem.indexOfScalar(u8, target_tok, '?')) |qi| {
            query_off = target_off + qi;
            path_len = qi;
        }

        // Percent-decoded target. Targets without escapes are zero-copy slices
        // into `storage`; escaped ones are decoded into a stack scratch buffer
        // first (appending reallocates `storage`, invalidating earlier
        // slices), then copied into `storage`. All slices are taken only
        // after every append, once the backing storage is stable.
        var decoded_off: ?usize = null;
        if (mem.indexOfScalar(u8, target_tok[0..path_len], '%') != null) {
            var decoded_buf: [max_line_bytes]u8 = undefined;
            const decoded = percentDecode(target_tok[0..path_len], &decoded_buf) orelse return .bad_request;
            decoded_off = req.storage.items.len;
            req.storage.appendSlice(self.allocator, decoded) catch return .out_of_memory;
        }

        req.target = req.storage.items[target_off .. target_off + target_tok.len];
        req.decoded_target = if (decoded_off) |off|
            req.storage.items[off..]
        else
            req.storage.items[target_off .. target_off + path_len];
        req.query_string = if (query_off) |off|
            req.storage.items[off .. target_off + target_tok.len]
        else
            "";
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
        // Hash compare for the name, then for each comma token (Milestone 8).
        if (header_hasher.hash(h.name) != comptime header_hasher.hash("connection")) continue;
        var tokens = mem.tokenizeAny(u8, h.value, ",");
        while (tokens.next()) |t| {
            const tok = mem.trim(u8, t, " \t");
            const tok_hash = header_hasher.hash(tok);
            if (tok_hash == comptime header_hasher.hash("close")) close = true;
            if (tok_hash == comptime header_hasher.hash("keep-alive")) keep = true;
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

test "unsupported protocol and method yield 501" {
    const allocator = testing.allocator;
    const bad_wires = [_][]const u8{
        "GET / HTTP/2.0\r\n\r\n",
        "BREW / HTTP/1.1\r\n\r\n",
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

test "chunked request: single chunk" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expect(req.transfer_chunked);
    try testing.expectEqualStrings("hello", req.body);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "chunked request: multiple chunks with interleaved trailers dropped" {
    const allocator = testing.allocator;
    const wire =
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "4\r\n!?!?\r\n" ++
        "0\r\n" ++
        "X-Trailer: dropped\r\n" ++
        "\r\n";
    const buf = try fill(allocator, wire);
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("hello world!?!?", req.body);
    try testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "chunked request: empty body" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqual(@as(usize, 0), req.body.len);
}

test "chunked request: size extensions and uppercase hex tolerated" {
    const allocator = testing.allocator;
    const buf = try fill(allocator,
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "A;foo=bar;baz\r\nabcdefghij\r\n" ++
            "3\r\nxyz\r\n" ++
            "0\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("abcdefghijxyz", req.body);
}

test "chunked request: malformed size line yields 400" {
    const allocator = testing.allocator;
    const bad_wires = [_][]const u8{
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
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

test "chunked request: body over the cap yields 413" {
    const allocator = testing.allocator;
    var wire_buf: [max_chunked_body + 128]u8 = undefined;
    const chunk_size = max_chunked_body + 1;
    const head = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n{X}\r\n", .{chunk_size}) catch unreachable;
    const buf = try fill(allocator, head);
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    // The size line announces more than the cap before any payload arrives.
    try testing.expectEqual(Outcome.payload_too_large, parser.parse(buf, &req));
}

test "chunked request: incremental feeding at every byte boundary" {
    const allocator = testing.allocator;
    const wire =
        "POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n";

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
        try testing.expectEqualStrings("abcdefg", req.body);
    }
}

test "chunked request pipelined with a content-length request" {
    const allocator = testing.allocator;
    const buf = try fill(allocator,
        "POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n0\r\n\r\n" ++
            "POST /b HTTP/1.1\r\nContent-Length: 2\r\n\r\ncd");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("ab", req.body);

    req.reset();
    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("cd", req.body);
}

test "chunked body spanning recv boundaries" {
    const allocator = testing.allocator;
    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    // Headers + first chunk size + half a chunk arrive first.
    const buf = try fill(allocator, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe");
    defer buf.deinit(allocator);
    try testing.expectEqual(Outcome.incomplete, parser.parse(buf, &req));

    _ = buf.writeSlice("llo\r\n0\r\n\r\n");
    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("hello", req.body);
}

// ---- Milestone 8: comptime header-name hashing ----

test "header hasher is case-insensitive and distinguishes names" {
    try testing.expectEqual(
        header_hasher.hash("content-type"),
        header_hasher.hash("Content-Type"),
    );
    try testing.expectEqual(
        header_hasher.hash("HOST"),
        header_hasher.hash("host"),
    );
    try testing.expect(header_hasher.hash("host") != header_hasher.hash("content-type"));
    // Comptime-known argument folds to a constant.
    try testing.expectEqual(@as(u32, comptime header_hasher.hash("range")), header_hasher.hash("RANGE"));
}

test "known header-name set is collision-free" {
    const hashes: [header_hasher.known.len]u32 = blk: {
        var out: [header_hasher.known.len]u32 = undefined;
        for (header_hasher.known, 0..) |n, i| out[i] = header_hasher.hash(n);
        break :blk out;
    };
    for (hashes, 0..) |a, i| {
        for (hashes[i + 1 ..]) |b| {
            try testing.expect(a != b);
        }
        try testing.expect(header_hasher.isKnownHash(a));
    }
    try testing.expect(!header_hasher.isKnownHash(header_hasher.hash("x-custom")));
}

test "hash-matched lookup finds known and unknown headers with any case" {
    const allocator = testing.allocator;
    const buf = try fill(allocator,
        "GET / HTTP/1.1\r\n" ++
            "HoSt: example.com\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "ACCEPT-ENCODING: gzip, deflate\r\n" ++
            "X-Custom-Header: custom-value\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("example.com", req.header("host").?);
    try testing.expectEqualStrings("text/plain", req.header("content-type").?);
    try testing.expectEqualStrings("gzip, deflate", req.header("accept-encoding").?);
    try testing.expectEqualStrings("custom-value", req.header("X-CUSTOM-HEADER").?);
    try testing.expectEqual(@as(?[]const u8, null), req.header("missing-header"));

    // The stored slot hash matches the recomputed name hash.
    const h = req.headerAt(3);
    try testing.expectEqual(header_hasher.hash(h.name), header_hasher.hash("x-custom-header"));
}

test "hashed value matching: keep-alive tokens and chunked detection" {
    const allocator = testing.allocator;
    const cases = [_]struct { wire: []const u8, keep: bool }{
        .{ .wire = "GET / HTTP/1.1\r\nConnection: CLOSE\r\n\r\n", .keep = false },
        .{ .wire = "GET / HTTP/1.1\r\nConnection: keep-alive, upgrade\r\n\r\n", .keep = true },
        .{ .wire = "GET / HTTP/1.0\r\nConnection: KEEP-ALIVE\r\n\r\n", .keep = true },
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

    // Chunked detection via hashed tokens, tolerating parameters.
    const buf = try fill(allocator, "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, ChUnKeD;foo=1\r\n\r\n0\r\n\r\n");
    defer buf.deinit(allocator);
    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();
    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expect(req.transfer_chunked);
}

test "URL decoding: escapes are decoded, plain targets are zero-copy" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET /a%20b%2Fc%41 HTTP/1.1\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("/a%20b%2Fc%41", req.target);
    try testing.expectEqualStrings("/a b/cA", req.decoded_target);
    try testing.expectEqualStrings("", req.query_string);

    const plain = try fill(allocator, "GET /plain/path HTTP/1.1\r\n\r\n");
    defer plain.deinit(allocator);
    var req2 = Request.init(allocator);
    defer req2.deinit();
    var parser2 = Parser.init(allocator);
    defer parser2.deinit();
    try testing.expectEqual(Outcome.complete, parser2.parse(plain, &req2));
    // Zero-copy: the decoded target aliases the raw target bytes.
    try testing.expectEqualStrings("/plain/path", req2.decoded_target);
    try testing.expectEqual(@as(usize, 0), req2.decoded_target.ptr - req2.target.ptr);
}

test "URL decoding: malformed escapes yield 400" {
    const allocator = testing.allocator;
    const bad_wires = [_][]const u8{
        "GET /a% HTTP/1.1\r\n\r\n",
        "GET /a%2 HTTP/1.1\r\n\r\n",
        "GET /a%zz HTTP/1.1\r\n\r\n",
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

test "query string split" {
    const allocator = testing.allocator;
    const buf = try fill(allocator, "GET /search?q=zig+lang&page=2 HTTP/1.1\r\n\r\n");
    defer buf.deinit(allocator);

    var req = Request.init(allocator);
    defer req.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try testing.expectEqual(Outcome.complete, parser.parse(buf, &req));
    try testing.expectEqualStrings("/search", req.decoded_target);
    try testing.expectEqualStrings("?q=zig+lang&page=2", req.query_string);

    // Escapes before the '?' are decoded; the query string stays raw.
    const buf2 = try fill(allocator, "GET /files%20x?raw=1 HTTP/1.1\r\n\r\n");
    defer buf2.deinit(allocator);
    var req2 = Request.init(allocator);
    defer req2.deinit();
    var parser2 = Parser.init(allocator);
    defer parser2.deinit();
    try testing.expectEqual(Outcome.complete, parser2.parse(buf2, &req2));
    try testing.expectEqualStrings("/files x", req2.decoded_target);
    try testing.expectEqualStrings("?raw=1", req2.query_string);
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
