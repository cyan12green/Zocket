const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll = @import("epoll.zig");
const eventfd = @import("eventfd.zig");
const connection = @import("connection.zig");
const sockets = @import("sockets.zig");
const timer_wheel = @import("timer_wheel.zig");
const http_parser = @import("../http/parser.zig");
const http_response = @import("../http/response.zig");
const dsl_pipeline = @import("../dsl/pipeline.zig");
const runtime_server = @import("../runtime/server.zig");

const max_events = 1024;

/// Default connection idle timeout in seconds (Milestone 5). Zero disables
/// idle reaping.
pub const default_idle_timeout_seconds: u32 = 60;

/// Fallback HTTP request processor used when a reactor is created without an
/// explicit handler (e.g. in tests): the default echo-on-everything config.
const default_http_handler = runtime_server.Server.default();

/// Connection protocol handled by a reactor.
pub const Mode = enum {
    /// Raw byte echo (Milestone 1/2 semantics).
    echo,
    /// HTTP/1.1: parse requests, respond with the request body echoed.
    http,
};

const HttpSession = struct {
    parser: http_parser.Parser,
    req: http_parser.Request,
    /// A response is queued in the send buffer and the fd is armed for
    /// EPOLLOUT until it has been fully flushed.
    writing: bool = false,
    /// Close the connection once the current response has been flushed
    /// (errors, and requests that asked for Connection: close).
    close_after_write: bool = false,
    /// Stub-status accounting state (Milestone 13): which shared counter the
    /// connection currently contributes to.
    stat_state: enum { waiting, reading, writing } = .waiting,
};

