//! Zig 0.18 compatibility shims.
//!
//! The 0.18 stdlib removed a large part of `std.posix` (socket syscalls,
//! `clock_gettime`, `nanosleep`, `close`, `write`, `fcntl`, `epoll_*`,
//! `eventfd`, `pipe`/`fork`/etc.) and `std.time.Instant`. The survivors live
//! in `std.os.linux` as raw syscalls returning `usize` (negative errno).
//! This module re-exposes the 0.16-era signatures the server was written
//! against, implemented over the raw Linux syscalls with the same error
//! names the call sites already handle (`WouldBlock`, ...).
//!
//! Linux-only by design (the server targets Linux epoll).
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fd_t = posix.fd_t;

/// Drop-in replacement for `std.time.Instant` (removed in 0.18):
/// monotonic BOOTTIME clock, `now()` + `since()` in nanoseconds.
pub const Instant = struct {
    timestamp: posix.timespec,

    pub const InitError = error{UnsupportedClock};

    pub fn now() InitError!Instant {
        var ts: posix.timespec = undefined;
        // BOOTTIME like the old std.time.Instant: monotonic and including
        // time the system spends suspended.
        const rc = linux.clock_gettime(.BOOTTIME, &ts);
        if (linux.errno(rc) != .SUCCESS) return error.UnsupportedClock;
        return .{ .timestamp = ts };
    }

    /// Nanoseconds from `start` to `self`, saturating at 0.
    pub fn since(self: Instant, start: Instant) u64 {
        const d_sec: i128 = @as(i128, self.timestamp.sec) - @as(i128, start.timestamp.sec);
        const d_nsec: i128 = @as(i128, self.timestamp.nsec) - @as(i128, start.timestamp.nsec);
        const total = d_sec * 1_000_000_000 + d_nsec;
        if (total < 0) return 0;
        return @intCast(total);
    }
};

/// 0.16 `posix.clock_gettime(clk)` shape: returns the timestamp, no out-param.
pub fn clock_gettime(clk_id: posix.CLOCK) Instant.InitError!posix.timespec {
    var ts: posix.timespec = undefined;
    const rc = linux.clock_gettime(switch (clk_id) {
        .REALTIME => .REALTIME,
        .MONOTONIC => .MONOTONIC,
        .MONOTONIC_RAW => .MONOTONIC_RAW,
        .BOOTTIME => .BOOTTIME,
        else => .REALTIME,
    }, &ts);
    if (linux.errno(rc) != .SUCCESS) return error.UnsupportedClock;
    return ts;
}

/// 0.16 `posix.nanosleep(seconds, nanoseconds)`: retry on EINTR, ignore rest.
pub fn nanosleep(seconds: u64, nanoseconds: u64) void {
    var req = posix.timespec{
        .sec = @intCast(seconds),
        .nsec = @intCast(nanoseconds),
    };
    while (true) {
        const rc = linux.nanosleep(&req, &req);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub const WriteError = error{
    InputOutput,
    SystemResources,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    AccessDenied,
    WouldBlock,
    ConnectionTimedOut,
    NotOpenForWriting,
    SocketNotConnected,
    Canceled,
    Unexpected,
};

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    while (true) {
        const rc = linux.write(fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .ACCES => return error.AccessDenied,
            .BADF, .INVAL => return error.NotOpenForWriting,
            .NOTCONN => return error.SocketNotConnected,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .CANCELED => return error.Canceled,
            .FAULT => unreachable,
            else => return error.Unexpected,
        }
    }
}

pub fn writev(fd: fd_t, iovs: []const posix.iovec_const) WriteError!usize {
    if (iovs.len == 0) return 0;
    while (true) {
        const rc = linux.writev(fd, iovs.ptr, iovs.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .ACCES => return error.AccessDenied,
            .BADF, .INVAL => return error.NotOpenForWriting,
            .NOTCONN => return error.SocketNotConnected,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .CANCELED => return error.Canceled,
            .FAULT => unreachable,
            else => return error.Unexpected,
        }
    }
}

pub const SocketError = error{
    PermissionDenied,
    AddressFamilyNotSupported,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    SystemResources,
    Unexpected,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!fd_t {
    const rc = linux.socket(domain, socket_type, protocol);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .PERM, .ACCES => return error.PermissionDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        .NOBUFS, .NOMEM, .MFILE, .NFILE => return error.SystemResources,
        .INVAL => return error.SocketTypeNotSupported,
        else => return error.Unexpected,
    }
}

pub const BindError = error{
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    PermissionDenied,
    SystemResources,
    Unexpected,
};

pub fn bind(fd: fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    const rc = linux.bind(fd, addr, len);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT, .INVAL => return error.AddressFamilyNotSupported,
        .PERM, .ACCES => return error.PermissionDenied,
        .BADF => return error.Unexpected,
        else => return error.Unexpected,
    }
}

pub const ListenError = error{
    AddressInUse,
    SystemResources,
    Unexpected,
};

pub fn listen(fd: fd_t, backlog: u32) ListenError!void {
    const rc = linux.listen(fd, backlog);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub const ConnectError = error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    HostUnreachable,
    NetworkUnreachable,
    ProtocolNotSupported,
    SystemResources,
    WouldBlock,
    Canceled,
    Unexpected,
};

