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
const static_cache_mod = @import("../dsl/static_cache.zig");
const cache_mod = @import("../dsl/modules/cache.zig");
const iouring_mod = @import("iouring.zig");
const limits_mod = @import("../dsl/limits.zig");
const version_mod = @import("../version.zig");
const http2_session = @import("../http2/session.zig");
const tls_conn = @import("../tls/conn.zig");
const buffer_mod = @import("buffer.zig");
const http2_frames = @import("../http2/frames.zig");
const websocket_mod = @import("../http/websocket.zig");

/// I/O backend selection. Default: epoll (measured at parity with the ring
/// on the keep-alive workloads and more robust at high connection counts).
/// Set to false (--uring) to try the io_uring batch path at init and use
/// it when available.
pub var force_epoll: bool = true;
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
    /// HTTP/2 session (Milestone 16), created lazily when the connection
    /// preface is detected (or negotiated over TLS via ALPN). When non-null
    /// the connection is in HTTP/2 mode and `parser`/`req` are unused.
    h2: ?http2_session.Session = null,
    /// TLS 1.3 session (M18): created lazily when the first record looks
    /// like a ClientHello. When non-null the recv buffer holds ciphertext;
    /// the plaintext lands in `tls_plain` and the parser reads from there.
    tls: ?tls_conn.TlsConn = null,
    /// Decrypted plaintext for the HTTP parser (TLS connections only).
    tls_plain: buffer_mod.Buffer = undefined,
    tls_plain_data: [16 * 1024]u8 = undefined,
    /// Staging for takeOut/takePlaintext and the serialized response head.
    tls_scratch: [16 * 1024 + 64]u8 = undefined,
    /// Response head staging for TLS serialization.
    tls_stage: buffer_mod.Buffer = undefined,
    tls_stage_data: [16 * 1024]u8 = undefined,
    /// Reusable h2 output-buffer scratch (kept across processHttp2 calls so
    /// response frames never reallocate per request).
    h2_out: std.ArrayList(u8) = .empty,
    /// A response is queued in the send buffer and the fd is armed for
    /// EPOLLOUT until it has been fully flushed.
    writing: bool = false,
    /// Whether EPOLLOUT is currently in the connection's epoll mask. Starts
    /// true (connections are registered with In|Out|ET) and is cleared after
    /// a full flush; used to skip the redundant In|Out -> In epoll_ctl when a
    /// response flushed synchronously without ever arming EPOLLOUT.
    out_armed: bool = true,
    /// Close the connection once the current response has been flushed
    /// (errors, and requests that asked for Connection: close).
    close_after_write: bool = false,
    /// Stub-status accounting state (Milestone 13): which shared counter the
    /// connection currently contributes to.
    stat_state: enum { waiting, reading, writing } = .waiting,
    /// sendfile state (Milestone 14): while `file_remaining > 0` the body is
    /// pushed from this fd into the socket.
    file_fd: posix.fd_t = -1,
    /// The fd is owned by the reactor's static cache (nginx open_file_cache
    /// equivalent): do not close it after sendfile.
    file_fd_cached: bool = false,
    file_offset: u64 = 0,
    file_remaining: u64 = 0,
    /// The response currently being flushed: its scratch and header/body
    /// slices must outlive the flush (kept here instead of on the
    /// processHttp stack).
    resp: http_response.Response = http_response.Response.init(.ok),
    /// The response body waiting to be sent (writev body slice; the head
    /// lives in the send buffer). Empty once fully flushed.
    pending_body: []const u8 = &.{},
    /// Whether the response body is a slice that must be freed once fully
    /// sent (module-allocated).
    pending_body_owned: bool = false,
    /// Chunked framing (route config `chunked: true`): the chunk terminator
    /// written by the head serializer into `tail_scratch`, sent after the
    /// body (or after the sendfile body, or alone for an empty body).
    pending_tail: []const u8 = &.{},
    tail_scratch: [8]u8 = undefined,
    /// The iovec array of the in-flight ring write (io_uring references it
    /// until the op is processed, so it must outlive flushHttp's stack).
    write_iovs: [3]posix.iovec_const = undefined,
    write_iov_count: usize = 0,
    /// M18: true once a 101 Switching Protocols handshake has been sent and
    /// the connection left HTTP behind (websocket byte-pipe mode).
    upgraded: bool = false,
    /// Scratch for the 101 handshake head (upgradeConnection); 160 covers
    /// the websocket head with digest plus slack.
    upgrade_head_scratch: [160]u8 = undefined,
};

