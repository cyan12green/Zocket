const std = @import("std");
const parser = @import("../http/parser.zig");
const response_mod = @import("../http/response.zig");
const hpack = @import("hpack.zig");
const frames = @import("frames.zig");
const pipeline = @import("../dsl/pipeline.zig");
const registry = @import("../dsl/registry.zig");
const server_mod = @import("../runtime/server.zig");
const static_cache_mod = @import("../dsl/static_cache.zig");
const limits_mod = @import("../dsl/limits.zig");

/// HTTP/2 connection session (RFC 9113), h2c prior-knowledge. Owns the
/// HPACK decoder, the stream table and flow-control state, and turns each
/// completed request into a pipeline run whose response is re-framed as
/// HEADERS + DATA.
///
/// The reactor feeds all available receive bytes into `process`; the session
/// consumes complete frames, appends outgoing frames to `send`, and invokes
/// `Handler.run` for each completed request. Buffered, non-file responses
/// are framed immediately (subject to flow control); file-backed responses
/// are read into a heap buffer and framed the same way (sendfile under h2
/// is deferred).
pub const Session = struct {
    allocator: std.mem.Allocator,
    hpack_dec: hpack.Decoder,
    /// Stream table. Deleted once a stream is fully closed.
    streams: std.AutoHashMap(u31, Stream),
    /// Reusable request structs returned by completed streams (their header
    /// slots and arena are reused, avoiding per-request allocation).
    request_pool: std.ArrayList(parser.Request) = .empty,
    /// Reusable HPACK response-block scratch (keeps its capacity across
    /// requests; reset per frameResponse so no per-request allocation).
    block_scratch: std.ArrayList(u8) = .empty,
    /// Header-count limit captured from the handler (used for pooled
    /// Request creation in decodeAndDispatch, where no handler is in scope).
    max_headers: usize = 32,
    // (prof) per-request timing accumulators.
    /// Connection-level flow control (RFC 9113 §5.2).
    conn_recv_window: u32 = default_window,
    conn_send_window: u32 = default_window,
    /// Whether the client preface has been consumed.
    preface_seen: bool = false,
    /// Server SETTINGS sent (once, right after the preface).
    settings_sent: bool = false,
    /// Client's advertised limits.
    peer_max_frame_size: u24 = frames.default_max_frame_size,
    peer_initial_window: u32 = default_window,
    /// Highest stream id the peer opened (for GOAWAY).
    max_stream_id: u31 = 0,
    /// A frame with the END_HEADERS flag pending (CONTINUATION assembly).
    pending_headers_stream: ?u31 = null,
    pending_hpack_block: std.ArrayList(u8) = .empty,
    /// Set when the connection should be torn down (GOAWAY sent/received).
    closing: bool = false,

    pub const default_window: u32 = 65535;
    pub const max_concurrent_streams: u32 = 100;

    /// RFC 9113 §6.5.2 error codes, comptime constants for GOAWAY/RST_STREAM.
    pub const err = struct {
        pub const no_error: u32 = 0x0;
        pub const protocol_error: u32 = 0x1;
        pub const internal_error: u32 = 0x2;
        pub const flow_control_error: u32 = 0x3;
        pub const stream_closed: u32 = 0x5;
        pub const frame_size_error: u32 = 0x6;
        pub const refused_stream: u32 = 0x7;
        pub const cancel: u32 = 0x8;
    };

    /// Comptime table of known SETTINGS identifiers with their valid ranges
    /// (RFC 9113 §6.5.2): unknown settings are ignored, out-of-range values
    /// are connection errors. `min`/`max` are the inclusive bounds.
    pub const Setting = struct {
        id: u16,
        name: []const u8,
        min: u32,
        max: u32,
    };
    pub const known_settings = [_]Setting{
        .{ .id = 1, .name = "HEADER_TABLE_SIZE", .min = 0, .max = 0xffffffff },
        .{ .id = 2, .name = "ENABLE_PUSH", .min = 0, .max = 1 },
        .{ .id = 4, .name = "INITIAL_WINDOW_SIZE", .min = 0, .max = 0x7fffffff },
        .{ .id = 5, .name = "MAX_FRAME_SIZE", .min = 16384, .max = 0x00ffffff },
    };

    /// Comptime lookup of a setting's valid range by id; null for unknown.
    pub fn settingRange(id: u16) ?Setting {
        inline for (known_settings) |s| {
            if (s.id == id) return s;
        }
        return null;
    }

    /// FNV-1a hash of a header/pseudo-header name (DM1 pattern): the request
    /// classifier dispatches on a single integer compare instead of a chain
    /// of string equality checks.
    fn hdrHash(name: []const u8) u64 {
        var h: u64 = 1469598103934665603;
        for (name) |c| h = (h ^ c) *% 1099511628211;
        return h;
    }

    pub const Error = error{
        /// Connection-level: send GOAWAY + close.
        ProtocolError,
        /// Frame too large: send GOAWAY FRAME_SIZE_ERROR + close.
        FrameSizeError,
        /// Flow-control window overflow: GOAWAY FLOW_CONTROL_ERROR + close.
        FlowControlError,
        /// Stream-level: send RST_STREAM + continue.
        StreamError,
        OutOfMemory,
    };

    pub const Stream = struct {
        state: enum { open, half_closed_remote, closed } = .open,
        recv_window: u32 = default_window,
        send_window: u32 = default_window,
        end_stream_received: bool = false,
        end_stream_sent: bool = false,
        headers: std.ArrayList(hpack.Field) = .empty,
        body: std.ArrayList(u8) = .empty,
        /// Assembled request (owned: headers copied from the arena).
        request: ?parser.Request = null,
        /// Response bytes pending emission (held when the send window is
        /// exhausted mid-body).
        pending_response: std.ArrayList(u8) = .empty,
        responded: bool = false,
        reset: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .hpack_dec = hpack.Decoder.init(allocator),
            .streams = std.AutoHashMap(u31, Stream).init(allocator),
            .pending_hpack_block = std.ArrayList(u8).empty,
            .request_pool = std.ArrayList(parser.Request).empty,
            .block_scratch = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.hpack_dec.deinit();
        self.pending_hpack_block.deinit(self.allocator);
        var it = self.streams.iterator();
        while (it.next()) |e| self.destroyStream(e.value_ptr);
        self.streams.deinit();
        for (self.request_pool.items) |*r| r.deinit();
        self.request_pool.deinit(self.allocator);
        self.block_scratch.deinit(self.allocator);
    }

    fn destroyStream(self: *Session, st: *Stream) void {
        // The HPACK-decoded fields and Request headers live in the Request's
        // arena (bump-owned); the arena is reclaimed when the Request is
        // reset on pool reuse. Only the containers themselves are freed.
        const arena = if (st.request) |*r| r.arena.asAllocator() else self.allocator;
        st.headers.deinit(arena);
        st.body.deinit(arena);
        st.pending_response.deinit(self.allocator);
        // Return the request to the per-session pool (its header slots and
        // arena are reused by the next stream — the HTTP/1 connection-reuse
        // model applied across streams, since each h2 stream is one-shot).
        if (st.request) |r| {
            self.request_pool.append(self.allocator, r) catch {
                var r2 = r;
                r2.deinit();
            };
            st.request = null;
        }
    }

    /// Caller context for running a completed request through the pipeline.
    pub const Handler = struct {
        server: *const server_mod.Server,
        allocator: std.mem.Allocator,
        client_ip: [4]u8 = .{ 0, 0, 0, 0 },
        stats: ?*const registry.ServerStats = null,
        static_cache: ?*static_cache_mod.StaticCache = null,
        limits: *const limits_mod.Limits,
        date_header: []const u8,
        version_string: []const u8,
    };

    /// True once the leading 24 bytes of a connection match the HTTP/2
    /// client preface (RFC 9113 §3.5). The reactor uses this to route a
    /// connection to an HTTP/2 session on first contact.
    pub fn looksLikeHttp2Preface(bytes: []const u8) bool {
        return bytes.len >= 24 and std.mem.eql(u8, bytes[0..24], preface);
    }

    pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    /// Consume the client preface from the head of `buf` and emit our
    /// SETTINGS. Called once per connection.
    pub fn onPreface(self: *Session, send: *std.ArrayList(u8)) !void {
        self.preface_seen = true;
        self.settings_sent = true;
        // Advertise: default initial window (65535), default max frame size
        // (16384), max concurrent streams 100.
        try frames.writeSettings(send, self.allocator, &.{
            .{ .id = 3, .value = max_concurrent_streams },
        });
    }

    /// Process all complete frames in `recv`. `send` accumulates outgoing
    /// frames. Returns the number of bytes consumed (the caller advances its
    /// buffer by that much). The client preface (24 bytes) is consumed here
    /// on first contact, and the server SETTINGS are emitted.
    pub fn process(
        self: *Session,
        recv: []const u8,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !usize {
        var off: usize = 0;
        if (!self.preface_seen) {
            if (recv.len < 24) return 0; // wait for the full preface
            if (!looksLikeHttp2Preface(recv[0..24])) return error.ProtocolError;
            off = 24;
            try self.onPreface(send);
        }
        while (true) {
            const hdr = frames.parseHeader(recv[off..]) orelse break;
            if (hdr.length > self.peer_max_frame_size) return error.FrameSizeError;
            const end = off + 9 + hdr.length;
            if (end > recv.len) break;
            const payload = recv[off + 9 .. end];
            try self.handleFrame(hdr, payload, send, handler);
            off = end;
        }
        return off;
    }

    fn handleFrame(
        self: *Session,
        hdr: frames.FrameHeader,
        payload: []const u8,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        // RFC 9113 §6.10: between a HEADERS/PUSH_PROMISE without END_HEADERS
        // and its final CONTINUATION, only CONTINUATION frames may appear —
        // even unknown extension frame types are a connection error there.
        if (self.pending_headers_stream != null and hdr.type != .continuation) {
            return error.ProtocolError;
        }
        if (hdr.type == .unknown) return; // RFC 9113 §4.1: ignore unknown types
        switch (hdr.type) {
            .settings => try self.handleSettings(hdr, payload, send),
            .headers => try self.handleHeaders(hdr, payload, send, handler),
            .data => try self.handleData(hdr, payload, send, handler),
            .continuation => try self.handleContinuation(hdr, payload, send, handler),
            .ping => {
                if (hdr.stream_id != 0) return error.ProtocolError;
                if (hdr.flag_bits & frames.flags.ack != 0) return; // our own PING ack
                if (payload.len != 8) return error.ProtocolError;
                try frames.writePingAck(send, self.allocator, payload);
            },
            .window_update => try self.handleWindowUpdate(hdr, payload, send),
            .rst_stream => {
                if (hdr.stream_id == 0) return error.ProtocolError;
                if (payload.len != 4) return error.FrameSizeError;
                if (self.streams.getPtr(hdr.stream_id) == null and hdr.stream_id > self.max_stream_id) {
                    return error.ProtocolError; // RST_STREAM on an idle stream
                }
                if (self.streams.getPtr(hdr.stream_id)) |st| {
                    st.state = .closed;
                    st.reset = true;
                }
            },
            .goaway => {
                if (hdr.stream_id != 0) return error.ProtocolError;
                if (payload.len < 8) return error.FrameSizeError;
                // Peer is shutting down: we finish current work then close.
                self.closing = true;
            },
            .priority => {
                if (hdr.stream_id == 0) return error.ProtocolError;
                if (payload.len != 5) return error.FrameSizeError;
                const dep: u31 = @intCast(((@as(u32, payload[0]) & 0x7f) << 24) | (@as(u32, payload[1]) << 16) | (@as(u32, payload[2]) << 8) | payload[3]);
                if (dep == hdr.stream_id) return error.ProtocolError; // self-dependency
            },
            .push_promise => return error.ProtocolError, // we never allow push
            .unknown => return, // handled above; keeps the switch exhaustive
        }
    }

    fn handleSettings(self: *Session, hdr: frames.FrameHeader, payload: []const u8, send: *std.ArrayList(u8)) !void {
        if (hdr.stream_id != 0) return error.ProtocolError;
        if (hdr.flag_bits & frames.flags.ack != 0) {
            if (payload.len != 0) return error.ProtocolError;
            return;
        }
        if (payload.len % 6 != 0) return error.ProtocolError;
        var i: usize = 0;
        while (i < payload.len) : (i += 6) {
            const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
            const value: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) | (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
            // Unknown settings are ignored; known ones validated by their
            // comptime-defined ranges (before any narrowing cast).
            if (settingRange(id)) |s| {
                if (value < s.min or value > s.max) return error.ProtocolError;
            }
            switch (id) {
                1 => self.hpack_dec.setHeaderTableSize(value), // HEADER_TABLE_SIZE
                2 => {}, // ENABLE_PUSH: validated by settingRange below
                3 => {}, // MAX_CONCURRENT_STREAMS: we open no streams
                4 => {
                    const delta: i64 = @as(i64, value) - @as(i64, self.peer_initial_window);
                    self.peer_initial_window = value;
                    // RFC 9113 §6.9.2: existing streams' windows adjust by
                    // the delta (may go negative; clamps at 0).
                    var it = self.streams.iterator();
                    while (it.next()) |e| {
                        const sw = @as(i64, e.value_ptr.send_window) + delta;
                        e.value_ptr.send_window = if (sw <= 0) 0 else if (sw >= 0x7fffffff) 0x7fffffff else @intCast(sw);
                    }
                },
                5 => self.peer_max_frame_size = @intCast(value),
                else => {}, // unknown settings ignored
            }
        }
        // ACK the settings.
        var h: [9]u8 = undefined;
        var fh = frames.FrameHeader{ .length = 0, .type = .settings, .flag_bits = frames.flags.ack };
        fh.encode(&h);
        try send.appendSlice(self.allocator, &h);
    }

    fn handleWindowUpdate(self: *Session, hdr: frames.FrameHeader, payload: []const u8, send: *std.ArrayList(u8)) !void {
        if (payload.len != 4) return error.ProtocolError;
        const inc: u32 = ((@as(u32, payload[0]) & 0x7f) << 24) | (@as(u32, payload[1]) << 16) | (@as(u32, payload[2]) << 8) | payload[3];
        if (inc == 0) return error.ProtocolError;
        if (hdr.stream_id == 0) {
            if (self.conn_send_window + inc > 0x7fffffff) return error.FlowControlError;
            self.conn_send_window += inc;
            // A connection-level WINDOW_UPDATE may unblock streams whose
            // pending response bodies were held by the connection window.
            var it = self.streams.iterator();
            while (it.next()) |e| {
                try self.flushPendingResponse(e.key_ptr.*, send);
            }
        } else {
            const st = self.streams.getPtr(hdr.stream_id) orelse {
                if (hdr.stream_id > self.max_stream_id) return error.ProtocolError;
                return; // closed stream
            };
            if (st.send_window + inc > 0x7fffffff) {
                self.streamErrorCode(hdr.stream_id, send, 0x3); // FLOW_CONTROL_ERROR
                return;
            }
            st.send_window += inc;
            // Resume any buffered response body.
            try self.flushPendingResponse(hdr.stream_id, send);
        }
    }

    fn handleHeaders(
        self: *Session,
        hdr: frames.FrameHeader,
        payload: []const u8,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        if (hdr.stream_id == 0) return error.ProtocolError;
        // Client-initiated streams use odd ids (RFC 9113 §5.1.1).
        if (hdr.stream_id % 2 == 0) return error.ProtocolError;
        if (hdr.stream_id < self.max_stream_id) {
            // A new stream with a numerically smaller id is a connection
            // error (RFC 9113 §5.1.1) unless it is a trailer/continuation of
            // the highest stream.
            if (hdr.stream_id != self.max_stream_id) return error.ProtocolError;
        }
        if (hdr.stream_id <= self.max_stream_id) {
            const existing = self.streams.getPtr(hdr.stream_id);
            const is_trailer = if (existing) |st| (st.body.items.len > 0 or st.end_stream_received) else false;
            if (is_trailer) {
                // Trailers (RFC 9113 §8.1): a HEADERS at the end of a request
                // body. Decode and discard; the END_STREAM flag may be here.
                var flds = std.ArrayList(hpack.Field).empty;
                defer flds.deinit(self.allocator);
                self.hpack_dec.decode(self.allocator, payload, &flds) catch return error.StreamError;
                var bad_trailer = false;
                for (flds.items) |f| {
                    if (f.name.len > 0 and f.name[0] == ':') bad_trailer = true;
                }
                for (flds.items) |f| {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
                if (bad_trailer) {
                    self.streamError(hdr.stream_id, send);
                    return;
                }
                if (hdr.flag_bits & frames.flags.end_stream != 0) {
                    if (existing) |st| {
                        st.end_stream_received = true;
                        try self.maybeRunRequest(hdr.stream_id, send, handler);
                    }
                }
                return;
            }
            // A second HEADERS on a request with no body is a stream error
            // (repeated request headers); on a fully closed stream it is
            // STREAM_CLOSED.
            if (existing != null) {
                self.streamError(hdr.stream_id, send);
                return;
            }
            self.streamErrorCode(hdr.stream_id, send, 0x5);
            return;
        }
        // Enforce the advertised concurrent-stream limit (RFC 9113 §5.1.2):
        // new streams beyond it are refused (RST_STREAM REFUSED_STREAM).
        if (self.streams.count() >= max_concurrent_streams) {
            self.streamError(hdr.stream_id, send);
            return;
        }
        self.max_stream_id = hdr.stream_id;
        // New stream.
        const st = try self.streams.getOrPut(hdr.stream_id);
        if (!st.found_existing) st.value_ptr.* = .{};
        // The per-stream send window (how much response DATA we may send)
        // is the peer's SETTINGS_INITIAL_WINDOW_SIZE (RFC 9113 §6.5.2).
        st.value_ptr.send_window = self.peer_initial_window;
        const stream = st.value_ptr;

        var block = payload;
        if (hdr.flag_bits & frames.flags.padded != 0) {
            if (payload.len < 1) return error.StreamError;
            const pad = payload[0];
            if (1 + pad > payload.len) return error.StreamError;
            block = payload[1 .. payload.len - pad];
        }
        if (hdr.flag_bits & frames.flags.priority != 0) {
            if (block.len < 5) return error.StreamError;
            const dep: u31 = @intCast(((@as(u32, block[0]) & 0x7f) << 24) | (@as(u32, block[1]) << 16) | (@as(u32, block[2]) << 8) | block[3]);
            if (dep == hdr.stream_id) {
                // RFC 9113 §5.3.1: a stream cannot depend on itself.
                self.streamError(hdr.stream_id, send);
                return;
            }
            block = block[5..];
        }

        if (hdr.flag_bits & frames.flags.end_headers != 0) {
            try self.decodeAndDispatch(hdr.stream_id, block);
        } else {
            // Continuation expected.
            self.pending_headers_stream = hdr.stream_id;
            self.pending_hpack_block.clearRetainingCapacity();
            try self.pending_hpack_block.appendSlice(self.allocator, block);
        }
        if (hdr.flag_bits & frames.flags.end_stream != 0) {
            stream.end_stream_received = true;
            try self.maybeRunRequest(hdr.stream_id, send, handler);
        }
    }

    fn handleContinuation(
        self: *Session,
        hdr: frames.FrameHeader,
        payload: []const u8,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        const ps = self.pending_headers_stream orelse return error.ProtocolError;
        if (hdr.stream_id != ps) return error.ProtocolError;
        try self.pending_hpack_block.appendSlice(self.allocator, payload);
        if (hdr.flag_bits & frames.flags.end_headers != 0) {
            const block = self.pending_hpack_block.items;
            const sid = ps;
            self.pending_headers_stream = null;
            try self.decodeAndDispatch(sid, block);
            // A HEADERS frame may have carried END_STREAM before the
            // CONTINUATION completed (RFC 9113 §6.2); dispatch now.
            if (self.streams.getPtr(sid)) |st| {
                if (st.end_stream_received) {
                    try self.maybeRunRequest(sid, send, handler);
                }
            }
        }
    }

    /// HPACK-decode the (possibly multi-frame) header block and assemble the
    /// request headers into the stream.
    fn decodeAndDispatch(
        self: *Session,
        stream_id: u31,
        block: []const u8,
    ) !void {
        const st = self.streams.getPtr(stream_id) orelse return error.ProtocolError;
        // The stream's Request (arena) is the per-request scratch: HPACK
        // fields allocate bump-style, no per-field syscalls. Freed when the
        // Request is pooled and its arena reset on reuse.
        if (st.request == null) {
            var r = self.request_pool.pop() orelse parser.Request.initWithLimits(self.allocator, self.max_headers);
            r.reset(); // clear the previous stream's arena before reuse
            st.request = r;
        }
        const arena_alloc = st.request.?.arena.asAllocator();
        var fields = std.ArrayList(hpack.Field).empty;
        defer fields.deinit(arena_alloc);
        self.hpack_dec.decode(arena_alloc, block, &fields) catch |e| {
            return switch (e) {
                error.ProtocolError, error.CompressionError, error.Truncated, error.InvalidHuffman => error.StreamError,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        // Fields live in the Request arena (bump-owned); just record them.
        for (fields.items) |f| {
            try st.headers.append(arena_alloc, .{ .name = f.name, .value = f.value, .value_len = f.value.len });
        }
    }

    fn handleData(
        self: *Session,
        hdr: frames.FrameHeader,
        payload: []const u8,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        if (hdr.stream_id == 0) return error.ProtocolError;
        const st_opt = self.streams.getPtr(hdr.stream_id);
        if (st_opt == null) {
            if (hdr.stream_id > self.max_stream_id) return error.ProtocolError; // idle: conn error
            return; // closed stream: ignore DATA on a closed stream
        }
        if (st_opt.?.state != .open) {
            self.streamErrorCode(hdr.stream_id, send, 0x5); // STREAM_CLOSED
            return;
        }
        var st = st_opt.?;
        var data = payload;
        if (hdr.flag_bits & frames.flags.padded != 0) {
            if (payload.len < 1) return error.StreamError;
            const pad = payload[0];
            if (1 + pad > payload.len) return error.StreamError;
            data = payload[1 .. payload.len - pad];
        }
        // Flow control: count consumed bytes against the connection and
        // stream receive windows; send WINDOW_UPDATE when half is free.
        if (data.len > st.recv_window or data.len > self.conn_recv_window) return error.StreamError;
        st.recv_window -= @intCast(data.len);
        self.conn_recv_window -= @intCast(data.len);
        try st.body.appendSlice(st.request.?.arena.asAllocator(), data);

        if (st.recv_window < (default_window / 2)) {
            const inc = default_window - st.recv_window;
            st.recv_window += inc;
            try frames.writeWindowUpdate(send, self.allocator, hdr.stream_id, inc);
        }
        if (self.conn_recv_window < (default_window / 2)) {
            const inc = default_window - self.conn_recv_window;
            self.conn_recv_window += inc;
            try frames.writeWindowUpdate(send, self.allocator, 0, inc);
        }

        if (hdr.flag_bits & frames.flags.end_stream != 0) {
            st.end_stream_received = true;
            try self.maybeRunRequest(hdr.stream_id, send, handler);
        }
    }

    /// When a stream has both headers (END_HEADERS) and the full body
    /// (END_STREAM), assemble the request, run the pipeline, and frame the
    /// response.
    fn maybeRunRequest(
        self: *Session,
        stream_id: u31,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        const st = self.streams.getPtr(stream_id) orelse return;
        if (!st.end_stream_received) return;

        // The stream's request was created (and its arena reset) in
        // decodeAndDispatch; the decoded fields still live in that arena, so
        // it must not be reset again here.
        const req = &st.request.?;
        self.max_headers = handler.limits.max_headers;
        var method_set = false;
        var path_set = false;
        var scheme_set = false;
        var authority: ?[]const u8 = null;
        var content_length: usize = 0;
        var content_length_set = false;
        var saw_regular_header = false;
        var pseudo_seen = [_]bool{false} ** 4; // method, scheme, authority, path
        for (st.headers.items) |f| {
            const is_pseudo = f.name.len > 0 and f.name[0] == ':';
            if (is_pseudo and saw_regular_header) {
                // RFC 9113 §8.1.2.1: pseudo-headers MUST precede regular ones.
                self.streamError(stream_id, send);
                return;
            }
            if (std.mem.eql(u8, f.name, ":method")) {
                if (pseudo_seen[0]) {
                    self.streamError(stream_id, send);
                    return;
                }
                pseudo_seen[0] = true;
                const m = parser.Method.fromString(f.value) orelse {
                    // Unknown method: answer 501.
                    try self.writeErrorResponse(stream_id, .not_implemented, send, handler);
                    st.state = .closed;
                    return;
                };
                req.method = m;
                method_set = true;
            } else if (std.mem.eql(u8, f.name, ":path")) {
                if (pseudo_seen[3]) {
                    self.streamError(stream_id, send);
                    return;
                }
                pseudo_seen[3] = true;
                // RFC 9113 §8.1.2.3: an empty :path is a malformed request
                // (except OPTIONS *, handled below by the pipeline).
                if (f.value.len == 0) {
                    self.streamError(stream_id, send);
                    return;
                }
                req.target = f.value;
                const q = std.mem.indexOfScalar(u8, f.value, '?');
                if (q) |qi| {
                    req.decoded_target = f.value[0..qi];
                    req.query_string = f.value[qi..];
                } else {
                    req.decoded_target = f.value;
                }
                path_set = true;
            } else if (std.mem.eql(u8, f.name, ":scheme")) {
                if (pseudo_seen[1]) {
                    self.streamError(stream_id, send);
                    return;
                }
                pseudo_seen[1] = true;
                scheme_set = true;
            } else if (std.mem.eql(u8, f.name, ":authority")) {
                if (pseudo_seen[2]) {
                    self.streamError(stream_id, send);
                    return;
                }
                pseudo_seen[2] = true;
                authority = f.value;
            } else if (std.mem.eql(u8, f.name, "content-length")) {
                content_length = std.fmt.parseInt(usize, f.value, 10) catch {
                    self.streamError(stream_id, send);
                    return;
                };
                content_length_set = true;
            } else {
                // Regular headers: classify the connection-specific set by
                // comptime hash dispatch (single integer compare per name).
                switch (hdrHash(f.name)) {
                    hdrHash("te") => {
                        if (!std.ascii.eqlIgnoreCase(f.value, "trailers")) {
                            self.streamError(stream_id, send); // §8.1.2.2
                            return;
                        }
                    },
                    hdrHash("connection"), hdrHash("keep-alive"), hdrHash("proxy-connection"), hdrHash("transfer-encoding"), hdrHash("upgrade") => {
                        self.streamError(stream_id, send); // §8.1.2.6
                        return;
                    },
                    else => {},
                }
                // §8.1.2.1: unknown pseudo-headers and response pseudo-headers
                // in a request are malformed.
                if (f.name.len > 0 and f.name[0] == ':') {
                    self.streamError(stream_id, send);
                    return;
                }
                // §8.1.2: header names MUST be lowercase.
                var has_upper = false;
                for (f.name) |c| {
                    if (std.ascii.isUpper(c)) {
                        has_upper = true;
                        break;
                    }
                }
                if (has_upper) {
                    self.streamError(stream_id, send);
                    return;
                }
                saw_regular_header = true;
                req.addHeaderParsed(f.name, f.value) catch |e| switch (e) {
                    error.HeaderCountExceeded, error.Malformed => {
                        self.streamError(stream_id, send);
                        return;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
        }
        if (!method_set or !path_set or !scheme_set) {
            // Missing required pseudo-header (RFC 9113 §8.1.2.6): stream
            // error (RST_STREAM), not a connection error.
            self.streamError(stream_id, send);
            return;
        }
        // :authority becomes Host.
        if (authority) |a| {
            req.addHeaderParsed("host", a) catch {};
        }
        req.keep_alive = true;
        // The body is whatever DATA carried (flow-controlled).
        req.body = st.body.items;
        if (content_length_set and req.body.len != content_length) {
            // Content-Length does not match the DATA payload: stream error.
            self.streamError(stream_id, send);
            return;
        }

        var resp = response_mod.Response.init(.ok);
        var ctx = pipeline.Context{
            .req = req,
            .resp = &resp,
            .allocator = handler.allocator,
            .client_ip = handler.client_ip,
            .stats = handler.stats,
            .static_cache = handler.static_cache,
            .limits = handler.limits,
        };
        if (handler.server.handleRequest(&ctx)) |outcome| {
            if (outcome == .not_handled) {
                resp = response_mod.Response.init(.not_found);
                resp.setBody(response_mod.Status.not_found.reasonPhrase());
            }
        } else |_| {
            resp = response_mod.Response.init(.internal_error);
            resp.setBody(response_mod.Status.internal_error.reasonPhrase());
        }
        st.responded = true;
        try self.frameResponse(stream_id, &resp, req.method == .head, send, handler);
    }

    /// A stream-level protocol violation (RFC 9113 §5.4.2): send RST_STREAM
    /// and drop the stream; the connection stays up.
    fn streamError(self: *Session, stream_id: u31, send: *std.ArrayList(u8)) void {
        self.streamErrorCode(stream_id, send, 0x1); // PROTOCOL_ERROR
    }

    fn streamErrorCode(self: *Session, stream_id: u31, send: *std.ArrayList(u8), code: u32) void {
        frames.writeRstStream(send, self.allocator, stream_id, code) catch return;
        if (self.streams.getPtr(stream_id)) |st| {
            st.state = .closed;
            st.reset = true;
        }
    }

    fn writeErrorResponse(
        self: *Session,
        stream_id: u31,
        status: response_mod.Status,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        var resp = response_mod.Response.init(status);
        resp.setBody(status.reasonPhrase());
        try self.frameResponse(stream_id, &resp, false, send, handler);
    }

    /// Serialize a pipeline response into HEADERS + DATA frames.
    fn frameResponse(
        self: *Session,
        stream_id: u31,
        resp: *response_mod.Response,
        is_head: bool,
        send: *std.ArrayList(u8),
        handler: *const Handler,
    ) !void {
        self.block_scratch.clearRetainingCapacity();
        const block = &self.block_scratch;
        // :status
        var status_buf: [8]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{@intFromEnum(resp.status)}) catch "500";
        try hpack.encodeField(block, self.allocator, ":status", status_str);
        // Date + Server (nginx-parity, both free).
        try hpack.encodeField(block, self.allocator, "date", handler.date_header);
        try hpack.encodeField(block, self.allocator, "server", handler.version_string);
        // Response headers (skip connection-specific ones, and content-length
        // is implicit in the DATA framing).
        for (resp.headers[0..resp.header_count]) |h| {
            if (std.mem.eql(u8, h.name, "connection") or
                std.mem.eql(u8, h.name, "keep-alive") or
                std.mem.eql(u8, h.name, "transfer-encoding"))
                continue;
            if (std.mem.eql(u8, h.name, "content-length")) continue;
            try hpack.encodeField(block, self.allocator, h.name, h.value);
        }
        // Body: buffered or read from the file (sendfile under h2 is
        // deferred; the file is read into a buffer and framed).
        var file_buf: ?[]u8 = null;
        defer if (file_buf) |b| handler.allocator.free(b);
        var body: []const u8 = resp.body;
        if (resp.body_from_file) {
            const size: usize = @intCast(resp.file_len - resp.file_offset);
            const buf = try handler.allocator.alloc(u8, size);
            file_buf = buf;
            var read_total: usize = 0;
            while (read_total < size) {
                const n = std.posix.pread(resp.file_fd, buf[read_total..], resp.file_offset + read_total) catch break;
                if (n == 0) break;
                read_total += n;
            }
            body = buf[0..read_total];
        }
        // HEAD: no body (RFC 9113 §8.1 — a HEAD response carries only the
        // headers). Matches the HTTP/1 serializer.
        if (is_head) body = &.{};

        // Send HEADERS. body_len 0 -> END_STREAM on the HEADERS frame.
        const end_stream = body.len == 0;
        try frames.writeHeaders(send, self.allocator, stream_id, block.items, end_stream, self.peer_max_frame_size);
        if (body.len > 0) {
            // DATA frames, flow-control limited. writeData copies into `send`
            // and any flow-control overflow into the stream's pending buffer,
            // so resp.body can be freed as soon as we return.
            try self.writeBodyFrames(stream_id, body, send);
        }

        // Free an allocator-owned module body (gzip, stub_status, autoindex,
        // proxy, error pages...) exactly like the HTTP/1 path's
        // freeResponseBody.
        if (resp.body_owned and !resp.body_from_file) {
            handler.allocator.free(resp.body);
            resp.body_owned = false;
        }
        // The response stream is done on our side (writeData already sets
        // end_stream_sent for the buffered path; the empty/HEAD path needs
        // it explicitly so the stream can be cleaned up).
        self.markStreamClosed(stream_id);
        self.maybeCloseStream(stream_id);
    }

    /// Write the response body as DATA frames, respecting the connection and
    /// stream send windows. If the windows are exhausted, buffer the rest in
    /// the stream's `pending_response` for emission on WINDOW_UPDATE.
    fn writeBodyFrames(
        self: *Session,
        stream_id: u31,
        body: []const u8,
        send: *std.ArrayList(u8),
    ) !void {
        const st = self.streams.getPtr(stream_id) orelse return;
        var off: usize = 0;
        while (off < body.len) {
            const allowed = @min(st.send_window, self.conn_send_window);
            if (allowed == 0) {
                // Buffer the remainder.
                try st.pending_response.appendSlice(self.allocator, body[off..]);
                return;
            }
            const chunk_u32 = @min(
                @as(u32, @intCast(body.len - off)),
                @min(allowed, self.peer_max_frame_size),
            );
            const chunk: usize = chunk_u32;
            const is_last = off + chunk >= body.len;
            try frames.writeData(send, self.allocator, stream_id, body[off .. off + chunk], is_last, self.peer_max_frame_size);
            st.send_window -= chunk_u32;
            self.conn_send_window -= chunk_u32;
            off += chunk;
            if (is_last) {
                st.end_stream_sent = true;
            }
        }
    }

    fn flushPendingResponse(self: *Session, stream_id: u31, send: *std.ArrayList(u8)) !void {
        const st = self.streams.getPtr(stream_id) orelse return;
        if (st.pending_response.items.len == 0) return;
        const pending = st.pending_response.items;
        st.pending_response.clearRetainingCapacity();
        try self.writeBodyFrames(stream_id, pending, send);
        self.maybeCloseStream(stream_id);
    }

    /// Mark a stream's response fully sent.
    fn markStreamClosed(self: *Session, stream_id: u31) void {
        const st = self.streams.getPtr(stream_id) orelse return;
        st.end_stream_sent = true;
    }

    /// Remove a fully closed stream (both directions done) and free it.
    fn maybeCloseStream(self: *Session, stream_id: u31) void {
        const st = self.streams.getPtr(stream_id) orelse return;
        if (st.end_stream_sent and st.end_stream_received and st.pending_response.items.len == 0) {
            self.destroyStream(st);
            _ = self.streams.remove(stream_id);
        }
    }
};

const testing = std.testing;

test "preface detection" {
    try testing.expect(Session.looksLikeHttp2Preface("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "xxxxxxxx"));
    try testing.expect(!Session.looksLikeHttp2Preface("GET / HTTP/1.1\r\n"));
}

test "session processes a GET request end to end" {
    // Build a synthetic client: preface + SETTINGS + HEADERS(:method GET,
    // :path /, :scheme http, :authority localhost) with END_STREAM.
    var send = std.ArrayList(u8).empty;
    defer send.deinit(testing.allocator);

    var s = Session.init(testing.allocator);
    defer s.deinit();

    // HPACK block for the request headers (literal, no indexing).
    var hb = std.ArrayList(u8).empty;
    defer hb.deinit(testing.allocator);
    try hpack.encodeField(&hb, testing.allocator, ":method", "GET");
    try hpack.encodeField(&hb, testing.allocator, ":scheme", "http");
    try hpack.encodeField(&hb, testing.allocator, ":authority", "localhost");
    try hpack.encodeField(&hb, testing.allocator, ":path", "/");

    // HEADERS frame (stream 1, END_HEADERS | END_STREAM).
    var hdr: [9]u8 = undefined;
    var fhdr = frames.FrameHeader{ .length = @intCast(hb.items.len), .type = .headers, .flag_bits = frames.flags.end_headers | frames.flags.end_stream, .stream_id = 1 };
    fhdr.encode(&hdr);

    var req_bytes = std.ArrayList(u8).empty;
    defer req_bytes.deinit(testing.allocator);
    try req_bytes.appendSlice(testing.allocator, Session.preface); // client preface
    try req_bytes.appendSlice(testing.allocator, &hdr);
    try req_bytes.appendSlice(testing.allocator, hb.items);

    var handler = Session.Handler{
        .server = &server_mod.Server.default(),
        .allocator = testing.allocator,
        .limits = &limits_mod.Limits{},
        .date_header = "Sat, 15 Aug 2026 00:00:00 GMT",
        .version_string = "Zocket/1.0.0",
    };
    _ = try s.process(req_bytes.items, &send, &handler);

    // The response frames should include a HEADERS frame with :status 200.
    var off: usize = 0;
    var found_headers = false;
    while (off + 9 <= send.items.len) {
        const fh = frames.parseHeader(send.items[off..]).?;
        if (off + 9 + fh.length > send.items.len) break;
        if (fh.type == .headers and fh.stream_id == 1) found_headers = true;
        off += 9 + fh.length;
    }
    try testing.expect(found_headers);
}

test "session rejects HTTP/1 after preface expectation" {
    try testing.expect(!Session.looksLikeHttp2Preface("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
}

test "session: HEAD request over h2 produces a HEADERS-only response (no DATA)" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    var send = std.ArrayList(u8).empty;
    defer send.deinit(testing.allocator);

    var hb = std.ArrayList(u8).empty;
    defer hb.deinit(testing.allocator);
    try hpack.encodeField(&hb, testing.allocator, ":method", "HEAD");
    try hpack.encodeField(&hb, testing.allocator, ":scheme", "http");
    try hpack.encodeField(&hb, testing.allocator, ":path", "/");
    var fh = frames.FrameHeader{
        .length = @intCast(hb.items.len),
        .type = .headers,
        .flag_bits = frames.flags.end_headers | frames.flags.end_stream,
        .stream_id = 1,
    };
    var req_bytes = std.ArrayList(u8).empty;
    defer req_bytes.deinit(testing.allocator);
    try req_bytes.appendSlice(testing.allocator, Session.preface);
    var hdr: [9]u8 = undefined;
    fh.encode(&hdr);
    try req_bytes.appendSlice(testing.allocator, &hdr);
    try req_bytes.appendSlice(testing.allocator, hb.items);

    var handler = Session.Handler{
        .server = &server_mod.Server.default(),
        .allocator = testing.allocator,
        .limits = &limits_mod.Limits{},
        .date_header = "Sat, 15 Aug 2026 00:00:00 GMT",
        .version_string = "Zocket/1.0.0",
    };
    _ = try s.process(req_bytes.items, &send, &handler);

    // Assert: a HEADERS frame with END_STREAM, and no DATA frame.
    var off: usize = 0;
    var headers_found = false;
    var data_found = false;
    while (off + 9 <= send.items.len) {
        const f = frames.parseHeader(send.items[off..]).?;
        if (off + 9 + f.length > send.items.len) break;
        if (f.type == .headers and f.stream_id == 1 and f.flag_bits & frames.flags.end_stream != 0) headers_found = true;
        if (f.type == .data) data_found = true;
        off += 9 + f.length;
    }
    try testing.expect(headers_found);
    try testing.expect(!data_found);
}

test "session: an allocator-owned module body is freed (gzip path, no leak)" {
    // Server with a gzip route (content=echo, log=gzip), like the example
    // config. Run a gzip-compressible POST through the session; if the
    // compressed body is not freed, the testing allocator reports a leak.
    const srv = server_mod.Server.comptimeInit(comptime server_mod.Config.fromJsonComptime(
        \\{ "routes": [ { "path": "/", "modules": { "content": "echo", "log": "gzip" } } ] }
    ));

    var s = Session.init(testing.allocator);
    defer s.deinit();
    var send = std.ArrayList(u8).empty;
    defer send.deinit(testing.allocator);

    var hb = std.ArrayList(u8).empty;
    defer hb.deinit(testing.allocator);
    try hpack.encodeField(&hb, testing.allocator, ":method", "POST");
    try hpack.encodeField(&hb, testing.allocator, ":scheme", "http");
    try hpack.encodeField(&hb, testing.allocator, ":path", "/");
    try hpack.encodeField(&hb, testing.allocator, "accept-encoding", "gzip");
    var fh = frames.FrameHeader{
        .length = @intCast(hb.items.len),
        .type = .headers,
        .flag_bits = frames.flags.end_headers,
        .stream_id = 1,
    };
    var req_bytes = std.ArrayList(u8).empty;
    defer req_bytes.deinit(testing.allocator);
    try req_bytes.appendSlice(testing.allocator, Session.preface);
    var hdr: [9]u8 = undefined;
    fh.encode(&hdr);
    try req_bytes.appendSlice(testing.allocator, &hdr);
    try req_bytes.appendSlice(testing.allocator, hb.items);
    // Compressible body (>= min_compress_bytes) as a DATA frame with END_STREAM.
    const body = "compressible-body-" ** 20;
    var dfh = frames.FrameHeader{
        .length = @intCast(body.len),
        .type = .data,
        .flag_bits = frames.flags.end_stream,
        .stream_id = 1,
    };
    dfh.encode(&hdr);
    try req_bytes.appendSlice(testing.allocator, &hdr);
    try req_bytes.appendSlice(testing.allocator, body);

    var handler = Session.Handler{
        .server = &srv,
        .allocator = testing.allocator,
        .limits = &limits_mod.Limits{},
        .date_header = "Sat, 15 Aug 2026 00:00:00 GMT",
        .version_string = "Zocket/1.0.0",
    };
    _ = try s.process(req_bytes.items, &send, &handler);
    // Deinits release everything; the testing allocator fails the test if the
    // gzip body leaked.
}