/// A single-reactor worker: its own thread, its own epoll instance and its own
/// connection registry, wired for the echo protocol (identical semantics to the
/// Milestone 1 single-threaded server). Inbound connections are handed over
/// from any thread via `attach`, which queues the connection behind a mutex and
/// pokes the loop with an eventfd; the reactor thread then registers the fd and
/// owns it exclusively from that point on, so the connection map and all
/// epoll_ctl calls for a given fd are confined to this thread.
pub const Reactor = struct {
    allocator: std.mem.Allocator,
    id: usize,
    mode: Mode,
    ep: epoll.Epoll,
    wakeup: eventfd.EventFd,
    connections: std.AutoHashMap(posix.fd_t, *connection.Connection),
    http_sessions: std.AutoHashMap(posix.fd_t, HttpSession),
    /// Config-driven HTTP request processor (Milestone 4). Only used in `.http`
    /// mode; when null, `default_http_handler` is used. Shared read-only across
    /// reactors, so it is safe to call from the reactor thread.
    http_handler: ?*const runtime_server.Server,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    pending: std.ArrayList(*connection.Connection),
    pending_lock: std.Thread.Mutex,
    /// Total connections this reactor has registered, ever. Bumped on the
    /// reactor thread when a pending connection is added to the registry;
    /// monotonic, so tests can assert dispatch happened without racing
    /// connection reaping.
    registered: std.atomic.Value(usize),
    /// Idle timeout in wheel ticks (1 s each); zero disables idle reaping.
    idle_timeout_ticks: u64,
    /// Wall-clock epoch the timer ticks are measured from.
    epoch: std.time.Instant,
    /// Timer wheel advancing on every loop iteration; idle connections expire
    /// and close.
    wheel: timer_wheel.default_wheel,
    /// Connections the wheel expired in the current advance pass; drained
    /// after `advanceTo` returns (the wheel callback must not tear down
    /// objects whose entries are still linked).
    expired_fds: std.ArrayList(posix.fd_t),
    /// Shared connection/request counters (Milestone 13); null in echo mode.
    stats: ?*runtime_server.ServerStats = null,
    /// Graceful-drain mode (Milestone 13): stop accepting new connections
    /// and exit the loop once the connection map empties (or a timeout).
    draining: std.atomic.Value(bool) = .init(false),
    drained: std.atomic.Value(bool) = .init(false),
    drain_started: std.time.Instant = undefined,

    pub fn init(allocator: std.mem.Allocator, id: usize, mode: Mode) !Reactor {
        return initWithTimeout(allocator, id, mode, default_idle_timeout_seconds);
    }

    /// Like `init`, with an explicit idle timeout in seconds (zero disables).
    pub fn initWithTimeout(allocator: std.mem.Allocator, id: usize, mode: Mode, idle_timeout_seconds: u32) !Reactor {
        return initWithHandlerTimeout(allocator, id, mode, null, idle_timeout_seconds);
    }

    /// Like `init`, but with an explicit HTTP request processor (used in HTTP
    /// mode; ignored in echo mode).
    pub fn initWithHandler(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
    ) !Reactor {
        return initWithHandlerTimeout(allocator, id, mode, http_handler, default_idle_timeout_seconds);
    }

    /// Full constructor: HTTP handler + idle timeout in seconds (zero
    /// disables idle reaping).
    pub fn initWithHandlerTimeout(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
        idle_timeout_seconds: u32,
    ) !Reactor {
        var self = Reactor{
            .allocator = allocator,
            .id = id,
            .mode = mode,
            .ep = try epoll.Epoll.create(),
            .wakeup = try eventfd.EventFd.create(),
            .connections = std.AutoHashMap(posix.fd_t, *connection.Connection).init(allocator),
            .http_sessions = std.AutoHashMap(posix.fd_t, HttpSession).init(allocator),
            .http_handler = http_handler,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .pending = .empty,
            .pending_lock = .{},
            .registered = std.atomic.Value(usize).init(0),
            .idle_timeout_ticks = timer_wheel.default_wheel.tickForNs(@as(u64, idle_timeout_seconds) * std.time.ns_per_s),
            .epoch = std.time.Instant.now() catch std.time.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
            .wheel = .{},
            .expired_fds = .empty,
            .stats = if (mode == .http)
                @constCast((http_handler orelse &default_http_handler).stats)
            else
                null,
            .drain_started = std.time.Instant.now() catch std.time.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
        };
        errdefer self.ep.close();
        self.ep.add(self.wakeup.fd, epoll.Events.In, self.wakeup.fd) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.pending.deinit(self.allocator);
        };
        return self;
    }

    /// The reactor thread must have been stopped and joined before deinit.
    pub fn deinit(self: *Reactor) void {
        // Tear down connections while the epoll fd is still open: they deregister
        // via epoll_ctl DEL, which would EBADF-panic on a closed epoll fd.
        self.closeAllConnections();
        self.ep.close();
        self.wakeup.close();
        self.connections.deinit();
        self.http_sessions.deinit();
        self.pending.deinit(self.allocator);
        self.expired_fds.deinit(self.allocator);
    }

    pub fn start(self: *Reactor) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, reactorLoop, .{self});
    }

    /// Ask the reactor to stop; the loop exits after the next wakeup or
    /// epoll_wait timeout. Call `join` afterwards.
    pub fn stop(self: *Reactor) void {
        self.running.store(false, .release);
        self.wakeup.write();
    }

    pub fn join(self: *Reactor) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Graceful drain (Milestone 13): stop accepting new connections; the
    /// loop exits once every existing connection has finished (or after
    /// `drain_timeout_ns`). The reactor thread must be joined afterwards.
    pub fn drain(self: *Reactor) void {
        self.draining.store(true, .release);
        self.drain_started = std.time.Instant.now() catch std.time.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } };
        self.wakeup.write();
    }

    /// True once the reactor loop has exited after a drain (polled by the
    /// server to join and free drained reactors).
    pub fn isDrained(self: *const Reactor) bool {
        return self.drained.load(.acquire);
    }

    /// Hand a new connection to this reactor. Safe to call from any thread.
    /// Rejected (and closed) while the reactor is draining.
    pub fn attach(self: *Reactor, conn: *connection.Connection) void {
        if (self.draining.load(.acquire)) {
            conn.close();
            conn.destroy();
            return;
        }
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        self.pending.append(self.allocator, conn) catch {
            conn.close();
            conn.destroy();
            return;
        };
        self.wakeup.write();
    }

    pub fn countConnections(self: *const Reactor) usize {
        return self.connections.count();
    }

    const drain_timeout_ns = 30 * std.time.ns_per_s;

    fn reactorLoop(self: *Reactor) void {
        sockets.pinToCpu(self.id);
        var events: [max_events]linux.epoll_event = undefined;
        while (self.running.load(.acquire)) {
            if (self.draining.load(.acquire)) {
                if (self.connections.count() == 0) break;
                const now = std.time.Instant.now() catch break;
                if (now.since(self.drain_started) > drain_timeout_ns) break;
            }
            self.advanceTimers();
            const n = self.ep.wait(&events, 100) catch continue;
            for (events[0..n]) |ev| {
                self.handleEvent(ev.events, @intCast(ev.data.ptr));
            }
        }
        // Drain anything still queued so deinit can free it deterministically,
        // even if a connection arrived between the last wakeup and stop.
        self.wakeup.read();
        self.drainPending();
        self.drained.store(true, .release);
    }

    /// Advance the timer wheel to the current wall tick and close every
    /// connection that expired. One clock read and (usually) one empty slot
    /// walk per loop iteration.
    fn advanceTimers(self: *Reactor) void {
        if (self.idle_timeout_ticks == 0) return;
        const tick = self.nowTick();
        self.wheel.advanceTo(tick, self, onExpired);
        for (self.expired_fds.items) |fd| self.removeConnection(fd);
        self.expired_fds.clearRetainingCapacity();
    }

    /// Wall-clock time in wheel ticks (1 s granularity), relative to `epoch`.
    fn nowTick(self: *const Reactor) u64 {
        const now = std.time.Instant.now() catch return 0;
        return timer_wheel.default_wheel.tickForNs(now.since(self.epoch));
    }

    /// Timer wheel fired an entry: record its connection for teardown. Runs
    /// on the reactor thread inside `advanceTo`; only appends (the wheel may
    /// hold pointers to connections whose destruction must be deferred).
    fn onExpired(self: *Reactor, entry: *timer_wheel.TimerEntry) void {
        const conn: *connection.Connection = @fieldParentPtr("timer", entry);
        self.expired_fds.append(self.allocator, conn.fd) catch {};
    }

    /// Stub-status accounting: the session moved from reading to writing
    /// (a response has been queued).
    fn markWriting(self: *Reactor, fd: posix.fd_t) void {
        const stats = self.stats orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        if (session.stat_state == .reading) {
            session.stat_state = .writing;
            _ = stats.reading.fetchSub(1, .monotonic);
            _ = stats.writing.fetchAdd(1, .monotonic);
        }
    }

    /// (Re)arm the idle timer for `conn` at the current tick. Any recv is
    /// activity, so the timer is pushed back on every read.
    fn rearmTimer(self: *Reactor, conn: *connection.Connection) void {
        if (self.idle_timeout_ticks == 0) return;
        self.wheel.rearm(&conn.timer, self.nowTick(), self.idle_timeout_ticks);
    }

    fn handleEvent(self: *Reactor, events: u32, fd: posix.fd_t) void {
        if (fd == self.wakeup.fd) {
            self.wakeup.read();
            self.drainPending();
            return;
        }

        if (self.mode == .http) {
            self.handleHttpEvent(events, fd);
            return;
        }

        const conn = self.connections.get(fd) orelse return;

        if (events & (epoll.Events.Error | epoll.Events.Hangup) != 0) {
            self.removeConnection(fd);
            return;
        }

        if (events & epoll.Events.In != 0) {
            const n = conn.recv() catch |e| {
                // WouldBlock on an edge-triggered fd is a no-op, all other
                // errors tear the connection down.
                if (e != error.WouldBlock) self.removeConnection(fd);
                return;
            };
            if (n == 0) {
                self.removeConnection(fd);
                return;
            }
            self.rearmTimer(conn);
            self.onMessage(conn) catch {
                self.removeConnection(fd);
            };
        }

        if (events & epoll.Events.Out != 0) {
            if (conn.send_buf.availableRead() > 0) {
                _ = conn.send() catch {
                    self.removeConnection(fd);
                    return;
                };
            }
            if (conn.send_buf.availableRead() == 0) {
                self.ep.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd) catch {};
            }
        }
    }

    /// HTTP/1.1 event handling. The connection's read and write sides are
    /// independent: reads drain into recv_buf (edge-triggered, so everything
    /// available is consumed), requests are parsed and answered, and responses
    /// are queued in the send buffer and flushed on EPOLLOUT.
    fn handleHttpEvent(self: *Reactor, events: u32, fd: posix.fd_t) void {
        if (events & (epoll.Events.Error | epoll.Events.Hangup) != 0) {
            self.removeConnection(fd);
            return;
        }

        if (events & epoll.Events.In != 0) {
            const conn = self.connections.get(fd) orelse return;
            var got_data = false;
            while (true) {
                const n = conn.recv() catch |e| switch (e) {
                    error.WouldBlock => break,
                    // Buffer full: request cannot complete in memory; processHttp
                    // turns this into a 431.
                    error.BufferFull => break,
                    else => {
                        self.removeConnection(fd);
                        return;
                    },
                };
                if (n == 0) {
                    self.removeConnection(fd);
                    return;
                }
                got_data = true;
            }
            if (got_data) {
                self.rearmTimer(conn);
                if (self.stats) |s| {
                    const session = self.http_sessions.getPtr(fd) orelse return;
                    if (session.stat_state == .waiting) {
                        session.stat_state = .reading;
                        _ = s.waiting.fetchSub(1, .monotonic);
                        _ = s.reading.fetchAdd(1, .monotonic);
                    }
                }
            }
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (!session.writing) self.processHttp(fd);
        }

        if (events & epoll.Events.Out != 0) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (session.writing) self.flushHttp(fd);
        }
    }

    /// Parse and answer whatever is buffered. Runs until the buffer holds no
    /// complete request, a response is partially flushed (waiting for
    /// EPOLLOUT), or the connection is torn down. Called on the reactor thread
    /// only; every iteration re-fetches state because processing may remove
    /// the connection.
    fn processHttp(self: *Reactor, fd: posix.fd_t) void {
        while (true) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            const conn = self.connections.get(fd) orelse return;
            if (session.writing) return;

            const outcome = session.parser.parse(conn.recv_buf, &session.req);
            switch (outcome) {
                .incomplete => {
                    // The buffer can hold the whole request, so an incomplete
                    // parse with a full buffer can never finish: header flood
                    // or oversized body.
                    if (conn.recv_buf.availableWrite() == 0) {
                        self.respondAndClose(fd, .header_too_large);
                    }
                    return;
                },
                .bad_request => {
                    self.respondAndClose(fd, .bad_request);
                    return;
                },
                .header_too_large => {
                    self.respondAndClose(fd, .header_too_large);
                    return;
                },
                .unsupported => {
                    self.respondAndClose(fd, .not_implemented);
                    return;
                },
                .payload_too_large => {
                    self.respondAndClose(fd, .payload_too_large);
                    return;
                },
                .out_of_memory => {
                    self.respondAndClose(fd, .internal_error);
                    return;
                },
                .complete => {
                    var resp = http_response.Response.init(.ok);
                    var ctx = dsl_pipeline.Context{
                        .req = &session.req,
                        .resp = &resp,
                        .allocator = self.allocator,
                        .client_ip = if (self.connections.get(fd)) |c| c.peer_ip else .{ 0, 0, 0, 0 },
                        .stats = self.stats,
                    };
                    const handler = self.http_handler orelse &default_http_handler;

                    // Milestone 11 fast path: module-less response-template
                    // routes are written straight from their pre-serialised
                    // bytes (status line + template headers + Connection +
                    // Content-Length + body), byte-identical to the pipeline
                    // equivalent but with zero dispatch.
                    if (handler.matchFast(&ctx)) |fb| {
                        const close = !session.req.keep_alive;
                        conn.send_buf.compact();
                        _ = conn.send_buf.writeSlice(fb.head);
                        var hdr_buf: [96]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "Connection: {s}\r\nContent-Length: {d}\r\n\r\n", .{
                            if (close) "close" else "keep-alive",
                            fb.body.len, // HEAD keeps the would-be body length
                        }) catch unreachable;
                        _ = conn.send_buf.writeSlice(hdr);
                        if (session.req.method != .head) {
                            _ = conn.send_buf.writeSlice(fb.body);
                        }
                        session.close_after_write = close;
                        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
                        self.markWriting(fd);
                        session.writing = true;
                        self.flushHttp(fd);
                        if (!self.connections.contains(fd)) return;
                        const sess = self.http_sessions.getPtr(fd) orelse return;
                        if (!sess.writing) continue; // flushed fully; next pipelined request
                        self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
                        return;
                    }

                    const request_outcome = handler.handleRequest(&ctx) catch {
                        self.respondAndClose(fd, .internal_error);
                        return;
                    };
                    if (request_outcome == .not_handled) {
                        // No module claimed the request (no route matched, a
                        // short-circuit, or no module attached): default 404.
                        resp = http_response.Response.init(.not_found);
                        resp.setBody(http_response.Status.not_found.reasonPhrase());
                    }
                    const close = ctx.close_after_write or !session.req.keep_alive;
                    resp.setHeader("Connection", if (close) "close" else "keep-alive");
                    conn.send_buf.compact();
                    if (session.req.method == .head) {
                        // HEAD: status line + headers only (Content-Length
                        // reflects the would-be body).
                        resp.writeHeadToBuffer(conn.send_buf) catch {
                            if (resp.body_owned) self.allocator.free(resp.body);
                            self.removeConnection(fd);
                            return;
                        };
                    } else {
                        resp.writeToBuffer(conn.send_buf) catch {
                            if (resp.body_owned) self.allocator.free(resp.body);
                            self.removeConnection(fd);
                            return;
                        };
                    }
                    if (resp.body_owned) self.allocator.free(resp.body);
                    session.close_after_write = close;
                    if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
                    self.markWriting(fd);
                    session.writing = true;
                    self.flushHttp(fd);
                    if (!self.connections.contains(fd)) return;
                    const sess = self.http_sessions.getPtr(fd) orelse return;
                    if (!sess.writing) continue; // flushed fully; next pipelined request
                    // Partially flushed: re-arm EPOLLOUT (epoll_ctl MOD
                    // re-evaluates readiness, so this delivers the event).
                    self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
                    return;
                },
            }
        }
    }

    /// Write queued response bytes until the socket would block. When the send
    /// buffer is drained: close if requested, otherwise reset the session and
    /// immediately process any pipelined data already buffered.
    fn flushHttp(self: *Reactor, fd: posix.fd_t) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        while (conn.send_buf.availableRead() > 0) {
            const n = conn.send() catch |e| {
                if (e == error.WouldBlock) break;
                self.removeConnection(fd);
                return;
            };
            if (n == 0) break;
        }

        if (conn.send_buf.availableRead() > 0) {
            // Socket buffer full; the next EPOLLOUT edge (socket became
            // writable again) will continue the flush.
            return;
        }

        if (session.close_after_write) {
            // Discard unread receive data so close() sends FIN instead of RST
            // (the client may still be sending the request body).
            drainRecv(conn, 64 * 1024);
            self.removeConnection(fd);
            return;
        }

        session.writing = false;
        if (self.stats) |s| {
            if (session.stat_state == .writing) {
                session.stat_state = .waiting;
                _ = s.writing.fetchSub(1, .monotonic);
                _ = s.waiting.fetchAdd(1, .monotonic);
            }
        }
        session.parser.reset();
        session.req.reset();
        // Nothing to send: wait for the next request without spurious
        // EPOLLOUT edges.
        self.ep.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd) catch {};
        self.processHttp(fd);
    }

    /// Read and discard up to `max` bytes from the socket.
    fn drainRecv(conn: *connection.Connection, max: usize) void {
        var buf: [4096]u8 = undefined;
        var left = max;
        while (left > 0) {
            const n = posix.read(conn.fd, buf[0..@min(left, buf.len)]) catch break;
            if (n == 0) break;
            left -= n;
        }
    }

    /// Queue an error response and close the connection after it is flushed.
    fn respondAndClose(self: *Reactor, fd: posix.fd_t, status: http_response.Status) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        // Milestone 13: error-log line for errors the pipeline never sees
        // (parse failures). Pipeline-visible errors are logged by the
        // error_log module when bound.
        {
            const code = @intFromEnum(status);
            var ip_buf: [16]u8 = undefined;
            const ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ conn.peer_ip[0], conn.peer_ip[1], conn.peer_ip[2], conn.peer_ip[3] }) catch "-";
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} - -> {d} {s}\n", .{
                if (code >= 500) "error" else "warn",
                ip,
                code,
                status.reasonPhrase(),
            }) catch return;
            _ = std.posix.write(2, line) catch {};
        }

        var resp = http_response.Response.init(status);
        resp.setBody(status.reasonPhrase());
        resp.setHeader("Connection", "close");
        conn.send_buf.compact();
        resp.writeToBuffer(conn.send_buf) catch {
            self.removeConnection(fd);
            return;
        };
        session.close_after_write = true;
        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        self.markWriting(fd);
        session.writing = true;
        self.flushHttp(fd);
    }

    /// Echo semantics identical to the Milestone 1 server: whatever was read is
    /// copied into the send buffer and the fd is armed for writability.
    fn onMessage(self: *Reactor, conn: *connection.Connection) !void {
        const data = conn.recv_buf.peek();
        if (data.len > 0) {
            _ = conn.send_buf.writeSlice(data);
            conn.recv_buf.reset();
            try self.ep.modify(
                conn.fd,
                epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered,
                conn.fd,
            );
        }
    }

    /// Pop the queue of connections handed over from other threads and register
    /// them with this reactor's epoll and registry. Only runs on the reactor
    /// thread (via the wakeup or at loop exit), so the map has a single owner.
    ///
    /// The queue is *moved* out of the shared list under the lock rather than
    /// copied: a concurrent `attach` may reallocate the list's backing array
    /// (freeing the old one), so any slice captured earlier would be a
    /// use-after-free. `toOwnedSlice` transfers ownership of the allocation to
    /// this thread; the caller frees it.
    fn drainPending(self: *Reactor) void {
        self.pending_lock.lock();
        if (self.pending.items.len == 0) {
            self.pending_lock.unlock();
            return;
        }
        const items = self.pending.toOwnedSlice(self.allocator) catch {
            self.pending_lock.unlock();
            return;
        };
        self.pending_lock.unlock();
        defer self.allocator.free(items);

        for (items) |conn| {
            self.ep.add(conn.fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, conn.fd) catch {
                conn.close();
                conn.destroy();
                continue;
            };
            if (self.connections.put(conn.fd, conn)) |_| {
                _ = self.registered.fetchAdd(1, .monotonic);
            } else |_| {
                self.ep.remove(conn.fd) catch {};
                conn.close();
                conn.destroy();
                continue;
            }
            if (self.idle_timeout_ticks > 0) {
                self.wheel.insert(&conn.timer, self.nowTick(), self.idle_timeout_ticks);
            }
            if (self.stats) |s| {
                _ = s.active.fetchAdd(1, .monotonic);
                _ = s.waiting.fetchAdd(1, .monotonic);
            }
            if (self.mode == .http) {
                var session = HttpSession{
                    .parser = http_parser.Parser.init(self.allocator),
                    .req = http_parser.Request.init(self.allocator),
                };
                if (self.http_sessions.put(conn.fd, session)) |_| {
                } else |_| {
                    session.parser.deinit();
                    session.req.deinit();
                    self.wheel.remove(&conn.timer);
                    self.ep.remove(conn.fd) catch {};
                    conn.close();
                    conn.destroy();
                }
            }
        }
    }

    fn removeConnection(self: *Reactor, fd: posix.fd_t) void {
        if (self.connections.fetchRemove(fd)) |kv| {
            const conn = kv.value;
            // Unlink the idle timer so the wheel never points at freed memory.
            self.wheel.remove(&conn.timer);
            self.ep.remove(fd) catch {};
            conn.close();
            conn.destroy();
        }
        if (self.http_sessions.fetchRemove(fd)) |kv| {
            var sess = kv.value;
            if (self.stats) |s| {
                switch (sess.stat_state) {
                    .waiting => _ = s.waiting.fetchSub(1, .monotonic),
                    .reading => _ = s.reading.fetchSub(1, .monotonic),
                    .writing => _ = s.writing.fetchSub(1, .monotonic),
                }
                _ = s.active.fetchSub(1, .monotonic);
            }
            sess.parser.deinit();
            sess.req.deinit();
        }
    }

    fn closeAllConnections(self: *Reactor) void {
        self.drainPending();
        var it = self.connections.valueIterator();
        while (it.next()) |c| {
            const conn = c.*;
            self.wheel.remove(&conn.timer);
            self.ep.remove(conn.fd) catch {};
            conn.close();
            conn.destroy();
        }
        self.connections.clearRetainingCapacity();
        var sit = self.http_sessions.valueIterator();
        while (sit.next()) |s| {
            s.parser.deinit();
            s.req.deinit();
        }
        self.http_sessions.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn readUntil(sock: posix.fd_t, buf: []u8, expected_len: usize, timeout_ms: u64) !usize {
    var total: usize = 0;
    const start = std.time.Instant.now() catch return error.Timeout;
    while (total < expected_len) {
        if ((std.time.Instant.now() catch return error.Timeout).since(start) > timeout_ms * std.time.ns_per_ms) {
            return error.Timeout;
        }
        // Read at most the remaining need; the socket may deliver more (e.g.
        // the next pipelined response) and the leftover stays buffered.
        const n = posix.read(sock, buf[total..expected_len]) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return error.Eof;
        total += n;
    }
    return total;
}

fn writeAll(sock: posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = posix.write(sock, remaining) catch {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        remaining = remaining[n..];
    }
}

test "reactor startup and shutdown" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    // Explicit stop-then-join (LIFO defers would do this at scope exit; doing
    // it here keeps assertions below race-free).
    r.stop();
    r.join();
    try testing.expectEqual(@as(?std.Thread, null), r.thread);
    try testing.expectEqual(0, r.countConnections());
}