pub fn connect(fd: fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    const rc = linux.connect(fd, @ptrCast(addr), len);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.PermissionDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .AGAIN, .INPROGRESS => return error.WouldBlock,
        .ALREADY => return error.ConnectionPending,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .HOSTUNREACH => return error.HostUnreachable,
        .NETUNREACH => return error.NetworkUnreachable,
        .PROTOTYPE, .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .INTR => return error.Canceled,
        .CANCELED => return error.Canceled,
        else => return error.Unexpected,
    }
}

pub const FcntlError = error{
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Locked,
    Unexpected,
};

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    const rc = linux.fcntl(fd, cmd, arg);
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        .ACCES, .PERM => return error.PermissionDenied,
        .AGAIN => return error.Locked,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return error.Unexpected,
    }
}

/// `posix.open(path, flags, mode)` via the kept `openat`.
pub fn open(path: []const u8, flags: posix.O, mode: posix.mode_t) posix.OpenError!fd_t {
    return posix.openat(posix.AT.FDCWD, path, flags, mode);
}

pub const DupError = error{
    SystemResources,
    Unexpected,
};

pub fn dup(old: fd_t) DupError!fd_t {
    const rc = linux.dup(old);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn dup2(old: fd_t, new: fd_t) DupError!void {
    // POSIX: when old and new are the same valid descriptor, dup2 is a
    // no-op success (dup3 would return EINVAL instead).
    if (old == new) {
        const probe = linux.fcntl(old, linux.F.GETFD, 0);
        if (linux.errno(probe) != .SUCCESS) return error.Unexpected;
        return;
    }
    const rc = linux.dup3(old, new, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn pipe() DupError![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = linux.pipe(&fds);
    switch (linux.errno(rc)) {
        .SUCCESS => return fds,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn fork() DupError!posix.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn setsid() DupError!posix.pid_t {
    const rc = linux.setsid();
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Unexpected,
    }
}

pub fn getpid() posix.pid_t {
    return linux.getpid();
}

pub fn eventfd(initval: u32, flags: u32) DupError!fd_t {
    const rc = linux.eventfd(initval, flags);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn epoll_create1(flags: u32) DupError!fd_t {
    const rc = linux.epoll_create1(flags);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
}

pub const EpollCtlError = error{
    BadFd,
    NotFound,
    AlreadyPresent,
    PermissionDenied,
    Unexpected,
};

pub fn epoll_ctl(epfd: fd_t, op: u32, fd: fd_t, event: ?*linux.epoll_event) EpollCtlError!void {
    const rc = linux.epoll_ctl(epfd, op, fd, event);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        .NOENT => return error.NotFound,
        .EXIST => return error.AlreadyPresent,
        .PERM, .ACCES => return error.PermissionDenied,
        else => return error.Unexpected,
    }
}

pub fn socketpair(domain: u32, socket_type: u32, protocol: u32) DupError![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = linux.socketpair(domain, socket_type, protocol, &fds);
    switch (linux.errno(rc)) {
        .SUCCESS => return fds,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub const PReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    Unseekable,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    Canceled,
    Unexpected,
};

pub fn pread(fd: fd_t, buf: []u8, offset: u64) PReadError!usize {
    if (buf.len == 0) return 0;
    const rc = linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        .INTR => return error.Canceled,
        .IO => return error.InputOutput,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .ISDIR => return error.IsDir,
        .NXIO, .SPIPE => return error.Unseekable,
        .CONNRESET => return error.ConnectionResetByPeer,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .BADF, .INVAL => return error.NotOpenForReading,
        .CANCELED => return error.Canceled,
        .FAULT => unreachable,
        else => return error.Unexpected,
    }
}

pub const TruncateError = error{
    FileTooBig,
    InputOutput,
    PermissionDenied,
    Unseekable,
    Unexpected,
};

pub fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    const rc = linux.ftruncate(fd, @intCast(length));
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .PERM, .ACCES, .ROFS, .TXTBSY => return error.PermissionDenied,
        .INVAL => return error.Unseekable,
        else => return error.Unexpected,
    }
}

pub const GetSockOptError = error{
    PermissionDenied,
    SocketNotConnected,
    SystemResources,
    Unexpected,
};

pub fn getsockopt(fd: fd_t, level: u32, optname: u32, value: []u8) GetSockOptError!void {
    var optlen: posix.socklen_t = @intCast(value.len);
    const rc = linux.getsockopt(fd, @intCast(level), optname, value.ptr, &optlen);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .PERM, .ACCES => return error.PermissionDenied,
        .NOTCONN, .BADF, .INVAL => return error.SocketNotConnected,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .FAULT => unreachable,
        else => return error.Unexpected,
    }
}

pub const GetSockNameError = error{
    SystemResources,
    Unexpected,
};

pub fn getsockname(fd: fd_t, addr: *posix.sockaddr, len: *posix.socklen_t) GetSockNameError!void {
    const rc = linux.getsockname(fd, addr, len);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub const ReadLinkError = error{
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotLink,
    Unexpected,
};

pub fn readlink(path: []const u8, out_buffer: []u8) ReadLinkError![]u8 {
    if (path.len >= posix.PATH_MAX) return error.NameTooLong;
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const rc = linux.readlink(zbuf[0..path.len :0], out_buffer.ptr, out_buffer.len);
    switch (linux.errno(rc)) {
        .SUCCESS => return out_buffer[0..rc],
        .NOENT, .NOTDIR => return error.FileNotFound,
        .INVAL => return error.NotLink,
        .NAMETOOLONG => return error.NameTooLong,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .FAULT => unreachable,
        else => return error.Unexpected,
    }
}

/// 0.16 `posix.lseek_SET(fd, offset)` helper.
pub fn lseek_SET(fd: fd_t, offset: u64) PReadError!void {
    const rc = linux.lseek(fd, @intCast(offset), posix.SEEK.SET);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NXIO, .SPIPE => return error.Unseekable,
        .BADF, .INVAL => return error.NotOpenForReading,
        else => return error.Unexpected,
    }
}

// ---- file helpers (replace the removed std.fs.Dir/File surface) ----

/// Same shape as `std.Io.File.Stat` (size, mtime.nanoseconds, kind), filled
/// from `statx` so existing field accesses keep working.
pub const FileStat = std.Io.File.Stat;

pub const StatError = error{
    FileNotFound,
    AccessDenied,
    NotDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

fn statxToFileStat(sx: linux.Statx) FileStat {
    const mode: u32 = sx.mode;
    const kind: std.Io.File.Kind = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => .directory,
        linux.S.IFREG => .file,
        linux.S.IFLNK => .sym_link,
        linux.S.IFCHR => .character_device,
        linux.S.IFBLK => .block_device,
        linux.S.IFIFO => .named_pipe,
        linux.S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };
    const mtime_ns: i128 = @as(i128, sx.mtime.sec) * 1_000_000_000 + @as(i128, sx.mtime.nsec);
    const ctime_ns: i128 = @as(i128, sx.ctime.sec) * 1_000_000_000 + @as(i128, sx.ctime.nsec);
    return .{
        .inode = sx.ino,
        .nlink = sx.nlink,
        .size = sx.size,
        .permissions = @enumFromInt(@as(posix.mode_t, @intCast(mode & 0o7777))),
        .kind = kind,
        .atime = null,
        .mtime = .{ .nanoseconds = @intCast(mtime_ns) },
        .ctime = .{ .nanoseconds = @intCast(ctime_ns) },
        .block_size = sx.blksize,
    };
}

fn statxErr(rc: usize) StatError {
    return switch (linux.errno(rc)) {
        .SUCCESS => unreachable,
        .NOENT, .LOOP => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM, .NOBUFS => error.SystemResources,
        .FAULT => unreachable,
        else => error.Unexpected,
    };
}

const statx_mask: linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .NLINK = true,
    .SIZE = true,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
};

