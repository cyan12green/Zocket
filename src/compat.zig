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
