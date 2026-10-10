//! Shared-memory zones for modules (nginx `ngx_shm_zone` equivalent).
//!
//! Every zone has a HARD CEILING known before the first request: keyed
//! tables are capped at comptime entry counts, blob stores carry a byte
//! budget. Nothing in here ever grows without bound, so load cannot blow
//! up memory — under pressure the zone refuses instead of expanding and
//! the consumer applies its own at-capacity policy:
//!
//!   - rate/concurrency limiting: refuse == reject the request (fail closed)
//!   - caching / affinity maps: refuse == bypass the feature (fail open)
//!
//! Zones are process-wide; a single mutex per zone guards multi-reactor
//! access (the same trade-off nginx makes with its zone locks).

const std = @import("std");
const sys = @import("../sys.zig");
const linux = std.os.linux;

/// A fixed-capacity open-addressing map: u64 key -> V. `cap` must be a
/// power of two. `upsert` returns null when the table is full AND the key
/// is unknown — that is the bounded-memory contract; callers decide whether
/// refusal means "reject the request" or "skip the feature". Entries whose
/// keys were inserted last recycle earliest only via `clear`; there is no
/// implicit eviction (limiting semantics need stable counters).
pub fn KeyedTable(comptime V: type, comptime cap: usize) type {
    const mask = cap - 1;
    if (cap & mask != 0) @compileError("KeyedTable cap must be a power of two");
    return struct {
        const Self = @This();

        const zero_val: V = std.mem.zeroes(V);

        mutex: sys.Mutex = .{},
        keys: [cap]u64 = @as([cap]u64, @splat(@as(u64, 0))),
        vals: [cap]V = @as([cap]V, @splat(zero_val)),
        filled: usize = 0,

        /// Probe at most `cap` slots: open addressing without tombstones
        /// can never need more, and a full table with an unknown key MUST
        /// terminate in refusal rather than wrap forever.
        fn probe(self: *const Self, key: u64) usize {
            var i: usize = @intCast(key & mask);
            var n: usize = 0;
            while (n < cap and self.keys[i] != 0 and self.keys[i] != key) : ({
                i = (i + 1) & mask;
                n += 1;
            }) {}
            return i;
        }

        /// Get-or-create the slot for `key`; returns whether the key
        /// already existed. Caller must hold the mutex (use for multi-step
        /// read-modify-write under one critical section).
        pub fn upsertLocked(self: *Self, key: u64) ?struct { slot: *V, existed: bool } {
            const i = self.probe(key);
            if (self.keys[i] == 0) {
                if (self.filled >= cap) return null;
                self.keys[i] = key;
                self.vals[i] = zero_val;
                self.filled += 1;
                return .{ .slot = &self.vals[i], .existed = false };
            }
            if (self.keys[i] != key) return null; // full, key unknown
            return .{ .slot = &self.vals[i], .existed = true };
        }

        /// Get-or-create under the zone mutex. The returned pointer is only
        /// safe to dereference while the mutex is held.
        pub fn upsert(self: *Self, key: u64) ?*V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const r = self.upsertLocked(key) orelse return null;
            return r.slot;
        }

        /// Read-only lookup (locks; returns a copy for value types).
        pub fn get(self: *Self, key: u64) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const i = self.probe(key);
            if (self.keys[i] == key) return self.vals[i];
            return null;
        }

        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.keys = @as([cap]u64, @splat(@as(u64, 0)));
            self.vals = @as([cap]V, @splat(zero_val));
            self.filled = 0;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.filled;
        }
    };
}