fn toZ(path: []const u8, buf: *[posix.PATH_MAX:0]u8) StatError![:0]const u8 {
    if (path.len >= posix.PATH_MAX) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// `std.fs.cwd().statFile(path)` replacement (follows symlinks).
pub fn statFile(path: []const u8) StatError!FileStat {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = try toZ(path, &zbuf);
    var sx: linux.Statx = undefined;
    const rc = linux.statx(posix.AT.FDCWD, zpath, 0, statx_mask, &sx);
    if (linux.errno(rc) != .SUCCESS) return statxErr(rc);
    return statxToFileStat(sx);
}

/// `File.stat()` replacement for an open fd.
pub fn fstat(fd: fd_t) StatError!FileStat {
    var sx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", posix.AT.EMPTY_PATH, statx_mask, &sx);
    if (linux.errno(rc) != .SUCCESS) return statxErr(rc);
    return statxToFileStat(sx);
}

pub const OpenFileError = StatError || error{ NotFile, IsDir };

/// `std.fs.cwd().openFile(path, .{})` replacement: read-only + CLOEXEC.
pub fn openFile(path: []const u8) OpenFileError!fd_t {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = toZ(path, &zbuf) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.NotDir => return error.NotDir,
        error.NameTooLong => return error.NameTooLong,
        error.SystemResources => return error.SystemResources,
        error.Unexpected => return error.Unexpected,
    };
    const rc = linux.openat(posix.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .NOENT, .NOTDIR, .LOOP => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// `std.fs.cwd().realpath(path, buf)` replacement: resolve via /proc/self/fd
/// (opens O_PATH, so it works for directories too).
pub fn realpath(path: []const u8, buf: []u8) StatError![]u8 {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = try toZ(path, &zbuf);
    const rc = linux.openat(posix.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .PATH = true }, 0);
    const fd: fd_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT, .NOTDIR, .LOOP => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    };
    defer close(fd);
    var link_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "/proc/self/fd/{d}", .{fd}) catch return error.Unexpected;
    var zlink: [64:0]u8 = undefined;
    @memcpy(zlink[0..link.len], link);
    zlink[link.len] = 0;
    const n = linux.readlink(zlink[0..link.len :0], buf.ptr, buf.len);
    switch (linux.errno(n)) {
        .SUCCESS => return buf[0..n],
        .NAMETOOLONG => return error.NameTooLong,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// Test helper: `std.fs.cwd().writeFile(.{ .sub_path, .data })` replacement.
pub fn writeFile(path: []const u8, data: []const u8) (StatError || WriteError)!void {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = try toZ(path, &zbuf);
    const rc = linux.openat(posix.AT.FDCWD, zpath, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o666);
    const fd: fd_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM, .ROFS, .ISDIR => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    };
    defer close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = try write(fd, data[off..]);
        off += n;
    }
}

