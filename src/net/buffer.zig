const std = @import("std");
const os = std.os;

pub const Buffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,

    const default_size = 16384;

    pub fn init(allocator: std.mem.Allocator) !*Buffer {
        const buf = try allocator.create(Buffer);
        buf.* = .{
            .data = try allocator.alloc(u8, default_size),
            .read_pos = 0,
            .write_pos = 0,
        };
        return buf;
    }

    pub fn initFixed(allocator: std.mem.Allocator, size: usize) !*Buffer {
        const buf = try allocator.create(Buffer);
        buf.* = .{
            .data = try allocator.alloc(u8, size),
            .read_pos = 0,
            .write_pos = 0,
        };
        return buf;
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }

    pub fn availableWrite(self: *const Buffer) usize {
        return self.data.len - self.write_pos;
    }

    pub fn availableRead(self: *const Buffer) usize {
        return self.write_pos - self.read_pos;
    }

    pub fn writeSlice(self: *Buffer, slice: []const u8) usize {
        const available = self.availableWrite();
        const to_write = @min(slice.len, available);
        @memcpy(self.data[self.write_pos..self.write_pos + to_write], slice[0..to_write]);
        self.write_pos += to_write;
        return to_write;
    }

    pub fn readSlice(self: *Buffer, slice: []u8) usize {
        const available = self.availableRead();
        const to_read = @min(slice.len, available);
        @memcpy(slice[0..to_read], self.data[self.read_pos..self.read_pos + to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    /// Advance the read position by `n` bytes without copying. Used by
    /// zero-copy consumers (e.g. the HTTP parser) that have already taken a
    /// slice from `peek()`.
    pub fn consume(self: *Buffer, n: usize) void {
        std.debug.assert(n <= self.availableRead());
        self.read_pos += n;
    }

    pub fn compact(self: *Buffer) void {
        if (self.read_pos == 0) return;
        const available = self.availableRead();
        if (available == 0) {
            self.read_pos = 0;
            self.write_pos = 0;
        } else {
            @memcpy(self.data[0..available], self.data[self.read_pos..self.write_pos]);
            self.read_pos = 0;
            self.write_pos = available;
        }
    }

    pub fn reset(self: *Buffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }

    pub fn peek(self: *const Buffer) []u8 {
        return self.data[self.read_pos..self.write_pos];
    }
};

const testing = std.testing;
test "buffer basic operations" {
    const allocator = testing.allocator;
    const buf = try Buffer.init(allocator);
    defer buf.deinit(allocator);

    try testing.expectEqual(16384, buf.availableWrite());
    try testing.expectEqual(0, buf.availableRead());

    const written = buf.writeSlice("hello");
    try testing.expectEqual(5, written);
    try testing.expectEqual(5, buf.availableRead());
    try testing.expectEqual(16384 - 5, buf.availableWrite());

    var read_buf: [10]u8 = undefined;
    const read = buf.readSlice(&read_buf);
    try testing.expectEqual(5, read);
    try testing.expectEqualStrings("hello", read_buf[0..5]);
    try testing.expectEqual(0, buf.availableRead());
}

test "buffer compact" {
    const allocator = testing.allocator;
    const buf = try Buffer.init(allocator);
    defer buf.deinit(allocator);

    _ = buf.writeSlice("hello");
    var zeroes = [_]u8{0} ** 5;
    _ = buf.readSlice(&zeroes);

    try testing.expectEqual(0, buf.availableRead());
    try testing.expectEqual(5, buf.read_pos);
    try testing.expectEqual(5, buf.write_pos);

    buf.compact();
    try testing.expectEqual(0, buf.read_pos);
    try testing.expectEqual(0, buf.write_pos);
}

test "buffer consume advances read position without copying" {
    const allocator = testing.allocator;
    const buf = try Buffer.init(allocator);
    defer buf.deinit(allocator);

    _ = buf.writeSlice("hello world");

    // Zero-copy: take a slice, then consume exactly that many bytes.
    const part = buf.peek()[0..5];
    try testing.expectEqualStrings("hello", part);
    buf.consume(5);

    try testing.expectEqual(5, buf.read_pos);
    try testing.expectEqual(6, buf.availableRead());
    try testing.expectEqualStrings(" world", buf.peek());

    // consume(0) and full-drain are fine.
    buf.consume(0);
    buf.consume(6);
    try testing.expectEqual(0, buf.availableRead());
}