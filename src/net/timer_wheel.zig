const std = @import("std");

/// One timer slot: an intrusive doubly-linked list node. Timers are embedded
/// in the object they govern (e.g. `Connection`), so firing an entry hands the
/// owner a pointer it can turn back into the owning object with
/// `@fieldParentPtr`.
pub const TimerEntry = struct {
    /// Absolute deadline in wheel ticks.
    expires: u64 = 0,
    prev: ?*TimerEntry = null,
    next: ?*TimerEntry = null,
    /// Index of the slot this entry currently lives in (for O(1) removal).
    slot: usize = 0,
    /// True while the entry is linked into a wheel.
    active: bool = false,
};

/// A ring-buffer timer wheel: O(1) insert/remove/rearm, amortized O(1) expiry.
///
/// Time is expressed as an abstract tick counter; the caller converts wall
/// time to ticks with the comptime `tick_ns` granularity (see
/// `tickForNs`). An entry armed at tick `now` with timeout `t` fires the
/// first time the wheel is advanced to tick `now + t` or beyond.
///
/// Entries are keyed by `expires % slot_count`, so a slot list may hold
/// entries from any number of revolutions ahead: each pass over a slot fires
/// the entries whose deadline has arrived and leaves the rest for the next
/// revolution. There is no cascade/re-link step.
///
/// `advanceTo` must be called with monotonically increasing ticks; it walks
/// every intermediate slot, so a stalled loop catches up in one call. Fired
/// entries are unlinked and handed to the caller's callback. The callback
/// must NOT destroy the objects of entries still linked in the wheel (i.e.
/// defer any teardown until `advanceTo` returns).
pub fn Wheel(comptime slots: usize, comptime tick_duration: u64) type {
    return struct {
        const Self = @This();

        /// Slot count and tick granularity are comptime constants.
        pub const slot_count = slots;
        pub const tick_ns = tick_duration;
        /// Ticks processed per `advanceTo` call at most. A stalled loop can
        /// fall arbitrarily far behind; catch-up is bounded so one call never
        /// walks an unbounded range, and continues on the next call.
        pub const max_advance = 1024;

        slots: [slot_count]?*TimerEntry = [_]?*TimerEntry{null} ** slot_count,
        /// Last tick `advanceTo` was called with.
        current: u64 = 0,

        pub fn init() Self {
            return .{};
        }

        /// Convert nanoseconds since an epoch to the wheel's tick index.
        pub fn tickForNs(ns: u64) u64 {
            return ns / tick_ns;
        }

        /// Arm `entry` to fire at `now + timeout_ticks` (saturating on
        /// overflow). The entry must not already be armed. O(1).
        pub fn insert(self: *Self, entry: *TimerEntry, now: u64, timeout_ticks: u64) void {
            std.debug.assert(!entry.active);
            const expires = std.math.add(u64, now, timeout_ticks) catch std.math.maxInt(u64);
            entry.expires = expires;
            entry.slot = @intCast(expires % slot_count);
            entry.active = true;
            self.push(entry);
        }

        /// Cancel `entry`. O(1); a no-op for an entry that is not armed.
        pub fn remove(self: *Self, entry: *TimerEntry) void {
            if (!entry.active) return;
            self.unlink(entry);
            entry.active = false;
        }

        /// Cancel and re-arm `entry` in one step. O(1).
        pub fn rearm(self: *Self, entry: *TimerEntry, now: u64, timeout_ticks: u64) void {
            self.remove(entry);
            self.insert(entry, now, timeout_ticks);
        }

        /// Advance the wheel to `tick`, firing every entry whose deadline has
        /// passed. Callbacks run in expiry order (approximately: slot order).
        /// `on_expired(ctx, entry)` must not destroy objects whose entries are
        /// still linked into the wheel. A tick jump larger than `max_advance`
        /// is processed across successive calls (bounded catch-up).
        pub fn advanceTo(self: *Self, tick: u64, ctx: anytype, comptime on_expired: *const fn (ctx: @TypeOf(ctx), entry: *TimerEntry) void) void {
            if (tick <= self.current) return;
            const target = @min(tick, self.current + max_advance);
            var t = self.current + 1;
            while (t <= target) : (t += 1) {
                self.expireSlot(t % slot_count, t, ctx, on_expired);
            }
            self.current = target;
        }

        /// Number of armed timers (tests / observability).
        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.slots) |head| {
                var cur = head;
                while (cur) |entry| : (cur = entry.next) total += 1;
            }
            return total;
        }

        fn push(self: *Self, entry: *TimerEntry) void {
            const head = &self.slots[entry.slot];
            entry.next = head.*;
            entry.prev = null;
            if (head.*) |old| old.prev = entry;
            head.* = entry;
        }

        fn unlink(self: *Self, entry: *TimerEntry) void {
            if (entry.prev) |p| p.next = entry.next else self.slots[entry.slot] = entry.next;
            if (entry.next) |n| n.prev = entry.prev;
            entry.prev = null;
            entry.next = null;
        }

        fn expireSlot(self: *Self, slot: usize, tick: u64, ctx: anytype, comptime on_expired: *const fn (ctx: @TypeOf(ctx), entry: *TimerEntry) void) void {
            var cur = self.slots[slot];
            while (cur) |entry| {
                const next = entry.next;
                if (entry.expires <= tick) {
                    self.unlink(entry);
                    entry.active = false;
                    on_expired(ctx, entry);
                }
                cur = next;
            }
        }
    };
}