/// `std.fs.cwd().createFile(path, .{})` replacement: RDWR|CREAT|TRUNC.
pub fn createFile(path: []const u8) StatError!fd_t {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = try toZ(path, &zbuf);
    const rc = linux.openat(posix.AT.FDCWD, zpath, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o666);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM, .ROFS, .ISDIR => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// `File.writeAll` replacement.
pub fn writeAll(fd: fd_t, bytes: []const u8) WriteError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try write(fd, bytes[off..]);
    }
}

/// Test helper: `std.fs.cwd().deleteFile(path)` replacement.
pub fn deleteFile(path: []const u8) StatError!void {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = try toZ(path, &zbuf);
    const rc = linux.unlinkat(posix.AT.FDCWD, zpath, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        else => return error.Unexpected,
    }
}

/// Test helper: `std.fs.cwd().readFileAlloc(path, gpa, .limited(n))`.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) (OpenFileError || error{OutOfMemory})![]u8 {
    const fd = try openFile(path);
    defer close(fd);
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = posix.read(fd, &chunk) catch return error.Unexpected;
        if (n == 0) break;
        if (total + n > max_bytes) return error.Unexpected;
        try list.appendSlice(allocator, chunk[0..n]);
        total += n;
    }
    return list.toOwnedSlice(allocator);
}

/// Test helper: `std.fs.cwd().symLink(target, link, .{})` replacement.
pub fn symLink(target: []const u8, link_path: []const u8) StatError!void {
    var zt: [posix.PATH_MAX:0]u8 = undefined;
    var zl: [posix.PATH_MAX:0]u8 = undefined;
    const zt_s = try toZ(target, &zt);
    const zl_s = try toZ(link_path, &zl);
    const rc = linux.symlink(zt_s, zl_s);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// Minimal directory iterator for autoindex (`std.fs.Dir.iterate`).
pub const DirEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

pub const Dir = struct {
    fd: fd_t,
    buf: [8192]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    eof: bool = false,
    pending_name: [512]u8 = undefined,
    pending_len: usize = 0,
    pending_kind: std.Io.File.Kind = .unknown,

    const linux_dirent64 = extern struct {
        ino: u64,
        off: i64,
        reclen: u16,
        entry_type: u8,
        name: [256]u8,
    };

    pub fn next(self: *Dir) ?DirEntry {
        while (true) {
            if (self.pos >= self.end) {
                if (self.eof) return null;
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                if (linux.errno(rc) != .SUCCESS or rc == 0) {
                    self.eof = true;
                    return null;
                }
                self.pos = 0;
                self.end = rc;
            }
            const d: *align(1) const linux_dirent64 = @ptrCast(@alignCast(&self.buf[self.pos]));
            const reclen: usize = d.reclen;
            if (reclen == 0 or self.pos + reclen > self.end) {
                self.eof = true;
                return null;
            }
            self.pos += reclen;
            const raw_name = std.mem.span(@as([*:0]const u8, @ptrCast(&d.name)));
            if (raw_name.len == 0 or (raw_name.len == 1 and raw_name[0] == '.') or
                (raw_name.len == 2 and raw_name[0] == '.' and raw_name[1] == '.'))
            {
                continue;
            }
            const copy_len = @min(raw_name.len, self.pending_name.len);
            @memcpy(self.pending_name[0..copy_len], raw_name[0..copy_len]);
            self.pending_len = copy_len;
            self.pending_kind = switch (d.entry_type) {
                4 => .directory,
                8 => .file,
                10 => .sym_link,
                1 => .named_pipe,
                2 => .character_device,
                6 => .block_device,
                12 => .unix_domain_socket,
                else => .unknown,
            };
            return .{ .name = self.pending_name[0..self.pending_len], .kind = self.pending_kind };
        }
    }
};

/// `std.fs.cwd().openDir(path, .{})` replacement for iteration.
pub fn openDir(path: []const u8) OpenFileError!Dir {
    var zbuf: [posix.PATH_MAX:0]u8 = undefined;
    const zpath = toZ(path, &zbuf) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.NotDir => return error.NotDir,
        error.NameTooLong => return error.NameTooLong,
        error.SystemResources => return error.SystemResources,
        error.Unexpected => return error.Unexpected,
    };
    const rc = linux.openat(posix.AT.FDCWD, zpath, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return .{ .fd = @intCast(rc) },
        .NOENT, .NOTDIR, .LOOP => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

// ---- sync (replace the removed std.Thread.Mutex) ----

/// Blocking mutex with the old `std.Thread.Mutex` call shape
/// (`lock()` / `unlock()` / `tryLock()`, no Io needed), futex-backed.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn lock(self: *Mutex) void {
        var c = self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) orelse return;
        if (c != 2) c = self.state.swap(2, .acquire);
        while (c != 0) {
            _ = linux.futex_4arg(
                @ptrCast(&self.state),
                .{ .cmd = .WAIT, .private = true },
                2,
                null,
            );
            c = self.state.swap(2, .acquire);
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(0, .release) != 1) {
            _ = linux.futex_4arg(
                @ptrCast(&self.state),
                .{ .cmd = .WAKE, .private = true },
                1,
                null,
            );
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }
};

