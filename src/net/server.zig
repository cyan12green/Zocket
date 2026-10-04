const std = @import("std");
const compat = @import("../compat.zig");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const connection = @import("connection.zig");
const sockets = @import("sockets.zig");

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 2048;

fn setNonBlock(fd: posix.fd_t) !void {
    const flags = try compat.fcntl(fd, F_GETFL, 0);
    _ = try compat.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    epoll: epoll.Epoll,
    listener: posix.fd_t,
    connections: std.AutoHashMap(posix.fd_t, *connection.Connection),
    max_connections: usize,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const listener = try sockets.createListeningSocket(port, 4096);

        const ep = try epoll.Epoll.create();

        var server = Server{
            .allocator = allocator,
            .epoll = ep,
            .listener = listener,
            .connections = std.AutoHashMap(posix.fd_t, *connection.Connection).init(allocator),
            .max_connections = 65536,
            .running = false,
        };

        try server.epoll.add(listener, epoll.Events.In | epoll.Events.EdgeTriggered, listener);

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.running = false;
        self.epoll.close();
        compat.close(self.listener);
        var iter = self.connections.valueIterator();
        while (iter.next()) |conn| {
            conn.*.destroy();
        }
        self.connections.deinit();
    }

    pub fn accept(self: *Server) !?*connection.Connection {
        // posix.accept is unusable in this Zig snapshot (errno-set mismatch in
        // stdlib); sockets.acceptNonBlock uses the raw accept4 syscall.
        const conn_fd = sockets.acceptNonBlock(self.listener) catch |e| {
            if (e == error.WouldBlock) return null;
            return e;
        };

        try setNonBlock(conn_fd);

        const conn = try connection.Connection.create(self.allocator, conn_fd);
        try self.connections.put(conn_fd, conn);

        try self.epoll.add(
            conn_fd,
            epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered,
            conn_fd,
        );

        return conn;
    }

    pub fn handleEvent(self: *Server, events: u32, fd: posix.fd_t) !void {
        if (fd == self.listener) {
            if (events & epoll.Events.In != 0) {
                while (true) {
                    if (try self.accept() == null) break;
                }
            }
            return;
        }

        const conn = self.connections.get(fd) orelse return;

        if (events & (epoll.Events.Error | epoll.Events.Hangup) != 0) {
            self.removeConnection(fd);
            return;
        }

        if (events & epoll.Events.In != 0) {
            const n = try conn.recv();
            if (n == 0) {
                self.removeConnection(fd);
                return;
            }
            try self.onMessage(conn);
        }

        if (events & epoll.Events.Out != 0) {
            if (conn.send_buf.availableRead() > 0) {
                _ = try conn.send();
            }
            if (conn.send_buf.availableRead() == 0) {
                try self.epoll.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd);
            }
        }
    }

    pub fn onMessage(self: *Server, conn: *connection.Connection) !void {
        const data = conn.recv_buf.peek();
        if (data.len > 0) {
            _ = conn.send_buf.writeSlice(data);
            conn.recv_buf.reset();

            try self.epoll.modify(
                conn.fd,
                epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered,
                conn.fd,
            );
        }
    }

    fn removeConnection(self: *Server, fd: posix.fd_t) void {
        if (self.connections.fetchRemove(fd)) |kv| {
            const conn = kv.value;
            conn.close();
            conn.destroy();
        }
    }

    pub fn run(self: *Server) !void {
        self.running = true;
        const max_events = 1024;
        var events: [max_events]linux.epoll_event = undefined;

        while (self.running) {
            const n = try self.epoll.wait(&events, 100);

            for (events[0..n]) |event| {
                try self.handleEvent(event.events, @intCast(event.data.ptr));
            }
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};

const testing = std.testing;

test "single-threaded server echoes bytes on an ephemeral port" {
    var srv = try Server.init(testing.allocator, 0);
    defer srv.deinit();
    const port = try sockets.boundPort(srv.listener);
    try testing.expect(port != 0);

    const Runner = struct {
        fn run(s: *Server) void {
            s.run() catch {};
        }
    };
    const thr = try std.Thread.spawn(.{}, Runner.run, .{&srv});

    const cfd = try compat.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer compat.close(cfd);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2; // AF_INET
    addr[2] = @intCast(port >> 8);
    addr[3] = @intCast(port & 0xff);
    addr[4] = 127;
    addr[7] = 1;
    try compat.connect(cfd, @ptrCast(&addr), 16);
    try compat.writeAll(cfd, "ping-echo");

    var buf: [9]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(cfd, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("ping-echo", buf[0..got]);

    srv.stop();
    thr.join();
}
