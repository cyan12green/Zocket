const std = @import("std");
const fuzz = @import("fuzz.zig");

/// Long-running fuzz campaign (`zig build fuzz`): pounds the HTTP/1 parser,
/// HPACK decoder, HTTP/2 session and the reactor's HTTP path with
/// deterministic pseudo-random inputs. Run under the DebugAllocator so any
/// crash, invalid free or memory corruption panics loudly. Nothing is
/// asserted beyond "survives without crashing".
pub fn main() !void {
    // Writing to a socketpair whose peer closed raises SIGPIPE by default;
    // the fuzz targets must treat it as an ordinary write error.
    var act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);

    const iterations_http1: usize = if (@import("builtin").mode == .Debug) 200_000 else 2_000_000;
    const iterations_hpack: usize = if (@import("builtin").mode == .Debug) 500_000 else 5_000_000;
    const iterations_session: usize = if (@import("builtin").mode == .Debug) 500_000 else 5_000_000;
    const iterations_reactor: usize = if (@import("builtin").mode == .Debug) 3_000 else 20_000;

    {
        var alloc = std.heap.DebugAllocator(.{}){};
        var prng = fuzz.Prng.init(0x1111_2222_3333_4444);
        std.debug.print("fuzz: HTTP/1 parser ({d} inputs)\n", .{iterations_http1});
        fuzz.fuzzHttp1(alloc.allocator(), &prng, iterations_http1);
        _ = alloc.deinitWithoutLeakChecks();
    }
    {
        var prng = fuzz.Prng.init(0x2222_3333_4444_5555);
        std.debug.print("fuzz: HPACK decoder ({d} blocks)\n", .{iterations_hpack});
        fuzz.fuzzHpack(&prng, iterations_hpack);
    }
    {
        var prng = fuzz.Prng.init(0x3333_4444_5555_6666);
        std.debug.print("fuzz: HTTP/2 session ({d} frame streams)\n", .{iterations_session});
        fuzz.fuzzHttp2Session(&prng, iterations_session);
    }
    {
        var alloc = std.heap.DebugAllocator(.{}){};
        var prng = fuzz.Prng.init(0x4444_5555_6666_7777);
        std.debug.print("fuzz: reactor HTTP path ({d} connection inputs)\n", .{iterations_reactor});
        fuzz.fuzzReactor(alloc.allocator(), &prng, iterations_reactor);
        _ = alloc.deinitWithoutLeakChecks();
    }
    std.debug.print("fuzz: OK\n", .{});
}