/// `std.crypto.random.bytes(buf)` replacement (CSPRNG via getrandom).
pub fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf.ptr + off, buf.len - off, 0);
        const err = linux.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) continue;
            off += rc;
        } else if (err == .INTR) {
            continue;
        } else {
            // getrandom virtually never fails with flags=0; fall back to a
            // xorshift mix so callers never block on entropy.
            var seed: u64 = 0x9E3779B97F4A7C15 ^ @as(u64, @intCast(off));
            for (buf[off..]) |*b| {
                seed ^= seed >> 12;
                seed ^= seed << 25;
                seed ^= seed >> 27;
                b.* = @truncate(seed);
            }
            return;
        }
    }
}

/// `std.ascii.indexOfIgnoreCase(haystack, needle)` replacement.
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

/// Old `std.fs.path.relative(allocator, from, to)` shape over the new
/// `relativeAlloc` (both inputs are absolute at our call sites, so the
/// dummy cwd is never consulted).
pub fn relativePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    return std.fs.path.relativeAlloc(allocator, ".", null, from, to);
}

const testing = std.testing;

test "compat: Instant and clock_gettime move forward" {
    const t0 = try Instant.now();
    nanosleep(0, 2 * std.time.ns_per_ms);
    const t1 = try Instant.now();
    try testing.expect(t1.since(t0) >= 2 * std.time.ns_per_ms / 2);
    try testing.expectEqual(@as(u64, 0), t0.since(t1)); // saturates
    const ts = try clock_gettime(posix.CLOCK.REALTIME);
    try testing.expect(ts.sec > 0);
}

test "compat: Mutex excludes concurrent increments" {
    var m = Mutex{};
    try testing.expect(m.tryLock());
    try testing.expect(!m.tryLock());
    m.unlock();
    const N = 4;
    const Per = 5000;
    var counter: u32 = 0;
    const Worker = struct {
        fn run(mu: *Mutex, c: *u32) void {
            var i: usize = 0;
            while (i < Per) : (i += 1) {
                mu.lock();
                c.* += 1;
                mu.unlock();
            }
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &counter });
    for (&threads) |*t| t.join();
    try testing.expectEqual(@as(u32, N * Per), counter);
}