test "reactor echoes a connection attached from another thread" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn); // reactor takes ownership of conn incl. fd pair[1]

    const msg = "hello reactor echo";
    try writeAll(pair[0], msg);

    var buf: [64]u8 = undefined;
    const n = try readUntil(pair[0], &buf, msg.len, 3000);
    try testing.expectEqualStrings(msg, buf[0..n]);

    // Attach a second connection through the queue to make sure each pending
    // item is registered independently.
    const pair2 = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair2[0]);
    try sockets.setNonBlock(pair2[0]);
    try sockets.setNonBlock(pair2[1]);
    const conn2 = try connection.Connection.create(allocator, pair2[1]);
    r.attach(conn2);

    const msg2 = "second";
    try writeAll(pair2[0], msg2);
    var buf2: [16]u8 = undefined;
    const n2 = try readUntil(pair2[0], &buf2, msg2.len, 3000);
    try testing.expectEqualStrings(msg2, buf2[0..n2]);

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 2), r.countConnections());
}

test "reactor handles concurrent dispatch from many threads" {
    const allocator = std.heap.page_allocator; // client fds live across threads
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const producers = 8;
    const per_producer = 4;
    var handles: [producers]std.Thread = undefined;

    const Producer = struct {
        rid: *Reactor,
        alloc: std.mem.Allocator,
        failures: *std.atomic.Value(usize),

        fn run(p: *@This()) void {
            var i: usize = 0;
            while (i < per_producer) : (i += 1) {
                const pair = posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    return;
                };
                sockets.setNonBlock(pair[0]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                sockets.setNonBlock(pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                const conn = connection.Connection.create(p.alloc, pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    posix.close(pair[1]);
                    return;
                };
                p.rid.attach(conn);

                var payload_buf: [64]u8 = undefined;
                const payload = std.fmt.bufPrint(&payload_buf, "from producer {d}-{d}", .{ 0, i }) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    return;
                };
                writeAll(pair[0], payload) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    return;
                };
                var echo_buf: [96]u8 = undefined;
                _ = readUntil(pair[0], &echo_buf, payload.len, 5000) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    posix.close(pair[0]);
                    return;
                };
                posix.close(pair[0]);
            }
        }
    };

    var failures = std.atomic.Value(usize).init(0);
    var producers_array: [producers]Producer = undefined;
    for (0..producers) |i| {
        producers_array[i] = .{ .rid = &r, .alloc = allocator, .failures = &failures };
        handles[i] = try std.Thread.spawn(.{}, Producer.run, .{&producers_array[i]});
    }
    for (0..producers) |i| {
        handles[i].join();
    }

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    // Every connection was dispatched and registered by the reactor. Live
    // connection count can be lower (producers close their client ends right
    // after the echo, and the reactor reaps the HUP), so assert on the
    // monotonic registration counter instead.
    try testing.expectEqual(@as(usize, producers * per_producer), r.registered.load(.monotonic));
}

