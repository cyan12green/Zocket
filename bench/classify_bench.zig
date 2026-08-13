//! Isolation micro-benchmark: header-name classification, FNV-hash path
//! (pre-DFA) vs comptime DFA path, for the header sets of the standard
//! request variants. Alternates rounds so machine noise cancels.
//!
//! Usage:  zig build-exe -OReleaseFast --dep tcp_server \
//!           -Mroot=bench/classify_bench.zig -Mtcp_server=src/root.zig \
//!           -femit-bin=zig-out/bin/classify_bench
//!         zig-out/bin/classify_bench

const std = @import("std");
const tcp_server = @import("tcp_server");
const parser = tcp_server.http.parser;
const header_dfa = tcp_server.http.header_dfa;

const wire_names = [_][]const u8{
    "Host",
    "User-Agent",
    "Accept",
    "Connection",
    "Content-Length",
    "Content-Type",
    "Transfer-Encoding",
    "If-None-Match",
    "X-Custom-Header",
    "Range",
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

var sink: u64 = 0;

/// Old path: FNV-1a hash of the wire name, compare against comptime hash of
/// each known name, eqlIgnoreCase verify on hit.
fn hashClassify(name: []const u8) bool {
    const h = parser.header_hasher.hash(name);
    inline for (parser.header_hasher.known) |k| {
        if (h == comptime parser.header_hasher.hash(k)) {
            if (std.ascii.eqlIgnoreCase(name, k)) return true;
        }
    }
    return false;
}

/// New path: DFA walk, terminal tag.
fn dfaClassify(name: []const u8) bool {
    return parser.header_dfa.classify(name) != 0;
}

fn bench(name: []const u8, iters: usize, rounds: usize, func: *const fn () void) void {
    for (0..1000) |_| func();
    var total: u128 = 0;
    for (0..rounds) |_| {
        const start = nowNanos();
        for (0..iters) |_| func();
        total += nowNanos() - start;
    }
    const ns = @as(f64, @floatFromInt(total / rounds)) / @as(f64, @floatFromInt(iters));
    std.debug.print("  {s:<24} {d:.2} ns/op\n", .{ name, ns });
}

pub fn main() !void {
    const iters: usize = 1_000_000;
    const rounds: usize = 7;

    // Correctness: both paths agree on every test name.
    for (wire_names) |n| {
        if (hashClassify(n) != dfaClassify(n)) {
            std.debug.print("MISMATCH on '{s}': hash={} dfa={}\n", .{ n, hashClassify(n), dfaClassify(n) });
            return error.Mismatch;
        }
    }
    std.debug.print("classification agreement OK; known set: {d} names, DFA nodes: {d}\n\n", .{
        parser.header_hasher.known.len,
        parser.header_dfa.node_count,
    });

    std.debug.print("classify one wire name (10-name set, hash verify on hit vs exact tag):\n", .{});
    bench("hash_path", iters, rounds, struct {
        fn f() void {
            for (wire_names) |n| {
                if (hashClassify(n)) sink +%= 1;
            }
        }
    }.f);
    bench("dfa_path", iters, rounds, struct {
        fn f() void {
            for (wire_names) |n| {
                if (dfaClassify(n)) sink +%= 1;
            }
        }
    }.f);
    _ = sink;
}