/// A byte-budgeted LRU store for opaque blobs (proxy_cache bodies). Sized
/// once at init (hard ceiling for the process lifetime): entry count and
/// total bytes never exceed the configured limits, so load cannot grow the
/// zone. A chained hash directory gives O(1) lookups; inserting a value
/// that cannot fit after evicting every older entry is refused (returns
/// null). This is the second half of the bounded-memory contract: caching
/// degrades to pass-through under pressure instead of eating the box.
pub const LruStore = struct {
    const Entry = struct {
        key: u64 = 0,
        bytes: []u8 = &.{}, // points into backing
        used: bool = false,
        tick: u64 = 0, // LRU clock
        meta: u64 = 0, // consumer-owned (expiry ns, status, ...)
        meta2: u64 = 0,
        next: i32 = -1, // hash-chain link (index into entries)
    };

    pub const Found = struct {
        meta: u64,
        meta2: u64,
        bytes: []u8,
    };

    mutex: sys.Mutex = .{},
    allocator: std.mem.Allocator,
    max_bytes: usize,
    entries: []Entry,
    /// Chained hash directory: -1 = empty head. Size is the next power of
    /// two at or above the entry count, so average chains stay ~1 long.
    buckets: []i32,
    used_count: usize = 0,
    used_bytes: usize = 0,
    clock: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize, max_entries: usize) !LruStore {
        const n = @max(max_entries, 1);
        var buckets_len: usize = 1;
        while (buckets_len < n) buckets_len <<= 1;
        const entries = try allocator.alloc(Entry, n);
        errdefer allocator.free(entries);
        @memset(entries, .{});
        const buckets = try allocator.alloc(i32, buckets_len);
        errdefer allocator.free(buckets);
        @memset(buckets, -1);
        return .{
            .allocator = allocator,
            .max_bytes = max_bytes,
            .entries = entries,
            .buckets = buckets,
        };
    }

    pub fn deinit(self: *LruStore) void {
        self.mutex.lock();
        for (self.entries) |e| {
            if (e.used) self.allocator.free(e.bytes);
        }
        self.allocator.free(self.entries);
        self.allocator.free(self.buckets);
        self.mutex.unlock();
    }

    fn bucketOf(self: *const LruStore, key: u64) usize {
        // Fibonacci hashing over the bucket count (power of two).
        const h = key *% 0x9E3779B97F4A7C15;
        return @intCast((h >> 32) & (@as(u64, self.buckets.len) - 1));
    }

    /// Walk the chain for `key`; returns the slot index or null.
    fn findSlot(self: *const LruStore, key: u64) ?usize {
        var i = self.buckets[self.bucketOf(key)];
        while (i >= 0) {
            const e = &self.entries[@intCast(i)];
            if (e.used and e.key == key) return @intCast(i);
            i = e.next;
        }
        return null;
    }

    /// Unlink slot `idx` from its key's chain (caller holds the mutex and
    /// guarantees the slot is linked, i.e. used).
    fn unlink(self: *LruStore, idx: usize) void {
        const e = &self.entries[idx];
        var cur = self.buckets[self.bucketOf(e.key)];
        var prev: i32 = -1;
        while (cur >= 0) : (cur = self.entries[@intCast(cur)].next) {
            if (cur == idx) {
                if (prev < 0) {
                    self.buckets[self.bucketOf(e.key)] = e.next;
                } else {
                    self.entries[@intCast(prev)].next = e.next;
                }
                return;
            }
            prev = cur;
        }
    }

    fn link(self: *LruStore, idx: usize) void {
        const b = self.bucketOf(self.entries[idx].key);
        self.entries[idx].next = self.buckets[b];
        self.buckets[b] = @intCast(idx);
    }

    /// Free an occupied slot (evict or pre-replace release).
    fn dropSlot(self: *LruStore, idx: usize) void {
        const e = &self.entries[idx];
        self.unlink(idx);
        self.used_bytes -= e.bytes.len;
        self.allocator.free(e.bytes);
        e.used = false;
        e.bytes = &.{};
        self.used_count -= 1;
    }

    /// Read-only lookup (locks; returns a copy of the metadata only — use
    /// getCopy for safe access to blob bytes across threads).
    pub fn lookup(self: *LruStore, key: u64) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findSlot(key) orelse return null;
        const e = &self.entries[idx];
        self.clock += 1;
        e.tick = self.clock;
        return e.*;
    }

    /// Lookup with the blob copied out UNDER the zone mutex: callers get
    /// allocator-owned bytes they can read without racing a concurrent
    /// evict-or-replace on another reactor thread.
    pub fn getCopy(self: *LruStore, key: u64, alloc: std.mem.Allocator) ?Found {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findSlot(key) orelse return null;
        const e = &self.entries[idx];
        const copy = alloc.dupe(u8, e.bytes) catch return null;
        self.clock += 1;
        e.tick = self.clock;
        return .{ .meta = e.meta, .meta2 = e.meta2, .bytes = copy };
    }

    /// Insert `bytes` (copied into the zone). Evicts LRU entries until it
    /// fits; returns null (storing nothing) when the value can never fit
    /// within the byte budget even empty-handed.
    pub fn put(self: *LruStore, key: u64, bytes: []const u8, meta: u64, meta2: u64) ?void {
        if (bytes.len > self.max_bytes) return null;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Resolve the slot: an existing key keeps its slot (its old bytes
        // are released now); otherwise prefer a free slot and fall back to
        // evicting the least-recently-used entry.
        var preferred: usize = undefined;
        if (self.findSlot(key)) |i| {
            self.dropSlot(i);
            preferred = i;
        } else {
            var found_free = false;
            for (self.entries, 0..) |*e, i| {
                if (!e.used) {
                    preferred = i;
                    found_free = true;
                    break;
                }
            }
            if (!found_free) {
                preferred = self.lruIndexLocked() orelse return null;
                self.dropSlot(preferred);
            }
        }

        // Make room among the remaining occupied slots.
        while (self.used_bytes + bytes.len > self.max_bytes) {
            const victim = self.lruIndexLocked() orelse return null;
            self.dropSlot(victim);
        }

        const copy = self.allocator.dupe(u8, bytes) catch return null;
        self.entries[preferred] = .{
            .key = key,
            .bytes = copy,
            .used = true,
            .meta = meta,
            .meta2 = meta2,
            .next = -1,
        };
        self.link(preferred);
        self.used_count += 1;
        self.used_bytes += copy.len;
        self.clock += 1;
        self.entries[preferred].tick = self.clock;
        return {};
    }

    /// Least-recently-used occupied slot (caller holds the mutex).
    fn lruIndexLocked(self: *LruStore) ?usize {
        var best: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |*e, i| {
            if (e.used and e.tick < oldest) {
                oldest = e.tick;
                best = i;
            }
        }
        return best;
    }

    /// Invalidate one key (revalidation that must forget stale data).
    pub fn remove(self: *LruStore, key: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findSlot(key)) |idx| self.dropSlot(idx);
    }

    pub fn stats(self: *LruStore) struct { entries: usize, bytes: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .entries = self.used_count, .bytes = self.used_bytes };
    }
};

