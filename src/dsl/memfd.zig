const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Create an anonymous in-memory file (survives exec across --reload-hard
/// when CLOEXEC is not set). `size` bytes are pre-allocated; the region is
/// zero-initialized by the kernel. The returned fd is NOT CLOEXEC — it
/// passes through to the child process on exec.
pub fn create(name: []const u8, size: usize) !posix.fd_t {
    const fd = try posix.memfd_create(name, 0);
    try posix.ftruncate(fd, @intCast(size));
    return fd;
}

/// Memory-map a memfd for read/write access. The caller must keep the fd
/// alive for the mapping's lifetime. Returns `size` bytes of zero-init'd
/// memory backed by the anonymous file.
pub fn map(fd: posix.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
    return try posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
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
    defer posix.close(fd);

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
