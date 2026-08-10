const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const connection = @import("connection.zig");
const sockets = @import("sockets.zig");

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 2048;

fn setNonBlock(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, F_GETFL, 0);
    _ = try posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
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
        posix.close(self.listener);
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