test "KeyedTable upsert/get round-trips and refuses when full" {
    var t = KeyedTable(u32, 4){};
    inline for (0..4) |i| {
        const slot = t.upsert(100 + i) orelse return error.UnexpectedFull;
        slot.* = @intCast(i * 10);
    }
    try testing.expectEqual(@as(usize, 4), t.count());
    try testing.expectEqual(@as(u32, 20), t.get(102).?);

    // Unknown key on a full table: bounded refusal, existing keys intact.
    try testing.expect(t.upsert(999) == null);
    try testing.expectEqual(@as(u32, 20), t.get(102).?);

    // Known keys still resolve after the refusal.
    const slot = t.upsert(101) orelse return error.LostSlot;
    slot.* += 1;
    try testing.expectEqual(@as(u32, 11), t.get(101).?);

    t.clear();
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expect(t.upsert(999) != null);
}

test "LruStore evicts least-recently-used and honors the byte budget" {
    var store = try LruStore.init(testing.allocator, 300, 4);
    defer store.deinit();

    _ = store.put(1, "aa", 0, 0);
    _ = store.put(2, "bbb", 0, 0);
    _ = store.put(3, "c", 0, 0);
    _ = store.lookup(1); // promote key 1
    _ = store.put(4, "dddd", 0, 0); // still fits: 4 slots, 10 bytes

    try testing.expect(store.lookup(1) != null);
    try testing.expect(store.lookup(2) != null);
    try testing.expect(store.lookup(3) != null);
    try testing.expect(store.lookup(4) != null);

    // A value bigger than the whole budget is refused outright.
    var big: [301]u8 = undefined;
    try testing.expect(store.put(5, &big, 0, 0) == null);

    // A value that fits only after evicting older entries does exactly
    // that (LRU order: 2 was touched least recently), and totals stay
    // within the byte budget no matter what arrives.
    var mid: [290]u8 = undefined;
    _ = store.put(6, &mid, 0, 0);
    // The assertion lookups above re-promoted every entry (key 1 became
    // LRU by a hair), so key 1 is who gets replaced.
    try testing.expect(store.lookup(1) == null); // evicted
    try testing.expect(store.lookup(2) != null);
    try testing.expect(store.lookup(3) != null);
    try testing.expect(store.lookup(4) != null);
    const s = store.stats();
    try testing.expect(s.bytes <= 300);
    try testing.expect(s.entries <= 4);
}