const http_ok_empty = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";

test "reactor serves HTTP with keep-alive and body echo" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Request 1: simple GET, keep-alive default.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n1]);

    // Request 2 on the same connection: POST, body echoed.
    try writeAll(pair[0], "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    const want2 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 5\r\n\r\nhello";
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // Request 3: Connection: close -> response then EOF.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    const want3 = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    const n3 = try readUntil(pair[0], &buf, want3.len, 3000);
    try testing.expectEqualStrings(want3, buf[0..n3]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}

test "reactor HTTP handles pipelined requests in one write" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(
        pair[0],
        "POST /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nA" ++
            "POST /b HTTP/1.1\r\nContent-Length: 1\r\n\r\nB",
    );
    var buf: [512]u8 = undefined;
    const want_a = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 1\r\n\r\nA";
    const want_b = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 1\r\n\r\nB";
    const n1 = try readUntil(pair[0], &buf, want_a.len, 3000);
    try testing.expectEqualStrings(want_a, buf[0..n1]);
    const n2 = try readUntil(pair[0], &buf, want_b.len, 3000);
    try testing.expectEqualStrings(want_b, buf[0..n2]);
}

test "reactor HTTP error paths respond and close" {
    const allocator = testing.allocator;
    const cases = [_]struct { wire: []const u8, want: []const u8 }{
        .{
            .wire = "BREW / HTTP/1.1\r\n\r\n",
            .want = "HTTP/1.1 501 Not Implemented\r\nConnection: close\r\nContent-Length: 15\r\n\r\nNot Implemented",
        },
        .{
            .wire = "GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n",
            .want = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 11\r\n\r\nBad Request",
        },
        .{
            .wire = "GET / HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
            .want = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 11\r\n\r\nBad Request",
        },
    };
    for (cases) |c| {
        var r = try Reactor.init(allocator, 0, .http);
        defer r.deinit();
        try r.start();
        defer r.join();
        defer r.stop();

        const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);

        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);

        try writeAll(pair[0], c.wire);
        var buf: [512]u8 = undefined;
        const n = try readUntil(pair[0], &buf, c.want.len, 3000);
        try testing.expectEqualStrings(c.want, buf[0..n]);
        // Error responses close the connection.
        try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));

        r.stop();
        r.join();
    }
}