const testing = std.testing;

/// The production wheel: 100 ms ticks, 1024 slots (102.4 s span per
/// revolution; the default 60 s idle timeout fits in one revolution).
pub const default_wheel = Wheel(1024, 100 * std.time.ns_per_ms);

const test_wheel = Wheel(4, 1);

const Fired = struct {
    entries: [8]*TimerEntry = undefined,
    n: usize = 0,

    fn onExpired(self: *Fired, entry: *TimerEntry) void {
        self.entries[self.n] = entry;
        self.n += 1;
    }
};

test "insert fires at the deadline, not before" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e = TimerEntry{};

    w.insert(&e, 0, 3); // expires tick 3
    w.advanceTo(1, &fired, Fired.onExpired);
    w.advanceTo(2, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);

    w.advanceTo(3, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n);
    try testing.expectEqual(@as(*TimerEntry, &e), fired.entries[0]);
    try testing.expectEqual(@as(usize, 0), w.count());
}

test "remove cancels a timer" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e = TimerEntry{};

    w.insert(&e, 0, 2);
    w.remove(&e);
    try testing.expectEqual(@as(usize, 0), w.count());

    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
    // Double removal is a no-op.
    w.remove(&e);
}

test "rearm moves the deadline" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e = TimerEntry{};

    w.insert(&e, 0, 5); // expires 5
    w.rearm(&e, 2, 2); // expires 4
    w.advanceTo(3, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
    w.advanceTo(4, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n);

    // Rearming an already-expired-but-not-yet-advanced entry re-arms it.
    var e2 = TimerEntry{};
    w.insert(&e2, 0, 1);
    w.advanceTo(0, &fired, Fired.onExpired); // no-op (same tick)
    w.rearm(&e2, 0, 100);
    w.advanceTo(1, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n); // only the old entry fired
    w.advanceTo(100, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 2), fired.n);
}

test "wrap-around: deadline beyond one revolution fires on the next pass" {
    var w = test_wheel.init(); // 4 slots
    var fired = Fired{};
    var e = TimerEntry{};

    w.insert(&e, 0, 6); // expires 6 -> slot 2
    w.advanceTo(2, &fired, Fired.onExpired); // first pass over slot 2
    try testing.expectEqual(@as(usize, 0), fired.n); // deadline is a revolution ahead
    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
    w.advanceTo(6, &fired, Fired.onExpired); // second pass over slot 2
    try testing.expectEqual(@as(usize, 1), fired.n);
}

test "multiple revolutions ahead fires after the right number of passes" {
    var w = test_wheel.init(); // 4 slots
    var fired = Fired{};
    var e = TimerEntry{};

    w.insert(&e, 0, 9); // expires 9 -> slot 1
    w.advanceTo(1, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
    w.advanceTo(9, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n);
}

test "catch-up: one big advance fires everything due in between" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e1 = TimerEntry{};
    var e2 = TimerEntry{};

    w.insert(&e1, 0, 3);
    w.insert(&e2, 0, 8);
    // Jump straight to tick 10: both must fire, once each.
    w.advanceTo(10, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 2), fired.n);
    try testing.expectEqual(@as(*TimerEntry, &e1), fired.entries[0]);
    try testing.expectEqual(@as(*TimerEntry, &e2), fired.entries[1]);

    w.advanceTo(11, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 2), fired.n); // nothing new
}

test "entries sharing a slot and deadline all fire in one pass" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e1 = TimerEntry{};
    var e2 = TimerEntry{};
    var e3 = TimerEntry{};

    w.insert(&e1, 0, 5); // slot 1
    w.insert(&e2, 0, 1); // slot 1
    w.insert(&e3, 2, 3); // slot 1, expires 5
    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 3), fired.n);
    try testing.expectEqual(@as(usize, 0), w.count());
}

test "advanceTo behind or equal to current is a no-op" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e = TimerEntry{};
    w.insert(&e, 0, 5);
    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n);
    w.advanceTo(4, &fired, Fired.onExpired);
    w.advanceTo(5, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 1), fired.n);
}

test "catch-up larger than max_advance completes across successive calls" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e1 = TimerEntry{};
    var e2 = TimerEntry{};

    w.insert(&e1, 0, 3);
    w.insert(&e2, 0, 2000); // deadline beyond the first call's window
    w.advanceTo(5000, &fired, Fired.onExpired);
    // Only max_advance ticks were processed: e1 fired, e2 did not.
    try testing.expectEqual(@as(usize, 1), fired.n);
    try testing.expectEqual(@as(*TimerEntry, &e1), fired.entries[0]);

    w.advanceTo(5000, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 2), fired.n);
    try testing.expectEqual(@as(*TimerEntry, &e2), fired.entries[1]);

    w.advanceTo(5001, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 2), fired.n); // nothing new
}

test "deadline arithmetic saturates instead of overflowing" {
    var w = test_wheel.init();
    var fired = Fired{};
    var e = TimerEntry{};
    w.insert(&e, std.math.maxInt(u64) - 1, 10);
    try testing.expectEqual(std.math.maxInt(u64), e.expires);
    // Never due at reachable ticks; must not fire early.
    w.advanceTo(4096, &fired, Fired.onExpired);
    try testing.expectEqual(@as(usize, 0), fired.n);
}