test "LruStore remove invalidates exactly one key" {
    var store = try LruStore.init(testing.allocator, 100, 4);
    defer store.deinit();
    _ = store.put(7, "x", 0, 0);
    _ = store.put(8, "yy", 0, 0);
    store.remove(7);
    try testing.expect(store.lookup(7) == null);
    try testing.expect(store.lookup(8) != null);
    try testing.expectEqual(@as(usize, 1), store.stats().entries);
}

test "KeyedTable probes past collisions and reports misses" {
    var t = KeyedTable(u32, 4){};
    // Keys 4 and 8 share the start slot (both & 3 == 0): chaining works.
    const s4 = t.upsert(4) orelse return error.UnexpectedFull;
    s4.* = 40;
    const s8 = t.upsert(8) orelse return error.UnexpectedFull;
    s8.* = 80;
    try testing.expectEqual(@as(u32, 40), t.get(4).?);
    try testing.expectEqual(@as(u32, 80), t.get(8).?);
    // Unknown keys miss (empty slot and full-table probe termination).
    try testing.expect(t.get(12) == null);
    _ = t.upsert(1) orelse return error.UnexpectedFull;
    _ = t.upsert(2) orelse return error.UnexpectedFull;
    try testing.expectEqual(@as(usize, 4), t.count());
    try testing.expect(t.get(999) == null);
    // upsertLocked distinguishes create from update.
    const created = t.upsertLocked(4).?;
    try testing.expect(created.existed);
    created.slot.* = 44;
    try testing.expectEqual(@as(u32, 44), t.get(4).?);
    try testing.expect(t.upsertLocked(999) == null); // full, unknown
}

test "KeyedTable key zero aliases the empty sentinel" {
    // keys[i] == 0 means "empty", so key 0 reads back the zero value even
    // when never inserted. Callers must never use key 0 (all production
    // keys are hashes/tags, never bare zero). Double-inserting key 0 also
    // double-counts `filled` (probe always lands on the zeroed slot).
    // Reported; this test pins the current behavior.
    var t = KeyedTable(u32, 4){};
    try testing.expectEqual(@as(?u32, 0), t.get(0));
    const s = t.upsert(0) orelse return error.UnexpectedFull;
    s.* = 7;
    try testing.expectEqual(@as(?u32, 7), t.get(0));
}

test "LruStore getCopy copies bytes under the lock" {
    var store = try LruStore.init(testing.allocator, 100, 4);
    defer store.deinit();
    _ = store.put(1, "payload", 7, 8);
    const found = store.getCopy(1, testing.allocator) orelse return error.Missing;
    defer testing.allocator.free(found.bytes);
    try testing.expectEqualSlices(u8, "payload", found.bytes);
    try testing.expectEqual(@as(u64, 7), found.meta);
    try testing.expectEqual(@as(u64, 8), found.meta2);
    try testing.expect(store.getCopy(2, testing.allocator) == null);
}

test "LruStore put over an existing key replaces in place" {
    var store = try LruStore.init(testing.allocator, 100, 4);
    defer store.deinit();
    _ = store.put(1, "aa", 0, 0);
    _ = store.put(1, "bbbb", 1, 2); // same key: old bytes released first
    try testing.expectEqual(@as(usize, 1), store.stats().entries);
    try testing.expectEqual(@as(usize, 4), store.stats().bytes);
    const found = store.lookup(1).?;
    try testing.expectEqualSlices(u8, "bbbb", found.bytes);
    try testing.expectEqual(@as(u64, 1), found.meta);
}

test "LruStore evicts entries when the slot count is exhausted" {
    var store = try LruStore.init(testing.allocator, 10000, 2);
    defer store.deinit();
    _ = store.put(1, "a", 0, 0);
    _ = store.put(2, "b", 0, 0);
    // No free slot left: the LRU entry is evicted to make room.
    _ = store.put(3, "c", 0, 0);
    try testing.expectEqual(@as(usize, 2), store.stats().entries);
    try testing.expect(store.lookup(1) == null); // least recently used
    try testing.expect(store.lookup(2) != null);
    try testing.expect(store.lookup(3) != null);
}