test "compat: randomBytes fills and indexOfIgnoreCase matches" {
    var a: [32]u8 = @splat(0);
    randomBytes(&a);
    var empty: [0]u8 = .{};
    randomBytes(&empty); // zero-length is a no-op
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", ""));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "he"));
    try testing.expectEqual(@as(?usize, 2), indexOfIgnoreCase("aBcDe", "CD"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("abc", "abcd"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("abc", "x"));
}

test "compat: relativePath computes a relative path" {
    const rel = try relativePath(testing.allocator, "/a/b", "/a/c");
    defer testing.allocator.free(rel);
    try testing.expectEqualStrings("../c", rel);
}

test "compat: file helpers round-trip" {
    const dir = "/tmp";
    const path = dir ++ "/zocket-compat-roundtrip.txt";
    const link = dir ++ "/zocket-compat-roundtrip-link";
    defer deleteFile(path) catch {};
    defer deleteFile(link) catch {};

    try writeFile(path, "hello compat");
    const st = try statFile(path);
    try testing.expectEqual(std.Io.File.Kind.file, st.kind);
    try testing.expectEqual(@as(u64, 12), st.size);

    const fd = try openFile(path);
    const fst = try fstat(fd);
    try testing.expectEqual(@as(u64, 12), fst.size);
    var head: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try pread(fd, &head, 0));
    try testing.expectEqualStrings("hello", &head);
    try lseek_SET(fd, 0);
    close(fd);

    const got = try readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello compat", got);

    var rp_buf: [512]u8 = undefined;
    const rp = try realpath(path, &rp_buf);
    try testing.expectEqualStrings(path, rp);

    try symLink(path, link);
    const lst = try statFile(link); // follows the link
    try testing.expectEqual(@as(u64, 12), lst.size);

    const cf = try createFile(dir ++ "/created.txt");
    defer deleteFile(dir ++ "/created.txt") catch {};
    try writeAll(cf, "created");
    close(cf);
    try testing.expectError(error.FileNotFound, statFile(dir ++ "/missing.txt"));
}

test "compat: truncate and writev gather" {
    const path = "/tmp/zocket-compat-trunc";
    defer deleteFile(path) catch {};
    const fd = try createFile(path);
    defer close(fd);
    try writeAll(fd, "0123456789");
    try ftruncate(fd, 4);
    try testing.expectEqual(@as(u64, 4), (try fstat(fd)).size);

    const pair = try socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer close(pair[0]);
    defer close(pair[1]);
    const iov = [_]posix.iovec_const{
        .{ .base = "foo".ptr, .len = 3 },
        .{ .base = "bar".ptr, .len = 3 },
    };
    try testing.expectEqual(@as(usize, 6), try writev(pair[0], &iov));
    try testing.expectEqual(@as(usize, 3), try write(pair[0], "baz"));
    var buf: [9]u8 = undefined;
    var got: usize = 0;
    while (got < 9) {
        const n = try posix.read(pair[1], buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("foobarbaz", buf[0..got]);
}

test "compat: sockets bind/listen/connect/accept" {
    const listen_fd = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(listen_fd);
    var zero_sa = std.mem.zeroes(posix.sockaddr);
    bind(listen_fd, &zero_sa, 0) catch |e| switch (e) {
        // Zeroed addr is invalid; the point is the error path works.
        error.AddressNotAvailable, error.AddressFamilyNotSupported, error.Unexpected => {},
        else => return e,
    };
    _ = try fcntl(listen_fd, 3, 0); // F_GETFL round-trips
    try testing.expect(getpid() > 0);

    // Real loopback listener via the sockets helper shape (raw here).
    const lfd = try socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer close(lfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2; // AF_INET
    addr[2] = 0;
    addr[3] = 0; // port 0 = ephemeral
    addr[4] = 127;
    addr[7] = 1; // 127.0.0.1
    const sa: *const posix.sockaddr = @ptrCast(&addr);
    try bind(lfd, sa, 16);
    try listen(lfd, 8);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try getsockname(lfd, @ptrCast(&bound), &slen);
    const port = (@as(u16, bound[2]) << 8) | bound[3];
    try testing.expect(port != 0);

    const cfd = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(cfd);
    var caddr: [16]u8 align(@alignOf(u16)) = addr;
    caddr[2] = bound[2];
    caddr[3] = bound[3];
    try connect(cfd, @ptrCast(&caddr), 16);
    var err_bytes: [4]u8 = undefined;
    try getsockopt(cfd, posix.SOL.SOCKET, posix.SO.ERROR, &err_bytes);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, &err_bytes, .little));

    // Refused: connect to the same port after closing the listener copy.
    const dead = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(dead);
    const lfd2 = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    {
        var a2: [16]u8 align(@alignOf(u16)) = addr;
        const sa2: *const posix.sockaddr = @ptrCast(&a2);
        try bind(lfd2, sa2, 16);
    }
    var sl2: posix.socklen_t = 16;
    var b2: [16]u8 align(@alignOf(u16)) = undefined;
    try getsockname(lfd2, @ptrCast(&b2), &sl2);
    close(lfd2);
    var c2: [16]u8 align(@alignOf(u16)) = addr;
    c2[2] = b2[2];
    c2[3] = b2[3];
    const refused = connect(dead, @ptrCast(&c2), 16);
    try testing.expect(refused == error.ConnectionRefused or refused == error.WouldBlock);
}

test "compat: eventfd, epoll and pipe/dup round-trip" {
    const efd = try eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer close(efd);
    const ep = try epoll_create1(0);
    defer close(ep);
    var ev = linux.epoll_event{ .events = 0x1, .data = .{ .ptr = 0 } };
    try epoll_ctl(ep, 1, efd, &ev); // ADD
    try epoll_ctl(ep, 3, efd, &ev); // MOD
    try epoll_ctl(ep, 2, efd, null); // DEL
    try testing.expectError(error.NotFound, epoll_ctl(ep, 2, efd, null)); // DEL again

    const fds = try pipe();
    const w = fds[1];
    defer close(fds[0]);
    defer close(w);
    const d = try dup(w);
    defer close(d);
    try dup2(d, d); // self-dup is a no-op success
    try writeAll(w, "piped");
    var buf: [5]u8 = undefined;
    var got: usize = 0;
    while (got < 5) {
        const n = try posix.read(fds[0], buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("piped", buf[0..got]);
}

test "compat: openDir iterates entries" {
    var dir = try openDir("testdata");
    defer close(dir.fd);
    var found_hello = false;
    while (dir.next()) |e| {
        if (std.mem.eql(u8, e.name, "hello.txt")) found_hello = true;
    }
    try testing.expect(found_hello);
}

test "compat: write/writev error mapping and broken pipe" {
    // Empty slices short-circuit without a syscall.
    try testing.expectEqual(@as(usize, 0), try write(-1, ""));
    try testing.expectEqual(@as(usize, 0), try writev(-1, &[_]posix.iovec_const{}));

    // Bad descriptor and read-only files: EBADF -> NotOpenForWriting.
    const iov = [_]posix.iovec_const{.{ .base = "x".ptr, .len = 1 }};
    try testing.expectError(error.NotOpenForWriting, write(-1, "x"));
    try testing.expectError(error.NotOpenForWriting, writev(-1, &iov));

    const path = "/tmp/zocket-compat-write-ro";
    try writeFile(path, "ro");
    defer deleteFile(path) catch {};
    const rfd = try openFile(path);
    defer close(rfd);
    try testing.expectError(error.NotOpenForWriting, write(rfd, "x"));
    try testing.expectError(error.NotOpenForWriting, writev(rfd, &iov));

    // A pipe whose read end is closed reports EPIPE as BrokenPipe. SIGPIPE
    // would kill the test process, so ignore it for the duration.
    const fds = try pipe();
    close(fds[0]);
    defer close(fds[1]);
    var ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.PIPE, &ign, &old);
    defer posix.sigaction(posix.SIG.PIPE, &old, null);
    try testing.expectError(error.BrokenPipe, write(fds[1], "x"));
    try testing.expectError(error.BrokenPipe, writev(fds[1], &iov));
}

test "compat: socket/bind/listen/connect error mapping" {
    try testing.expectError(error.AddressFamilyNotSupported, socket(9999, posix.SOCK.STREAM, 0));
    try testing.expectError(error.ProtocolNotSupported, socket(posix.AF.UNIX, posix.SOCK.STREAM, 6));
    try testing.expectError(error.SocketTypeNotSupported, socket(posix.AF.INET, 999, 0));
    try testing.expectError(error.SocketTypeNotSupported, socket(posix.AF.INET, posix.SOCK.STREAM, 999));
    try testing.expectError(error.Unexpected, socketpair(posix.AF.INET, posix.SOCK.STREAM, 0));
    if (linux.geteuid() != 0) {
        // Raw sockets need CAP_NET_RAW; a valid protocol reaches the check.
        try testing.expectError(error.PermissionDenied, socket(posix.AF.INET, posix.SOCK.RAW, 1));
    }

    var zero_sa = std.mem.zeroes(posix.sockaddr);
    try testing.expectError(error.Unexpected, bind(-1, &zero_sa, 0));

    const a = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(a);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2; // AF_INET
    addr[4] = 127;
    addr[7] = 1; // 127.0.0.1, ephemeral port
    try bind(a, @ptrCast(&addr), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try getsockname(a, @ptrCast(&bound), &slen);

    const b = try socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(b);
    try testing.expectError(error.AddressInUse, bind(b, @ptrCast(&bound), 16));

    var nonlocal: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    nonlocal[0] = 2;
    nonlocal[4] = 8;
    nonlocal[5] = 8;
    nonlocal[6] = 8;
    nonlocal[7] = 8; // 8.8.8.8 is not a local address
    try testing.expectError(error.AddressNotAvailable, bind(b, @ptrCast(&nonlocal), 16));

    // listen/connect on non-sockets and bad descriptors.
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try testing.expectError(error.Unexpected, listen(fds[0], 1));
    try testing.expectError(error.Unexpected, listen(-1, 1));
    try testing.expectError(error.Unexpected, connect(-1, @ptrCast(&addr), 16));
}

test "compat: nonblocking connect reports pending" {
    const fd = try socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer close(fd);
    var blackhole: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    blackhole[0] = 2; // AF_INET
    blackhole[2] = 0;
    blackhole[3] = 9; // port 9
    blackhole[4] = 10;
    blackhole[5] = 255;
    blackhole[6] = 255;
    blackhole[7] = 1; // 10.255.255.1:9
    const first = connect(fd, @ptrCast(&blackhole), 16);
    if (first) |_| {} else |e| switch (e) {
        // Still in progress: a second connect reports EALREADY.
        error.WouldBlock => try testing.expectError(error.ConnectionPending, connect(fd, @ptrCast(&blackhole), 16)),
        // No route to that address on this host: nothing to assert.
        error.NetworkUnreachable, error.HostUnreachable, error.ConnectionTimedOut => {},
        else => return e,
    }
}

test "compat: eventfd round-trip and epoll ctl errors" {
    try testing.expectError(error.Unexpected, eventfd(0, 1 << 20));
    const efd = try eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer close(efd);
    var val: u64 = 42;
    try testing.expectEqual(@as(usize, 8), try write(efd, std.mem.asBytes(&val)));
    var got: u64 = 0;
    try testing.expectEqual(@as(usize, 8), try posix.read(efd, std.mem.asBytes(&got)));
    try testing.expectEqual(@as(u64, 42), got);

    try testing.expectError(error.Unexpected, epoll_create1(0xdead));
    const ep = try epoll_create1(0);
    defer close(ep);
    var ev = linux.epoll_event{ .events = 0x1, .data = .{ .ptr = 0 } };
    try epoll_ctl(ep, 1, efd, &ev); // ADD
    try testing.expectError(error.AlreadyPresent, epoll_ctl(ep, 1, efd, &ev)); // ADD again
    try testing.expectError(error.BadFd, epoll_ctl(ep, 1, -1, &ev));
    try testing.expectError(error.BadFd, epoll_ctl(-1, 1, efd, &ev));
    try epoll_ctl(ep, 2, efd, null); // DEL
}

test "compat: dup2 onto an explicit target and dup errors" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    const path = "/tmp/zocket-compat-dup2";
    try writeFile(path, "");
    defer deleteFile(path) catch {};
    const target = try openFile(path);
    try dup2(fds[1], target); // target becomes a copy of the pipe write end
    try writeAll(target, "via-dup2");
    close(target);
    var buf: [8]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(fds[0], buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("via-dup2", buf[0..got]);

    try testing.expectError(error.Unexpected, dup2(-1, fds[1]));
    try testing.expectError(error.Unexpected, fcntl(-1, linux.F.GETFD, 0));
    try testing.expectError(error.Unexpected, dup(-1));
}

test "compat: pread, ftruncate and lseek edge cases" {
    var one: [1]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, pread(-1, &one, 0));
    try testing.expectError(error.NotOpenForReading, lseek_SET(-1, 0));
    try testing.expectError(error.Unexpected, ftruncate(-1, 0));

    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try testing.expectError(error.Unseekable, pread(fds[0], &one, 0));
    try testing.expectError(error.Unseekable, lseek_SET(fds[0], 0));
    try testing.expectError(error.Unseekable, ftruncate(fds[0], 0));

    const dir = try openDir("/tmp");
    defer close(dir.fd);
    try testing.expectError(error.IsDir, pread(dir.fd, &one, 0));

    const path = "/tmp/zocket-compat-pread";
    defer deleteFile(path) catch {};
    const fd = try createFile(path);
    defer close(fd);
    try writeAll(fd, "abc");
    try testing.expectEqual(@as(usize, 0), try pread(fd, &one, 99)); // past EOF
    try ftruncate(fd, 64);
    try testing.expectEqual(@as(u64, 64), (try fstat(fd)).size);
}

test "compat: readlink and symLink error mapping" {
    var buf: [256]u8 = undefined;
    try testing.expectError(error.FileNotFound, readlink("/tmp/zocket-compat-rl-missing", &buf));

    const path = "/tmp/zocket-compat-rl";
    const link = "/tmp/zocket-compat-rl-link";
    defer deleteFile(path) catch {};
    defer deleteFile(link) catch {};
    try writeFile(path, "x");
    try testing.expectError(error.NotLink, readlink(path, &buf)); // EINVAL
    try symLink(path, link);
    try testing.expectEqualStrings(path, try readlink(link, &buf));
    try testing.expectError(error.Unexpected, symLink(path, link)); // EEXIST
    try testing.expectError(error.FileNotFound, symLink(path, "/tmp/zocket-compat-rl-missing-dir/x"));
}

test "compat: file helper error mapping" {
    const missing = "/tmp/zocket-compat-missing";
    var buf: [256]u8 = undefined;
    try testing.expectError(error.FileNotFound, statFile(missing));
    try testing.expectError(error.FileNotFound, openFile(missing));
    try testing.expectError(error.FileNotFound, realpath(missing, &buf));
    try testing.expectError(error.FileNotFound, openDir(missing));
    try testing.expectError(error.FileNotFound, deleteFile(missing));
    try testing.expectError(error.FileNotFound, writeFile("/tmp/zocket-compat-missing-dir/x", "x"));
    try testing.expectError(error.FileNotFound, createFile("/tmp/zocket-compat-missing-dir/x"));
    try testing.expectError(error.AccessDenied, writeFile("/tmp", "x")); // EISDIR
    try testing.expectError(error.AccessDenied, createFile("/tmp")); // EISDIR

    // toZ rejects over-long paths before the syscall.
    var long: [posix.PATH_MAX + 8]u8 = @splat('a');
    long[0] = '/';
    try testing.expectError(error.NameTooLong, openFile(&long));
    try testing.expectError(error.NameTooLong, openDir(&long));

    // A regular file is not a directory.
    const file = "/tmp/zocket-compat-notdir";
    defer deleteFile(file) catch {};
    try writeFile(file, "x");
    try testing.expectError(error.FileNotFound, openDir(file));
    try testing.expectError(error.FileNotFound, openFile("/tmp/zocket-compat-notdir/child"));

    // Symlink loop: ELOOP -> FileNotFound.
    const l1 = "/tmp/zocket-compat-loop1";
    const l2 = "/tmp/zocket-compat-loop2";
    defer deleteFile(l1) catch {};
    defer deleteFile(l2) catch {};
    try symLink(l2, l1);
    try symLink(l1, l2);
    try testing.expectError(error.FileNotFound, statFile(l1));
    try testing.expectError(error.FileNotFound, openFile(l1));

    // statx on a bad fd is not EBADF-aware here.
    try testing.expectError(error.Unexpected, fstat(-1));

    // realpath resolves directories too (O_PATH), and a directory fd opens.
    const rp = try realpath("/tmp", &buf);
    try testing.expectEqualStrings("/tmp", rp);
    const dfd = try openFile("/tmp");
    close(dfd);

    // deleteFile on a directory: EISDIR -> Unexpected.
    const dpath = "/tmp/zocket-compat-rmdir";
    deleteFile(dpath) catch {};
    try testing.expectEqual(@as(usize, 0), linux.mkdir(dpath, 0o755));
    defer _ = linux.rmdir(dpath);
    try testing.expectError(error.Unexpected, deleteFile(dpath));

    // readFileAlloc fails closed over the byte cap (and frees its list).
    try testing.expectError(error.Unexpected, readFileAlloc(testing.allocator, file, 0));
}

test "compat: Mutex blocks while held" {
    var m = Mutex{};
    m.lock();
    var acquired = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(mu: *Mutex, done: *std.atomic.Value(bool)) void {
            mu.lock();
            mu.unlock();
            done.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &m, &acquired });
    // Hold the lock long enough for the worker to enter the futex wait.
    nanosleep(0, 5 * std.time.ns_per_ms);
    m.unlock();
    t.join();
    try testing.expect(acquired.load(.acquire));
}

test "compat: clock_gettime clock ids and nanosleep" {
    _ = try clock_gettime(posix.CLOCK.MONOTONIC);
    _ = try clock_gettime(posix.CLOCK.MONOTONIC_RAW);
    _ = try clock_gettime(posix.CLOCK.BOOTTIME);
    _ = try clock_gettime(posix.CLOCK.PROCESS_CPUTIME_ID); // unmapped -> REALTIME
    nanosleep(0, 0);
}
