const std = @import("std");
const posix = std.posix;

const limits_mod = @import("../dsl/limits.zig");

/// Spooling into temporary file for large request bodies onto disk.
/// `max_body_spool` defines the limit after which it writes to disk instead
/// of memory.
pub const BodySpool = struct {
    fd: posix.fd_t,
    size: usize,

    pub fn create() !BodySpool {
        const fd = try posix.memfd_create("body-spool", 0);
        return .{ .fd = fd, .size = 0 };
    }

    pub fn writeAll(self: *BodySpool, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try posix.write(self.fd, bytes[written..]);
            if (n == 0) return error.WriteZero;
            written += n;
        }
        self.size += bytes.len;
    }

    pub fn readAll(self: *const BodySpool, gpa: std.mem.Allocator) ![]u8 {
        const result = try gpa.alloc(u8, self.size);
        errdefer gpa.free(result);
        try posix.lseek_SET(self.fd, 0);
        var offset: usize = 0;
        while (offset < result.len) {
            const n = try posix.pread(self.fd, result[offset..], offset);
            if (n == 0) return error.UnexpectedEndOfFile;
            offset += n;
        }
        return result;
    }

    pub fn deinit(self: *BodySpool) void {
        posix.close(self.fd);
        self.* = undefined;
    }
};

pub const BodyStorage = struct {
    const Storage = union(enum) {
        memory: std.ArrayList(u8),
        spool: BodySpool,
    };

    allocator: std.mem.Allocator,
    storage: Storage,
    max_memory: usize,

    pub fn init(allocator: std.mem.Allocator, max_memory: usize) BodyStorage {
        return .{
            .allocator = allocator,
            .storage = .{ .memory = std.ArrayList(u8).empty },
            .max_memory = max_memory,
        };
    }

    pub fn write(self: *BodyStorage, bytes: []const u8) !void {
        switch (self.storage) {
            .memory => |*memory| {
                if (bytes.len <= self.max_memory -| memory.items.len) {
                    try memory.appendSlice(self.allocator, bytes);
                    return;
                }
                var spool = try BodySpool.create();
                errdefer spool.deinit();
                try spool.writeAll(memory.items);
                try spool.writeAll(bytes);
                memory.deinit(self.allocator);
                self.storage = .{ .spool = spool };
            },
            .spool => |*spool| {
                try spool.writeAll(bytes);
            },
        }
    }

    pub fn readAll(self: *const BodyStorage, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.storage) {
            .memory => |memory| try allocator.dupe(u8, memory.items),
            .spool => |spool| try spool.readAll(allocator),
        };
    }

    pub fn deinit(self: *BodyStorage) void {
        switch (self.storage) {
            .memory => |*memory| memory.deinit(self.allocator),
            .spool => |*spool| spool.deinit(),
        }
    }

    pub fn reset(self: *BodyStorage) void {
        switch (self.storage) {
            .memory => |*memory| memory.clearRetainingCapacity(),
            .spool => |*spool| {
                spool.deinit();
                self.storage = .{ .memory = std.ArrayList(u8).empty };
            },
        }
    }

    pub fn size(self: *const BodyStorage) usize {
        return switch (self.storage) {
            .memory => |memory| memory.items.len,
            .spool => |spool| spool.size,
        };
    }

    /// Zero-copy access to the body bytes when stored in memory.
    /// For spool mode, caller must use readAll() which allocates.
    pub fn items(self: *const BodyStorage) []const u8 {
        return switch (self.storage) {
            .memory => |memory| memory.items,
            .spool => return &.{},
        };
    }
};

test "BodySpool created and destroyed" {
    var spool = try BodySpool.create();
    defer spool.deinit();
    try std.testing.expect(spool.fd >= 0);
    try std.testing.expectEqual(@as(usize, 0), spool.size);
}

test "BodySpool writeAll and readAll round trip" {
    var spool = try BodySpool.create();
    defer spool.deinit();
    const input = "hello, body spool!";
    try spool.writeAll(input);
    const output = try spool.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, input, output);
}

test "BodySpool multiple writes are concatenated" {
    var spool = try BodySpool.create();
    defer spool.deinit();
    try spool.writeAll("hello");
    try spool.writeAll(" ");
    try spool.writeAll("world");
    try std.testing.expectEqual(@as(usize, 11), spool.size);
    const output = try spool.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "hello world", output);
}

test "BodySpool large body round trips" {
    const allocator = std.testing.allocator;
    var spool = try BodySpool.create();
    defer spool.deinit();
    const input = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate(i);
    try spool.writeAll(input);
    try std.testing.expectEqual(input.len, spool.size);
    const output = try spool.readAll(allocator);
    defer allocator.free(output);
    try std.testing.expectEqualSlices(u8, input, output);
}

test "BodyStorage starts empty" {
    var body = BodyStorage.init(std.testing.allocator, 1024);
    defer body.deinit();
    try std.testing.expectEqual(@as(usize, 0), body.size());
}

test "small body stays in memory" {
    var body = BodyStorage.init(std.testing.allocator, 1024);
    defer body.deinit();
    try body.write("hello");
    switch (body.storage) {
        .memory => {},
        .spool => return error.UnexpectedSpill,
    }
}

test "small body round trips" {
    var body = BodyStorage.init(std.testing.allocator, 1024);
    defer body.deinit();
    try body.write("hello world");
    try std.testing.expectEqual(@as(usize, 11), body.size());
    const output = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "hello world", output);
}

test "body spills when max_memory is exceeded" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello");
    try body.write("!");
    try std.testing.expectEqual(@as(usize, 6), body.size());
    switch (body.storage) {
        .memory => return error.ExpectedSpool,
        .spool => {},
    }
}

test "spilling preserves existing memory data" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello");
    try body.write(" world");
    const output = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "hello world", output);
}

test "single write larger than max_memory spills" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello world");
    try std.testing.expectEqual(@as(usize, 11), body.size());
    switch (body.storage) {
        .memory => return error.ExpectedSpool,
        .spool => {},
    }
    const output = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "hello world", output);
}

test "writes after spilling go to spool" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello");
    try body.write(" world");
    try body.write("!");
    const output = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "hello world!", output);
    switch (body.storage) {
        .memory => return error.ExpectedSpool,
        .spool => {},
    }
}

test "reset clears spooled body" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello world");
    switch (body.storage) {
        .spool => {},
        else => return error.ExpectedSpool,
    }
    body.reset();
    try std.testing.expectEqual(@as(usize, 0), body.size());
    switch (body.storage) {
        .memory => {},
        .spool => return error.ExpectedMemory,
    }
}

test "readAll can be called repeatedly" {
    var body = BodyStorage.init(std.testing.allocator, 5);
    defer body.deinit();
    try body.write("hello world");
    const first = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try body.readAll(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}