test "LruStore evicts oldest bytes when the budget overflows" {
    var store = try LruStore.init(testing.allocator, 10, 8);
    defer store.deinit();
    _ = store.put(1, "123456", 0, 0);
    _ = store.put(2, "abcdef", 0, 0); // 12 > 10: key 1 evicted
    try testing.expect(store.lookup(1) == null);
    try testing.expect(store.lookup(2) != null);
    try testing.expect(store.stats().bytes <= 10);
}

test "LruStore remove of a missing key is a no-op" {
    var store = try LruStore.init(testing.allocator, 100, 4);
    defer store.deinit();
    _ = store.put(1, "a", 0, 0);
    store.remove(999);
    try testing.expectEqual(@as(usize, 1), store.stats().entries);
    try testing.expect(store.lookup(1) != null);
}

test "LruStore unlinks a mid-chain entry correctly" {
    // Force three keys into one bucket: with 8 buckets the mask is 7, so
    // scan for keys whose fibonacci hash lands in bucket 0.
    var store = try LruStore.init(testing.allocator, 10000, 8);
    defer store.deinit();
    var keys: [3]u64 = undefined;
    var found: usize = 0;
    var k: u64 = 1;
    while (found < 3) : (k += 1) {
        const h = k *% 0x9E3779B97F4A7C15;
        if ((h >> 32) & 7 == 0) {
            keys[found] = k;
            found += 1;
        }
    }
    _ = store.put(keys[0], "a", 0, 0);
    _ = store.put(keys[1], "b", 0, 0);
    _ = store.put(keys[2], "c", 0, 0);
    // Remove the middle link (prev >= 0 unlink arm).
    store.remove(keys[1]);
    try testing.expect(store.lookup(keys[1]) == null);
    try testing.expect(store.lookup(keys[0]) != null);
    try testing.expect(store.lookup(keys[2]) != null);
    try testing.expectEqual(@as(usize, 2), store.stats().entries);
    // Removing the head exercises the other unlink arm.
    store.remove(keys[2]);
    try testing.expect(store.lookup(keys[0]) != null);
    try testing.expectEqual(@as(usize, 1), store.stats().entries);
}

/// Mmap-backed variant of KeyedTable: same semantics, but keys/vals/filled
/// live in a memfd region instead of inline arrays. This allows the zone to
/// survive exec across --reload-hard (memfds pass through without CLOEXEC).
///
/// Memory layout (total = mmapSize(V, cap)):
///   [cap] u64 keys  |  [cap] V vals  |  u64 filled
pub fn MmapKeyedTable(comptime V: type, comptime cap: usize) type {
    const mask = cap - 1;
    if (cap & mask != 0) @compileError("MmapKeyedTable cap must be a power of two");
    return struct {
        const Self = @This();

        const zero_val: V = std.mem.zeroes(V);

        mutex: sys.Mutex = .{},
        keys: [*]u64,
        vals: [*]V,
        filled_ptr: *u64,
        /// The mmap region; caller must keep it alive.
        region: []align(std.heap.page_size_min) u8,

        /// Byte size needed for the mmap region.
        pub fn mmapSize() usize {
            return @sizeOf([cap]u64) + @sizeOf([cap]V) + @sizeOf(u64);
        }

        /// Wrap an existing mmap region. The region must be at least
        /// `mmapSize()` bytes. Ownership of the region is NOT transferred
        /// (caller manages mmap lifecycle).
        pub fn init(region: []align(std.heap.page_size_min) u8) Self {
            const keys_ptr: [*]u64 = @ptrCast(region.ptr);
            const vals_offset = @sizeOf([cap]u64);
            const vals_ptr: [*]V = @ptrCast(region.ptr + vals_offset);
            const filled_offset = vals_offset + @sizeOf([cap]V);
            const filled_ptr: *u64 = @ptrCast(region.ptr + filled_offset);
            return .{
                .keys = keys_ptr,
                .vals = vals_ptr,
                .filled_ptr = filled_ptr,
                .region = region,
            };
        }

        fn filled(self: *const Self) *u64 {
            return self.filled_ptr;
        }

        fn probe(self: *const Self, key: u64) usize {
            var i: usize = @intCast(key & mask);
            var n: usize = 0;
            while (n < cap and self.keys[i] != 0 and self.keys[i] != key) : ({
                i = (i + 1) & mask;
                n += 1;
            }) {}
            return i;
        }

        pub fn upsertLocked(self: *Self, key: u64) ?struct { slot: *V, existed: bool } {
            const i = self.probe(key);
            if (self.keys[i] == 0) {
                if (self.filled().* >= @as(u64, cap)) return null;
                self.keys[i] = key;
                self.vals[i] = zero_val;
                self.filled().* += 1;
                return .{ .slot = &self.vals[i], .existed = false };
            }
            if (self.keys[i] != key) return null;
            return .{ .slot = &self.vals[i], .existed = true };
        }

        pub fn upsert(self: *Self, key: u64) ?*V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const r = self.upsertLocked(key) orelse return null;
            return r.slot;
        }

        pub fn get(self: *Self, key: u64) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const i = self.probe(key);
            if (self.keys[i] == key) return self.vals[i];
            return null;
        }

        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            @memset(self.keys[0..cap], 0);
            self.filled().* = 0;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.filled().*;
        }
    };
}

