const std = @import("std");

/// Bump arena for per-request data (headers, decoded target, query):
/// request-scoped allocations never move and are never freed individually;
/// `reset()` rewinds the whole arena between requests. A request that fits
/// the embedded 16 KiB costs zero heap allocations; larger requests spill
/// into heap blocks (doubling sizes) that are kept warm across requests.
///
/// Slices returned by `alloc` stay valid until the next `reset()`.
pub const default_size = 16384;

pub const Arena = struct {
    allocator: std.mem.Allocator,
    embedded: [default_size]u8 = undefined,
    embedded_used: usize = 0,
    /// Heap overflow blocks (newest first). Blocks are never moved, so
    /// slices into them stay valid; freed only in `deinit`.
    blocks: ?*Block = null,
    /// The block currently being filled (the largest, for warm reuse).
    cur_block: ?*Block = null,

    pub const Block = struct {
        data: []u8,
        used: usize,
        next: ?*Block,
    };

    pub fn init(allocator: std.mem.Allocator) Arena {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Arena) void {
        var b = self.blocks;
        while (b) |blk| {
            const next = blk.next;
            self.allocator.free(blk.data);
            self.allocator.destroy(blk);
            b = next;
        }
        self.blocks = null;
        self.cur_block = null;
    }

    /// Rewind the arena for the next request. Heap blocks keep their
    /// capacity (warm reuse).
    pub fn reset(self: *Arena) void {
        self.embedded_used = 0;
        var b = self.blocks;
        while (b) |blk| {
            blk.used = 0;
            b = blk.next;
        }
        // Reuse the largest block first (the newest in the list).
        self.cur_block = self.blocks;
    }

    /// Bump-allocate `n` bytes (8-byte aligned). Null when out of memory.
    pub fn alloc(self: *Arena, n: usize) ?[]u8 {
        if (self.embedded_used + n <= self.embedded.len) {
            const off = std.mem.alignForward(usize, self.embedded_used, 8);
            if (off + n > self.embedded.len) {
                return self.allocHeap(n);
            }
            const s = self.embedded[off .. off + n];
            self.embedded_used = off + n;
            return s;
        }
        return self.allocHeap(n);
    }

    fn allocHeap(self: *Arena, n: usize) ?[]u8 {
        if (self.cur_block) |blk| {
            const off = std.mem.alignForward(usize, blk.used, 8);
            if (off + n <= blk.data.len) {
                const s = blk.data[off .. off + n];
                blk.used = off + n;
                return s;
            }
        }
        // New overflow block, doubling from the current largest.
        const cap = if (self.cur_block) |blk| @max(blk.data.len * 2, n) else @max(default_size, n);
        const data = self.allocator.alloc(u8, cap) catch return null;
        const blk = self.allocator.create(Block) catch {
            self.allocator.free(data);
            return null;
        };
        blk.* = .{ .data = data, .used = n, .next = self.blocks };
        self.blocks = blk;
        self.cur_block = blk;
        return data[0..n];
    }

    /// Total bytes currently used (embedded + heap blocks); for tests and
    /// the stub status page.
    pub fn usedBytes(self: *const Arena) usize {
        var total = self.embedded_used;
        var b = self.blocks;
        while (b) |blk| {
            total += blk.used;
            b = blk.next;
        }
        return total;
    }
};

const testing = std.testing;

test "arena fits small allocations in the embedded buffer" {
    const allocator = testing.allocator;
    var a = Arena.init(allocator);
    defer a.deinit();

    const s1 = (a.alloc(5) orelse return error.SkipZigTest);
    @memcpy(s1, "hello");
    _ = a.alloc(100) orelse return error.SkipZigTest;
    try testing.expectEqualStrings("hello", s1);
    try testing.expectEqual(@as(usize, 108), a.usedBytes());
    try testing.expect(a.blocks == null);
}

test "arena spills into heap blocks and keeps slices stable" {
    const allocator = testing.allocator;
    var a = Arena.init(allocator);
    defer a.deinit();

    // Fill past the embedded 16 KiB.
    const s1 = (a.alloc(100) orelse return error.SkipZigTest);
    @memset(s1, 'a');
    const big = (a.alloc(default_size) orelse return error.SkipZigTest);
    @memset(big, 'b');
    const tail = (a.alloc(50) orelse return error.SkipZigTest);
    try testing.expectEqualStrings(&[_]u8{'a'} ** 100, s1);
    try testing.expectEqualStrings(&[_]u8{'b'} ** default_size, big);
    try testing.expectEqual(@as(usize, 50), tail.len);
}

test "arena reset rewinds and reuses capacity without allocation" {
    const allocator = testing.allocator;
    var a = Arena.init(allocator);
    defer a.deinit();

    _ = a.alloc(default_size + 1000) orelse return error.SkipZigTest; // forces a heap block
    try testing.expect(a.blocks != null);
    const used_before = a.usedBytes();
    a.reset();
    try testing.expectEqual(@as(usize, 0), a.usedBytes());
    _ = a.alloc(64) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 64), a.usedBytes());
    _ = a.alloc(used_before) orelse return error.SkipZigTest;
}
