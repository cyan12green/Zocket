const std = @import("std");
const posix = std.posix;

/// nginx `open_file_cache` equivalent for the static module (per-reactor, no
/// locks). A small cache of open file fds plus their metadata and
/// preformatted entity headers (ETag, Last-Modified): serving a cached file
/// costs zero open/stat/close syscalls and zero date formatting per
/// request. Entries are revalidated against the path's current (size,
/// mtime) when older than `valid_ns`, so a replaced file is picked up
/// within the window; the cached fd is shared between requests until then.
pub const valid_ns = 1 * std.time.ns_per_s;
const max_entries = 16;

pub const Entry = struct {
    in_use: bool = false,
    /// Resolved path key (owned by the cache).
    path: []u8 = &.{},
    fd: posix.fd_t = -1,
    size: u64 = 0,
    mtime_secs: u64 = 0,
    /// Preformatted ETag ("mtime-size") and Last-Modified (IMF-fixdate).
    etag: [40]u8 = undefined,
    etag_len: usize = 0,
    lm: [48]u8 = undefined,
    lm_len: usize = 0,
    /// When the entry was last revalidated.
    refreshed: std.time.Instant = undefined,
};

pub const StaticCache = struct {
    allocator: std.mem.Allocator,
    entries: [max_entries]Entry = undefined,

    pub fn init(allocator: std.mem.Allocator) StaticCache {
        var c = StaticCache{ .allocator = allocator };
        for (&c.entries) |*e| e.* = .{};
        return c;
    }

    pub fn deinit(self: *StaticCache) void {
        for (&self.entries) |*e| self.evict(e);
    }

    /// Find (and if stale, revalidate) the entry for `path`. Returns null on
    /// miss or when the file changed on disk.
    pub fn lookup(self: *StaticCache, path: []const u8) ?*Entry {
        const now = std.time.Instant.now() catch return null;
        for (&self.entries) |*e| {
            if (!e.in_use) continue;
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (now.since(e.refreshed) > valid_ns) {
                if (!self.revalidate(e, now)) return null;
            }
            return e;
        }
        return null;
    }

    /// Insert a freshly opened fd + metadata, evicting the oldest entry when
    /// full. Returns the entry (the cache owns `fd` from now on) or null
    /// when the key could not be stored.
    pub fn insert(
        self: *StaticCache,
        path: []const u8,
        fd: posix.fd_t,
        size: u64,
        mtime_secs: u64,
    ) ?*Entry {
        var victim: ?*Entry = null;
        for (&self.entries) |*e| {
            if (!e.in_use) {
                victim = e;
                break;
            }
            if (victim == null or e.refreshed.since(victim.?.refreshed) > 0) {
                victim = e;
            }
        }
        const e = victim orelse return null;
        self.evict(e);

        e.path = self.allocator.dupe(u8, path) catch return null;
        errdefer self.allocator.free(e.path);
        e.fd = fd;
        e.size = size;
        e.mtime_secs = mtime_secs;
        const etag = std.fmt.bufPrint(&e.etag, "\"{d}-{d}\"", .{ mtime_secs, size }) catch return null;
        e.etag_len = etag.len;
        const lm = cache_date(mtime_secs, &e.lm) orelse return null;
        e.lm_len = lm.len;
        e.refreshed = std.time.Instant.now() catch return null;
        e.in_use = true;
        return e;
    }

    /// The path's current (size, mtime) must match the cached metadata;
    /// evicts and returns false when the file changed (or vanished).
    fn revalidate(self: *StaticCache, e: *Entry, now: std.time.Instant) bool {
        var st: std.fs.File.Stat = undefined;
        if (std.fs.cwd().statFile(e.path)) |s| {
            st = s;
        } else |_| {
            self.evict(e);
            return false;
        }
        const mtime: u64 = @intCast(@max(0, @divTrunc(st.mtime.nanoseconds, std.time.ns_per_s)));
        if (st.size != e.size or mtime != e.mtime_secs) {
            self.evict(e);
            return false;
        }
        e.refreshed = now;
        return true;
    }

    fn evict(self: *StaticCache, e: *Entry) void {
        if (!e.in_use) return;
        if (e.fd >= 0) posix.close(e.fd);
        self.allocator.free(e.path);
        e.* = .{};
    }
};

/// IMF-fixdate (RFC 9110 §5.6.7) for a unix timestamp, into `buf`.
fn cache_date(secs: u64, buf: []u8) ?[]const u8 {
    const days = @divTrunc(secs, 86400);
    const rem = secs % 86400;
    var y: u64 = 1970;
    var d = days;
    while (true) {
        const leap: u64 = if (isLeap(y)) 366 else 365;
        if (d < leap) break;
        d -= leap;
        y += 1;
    }
    const months = [_]u8{ 31, if (isLeap(y)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: usize = 0;
    while (d >= months[m]) {
        d -= months[m];
        m += 1;
    }
    const day = d + 1;
    const weekday = (days + 4) % 7; // 1970-01-01 was a Thursday
    const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const mnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        names[weekday],     day,  mnames[m],     y,
        @divTrunc(rem, 3600),      @divTrunc(rem % 3600, 60),
        rem % 60,
    }) catch null;
}

fn isLeap(y: u64) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

const testing = std.testing;

test "static cache insert and lookup" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();
    const src = std.fs.cwd().openFile("testdata/hello.txt", .{}) catch return error.SkipZigTest;
    const fd = posix.dup(src.handle) catch return error.SkipZigTest;

    const e = cache.insert("testdata/hello.txt", fd, 19, 123) orelse return error.SkipZigTest;
    try testing.expectEqual(fd, e.fd);
    try testing.expectEqual(@as(usize, 19), e.size);

    const hit = cache.lookup("testdata/hello.txt") orelse return error.SkipZigTest;
    try testing.expectEqual(fd, hit.fd);
    try testing.expect(hit.etag_len > 0);
    try testing.expect(hit.lm_len > 0);
    try testing.expect(cache.lookup("testdata/other.txt") == null);
}

test "static cache evicts when full" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();
    const src = std.fs.cwd().openFile("testdata/hello.txt", .{}) catch return error.SkipZigTest;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const buf = std.fmt.allocPrint(allocator, "testdata/f{d}", .{i}) catch return error.SkipZigTest;
        defer allocator.free(buf);
        // Each entry needs a real fd (eviction closes them); dup the file.
        const dup = posix.dup(src.handle) catch return error.SkipZigTest;
        _ = cache.insert(buf, dup, 1, 1) orelse return error.SkipZigTest;
    }
    var used: usize = 0;
    for (&cache.entries) |*e| {
        if (e.in_use) used += 1;
    }
    try testing.expectEqual(@as(usize, 16), used);
}

test "static cache revalidates a changed file" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();

    const path = "testdata/cache-refresh-tmp";
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = "one" }) catch return error.SkipZigTest;
    defer std.fs.cwd().deleteFile(path) catch {};

    const file = std.fs.cwd().openFile(path, .{}) catch return error.SkipZigTest;
    const st = file.stat() catch return error.SkipZigTest;
    const mtime: u64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    _ = cache.insert(path, file.handle, st.size, mtime) orelse return error.SkipZigTest;

    const first = cache.lookup(path) orelse return error.SkipZigTest;
    try testing.expectEqual(file.handle, first.fd);

    // The file changes on disk: once the entry is stale, the next lookup
    // must evict (new size/mtime). Force staleness past the 1 s window.
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = "two three four" }) catch return error.SkipZigTest;
    const stale = cache.lookup(path) orelse return error.SkipZigTest;
    stale.refreshed = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };
    try testing.expect(cache.lookup(path) == null);
}
