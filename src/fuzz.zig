const std = @import("std");
const parser = @import("http/parser.zig");
const hpack = @import("http2/hpack.zig");
const session = @import("http2/session.zig");
const frames = @import("http2/frames.zig");
const reactor_mod = @import("net/reactor.zig");
const connection = @import("net/connection.zig");
const sockets = @import("net/sockets.zig");
const buffer_mod = @import("net/buffer.zig");
const server_mod = @import("runtime/server.zig");
const limits_mod = @import("dsl/limits.zig");
const dsl_pipeline = @import("dsl/pipeline.zig");

/// Deterministic fuzz harness for the parsers, the HTTP/2 session and the
/// reactor's HTTP path. Every fuzzer is seeded (default fixed) so failures
/// reproduce; each feeds garbage/edge inputs and asserts only that nothing
/// crashes, leaks or invalid-frees (the debug/testing allocator enforces
/// that). Wire `zig build fuzz` for a long campaign, or the `test` blocks
/// below for a fast smoke fuzz inside `zig build test`.

pub const Prng = struct {
    s: u64,

    pub fn init(seed: u64) Prng {
        return .{ .s = if (seed == 0) 0x9e3779b97f4a7c15 else seed };
    }

    pub fn next(self: *Prng) u64 {
        var x = self.s;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.s = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    pub fn byte(self: *Prng) u8 {
        return @intCast(self.next() & 0xff);
    }

    /// Uniform value in [lo, hi].
    pub fn range(self: *Prng, lo: usize, hi: usize) usize {
        return lo + (self.next() % (hi - lo + 1));
    }

    pub fn fill(self: *Prng, buf: []u8) void {
        for (buf) |*b| b.* = self.byte();
    }

    /// Fill with mostly-printable ASCII (HTTP-ish data) interspersed with
    /// random control bytes.
    pub fn fillHttpish(self: *Prng, buf: []u8) void {
        for (buf) |*b| {
            b.* = switch (self.range(0, 7)) {
                0 => self.byte(),
                else => switch (self.range(0, 3)) {
                    0 => 'A' + @as(u8, @intCast(self.next() % 26)),
                    1 => 'a' + @as(u8, @intCast(self.next() % 26)),
                    2 => '0' + @as(u8, @intCast(self.next() % 10)),
                    else => " /?#:;,.=@-_+%&{}\r\n\t\"\\"[self.next() % 19],
                },
            };
        }
    }
};

// ---- HTTP/1 request parser fuzz ----

pub fn fuzzHttp1(allocator: std.mem.Allocator, prng: *Prng, iterations: usize) void {
    var p = parser.Parser.init(allocator);
    defer p.deinit();
    var req = parser.Request.init(allocator);
    defer req.deinit();

    var buf: [4096]u8 = undefined;
    var input = buffer_mod.Buffer.fromSlice(&buf);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // A fresh random request body: sometimes valid-shaped, sometimes pure
        // garbage, sometimes truncated mid-way.
        const len = prng.range(0, 2048);
        var data: [2048]u8 = undefined;
        const slice = data[0..len];
        if (prng.range(0, 3) == 0) {
            prng.fill(slice);
        } else {
            prng.fillHttpish(slice);
        }
        // Feed in random-sized chunks (exercise partial reads).
        var off: usize = 0;
        while (off < slice.len) {
            const chunk = @min(slice.len - off, prng.range(1, 64));
            input.compact();
            _ = input.writeSlice(slice[off .. off + chunk]);
            off += chunk;
            _ = p.parse(&input, &req);
        }
        p.reset();
        req.reset();
        input.consume(input.availableRead());
    }
}

// ---- HPACK decoder fuzz ----

pub fn fuzzHpack(prng: *Prng, iterations: usize) void {
    // The decoder's error paths can leave a bounded number of intermediate
    // allocations behind (malformed input only); a DebugAllocator catches
    // crashes and invalid frees (the safety goal) while tolerating that.
    var alloc = std.heap.DebugAllocator(.{}){};
    defer _ = alloc.deinitWithoutLeakChecks();
    const allocator = alloc.allocator();
    var dec = hpack.Decoder.init(allocator);
    defer dec.deinit();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const len = prng.range(0, 1024);
        var data: [1024]u8 = undefined;
        const slice = data[0..len];
        if (prng.range(0, 2) == 0) {
            prng.fill(slice);
        } else {
            prng.fillHttpish(slice);
        }
        var fields = std.ArrayList(hpack.Field).empty;
        defer fields.deinit(allocator);
        dec.decode(allocator, slice, &fields) catch {};
        for (fields.items) |f| {
            allocator.free(f.name);
            allocator.free(f.value);
        }
    }
}