test "reactor HTTP oversized body yields 413 and closes" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    const echo_mod = @import("../dsl/modules/echo.zig");
    var body = [_]u8{'x'} ** (echo_mod.max_echo_body + 1);
    var wire_buf: [echo_mod.max_echo_body + 256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try writeAll(pair[0], wire);
    // Body arrives in a second chunk to exercise the partial-body path.
    std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
    try writeAll(pair[0], &body);

    const want = "HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\nContent-Length: 17\r\n\r\nPayload Too Large";
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}

// A JSON config loaded at runtime, driving requests through the pipeline in a
// reactor: unmatched requests fall back to the default 404 (no module
// attached), matched ones go through the echo module.
test "reactor runs a JSON-config pipeline with default 404 fallback" {
    const allocator = testing.allocator;
    const json =
        \\{ "routes": [
        \\    { "path": "/only", "match": "exact", "modules": { "content": "echo" } }
        \\  ] }
    ;
    var cfg = try runtime_server.Config.fromJson(allocator, json);
    defer cfg.deinit(allocator);
    try cfg.validate(runtime_server.default_registry);
    const srv = runtime_server.Server.init(cfg);

    var r = try Reactor.initWithHandler(allocator, 0, .http, &srv);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Matched route: echo module answers with the request body.
    try writeAll(pair[0], "POST /only HTTP/1.1\r\nContent-Length: 4\r\n\r\necho");
    var buf: [512]u8 = undefined;
    const want_echo = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 4\r\n\r\necho";
    const n1 = try readUntil(pair[0], &buf, want_echo.len, 3000);
    try testing.expectEqualStrings(want_echo, buf[0..n1]);

    // No route matches: default 404, connection stays alive.
    try writeAll(pair[0], "GET /elsewhere HTTP/1.1\r\n\r\n");
    const want_404 = "HTTP/1.1 404 Not Found\r\nConnection: keep-alive\r\nContent-Length: 9\r\n\r\nNot Found";
    const n2 = try readUntil(pair[0], &buf, want_404.len, 3000);
    try testing.expectEqualStrings(want_404, buf[0..n2]);

    r.stop();
    r.join();
}