test "MmapKeyedTable upsert/get round-trips and survives init" {
    const K = MmapKeyedTable(u32, 4);
    const region = try memfd_mod.map(try memfd_mod.create("test-kv", K.mmapSize()), K.mmapSize());
    defer std.posix.munmap(region);

    var t = K.init(region);
    inline for (0..4) |i| {
        const slot = t.upsert(100 + i) orelse return error.UnexpectedFull;
        slot.* = @intCast(i * 10);
    }
    try testing.expectEqual(@as(usize, 4), t.count());
    try testing.expectEqual(@as(u32, 20), t.get(102).?);
    try testing.expect(t.upsert(999) == null);

    // Simulate exec survival: wrap the same mmap region again.
    var t2 = K.init(region);
    try testing.expectEqual(@as(u32, 20), t2.get(102).?);
    const slot = t2.upsert(101) orelse return error.LostSlot;
    slot.* += 1;
    try testing.expectEqual(@as(u32, 11), t2.get(101).?);
}

test "MmapKeyedTable misses, clear and locking semantics" {
    const K = MmapKeyedTable(u32, 4);
    try testing.expectEqual(@as(usize, @sizeOf([4]u64) + @sizeOf([4]u32) + @sizeOf(u64)), K.mmapSize());
    const region = try memfd_mod.map(try memfd_mod.create("test-kv-miss", K.mmapSize()), K.mmapSize());
    defer std.posix.munmap(region);

    var t = K.init(region);
    try testing.expect(t.get(1) == null);
    try testing.expectEqual(@as(usize, 0), t.count());
    const s = t.upsert(1) orelse return error.UnexpectedFull;
    s.* = 11;
    const locked = t.upsertLocked(1).?;
    try testing.expect(locked.existed);
    const fresh = t.upsertLocked(2).?;
    try testing.expect(!fresh.existed);
    try testing.expectEqual(@as(usize, 2), t.count());
    t.clear();
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expect(t.get(1) == null);
    // Usable again after clear.
    const s2 = t.upsert(1) orelse return error.UnexpectedFull;
    try testing.expectEqual(@as(u32, 0), s2.*); // zeroed on create
}

test "ZoneRegistry acquire, reuse, descriptors and bad-fd adopt" {
    var reg = ZoneRegistry.init(testing.allocator);
    defer reg.deinit();

    const r1 = try reg.acquire("test-zone-a", 4096);
    try testing.expectEqual(@as(usize, 4096), r1.len);
    // Same name returns the identical region (no duplicate memfd).
    const r1b = try reg.acquire("test-zone-a", 4096);
    try testing.expectEqual(r1.ptr, r1b.ptr);
    const r2 = try reg.acquire("test-zone-b", 8192);
    try testing.expect(r2.ptr != r1.ptr);

    const descs = try reg.descriptors();
    defer testing.allocator.free(descs);
    try testing.expectEqual(@as(usize, 2), descs.len);
    for (descs) |d| {
        try testing.expect(d.fd >= 0);
        try testing.expect(d.size == 4096 or d.size == 8192);
    }

    // Adopting a closed fd is refused instead of panicking in mmap.
    try testing.expectError(error.BadFd, reg.adopt("test-zone-bad", -1, 4096));
    // Adopting an already-known name returns the existing region.
    const r1c = try reg.adopt("test-zone-a", -1, 4096);
    try testing.expectEqual(r1.ptr, r1c.ptr);
}

test "adoptInherited with no zones is a global no-op" {
    // Empty input returns before touching the process-global registry.
    try adoptInherited(testing.allocator, &.{});
}

