//! Fast itoa benchmark (Milestone-14 response fast path).
//!
//! Measures, under identical conditions:
//!   1. Integer formatting: `std.fmt.bufPrint("{d}")` vs
//!      `tcp_server.http.response.formatUInt` (the 4-digits-at-a-time table
//!      itoa now used by the response builder; `std.fmt.printIntAny` already
//!      uses a 2-digit table but pays the format-machinery + bounds-check
//!      funnel).
//!   2. Full response build: the generic-sink `Response.write` path vs the
//!      send-buffer hot path `Response.writeToBuffer` (single capacity check,
//!      raw memcpy).
//!
//! The response variants are identical to bench/reqresp_bench.zig so numbers
//! compare one-for-one with the recorded baseline. The A/B of the response
//! fast path (std.fmt double-pass vs single-pass) is recorded in
//! bench/BENCH.md (Milestone 14, response serialisation).
//!
//! Usage:  zig build-exe -OReleaseFast --dep tcp_server \
//!           -Mroot=bench/itoa_bench.zig -Mtcp_server=src/root.zig \
//!           -femit-bin=zig-out/bin/itoa_bench
//!         zig-out/bin/itoa_bench [--iters N] [--rounds N]

const std = @import("std");
const tcp_server = @import("tcp_server");
const http_response = tcp_server.http.response;
const buffer_mod = tcp_server.buffer;

const formatUInt = http_response.formatUInt;
const digitCount = http_response.digitCount;

// ---------------------------------------------------------------------------
// Benchmark harness (same shape as bench/reqresp_bench.zig)
// ---------------------------------------------------------------------------

const ResponseVariant = struct {
    name: []const u8,
    status: http_response.Status,
    headers: []const []const u8,
    body: []const u8,
};

const body_64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

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

const itoa_cases = [_]struct { name: []const u8, value: u64 }{
    .{ .name = "status_200", .value = 200 },
    .{ .name = "zero", .value = 0 },
    .{ .name = "u16max", .value = 65535 },
    .{ .name = "16MiB", .value = 16 * 1024 * 1024 },
    .{ .name = "u64max", .value = std.math.maxInt(u64) },
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

fn runBenchmark(name: []const u8, cfg: BenchConfig, func: *const fn () void) u64 {
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
    const avg_ns_per_op = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const ops_per_sec = if (avg_ns_per_op > 0)
        @as(u64, @intFromFloat(1_000_000_000.0 / avg_ns_per_op))
    else
        0;

    std.debug.print("  {s:<32} {d:.2} ns/op   {d} ops/sec\n", .{
        name, avg_ns_per_op, ops_per_sec,
    });
    return avg_ns;
}

// ---- itoa micro: values rotate so nothing is constant-folded ----

var itoa_value: u64 = 1;
var itoa_sink: u64 = 0;
var itoa_buf: [32]u8 = undefined;

fn stdItoaOp() void {
    itoa_value = itoa_value *% 31 +% 7;
    const s = std.fmt.bufPrint(&itoa_buf, "{d}", .{itoa_value}) catch unreachable;
    itoa_sink +%= s.len;
}

fn fastItoaOp() void {
    itoa_value = itoa_value *% 31 +% 7;
    const pos = formatUInt(&itoa_buf, 0, itoa_value);
    itoa_sink +%= pos;
}

// ---- response build ----

var allocator: std.mem.Allocator = undefined;
var resp_out_fast: *buffer_mod.Buffer = undefined;
var resp_list: std.ArrayList(u8) = .empty;

fn buildResp(v: ResponseVariant) http_response.Response {
    var resp = http_response.Response.init(v.status);
    var i: usize = 0;
    while (i < v.headers.len) : (i += 2) {
        resp.setHeader(v.headers[i], v.headers[i + 1]);
    }
    resp.setBody(v.body);
    return resp;
}

/// Generic-sink path: `Response.write` into an in-memory list (per-segment
/// append, no pre-sizing).
fn respFmtOp(v: ResponseVariant) void {
    var resp = buildResp(v);
    resp_list.clearRetainingCapacity();
    resp.write(http_response.ListSink{ .list = &resp_list, .allocator = allocator }) catch unreachable;
}

/// Send-buffer hot path: `Response.writeToBuffer` (single capacity check,
/// raw memcpy).
fn respFastOp(v: ResponseVariant) void {
    var resp = buildResp(v);
    resp_out_fast.reset();
    resp.writeToBuffer(resp_out_fast) catch unreachable;
}

// ---------------------------------------------------------------------------
// Correctness: byte-identical output + writeUInt vs std.fmt
// ---------------------------------------------------------------------------

fn verifyCorrectness() bool {
    // 1. formatUInt vs std.fmt across a wide value range.
    var val: u64 = 0;
    while (val < 1_000_000) : (val += 1) {
        var a: [32]u8 = undefined;
        const want = std.fmt.bufPrint(&a, "{d}", .{val}) catch unreachable;
        var b: [32]u8 = undefined;
        const got = b[0..formatUInt(&b, 0, val)];
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("  MISMATCH formatUInt({d}): want '{s}' got '{s}'\n", .{ val, want, got });
            return false;
        }
    }
    for ([_]u64{ 999_999_999, 1_000_000_000, 4_294_967_295, 16 * 1024 * 1024, 1_000_000_000_000, std.math.maxInt(u64) }) |v2| {
        var a: [32]u8 = undefined;
        const want = std.fmt.bufPrint(&a, "{d}", .{v2}) catch unreachable;
        var b: [32]u8 = undefined;
        const got = b[0..formatUInt(&b, 0, v2)];
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("  MISMATCH formatUInt({d}): want '{s}' got '{s}'\n", .{ v2, want, got });
            return false;
        }
    }

    // 2. Generic-sink and buffer paths produce byte-identical responses.
    for (response_variants) |rv| {
        resp_out_fast.reset();
        resp_list.clearRetainingCapacity();
        var resp_f = buildResp(rv);
        resp_f.write(http_response.ListSink{ .list = &resp_list, .allocator = allocator }) catch unreachable;
        resp_f.writeToBuffer(resp_out_fast) catch unreachable;
        if (!std.mem.eql(u8, resp_list.items, resp_out_fast.peek())) {
            std.debug.print("  MISMATCH response variant '{s}'\n", .{rv.name});
            std.debug.print("    sink:  '{s}'\n", .{resp_list.items});
            std.debug.print("    buffer: '{s}'\n", .{resp_out_fast.peek()});
            return false;
        }
    }
    return true;
}

