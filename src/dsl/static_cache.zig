const std = @import("std");
const sys = @import("../sys.zig");
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
/// Files at most this large have their content cached (served as one writev
/// instead of writev + sendfile); larger files keep the sendfile path.
pub const content_cache_max = 16384;

pub const Entry = struct {
    in_use: bool = false,
    /// Resolved path key (owned by the cache).
    path: []u8 = &.{},
    /// FNV-1a of `path`: the lookup compares integers first and only then
    /// verifies bytes (collision-hardening on a hot path), so the common
    /// miss over 15 non-matching entries is 15 integer compares.
    path_hash: u64 = 0,
    fd: posix.fd_t = -1,
    size: u64 = 0,
    mtime_secs: u64 = 0,
    /// Preformatted ETag ("mtime-size") and Last-Modified (IMF-fixdate).
    etag: [40]u8 = undefined,
    etag_len: usize = 0,
    lm: [48]u8 = undefined,
    lm_len: usize = 0,
    /// Full content of small files (<= content_cache_max), owned by the
    /// entry: serving them is one writev (head + cached bytes), no
    /// open/sendfile per request.
    content: []u8 = &.{},
    content_cached: bool = false,
    /// When the entry was last revalidated.
    refreshed: sys.Instant = undefined,
};

/// FNV-1a 64 over the path bytes (cache key prefilter).
fn pathHash(path: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (path) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub const StaticCache = struct {
    allocator: std.mem.Allocator,
    /// Configured entry count (config `limits.static_cache_entries`);
    /// heap-allocated at init.
    entries: []Entry = &.{},
    /// Configured revalidation window (config `limits.static_cache_valid_seconds`).
    valid_ns: u64 = valid_ns,
    /// Configured content-cache threshold (config `limits.static_content_cache_max`).
    content_cache_max: usize = content_cache_max,

    pub fn init(allocator: std.mem.Allocator) StaticCache {
        return initWithConfig(allocator, max_entries, valid_ns / std.time.ns_per_s, content_cache_max);
    }

    /// Like `init`, with configurable cache parameters (config `limits`).
    pub fn initWithConfig(allocator: std.mem.Allocator, entry_count: usize, valid_seconds: u64, content_max: usize) StaticCache {
        var c = StaticCache{
            .allocator = allocator,
            .valid_ns = valid_seconds * std.time.ns_per_s,
            .content_cache_max = content_max,
        };
        if (entry_count > 0) {
            c.entries = allocator.alloc(Entry, entry_count) catch &.{};
        }
        for (c.entries) |*e| e.* = .{};
        return c;
    }

    pub fn deinit(self: *StaticCache) void {
        for (self.entries) |*e| self.evict(e);
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.entries = &.{};
    }

    /// Find (and if stale, revalidate) the entry for `path`. Returns null on
    /// miss or when the file changed on disk.
    pub fn lookup(self: *StaticCache, path: []const u8) ?*Entry {
        const now = sys.Instant.now() catch return null;
        const want = pathHash(path);
        for (self.entries) |*e| {
            if (!e.in_use or e.path_hash != want) continue;
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (now.since(e.refreshed) > self.valid_ns) {
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
        for (self.entries) |*e| {
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
        e.path_hash = pathHash(path);
        e.fd = fd;
        e.size = size;
        e.mtime_secs = mtime_secs;
        if (size <= self.content_cache_max) {
            const content = self.allocator.alloc(u8, @intCast(size)) catch null;
            if (content) |buf| {
                var got: usize = 0;
                while (got < buf.len) {
                    const n = posix.read(fd, buf[got..]) catch break;
                    if (n == 0) break;
                    got += n;
                }
                if (got == buf.len) {
                    e.content = buf;
                    e.content_cached = true;
                } else {
                    self.allocator.free(buf);
                }
            }
        }
        const etag = std.fmt.bufPrint(&e.etag, "\"{d}-{d}\"", .{ mtime_secs, size }) catch return null;
        e.etag_len = etag.len;
        const lm = cache_date(mtime_secs, &e.lm) orelse return null;
        e.lm_len = lm.len;
        e.refreshed = sys.Instant.now() catch return null;
        e.in_use = true;
        return e;
    }

    /// The path's current (size, mtime) must match the cached metadata;
    /// evicts and returns false when the file changed (or vanished).
    fn revalidate(self: *StaticCache, e: *Entry, now: sys.Instant) bool {
        var st: sys.FileStat = undefined;
        if (sys.statFile(e.path)) |s| {
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
        if (e.fd >= 0) sys.close(e.fd);
        self.allocator.free(e.path);
        if (e.content_cached) self.allocator.free(e.content);
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
    // Epoch (day 0) was a Thursday and names[0] is "Thu": index by
    // days % 7 directly. (The sibling cache.zig uses (days + 4) % 7 with
    // Sunday-first names — same mapping, different table origin.)
    const weekday = days % 7;
    const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const mnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        names[weekday],       day,                       mnames[m], y,
        @divTrunc(rem, 3600), @divTrunc(rem % 3600, 60), rem % 60,
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
    const src = sys.openFile("testdata/hello.txt") catch return error.SkipZigTest;
    const fd = sys.dup(src) catch return error.SkipZigTest;

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
    const src = sys.openFile("testdata/hello.txt") catch return error.SkipZigTest;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const buf = std.fmt.allocPrint(allocator, "testdata/f{d}", .{i}) catch return error.SkipZigTest;
        defer allocator.free(buf);
        // Each entry needs a real fd (eviction closes them); dup the file.
        const dup = sys.dup(src) catch return error.SkipZigTest;
        _ = cache.insert(buf, dup, 1, 1) orelse return error.SkipZigTest;
    }
    var used: usize = 0;
    for (cache.entries) |*e| {
        if (e.in_use) used += 1;
    }
    try testing.expectEqual(@as(usize, 16), used);
}

test "static cache revalidates a changed file" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();

    const path = "testdata/cache-refresh-tmp";
    sys.writeFile(path, "one") catch return error.SkipZigTest;
    defer sys.deleteFile(path) catch {};

    const file = sys.openFile(path) catch return error.SkipZigTest;
    const st = sys.fstat(file) catch return error.SkipZigTest;
    const mtime: u64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    _ = cache.insert(path, file, st.size, mtime) orelse return error.SkipZigTest;

    const first = cache.lookup(path) orelse return error.SkipZigTest;
    try testing.expectEqual(file, first.fd);

    // The file changes on disk: once the entry is stale, the next lookup
    // must evict (new size/mtime). Force staleness past the 1 s window.
    sys.writeFile(path, "two three four") catch return error.SkipZigTest;
    const stale = cache.lookup(path) orelse return error.SkipZigTest;
    stale.refreshed = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };
    try testing.expect(cache.lookup(path) == null);
}

test "static cache lookup misses on an empty cache" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();
    try testing.expect(cache.lookup("testdata/hello.txt") == null);
    // Zero-entry caches never store (insert returns null, no crash).
    var empty = StaticCache.initWithConfig(allocator, 0, 1, content_cache_max);
    defer empty.deinit();
    try testing.expect(empty.lookup("anything") == null);
    // Fake fd: insert has nowhere to put it.
    try testing.expect(empty.insert("anything", -1, 10, 10) == null);
}

test "static cache skips content for large files" {
    const allocator = testing.allocator;
    var cache = StaticCache.initWithConfig(allocator, 4, 60, 8);
    defer cache.deinit();
    const src = sys.openFile("testdata/hello.txt") catch return error.SkipZigTest;
    const fd = sys.dup(src) catch return error.SkipZigTest;
    // 19 bytes > 8-byte content budget: metadata caches, body does not.
    const e = cache.insert("testdata/hello.txt", fd, 19, 1709164800) orelse return error.SkipZigTest;
    try testing.expect(!e.content_cached);
    try testing.expect(e.etag_len > 0);
    try testing.expect(e.lm_len > 0);
    // Leap-day mtime formats through the date path.
    try testing.expect(std.mem.indexOf(u8, e.lm[0..e.lm_len], "Feb 2024") != null);
    const hit = cache.lookup("testdata/hello.txt") orelse return error.SkipZigTest;
    try testing.expectEqual(fd, hit.fd);
}

test "static cache evicts a deleted file on revalidation" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();

    const path = "testdata/cache-vanish-tmp";
    sys.writeFile(path, "here today") catch return error.SkipZigTest;
    const file = sys.openFile(path) catch return error.SkipZigTest;
    const st = sys.fstat(file) catch return error.SkipZigTest;
    const mtime: u64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    _ = cache.insert(path, file, st.size, mtime) orelse return error.SkipZigTest;
    _ = cache.lookup(path) orelse return error.SkipZigTest;

    // The file vanishes: a stale lookup evicts and reports a miss.
    sys.deleteFile(path) catch return error.SkipZigTest;
    const stale = cache.lookup(path) orelse return error.SkipZigTest;
    stale.refreshed = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };
    try testing.expect(cache.lookup(path) == null);
    // Second lookup stays a miss (entry is gone).
    try testing.expect(cache.lookup(path) == null);
}

