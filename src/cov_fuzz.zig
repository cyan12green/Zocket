// Coverage fuzz driver: runs the FULL deterministic fuzz campaign as
// tests (same seeds/counts as `zig build fuzz` in Debug). Built ONLY via
// the `fuzzcov` build step with SanitizerCoverage instrumentation — its
// .zcov merges with the unit-test .zcov files (`zig-cov report *.zcov`).
// NOT part of `zig build test` (minutes-long runtime).
const std = @import("std");
const fuzz = @import("fuzz.zig");

test "fuzzcov: HTTP/1 parser campaign" {
    var alloc = std.heap.DebugAllocator(.{}){};
    var prng = fuzz.Prng.init(0x1111_2222_3333_4444);
    fuzz.fuzzHttp1(alloc.allocator(), &prng, 200_000);
    _ = alloc.deinitWithoutLeakChecks();
}

test "fuzzcov: HPACK decoder campaign" {
    var prng = fuzz.Prng.init(0x2222_3333_4444_5555);
    fuzz.fuzzHpack(&prng, 500_000);
}

test "fuzzcov: HTTP/2 session campaign" {
    var prng = fuzz.Prng.init(0x3333_4444_5555_6666);
    fuzz.fuzzHttp2Session(&prng, 500_000);
}

test "fuzzcov: reactor HTTP path campaign" {
    var alloc = std.heap.DebugAllocator(.{}){};
    var prng = fuzz.Prng.init(0x4444_5555_6666_7777);
    fuzz.fuzzReactor(alloc.allocator(), &prng, 3_000);
    _ = alloc.deinitWithoutLeakChecks();
}
