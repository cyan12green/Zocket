const std = @import("std");
const sys = @import("../sys.zig");
const posix = std.posix;
const linux = std.os.linux;

/// Create an anonymous in-memory file (survives exec across --reload-hard
/// when CLOEXEC is not set). `size` bytes are pre-allocated; the region is
/// zero-initialized by the kernel. The returned fd is NOT CLOEXEC — it
/// passes through to the child process on exec.
pub fn create(name: []const u8, size: usize) !posix.fd_t {
    const fd = try posix.memfd_create(name, 0);
    try sys.ftruncate(fd, @intCast(size));
    return fd;
}

/// Memory-map a memfd for read/write access. The caller must keep the fd
/// alive for the mapping's lifetime. Returns `size` bytes of zero-init'd
/// memory backed by the anonymous file.
pub fn map(fd: posix.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
    return try posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        posix.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
}

/// Re-open an inherited fd (survived exec because memfd is not CLOEXEC)
/// and map it. Used by the child process during --reload-hard.
pub fn inheritAndMap(fd: posix.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
    return map(fd, size);
}

test "memfd create and map round-trips" {
    const size = std.heap.page_size_min;
    const fd = try create("test-zone", size);
    defer sys.close(fd);

    const region = try map(fd, size);
    defer posix.munmap(region);

    // Kernel zero-initializes the region.
    try std.testing.expectEqual(@as(u8, 0), region[0]);

    // Write and read back through the mapping.
    region[0] = 0xAB;
    region[1] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), region[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), region[1]);
}

test "memfd inheritAndMap remaps a live fd" {
    const size = std.heap.page_size_min;
    const fd = try create("test-inherit", size);
    defer sys.close(fd);
    const first = try map(fd, size);
    defer posix.munmap(first);
    first[0] = 0x5A;
    // Same fd remapped: shared mapping sees the write.
    const second = try inheritAndMap(fd, size);
    defer posix.munmap(second);
    try std.testing.expectEqual(@as(u8, 0x5A), second[0]);
}

test "memfd regions are independent per fd" {
    const size = std.heap.page_size_min;
    const fd_a = try create("test-iso-a", size);
    defer sys.close(fd_a);
    const fd_b = try create("test-iso-b", size);
    defer sys.close(fd_b);

    const a = try map(fd_a, size);
    defer posix.munmap(a);
    const b = try map(fd_b, size);
    defer posix.munmap(b);

    // A 16-byte pattern survives through a second shared mapping.
    for (0..16) |i| a[i] = @intCast(0x30 + i);
    const a2 = try inheritAndMap(fd_a, size);
    defer posix.munmap(a2);
    for (0..16) |i| try std.testing.expectEqual(@as(u8, @intCast(0x30 + i)), a2[i]);

    // The sibling fd sees none of it (still zero-initialized).
    for (0..16) |i| try std.testing.expectEqual(@as(u8, 0), b[i]);
    b[0] = 0xFF;
    try std.testing.expectEqual(@as(u8, 0x30), a[0]);
}