test "formatUInt matches std.fmt for all values 0..1M and edge values" {
    try std.testing.expect(verifyCorrectness());
}

pub fn main() !void {
    var iters: usize = 100_000;
    var rounds: usize = 5;

    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iters")) {
            iters = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArg, 10);
        }
    }

    allocator = std.heap.page_allocator;
    resp_out_fast = try buffer_mod.Buffer.init(allocator);
    try resp_list.ensureTotalCapacity(allocator, 1024);

    if (!verifyCorrectness()) {
        std.debug.print("FAIL: output mismatch — aborting benchmark\n", .{});
        return error.OutputMismatch;
    }
    std.debug.print("correctness: formatUInt and both serialisation paths byte-identical to std.fmt\n\n", .{});

    const cfg = BenchConfig{ .iterations = iters, .warmup_iterations = 1_000, .rounds = rounds };

    std.debug.print("=== itoa: std.fmt.bufPrint({{d}}) vs writeUInt (table, 4 digits/step) ===\n", .{});
    const fmt_total = runBenchmark("std_fmt_itoa[rotating]", cfg, stdItoaOp);
    const fast_total = runBenchmark("fast_itoa[rotating]", cfg, fastItoaOp);
    std.debug.print("  speedup: {d:.2}x\n\n", .{@as(f64, @floatFromInt(fmt_total)) / @as(f64, @floatFromInt(fast_total))});

    std.debug.print("=== response build: generic sink (per-segment) vs writeToBuffer (single check) ===\n", .{});
    var fmt_resp_total: u128 = 0;
    var fast_resp_total: u128 = 0;
    inline for (response_variants) |rv| {
        const fmt_ns = runBenchmark("build_sink[" ++ rv.name ++ "]", cfg, struct {
            fn f() void {
                respFmtOp(rv);
            }
        }.f);
        const fast_ns = runBenchmark("build_buf[" ++ rv.name ++ "]", cfg, struct {
            fn f() void {
                respFastOp(rv);
            }
        }.f);
        fmt_resp_total += fmt_ns;
        fast_resp_total += fast_ns;
        std.debug.print("    ratio: {d:.2}x\n", .{@as(f64, @floatFromInt(fmt_ns)) / @as(f64, @floatFromInt(fast_ns))});
    }
    std.debug.print("  overall: {d:.2}x\n", .{
        @as(f64, @floatFromInt(fmt_resp_total)) / @as(f64, @floatFromInt(fast_resp_total)),
    });
    _ = itoa_sink; // observability
}