/// A single-reactor worker: its own thread, its own epoll instance and its own
/// connection registry, wired for the echo protocol (identical semantics to the
/// Milestone 1 single-threaded server). Inbound connections are handed over
/// from any thread via `attach`, which queues the connection behind a mutex and
/// pokes the loop with an eventfd; the reactor thread then registers the fd and
/// owns it exclusively from that point on, so the connection map and all
/// epoll_ctl calls for a given fd are confined to this thread.
pub const Reactor = struct {
    /// Re-entrancy guard for the TLS processing path: flushHttp's recursion
    /// (finalizeFlush → processHttp) re-enters processHttpTls while the
    /// outer call is mid-accounting (plaintext not yet advanced); the
    /// recursion must not re-process it.
    tls_processing: bool = false,
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
    /// Static-file fd cache (nginx open_file_cache equivalent, Milestone 14
    /// follow-up): per-reactor, no locks. Served from it, a cached file
    /// costs zero open/stat/close syscalls and zero ETag/date formatting.
    static_cache: static_cache_mod.StaticCache = undefined,
    /// Connection pool (Milestone 14 follow-up): accepts recycle pooled
    /// connections, so steady-state connection churn costs zero allocations.
    conn_pool: connection.ConnectionPool = undefined,
    /// I/O backend: io_uring (reads/writes batched on the ring, no EAGAIN
    /// drain probe, no EPOLLOUT arming) or the classic epoll path. The ring
    /// is tried at init and falls back to epoll when unavailable (sandboxes,
    /// old kernels).
    io_mode: enum { epoll, ring } = .epoll,
    ring: iouring_mod.IoRing = .{},
    /// Connections whose read must be (re)submitted to the ring: appended by
    /// completions and new registrations, drained by ringSubmitReads every
    /// loop iteration. Fds whose submit failed (SQ full) stay in the list
    /// for the next iteration, so reads are never lost.
    resubmit_reads: [8192]posix.fd_t = undefined,
    resubmit_count: usize = 0,
    /// Cached Date header (nginx ngx_cached_http_time equivalent): the
    /// IMF-fixdate string is formatted once per wall-clock second and
    /// copied into every response, so per-request date formatting is zero.
    date_cache: [40]u8 = undefined,
    /// Runtime-tunable limits from the config `limits` section (buffers,
    /// parser caps, caches, pool). Applied at init; the compiled defaults
    /// apply when no config sets them.
    limits: limits_mod.Limits = .{},
    date_len: usize = 0,
    date_sec: u64 = 0,
    /// Per-reactor listener (Milestone 14, SO_REUSEPORT): when set, this
    /// reactor accepts connections directly from the kernel; -1 otherwise.
    listener: posix.fd_t = -1,
    /// Total accepted counter shared with the server (bumped per accept).
    accepted_counter: ?*std.atomic.Value(usize) = null,
    /// Graceful-drain mode (Milestone 13): stop accepting new connections
    /// and exit the loop once the connection map empties (or a timeout).
    draining: std.atomic.Value(bool) = .init(false),
    drained: std.atomic.Value(bool) = .init(false),
    drain_started: std.time.Instant = undefined,
    /// Set by `drain`: the listener should be closed as soon as the current
    /// epoll batch finishes (see `closeListenerIfRequested`).
    listener_close_requested: std.atomic.Value(bool) = .init(false),

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

    /// Like `initWithHandlerTimeout`, with a per-reactor listener
    /// (SO_REUSEPORT accept path, Milestone 14).
    pub fn initWithHandlerListener(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
        idle_timeout_seconds: u32,
        listener: posix.fd_t,
    ) !Reactor {
        var self = try initWithHandlerTimeout(allocator, id, mode, http_handler, idle_timeout_seconds);
        self.listener = listener;
        self.ep.add(listener, epoll.Events.In | epoll.Events.EdgeTriggered, listener) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.pending.deinit(self.allocator);
            self.expired_fds.deinit(self.allocator);
            return error.ListenerRegisterFailed;
        };
        return self;
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
            .static_cache = undefined,
            .conn_pool = undefined,
            .drain_started = std.time.Instant.now() catch std.time.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
        };
        // Apply the config `limits` to the per-reactor caches and pool.
        self.limits = (http_handler orelse &default_http_handler).cfg.limits;
        self.static_cache = static_cache_mod.StaticCache.initWithConfig(
            allocator,
            self.limits.static_cache_entries,
            self.limits.static_cache_valid_seconds,
            self.limits.static_content_cache_max,
        );
        self.conn_pool = connection.ConnectionPool.initWithConfig(
            allocator,
            self.limits.connection_pool_max,
            self.limits.recv_buffer_size,
            self.limits.send_buffer_size,
            self.limits.max_body,
        );

        errdefer self.ep.close();
        self.ep.add(self.wakeup.fd, epoll.Events.In, self.wakeup.fd) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.pending.deinit(self.allocator);
        };
        // Try io_uring; the epoll path remains when it is unavailable.
        // The ring fd is epoll-registered (level-triggered): it is readable
        // whenever completions are ready, so the loop structure is shared.
        if (!force_epoll) {
            self.ring = iouring_mod.IoRing.init() catch .{};
            if (self.ring.inited) {
                if (self.ep.add(self.ring.ringFd(), epoll.Events.In, self.ring.ringFd())) |_| {
                    self.io_mode = .ring;
                } else |_| {
                    self.ring.deinit();
                    self.ring = .{};
                }
            }
        }
        if (self.listener >= 0) {
            self.ep.add(self.listener, epoll.Events.In | epoll.Events.EdgeTriggered, self.listener) catch {
                self.ep.close();
                self.wakeup.close();
                self.connections.deinit();
                self.http_sessions.deinit();
                self.pending.deinit(self.allocator);
                return error.ListenerRegisterFailed;
            };
        }
        return self;
    }

    /// The reactor thread must have been stopped and joined before deinit.
    pub fn deinit(self: *Reactor) void {
        // Tear down connections while the epoll fd is still open: they deregister
        // via epoll_ctl DEL, which would EBADF-panic on a closed epoll fd.
        self.closeAllConnections();
        if (self.listener >= 0) posix.close(self.listener);
        self.static_cache.deinit();
        self.conn_pool.deinit();
        self.ring.deinit();
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
        // Graceful handoff (daemon swap, reload): stop routing new
        // connections to this reactor by closing its SO_REUSEPORT listener,
        // so the kernel delivers them to sibling listeners (the new
        // process). Deferred to after the current epoll batch: the listener
        // may be mid-event, and closing it inside the batch could let a
        // later stale event accept from a closed fd.
        self.listener_close_requested.store(true, .release);
        self.wakeup.write();
    }

    /// Close the listener if drain requested it. Called once per loop
    /// iteration and after the loop exits (drain may have been requested
    /// while the loop was in epoll_wait).
    fn closeListenerIfRequested(self: *Reactor) void {
        if (self.listener >= 0 and self.listener_close_requested.swap(false, .release)) {
            posix.close(self.listener);
            self.listener = -1;
        }
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
            self.closeListenerIfRequested();
            if (self.draining.load(.acquire)) {
                if (self.connections.count() == 0) break;
                const now = std.time.Instant.now() catch break;
                if (now.since(self.drain_started) > drain_timeout_ns) break;
            }
            self.advanceTimers();
            const n = self.ep.wait(&events, 100) catch continue;
            // Refresh the cached Date after the wait: a request that just
            // woke the loop is handled with a fresh second (stale by the µs
            // of batch processing), instead of up to a second + the wait
            // timeout if the refresh ran before the wait. (nginx refreshes
            // its cached time once per event cycle too; ours is per batch.)
            self.refreshDate();
            for (events[0..n]) |ev| {
                self.handleEvent(ev.events, @intCast(ev.data.ptr));
            }
        }
        // Drain anything still queued so deinit can free it deterministically,
        // even if a connection arrived between the last wakeup and stop.
        self.wakeup.read();
        self.drainPending();
        self.closeListenerIfRequested();
        self.drained.store(true, .release);
    }

    /// Refresh the cached Date string when the wall-clock second changes.
    fn refreshDate(self: *Reactor) void {
        const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch return;
        const now: u64 = @intCast(ts.sec);
        if (now == self.date_sec) return;
        self.date_sec = now;
        const date = cache_mod.formatHttpDate(now, &self.date_cache) orelse return;
        self.date_len = date.len;
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
    /// activity, so the timer is pushed back on every read; the rearm is
    /// skipped when the entry is already armed at this tick (back-to-back
    /// requests inside one 100 ms wheel tick cost nothing).
    fn rearmTimer(self: *Reactor, conn: *connection.Connection) void {
        if (self.idle_timeout_ticks == 0) return;
        const tick = self.nowTick();
        if (conn.timer.active and tick == conn.timer_last_tick) return;
        conn.timer_last_tick = tick;
        self.wheel.rearm(&conn.timer, tick, self.idle_timeout_ticks);
    }

    fn handleEvent(self: *Reactor, events: u32, fd: posix.fd_t) void {
        if (fd == self.wakeup.fd) {
            self.wakeup.read();
            self.drainPending();
            return;
        }
        if (fd == self.listener) {
            if (events & epoll.Events.In != 0) self.acceptConnections();
            return;
        }
        if (self.io_mode == .ring and fd == self.ring.ringFd()) {
            self.handleRingCompletions();
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
            if (!session.writing or session.h2 != null) self.processHttp(fd);
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
            // HTTP/1 stops parsing while a response is being flushed (the
            // pipelined request bytes stay buffered); HTTP/2 and TLS must
            // keep reading while writing (h2 control frames; the TLS
            // handshake's client Finished arrives while the flight flushes).
            if (session.writing and session.h2 == null and
                (session.tls == null or session.tls.?.stage() == .application)) return;

            // M18: upgraded connections left HTTP behind — their bytes are
            // websocket frames now.
            if (session.upgraded) {
                self.processWebsocket(fd);
                return;
            }

            // TLS detection (M18): a connection whose first record is a
            // ClientHello (handshake record type 22, legacy version 3.x,
            // handshake type 1) switches to the TLS 1.3 session.
            if (session.tls == null and session.h2 == null) {
                const recv_slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
                if (recv_slice.len >= 6 and recv_slice[0] == 0x16 and recv_slice[1] == 0x03 and recv_slice[5] == 0x01) {
                    if (self.http_handler) |handler| {
                        if (handler.tls_creds) |*creds| {
                            session.tls = tls_conn.TlsConn.init(creds);
                            session.tls_plain = buffer_mod.Buffer.fromSlice(&session.tls_plain_data);
                            session.tls_stage = buffer_mod.Buffer.fromSlice(&session.tls_stage_data);
                        }
                    }
                }
            }
            if (session.tls != null) {
                self.processHttpTls(fd, &session.tls.?);
                return;
            }

            // HTTP/2 detection (h2c prior knowledge, RFC 9113 §3.4): a
            // connection whose first bytes are the client preface switches to
            // the HTTP/2 session permanently.
            if (session.h2 == null) {
                const recv_slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
                if (recv_slice.len >= 24 and http2_session.Session.looksLikeHttp2Preface(recv_slice[0..24])) {
                    session.h2 = http2_session.Session.init(self.allocator);
                    if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
                }
            }
            if (session.h2) |*h2s| {
                self.processHttp2(fd, h2s);
                return;
            }

            const outcome = session.parser.parse(&conn.recv_buf, &session.req);
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
                    // M18: connection upgrade (RFC 6455 §4.2 and friends): on
                    // `Connection: upgrade` + `Upgrade: <proto>` reply
                    // 101 Switching Protocols and hand the connection over —
                    // HTTP parsing stops and the session becomes a byte pipe
                    // driven by the websocket framing path.
                    var wants_upgrade = false;
                    var upgrade_proto: []const u8 = "";
                    var ws_key: []const u8 = "";
                    for (session.req.slots[0..session.req.header_count]) |slot| {
                        switch (slot.tag) {
                            .upgrade => upgrade_proto = slot.value,
                            .sec_websocket_key => ws_key = slot.value,
                            .connection => {
                                if (std.ascii.indexOfIgnoreCase(slot.value, "upgrade") != null) {
                                    wants_upgrade = true;
                                }
                            },
                            else => {},
                        }
                    }
                    // RFC 6455 §4.2.1: only a GET asking for version 13 may
                    // switch protocols; anything else is handled as plain HTTP.
                    const ws_version_ok = blk: {
                        const v = session.req.header("sec-websocket-version") orelse break :blk false;
                        break :blk std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "13");
                    };
                    if (wants_upgrade and !session.upgraded and
                        session.req.method == .get and ws_version_ok)
                    {
                        self.upgradeConnection(fd, upgrade_proto, ws_key);
                        return;
                    }
                    if (self.handleHttpRequest(fd, false)) continue;
                    return;
                },
            }
        }
    }

    /// Send the 101 Switching Protocols handshake and flip the session into
    /// upgraded (byte-pipe) mode. `ws_key` is the client's Sec-WebSocket-Key;
    /// when the protocol is websocket the RFC 6455 §4.2.2 Sec-WebSocket-Accept
    /// digest is appended so real ws clients accept the handshake.
    fn upgradeConnection(self: *Reactor, fd: posix.fd_t, proto: []const u8, ws_key: []const u8) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        const head = websocket_mod.upgradeHead(proto, ws_key, &session.upgrade_head_scratch) orelse {
            self.removeConnection(fd);
            return;
        };
        conn.send_buf.compact();
        _ = conn.send_buf.writeSlice(head);
        session.close_after_write = false;
        session.writing = true;
        session.upgraded = true;
        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        self.markWriting(fd);
        self.flushHttp(fd);
    }

    /// Post-101 traffic: parse RFC 6455 frames straight out of the receive
    /// buffer (no HTTP parsing anymore) and answer them. Text/binary frames
    /// echo back unmasked, ping gets pong, close gets a close echo and ends
    /// the connection.
    fn processWebsocket(self: *Reactor, fd: posix.fd_t) void {
        while (true) {
            // Re-fetched every frame: answering one may flush synchronously
            // and tear the connection down (close frames), so nothing may be
            // held across an iteration.
            const conn = self.connections.get(fd) orelse return;
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (session.writing) return; // flush first; bytes stay buffered
            if (conn.recv_buf.availableRead() == 0) return;
            var frame = websocket_mod.Frame{};
            switch (websocket_mod.decode(conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos], &frame)) {
                .incomplete => return,
                .malformed => {
                    self.removeConnection(fd);
                    return;
                },
                .ok => {},
            }
            // Consume the whole frame up front: everything below either borrows
            // the payload slice or drops it. No recv happens until the response
            // has flushed, so the borrow stays valid (same invariant as the
            // zero-copy Content-Length bodies).
            conn.recv_buf.read_pos += frame.total_len;

            switch (frame.opcode) {
                .ping => self.websocketSendFrame(fd, session, .pong, frame.payload),
                .pong => {}, // unsolicited pongs are dropped
                .close => {
                    self.websocketSendFrame(fd, session, .close, frame.payload);
                    session.close_after_write = true;
                    if (!session.writing) {
                        // The echo flushed inline: tear down right away.
                        self.removeConnection(fd);
                    }
                    // Either way this connection is done: the close reply is
                    // the last thing it ever sends.
                    return;
                },
                .text, .binary => self.websocketSendFrame(fd, session, frame.opcode, frame.payload),
                .continuation => {
                    // Fragmented messages are rejected outright (RFC 6455 §5.4
                    // allows endpoints to fail on them): no reassembly state.
                    self.removeConnection(fd);
                    return;
                },
                else => {
                    // Reserved/unknown opcode: protocol error, tear down.
                    self.removeConnection(fd);
                    return;
                },
            }
        }
    }

    /// Queue one outbound websocket frame (head into the send buffer, payload
    /// borrowed as the pending writev body).
    fn websocketSendFrame(self: *Reactor, fd: posix.fd_t, session: *HttpSession, opcode: websocket_mod.Opcode, payload: []const u8) void {
        const conn = self.connections.get(fd) orelse return;
        var head_buf: [10]u8 = undefined;
        const head = websocket_mod.encodeHead(opcode, payload.len, &head_buf);
        conn.send_buf.compact();
        _ = conn.send_buf.writeSlice(head);
        session.pending_body = payload;
        session.pending_body_owned = false;
        session.pending_tail = &.{};
        session.writing = true;
        self.markWriting(fd);
        self.flushHttp(fd);
    }

    /// Drain the ring's completions (called when the ring fd is epoll-ready)
    /// and dispatch them; then resubmit reads for connections without one.
    fn handleRingCompletions(self: *Reactor) void {
        var comps: [iouring_mod.IoRing.completion_batch]iouring_mod.IoRing.Completion = undefined;
        while (true) {
            const n = self.ring.drain(&comps, false) catch return;
            if (n == 0) break;
            for (comps[0..n]) |c| self.handleCompletion(c);
        }
        // One submit per loop iteration: covers reads resubmitted by
        // completions and writes queued by the flush path.
        self.ring.submit() catch {};
    }

    fn handleCompletion(self: *Reactor, c: iouring_mod.IoRing.Completion) void {
        const fd: posix.fd_t = @intCast(c.user_data & 0xFFFFFFFF);
        if (c.user_data & iouring_mod.IoRing.cancel_tag != 0) {
            // A connection close was deferred until its pending read was
            // cancelled: close it for real now (ignore if already gone).
            if (self.connections.get(fd)) |conn| {
                if (conn.closing) self.closeConnection(conn);
            }
            return;
        }
        if (c.user_data & iouring_mod.IoRing.poll_tag != 0) {
            if (c.result < 0) {
                if (self.connections.get(fd)) |_| self.removeConnection(fd);
                return;
            }
            // POLLOUT: the socket is writable again, resume the sendfile.
            self.finalizeFlush(fd);
            return;
        }
        if (c.result < 0) {
            const err: i32 = -c.result;
            // The fd was closed and the op cancelled: the connection is gone.
            if (err == @intFromEnum(linux.E.CANCELED) or err == @intFromEnum(linux.E.BADF)) return;
            if (self.connections.get(fd)) |_| self.removeConnection(fd);
            return;
        }
        if (c.user_data & iouring_mod.IoRing.write_tag != 0) {
            if (self.mode == .http) {
                self.handleWriteData(fd, @intCast(c.result));
            } else {
                self.handleEchoWrite(fd, @intCast(c.result));
            }
        } else {
            self.handleReadData(fd, @intCast(c.result));
        }
    }

    /// A ring read completed: the data is in the connection's recv buffer.
    /// There is no EAGAIN drain probe - the next request's data completes
    /// the freshly submitted read instead.
    fn handleReadData(self: *Reactor, fd: posix.fd_t, n: usize) void {
        const conn = self.connections.get(fd) orelse return;
        conn.read_pending = false;
        if (conn.closing) return; // close deferred until the cancel lands
        if (n == 0) {
            self.removeConnection(fd);
            return;
        }
        conn.recv_buf.write_pos += n;
        // Make room for the next read before it is submitted (the old recv()
        // grew the buffer here; the sweep must never resubmit into a full
        // buffer, or a request larger than 16 KiB would hit the 431 path).
        if (conn.recv_buf.availableWrite() == 0) {
            conn.recv_buf.compact();
            if (conn.recv_buf.availableWrite() == 0 and conn.recv_buf.data.len < conn.max_recv_buf) {
                conn.recv_buf.grow(conn.allocator, @min(conn.max_recv_buf, conn.recv_buf.data.len * 2)) catch {};
            }
        }
        self.rearmTimer(conn);
        if (self.mode == .http) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (self.stats) |s| {
                if (session.stat_state == .waiting) {
                    session.stat_state = .reading;
                    _ = s.waiting.fetchSub(1, .monotonic);
                    _ = s.reading.fetchAdd(1, .monotonic);
                }
            }
            if (!session.writing or session.h2 != null) self.processHttp(fd);
        } else {
            const c = self.connections.get(fd) orelse return;
            self.onMessage(c) catch {
                self.removeConnection(fd);
            };
        }
        // Resubmit the read for the next request: queue the fd on the
        // resubmit list; ringSubmitReads sends the batch at the end of the
        // completion drain (retrying any op the SQ could not hold).
        if (self.connections.get(fd)) |c2| {
            if (!c2.read_pending and !c2.closing and self.resubmit_count < self.resubmit_reads.len) {
                self.resubmit_reads[self.resubmit_count] = fd;
                self.resubmit_count += 1;
            }
        }
    }

    /// Advance the http send state by `n` bytes: head (send buffer), then
    /// the body iov, then the chunked terminator iov. Shared by the ring
    /// write completion and the epoll-mode direct writev.
    fn advanceHttpWrite(self: *Reactor, conn: *connection.Connection, session: *HttpSession, n: usize) void {
        _ = self;
        var remaining = n;
        const head_avail = conn.send_buf.availableRead();
        if (head_avail > 0) {
            const c = @min(remaining, head_avail);
            conn.send_buf.consume(c);
            remaining -= c;
        }
        if (remaining > 0 and session.pending_body.len > 0) {
            const c = @min(remaining, session.pending_body.len);
            session.pending_body = session.pending_body[c..];
            remaining -= c;
        }
        if (remaining > 0 and session.pending_tail.len > 0) {
            const c = @min(remaining, session.pending_tail.len);
            session.pending_tail = session.pending_tail[c..];
            remaining -= c;
        }
    }

    /// A ring write completed: advance the send state by n bytes and either
    /// resubmit the remainder or finalize the flush.
    fn handleWriteData(self: *Reactor, fd: posix.fd_t, n: usize) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        if (!session.writing) return;

        self.advanceHttpWrite(conn, session, n);
        if (session.pending_body.len > 0 or session.pending_tail.len > 0) {
            self.flushHttp(fd); // socket was full mid-write; resubmit
            return;
        }
        self.freeResponseBody(session);
        session.pending_body_owned = false;
        session.pending_body = &.{};
        session.pending_tail = &.{};
        if (conn.send_buf.availableRead() > 0) {
            self.flushHttp(fd);
            return;
        }
        self.finalizeFlush(fd);
    }

    /// Echo-mode ring write completion: advance the send buffer.
    fn handleEchoWrite(self: *Reactor, fd: posix.fd_t, n: usize) void {
        const conn = self.connections.get(fd) orelse return;
        conn.write_pending = false;
        conn.send_buf.consume(@min(n, conn.send_buf.availableRead()));
        if (conn.send_buf.availableRead() > 0) {
            conn.write_iovs[0] = .{ .base = conn.send_buf.peek().ptr, .len = conn.send_buf.availableRead() };
            self.ring.submitWritev(fd, conn.write_iovs[0..1]) catch {
                self.removeConnection(fd);
            };
        }
    }

    /// Submit ring reads for the connections on the resubmit list (also
    /// grows the recv buffer when a body demands it). Ops the SQ cannot
    /// hold stay on the list for the next iteration, so reads are never
    /// lost.
    fn ringSubmitReads(self: *Reactor) void {
        var kept: usize = 0;
        for (self.resubmit_reads[0..self.resubmit_count]) |fd| {
            const conn = self.connections.get(fd) orelse continue;
            if (conn.read_pending or conn.closing) continue;
            if (conn.recv_buf.availableWrite() == 0) {
                conn.recv_buf.compact();
                if (conn.recv_buf.availableWrite() == 0) {
                    if (conn.recv_buf.data.len < conn.max_recv_buf) {
                        conn.recv_buf.grow(conn.allocator, @min(conn.max_recv_buf, conn.recv_buf.data.len * 2)) catch continue;
                    } else continue;
                }
            }
            const slice = conn.recv_buf.data[conn.recv_buf.write_pos..];
            self.ring.submitRead(fd, slice) catch {
                if (kept < self.resubmit_reads.len) {
                    self.resubmit_reads[kept] = fd;
                    kept += 1;
                }
                continue;
            };
            conn.read_pending = true;
        }
        self.resubmit_count = kept;
        self.ring.submit() catch {};
    }

    /// Close a connection whose pending ring read has been cancelled.
    fn closeConnection(self: *Reactor, conn: *connection.Connection) void {
        // The fd must be captured before the connection is destroyed below.
        const fd = conn.fd;
        _ = self.connections.remove(fd);
        self.wheel.remove(&conn.timer);
        if (self.io_mode == .epoll) self.ep.remove(fd) catch {};
        self.dropConnection(conn);
        if (self.http_sessions.fetchRemove(fd)) |kv| {
            var sess = kv.value;
            if (sess.file_fd >= 0 and !sess.file_fd_cached) posix.close(sess.file_fd);
            if (sess.resp.body_owned) self.allocator.free(sess.resp.body);
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
            if (sess.tls) |*tc| {
                // Best-effort close_notify before the FIN, then drain.
                if (tc.stage() == .application) {
                    tc.shutdown() catch {};
                    var out: [4096]u8 = undefined;
                    const m = tc.takeOut(&out);
                    if (m > 0) {
                        _ = posix.write(conn.fd, out[0..m]) catch {};
                    }
                }
                tc.deinit();
            }
            if (sess.h2) |*h2| h2.deinit();
        }
    }

    /// Write queued response bytes until the socket would block. When the send
    /// buffer is drained: close if requested, otherwise reset the session and
    /// immediately process any pipelined data already buffered.
    fn flushHttp(self: *Reactor, fd: posix.fd_t) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        // Iov order mirrors the wire: head (send buffer; chunked routes put
        // the chunk-size line there), then the body, then the chunked
        // terminator. The head flushes before any sendfile body (sendfile
        // runs from finalizeFlush), so a file route never has a body iov.
        const build_iovs = struct {
            fn call(
                sess: *HttpSession,
                c: *connection.Connection,
                iovs: *[3]posix.iovec_const,
                count: *usize,
            ) void {
                var n: usize = 0;
                const head_len = c.send_buf.availableRead();
                if (head_len > 0) {
                    iovs.*[n] = .{ .base = c.send_buf.peek().ptr, .len = head_len };
                    n += 1;
                }
                if (sess.pending_body.len > 0) {
                    iovs.*[n] = .{ .base = sess.pending_body.ptr, .len = sess.pending_body.len };
                    n += 1;
                }
                if (sess.pending_tail.len > 0) {
                    iovs.*[n] = .{ .base = sess.pending_tail.ptr, .len = sess.pending_tail.len };
                    n += 1;
                }
                count.* = n;
            }
        }.call;

        if (self.io_mode == .ring) {
            // Submit whatever is pending as one ring writev; the completion
            // advances the state and resubmits or finalizes. The ring waits
            // for writability, so there is no EPOLLOUT dance.
            var count: usize = 0;
            build_iovs(session, conn, &session.write_iovs, &count);
            if (count == 0) return self.finalizeFlush(fd);
            session.write_iov_count = count;
            self.ring.submitWritev(fd, session.write_iovs[0..count]) catch {
                self.removeConnection(fd);
                return;
            };
            return; // one ring.submit() per loop iteration (the sweep)
        }

        // One writev for whatever is pending: the remaining head, the body
        // and the chunked terminator.
        var iov: [3]posix.iovec_const = undefined;
        var count: usize = 0;
        build_iovs(session, conn, &iov, &count);
        if (count == 0) {
            // Milestone 14: push any file body straight into the socket.
            if (session.file_remaining > 0) {
                var off: i64 = @intCast(session.file_offset);
                while (session.file_remaining > 0) {
                    const rc = linux.sendfile(fd, session.file_fd, &off, @intCast(@min(session.file_remaining, 1 << 20)));
                    const err = posix.errno(rc);
                    if (err != .SUCCESS) {
                        if (err == .AGAIN or err == .INTR) break; // wait for EPOLLOUT
                        if (!session.file_fd_cached) posix.close(session.file_fd);
                        session.file_fd = -1;
                        self.removeConnection(fd);
                        return;
                    }
                    const n = rc;
                    session.file_offset += n;
                    session.file_remaining -= n;
                    off = @intCast(session.file_offset);
                }
                if (session.file_remaining > 0) {
                    // Socket buffer full mid-sendfile: continue on the next
                    // EPOLLOUT edge.
                    return;
                }
                if (!session.file_fd_cached) posix.close(session.file_fd);
                session.file_fd_cached = false;
                session.file_fd = -1;
            }
            if (session.pending_tail.len > 0) {
                // Chunked sendfile route: the terminator flushes now, after
                // the file bytes.
                self.flushHttp(fd);
                return;
            }
            return self.finalizeFlush(fd);
        }
        const n = posix.writev(fd, iov[0..count]) catch |e| {
            if (e == error.WouldBlock) return;
            self.freeResponseBody(session);
            session.pending_body = &.{};
            session.pending_tail = &.{};
            self.removeConnection(fd);
            return;
        };
        self.advanceHttpWrite(conn, session, n);
        if (session.pending_body.len > 0 or session.pending_tail.len > 0) {
            // Socket buffer full; continue on the next EPOLLOUT edge.
            return;
        }
        self.freeResponseBody(session);
        session.pending_body_owned = false;
        session.pending_body = &.{};
        session.pending_tail = &.{};
        if (conn.send_buf.availableRead() > 0) return;
        return self.finalizeFlush(fd);
    }

    /// Post-flush steps shared by both I/O paths: file body, close, session
    /// reset, pipelined processing. In ring mode an EAGAIN on sendfile
    /// submits a POLLOUT wait instead of relying on an epoll event.
    fn finalizeFlush(self: *Reactor, fd: posix.fd_t) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        // Milestone 14: push any file body straight into the socket.
        if (session.file_remaining > 0) {
            var off: i64 = @intCast(session.file_offset);
            while (session.file_remaining > 0) {
                const rc = linux.sendfile(fd, session.file_fd, &off, @intCast(@min(session.file_remaining, 1 << 20)));
                const err = posix.errno(rc);
                if (err != .SUCCESS) {
                    if (err == .AGAIN or err == .INTR) {
                        if (self.io_mode == .ring) {
                            self.ring.submitPollOut(fd) catch {};
                            self.ring.submit() catch {};
                        }
                        return;
                    }
                    if (!session.file_fd_cached) posix.close(session.file_fd);
                    session.file_fd = -1;
                    self.removeConnection(fd);
                    return;
                }
                const n = rc;
                session.file_offset += n;
                session.file_remaining -= n;
                off = @intCast(session.file_offset);
            }
            if (session.file_remaining > 0) {
                // Socket buffer full mid-sendfile: continue on the next
                // EPOLLOUT edge (epoll) or POLLOUT completion (ring).
                return;
            }
            if (!session.file_fd_cached) posix.close(session.file_fd);
            session.file_fd_cached = false;
            session.file_fd = -1;
        }

        if (session.pending_tail.len > 0) {
            // Chunked sendfile route (ring path): the terminator flushes
            // after the file bytes; handleWriteData → flushHttp → finalize.
            self.flushHttp(fd);
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
        // The recv buffer keeps any capacity it grew for a large request:
        // shrinking it here would reallocate (mmap/munmap) on every request,
        // and a keep-alive connection sees similar-sized bodies, so the
        // capacity is amortized. The allocation is bounded by
        // connection.Connection.max_recv_buffer and dies with the connection.
        // Nothing to send: wait for the next request without spurious
        // EPOLLOUT edges (epoll path only; the ring never arms EPOLLOUT).
        if (session.out_armed and self.io_mode == .epoll) {
            self.ep.modify(fd, epoll.Events.In | epoll.Events.EdgeTriggered, fd) catch {};
            session.out_armed = false;
        }
        self.processHttp(fd);
    }

    /// Free a module-allocated response body once its parts are fully sent
    /// (or the connection dies mid-flush).
    fn freeResponseBody(self: *Reactor, session: *HttpSession) void {
        if (session.resp.body_owned) {
            self.allocator.free(session.resp.body);
            session.resp.body_owned = false;
        }
    }

    /// Handle one parsed HTTP request: run the pipeline, serialize the
    /// response, flush. `tls_mode` routes the response through the TLS
    /// session (encrypted) instead of the writev/sendfile path. Returns
    /// true when the caller should continue parsing the next pipelined
    /// request (plaintext only; TLS processes one request per pass).
    fn handleHttpRequest(self: *Reactor, fd: posix.fd_t, tls_mode: bool) bool {
        const conn = self.connections.get(fd) orelse return false;
        const session = self.http_sessions.getPtr(fd) orelse return false;
        const close0 = !session.req.keep_alive;
        session.resp = http_response.Response.init(.ok);
        const handler = self.http_handler orelse &default_http_handler;
        var ctx = dsl_pipeline.Context{
            .req = &session.req,
            .resp = &session.resp,
            .allocator = self.allocator,
            .client_ip = if (self.connections.get(fd)) |c| c.peer_ip else .{ 0, 0, 0, 0 },
            .stats = self.stats,
            .static_cache = &self.static_cache,
            .limits = &self.limits,
            .formats = handler.formats(),
            .subrequest = .{ .impl = handler, .call = runtime_server.Server.subrequestImpl },
            .started = std.time.Instant.now() catch std.time.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
            .now_ns = blk: {
                const t = std.time.Instant.now() catch break :blk 0;
                break :blk @intCast(t.since(self.epoch));
            },
        };

        if (!tls_mode) {
            // Milestone 11 fast path: module-less response-template routes are
            // written straight from their pre-serialised bytes (status line +
            // template headers + Connection + Content-Length + body),
            // byte-identical to the pipeline equivalent but with zero dispatch.
            if (handler.matchFast(&ctx)) |fb| {
                conn.send_buf.compact();
                _ = conn.send_buf.writeSlice(fb.head);
                var hdr_buf: [96]u8 = undefined;
                const hdr = std.fmt.bufPrint(&hdr_buf, "Connection: {s}\r\nContent-Length: {d}\r\n\r\n", .{
                    if (close0) "close" else "keep-alive",
                    fb.body.len, // HEAD keeps the would-be body length
                }) catch unreachable;
                _ = conn.send_buf.writeSlice(hdr);
                if (session.req.method != .head) {
                    _ = conn.send_buf.writeSlice(fb.body);
                }
                session.close_after_write = close0;
                if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
                self.markWriting(fd);
                session.writing = true;
                self.flushHttp(fd);
                if (!self.connections.contains(fd)) return false;
                const sess = self.http_sessions.getPtr(fd) orelse return false;
                if (!sess.writing) return true; // flushed fully; next pipelined request
                sess.out_armed = true;
                self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
                return false;
            }
        }

        const request_outcome = handler.handleRequest(&ctx) catch {
            self.respondAndClose(fd, .internal_error);
            return false;
        };
        if (request_outcome == .not_handled) {
            // No module claimed the request (no route matched, a
            // short-circuit, or no module attached): default 404.
            session.resp = http_response.Response.init(.not_found);
            session.resp.setBody(http_response.Status.not_found.reasonPhrase());
        }
        const close = ctx.close_after_write or !session.req.keep_alive;
        session.resp.setHeader("Connection", if (close) "close" else "keep-alive");
        // nginx-parity headers, both effectively free: Date comes
        // from the once-per-second cache, Server is a comptime literal.
        session.resp.setHeader("Date", self.date_cache[0..self.date_len]);
        session.resp.setHeader("Server", "Zocket/" ++ version_mod.version);
        conn.send_buf.compact();

        if (tls_mode) {
            self.handleHttpResponseTls(fd, close);
            return false;
        }

        // The head (fast single-pass writer, fast itoa) goes into
        // the send buffer, the body stays put: one writev of two
        // iovs. (Sending the head as many iovec segments instead
        // cost more kernel iov handling than the serialisation
        // saved — measured -8% on the echo workload.)
        // Chunked routes (config `chunked: true`) use three iovs:
        // head+size line, body, terminator.
        const is_head = session.req.method == .head;
        const chunked = session.resp.chunked and
            session.resp.status != .not_modified;
        if (chunked) {
            // HEAD claims no body: size line omitted, only the
            // empty-chunk terminator is sent. Sendfile bodies
            // frame `file_len` bytes (the size line is known at
            // head time; the terminator flushes after sendfile).
            const cl: usize = if (is_head) 0 else if (session.resp.body_from_file) session.resp.file_len else session.resp.body.len;
            const framing = session.resp.writeChunkedHeadToBuffer(&conn.send_buf, cl, &session.tail_scratch) catch {
                self.freeResponseBody(session);
                self.removeConnection(fd);
                return false;
            };
            _ = framing.head_len; // head+size in send_buf, body is its own iov
            session.pending_tail = framing.tail;
        } else if (session.resp.body_from_file) {
            session.pending_tail = &.{};
            session.resp.writeHeadToBufferWithLength(&conn.send_buf, session.resp.file_len) catch {
                self.freeResponseBody(session);
                self.removeConnection(fd);
                return false;
            };
        } else {
            session.pending_tail = &.{};
            session.resp.writeHeadToBuffer(&conn.send_buf) catch {
                self.freeResponseBody(session);
                self.removeConnection(fd);
                return false;
            };
        }
        if (session.req.method == .head or session.resp.body.len == 0) {
            session.pending_body = &.{};
            session.pending_body_owned = false;
            self.freeResponseBody(session);
        } else {
            session.pending_body = session.resp.body;
            session.pending_body_owned = session.resp.body_owned;
        }
        if (session.resp.body_from_file) {
            // Take ownership of the module's fd; the body goes via
            // sendfile once the head has flushed. Cached fds stay
            // with the cache.
            session.file_fd = session.resp.file_fd;
            session.file_fd_cached = session.resp.file_fd_cached;
            session.file_offset = session.resp.file_offset;
            session.file_remaining = if (session.req.method == .head) 0 else session.resp.file_len;
        }
        session.close_after_write = close;
        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        self.markWriting(fd);
        session.writing = true;
        self.flushHttp(fd);
        if (!self.connections.contains(fd)) return false;
        const sess = self.http_sessions.getPtr(fd) orelse return false;
        if (!sess.writing) return true; // flushed fully; next pipelined request
        // Partially flushed: re-arm EPOLLOUT (epoll_ctl MOD
        // re-evaluates readiness, so this delivers the event).
        sess.out_armed = true;
        self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
        return false;
    }

    /// TLS response path (M18): the head and body go through the TLS session
    /// (encrypted); the ciphertext lands in the send buffer and flushes like
    /// the plaintext path. Sendfile is disabled over TLS — file bodies are
    /// read into memory (the static content cache covers small files).
    fn handleHttpResponseTls(self: *Reactor, fd: posix.fd_t, close: bool) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        const tc = &session.tls.?;

        // File bodies: read into memory (no sendfile over TLS in M18).
        if (session.resp.body_from_file) {
            const file_len: usize = @intCast(session.resp.file_len);
            const fbuf = self.allocator.alloc(u8, file_len) catch {
                self.removeConnection(fd);
                return;
            };
            var got: usize = 0;
            while (got < file_len) {
                const n = posix.read(session.resp.file_fd, fbuf[got..]) catch break;
                if (n == 0) break;
                got += n;
            }
            if (!session.resp.file_fd_cached) posix.close(session.resp.file_fd);
            session.resp.setBody(fbuf[0..got]);
            session.resp.body_owned = true;
            session.resp.body_from_file = false;
        }

        // Serialize the head into the staging buffer, then push head + body
        // through the TLS session.
        session.tls_stage.compact();
        session.resp.writeHeadToBuffer(&session.tls_stage) catch {
            self.freeResponseBody(session);
            self.removeConnection(fd);
            return;
        };
        tc.write(session.tls_stage.peek()) catch {
            self.freeResponseBody(session);
            self.removeConnection(fd);
            return;
        };
        if (session.req.method != .head and session.resp.body.len > 0) {
            tc.write(session.resp.body) catch {
                self.freeResponseBody(session);
                self.removeConnection(fd);
                return;
            };
        }
        self.freeResponseBody(session);

        // Drain the produced records into the send buffer and flush.
        var drained: usize = 0;
        while (true) {
            const oslice = tc.takeOutSlice();
            if (oslice.len == 0) break;
            drained += oslice.len;
            // Grow to fit the whole batch: takeOutSlice returns the entire
            // out buffer at once, so a doubling grow would truncate the
            // writeSlice below and silently drop records.
            if (conn.send_buf.availableWrite() < oslice.len) {
                if (conn.send_buf.data.len < connection.Connection.max_recv_buffer) {
                    conn.send_buf.grow(self.allocator, @min(connection.Connection.max_recv_buffer, conn.send_buf.data.len + oslice.len)) catch {
                        self.removeConnection(fd);
                        return;
                    };
                } else {
                    self.removeConnection(fd);
                    return;
                }
            }
            _ = conn.send_buf.writeSlice(oslice);
            tc.consumeOut(oslice.len);
        }
        session.close_after_write = close;
        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        self.markWriting(fd);
        session.writing = true;
        self.flushHttp(fd);
        if (!self.connections.contains(fd)) return;
        const sess = self.http_sessions.getPtr(fd) orelse return;
        if (sess.writing) {
            sess.out_armed = true;
            self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
        }
    }

    /// Drive the TLS 1.3 session for `fd` (M18): feed the buffered ciphertext,
    /// drain produced records to the socket, and once the handshake is done,
    /// feed the decrypted plaintext into the HTTP parser (or the h2 session
    /// when ALPN negotiated h2). The response path routes through
    /// `tls_conn.write`; the ciphertext is flushed via the normal send buffer.
    fn processHttpTls(self: *Reactor, fd: posix.fd_t, tc: *tls_conn.TlsConn) void {
        if (self.tls_processing) return; // re-entrant from a flush recursion
        self.tls_processing = true;
        defer self.tls_processing = false;
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;

        // Feed all buffered ciphertext into the TLS session.
        const recv_slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
        if (recv_slice.len > 0) {
            tc.feed(recv_slice) catch {
                self.removeConnection(fd);
                return;
            };
            conn.recv_buf.read_pos = conn.recv_buf.write_pos;
        }

        // Drain produced records into the send buffer and flush.
        var wrote = false;
        while (true) {
            const oslice = tc.takeOutSlice();
            if (oslice.len == 0) break;
            if (conn.send_buf.availableWrite() < oslice.len) {
                if (conn.send_buf.data.len < connection.Connection.max_recv_buffer) {
                    conn.send_buf.grow(self.allocator, @min(connection.Connection.max_recv_buffer, conn.send_buf.data.len + oslice.len)) catch {
                        self.removeConnection(fd);
                        return;
                    };
                } else {
                    self.removeConnection(fd);
                    return;
                }
            }
            _ = conn.send_buf.writeSlice(oslice);
            tc.consumeOut(oslice.len);
            wrote = true;
        }
        if (wrote) {
            self.markWriting(fd);
            session.writing = true;
            self.flushHttp(fd);
            if (!self.connections.contains(fd)) return;
            const sess = self.http_sessions.getPtr(fd) orelse return;
            if (sess.writing) {
                sess.out_armed = true;
                self.ep.modify(fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, fd) catch {};
                return;
            }
            const s2 = self.http_sessions.getPtr(fd) orelse return;
            if (s2.tls == null) return;
        }

        // The handshake is done: parse the decrypted plaintext.
        if (tc.stage() != .application) return;
        if (self.connections.get(fd) == null) {
            return;
        }
        const sess = self.http_sessions.getPtr(fd) orelse {
            return;
        };

        // Route to the h2 session when ALPN negotiated it.
        if (sess.h2 == null and std.mem.eql(u8, tc.alpn(), "h2")) {
            sess.h2 = http2_session.Session.init(self.allocator);
            if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        }

        // Drain ALL pending plaintext (one feed can decrypt several records;
        // the staging buffer grows for bodies larger than one record) and
        // process until no progress is possible. A single pass would stall
        // requests larger than the staging buffer: the remaining plaintext
        // waits for an EPOLLIN that never comes (the client is waiting for
        // the response).
        while (true) {
            if (sess.h2) |*h2s| {
                // Zero-copy: the h2 session parses straight out of the TLS
                // session's plaintext buffer; only consumed bytes advance.
                const plain = tc.plaintextSlice();
                if (plain.len == 0) break;
                const consumed = self.processHttp2From(fd, h2s, plain);
                tc.consumePlaintext(consumed);
                if (consumed == 0) break; // no progress possible
            } else {
                if (sess.tls_plain.availableWrite() == 0) sess.tls_plain.compact();
                const p = tc.takePlaintext(&sess.tls_scratch);
                if (p > 0) {
                    if (sess.tls_plain.availableWrite() < p) {
                        sess.tls_plain.grow(self.allocator, sess.tls_plain.data.len + p) catch {
                            self.removeConnection(fd);
                            return;
                        };
                    }
                    _ = sess.tls_plain.writeSlice(sess.tls_scratch[0..p]);
                }
                const before = sess.tls_plain.availableRead();
                self.processHttpFrom(fd, &sess.tls_plain);
                if (self.http_sessions.getPtr(fd) == null) return; // connection gone
                if (sess.tls_plain.availableRead() == before and p == 0) break;
            }
        }
        if (sess.h2) |*h2s| self.flushH2Output(fd, h2s);
    }

    /// Process a request from an arbitrary plaintext buffer (TLS path).
    fn processHttpFrom(self: *Reactor, fd: posix.fd_t, plain: *buffer_mod.Buffer) void {
        const session = self.http_sessions.getPtr(fd) orelse return;
        const outcome = session.parser.parse(plain, &session.req);
        switch (outcome) {
            .incomplete => {
                if (plain.availableWrite() == 0) {
                    // Plaintext staging exhausted without a complete request:
                    // keep the partial parse state; more plaintext arrives on
                    // the next read (requests larger than the 16 KiB staging
                    // are parsed incrementally).
                    plain.compact();
                }
                return;
            },
            .complete => {},
            .bad_request, .header_too_large, .payload_too_large, .unsupported, .out_of_memory => {
                self.respondAndClose(fd, switch (outcome) {
                    .bad_request => .bad_request,
                    .header_too_large => .header_too_large,
                    .payload_too_large => .payload_too_large,
                    .unsupported => .not_implemented,
                    .out_of_memory => .internal_error,
                    else => unreachable,
                });
                return;
            },
        }
        _ = self.handleHttpRequest(fd, true);
    }

    /// Drive the HTTP/2 session for `fd`: feed all buffered receive bytes,
    /// append the produced frames to the send buffer and flush. On a
    /// connection-level error send GOAWAY then close.
    fn processHttp2(self: *Reactor, fd: posix.fd_t, h2s: *http2_session.Session) void {
        const conn = self.connections.get(fd) orelse return;
        const recv_slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
        const consumed = self.processHttp2Slice(fd, h2s, recv_slice);
        // Only the bytes of complete frames are consumed; an incomplete
        // trailing frame stays buffered for the next read. Advance before
        // flushing: flushHttp recurses back here and must not reprocess.
        conn.recv_buf.read_pos += consumed;
        self.flushH2Output(fd, h2s);
    }

    /// Process h2 bytes from an arbitrary slice (the recv buffer for h2c,
    /// the TLS plaintext buffer for h2-over-TLS). Returns the consumed count.
    fn processHttp2From(self: *Reactor, fd: posix.fd_t, h2s: *http2_session.Session, plain: []const u8) usize {
        return self.processHttp2Slice(fd, h2s, plain);
    }

    fn processHttp2Slice(self: *Reactor, fd: posix.fd_t, h2s: *http2_session.Session, recv_slice: []const u8) usize {
        const conn = self.connections.get(fd) orelse return 0;
        const session_p = self.http_sessions.getPtr(fd) orelse return 0;
        const out = &session_p.h2_out;
        out.clearRetainingCapacity();

        var handler = http2_session.Session.Handler{
            .server = self.http_handler orelse &default_http_handler,
            .allocator = self.allocator,
            .client_ip = conn.peer_ip,
            .stats = self.stats,
            .static_cache = &self.static_cache,
            .limits = &self.limits,
            .date_header = self.date_cache[0..self.date_len],
            .version_string = "Zocket/" ++ version_mod.version,
        };

        const consumed = h2s.process(recv_slice, out, &handler) catch |e| blk: {
            // Connection-level protocol violation: GOAWAY then close.
            var gbuf = std.ArrayList(u8).empty;
            defer gbuf.deinit(self.allocator);
            const code: u32 = switch (e) {
                error.FrameSizeError => 0x6, // FRAME_SIZE_ERROR
                error.FlowControlError => 0x3, // FLOW_CONTROL_ERROR
                error.OutOfMemory => 0x2, // INTERNAL_ERROR
                else => 0x1, // PROTOCOL_ERROR
            };
            http2_frames.writeGoaway(&gbuf, self.allocator, h2s.max_stream_id, code, @errorName(e)) catch {};
            self.appendH2Output(fd, &gbuf);
            self.markWriting(fd);
            const sess = self.http_sessions.getPtr(fd) orelse return 0;
            sess.writing = true;
            sess.close_after_write = true;
            break :blk 0;
        };
        if (out.items.len > 0) {
            self.appendH2Output(fd, out);
            const sess = self.http_sessions.getPtr(fd) orelse return consumed;
            if (sess.tls != null) {
                // h2 over TLS: drain the encrypted records into send_buf.
                while (true) {
                    // Zero-copy drain: the session's out buffer is copied
                    // once into the send buffer (no scratch staging).
                    const oslice = sess.tls.?.takeOutSlice();
                    if (oslice.len == 0) break;
                    if (conn.send_buf.availableWrite() < oslice.len) {
                        conn.send_buf.grow(self.allocator, conn.send_buf.data.len + oslice.len) catch {
                            self.removeConnection(fd);
                            return consumed;
                        };
                    }
                    _ = conn.send_buf.writeSlice(oslice);
                    sess.tls.?.consumeOut(oslice.len);
                }
            }
            if (!sess.writing) {
                self.markWriting(fd);
                sess.writing = true;
            }
        }
        return consumed;
    }

    /// Flush h2 output produced by processHttp2Slice, then handle a session
    /// close. Must run after the caller advanced its buffer past the
    /// consumed bytes: flushHttp recurses (finalizeFlush → processHttp →
    /// processHttp2) and must not see the same bytes twice.
    fn flushH2Output(self: *Reactor, fd: posix.fd_t, h2s: *http2_session.Session) void {
        const sess = self.http_sessions.getPtr(fd) orelse return;
        if (sess.writing) self.flushHttp(fd);
        // If the session asked to close (GOAWAY received), finish draining
        // and close.
        if (h2s.closing) {
            const s2 = self.http_sessions.getPtr(fd) orelse return;
            if (!s2.writing) self.removeConnection(fd);
        }
    }

    fn appendH2Output(self: *Reactor, fd: posix.fd_t, out: *const std.ArrayList(u8)) void {
        const conn = self.connections.get(fd) orelse return;
        if (out.items.len == 0) return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        if (session.tls != null) {
            // h2 over TLS (M18): the frames must be encrypted. The caller
            // (processHttp2Slice) drains + flushes afterwards.
            session.tls.?.write(out.items) catch {
                self.removeConnection(fd);
            };
            return;
        }
        conn.send_buf.compact();
        // writeSlice silently truncates at the buffer's capacity; grow to
        // fit the whole frame batch (HTTP/1 keeps send_buf small because the
        // body goes out via writev, but HTTP/2 frames all live in send_buf).
        if (conn.send_buf.availableWrite() < out.items.len) {
            conn.send_buf.grow(self.allocator, conn.send_buf.data.len + out.items.len) catch return;
        }
        _ = conn.send_buf.writeSlice(out.items);
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
        resp.writeToBuffer(&conn.send_buf) catch {
            self.removeConnection(fd);
            return;
        };
        session.close_after_write = true;
        if (self.stats) |s| _ = s.requests.fetchAdd(1, .monotonic);
        self.markWriting(fd);
        session.writing = true;
        self.flushHttp(fd);
    }

    /// Accept from the per-reactor listener (SO_REUSEPORT, Milestone 14) and
    /// register each connection directly — no accept loop, no dispatcher, no
    /// eventfd wakeup. While draining (reload-hard handoff) connections
    /// already queued in the accept backlog are still served: dropping them
    /// would reset clients mid-handshake. The listener is closed right after
    /// this batch, so this is bounded to the backlog; connections arriving
    /// after the close go to the sibling listeners (the new daemon).
    fn acceptConnections(self: *Reactor) void {
        while (true) {
            const conn_fd = sockets.acceptNonBlock(self.listener) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return,
            };
            // TCP_NODELAY on accepted connections: nginx (default), Caddy
            // and Bun all enable it; without it the Nagle/delayed-ACK
            // interlock adds ~40 ms stalls to small two-part responses.
            // One setsockopt per connection, amortized over keep-alive.
            sockets.setTcpNoDelay(conn_fd);
            if (self.accepted_counter) |c| _ = c.fetchAdd(1, .monotonic);
            const conn = self.conn_pool.acquire(conn_fd) catch {
                posix.close(conn_fd);
                return;
            };
            conn.peer_ip = sockets.peerIp(conn_fd);
            self.registerConnection(conn);
        }
    }

    /// Close a connection and recycle it: pool-owned objects go back to the
    /// pool, external ones (tests, attach path) are destroyed.
    fn dropConnection(self: *Reactor, conn: *connection.Connection) void {
        conn.close();
        if (conn.from_pool) {
            self.conn_pool.release(conn);
        } else {
            conn.destroy();
        }
    }

    /// Register a freshly created connection with this reactor's epoll and
    /// registries (shared by the pending queue and the accept path).
    fn registerConnection(self: *Reactor, conn: *connection.Connection) void {
        if (self.io_mode == .ring) {
            // Reads and writes go through the ring: the connection is never
            // epoll-registered.
        } else {
            self.ep.add(conn.fd, epoll.Events.In | epoll.Events.Out | epoll.Events.EdgeTriggered, conn.fd) catch {
                self.dropConnection(conn);
                return;
            };
        }
        if (self.connections.put(conn.fd, conn)) |_| {
            _ = self.registered.fetchAdd(1, .monotonic);
        } else |_| {
            self.ep.remove(conn.fd) catch {};
            self.dropConnection(conn);
            return;
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
                .parser = http_parser.Parser.initWithLimits(self.allocator, self.limits.max_line_bytes, self.limits.max_chunked_body),
                .req = http_parser.Request.initWithLimits(self.allocator, self.limits.max_headers),
            };
            if (self.http_sessions.put(conn.fd, session)) |_| {} else |_| {
                session.parser.deinit();
                session.req.deinit();
                self.wheel.remove(&conn.timer);
                if (self.io_mode == .epoll) self.ep.remove(conn.fd) catch {};
                self.dropConnection(conn);
            }
        }
        if (self.io_mode == .ring and self.resubmit_count < self.resubmit_reads.len) {
            self.resubmit_reads[self.resubmit_count] = conn.fd;
            self.resubmit_count += 1;
            self.ringSubmitReads();
        }
    }

    /// Echo semantics identical to the Milestone 1 server: whatever was read is
    /// copied into the send buffer and the fd is armed for writability.
    fn onMessage(self: *Reactor, conn: *connection.Connection) !void {
        const data = conn.recv_buf.peek();
        if (data.len > 0) {
            _ = conn.send_buf.writeSlice(data);
            conn.recv_buf.reset();
            if (self.io_mode == .ring) {
                if (conn.write_pending) return; // the in-flight write resubmits
                conn.write_iovs[0] = .{ .base = conn.send_buf.peek().ptr, .len = conn.send_buf.availableRead() };
                self.ring.submitWritev(conn.fd, conn.write_iovs[0..1]) catch return error.WriteFailed;
                conn.write_pending = true;
                return;
            }
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
            self.registerConnection(conn);
        }
    }

    fn removeConnection(self: *Reactor, fd: posix.fd_t) void {
        if (self.connections.get(fd)) |conn| {
            if (self.io_mode == .ring and conn.read_pending) {
                // A read is in flight for this fd: closing it now would
                // let a stale completion corrupt a reused fd. Cancel the
                // read and close when the cancel lands.
                if (conn.closing) return;
                conn.closing = true;
                self.ring.submitCancel(fd) catch {
                    self.closeConnection(conn);
                    return;
                };
                self.ring.submit() catch {
                    self.closeConnection(conn);
                };
                return;
            }
        }
        if (self.connections.fetchRemove(fd)) |kv| {
            const conn = kv.value;
            // Unlink the idle timer so the wheel never points at freed memory.
            self.wheel.remove(&conn.timer);
            if (self.io_mode == .epoll) self.ep.remove(fd) catch {};
            self.dropConnection(conn);
        }
        if (self.http_sessions.fetchRemove(fd)) |kv| {
            var sess = kv.value;
            if (sess.file_fd >= 0 and !sess.file_fd_cached) posix.close(sess.file_fd);
            if (sess.resp.body_owned) self.allocator.free(sess.resp.body);
            if (self.stats) |s| {
                switch (sess.stat_state) {
                    .waiting => _ = s.waiting.fetchSub(1, .monotonic),
                    .reading => _ = s.reading.fetchSub(1, .monotonic),
                    .writing => _ = s.writing.fetchSub(1, .monotonic),
                }
                _ = s.active.fetchSub(1, .monotonic);
            }
            if (sess.h2) |*h2s| h2s.deinit();
            sess.h2_out.deinit(self.allocator);
            sess.parser.deinit();
            sess.req.deinit();
            if (sess.tls) |*tc| {
                // Best-effort close_notify before the FIN, then drain.
                if (tc.stage() == .application) {
                    tc.shutdown() catch {};
                    var out: [4096]u8 = undefined;
                    const m = tc.takeOut(&out);
                    if (m > 0) {
                        _ = posix.write(fd, out[0..m]) catch {};
                    }
                }
                tc.deinit();
            }
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
            if (s.file_fd >= 0 and !s.file_fd_cached) posix.close(s.file_fd);
            if (s.resp.body_owned) self.allocator.free(s.resp.body);
            if (s.h2) |*h2s| h2s.deinit();
            s.h2_out.deinit(self.allocator);
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
        const n = posix.write(sock, remaining) catch |e| {
            // A closed peer (EPIPE/ECONNRESET) must surface, not retry forever.
            if (e == error.WouldBlock) {
                std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
                continue;
            }
            return e;
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

/// Runtime-built 200-empty response including the cached Date/Server lines.
fn httpOkEmpty(buf: []u8) []const u8 {
    var dbuf: [96]u8 = undefined;
    return std.fmt.bufPrint(buf, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 0" ++ "\r\n\r\n", .{testDateLine(&dbuf)}) catch unreachable;
}

/// Expected "Date: ...\r\nServer: Zocket\r\n" for the current wall
/// second (the reactor caches the date and refreshes it once per second).
fn testDateLine(buf: []u8) []const u8 {
    const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
    const date = cache_mod.formatHttpDate(@intCast(ts.sec), buf) orelse unreachable;
    return std.fmt.bufPrint(buf[date.len..], "Date: {s}\r\nServer: Zocket/" ++ version_mod.version ++ "\r\n", .{date}) catch unreachable;
}

/// Build one masked client-to-server websocket frame (RFC 6455 §5.3): the
/// client MUST mask; the key is fixed here so tests are deterministic.
fn wsMaskedFrame(buf: []u8, opcode: websocket_mod.Opcode, payload: []const u8) []const u8 {
    const mask = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var pos: usize = 2;
    if (payload.len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload.len), .big);
        pos = 4;
    }
    @memcpy(buf[pos..][0..4], &mask);
    pos += 4;
    for (payload, 0..) |c, i| buf[pos + i] = c ^ mask[i % 4];
    return buf[0 .. pos + payload.len];
}

test "reactor upgrades to websocket and echoes frames after the 101" {
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

    // Handshake: the RFC 6455 §1.3 example key.
    try writeAll(pair[0], "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
    const want_101 = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, want_101.len, 3000);
    try testing.expectEqualStrings(want_101, buf[0..n1]);

    // Post-101 raw phase: a masked text frame echoes back as an unmasked
    // text frame (server frames are never masked).
    var wire: [64]u8 = undefined;
    try writeAll(pair[0], wsMaskedFrame(&wire, .text, "Hello"));
    const n2 = try readUntil(pair[0], &buf, 7, 3000);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 } ++ "Hello".*, buf[0..n2]);

    // Ping -> pong with the payload preserved.
    try writeAll(pair[0], wsMaskedFrame(&wire, .ping, "pi"));
    const n3 = try readUntil(pair[0], &buf, 4, 3000);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 0x02, 'p', 'i' }, buf[0..n3]);

    // Close -> close echo, then the server tears the connection down (EOF).
    try writeAll(pair[0], wsMaskedFrame(&wire, .close, ""));
    const n4 = try readUntil(pair[0], &buf, 2, 3000);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x00 }, buf[0..n4]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}