test "reactor HEAD responds with head only and correct Content-Length" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // HEAD on a path the echo module answers with an empty body.
    try writeAll(pair[0], "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    const want = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    // HEAD on a POST-shaped path: Content-Length must reflect the would-be
    // body, but no body bytes may follow the head.
    try writeAll(pair[0], "HEAD /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    const want2 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 5\r\n\r\n";
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);
    // The echoed body must NOT be sent: a short read window yields nothing.
    try testing.expectError(error.Timeout, readUntil(pair[0], &buf, 1, 500));

    r.stop();
    r.join();
}

// M11: a module-less response-template route is served from pre-serialised
// bytes, byte-identical to the pipeline equivalent.
test "reactor serves a comptime template route from pre-serialised bytes" {
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config{
        .routes = &.{
            .{
                .path = "/health",
                .match = .exact,
                .response = .{ .status = 200, .body = "ok" },
            },
            .{
                .path = "/old",
                .match = .exact,
                .response = .{ .status = 301, .headers = &.{.{ .name = "Location", .value = "/health" }} },
            },
        },
    };
    const srv = runtime_server.Server.comptimeInit(cfg);
    var r = try Reactor.initWithHandler(allocator, 0, .http, &srv);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const want = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok";
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    // Redirect template with a header.
    try writeAll(pair[0], "GET /old HTTP/1.1\r\nHost: x\r\n\r\n");
    const want2 = "HTTP/1.1 301 Moved Permanently\r\nLocation: /health\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // A pipelined request after the fast-path responses keeps the connection.
    try writeAll(pair[0], "GET /health HTTP/1.1\r\nHost: x\r\n\r\n" ++ "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    const n3 = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n3]);
    const n4 = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n4]);

    r.stop();
    r.join();
}