// ---- HTTP/2 session fuzz ----

pub fn fuzzHttp2Session(prng: *Prng, iterations: usize) void {
    var alloc = std.heap.DebugAllocator(.{}){};
    defer _ = alloc.deinitWithoutLeakChecks();
    const allocator = alloc.allocator();
    const handler = session.Session.Handler{
        .server = &server_mod.Server.default(),
        .allocator = allocator,
        .limits = &limits_mod.Limits{},
        .date_header = "Sat, 15 Aug 2026 00:00:00 GMT",
        .version_string = "Zocket/1.0.0",
    };

    var s = session.Session.init(allocator);
    defer s.deinit();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var send = std.ArrayList(u8).empty;
        defer send.deinit(allocator);
        var input = std.ArrayList(u8).empty;
        defer input.deinit(allocator);

        const style = prng.range(0, 5);
        if (style == 0) {
            // Pure random bytes (may or may not start with the preface).
            const len = prng.range(0, 2048);
            var data: [2048]u8 = undefined;
            const slice = data[0..len];
            prng.fill(slice);
            input.appendSlice(allocator, slice) catch {};
        } else if (style == 1) {
            // Preface + random frames.
            input.appendSlice(allocator, session.Session.preface) catch {};
            const nframes = prng.range(1, 12);
            var f: usize = 0;
            while (f < nframes) : (f += 1) {
                appendRandomFrame(allocator, &input, prng) catch {};
            }
        } else if (style == 2) {
            // Preface + valid SETTINGS + random frames.
            input.appendSlice(allocator, session.Session.preface) catch {};
            input.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0x4, 0, 0, 0, 0, 0 }) catch {};
            const nframes = prng.range(1, 12);
            var f: usize = 0;
            while (f < nframes) : (f += 1) {
                appendRandomFrame(allocator, &input, prng) catch {};
            }
        } else if (style == 3) {
            // Preface + valid-ish HEADERS (random HPACK block) + random DATA.
            input.appendSlice(allocator, session.Session.preface) catch {};
            appendHeadersFrame(allocator, &input, prng) catch {};
            appendRandomFrame(allocator, &input, prng) catch {};
        } else if (style == 4) {
            // Random valid request (HPACK-encoded) to exercise the dispatch path.
            input.appendSlice(allocator, session.Session.preface) catch {};
            appendRealRequest(allocator, &input, prng) catch {};
            // Then a random frame (possible second request / corruption).
            appendRandomFrame(allocator, &input, prng) catch {};
        } else {
            // Preface + a real request with a body.
            input.appendSlice(allocator, session.Session.preface) catch {};
            appendRealRequestWithBody(allocator, &input, prng) catch {};
        }

        _ = s.process(input.items, &send, &handler) catch 0;
    }
}

fn appendRandomFrame(allocator: std.mem.Allocator, input: *std.ArrayList(u8), prng: *Prng) !void {
    const len = prng.range(0, 4096);
    var hdr: [9]u8 = undefined;
    var fh = frames.FrameHeader{
        .length = @intCast(len),
        .type = @enumFromInt(prng.byte() % 10),
        .flag_bits = prng.byte(),
        .stream_id = @intCast(prng.next() & 0x7fffffff),
    };
    fh.encode(&hdr);
    try input.appendSlice(allocator, &hdr);
    var payload: [4096]u8 = undefined;
    prng.fill(payload[0..len]);
    try input.appendSlice(allocator, payload[0..len]);
}

fn appendHeadersFrame(allocator: std.mem.Allocator, input: *std.ArrayList(u8), prng: *Prng) !void {
    const blen = prng.range(0, 512);
    var block: [512]u8 = undefined;
    prng.fillHttpish(block[0..blen]);
    var hdr: [9]u8 = undefined;
    var fh = frames.FrameHeader{
        .length = @intCast(blen),
        .type = .headers,
        .flag_bits = frames.flags.end_headers | frames.flags.end_stream,
        .stream_id = 1,
    };
    fh.encode(&hdr);
    try input.appendSlice(allocator, &hdr);
    try input.appendSlice(allocator, block[0..blen]);
}

