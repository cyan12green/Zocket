const std = @import("std");

/// A typed comptime pool: a fixed-size array plus a length, used to build
/// comptime data structures (tries, DFAs, route tables) without an allocator.
///
/// Comptime code cannot use `std.mem.Allocator` (there is no comptime heap),
/// and an allocator's `free` is meaningless in a builder whose lifetime is
/// "start compilation -> build everything -> freeze -> builder disappears" —
/// that is an arena by definition. `CtPool` is the append-only core of that
/// arena, typed per element: `create` returns a pointer into the fixed array
/// (stable — the array never moves), and once the build is done the pool
/// becomes a comptime constant whose `freeze()` yields a plain static slice
/// in `.rodata`. Exhausting the pool is a compile error, not a runtime
/// surprise.
///
/// Typical shape:
///
/// ```zig
/// const RouterBuilder = struct {
///     nodes: CtPool(Node, 1024) = .{},
///     edges: CtPool(Edge, 4096) = .{},
/// };
///
/// const built = comptime blk: {
///     var b = RouterBuilder{};
///     const n = b.nodes.create(.{ ... });
///     _ = b.edges.create(.{ .child = n });
///     break :blk b;
/// };
/// const frozen: []const Node = built.nodes.freeze();
/// ```
pub fn CtPool(comptime T: type, comptime N: usize) type {
    return struct {
        pub const Elem = T;
        pub const capacity = N;

        items: [N]T = undefined,
        len: usize = 0,

        /// Reserve the next slot, initialised to `value`, and return a
        /// pointer into the pool's array. Caller keeps the pointer (or, more
        /// idiomatically for index-based structures, captures `len` before
        /// the call) for the rest of the build.
        pub fn create(self: *@This(), value: T) *T {
            if (self.len == N) {
                @compileError("comptime pool exhausted: " ++ @typeName(T) ++
                    "[" ++ std.fmt.comptimePrint("{d}", .{N}) ++ "]");
            }
            const p = &self.items[self.len];
            self.len += 1;
            p.* = value;
            return p;
        }

        /// Mutable slice of the used slots (for builders that write through
        /// slices rather than the create() pointer).
        pub fn slice(self: *@This()) []T {
            return self.items[0..self.len];
        }

        /// Freeze the built data into a read-only slice. The pool is taken
        /// by value: the used portion of the (comptime) array becomes a
        /// comptime constant, and the returned slice lives in `.rodata`.
        /// Only valid once the pool is a comptime constant (e.g. broken out
        /// of a `comptime blk`); a by-pointer slice would reference the
        /// comptime var and Zig forbids that escaping into runtime values.
        /// NOTE: do NOT call freeze on a runtime pool and retain the slice
        /// past the call — the slice dangles over the dead by-value copy.
        /// Runtime code should use slice(); freeze is for comptime builds.
        pub fn freeze(self: @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

const testing = std.testing;

test "create appends and slice yields the used portion in order" {
    // create() is comptime-only (capacity overflow is a @compileError, so
    // the length check only fires at comptime); build at comptime, then
    // assert on the runtime slice (borrows the live pool — no dangle).
    var p = comptime blk: {
        var q = CtPool(u32, 8){};
        _ = q.create(10);
        _ = q.create(20);
        _ = q.create(30);
        break :blk q;
    };
    try testing.expectEqual(@as(usize, 3), p.slice().len);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, p.slice());
}

test "freeze escapes a comptime pool into .rodata" {
    // freeze() takes the pool by value: inside a comptime block the copy
    // is comptime-known, so the slice legally escapes into .rodata.
    // (Calling freeze on a RUNTIME pool dangles over the dead parameter
    // copy — runtime code must use slice().)
    const frozen = comptime blk: {
        var p = CtPool(u32, 8){};
        _ = p.create(10);
        _ = p.create(20);
        _ = p.create(30);
        break :blk p.freeze();
    };
    try testing.expectEqual(@as(usize, 3), frozen.len);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, frozen);
}

test "create pointers are stable and point into the pool array" {
    var p = comptime blk: {
        var q = CtPool(u32, 4){};
        const a = q.create(1);
        const b = q.create(2);
        std.debug.assert(a == &q.items[0]);
        std.debug.assert(b == &q.items[1]);
        a.* = 100; // mutate through the returned pointer
        break :blk q;
    };
    try testing.expectEqualSlices(u32, &.{ 100, 2 }, p.slice());
}

test "create captures its own index for index-based structures" {
    var p = comptime blk: {
        var q = CtPool(u32, 8){};
        const idx0 = q.len;
        _ = q.create(7);
        const idx1 = q.len;
        _ = q.create(8);
        std.debug.assert(idx0 == 0 and idx1 == 1);
        break :blk q;
    };
    try testing.expectEqual(@as(usize, 2), p.slice().len);
}

test "slice exposes the used portion for in-place builders" {
    var p = comptime blk: {
        var q = CtPool(u32, 8){};
        _ = q.create(1);
        q.slice()[0] = 99; // write through the slice
        _ = q.create(2);
        break :blk q;
    };
    try testing.expectEqualSlices(u32, &.{ 99, 2 }, p.slice());
}

test "multiple typed pools in one builder (RouterBuilder pattern)" {
    const Node = struct { tag: u8, edges_start: u32 };
    const Edge = struct { byte: u8, child: u32 };
    const Builder = struct {
        nodes: CtPool(Node, 16) = .{},
        edges: CtPool(Edge, 64) = .{},
    };

    var b = comptime blk: {
        var bb = Builder{};
        const root = bb.nodes.create(.{ .tag = 0, .edges_start = 0 });
        _ = bb.edges.create(.{ .byte = 'a', .child = root.*.tag });
        _ = bb.nodes.create(.{ .tag = 1, .edges_start = 0 });
        break :blk bb;
    };

    try testing.expectEqual(@as(usize, 2), b.nodes.slice().len);
    try testing.expectEqual(@as(usize, 1), b.edges.slice().len);
    try testing.expectEqual(@as(u8, 'a'), b.edges.slice()[0].byte);
    try testing.expectEqual(@as(u8, 0), b.nodes.slice()[0].tag);
    // Exhaustion would be a compile error: p.create() beyond capacity.
}

test "empty pool slices to zero length and exposes its type constants" {
    var p = comptime blk: {
        break :blk CtPool(u32, 8){};
    };
    try testing.expectEqual(@as(usize, 0), p.slice().len);
    try testing.expectEqual(@as(usize, 0), p.len);
    try testing.expectEqual(@as(usize, 8), @TypeOf(p).capacity);
    try testing.expectEqual(u32, @TypeOf(p).Elem);
    const frozen = comptime blk: {
        var q = CtPool(u32, 8){};
        break :blk q.freeze();
    };
    try testing.expectEqual(@as(usize, 0), frozen.len);
}

test "pool fills exactly to capacity" {
    var p = comptime blk: {
        var q = CtPool(u8, 4){};
        _ = q.create('a');
        _ = q.create('b');
        _ = q.create('c');
        _ = q.create('d');
        break :blk q;
    };
    try testing.expectEqual(@as(usize, 4), p.slice().len);
    try testing.expectEqualSlices(u8, "abcd", p.slice());
}
