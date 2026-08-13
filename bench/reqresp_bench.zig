//! Parameterized request-parse / response-build micro-benchmark (Ziglet
//! side), paired with bench/reqresp_bench_httpx.zig (httpx.zig side).
//!
//! Runs the full request x response variant matrix, or a subset via CLI:
//!   --req <name>     only the named request variant (parse op)
//!   --resp <name>    only the named response variant (build op)
//!   --iters N        iterations per round (default 100000)
//!   --rounds N       rounds (default 5)
//!
//! Variant tables are identical on both sides so operations compare
//! one-for-one.

const std = @import("std");
const ziglet = @import("ziglet");

const http_parser = ziglet.http.parser;
const http_response = ziglet.http.response;
const buffer_mod = ziglet.buffer;

const RequestVariant = struct { name: []const u8, wire: []const u8 };

const body_64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const body_1k = "The quick brown fox jumps over the lazy dog. " ** 22; // 990B, padded below

const request_variants = [_]RequestVariant{
    .{ .name = "get_min", .wire = "GET / HTTP/1.1\r\n\r\n" },
    .{
        .name = "get_4h",
        .wire = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench-agent/1.0\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n",
    },
    .{
        .name = "post_4h_64b",
        .wire = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Type: text/plain\r\nAccept: */*\r\nContent-Length: 64\r\n\r\n" ++ body_64,
    },
    .{
        .name = "post_8h_1k",
        .wire = "POST /submit HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench-agent/1.0\r\nAccept: */*\r\nContent-Type: text/plain\r\nX-Bench-One: 1\r\nX-Bench-Two: 2\r\nContent-Length: 1024\r\n\r\n" ++ (body_1k ++ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
    },
};

const ResponseVariant = struct {
    name: []const u8,
    status: http_response.Status,
    /// Flat name, value, name, value...
    headers: []const []const u8,
    body: []const u8,
};

const response_variants = [_]ResponseVariant{
    .{ .name = "empty", .status = .ok, .headers = &.{}, .body = "" },
    .{
        .name = "small",
        .status = .ok,
        .headers = &.{ "Content-Type", "text/plain" },
        .body = "Hello, World!",
    },
    .{
        .name = "medium",
        .status = .ok,
        .headers = &.{
            "Content-Type",  "text/html",
            "Cache-Control", "max-age=3600",
            "X-Bench-One",   "1",
            "X-Bench-Two",   "2",
            "ETag",          "\"abc123\"",
            "Vary",          "Accept-Encoding",
        },
        .body = body_64 ++ body_64 ++ body_64 ++ body_64,
    },
    .{
        .name = "notfound",
        .status = .not_found,
        .headers = &.{ "Content-Type", "text/plain" },
        .body = "Not Found",
    },
};

var epoch: std.time.Instant = undefined;
var epoch_set = false;

fn nowNanos() u64 {
    if (!epoch_set) {
        epoch = std.time.Instant.now() catch return 0;
        epoch_set = true;
    }
    return (std.time.Instant.now() catch return 0).since(epoch);
}

const BenchConfig = struct {
    iterations: usize,
    warmup_iterations: usize,
    rounds: usize,
};

fn runBenchmark(name: []const u8, cfg: BenchConfig, func: *const fn () void) void {
    for (0..cfg.warmup_iterations) |_| func();

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u128 = 0;

    for (0..cfg.rounds) |_| {
        const start = nowNanos();
        for (0..cfg.iterations) |_| func();
        const end = nowNanos();
        const elapsed_ns = end - start;
        if (elapsed_ns < min_ns) min_ns = elapsed_ns;
        if (elapsed_ns > max_ns) max_ns = elapsed_ns;
        total_ns += elapsed_ns;
    }

    const avg_ns = @as(u64, @intCast(total_ns / cfg.rounds));
    const min_ns_per_op = @as(f64, @floatFromInt(min_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const avg_ns_per_op = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const max_ns_per_op = @as(f64, @floatFromInt(max_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const ops_per_sec = if (avg_ns_per_op > 0)
        @as(u64, @intFromFloat(1_000_000_000.0 / avg_ns_per_op))
    else
        0;

    std.debug.print("  {s:<30} rounds={d} iters={d} min={d:.2}ns/op avg={d:.2}ns/op max={d:.2}ns/op throughput={d} ops/sec\n", .{
        name,
        cfg.rounds,
        cfg.iterations,
        min_ns_per_op,
        avg_ns_per_op,
        max_ns_per_op,
        ops_per_sec,
    });
}

var allocator: std.mem.Allocator = undefined;
var parse_buf: *buffer_mod.Buffer = undefined;
var parse_parser: http_parser.Parser = undefined;
var parse_req: http_parser.Request = undefined;

fn parseOpFor(comptime v: RequestVariant) void {
    parse_buf.reset();
    _ = parse_buf.writeSlice(v.wire);
    parse_parser.reset();
    parse_req.reset();
    _ = parse_parser.parse(parse_buf, &parse_req);
}

var resp_out: *buffer_mod.Buffer = undefined;

fn respondOpImpl(comptime v: ResponseVariant) void {
    var resp = http_response.Response.init(v.status);
    for (v.headers) |pair| _ = pair;
    var i: usize = 0;
    while (i < v.headers.len) : (i += 2) {
        resp.setHeader(v.headers[i], v.headers[i + 1]);
    }
    resp.setBody(v.body);
    resp_out.reset();
    resp.writeToBuffer(resp_out) catch unreachable;
}

fn matchName(want: ?[]const u8, name: []const u8) bool {
    if (want) |w| return std.mem.eql(u8, w, name);
    return true;
}

pub fn main() !void {
    allocator = std.heap.page_allocator;

    var req_filter: ?[]const u8 = null;
    var resp_filter: ?[]const u8 = null;
    var iters: usize = 100_000;
    var rounds: usize = 5;

    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--req")) {
            req_filter = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--resp")) {
            resp_filter = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--iters")) {
            iters = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArg, 10);
        }
    }

    std.debug.print("=== Ziglet request/response micro-benchmark (ReleaseFast) ===\n\n", .{});

    parse_buf = try buffer_mod.Buffer.init(allocator);
    parse_parser = http_parser.Parser.init(allocator);
    parse_req = http_parser.Request.init(allocator);
    resp_out = try buffer_mod.Buffer.init(allocator);

    const cfg = BenchConfig{ .iterations = iters, .warmup_iterations = 1_000, .rounds = rounds };

    std.debug.print("Request parsing:\n", .{});
    inline for (request_variants) |v| {
        if (matchName(req_filter, v.name)) {
            runBenchmark("request_parse[" ++ v.name ++ "]", cfg, struct {
                fn f() void {
                    parseOpFor(v);
                }
            }.f);
        }
    }
    std.debug.print("\nResponse building:\n", .{});
    inline for (response_variants) |v| {
        if (matchName(resp_filter, v.name)) {
            runBenchmark("response_build[" ++ v.name ++ "]", cfg, struct {
                fn f() void {
                    respondOpImpl(v);
                }
            }.f);
        }
    }
    std.debug.print("\n", .{});
}
