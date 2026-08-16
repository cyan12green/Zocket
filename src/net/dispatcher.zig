const std = @import("std");
const reactor = @import("reactor.zig");

/// Round-robin scheduler that assigns inbound connections to reactor threads.
/// Thread-safe: `pick` only touches an atomic index, so it may be called from
/// many worker/accept paths concurrently.
pub const Dispatcher = struct {
    reactors: []*reactor.Reactor,
    next: std.atomic.Value(usize),

    pub fn init(reactors: []*reactor.Reactor) Dispatcher {
        return .{
            .reactors = reactors,
            .next = std.atomic.Value(usize).init(0),
        };
    }

    pub fn count(self: *const Dispatcher) usize {
        return self.reactors.len;
    }

    /// Returns the reactor that should own the next inbound connection.
    pub fn pick(self: *Dispatcher) *reactor.Reactor {
        const i = self.next.fetchAdd(1, .monotonic) % self.reactors.len;
        return self.reactors[i];
    }
};

const testing = std.testing;

const Worker = struct {
    disp: *Dispatcher,
    counts: *[4]std.atomic.Value(usize),
    picks_per: usize,

    fn run(w: *Worker) void {
        for (0..w.picks_per) |_| {
            const r = w.disp.pick();
            _ = w.counts[r.id].fetchAdd(1, .monotonic);
        }
    }
};

fn makeReactors(allocator: std.mem.Allocator, n: usize) ![]*reactor.Reactor {
    const raws = try allocator.alloc(*reactor.Reactor, n);
    for (raws, 0..) |_, i| {
        const r = try allocator.create(reactor.Reactor);
        r.* = try reactor.Reactor.init(allocator, i, .echo);
        raws[i] = r;
    }
    return raws;
}

fn destroyReactors(allocator: std.mem.Allocator, raws: []*reactor.Reactor) void {
    for (raws) |r| {
        r.deinit();
        allocator.destroy(r);
    }
    allocator.free(raws);
}

test "dispatcher round-robins across reactors" {
    const allocator = testing.allocator;
    const n = 4;
    const raws = try makeReactors(allocator, n);
    defer destroyReactors(allocator, raws);

    var disp = Dispatcher.init(raws);
    try testing.expectEqual(n, disp.count());

    var counts = [_]usize{0} ** n;
    const picks = 1000;
    for (0..picks) |_| {
        const r = disp.pick();
        counts[r.id] += 1;
    }
    for (0..n) |i| {
        try testing.expectEqual(picks / n, counts[i]);
    }
}

test "dispatcher picks stay balanced under concurrent threads" {
    const allocator = testing.allocator;
    const n = 4;
    const raws = try makeReactors(allocator, n);
    defer destroyReactors(allocator, raws);

    var disp = Dispatcher.init(raws);

    const threads = 8;
    const picks_per = 2000;
    var counts = [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** n;
    var handles: [threads]std.Thread = undefined;

    var workers: [threads]Worker = undefined;
    for (0..threads) |i| {
        workers[i] = .{ .disp = &disp, .counts = &counts, .picks_per = picks_per };
        handles[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    }
    for (0..threads) |i| {
        handles[i].join();
    }

    const total = threads * picks_per;
    var sum: usize = 0;
    for (0..n) |i| {
        const c = counts[i].load(.monotonic);
        const expected = total / n;
        // Small slack for interleaving; distribution must stay near-equal.
        try testing.expect(c >= expected - 5);
        try testing.expect(c <= expected + 5);
        sum += c;
    }
    try testing.expectEqual(total, sum);
}