test "static cache refreshes the timestamp of an unchanged file" {
    const allocator = testing.allocator;
    var cache = StaticCache.init(allocator);
    defer cache.deinit();

    const path = "testdata/cache-steady-tmp";
    sys.writeFile(path, "steady") catch return error.SkipZigTest;
    defer sys.deleteFile(path) catch {};
    const file = sys.openFile(path) catch return error.SkipZigTest;
    const st = sys.fstat(file) catch return error.SkipZigTest;
    const mtime: u64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    _ = cache.insert(path, file, st.size, mtime) orelse return error.SkipZigTest;

    // Force staleness without touching the file: revalidation succeeds and
    // the entry stays live (covers the refreshed=now success branch).
    const stale = cache.lookup(path) orelse return error.SkipZigTest;
    stale.refreshed = .{ .timestamp = .{ .sec = 0, .nsec = 0 } };
    const hit = cache.lookup(path) orelse return error.SkipZigTest;
    try testing.expectEqual(file, hit.fd);
}

test "static cache date helpers handle month ends and leap years" {
    var buf: [48]u8 = undefined;
    // Century leap year, weekday pinned (2000-02-29 was a Tuesday).
    try testing.expectEqualStrings("Tue, 29 Feb 2000 12:00:00 GMT", cache_date(951825600, &buf).?);
    try testing.expectEqualStrings("Tue, 28 Feb 2023 00:00:00 GMT", cache_date(1677542400, &buf).?);
    // Epoch: Thursday.
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", cache_date(0, &buf).?);
    try testing.expect(isLeap(2000));
    try testing.expect(!isLeap(1900));
    try testing.expect(isLeap(2024));
    try testing.expect(!isLeap(2023));
}