test "reactor leaves non-RFC upgrade requests as plain HTTP" {
    // RFC 6455 §4.2.1: missing/wrong Sec-WebSocket-Version or a non-GET
    // method must not switch protocols.
    const cases = [_][]const u8{
        // Version absent.
        "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        // Wrong version.
        "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n",
        // POST cannot upgrade.
        "POST /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nContent-Length: 0\r\n\r\n",
    };
    for (cases) |wire| {
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

        try writeAll(pair[0], wire);
        var buf: [512]u8 = undefined;
        const n = try readUntil(pair[0], &buf, "HTTP/1.1 ".len + 3, 3000);
        // A normal HTTP status came back — never a protocol switch.
        try testing.expect(!std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 101"));
    }
}

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
    var ok_buf_0: [160]u8 = undefined;
    const http_ok_empty_0 = httpOkEmpty(&ok_buf_0);
    const n1 = try readUntil(pair[0], &buf, http_ok_empty_0.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_0, buf[0..n1]);

    // Request 2 on the same connection: POST, body echoed.
    try writeAll(pair[0], "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var date_buf_want2: [96]u8 = undefined;
    var want_buf_want2: [512]u8 = undefined;
    const want2 = std.fmt.bufPrint(&want_buf_want2, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 5" ++ "\r\n\r\n" ++ "hello", .{testDateLine(&date_buf_want2)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // Request 3: Connection: close -> response then EOF.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    var date_buf_want3: [96]u8 = undefined;
    var want_buf_want3: [512]u8 = undefined;
    const want3 = std.fmt.bufPrint(&want_buf_want3, "HTTP/1.1 200 OK\r\n" ++ "Connection: close\r\n" ++ "{s}" ++ "Content-Length: 0" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want3)}) catch unreachable;
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
    var date_buf_want_a: [96]u8 = undefined;
    var want_buf_want_a: [512]u8 = undefined;
    const want_a = std.fmt.bufPrint(&want_buf_want_a, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 1" ++ "\r\n\r\n" ++ "A", .{testDateLine(&date_buf_want_a)}) catch unreachable;
    var date_buf_want_b: [96]u8 = undefined;
    var want_buf_want_b: [512]u8 = undefined;
    const want_b = std.fmt.bufPrint(&want_buf_want_b, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 1" ++ "\r\n\r\n" ++ "B", .{testDateLine(&date_buf_want_b)}) catch unreachable;
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

test "reactor HTTP oversized body hits the buffer cap, yields 431 and closes" {
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
    // 16 MiB does not fit a test stack; allocate and send in chunks (the
    // recv buffer grows up to max_recv_buffer, then the buffer-full path
    // rejects).
    const body = try allocator.alloc(u8, echo_mod.max_echo_body + 1);
    defer allocator.free(body);
    @memset(body, 'x');
    var wire_buf: [256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try writeAll(pair[0], wire);
    var sent: usize = 0;
    while (sent < body.len) : (sent += 65536) {
        // Body arrives in chunks to exercise the partial-body path. The
        // server 431s and closes as soon as the buffer cap is hit, so a
        // BrokenPipe mid-stream is expected.
        std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
        writeAll(pair[0], body[sent..@min(sent + 65536, body.len)]) catch |e| {
            if (e == error.BrokenPipe) break;
            return e;
        };
    }

    // The recv buffer grows only up to max_recv_buffer, so a body over the
    // cap is rejected by the buffer-full path (431) before the echo module's
    // 413 can apply; the module's 413 path is covered by its own unit test.
    const want = "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\nContent-Length: 31\r\n\r\nRequest Header Fields Too Large";
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 2000));
}

test "reactor HTTP 64 KiB POST is echoed with 200 (regression: was 431) and keeps the connection alive" {
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

    // 64 KiB body: larger than the 16 KiB default buffer, so the receive
    // path must grow it (in steps) before the request can complete. Before
    // the buffer-growth fix this request was rejected with 431 (buffer full,
    // request incomplete) — this test locks in the 200 + full-body echo.
    const body_len = 64 * 1024;
    var body = [_]u8{'z'} ** body_len;
    var wire_buf: [body_len + 128]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body_len, body }) catch unreachable;

    var sent: usize = 0;
    while (sent < wire.len) : (sent += 4096) {
        try writeAll(pair[0], wire[sent..@min(sent + 4096, wire.len)]);
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    var date_buf_head: [96]u8 = undefined;
    var want_buf_head: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&want_buf_head, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 65536" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_head)}) catch unreachable;
    const total = head.len + body_len;
    var resp_buf: [body_len + 128]u8 = undefined;
    const got = try readUntil(pair[0], &resp_buf, total, 5000);
    try testing.expectEqual(total, got);
    try testing.expectEqualStrings(head, resp_buf[0..head.len]);
    try testing.expectEqualSlices(u8, &body, resp_buf[head.len..total]);

    // The connection must survive the large request: the grown recv-buffer
    // capacity is kept (no per-request realloc) and a follow-up request is
    // served normally.
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var small: [128]u8 = undefined;
    var ok_buf_5: [160]u8 = undefined;
    const http_ok_empty_5 = httpOkEmpty(&ok_buf_5);
    const n2 = try readUntil(pair[0], &small, http_ok_empty_5.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_5, small[0..n2]);
}

// A JSON config loaded at runtime, driving requests through the pipeline in a
// reactor: unmatched requests fall back to the default 404 (no module
// attached), matched ones go through the echo module.
test "reactor runs a conf-config pipeline with default 404 fallback" {
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location = /only { content echo; }
        \\}
    );
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
    var date_buf_want_echo: [96]u8 = undefined;
    var want_buf_want_echo: [512]u8 = undefined;
    const want_echo = std.fmt.bufPrint(&want_buf_want_echo, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 4" ++ "\r\n\r\n" ++ "echo", .{testDateLine(&date_buf_want_echo)}) catch unreachable;
    const n1 = try readUntil(pair[0], &buf, want_echo.len, 3000);
    try testing.expectEqualStrings(want_echo, buf[0..n1]);

    // No route matches: default 404, connection stays alive.
    try writeAll(pair[0], "GET /elsewhere HTTP/1.1\r\n\r\n");
    var date_buf_want_404: [96]u8 = undefined;
    var want_buf_want_404: [512]u8 = undefined;
    const want_404 = std.fmt.bufPrint(&want_buf_want_404, "HTTP/1.1 404 Not Found\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 9" ++ "\r\n\r\n" ++ "Not Found", .{testDateLine(&date_buf_want_404)}) catch unreachable;
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
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 0" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want)}) catch unreachable;
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    // HEAD on a POST-shaped path: Content-Length must reflect the would-be
    // body, but no body bytes may follow the head.
    try writeAll(pair[0], "HEAD /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var date_buf_want2b: [96]u8 = undefined;
    var want_buf_want2b: [512]u8 = undefined;
    const want2b = std.fmt.bufPrint(&want_buf_want2b, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 5" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want2b)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want2b.len, 3000);
    try testing.expectEqualStrings(want2b, buf[0..n2]);
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

    try writeAll(pair[0], "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    var buf: [512]u8 = undefined;
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Content-Length: 11" ++ "\r\n\r\n" ++ "hello world", .{testDateLine(&date_buf_want)}) catch unreachable;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    r.stop();
    r.join();
}

test "reactor serves a chunked response when the route opts in" {
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location /chunked { content echo; chunked on; }
        \\}
    );
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

    // POST /chunked: echo body framed as a single chunk.
    try writeAll(pair[0], "POST /chunked HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var buf: [512]u8 = undefined;
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "5\r\nhello\r\n0\r\n\r\n", .{testDateLine(&date_buf_want)}) catch unreachable;
    const n1 = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n1]);

    // GET with an empty body: empty-chunk framing only.
    try writeAll(pair[0], "GET /chunked HTTP/1.1\r\n\r\n");
    var date_buf_want2: [96]u8 = undefined;
    var want_buf_want2: [512]u8 = undefined;
    const want2 = std.fmt.bufPrint(&want_buf_want2, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "0\r\n\r\n", .{testDateLine(&date_buf_want2)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // HEAD: same head as GET, no framing bytes.
    try writeAll(pair[0], "HEAD /chunked HTTP/1.1\r\n\r\n");
    var date_buf_want3: [96]u8 = undefined;
    var want_buf_want3: [512]u8 = undefined;
    const want3 = std.fmt.bufPrint(&want_buf_want3, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "0\r\n\r\n", .{testDateLine(&date_buf_want3)}) catch unreachable;
    const n3 = try readUntil(pair[0], &buf, want3.len, 3000);
    try testing.expectEqualStrings(want3, buf[0..n3]);

    // Chunked request into the chunked route: assembled then re-framed.
    try writeAll(pair[0], "POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n");
    var date_buf_want4: [96]u8 = undefined;
    var want_buf_want4: [512]u8 = undefined;
    const want4 = std.fmt.bufPrint(&want_buf_want4, "HTTP/1.1 200 OK\r\n" ++ "Connection: keep-alive\r\n" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "6\r\nabcdef\r\n0\r\n\r\n", .{testDateLine(&date_buf_want4)}) catch unreachable;
    const n4 = try readUntil(pair[0], &buf, want4.len, 3000);
    try testing.expectEqualStrings(want4, buf[0..n4]);

    r.stop();
    r.join();
}
// wheel's tick granularity is 100 ms, so deadlines land within ~100 ms of the
// nominal second (the loop re-advances the wheel before every epoll_wait,
// timeout 100 ms). Sleeps below leave generous margins on both sides of every
// deadline.
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
    var ok_buf_1: [160]u8 = undefined;
    const http_ok_empty_1 = httpOkEmpty(&ok_buf_1);
    const n1 = try readUntil(pair[0], &buf, http_ok_empty_1.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_1, buf[0..n1]);

    // Request 2 just before the deadline: pushes the deadline to ~1.5 s.
    std.posix.nanosleep(0, 500 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var ok_buf_2: [160]u8 = undefined;
    const http_ok_empty_2 = httpOkEmpty(&ok_buf_2);
    const n2 = try readUntil(pair[0], &buf, http_ok_empty_2.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_2, buf[0..n2]);

    // Request 3 *after* the original ~1 s deadline: answered, which proves the
    // timer was re-armed (without rearming the connection would already be
    // closed and this write would fail).
    std.posix.nanosleep(0, 600 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var ok_buf_3: [160]u8 = undefined;
    const http_ok_empty_3 = httpOkEmpty(&ok_buf_3);
    const n3 = try readUntil(pair[0], &buf, http_ok_empty_3.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_3, buf[0..n3]);

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
    var ok_buf_4: [160]u8 = undefined;
    const http_ok_empty_4 = httpOkEmpty(&ok_buf_4);
    const n1 = try readUntil(pair[0], &buf, http_ok_empty_4.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_4, buf[0..n1]);

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 1), r.countConnections());
}