/// Zone descriptor carried in the state file across --reload-hard.
pub const ZoneInfo = struct {
    name: []const u8,
    fd: i32,
    size: usize,
};

/// Named zone registry: maps zone name -> fd + mmap region. Used by
/// modules (limit.zig, proxy_cache) to acquire mmap-backed zones. On
/// first start the registry creates fresh memfds; on --reload-hard the
/// child inherits fds from the state file.
pub const ZoneRegistry = struct {
    const Zone = struct {
        name: []const u8,
        fd: posix.fd_t,
        size: usize,
        region: []align(std.heap.page_size_min) u8,
    };

    zones: std.array_hash_map.String(Zone),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZoneRegistry {
        return .{ .zones = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *ZoneRegistry) void {
        for (self.zones.values()) |z| {
            posix.munmap(z.region);
            sys.close(z.fd);
            self.allocator.free(z.name);
        }
        self.zones.deinit(self.allocator);
    }

    /// Acquire or create a named zone of `size` bytes. If the zone already
    /// exists (same name), returns the existing region. Otherwise creates a
    /// fresh memfd.
    pub fn acquire(self: *ZoneRegistry, name: []const u8, size: usize) ![]align(std.heap.page_size_min) u8 {
        if (self.zones.getPtr(name)) |z| return z.region;
        const fd = try posix.memfd_create(name, 0);
        try sys.ftruncate(fd, @intCast(size));
        const region = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            posix.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        const duped_name = try self.allocator.dupe(u8, name);
        try self.zones.put(self.allocator, duped_name, .{
            .name = duped_name,
            .fd = fd,
            .size = size,
            .region = region,
        });
        return region;
    }

    /// Adopt an inherited fd (survived exec from the parent daemon). The
    /// new process mmaps it and registers it under the given name.
    /// A state-file fd that is not open here (spawn does not inherit
    /// memfds) is refused: 0.18 posix.mmap panics on EBADF instead of
    /// returning an error, so validate first and let the caller fall
    /// back to a fresh zone.
    pub fn adopt(self: *ZoneRegistry, name: []const u8, fd: posix.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
        if (self.zones.getPtr(name)) |z| return z.region;
        _ = sys.fcntl(fd, linux.F.GETFD, 0) catch return error.BadFd;
        const region = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            posix.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        const duped_name = try self.allocator.dupe(u8, name);
        try self.zones.put(self.allocator, duped_name, .{
            .name = duped_name,
            .fd = fd,
            .size = size,
            .region = region,
        });
        return region;
    }

    /// Build zone descriptors for serialisation into the state file.
    pub fn descriptors(self: *const ZoneRegistry) ![]ZoneInfo {
        var list = std.ArrayList(ZoneInfo).empty;
        var it = self.zones.iterator();
        while (it.next()) |e| {
            try list.append(self.allocator, .{
                .name = e.key_ptr.*,
                .fd = @intCast(e.value_ptr.fd),
                .size = e.value_ptr.size,
            });
        }
        return list.toOwnedSlice(self.allocator);
    }
};

const posix = std.posix;
const memfd_mod = @import("memfd.zig");
const testing = std.testing;

/// Process-global zone registry. Created once during module lifecycle init
/// and read by main.zig when serialising the state file. Not thread-safe
/// for concurrent writes — lifecycle init is single-threaded (gated).
pub var global_registry: ?ZoneRegistry = null;

/// Initialise the global registry (called from lifecycle init). Returns
/// a pointer that modules use to acquire zones.
pub fn initGlobalRegistry(allocator: std.mem.Allocator) !*ZoneRegistry {
    if (global_registry) |*r| return r;
    global_registry = ZoneRegistry.init(allocator);
    return &global_registry.?;
}

/// Adopt inherited zone fds from a state file. Called before lifecycle
/// init so that modules get mmap regions that survived exec. Each
/// descriptor's fd is still valid (memfd is not CLOEXEC).
pub fn adoptInherited(allocator: std.mem.Allocator, zone_fds: []const ZoneInfo) !void {
    if (zone_fds.len == 0) return;
    const reg = try initGlobalRegistry(allocator);
    for (zone_fds) |z| {
        if (z.fd < 0) continue;
        _ = reg.adopt(z.name, @intCast(z.fd), z.size) catch continue;
    }
}