test "reactor serves a chunked request end to end" {
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0],
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    var buf: [512]u8 = undefined;
    const want = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 11\r\n\r\nhello world";
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    r.stop();
    r.join();
}

// M5: idle timeout. A 1 s timeout is used so the tests finish quickly; the
// wheel's tick granularity is 100 ms, so deadlines land within ~100 ms of the
// nominal second (the loop re-advances the wheel before every epoll_wait,
// timeout 100 ms). Sleeps below leave generous margins on both sides of every
// deadline.
test "reactor closes a connection that goes idle" {
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 1);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // No traffic at all: the reactor expires the connection ~1 s after it was
    // registered. EOF (error.Eof) proves the close; Timeout would mean the
    // timer never fired.
    std.posix.nanosleep(2, 0);
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 1000));

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), r.countConnections());
}

test "reactor resets the idle timer on active traffic" {
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 1);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Request 1: arms the timer with a ~1 s deadline.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n1]);

    // Request 2 just before the deadline: pushes the deadline to ~1.5 s.
    std.posix.nanosleep(0, 500 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    const n2 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n2]);

    // Request 3 *after* the original ~1 s deadline: answered, which proves the
    // timer was re-armed (without rearming the connection would already be
    // closed and this write would fail).
    std.posix.nanosleep(0, 600 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    const n3 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n3]);

    // Idle again past the re-armed deadline (~2.5 s): now it does expire.
    std.posix.nanosleep(2, 0);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 1000));

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), r.countConnections());
}

test "idle timeout of zero disables reaping" {
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 0);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Well past any plausible 1 s window: the connection must still be alive.
    std.posix.nanosleep(2, 0);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, http_ok_empty.len, 3000);
    try testing.expectEqualStrings(http_ok_empty, buf[0..n1]);

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 1), r.countConnections());
}