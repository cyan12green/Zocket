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

        mutex: std.Thread.Mutex = .{},
        keys: [cap]u64 = [_]u64{0} ** cap,
        vals: [cap]V = [_]V{zero_val} ** cap,
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
            self.keys = [_]u64{0} ** cap;
            self.vals = [_]V{zero_val} ** cap;
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

    mutex: std.Thread.Mutex = .{},
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

const testing = std.testing;