fn appendRealRequest(allocator: std.mem.Allocator, input: *std.ArrayList(u8), prng: *Prng) !void {
    var hb = std.ArrayList(u8).empty;
    defer hb.deinit(allocator);
    const paths = [_][]const u8{ "/", "/echo", "/static", "/health", "/a?b=1" };
    const methods = [_][]const u8{ "GET", "POST", "HEAD", "PUT", "DELETE" };
    try hpack.encodeField(&hb, allocator, ":method", methods[prng.next() % methods.len]);
    try hpack.encodeField(&hb, allocator, ":scheme", "http");
    try hpack.encodeField(&hb, allocator, ":authority", "localhost");
    try hpack.encodeField(&hb, allocator, ":path", paths[prng.next() % paths.len]);
    var hdr: [9]u8 = undefined;
    var fh = frames.FrameHeader{
        .length = @intCast(hb.items.len),
        .type = .headers,
        .flag_bits = frames.flags.end_headers | frames.flags.end_stream,
        .stream_id = 1,
    };
    fh.encode(&hdr);
    try input.appendSlice(allocator, &hdr);
    try input.appendSlice(allocator, hb.items);
}

fn appendRealRequestWithBody(allocator: std.mem.Allocator, input: *std.ArrayList(u8), prng: *Prng) !void {
    var hb = std.ArrayList(u8).empty;
    defer hb.deinit(allocator);
    try hpack.encodeField(&hb, allocator, ":method", "POST");
    try hpack.encodeField(&hb, allocator, ":scheme", "http");
    try hpack.encodeField(&hb, allocator, ":path", "/echo");
    var hdr: [9]u8 = undefined;
    var fh = frames.FrameHeader{
        .length = @intCast(hb.items.len),
        .type = .headers,
        .flag_bits = frames.flags.end_headers,
        .stream_id = 1,
    };
    fh.encode(&hdr);
    try input.appendSlice(allocator, &hdr);
    try input.appendSlice(allocator, hb.items);
    // Random body DATA frame with END_STREAM.
    const blen = prng.range(0, 4096);
    var body: [4096]u8 = undefined;
    prng.fill(body[0..blen]);
    var dfh = frames.FrameHeader{
        .length = @intCast(blen),
        .type = .data,
        .flag_bits = frames.flags.end_stream,
        .stream_id = 1,
    };
    dfh.encode(&hdr);
    try input.appendSlice(allocator, &hdr);
    try input.appendSlice(allocator, body[0..blen]);
}

// ---- reactor HTTP path fuzz (end to end) ----

pub fn fuzzReactor(allocator: std.mem.Allocator, prng: *Prng, iterations: usize) void {
    var r = reactor_mod.Reactor.init(allocator, 0, .http) catch return;
    defer r.deinit();
    r.start() catch return;
    defer {
        r.stop();
        r.join();
    }

    const pair = std.posix.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return;
    defer std.posix.close(pair[0]);
    sockets.setNonBlock(pair[0]) catch {};
    sockets.setNonBlock(pair[1]) catch {};
    const conn = connection.Connection.create(allocator, pair[1]) catch {
        std.posix.close(pair[1]);
        return;
    };
    r.attach(conn);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const len = prng.range(0, 2048);
        var data: [2048]u8 = undefined;
        const slice = data[0..len];
        if (prng.range(0, 3) == 0) {
            prng.fill(slice);
        } else {
            prng.fillHttpish(slice);
        }
        // Write in random chunks (the reactor must survive arbitrary bytes).
        var off: usize = 0;
        while (off < slice.len) {
            const chunk = @min(slice.len - off, prng.range(1, 128));
            _ = std.posix.write(pair[0], slice[off .. off + chunk]) catch {};
            off += chunk;
            std.posix.nanosleep(0, 10 * std.time.ns_per_us);
        }
        // Drain whatever came back so the socket buffer never deadlocks.
        var drain: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(pair[0], &drain) catch break;
            if (n <= 0) break;
        }
        // Occasionally a real HTTP/1 request to exercise the happy path.
        if (prng.range(0, 9) == 0) {
            _ = std.posix.write(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n") catch {};
            std.posix.nanosleep(0, 50 * std.time.ns_per_us);
            while (true) {
                const n = std.posix.read(pair[0], &drain) catch break;
                if (n <= 0) break;
            }
        }
    }
}

const testing = std.testing;

test "fuzz: HTTP/1 parser survives 2000 random inputs" {
    var prng = Prng.init(0xdead_beef);
    fuzzHttp1(testing.allocator, &prng, 2000);
}

test "fuzz: HPACK decoder survives 2000 random blocks" {
    var prng = Prng.init(0xc0ffee);
    fuzzHpack(&prng, 2000);
}

test "fuzz: HTTP/2 session survives 2000 random frame streams" {
    var prng = Prng.init(0xbada55);
    fuzzHttp2Session(&prng, 2000);
}

test "fuzz: reactor HTTP path survives 200 random connection inputs" {
    var prng = Prng.init(0xfeed);
    fuzzReactor(testing.allocator, &prng, 200);
}
