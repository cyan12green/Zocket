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

/// A byte-budgeted LRU store for opaque blobs (proxy_cache bodies). Total
/// bytes across entries never exceeds `max_bytes`, entry count never
/// exceeds `max_entries`; inserting a value that cannot fit after evicting
/// every older entry is refused (returns null). This is the second half of
/// the bounded-memory contract: caching degrades to pass-through under
/// pressure instead of eating the box.
pub fn LruStore(comptime max_entries: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: u64 = 0,
            bytes: []u8 = &.{}, // points into backing
            used: bool = false,
            tick: u64 = 0, // LRU clock
            meta: u64 = 0, // consumer-owned (expiry ns, status, ...)
            meta2: u64 = 0,
        };

        mutex: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,
        max_bytes: usize,
        entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
        used_count: usize = 0,
        used_bytes: usize = 0,
        clock: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, max_bytes: usize) Self {
            return .{ .allocator = allocator, .max_bytes = max_bytes };
        }

        fn lruIndex(self: *Self) usize {
            var best: usize = 0;
            for (&self.entries, 0..) |*e, i| {
                if (!e.used) return i; // free slot beats everything
                if (e.tick < self.entries[best].tick or !self.entries[best].used) best = i;
            }
            return best;
        }

        pub fn lookup(self: *Self, key: u64) ?Entry {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.entries) |*e| {
                if (e.used and e.key == key) {
                    self.clock += 1;
                    e.tick = self.clock;
                    return e.*;
                }
            }
            return null;
        }

        /// Insert `bytes` (copied into the zone). Evicts LRU entries until
        /// it fits; returns null (storing nothing) when the value can never
        /// fit within the byte budget even empty-handed.
        pub fn put(self: *Self, key: u64, bytes: []const u8, meta: u64, meta2: u64) ?void {
            if (bytes.len > self.max_bytes) return null;
            self.mutex.lock();
            defer self.mutex.unlock();

            // Claim a slot: same-key replace or the LRU/free choice. Either
            // way the previous occupant's bytes are released up front, so
            // the accounting below sees one uniform "empty" slot.
            var idx: usize = self.used_count;
            for (&self.entries, 0..) |*e, i| {
                if (e.used and e.key == key) {
                    idx = i;
                    break;
                }
            } else {
                idx = blk: {
                    const li = self.lruIndex();
                    break :blk li;
                };
            }
            {
                const chosen = &self.entries[idx];
                if (chosen.used) {
                    self.used_bytes -= chosen.bytes.len;
                    self.allocator.free(chosen.bytes);
                    chosen.used = false;
                    chosen.bytes = &.{};
                    self.used_count -= 1;
                }
            }

            // Make room among the REMAINING entries.
            while (self.used_bytes + bytes.len > self.max_bytes) {
                var victim: usize = std.math.maxInt(usize);
                var oldest: u64 = std.math.maxInt(u64);
                for (&self.entries, 0..) |*e, i| {
                    if (e.used and (victim == std.math.maxInt(usize) or e.tick < oldest)) {
                        victim = i;
                        oldest = e.tick;
                    }
                }
                if (victim == std.math.maxInt(usize)) return null;
                const v = &self.entries[victim];
                self.used_bytes -= v.bytes.len;
                self.allocator.free(v.bytes);
                v.used = false;
                v.bytes = &.{};
                self.used_count -= 1;
            }

            const copy = self.allocator.dupe(u8, bytes) catch return null;
            const e = &self.entries[idx];
            e.key = key;
            e.bytes = copy;
            e.used = true;
            e.meta = meta;
            e.meta2 = meta2;
            self.used_bytes += copy.len;
            self.clock += 1;
            e.tick = self.clock;
            self.used_count += 1;
            return {};
        }

        /// Invalidate one key (revalidation that must forget stale data).
        pub fn remove(self: *Self, key: u64) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.entries) |*e| {
                if (e.used and e.key == key) {
                    self.used_bytes -= e.bytes.len;
                    self.allocator.free(e.bytes);
                    e.used = false;
                    e.bytes = &.{};
                    self.used_count -= 1;
                }
            }
        }

        pub fn stats(self: *Self) struct { entries: usize, bytes: usize } {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{ .entries = self.used_count, .bytes = self.used_bytes };
        }
    };
}

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
    var store = LruStore(4).init(testing.allocator, 300);
    defer {
        for (&store.entries) |*e| {
            if (e.used) store.allocator.free(e.bytes);
        }
    }

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
    var store = LruStore(4).init(testing.allocator, 100);
    defer {
        for (&store.entries) |*e| {
            if (e.used) store.allocator.free(e.bytes);
        }
    }
    _ = store.put(7, "x", 0, 0);
    _ = store.put(8, "yy", 0, 0);
    store.remove(7);
    try testing.expect(store.lookup(7) == null);
    try testing.expect(store.lookup(8) != null);
    try testing.expectEqual(@as(usize, 1), store.stats().entries);
}

const testing = std.testing;
