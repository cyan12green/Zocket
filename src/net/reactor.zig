const std = @import("std");
const compat = @import("../compat.zig");
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
const limit_mod = @import("../dsl/modules/limit.zig");
const version_mod = @import("../version.zig");
const http2_session = @import("../http2/session.zig");
const tls_conn = @import("../tls/conn.zig");
const buffer_mod = @import("buffer.zig");
const http2_frames = @import("../http2/frames.zig");
const websocket_mod = @import("../http/websocket.zig");
const proxy_mod = @import("../dsl/modules/proxy.zig");
const proxy_proto = @import("proxy_proto.zig");
const sni_mod = @import("sni.zig");
const dsl_registry = @import("../dsl/registry.zig");
const default_registry = dsl_registry.default_registry;

/// I/O backend selection. Default: epoll (measured at parity with the ring
/// on the keep-alive workloads and more robust at high connection counts).
/// Set to false (--uring) to try the io_uring batch path at init and use
/// it when available.
pub var force_epoll: bool = true;
const runtime_server = @import("../runtime/server.zig");

const max_events = 1024;

/// Monotonic ns on the PROXY clock (its lazy epoch): transaction
/// deadlines must share the base that stamped started_ns.


fn upstreamNowNs() u64 {
    return proxy_mod.currentNs();
}

/// Default connection idle timeout in seconds. Zero disables
/// idle reaping.
pub const default_idle_timeout_seconds: u32 = 60;

/// Fallback HTTP request processor used when a reactor is created without an
/// explicit handler (e.g. in tests): the default echo-on-everything config.
/// NOTE(vhost): in multi-server mode every reactor must receive its own
/// handler pointer; this fallback is test-only.
const default_http_handler = runtime_server.Server.default();
/// Epoll data tag marking an upstream fd; the low bits carry the CLIENT fd
/// (fds are small positive ints, so bit 30 is safely out of their range).
const up_tag: u64 = 1 << 30;

/// `limits.max_requests` maps to the h2 per-connection concurrent-stream
/// ceiling when configured (0 keeps the protocol default of 100): the
/// worker-wide in-flight cap cannot be enforced per stream without
/// cross-session accounting, so the advertised/enforced limit is the
/// session-level analog.
fn applyH2StreamCap(h2s: *http2_session.Session, max_requests: usize) void {
    if (max_requests == 0) return;
    const cap: u32 = @intCast(@min(max_requests, @as(usize, std.math.maxInt(u32))));
    if (cap != 0 and cap < h2s.max_streams) h2s.max_streams = cap;
}

/// Connection protocol handled by a reactor.
pub const Mode = enum {
    /// Raw byte echo.
    echo,
    /// HTTP/1.1: parse requests, respond with the request body echoed.
    http,
};

/// One parked upstream round trip (framework v2). Owned by the client
/// session; the reactor drives it from epoll events on the upstream fd.
pub const UpTxState = enum { sending, reading };

pub const UpTx = struct {
    fd: posix.fd_t,
    backend_idx: usize,
    route: *const dsl_registry.Route,
    state: UpTxState,
    request: []const u8, // arena slice
    sent: usize = 0,
    reader: proxy_mod.UpstreamReader = .{},
    started_ns: u64,
    offer_sticky: bool,
    sticky_name: []const u8,

    /// Send-phase writability wait (event mask is IN|OUT then).
    awaiting_out: bool = false,
    /// fd came from the keepalive pool (see ParkedPlan.pooled).
    pooled: bool = false,
    /// The stale-pool retry already ran for this transaction.
    retried: bool = false,
};

const HttpSession = struct {
    parser: http_parser.Parser,
    req: http_parser.Request,
    /// HTTP/2 session, created lazily when the connection
    /// preface is detected (or negotiated over TLS via ALPN). When non-null
    /// the connection is in HTTP/2 mode and `parser`/`req` are unused.
    h2: ?http2_session.Session = null,
    /// TLS 1.3 session created lazily when the first record looks
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
    /// Stub-status accounting state which shared counter the
    /// connection currently contributes to.
    stat_state: enum { waiting, reading, writing } = .waiting,
    /// PROXY protocol header already consumed on this connection (only
    /// meaningful when the reactor's `proxy_protocol` is set; fresh
    /// sessions start false and consume exactly one header).
    proxy_consumed: bool = false,
    /// limit_rate throttle (bytes/sec, 0 = unlimited): token-bucket state.
    /// `rate_allowance` refills with elapsed time up to one burst; when a
    /// flush finds no allowance with body bytes pending, `throttled` parks
    /// the session until the loop's throttle kick refills it.
    rate_bps: u64 = 0,
    rate_allowance: i64 = 0,
    rate_last_ns: u64 = 0,
    throttled: bool = false,
    /// Listed in the reactor's throttle kick list (dedup flag; cleared
    /// when kicked to completion).
    throttle_listed: bool = false,
    /// sendfile state while `file_remaining > 0` the body is
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
    /// True once a 101 Switching Protocols handshake has been sent and
    /// the connection left HTTP behind (websocket byte-pipe mode).
    upgraded: bool = false,
    /// Request-timeout bookkeeping (slowloris defense): when the first byte
    /// of this request arrived and when the last successful recv happened.
    first_byte_at: ?compat.Instant = null,
    last_rx_at: ?compat.Instant = null,
    /// Scratch for the 101 handshake head (upgradeConnection); 160 covers
    /// the websocket head with digest plus slack.
    upgrade_head_scratch: [160]u8 = undefined,
    /// Test-only stable route anchor (framework v2 driver tests).
    route_ptr_for_test: ?*const dsl_registry.Route = null,
    /// Parked upstream transaction (framework v2 .async): heap-allocated
    /// only while a proxy request is in flight; every other connection pays
    /// nothing.
    /// Inline parked-upstream transaction: one per connection, so parking
    /// costs no heap allocation and no fd->session map (the epoll tag
    /// carries the client fd). nginx keeps the same state on its
    /// connection object.
    up_tx: UpTx = undefined,
    up_active: bool = false,
    /// This session has a request counted against `limits.max_requests`
    /// (incremented at request entry, released on completion/teardown).
    req_counted: bool = false,

};

/// A single-reactor worker: its own thread, its own epoll instance and its own
/// connection registry, wired for the echo protocol (identical semantics to the
/// single-threaded server). Inbound connections are handed over
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
    /// Config-driven HTTP request processor. Only used in `.http`
    /// mode; when null, `default_http_handler` is used. Shared read-only across
    /// reactors, so it is safe to call from the reactor thread.
    http_handler: ?*const runtime_server.Server,
    /// Optional server group for per-request Host-based server selection.
    /// When set, `handler` is resolved per-request via `resolveServer`.
    server_group: ?*const runtime_server.ServerGroup = null,
    /// The resolved handler for the current request. Updated by
    /// `resolveServer` when a server_group is present; otherwise stays the
    /// default or the value from `http_handler`.
    handler: *const runtime_server.Server = &default_http_handler,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    pending: std.ArrayList(*connection.Connection),
    /// Accepted connection fds handed over by the server's acceptor thread
    /// (raw fds: the reactor adopts them in its own pool).
    pending_fds: std.ArrayList(posix.fd_t),
    pending_lock: compat.Mutex,
    /// Total connections this reactor has registered, ever. Bumped on the
    /// reactor thread when a pending connection is added to the registry;
    /// monotonic, so tests can assert dispatch happened without racing
    /// connection reaping.
    registered: std.atomic.Value(usize),
    /// Idle timeout in wheel ticks (1 s each); zero disables idle reaping.
    idle_timeout_ticks: u64,
    /// Wall-clock epoch the timer ticks are measured from.
    epoch: compat.Instant,
    /// Timer wheel advancing on every loop iteration; idle connections expire
    /// and close.
    wheel: timer_wheel.default_wheel,
    /// Connections the wheel expired in the current advance pass; drained
    /// after `advanceTo` returns (the wheel callback must not tear down
    /// objects whose entries are still linked).
    expired_fds: std.ArrayList(posix.fd_t),
    /// Throttled sessions awaiting budget (limit_rate): kicked once per
    /// loop iteration (see kickThrottled). Membership is deduped by the
    /// session's throttle_listed flag; stale fds are skipped on visit.
    throttle_fds: std.ArrayList(posix.fd_t),
    /// Shared connection/request counters; null in echo mode.
    stats: ?*runtime_server.ServerStats = null,
    /// Static-file fd cache (nginx open_file_cache equivalent),
    /// follow-up): per-reactor, no locks. Served from it, a cached file
    /// costs zero open/stat/close syscalls and zero ETag/date formatting.
    static_cache: static_cache_mod.StaticCache = undefined,
    /// Connection pool accepts recycle pooled
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
    /// Requests parsed-but-unanswered on this reactor right now
    /// (`limits.max_requests` cap; single-threaded access).
    in_flight: usize = 0,
    /// Per-reactor listener when set, this
    /// reactor accepts connections directly from the kernel; -1 otherwise.
    listener: posix.fd_t = -1,
    /// True when several reactors share ONE listening socket (the server
    /// creates a single SO_REUSEPORT listener and every reactor adds it to
    /// its epoll with EPOLLEXCLUSIVE). Long-lived keep-alive connections
    /// are then handed to reactors by rotation instead of the kernel's
    /// per-connection 4-tuple hash, which skews 100-connection bursts ~2:1
    /// across four threads and caps throughput on the hot pair. A shared
    /// listener is never closed by a reactor: the owning Server closes it.
    shared_listener: bool = false,
    /// PROXY protocol expected on accepted connections (set post-init from
    /// the listen spec; `listen ... proxy_protocol`). The header is consumed
    /// in processHttp before any protocol sniffing.
    proxy_protocol: bool = false,
    /// Total accepted counter shared with the server (bumped per accept).
    accepted_counter: ?*std.atomic.Value(usize) = null,
    /// Last wall tick the request-timeout sweep ran (1 Hz gating).
    last_timeout_sweep_tick: u64 = 0,
    /// Test-only stable route anchor (framework v2 driver tests).
    route_ptr_for_test: ?*const dsl_registry.Route = null,
    /// Parked upstream transactions: upstream fd -> client fd.
    upstream_conns: std.AutoHashMap(posix.fd_t, posix.fd_t),
    /// Graceful-drain mode stop accepting new connections
    /// and exit the loop once the connection map empties (or a timeout).
    draining: std.atomic.Value(bool) = .init(false),
    drained: std.atomic.Value(bool) = .init(false),
    drain_started: compat.Instant = undefined,
    /// Set by `drain`: the listener should be closed as soon as the current
    /// epoll batch finishes (see `closeListenerIfRequested`).
    listener_close_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, id: usize, mode: Mode) !Reactor {
        return initWithTimeout(allocator, id, mode, default_idle_timeout_seconds);
    }

    /// Like `init`, with an explicit idle timeout in seconds (zero disables).
    pub fn initWithTimeout(allocator: std.mem.Allocator, id: usize, mode: Mode, idle_timeout_seconds: u32) !Reactor {
        return initWithHandlerTimeout(allocator, id, mode, null, idle_timeout_seconds, null);
    }

    /// Like `init`, but with an explicit HTTP request processor (used in HTTP
    /// mode; ignored in echo mode).
    pub fn initWithHandler(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
    ) !Reactor {
        return initWithHandlerTimeout(allocator, id, mode, http_handler, default_idle_timeout_seconds, null);
    }

    /// Like `initWithHandlerTimeout`, with a per-reactor listener
    /// (SO_REUSEPORT accept path).
    pub fn initWithHandlerListener(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
        idle_timeout_seconds: u32,
        listener: posix.fd_t,
    ) !Reactor {
        return initWithHandlerGroup(allocator, id, mode, http_handler, null, idle_timeout_seconds, listener);
    }

    /// Like `initWithHandlerListener`, with a server group for multi-vhost.
    pub fn initWithHandlerGroup(
        allocator: std.mem.Allocator,
        id: usize,
        mode: Mode,
        http_handler: ?*const runtime_server.Server,
        server_group: ?*const runtime_server.ServerGroup,
        idle_timeout_seconds: u32,
        listener: posix.fd_t,
    ) !Reactor {
        var self = try initWithHandlerTimeout(allocator, id, mode, http_handler, idle_timeout_seconds, server_group);
        self.listener = listener;
        // A listener fd is only registered when this reactor owns one
        // (tests / standalone); shared-listener servers hand accepted fds
        // over through `pushAcceptedFd` instead.
        if (listener >= 0) self.ep.add(listener, epoll.Events.In | epoll.Events.Exclusive, listener) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.upstream_conns.deinit();
            self.upstream_conns.deinit();
            self.pending.deinit(self.allocator);
            self.pending_fds.deinit(self.allocator);
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
        server_group: ?*const runtime_server.ServerGroup,
    ) !Reactor {
        var self = Reactor{
            .allocator = allocator,
            .id = id,
            .mode = mode,
            .ep = try epoll.Epoll.create(),
            .wakeup = try eventfd.EventFd.create(),
            .connections = std.AutoHashMap(posix.fd_t, *connection.Connection).init(allocator),
            .http_sessions = std.AutoHashMap(posix.fd_t, HttpSession).init(allocator),
            .upstream_conns = std.AutoHashMap(posix.fd_t, posix.fd_t).init(allocator),
            .http_handler = http_handler,
            .handler = http_handler orelse &default_http_handler,
            .server_group = server_group,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .pending = .empty,
            .pending_fds = .empty,
            .pending_lock = .{},
            .registered = std.atomic.Value(usize).init(0),
            .idle_timeout_ticks = timer_wheel.default_wheel.tickForNs(@as(u64, idle_timeout_seconds) * std.time.ns_per_s),
            .epoch = compat.Instant.now() catch compat.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
            .wheel = .{},
            .expired_fds = .empty,
            .throttle_fds = .empty,
            .stats = if (mode == .http)
                @constCast((http_handler orelse &default_http_handler).stats)
            else
                null,
            .static_cache = undefined,
            .conn_pool = undefined,
            .drain_started = compat.Instant.now() catch compat.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
        };
        // NOTE: the pool's epoll hook is set on the reactor THREAD (see
        // reactorLoop): the Reactor value is returned/copied by the init
        // chain, so `&self.ep` taken here would point at a dead stack
        // frame.
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
        // Module lifecycle runs once per process (gated inside): modules
        // size their shmem zones from the configured limits here.
        runtime_server.default_registry.initModules(&self.limits);

        errdefer self.ep.close();
        self.ep.add(self.wakeup.fd, epoll.Events.In, self.wakeup.fd) catch {
            self.ep.close();
            self.wakeup.close();
            self.connections.deinit();
            self.http_sessions.deinit();
            self.upstream_conns.deinit();
            self.upstream_conns.deinit();
            self.pending.deinit(self.allocator);
            self.pending_fds.deinit(self.allocator);
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
            self.ep.add(self.listener, epoll.Events.In | epoll.Events.Exclusive, self.listener) catch {
                self.ep.close();
                self.wakeup.close();
                self.connections.deinit();
                self.http_sessions.deinit();
                self.upstream_conns.deinit();
                self.upstream_conns.deinit();
                self.pending.deinit(self.allocator);
            self.pending_fds.deinit(self.allocator);
                return error.ListenerRegisterFailed;
            };
        }
        return self;
    }

    /// The reactor thread must have been stopped and joined before deinit.
    pub fn deinit(self: *Reactor) void {
        proxy_mod.setPoolEpoll(null);
        // Tear down connections while the epoll fd is still open: they deregister
        // via epoll_ctl DEL, which would EBADF-panic on a closed epoll fd.
        self.closeAllConnections();
        if (self.listener >= 0 and !self.shared_listener) compat.close(self.listener);
        self.static_cache.deinit();
        self.conn_pool.deinit();
        self.ring.deinit();
        self.ep.close();
        self.wakeup.close();
        self.connections.deinit();
        self.http_sessions.deinit();
        self.upstream_conns.deinit();
        self.pending.deinit(self.allocator);
        self.pending_fds.deinit(self.allocator);
        self.expired_fds.deinit(self.allocator);
        self.throttle_fds.deinit(self.allocator);
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

    /// Graceful drain stop accepting new connections; the
    /// loop exits once every existing connection has finished (or after
    /// `drain_timeout_ns`). The reactor thread must be joined afterwards.
    pub fn drain(self: *Reactor) void {
        self.draining.store(true, .release);
        self.drain_started = compat.Instant.now() catch compat.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } };
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
            if (self.shared_listener) {
                // Stop accepting on this reactor without closing the socket:
                // sibling reactors still accept from it, and the owning
                // Server closes it once every reactor has detached.
                self.ep.remove(self.listener) catch {};
            } else {
                compat.close(self.listener);
            }
            self.listener = -1;
        }
    }

    /// True once the reactor loop has exited after a drain (polled by the
    /// server to join and free drained reactors).
    pub fn isDrained(self: *const Reactor) bool {
        return self.drained.load(.acquire);
    }

    /// Resolve the active server from the Host header. When server_group is
    /// null or host_select is off, this is a no-op (handler stays the default).
    fn resolveServer(self: *Reactor, host: []const u8) void {
        if (self.server_group) |group| {
            self.handler = group.selectServer(host, null);
            self.stats = self.handler.stats;
        }
    }

    /// Hand a new connection to this reactor. Safe to call from any thread.
    /// Hand an already-accepted connection fd over to this reactor (the
    /// server's acceptor thread accepts from the single shared listener and
    /// round-robins fds, so connection distribution never depends on the
    /// kernel's wakeup choices). The fd is adopted on the reactor thread.
    pub fn pushAcceptedFd(self: *Reactor, fd: posix.fd_t) void {
        if (self.draining.load(.acquire)) {
            compat.close(fd);
            return;
        }
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        self.pending_fds.append(self.allocator, fd) catch {
            compat.close(fd);
            return;
        };
        self.wakeup.write();
    }

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
    // Pooled upstream connections stay registered on this reactor's epoll
    // (pool_tag) so an upstream close is reaped before reuse — nginx's
    // keepalive close-handler model. The hook must point at the reactor's
    // FINAL storage and be set on the thread that owns the pool.
    proxy_mod.setPoolEpoll(&self.ep);
    defer proxy_mod.setPoolEpoll(null);
        sockets.pinToCpu(self.id);
        var events: [max_events]linux.epoll_event = undefined;
        while (self.running.load(.acquire)) {
            self.closeListenerIfRequested();
            if (self.draining.load(.acquire)) {
                if (self.connections.count() == 0) break;
                const now = compat.Instant.now() catch break;
                if (now.since(self.drain_started) > drain_timeout_ns) break;
            }
            self.advanceTimers();
            self.enforceRequestTimeouts();
            self.kickThrottled();
            const loop_t0 = upstreamNowNs();
            // While any connection is rate-limited, wake often enough to
            // refill its byte budget smoothly (the kick list re-drives
            // paused flushes once per loop iteration; a 100 ms idle wait
            // would quantise limit_rate to ~10 refills/second).
            const wait_ms: i32 = if (self.throttle_fds.items.len > 0) 5 else 100;
            const n = self.ep.wait(&events, wait_ms) catch continue;
            _ = loop_t0;
            // Refresh the cached Date after the wait: a request that just
            // woke the loop is handled with a fresh second (stale by the µs
            // of batch processing), instead of up to a second + the wait
            // timeout if the refresh ran before the wait. (nginx refreshes
            // its cached time once per event cycle too; ours is per batch.)
            self.refreshDate();
            for (events[0..n]) |ev| {
                const d: u64 = @intCast(ev.data.ptr);
                if (d & proxy_mod.pool_tag != 0) {
                    // Idle pooled upstream closed by the peer: reap before
                    // the entry is ever reused.
                    proxy_mod.reapPooledFd(@intCast(d & ~proxy_mod.pool_tag));
                    continue;
                }
                if (d & up_tag != 0) {
                    // Upstream fds register as up_tag | client_fd: the
                    // completion event finds the session (and its inline
                    // transaction) without any fd->session lookup.
                    self.handleUpstreamEvent(@intCast(d & ~up_tag));
                } else {
                    const disp_t0 = upstreamNowNs();
                    self.handleEvent(ev.events, @intCast(d));
                    _ = disp_t0;
                }
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
        const ts = compat.clock_gettime(posix.CLOCK.REALTIME) catch return;
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
        const now = compat.Instant.now() catch return 0;
        return timer_wheel.default_wheel.tickForNs(now.since(self.epoch));
    }

    /// Nanoseconds since the reactor epoch (limit_rate bucket clock).
    fn nowNs(self: *const Reactor) u64 {
        const now = compat.Instant.now() catch return 0;
        return now.since(self.epoch);
    }

    /// Shorten the body iov to `take` bytes (limit_rate trimming). The layout
    /// from build_iovs is head?, body, tail? — the body sits right after the
    /// head when both are present.
    fn trimBodyIov(iovs: *[3]posix.iovec_const, count: usize, head_len: usize, take: usize) void {
        if (count == 0) return;
        const idx: usize = if (head_len > 0) 1 else 0;
        if (idx < count) iovs[idx].len = take;
    }

    /// Outcome of one bounded sendfile pass.
    const PumpOutcome = enum {
        done,
        /// EAGAIN: socket not writable (caller waits on EPOLLOUT/POLLOUT).
        wait_io,
        /// Budget spent: already parked on the kick list.
        wait_budget,
        /// Fatal error: connection removed, session dangles.
        gone,
    };

    /// Bounded sendfile pump: at most one limit_rate take per call (the
    /// kick list resumes when the bucket refills; EAGAIN resumes on
    /// EPOLLOUT). Unthrottled sessions behave exactly as the old unbounded
    /// loop. Releases the file fd on full completion (unless cached).
    fn pumpFile(self: *Reactor, fd: posix.fd_t, session: *HttpSession) PumpOutcome {
        var cap = session.file_remaining;
        const throttled = session.rate_bps > 0;
        if (throttled) {
            const take = rateTake(session.rate_bps, &session.rate_allowance, &session.rate_last_ns, self.nowNs(), session.file_remaining);
            if (take == 0) {
                self.parkThrottled(fd, session);
                return .wait_budget;
            }
            cap = take;
        }
        sockets.setTcpCork(fd);
        defer sockets.clearTcpCork(fd);
        var off: i64 = @intCast(session.file_offset);
        const stop_at = session.file_remaining - cap;
        while (session.file_remaining > stop_at) {
            const chunk = @min(session.file_remaining, @min(@as(u64, 1 << 20), session.file_remaining - stop_at));
            const rc = linux.sendfile(fd, session.file_fd, &off, @intCast(chunk));
            const err = linux.errno(rc);
            if (err != .SUCCESS) {
                if (err == .AGAIN or err == .INTR) return .wait_io;
                if (!session.file_fd_cached) compat.close(session.file_fd);
                session.file_fd = -1;
                self.removeConnection(fd);
                return .gone;
            }
            const n = rc;
            session.file_offset += n;
            session.file_remaining -= n;
            off = @intCast(session.file_offset);
        }
        if (session.file_remaining > stop_at) {
            // EAGAIN with budget left (throttled park is then a harmless
            // duplicate of the EPOLLOUT edge).
            if (throttled) self.parkThrottled(fd, session);
            return .wait_io;
        }
        if (session.file_remaining > 0) {
            // Stopped exactly on budget with bytes still unsent (only
            // reachable throttled: unthrottled stop_at is 0).
            self.parkThrottled(fd, session);
            return .wait_budget;
        }
        if (!session.file_fd_cached) compat.close(session.file_fd);
        session.file_fd_cached = false;
        session.file_fd = -1;
        return .done;
    }

    /// Token bucket take: refill `allowance` by elapsed*bps (capped at one
    /// burst: 1 s of budget clamped to [4 KiB, 256 KiB]), take up to `want`.
    /// Pure arithmetic over explicit state so the pacing math is unit-tested
    /// without a reactor.
    /// Fixed-point accumulation: `allowance` is in 1/64-byte units so that
    /// refills at sub-byte granularity (frequent kick iterations) do not
    /// lose their fractional remainder to integer truncation — the old
    /// whole-byte math starved throttled transfers to ~1/4 of the rate.
    fn rateTake(bps: u64, allowance: *i64, last_ns: *u64, now_ns: u64, want: usize) usize {
        if (bps == 0) return want;
        const frac: u64 = 64;
        // The first take sees last_ns == 0 (the full uptime): u128 keeps
        // every product overflow-free for any elapsed/rate combination,
        // and the burst cap below bounds the result.
        const elapsed = now_ns -| last_ns.*;
        last_ns.* = now_ns;
        // Explicit u64: @min/@max with comptime bounds narrow their result
        // type, and the narrowed type would overflow on the * frac below.
        const base: u64 = @max(@min(bps, 1 << 18), 4096);
        const burst: i64 = @intCast(base * frac);
        const refill128 = (@as(u128, elapsed) * @as(u128, bps) * frac) / std.time.ns_per_s;
        const refill: i64 = @intCast(@min(refill128, @as(u128, @intCast(burst))));
        allowance.* = @min(allowance.* + refill, burst);
        const avail: i64 = @divTrunc(allowance.*, @as(i64, @intCast(frac)));
        const take: usize = @intCast(@min(@max(avail, 0), @as(i64, @intCast(want))));
        allowance.* -= @as(i64, @intCast(take)) * @as(i64, @intCast(frac));
        return take;
    }

    /// Latch this response's limit_rate throttle: fresh bucket per response.
    /// last_ns starts at 0 so the first take sees the full elapsed time and
    /// refills to a whole burst — headers + first chunk flow immediately.
    fn latchRate(session: *HttpSession, route: ?*const dsl_registry.Route) void {
        session.rate_bps = if (route) |r| r.limit_rate_bps else 0;
        session.rate_allowance = 0;
        session.rate_last_ns = 0;
        session.throttled = false;
        // throttle_listed is left for the kick loop to reap (self-cleaning).
    }

    /// Park a budget-exhausted session on the kick list (deduped by the
    /// session flag). The loop kick refills it; EPOLLOUT edges may also
    /// refire it sooner.
    fn parkThrottled(self: *Reactor, fd: posix.fd_t, session: *HttpSession) void {
        session.throttled = true;
        if (!session.throttle_listed) {
            session.throttle_listed = true;
            self.throttle_fds.append(self.allocator, fd) catch {
                session.throttle_listed = false;
            };
        }
    }

    /// Refill throttled sessions (limit_rate): budgeted ones resume via
    /// flushHttp; finished, unflagged or stale entries leave the list.
    /// Runs once per loop iteration (after the timer advance).
    fn kickThrottled(self: *Reactor) void {
        if (self.throttle_fds.items.len == 0) return;
        var i: usize = 0;
        while (i < self.throttle_fds.items.len) {
            const fd = self.throttle_fds.items[i];
            const gone = self.connections.get(fd) == null or self.http_sessions.getPtr(fd) == null;
            if (gone) {
                _ = self.throttle_fds.swapRemove(i);
                continue;
            }
            const sess = self.http_sessions.getPtr(fd).?;
            if (!sess.throttle_listed or !sess.throttled or !sess.writing) {
                sess.throttle_listed = false;
                sess.throttled = false;
                _ = self.throttle_fds.swapRemove(i);
                continue;
            }
            self.flushHttp(fd);
            if (self.http_sessions.getPtr(fd)) |s2| {
                if (!s2.throttled or !s2.writing) {
                    s2.throttle_listed = false;
                    s2.throttled = false;
                    _ = self.throttle_fds.swapRemove(i);
                    continue;
                }
            } else {
                _ = self.throttle_fds.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Timer wheel fired an entry: record its connection for teardown. Runs
    /// on the reactor thread inside `advanceTo`; only appends (the wheel may
    /// hold pointers to connections whose destruction must be deferred).
    fn onExpired(self: *Reactor, entry: *timer_wheel.TimerEntry) void {
        const conn: *connection.Connection = @fieldParentPtr("timer", entry);
        self.expired_fds.append(self.allocator, conn.fd) catch {};
    }

    /// Per-request deadlines (slowloris defense; runs at most once per
    /// second): headers must COMPLETE within client_header_timeout_s of the
    /// first byte regardless of activity (dribbling resets the idle timer,
    /// not this); body reads may pause at most client_body_timeout_s.
    fn enforceRequestTimeouts(self: *Reactor) void {
        const hdr_s = self.limits.client_header_timeout_s;
        const body_s = self.limits.client_body_timeout_s;
        if (hdr_s == 0 and body_s == 0) return;
        const now = compat.Instant.now() catch return;

        // At-most-once-per-second gate (wheel ticks are 1s apart).
        const tick = self.nowTick();
        if (tick == self.last_timeout_sweep_tick) return;
        self.last_timeout_sweep_tick = tick;

        var expired: [64]posix.fd_t = undefined;
        var n_expired: usize = 0;
        var it = self.http_sessions.iterator();
        outer: while (it.next()) |kv| {
            const fd = kv.key_ptr.*;
            const sess = kv.value_ptr; // *HttpSession — no giant copies
            if (sess.upgraded or sess.h2 != null or sess.tls != null or sess.writing) continue;
            const first = sess.first_byte_at orelse continue;
            const header_phase = switch (sess.parser.state) {
                .request_line, .headers => true,
                else => false,
            };
            if (header_phase) {
                if (hdr_s == 0) continue;
                if (now.since(first) < hdr_s * std.time.ns_per_s) continue;
            } else {
                if (body_s == 0) continue;
                const last = sess.last_rx_at orelse continue;
                if (now.since(last) < body_s * std.time.ns_per_s) continue;
            }
            if (n_expired < expired.len) {
                expired[n_expired] = fd;
                n_expired += 1;
                continue :outer;
            }
            break;
        }
        for (expired[0..n_expired]) |fd| {
            self.removeConnection(fd);
        }
    }

    /// Queue and flush the HTTP/1.1 interim `100 Continue` line. Tiny
    /// (25 bytes): one immediate send; if the socket buffer is full the
    /// OUT arm flushes it before any final response (which is queued
    /// later, so ordering is preserved).
    fn sendInterimContinue(self: *Reactor, fd: posix.fd_t, conn: *connection.Connection) void {
        _ = conn.send_buf.writeSlice("HTTP/1.1 100 Continue\r\n\r\n");
        _ = conn.send() catch {
            self.removeConnection(fd);
            return;
        };
        if (conn.send_buf.availableRead() > 0) {
            self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
        } else {
            self.markWriting(fd);
        }
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
                self.ep.modify(fd, epoll.Events.In, fd) catch {};
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
            // One read per readiness event (level-triggered, like nginx):
            // with LT the socket re-fires while unread data remains, so the
            // old drain-until-EAGAIN probe (an extra read syscall on every
            // request) is unnecessary.
            {
                const res: ?usize = conn.recv() catch |e| switch (e) {
                    error.WouldBlock => null,
                    // Buffer full: request cannot complete in memory;
                    // processHttp turns this into a 431.
                    error.BufferFull => null,
                    else => {
                        self.removeConnection(fd);
                        return;
                    },
                };
                if (res) |n| {
                    if (n == 0) {
                        self.removeConnection(fd);
                        return;
                    }
                    got_data = true;
                }
            }
            const now_inst = compat.Instant.now() catch null;
            if (got_data) {
                self.rearmTimer(conn);
                if (self.stats) |s| {
                    const session0 = self.http_sessions.getPtr(fd) orelse return;
                    if (session0.stat_state == .waiting) {
                        session0.stat_state = .reading;
                        _ = s.waiting.fetchSub(1, .monotonic);
                        _ = s.reading.fetchAdd(1, .monotonic);
                    }
                }
            }
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (now_inst) |t| {
                if (session.first_byte_at == null) session.first_byte_at = t;
                session.last_rx_at = t;
            }
            if (!session.writing or session.h2 != null) self.processHttp(fd);
        }

        if (events & epoll.Events.Out != 0) {
            const session = self.http_sessions.getPtr(fd) orelse return;
            if (session.writing) self.flushHttp(fd);
            // Level-triggered OUT must be removed once the response is fully
            // written: a writable socket is always reported ready, so a
            // stale OUT arm makes epoll return this fd on EVERY wait — a
            // busy event storm (and the latency tail it causes).
            if (self.connections.get(fd) == null) return;
            const s2 = self.http_sessions.getPtr(fd) orelse return;
            // Disarmed when the response is finished or paused on the rate
            // budget (the throttle kick re-drives it): an armed OUT on a
            // writable socket re-fires on every wait otherwise.
            if ((!s2.writing or s2.throttled) and s2.out_armed) {
                s2.out_armed = false;
                self.ep.modify(fd, epoll.Events.In, fd) catch {};
            }
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
            // PROXY protocol: on opted-in listeners the first bytes are the
            // proxy header — consume before any sniffing (TLS/h2/preface all
            // look past it). Incomplete waits for more bytes; malformed
            // drops the connection (nginx closes it too).
            if (self.proxy_protocol and !session.proxy_consumed) {
                const slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
                switch (proxy_proto.parse(slice)) {
                    .incomplete => return,
                    .invalid => {
                        self.removeConnection(fd);
                        return;
                    },
                    .done => |d| {
                        if (d.ip) |ip| conn.peer_ip = ip;
                        conn.recv_buf.consume(d.consumed);
                        session.proxy_consumed = true;
                    },
                }
            }
            // Framework v2: an upstream transaction is in flight — client
            // bytes stay buffered until it completes.
            if (session.up_active) return;
            // HTTP/1 stops parsing while a response is being flushed (the
            // pipelined request bytes stay buffered); HTTP/2 and TLS must
            // keep reading while writing (h2 control frames; the TLS
            // handshake's client Finished arrives while the flight flushes).
            if (session.writing and session.h2 == null and
                (session.tls == null or session.tls.?.stage() == .application)) return;

            // Upgraded connections left HTTP behind — their bytes are
            // websocket frames now.
            if (session.upgraded) {
                self.processWebsocket(fd);
                return;
            }

            // TLS detection a connection whose first record is a
            // ClientHello (handshake record type 22, legacy version 3.x,
            // handshake type 1) switches to the TLS 1.3 session.
            if (session.tls == null and session.h2 == null) {
                const recv_slice = conn.recv_buf.data[conn.recv_buf.read_pos..conn.recv_buf.write_pos];
                if (recv_slice.len >= 6 and recv_slice[0] == 0x16 and recv_slice[1] == 0x03 and recv_slice[5] == 0x01) {
                    // SNI-based vhost certificate selection: route the
                    // handshake to the server whose server_name matches
                    // the ClientHello's SNI (falls back to the default /
                    // first server with credentials when unmatched).
                    const creds_server = blk: {
                        const group = self.server_group orelse break :blk self.handler;
                        const sni_name = sni_mod.peekServerName(recv_slice) orelse break :blk self.handler;
                        break :blk group.selectServerTls(sni_name);
                    };
                    if (creds_server.tls_creds) |*creds| {
                        session.tls = tls_conn.TlsConn.init(creds);
                        session.tls_plain = buffer_mod.Buffer.fromSlice(&session.tls_plain_data);
                        session.tls_stage = buffer_mod.Buffer.fromSlice(&session.tls_stage_data);
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
                    applyH2StreamCap(&(session.h2.?), self.limits.max_requests);
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
                    // Expect: 100-continue — answer the interim status so
                    // the client starts uploading instead of waiting out
                    // its continue timer (~1 s in curl).
                    if (session.parser.takeContinue()) {
                        self.sendInterimContinue(fd, conn);
                    }
                    // The buffer grows on demand up to max_recv_buf, so a
                    // full buffer is only fatal once growth is exhausted
                    // (header flood or a body beyond the cap); below the cap
                    // the level-triggered read fills more on the next event.
                    if (conn.recv_buf.availableWrite() == 0 and
                        conn.recv_buf.data.len >= conn.max_recv_buf)
                    {
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
                    // Connection upgrade (RFC 6455 §4.2 and friends): on
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
                                if (compat.indexOfIgnoreCase(slot.value, "upgrade") != null) {
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

    /// Park a proxied request: adopt the connected upstream fd, register it
    /// for readability, and stash the transaction on the session.
fn parkUpstream(self: *Reactor, fd: posix.fd_t, ctx: *dsl_pipeline.Context) !void {
        const plan = proxy_mod.takeParked(ctx) orelse return error.NoParkedPlan;
        const conn = self.connections.get(fd) orelse return error.NoConn;
        const session = self.http_sessions.getPtr(fd) orelse return error.NoSession;

        const tx = &session.up_tx;
        // Resume from the parked state, not from scratch: the inline phase
        // may already have sent part (or all) of the request and buffered
        // part of the response. Restarting the send duplicates bytes on the
        // wire (fatal against close-semantics origins) and dropping the
        // buffered reader loses already-consumed response bytes.
        tx.* = .{
            .fd = plan.fd,
            .backend_idx = plan.backend_idx,
            .route = plan.route,
            .state = if (plan.sent < plan.request.len) .sending else .reading,
            .request = plan.request,
            .sent = plan.sent,
            .started_ns = plan.started_ns,
            .offer_sticky = plan.offer_sticky,
            .sticky_name = plan.sticky_name,
            .awaiting_out = plan.awaiting_out,
            .pooled = plan.pooled,
        };
        if (plan.reader_ptr) |rp| tx.reader = rp.*;
        session.up_active = true;
        // Arm only what the resumed state needs: IN|OUT while still
        // sending (level-triggered OUT refires until the send completes),
        // IN-only once reading (an always-armed OUT would busy-spin the
        // event loop on every parked transaction). LT (not ET) on purpose
        // — the origin may answer between connect and this registration.
        const mask: u32 = if (tx.state == .sending)
            epoll.Events.In | epoll.Events.Out
        else
            epoll.Events.In;
        // The epoll tag is -client_fd: the completion event finds the
        // session (and its inline tx) without any lookup.
        self.ep.add(plan.fd, mask, @intCast(@as(u64, @intCast(fd)) | up_tag)) catch |e| {
            session.up_active = false;
            return e;
        };
        _ = conn;
        // NO eager pump here: completing inside park would rewind the
        // request arena (finalizeFlush -> req.reset) while outer frames
        // still hold ParkedPlan/request slices. Level-triggered IN reports
        // already-ready upstreams on the next epoll_wait, costing one
        // loop cycle at most.
    }

    /// Drop a parked transaction (error paths / connection teardown).
    fn dropUpstream(self: *Reactor, session: *HttpSession) void {
        if (!session.up_active) return;
        const tx = &session.up_tx;
        session.up_active = false;
        if (self.io_mode == .epoll) self.ep.remove(tx.fd) catch {};
        compat.close(tx.fd);
        // The client went away, not the backend: release the in-flight
        // slot without touching the passive health counters.
        proxy_mod.upstreamAbandoned(tx.backend_idx);
    }

    /// Drive a parked upstream transaction from an epoll readiness event.
    fn handleUpstreamEvent(self: *Reactor, client_fd: posix.fd_t) void {
        const session = self.http_sessions.getPtr(client_fd) orelse return;
        if (!session.up_active) return;
        const tx = &session.up_tx;
        const up_fd = tx.fd;
        // Transaction deadline: a parked request must finish within 5 s.
        if (upstreamNowNs() -% tx.started_ns > 5 * std.time.ns_per_s) {
            return self.failUpstream(client_fd);
        }
        switch (tx.state) {
            .sending => {
                while (tx.sent < tx.request.len) {
                    const n = compat.write(up_fd, tx.request[tx.sent..]) catch |e| switch (e) {
                        // Yield: arm OUT alongside IN and resume from this
                        // exact byte on the writability event.
                        error.WouldBlock => {
                            tx.awaiting_out = true;
                            if (self.io_mode == .epoll)
                                self.ep.modify(up_fd, epoll.Events.In | epoll.Events.Out, @intCast(@as(u64, @intCast(client_fd)) | up_tag)) catch
                                    return self.failUpstream(client_fd);
                            return;
                        },
                        else => {
                            if (self.retryParkedOnce(client_fd, session, tx)) return;
                            return self.failUpstream(client_fd);
                        },
                    };
                    tx.sent += n;
                }
                tx.state = .reading;
                if (tx.awaiting_out) {
                    tx.awaiting_out = false;
                    if (self.io_mode == .epoll)
                        self.ep.modify(up_fd, epoll.Events.In, @intCast(@as(u64, @intCast(client_fd)) | up_tag)) catch {};
                }
                self.pumpOnce(client_fd, up_fd, session, tx);
            },
            .reading => {
                self.pumpOnce(client_fd, up_fd, session, tx);
            },
        }
    }

    /// Retry a parked transaction once on a FRESH connection when the fd
    /// came from the keepalive pool and the failure happened before any
    /// response byte was consumed. Returns true when the retry is armed
    /// (the transaction stays parked and the caller must not fail it).
    fn retryParkedOnce(self: *Reactor, client_fd: posix.fd_t, session: *HttpSession, tx: *UpTx) bool {
        if (!tx.pooled or tx.retried) return false;
        if (tx.reader.used != 0 or tx.reader.pos != 0) return false;
        tx.retried = true;
        const old_fd = tx.fd;
        if (self.io_mode == .epoll) self.ep.remove(old_fd) catch {};
        compat.close(old_fd);
        const fd = proxy_mod.reconnectUpstream(tx.route, tx.backend_idx) catch return false;
        tx.fd = fd;
        // Resend the request inline (non-blocking fd; the request is small
        // and the fresh kernel buffer accepts it).
        var sent: usize = 0;
        while (sent < tx.request.len) {
            const n = compat.write(fd, tx.request[sent..]) catch {
                compat.close(fd);
                return false;
            };
            sent += n;
        }
        tx.sent = sent;
        tx.state = .reading;
        self.ep.add(fd, epoll.Events.In, @intCast(@as(u64, @intCast(client_fd)) | up_tag)) catch {
            compat.close(fd);
            return false;
        };
        _ = session;
        return true;
    }

    fn pumpOnce(self: *Reactor, client_fd: posix.fd_t, up_fd: posix.fd_t, session: *HttpSession, tx: *UpTx) void {
        const res = tx.reader.read(up_fd) catch |e| switch (e) {
            error.WouldBlock => {
                return;
            },
            else => {
                // A pooled connection the upstream closed while idle shows
                // up as ECONNRESET/EOF on the first read after a request.
                // Retry once on a fresh connection (nginx's upstream
                // keepalive behavior) instead of counting a backend
                // failure and tripping the passive breaker.
                if (self.retryParkedOnce(client_fd, session, tx)) return;
                return self.failUpstream(client_fd);
            },
        };
        session.resp = http_response.Response.init(@enumFromInt(res.status));
        // Ownership contract: every string stored on the response must
        // outlive the flush. Reader slices die with the transaction below,
        // so copy names AND values (plus body) into the request arena.
        const arena_a = session.req.arena.asAllocator();
        for (res.headers) |h| {
            // Parse-time DFA tags from the upstream reader: integer
            // compares instead of hashing every response header name.
            const skip = switch (h.tag) {
                .connection,
                .content_length,
                .transfer_encoding,
                // nginx's default proxy_hide_header set (Date/Server).
                .date,
                .server,
                => true,
                else => false,
            };
            // Same route filters as the inline adopt path: proxy_hide_header
            // drops headers, proxy_redirect rewrites Location/Refresh.
            if (skip or proxy_mod.headerHidden(tx.route, h.name)) continue;
            const value_src = proxy_mod.rewriteAdoptedHeader(tx.route, h.name, h.value, arena_a) orelse h.value;
            const name_c = arena_a.dupe(u8, h.name) catch return self.failUpstream(client_fd);
            const value_c = arena_a.dupe(u8, value_src) catch return self.failUpstream(client_fd);
            session.resp.setHeader(name_c, value_c);
        }
        const body = arena_a.dupe(u8, res.body) catch
            return self.failUpstream(client_fd);
        session.resp.body = body;
        if (tx.offer_sticky and tx.sticky_name.len > 0) {
            var tag_buf: [48]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "{s}=s{d}; Path=/", .{ tx.sticky_name, tx.backend_idx }) catch "";
            if (tag.len > 0) session.resp.setHeader("Set-Cookie", tag);
        }
        // Parked completions bypass the pipeline walk: run the route's
        // response filters AND log-phase handlers (accel, error_page) and
        // follow any internal redirect they ask for (see continueParked).
        self.continueParked(client_fd, session, tx.route);

        latchRate(session, tx.route);
        // upstreamSuccess re-tags the fd for the pool (epoll MOD), so the
        // completion must NOT unregister it: pooled fds stay registered for
        // event-loop close reaping (nginx's keepalive close handler).
        proxy_mod.upstreamSuccess(tx.backend_idx, up_fd, upstreamNowNs(), tx.route);
        session.up_active = false;
        self.finishProxied(client_fd, session);
    }

    /// 502 with keep-alive semantics identical to the synchronous path.
    fn failUpstream(self: *Reactor, client_fd: posix.fd_t) void {
        const session = self.http_sessions.getPtr(client_fd) orelse return;
        if (!session.up_active) return;
        const tx = &session.up_tx;
        // Route pointer stays valid after the transaction dies (routes are
        // static for the server's lifetime); captured for the continuation.
        const route = tx.route;
        latchRate(session, tx.route);
        proxy_mod.upstreamFail(tx.backend_idx, tx.route, upstreamNowNs());
        if (self.io_mode == .epoll) self.ep.remove(tx.fd) catch {};
        compat.close(tx.fd); // failed fds are not pooled
        session.up_active = false;

        session.resp = http_response.Response.init(.bad_gateway);
        session.resp.setBody(http_response.Status.bad_gateway.reasonPhrase());
        // Log handlers may rewrite the 502 (error_page) or redirect
        // internally; standard headers are set after that so a replaced
        // response still carries them.
        self.continueParked(client_fd, session, route);
        session.resp.setHeader("Connection", "keep-alive");
        session.resp.setHeader("Date", self.date_cache[0..self.date_len]);
        session.resp.setHeader("Server", "Zocket/" ++ version_mod.version);
        const conn = self.connections.get(client_fd) orelse return;
        conn.send_buf.compact();
        session.resp.writeHeadToBuffer(&conn.send_buf) catch {
            self.removeConnection(client_fd);
            return;
        };
        session.pending_body = session.resp.body;
        session.pending_body_owned = false;
        session.writing = true;
        self.markWriting(client_fd);
        self.flushHttp(client_fd);
    }

    /// Serialize the adopted response out to the client.
    fn finishProxied(self: *Reactor, client_fd: posix.fd_t, session: *HttpSession) void {
        const close0 = !session.req.keep_alive;
        session.resp.setHeader("Connection", if (close0) "close" else "keep-alive");
        session.resp.setHeader("Date", self.date_cache[0..self.date_len]);
        session.resp.setHeader("Server", "Zocket/" ++ version_mod.version);
        const conn = self.connections.get(client_fd) orelse return;
        conn.send_buf.compact();
        if (session.resp.body_from_file) {
            // An internal redirect (accel/error_page) landed on a static
            // file: same head + sendfile ownership handoff as the main path.
            session.resp.writeHeadToBufferWithLength(&conn.send_buf, session.resp.file_len) catch {
                self.removeConnection(client_fd);
                return;
            };
            session.pending_body = &.{};
            session.file_fd = session.resp.file_fd;
            session.file_fd_cached = session.resp.file_fd_cached;
            session.file_offset = session.resp.file_offset;
            session.file_remaining = if (session.req.method == .head) 0 else session.resp.file_len;
        } else {
            session.resp.writeHeadToBuffer(&conn.send_buf) catch {
                self.removeConnection(client_fd);
                return;
            };
            session.pending_body = session.resp.body;
        }
        session.pending_body_owned = false;
        session.writing = true;
        self.markWriting(client_fd);
        self.flushHttp(client_fd);
    }

    /// Parked completion tail: run the route's response filters and
    /// log-phase handlers (accel, error_page), then follow any internal
    /// redirect they request — the phases the pipeline walk skipped when
    /// the proxy parked. The nested walk runs with the synchronous driver
    /// (async_supported = false): a redirect into another proxied route
    /// cannot park again from this callback, and blocking there is bounded
    /// by the upstream timeouts.
    fn continueParked(self: *Reactor, client_fd: posix.fd_t, session: *HttpSession, route: *const dsl_registry.Route) void {
        var fctx = dsl_pipeline.Context{
            .req = &session.req,
            .resp = &session.resp,
            .route = route,
            .allocator = self.allocator,
            .client_ip = if (self.connections.get(client_fd)) |c| c.peer_ip else .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .stats = self.stats,
            .static_cache = &self.static_cache,
            .limits = &self.limits,
            .formats = self.handler.formats(),
            .started = compat.Instant.now() catch compat.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
            .now_ns = blk: {
                const t = compat.Instant.now() catch break :blk 0;
                break :blk @intCast(t.since(self.epoch));
            },
        };
        dsl_pipeline.applyResponseFilters(route, &fctx) catch {
            session.resp = http_response.Response.init(.internal_error);
            session.resp.setBody(http_response.Status.internal_error.reasonPhrase());
            return;
        };
        dsl_pipeline.runLogHandlers(route, &fctx) catch {
            session.resp = http_response.Response.init(.internal_error);
            session.resp.setBody(http_response.Status.internal_error.reasonPhrase());
            return;
        };
        // Follow internal redirects (accel, error_page). The first hop is
        // applied here so the nested handleRequest starts on the NEW
        // target; further hops are its own loop's business.
        var hops: u8 = 0;
        while ((fctx.internal_redirect_target != null or fctx.internal_redirect_named != null) and hops < 8) {
            hops += 1;
            if (fctx.internal_redirect_target) |target| {
                fctx.internal_redirect_target = null;
                const uri = session.req.arena.asAllocator().dupe(u8, target) catch break;
                session.req.target = uri;
                session.req.decoded_target = uri;
            } else {
                const name = fctx.internal_redirect_named.?;
                fctx.internal_redirect_named = null;
                const named = self.handler.router.matchNamed(name) orelse break;
                fctx.force_route = named;
            }
            fctx.route = null;
            fctx.capture_count = 0;
            fctx.redirect_hops = hops;
            const out = self.handler.handleRequest(&fctx) catch {
                session.resp = http_response.Response.init(.bad_gateway);
                session.resp.setBody(http_response.Status.bad_gateway.reasonPhrase());
                return;
            };
            if (out == .not_handled) {
                session.resp = http_response.Response.init(.not_found);
                session.resp.setBody(http_response.Status.not_found.reasonPhrase());
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
        latchRate(session, null);
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
            // A torn-down connection may hold a counted request (abort or
            // error close): release the `max_requests` slot exactly once.
            if (sess.req_counted) {
                sess.req_counted = false;
                self.in_flight -|= 1;
            }
            if (sess.file_fd >= 0 and !sess.file_fd_cached) compat.close(sess.file_fd);
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
                        _ = compat.write(conn.fd, out[0..m]) catch {};
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
            // limit_rate: trim the body iov to this flush's budget (the
            // completion resubmits the remainder through this same gate).
            if (session.rate_bps > 0 and session.pending_body.len > 0) {
                const take = rateTake(session.rate_bps, &session.rate_allowance, &session.rate_last_ns, self.nowNs(), session.pending_body.len);
                if (take < session.pending_body.len) {
                    trimBodyIov(&session.write_iovs, count, conn.send_buf.availableRead(), take);
                    if (take == 0 and conn.send_buf.availableRead() == 0 and session.file_remaining == 0) {
                        self.parkThrottled(fd, session);
                        return;
                    }
                }
            }
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
        // limit_rate: trim the body iov to this flush's budget (the head
        // and chunked terminator bypass the bucket — framing is tiny).
        var budget_limited = false;
        if (session.rate_bps > 0 and session.pending_body.len > 0) {
            const take = rateTake(session.rate_bps, &session.rate_allowance, &session.rate_last_ns, self.nowNs(), session.pending_body.len);
            budget_limited = take < session.pending_body.len;
            if (budget_limited) trimBodyIov(&iov, count, conn.send_buf.availableRead(), take);
        }
        if (count == 0) {
            // Push any file body straight into the socket (budgeted
            // by limit_rate inside pumpFile).
            if (session.file_remaining > 0) {
                switch (self.pumpFile(fd, session)) {
                    .gone, .wait_budget, .wait_io => return,
                    .done => {},
                }
            }
            if (session.pending_tail.len > 0) {
                // Chunked sendfile route: the terminator flushes now, after
                // the file bytes.
                self.flushHttp(fd);
                return;
            }
            return self.finalizeFlush(fd);
        }
        const n = compat.writev(fd, iov[0..count]) catch |e| {
            if (e == error.WouldBlock) {
                // Budget-exhausted stops park on the kick list (EPOLLOUT
                // alone would stall: no writable transition is coming).
                if (budget_limited) self.parkThrottled(fd, session);
                return;
            }
            self.freeResponseBody(session);
            session.pending_body = &.{};
            session.pending_tail = &.{};
            self.removeConnection(fd);
            return;
        };
        self.advanceHttpWrite(conn, session, n);
        if (session.pending_body.len > 0 or session.pending_tail.len > 0) {
            // Socket buffer full (or budget spent); continue on the next
            // EPOLLOUT edge — or the throttle kick, when budgeted.
            if (budget_limited) self.parkThrottled(fd, session);
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

        // Push any file body straight into the socket (budgeted
        // by limit_rate inside pumpFile).
        if (session.file_remaining > 0) {
            switch (self.pumpFile(fd, session)) {
                .gone, .wait_budget => return,
                .wait_io => {
                    // EAGAIN mid-sendfile (ring): wait for the POLLOUT
                    // completion as before.
                    if (self.io_mode == .ring) {
                        self.ring.submitPollOut(fd) catch {};
                        self.ring.submit() catch {};
                    }
                    return;
                },
                .done => {},
            }
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
        session.throttled = false;
        // Request complete: release its `max_requests` slot.
        if (session.req_counted) {
            session.req_counted = false;
            self.in_flight -|= 1;
        }
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
            self.ep.modify(fd, epoll.Events.In, fd) catch {};
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
        // In-flight request cap (`limits.max_requests`, per reactor/worker):
        // shed new work with 503 once this reactor already holds that many
        // requests. The count runs from parse to the fully-flushed response
        // (including time parked on an upstream), so it bounds concurrent
        // upstream fan-out and per-request memory. Comptime config; the
        // counter is a plain field because one reactor thread owns it.
        const shed = self.limits.max_requests != 0 and self.in_flight >= self.limits.max_requests;
        // Shed requests get a 503 but keep the connection (when the client
        // asked for keep-alive): the request body is already consumed by
        // the parser, so a retry on the same socket costs no reconnect —
        // otherwise sustained shedding turns into a connect storm on the
        // same cores that are already saturated.
        if (!shed and !session.req_counted) {
            session.req_counted = true;
            self.in_flight += 1;
        }
        const close0 = !session.req.keep_alive;
        session.resp = if (shed) blk: {
            var resp = http_response.Response.init(.service_unavailable);
            resp.setBody(http_response.Status.service_unavailable.reasonPhrase());
            break :blk resp;
        } else http_response.Response.init(.ok);
        // Resolve per-request server from Host header when a server group
        // is configured.
        if (session.req.header("host")) |host| {
            self.resolveServer(host);
        }
        const handler = self.handler;
        var ctx = dsl_pipeline.Context{
            .req = &session.req,
            .resp = &session.resp,
            .allocator = self.allocator,
            .client_ip = if (self.connections.get(fd)) |c| c.peer_ip else .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .stats = self.stats,
            .static_cache = &self.static_cache,
            .limits = &self.limits,
            .formats = handler.formats(),
            .subrequest = .{ .impl = handler, .call = runtime_server.Server.subrequestImpl },
            // Parking available on the epoll HTTP path; ring/TLS fronts
            // keep the synchronous upstream driver.
            .async_supported = self.io_mode == .epoll,
            .body_storage = if (session.req.body_storage) |*bs| bs else null,
            .started = compat.Instant.now() catch compat.Instant{ .timestamp = .{ .sec = 0, .nsec = 0 } },
            .now_ns = blk: {
                const t = compat.Instant.now() catch break :blk 0;
                break :blk @intCast(t.since(self.epoch));
            },
        };

        if (!tls_mode and !shed) {
            // Fast path: module-less response-template routes are
            // written straight from their pre-serialised bytes (status line +
            // template headers + Connection + Content-Length + body),
            // byte-identical to the pipeline equivalent but with zero dispatch.
            if (handler.matchFast(&ctx)) |fb| {
                conn.send_buf.compact();
                _ = conn.send_buf.writeSlice(fb.head);
                var hdr_buf: [96]u8 = undefined;
                const hdr = if (close0)
                    std.fmt.bufPrint(&hdr_buf, "Connection: close\r\nContent-Length: {d}\r\n\r\n", .{fb.body.len}) catch unreachable
                else
                    std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{fb.body.len}) catch unreachable;
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
                self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
                return false;
            }
        }

        var request_outcome: dsl_pipeline.Outcome = .not_handled;
        if (!shed) request_outcome = blk: {
            if (!ctx.async_supported) {
                // Synchronous drivers (ring/TLS fronts): modules use the
                // blocking path; no parking possible.
                break :blk handler.handleRequest(&ctx) catch |e| {
                    const st = dsl_registry.statusForModuleError(e);
                    ctx.resp.status = st;
                    ctx.resp.setBody(st.reasonPhrase());
                    self.respondAndClose(fd, st);
                    return false;
                };
            }
            break :blk handler.handleRequest(&ctx) catch |e| switch (e) {
                error.AsyncPending => {
                    self.parkUpstream(fd, &ctx) catch {
                        self.respondAndClose(fd, .internal_error);
                        return false;
                    };
                    return false;
                },
                else => {
                    const st = dsl_registry.statusForModuleError(e);
                    ctx.resp.status = st;
                    ctx.resp.setBody(st.reasonPhrase());
                    self.respondAndClose(fd, st);
                    return false;
                },
            };
        };
        if (request_outcome == .not_handled and !shed) {
            // No module claimed the request (no route matched, a
            // short-circuit, or no module attached): default 404.
            session.resp = http_response.Response.init(.not_found);
            session.resp.setBody(http_response.Status.not_found.reasonPhrase());
        }
        // `return 444;` (nginx): drop the connection without writing a
        // single response byte.
        if (session.resp.status == .no_response) {
            self.removeConnection(fd);
            return false;
        }
        const close = ctx.close_after_write or !session.req.keep_alive;
        // HTTP/1.1 defaults to keep-alive: skip the redundant header
        // (~25 bytes/response saved on the hot path).
        if (close) session.resp.setHeader("Connection", "close");
        // Date and Server are RFC-recommended but cost ~55 bytes/response;
        // include them for non-trivial responses (body, module-set headers,
        // HEAD requests, or connection close) and skip for minimal fast-paths
        // (empty-body echo) to match nginx's echo module behaviour.
        const has_content = session.resp.body.len > 0 or session.resp.body_from_file;
        const is_head_req = session.req.method == .head;
        if (has_content or session.resp.header_count > 0 or close or is_head_req or session.resp.chunked) {
            session.resp.setHeader("Date", self.date_cache[0..self.date_len]);
            session.resp.setHeader("Server", "Zocket/" ++ version_mod.version);
        }
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
        latchRate(session, ctx.route);
        session.writing = true;
        self.flushHttp(fd);
        if (!self.connections.contains(fd)) return false;
        const sess = self.http_sessions.getPtr(fd) orelse return false;
        if (!sess.writing) return true; // flushed fully; next pipelined request
        // Partially flushed: re-arm EPOLLOUT (epoll_ctl MOD
        // re-evaluates readiness, so this delivers the event).
        sess.out_armed = true;
        self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
        return false;
    }

    /// TLS response path the head and body go through the TLS session
    /// (encrypted); the ciphertext lands in the send buffer and flushes like
    /// the plaintext path. Sendfile is disabled over TLS — file bodies are
    /// read into memory (the static content cache covers small files).
    fn handleHttpResponseTls(self: *Reactor, fd: posix.fd_t, close: bool) void {
        const conn = self.connections.get(fd) orelse return;
        const session = self.http_sessions.getPtr(fd) orelse return;
        const tc = &session.tls.?;

        // File bodies: read into memory (no sendfile through TLS).
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
            if (!session.resp.file_fd_cached) compat.close(session.resp.file_fd);
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
            self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
        }
    }

    /// Drive the TLS 1.3 session for `fd` feed the buffered ciphertext,
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
                self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
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
            applyH2StreamCap(&(sess.h2.?), self.limits.max_requests);
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
                // Expect: 100-continue over TLS: encrypt the interim line
                // and flush it before the client uploads.
                if (session.parser.takeContinue()) {
                    const tc = &(session.tls orelse return);
                    const conn = self.connections.get(fd) orelse return;
                    tc.write("HTTP/1.1 100 Continue\r\n\r\n") catch {
                        self.removeConnection(fd);
                        return;
                    };
                    while (true) {
                        const oslice = tc.takeOutSlice();
                        if (oslice.len == 0) break;
                        if (conn.send_buf.availableWrite() < oslice.len) {
                            const grown = conn.send_buf.data.len + oslice.len;
                            if (conn.send_buf.data.len < connection.Connection.max_recv_buffer) {
                                conn.send_buf.grow(self.allocator, @min(connection.Connection.max_recv_buffer, grown)) catch {
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
                    self.flushHttp(fd);
                    if (!self.connections.contains(fd)) return;
                    const s = self.http_sessions.getPtr(fd) orelse return;
                    if (s.writing) {
                        s.out_armed = true;
                        self.ep.modify(fd, epoll.Events.In | epoll.Events.Out, fd) catch {};
                        return;
                    }
                }
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

        // Resolve per-request server from Host header when a server group
        // is configured. h2 frames carry a :authority pseudo-header but the
        // header() API maps it; fall back to the existing handler when absent.
        if (session_p.req.header("host")) |host| {
            self.resolveServer(host);
        }
        var handler = http2_session.Session.Handler{
            .server = self.handler,
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
            // h2 over TLS the frames must be encrypted. The caller
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
        // Error-log line for errors the pipeline never sees
        // (parse failures). Pipeline-visible errors are logged by the
        // error_log module when bound. Severity is .warn for all codes:
        // client-side failures (4xx) and unexpected server errors (5xx) are
        // operational warnings, not application bugs; using .err would
        // increment the test runner's log_err_count and fail tests.
        {
            const code = @intFromEnum(status);
            var ip_buf: [48]u8 = undefined;
            const ip = sockets.fmtIp(conn.peer_ip, &ip_buf);
            std.log.warn("{s} - -> {d} {s}", .{ ip, code, status.reasonPhrase() });
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
        latchRate(session, null);
        session.writing = true;
        self.flushHttp(fd);
    }

    /// Accept from the per-reactor listener (SO_REUSEPORT) and
    /// register each connection directly — no accept loop, no dispatcher, no
    /// eventfd wakeup. While draining (reload-hard handoff) connections
    /// already queued in the accept backlog are still served: dropping them
    /// would reset clients mid-handshake. The listener is closed right after
    /// this batch, so this is bounded to the backlog; connections arriving
    /// after the close go to the sibling listeners (the new daemon).
    fn acceptConnections(self: *Reactor) void {
        // With a shared listener accept exactly ONE connection per
        // readiness event (see `pushAcceptedFd` for the server acceptor
        // path); a private listener drains its whole backlog.
        const accept_one = self.shared_listener;
        while (true) {
            const conn_fd = sockets.acceptNonBlock(self.listener) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return,
            };
            self.adoptAcceptedFd(conn_fd);
            if (accept_one) return;
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
        // Server-level limit_conn: reject if this IP already holds the max
        // number of concurrent connections. Checked AFTER the fd is accepted
        // but BEFORE epoll registration so a rejected connection never
        // consumes an epoll slot or a session slot.
        if (self.limits.server_limit_conn > 0) {
            limit_mod.ensureConnZoneInit();
            const key = limit_mod.hashClientIp(conn.peer_ip);
            var admitted = false;
            {
                limit_mod.conn_zone.mutex.lock();
                defer limit_mod.conn_zone.mutex.unlock();
                if (limit_mod.conn_zone.upsertLocked(key)) |r| {
                    if (!r.existed) {
                        // First connection from this IP: set count and admit.
                        r.slot.active = 1;
                        admitted = true;
                    } else if (r.slot.active < self.limits.server_limit_conn) {
                        r.slot.active += 1;
                        admitted = true;
                    }
                }
                // If upsertLocked returned null, the table is full — fail open
                // (admit) rather than silently dropping connections from IPs
                // we can no longer track.
            }
            if (!admitted) {
                self.dropConnection(conn);
                return;
            }
            conn.server_limit_conn_key = key;
        }
        if (self.io_mode == .ring) {
            // Reads and writes go through the ring: the connection is never
            // epoll-registered.
        } else {
            self.ep.add(conn.fd, epoll.Events.In | epoll.Events.Out, conn.fd) catch {
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
                .req = http_parser.Request.initWithLimits(self.allocator, self.limits.max_headers, self.limits.max_body_spool),
            };
            if (self.http_sessions.put(conn.fd, session)) |_| {} else |_| {
                session.parser.deinit();
                session.req.deinit();
                self.wheel.remove(&conn.timer);
                if (self.io_mode == .epoll) self.ep.remove(conn.fd) catch {};
                _ = self.connections.fetchRemove(conn.fd);
                self.dropConnection(conn);
            }
        }
        if (self.io_mode == .ring and self.resubmit_count < self.resubmit_reads.len) {
            self.resubmit_reads[self.resubmit_count] = conn.fd;
            self.resubmit_count += 1;
            self.ringSubmitReads();
        }
    }

    /// Echo semantics identical to the standalone single-threaded server: whatever was read is
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
                epoll.Events.In | epoll.Events.Out,
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
        var conns: []*connection.Connection = &.{};
        var fds: []posix.fd_t = &.{};
        {
            self.pending_lock.lock();
            defer self.pending_lock.unlock();
            if (self.pending.items.len > 0) {
                conns = self.pending.toOwnedSlice(self.allocator) catch &.{};
            }
            if (self.pending_fds.items.len > 0) {
                fds = self.pending_fds.toOwnedSlice(self.allocator) catch &.{};
            }
        }
        defer self.allocator.free(conns);
        defer self.allocator.free(fds);

        for (conns) |conn| {
            self.registerConnection(conn);
        }
        for (fds) |fd| {
            self.adoptAcceptedFd(fd);
        }
    }

    /// Turn a freshly accepted fd into a registered connection: enforce the
    /// global connection ceiling, set TCP_NODELAY, take a pool slot and
    /// register. Closes the fd when the reactor cannot take it.
    fn adoptAcceptedFd(self: *Reactor, conn_fd: posix.fd_t) void {
        // Global max_connections ceiling: reject before acquiring a pool
        // slot or registering the fd. The ServerStats.active atomic is
        // shared across all reactor threads and already tracks the live
        // connection count; checking it here costs one atomic load.
        if (self.limits.max_connections > 0) {
            if (self.stats) |s| {
                if (s.active.load(.monotonic) >= self.limits.max_connections) {
                    compat.close(conn_fd);
                    return;
                }
            }
        }
        // TCP_NODELAY on accepted connections: nginx (default), Caddy
        // and Bun all enable it; without it the Nagle/delayed-ACK
        // interlock adds ~40 ms stalls to small two-part responses.
        // One setsockopt per connection, amortized over keep-alive.
        sockets.setTcpNoDelay(conn_fd);
        if (self.accepted_counter) |c| _ = c.fetchAdd(1, .monotonic);
        const conn = self.conn_pool.acquire(conn_fd) catch {
            compat.close(conn_fd);
            return;
        };
        conn.peer_ip = sockets.peerIp(conn_fd);
        self.registerConnection(conn);
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
        if (self.http_sessions.getPtr(fd)) |sess| {
            if (sess.up_active) self.dropUpstream(sess);
        }
        if (self.connections.fetchRemove(fd)) |kv| {
            const conn = kv.value;
            // Release the server-level limit_conn slot before dropping.
            if (conn.server_limit_conn_key != 0) {
                limit_mod.conn_zone.mutex.lock();
                defer limit_mod.conn_zone.mutex.unlock();
                if (limit_mod.conn_zone.upsertLocked(conn.server_limit_conn_key)) |r| {
                    if (r.slot.active > 0) r.slot.active -= 1;
                }
            }
            // Unlink the idle timer so the wheel never points at freed memory.
            self.wheel.remove(&conn.timer);
            if (self.io_mode == .epoll) self.ep.remove(fd) catch {};
            self.dropConnection(conn);
        }
        if (self.http_sessions.fetchRemove(fd)) |kv| {
            var sess = kv.value;
            // A torn-down connection may hold a counted request (abort or
            // error close): release the `max_requests` slot exactly once.
            if (sess.req_counted) {
                sess.req_counted = false;
                self.in_flight -|= 1;
            }
            if (sess.file_fd >= 0 and !sess.file_fd_cached) compat.close(sess.file_fd);
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
                        _ = compat.write(fd, out[0..m]) catch {};
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
            if (s.file_fd >= 0 and !s.file_fd_cached) compat.close(s.file_fd);
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
    const start = compat.Instant.now() catch return error.Timeout;
    while (total < expected_len) {
        if ((compat.Instant.now() catch return error.Timeout).since(start) > timeout_ms * std.time.ns_per_ms) {
            return error.Timeout;
        }
        // Read at most the remaining need; the socket may deliver more (e.g.
        // the next pipelined response) and the leftover stays buffered.
        const n = posix.read(sock, buf[total..expected_len]) catch {
            compat.nanosleep(0, 1 * std.time.ns_per_ms);
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
        const n = compat.write(sock, remaining) catch |e| {
            // A closed peer (EPIPE/ECONNRESET) must surface, not retry forever.
            if (e == error.WouldBlock) {
                compat.nanosleep(0, 1 * std.time.ns_per_ms);
                continue;
            }
            return e;
        };
        remaining = remaining[n..];
    }
}

test "reactor startup and shutdown" {
    std.testing.log_level = .err;
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .echo);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
    const pair2 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair2[0]);
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
    std.testing.log_level = .err;
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
                const pair = compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    return;
                };
                sockets.setNonBlock(pair[0]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    compat.close(pair[0]);
                    compat.close(pair[1]);
                    return;
                };
                sockets.setNonBlock(pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    compat.close(pair[0]);
                    compat.close(pair[1]);
                    return;
                };
                const conn = connection.Connection.create(p.alloc, pair[1]) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    compat.close(pair[0]);
                    compat.close(pair[1]);
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
                    compat.close(pair[0]);
                    return;
                };
                var echo_buf: [96]u8 = undefined;
                _ = readUntil(pair[0], &echo_buf, payload.len, 5000) catch {
                    _ = p.failures.fetchAdd(1, .monotonic);
                    compat.close(pair[0]);
                    return;
                };
                compat.close(pair[0]);
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

/// Runtime-built 200-empty response — no Date/Server for empty-body
/// echo (matches the reactor's fast-path that skips redundant headers).
fn httpOkEmpty(_: []u8) []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
}

/// Expected "Date: ...\r\nServer: Zocket\r\n" for the current wall
/// second (the reactor caches the date and refreshes it once per second).
fn testDateLine(buf: []u8) []const u8 {
    const ts = compat.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
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

test "slowloris: dribbling headers still dies at the header deadline" {
    std.testing.log_level = .err;
    // The idle timer resets on every byte; the HEADER deadline does not.
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    r.limits.client_header_timeout_s = 1;
    r.limits.client_body_timeout_s = 0;
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Dribble one byte every 200ms for ~1.2s: activity keeps the idle
    // timer happy, but headers must complete within 1s total.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try writeAll(pair[0], "G");
        compat.nanosleep(0, 200 * std.time.ns_per_ms);
        if (i >= 4) {
            // By now the deadline has passed; expect the server to hang up.
            var buf: [64]u8 = undefined;
            if (readUntil(pair[0], &buf, 1, 400)) |n| {
                try testing.expectEqual(@as(usize, 0), n); // EOF == closed
            } else |e| {
                try testing.expectEqual(error.Eof, e);
            }
            return; // deadline enforced: test complete
        }
    }
    return error.HeaderDeadlineNotEnforced;
}

test "body inactivity gap closes the connection (client_body_timeout)" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    r.limits.client_header_timeout_s = 0;
    r.limits.client_body_timeout_s = 1;
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Headers complete, body stalls mid-stream.
    try writeAll(pair[0], "POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 100\r\n\r\nab");
    var buf: [64]u8 = undefined;
    const res = readUntil(pair[0], &buf, 1, 2500);
    try testing.expectError(error.Eof, res);
}

test "reactor upgrades to websocket and echoes frames after the 101" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
    std.testing.log_level = .err;
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

        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
    const want2 = std.fmt.bufPrint(&want_buf_want2, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 5" ++ "\r\n\r\n" ++ "hello", .{testDateLine(&date_buf_want2)}) catch unreachable;
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
    const want_a = std.fmt.bufPrint(&want_buf_want_a, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 1" ++ "\r\n\r\n" ++ "A", .{testDateLine(&date_buf_want_a)}) catch unreachable;
    var date_buf_want_b: [96]u8 = undefined;
    var want_buf_want_b: [512]u8 = undefined;
    const want_b = std.fmt.bufPrint(&want_buf_want_b, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 1" ++ "\r\n\r\n" ++ "B", .{testDateLine(&date_buf_want_b)}) catch unreachable;
    const n1 = try readUntil(pair[0], &buf, want_a.len, 3000);
    try testing.expectEqualStrings(want_a, buf[0..n1]);
    const n2 = try readUntil(pair[0], &buf, want_b.len, 3000);
    try testing.expectEqualStrings(want_b, buf[0..n2]);
}

test "limits.max_requests lowers the h2 concurrent-stream ceiling" {
    const httpx = struct {
        const h2 = @import("../http2/session.zig");
    };
    var s = httpx.h2.Session.init(testing.allocator);
    defer s.deinit();
    // Unconfigured: the protocol default stays.
    applyH2StreamCap(&s, 0);
    try testing.expectEqual(@as(u32, 100), s.max_streams);
    // Configured: the session advertises/enforces the configured cap.
    applyH2StreamCap(&s, 25);
    try testing.expectEqual(@as(u32, 25), s.max_streams);
    // A cap above the default does not raise it.
    applyH2StreamCap(&s, 500);
    try testing.expectEqual(@as(u32, 25), s.max_streams);
}

test "reactor max_requests sheds with 503 at the cap and releases the slot" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.limits.max_requests = 1;
    try r.start();
    defer r.join();
    defer r.stop();

    // At the cap: the next request is shed immediately with 503 + close and
    // is never counted.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);
        r.in_flight = 1; // one request already in flight on this reactor
        try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        var buf: [512]u8 = undefined;
        const n = try readUntil(pair[0], &buf, 64, 3000);
        try testing.expect(std.mem.indexOf(u8, buf[0..n], "503 Service Unavailable") != null);
        // Keep-alive shed: no Connection: close on the response.
        try testing.expect(std.mem.indexOf(u8, buf[0..n], "Connection: close") == null);
        try testing.expectEqual(@as(usize, 1), r.in_flight);
    }
    // Below the cap: a normal request completes and releases its slot.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);
        r.in_flight = 0;
        try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        var buf: [512]u8 = undefined;
        // Empty-body echo takes the minimal fast path (no Date/Server).
        const want = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
        const n = try readUntil(pair[0], &buf, want.len, 3000);
        try testing.expectEqualStrings(want, buf[0..n]);
        // The release happens on the reactor thread just before the next
        // loop turn; allow it a moment to land.
        var spins: usize = 0;
        while (r.in_flight != 0 and spins < 200) : (spins += 1) {
            compat.nanosleep(0, std.time.ns_per_ms);
        }
        try testing.expectEqual(@as(usize, 0), r.in_flight);
    }
}

test "reactor HTTP error paths respond and close" {
    std.testing.log_level = .err;
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

        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
        compat.nanosleep(0, 5 * std.time.ns_per_ms);
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // 64 KiB body: larger than the 16 KiB default buffer, so the receive
    // path must grow it (in steps) before the request can complete. Before
    // the buffer-growth fix this request was rejected with 431 (buffer full,
    // request incomplete) — this test locks in the 200 + full-body echo.
    const body_len = 64 * 1024;
    var body: [body_len]u8 = @splat(@as(u8, 'z'));
    var wire_buf: [body_len + 128]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body_len, body }) catch unreachable;

    var sent: usize = 0;
    while (sent < wire.len) : (sent += 4096) {
        try writeAll(pair[0], wire[sent..@min(sent + 4096, wire.len)]);
        compat.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    var date_buf_head: [96]u8 = undefined;
    var want_buf_head: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&want_buf_head, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 65536" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_head)}) catch unreachable;
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
    std.testing.log_level = .err;
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

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Matched route: echo module answers with the request body.
    try writeAll(pair[0], "POST /only HTTP/1.1\r\nContent-Length: 4\r\n\r\necho");
    var buf: [512]u8 = undefined;
    var date_buf_want_echo: [96]u8 = undefined;
    var want_buf_want_echo: [512]u8 = undefined;
    const want_echo = std.fmt.bufPrint(&want_buf_want_echo, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 4" ++ "\r\n\r\n" ++ "echo", .{testDateLine(&date_buf_want_echo)}) catch unreachable;
    const n1 = try readUntil(pair[0], &buf, want_echo.len, 3000);
    try testing.expectEqualStrings(want_echo, buf[0..n1]);

    // No route matches: default 404, connection stays alive.
    try writeAll(pair[0], "GET /elsewhere HTTP/1.1\r\n\r\n");
    var date_buf_want_404: [96]u8 = undefined;
    var want_buf_want_404: [512]u8 = undefined;
    const want_404 = std.fmt.bufPrint(&want_buf_want_404, "HTTP/1.1 404 Not Found\r\n" ++ "" ++ "{s}" ++ "Content-Length: 9" ++ "\r\n\r\n" ++ "Not Found", .{testDateLine(&date_buf_want_404)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want_404.len, 3000);
    try testing.expectEqualStrings(want_404, buf[0..n2]);

    r.stop();
    r.join();
}

test "reactor HEAD responds with head only and correct Content-Length" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // HEAD on a path the echo module answers with an empty body.
    try writeAll(pair[0], "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 0" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want)}) catch unreachable;
    var buf: [512]u8 = undefined;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    // HEAD on a POST-shaped path: Content-Length must reflect the would-be
    // body, but no body bytes may follow the head.
    try writeAll(pair[0], "HEAD /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var date_buf_want2b: [96]u8 = undefined;
    var want_buf_want2b: [512]u8 = undefined;
    const want2b = std.fmt.bufPrint(&want_buf_want2b, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 5" ++ "\r\n\r\n" ++ "", .{testDateLine(&date_buf_want2b)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want2b.len, 3000);
    try testing.expectEqualStrings(want2b, buf[0..n2]);
    // The echoed body must NOT be sent: a short read window yields nothing.
    try testing.expectError(error.Timeout, readUntil(pair[0], &buf, 1, 500));

    r.stop();
    r.join();
}

// A module-less response-template route is served from pre-serialised
// bytes, byte-identical to the pipeline equivalent.
test "reactor serves a comptime template route from pre-serialised bytes" {
    std.testing.log_level = .err;
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

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    var buf: [512]u8 = undefined;
    const want = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    // Redirect template with a header.
    try writeAll(pair[0], "GET /old HTTP/1.1\r\nHost: x\r\n\r\n");
    const want2 = "HTTP/1.1 301 Moved Permanently\r\nLocation: /health\r\nContent-Length: 0\r\n\r\n";
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
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    var buf: [512]u8 = undefined;
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Content-Length: 11" ++ "\r\n\r\n" ++ "hello world", .{testDateLine(&date_buf_want)}) catch unreachable;
    const n = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n]);

    r.stop();
    r.join();
}

test "reactor serves a chunked response when the route opts in" {
    std.testing.log_level = .err;
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

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // POST /chunked: echo body framed as a single chunk.
    try writeAll(pair[0], "POST /chunked HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var buf: [512]u8 = undefined;
    var date_buf_want: [96]u8 = undefined;
    var want_buf_want: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf_want, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "5\r\nhello\r\n0\r\n\r\n", .{testDateLine(&date_buf_want)}) catch unreachable;
    const n1 = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n1]);

    // GET with an empty body: empty-chunk framing only.
    try writeAll(pair[0], "GET /chunked HTTP/1.1\r\n\r\n");
    var date_buf_want2: [96]u8 = undefined;
    var want_buf_want2: [512]u8 = undefined;
    const want2 = std.fmt.bufPrint(&want_buf_want2, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "0\r\n\r\n", .{testDateLine(&date_buf_want2)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want2.len, 3000);
    try testing.expectEqualStrings(want2, buf[0..n2]);

    // HEAD: same head as GET, no framing bytes.
    try writeAll(pair[0], "HEAD /chunked HTTP/1.1\r\n\r\n");
    var date_buf_want3: [96]u8 = undefined;
    var want_buf_want3: [512]u8 = undefined;
    const want3 = std.fmt.bufPrint(&want_buf_want3, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "0\r\n\r\n", .{testDateLine(&date_buf_want3)}) catch unreachable;
    const n3 = try readUntil(pair[0], &buf, want3.len, 3000);
    try testing.expectEqualStrings(want3, buf[0..n3]);

    // Chunked request into the chunked route: assembled then re-framed.
    try writeAll(pair[0], "POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n");
    var date_buf_want4: [96]u8 = undefined;
    var want_buf_want4: [512]u8 = undefined;
    const want4 = std.fmt.bufPrint(&want_buf_want4, "HTTP/1.1 200 OK\r\n" ++ "" ++ "{s}" ++ "Transfer-Encoding: chunked\r\n\r\n" ++ "6\r\nabcdef\r\n0\r\n\r\n", .{testDateLine(&date_buf_want4)}) catch unreachable;
    const n4 = try readUntil(pair[0], &buf, want4.len, 3000);
    try testing.expectEqualStrings(want4, buf[0..n4]);

    r.stop();
    r.join();
}
// wheel's tick granularity is 100 ms, so deadlines land within ~100 ms of the
// nominal second (the loop re-advances the wheel before every epoll_wait,
// timeout 100 ms). Sleeps below leave generous margins on both sides of every
// deadline.
// Idle timeout. A 1 s timeout is used so the tests finish quickly; the
// wheel's tick granularity is 100 ms, so deadlines land within ~100 ms of the
// nominal second (the loop re-advances the wheel before every epoll_wait,
// timeout 100 ms). Sleeps below leave generous margins on both sides of every
// deadline.
test "reactor closes a connection that goes idle" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 1, null);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // No traffic at all: the reactor expires the connection ~1 s after it was
    // registered. EOF (error.Eof) proves the close; Timeout would mean the
    // timer never fired.
    compat.nanosleep(2, 0);
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 1000));

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), r.countConnections());
}

test "reactor resets the idle timer on active traffic" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 1, null);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
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
    compat.nanosleep(0, 500 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var ok_buf_2: [160]u8 = undefined;
    const http_ok_empty_2 = httpOkEmpty(&ok_buf_2);
    const n2 = try readUntil(pair[0], &buf, http_ok_empty_2.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_2, buf[0..n2]);

    // Request 3 *after* the original ~1 s deadline: answered, which proves the
    // timer was re-armed (without rearming the connection would already be
    // closed and this write would fail).
    compat.nanosleep(0, 600 * std.time.ns_per_ms);
    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var ok_buf_3: [160]u8 = undefined;
    const http_ok_empty_3 = httpOkEmpty(&ok_buf_3);
    const n3 = try readUntil(pair[0], &buf, http_ok_empty_3.len, 3000);
    try testing.expectEqualStrings(http_ok_empty_3, buf[0..n3]);

    // Idle again past the re-armed deadline (~2.5 s): now it does expire.
    compat.nanosleep(2, 0);
    try testing.expectError(error.Eof, readUntil(pair[0], &buf, 1, 1000));

    r.stop();
    r.join();
    try testing.expectEqual(@as(usize, 0), r.countConnections());
}

test "idle timeout of zero disables reaping" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.initWithHandlerTimeout(allocator, 0, .http, null, 0, null);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Well past any plausible 1 s window: the connection must still be alive.
    compat.nanosleep(2, 0);
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

// ---- framework v2 driver unit tests (deterministic socketpair origin) ----

test "upstream driver sends parked request and adopts response" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const cpair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(cpair[0]);

    const sess_local = HttpSession{
        .parser = http_parser.Parser.init(allocator),
        .req = http_parser.Request.init(allocator),
    };
    // Register under the client fd so the driver's session lookup succeeds
    // (same contract as production).
    try r.http_sessions.put(cpair[1], sess_local);
    // Always refetch: map storage can move.
    const sess = r.http_sessions.getPtr(cpair[1]).?;
    // The arena-backed body adoption needs a live request arena.
    sess.req.arena = @import("../http/arena.zig").Arena.init(allocator);
    sess.up_active = false;
    var route = dsl_registry.Route{ .path = "/", .match = .prefix };
    sess.route_ptr_for_test = &route;
    defer {
        if (r.http_sessions.getPtr(cpair[1])) |s2| {
            s2.parser.deinit();
            s2.req.deinit();
        }
        _ = r.http_sessions.remove(cpair[1]);
    }
    try r.connections.put(cpair[1], try connection.Connection.create(allocator, cpair[1]));

    // Pre-stage the origin response so the single drive completes
    // send->read->adopt without hitting the bounded wait.
    _ = try compat.write(pair[1], "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nX-Mid: mid\r\n\r\nhi");

    var rt_buf: [16 * 1024]u8 = undefined;
    sess.up_tx = .{
        .fd = pair[0],
        .backend_idx = 0,
        .route = sess.route_ptr_for_test.?,
        .state = .sending,
        .request = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n",
        .reader = proxy_mod.UpstreamReader.initBuf(&rt_buf),
        .offer_sticky = false,
        .sticky_name = "",
        .started_ns = upstreamNowNs(),
    };
    sess.up_active = true;

    r.handleUpstreamEvent(cpair[1]);

    // Origin received the exact parked request.
    var buf: [128]u8 = undefined;
    const n = try posix.read(pair[1], &buf);
    try testing.expectEqualStrings("GET /x HTTP/1.1\r\nHost: t\r\n\r\n", buf[0..n]);

    // Response adopted; the inline transaction is retired.
    try testing.expect(!sess.up_active);
    try testing.expectEqual(http_response.Status.ok, sess.resp.status);
    try testing.expectEqualStrings("hi", sess.resp.body);
    var saw_ct = false;
    var saw_mid = false;
    for (sess.resp.headers[0..sess.resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) saw_ct = true;
        if (std.ascii.eqlIgnoreCase(h.name, "X-Mid")) saw_mid = true;
    }
    try testing.expect(saw_ct and saw_mid);
}

test "max_connections: active counter tracks registered connections" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.limits.max_connections = 2;
    try r.start();
    defer r.join();
    defer r.stop();

    // Attach two connections — both go through registerConnection which
    // bumps stats.active.
    const pair1 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair1[0]);
    try sockets.setNonBlock(pair1[0]);
    try sockets.setNonBlock(pair1[1]);
    const conn1 = try connection.Connection.create(allocator, pair1[1]);
    r.attach(conn1);
    compat.nanosleep(0, 50 * std.time.ns_per_ms);

    const pair2 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair2[0]);
    try sockets.setNonBlock(pair2[0]);
    try sockets.setNonBlock(pair2[1]);
    const conn2 = try connection.Connection.create(allocator, pair2[1]);
    r.attach(conn2);
    compat.nanosleep(0, 50 * std.time.ns_per_ms);

    // Both registered: countConnections reflects the map size.
    try testing.expectEqual(@as(usize, 2), r.countConnections());
}

test "max_connections: accept path rejects when active >= limit" {
    std.testing.log_level = .err;
    // The accept-path check is: if (s.active.load() >= limits.max_connections)
    // close the fd. This is a single atomic comparison in acceptConnections.
    // Full integration coverage comes from the bench suite.
    // Here we verify the config field propagates correctly.
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.limits.max_connections = 42;
    try testing.expectEqual(@as(usize, 42), r.limits.max_connections);
    r.limits.max_connections = 0;
    try testing.expectEqual(@as(usize, 0), r.limits.max_connections);
}

test "server_limit_conn: per-IP concurrent cap enforced via attach" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.limits.server_limit_conn = 2;
    try r.start();
    defer r.join();
    defer r.stop();

    // Attach two connections — both should be admitted.
    const pair1 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair1[0]);
    try sockets.setNonBlock(pair1[0]);
    try sockets.setNonBlock(pair1[1]);
    var conn1 = try connection.Connection.create(allocator, pair1[1]);
    conn1.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
    r.attach(conn1);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);

    const pair2 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair2[0]);
    try sockets.setNonBlock(pair2[0]);
    try sockets.setNonBlock(pair2[1]);
    var conn2 = try connection.Connection.create(allocator, pair2[1]);
    conn2.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
    r.attach(conn2);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);

    try testing.expectEqual(@as(usize, 2), r.countConnections());

    // Third connection from the same IP should be rejected.
    const pair3 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair3[0]);
    try sockets.setNonBlock(pair3[0]);
    try sockets.setNonBlock(pair3[1]);
    var conn3 = try connection.Connection.create(allocator, pair3[1]);
    conn3.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
    r.attach(conn3);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);

    // Exactly 2 connections: third was rejected.
    try testing.expectEqual(@as(usize, 2), r.countConnections());
}

test "server_limit_conn: different IPs tracked independently" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.limits.server_limit_conn = 1;
    try r.start();
    defer r.join();
    defer r.stop();

    // IP A: first connection admitted.
    const p1 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(p1[0]);
    try sockets.setNonBlock(p1[0]);
    try sockets.setNonBlock(p1[1]);
    var c1 = try connection.Connection.create(allocator, p1[1]);
    c1.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
    r.attach(c1);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), r.countConnections());

    // IP A: second connection rejected (limit = 1).
    const p2 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(p2[0]);
    try sockets.setNonBlock(p2[0]);
    try sockets.setNonBlock(p2[1]);
    var c2 = try connection.Connection.create(allocator, p2[1]);
    c2.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
    r.attach(c2);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), r.countConnections());

    // IP B: admitted (different IP, independent counter).
    const p3 = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(p3[0]);
    try sockets.setNonBlock(p3[0]);
    try sockets.setNonBlock(p3[1]);
    var c3 = try connection.Connection.create(allocator, p3[1]);
    c3.peer_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 2 };
    r.attach(c3);
    compat.nanosleep(0, 30 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 2), r.countConnections());
}

/// Fake keepalive upstream for parked-proxy tests (mirrors the one in
/// proxy.zig's tests; duplicated so reactor tests don't depend on
/// module-test internals).
const TestUpstream = struct {
    listener: posix.fd_t,
    port: u16,
    response: []const u8,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(response: []const u8) !*TestUpstream {
        const self = try testing.allocator.create(TestUpstream);
        const lfd = try compat.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        try compat.bind(lfd, @ptrCast(&addr), 16);
        try compat.listen(lfd, 8);
        var slen: posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try compat.getsockname(lfd, @ptrCast(&bound), &slen);
        self.* = .{
            .listener = lfd,
            .port = (@as(u16, bound[2]) << 8) | bound[3],
            .response = response,
        };
        self.thread = try std.Thread.spawn(.{}, runFn, .{self});
        return self;
    }

    fn runFn(self: *TestUpstream) void {
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]posix.pollfd{.{ .fd = self.listener, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&pfds, 100) catch break;
            if (ready == 0) continue;
            const cfd = linux.accept4(self.listener, null, null, 0);
            if (linux.errno(cfd) != .SUCCESS) break;
            const fd: posix.fd_t = @intCast(cfd);
            while (!self.stop_flag.load(.acquire)) {
                var rpfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
                const rready = posix.poll(&rpfds, 1000) catch break;
                if (rready == 0) break;
                var req_buf: [4096]u8 = undefined;
                var used: usize = 0;
                var complete = false;
                while (used < req_buf.len) {
                    const n = posix.read(fd, req_buf[used..]) catch break;
                    if (n == 0) break;
                    used += n;
                    if (std.mem.indexOf(u8, req_buf[0..used], "\r\n\r\n") != null) {
                        complete = true;
                        break;
                    }
                }
                if (!complete) break;
                _ = compat.write(fd, self.response) catch break;
            }
            compat.close(fd);
        }
    }

    fn stop(self: *TestUpstream) void {
        self.stop_flag.store(true, .release);
        compat.close(self.listener);
        self.thread.join();
        testing.allocator.destroy(self);
    }
};

/// Read a full response head (through \r\n\r\n) then the Content-Length
/// body. Returns head_len and body_len.
fn readHeadBody(sock: posix.fd_t, buf: []u8) !struct { head_len: usize, body_len: usize } {
    var total: usize = 0;
    const start = compat.Instant.now() catch return error.Timeout;
    while (true) {
        if ((compat.Instant.now() catch return error.Timeout).since(start) > 8000 * std.time.ns_per_ms) {
            return error.Timeout;
        }
        if (total >= buf.len) return error.TooLong;
        const n = posix.read(sock, buf[total .. total + 1]) catch {
            compat.nanosleep(0, 1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return error.Eof;
        total += n;
        if (total >= 4 and std.mem.eql(u8, buf[total - 4 .. total], "\r\n\r\n")) break;
    }
    // Minimal Content-Length scan of the head.
    var body_len: usize = 0;
    var i: usize = 0;
    const head = buf[0..total];
    const cl = "Content-Length:";
    while (i + cl.len < head.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(head[i .. i + cl.len], cl)) {
            var j = i + cl.len;
            while (j < head.len and (head[j] == ' ' or head[j] == '\t')) j += 1;
            var k = j;
            while (k < head.len and head[k] >= '0' and head[k] <= '9') k += 1;
            body_len = std.fmt.parseInt(usize, head[j..k], 10) catch 0;
            break;
        }
    }
    if (body_len > 0) {
        const n = try readUntil(sock, buf[total..], body_len, 5000);
        if (n < body_len) return error.Eof;
        total += n;
    }
    return .{ .head_len = total - body_len, .body_len = body_len };
}

test "reactor parked proxy completes through epoll events" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const up = try TestUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Up: 1\r\n\r\nhello");
    defer up.stop();

    const router_mod = @import("../dsl/router.zig");
    var ups = [_]router_mod.Upstream{.{
        .host = "127.0.0.1",
        .port = up.port,
        .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", up.port).?,
    }};
    const bindings = [_]router_mod.ModuleBinding{.{ .phase = .rewrite, .module = "proxy" }};
    const routes = [_]router_mod.Route{.{
        .path = "/",
        .modules = &bindings,
        .upstreams = &ups,
    }};
    var proxy_srv = runtime_server.Server.init(.{ .routes = &routes });
    proxy_mod.testResetRoute(&routes[0]);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &proxy_srv;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /proxied/x HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));
    try testing.expectEqualStrings("hello", buf[res.head_len..][0..res.body_len]);
}

test "reactor parked proxy to a dead upstream yields 502" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    // Reserve-then-close a port so nothing listens on it.
    const lfd = try compat.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try compat.bind(lfd, @ptrCast(&addr), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try compat.getsockname(lfd, @ptrCast(&bound), &slen);
    const dead_port = (@as(u16, bound[2]) << 8) | bound[3];
    compat.close(lfd);

    const router_mod = @import("../dsl/router.zig");
    var ups = [_]router_mod.Upstream{.{
        .host = "127.0.0.1",
        .port = dead_port,
        .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", dead_port).?,
    }};
    const bindings = [_]router_mod.ModuleBinding{.{ .phase = .rewrite, .module = "proxy" }};
    const routes = [_]router_mod.Route{.{
        .path = "/",
        .modules = &bindings,
        .upstreams = &ups,
        .max_fails = 1000000,
    }};
    var proxy_srv = runtime_server.Server.init(.{ .routes = &routes });
    proxy_mod.testResetRoute(&routes[0]);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &proxy_srv;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET / HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 502 Bad Gateway"));
}

test "reactor PROXY protocol sets the client IP before access checks" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location / {
        \\        content echo;
        \\        allow 203.0.113.9;
        \\        deny all;
        \\    }
        \\}
    );
    const srv = runtime_server.Server.init(cfg);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    r.proxy_protocol = true;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Claimed 203.0.113.9 matches `allow` -> echo answers 200.
    try writeAll(pair[0], "PROXY TCP4 203.0.113.9 10.0.0.1 1234 80\r\nGET / HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));

    // Same connection, second request without a new header: the header is
    // consumed exactly once (keep-alive continues as plain HTTP).
    try writeAll(pair[0], "GET /again HTTP/1.1\r\nHost: test\r\n\r\n");
    const res2 = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res2.head_len], "HTTP/1.1 200 OK"));
}

test "reactor PROXY protocol denies unlisted sources and drops garbage" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location / {
        \\        content echo;
        \\        allow 203.0.113.9;
        \\        deny all;
        \\    }
        \\}
    );
    const srv = runtime_server.Server.init(cfg);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    r.proxy_protocol = true;
    try r.start();
    defer r.join();
    defer r.stop();

    // Unlisted source IP: header parses, access denies -> 403.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);
        try writeAll(pair[0], "PROXY TCP4 198.51.100.7 10.0.0.1 1234 80\r\nGET / HTTP/1.1\r\nHost: test\r\n\r\n");
        var buf: [4096]u8 = undefined;
        const res = try readHeadBody(pair[0], &buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 403 Forbidden"));
    }
    // Garbage where the header belongs: connection dropped, EOF, no reply.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);
        try writeAll(pair[0], "GARBAGE BYTES\r\n");
        var buf: [4096]u8 = undefined;
        const res = readHeadBody(pair[0], &buf);
        try testing.expectError(error.Eof, res);
    }
}

test "rateTake paces takes against elapsed time with a burst cap" {
    // Unlimited: everything flows.
    {
        var allow: i64 = 0;
        var last: u64 = 0;
        try testing.expectEqual(@as(usize, 100000), Reactor.rateTake(0, &allow, &last, 1000, 100000));
    }
    // First take refills to a full burst (1 s of budget, clamped).
    {
        var allow: i64 = 0;
        var last: u64 = 0;
        const bps: u64 = 10_000;
        try testing.expectEqual(@as(usize, 10000), Reactor.rateTake(bps, &allow, &last, 5 * std.time.ns_per_s, 100000));
        try testing.expectEqual(@as(i64, 0), allow);
        // 100 ms later: 1000 bytes earned.
        try testing.expectEqual(@as(usize, 1000), Reactor.rateTake(bps, &allow, &last, 5 * std.time.ns_per_s + 100 * std.time.ns_per_ms, 5000));
        // Nothing earned with no time passing.
        try testing.expectEqual(@as(usize, 0), Reactor.rateTake(bps, &allow, &last, 5 * std.time.ns_per_s + 100 * std.time.ns_per_ms, 5000));
    }
    // Burst capped at 256 KiB even for huge rates; floored at 4 KiB.
    {
        var allow: i64 = 0;
        var last: u64 = 0;
        try testing.expectEqual(@as(usize, 262144), Reactor.rateTake(100_000_000, &allow, &last, 60 * std.time.ns_per_s, 1_000_000));
        var allow2: i64 = 0;
        var last2: u64 = 0;
        try testing.expectEqual(@as(usize, 4096), Reactor.rateTake(100, &allow2, &last2, 60 * std.time.ns_per_s, 1_000_000));
    }
    // Partial takes preserve the remainder (allowance is in 1/64-byte
    // fixed-point units; 500 bytes == 500 * 64 units).
    {
        var allow: i64 = 500 * 64;
        var last: u64 = 1000;
        try testing.expectEqual(@as(usize, 200), Reactor.rateTake(10_000, &allow, &last, 1000, 200));
        try testing.expectEqual(@as(i64, 300 * 64), allow);
    }
}

test "reactor limit_rate paces file and echo bodies byte-exact" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location /file {
        \\        root "testdata";
        \\        content static;
        \\        limit_rate 10k;
        \\    }
        \\    location /echo {
        \\        content echo;
        \\        limit_rate 10k;
        \\    }
        \\}
    );
    const srv = runtime_server.Server.init(cfg);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    try r.start();
    defer r.join();
    defer r.stop();

    // Sendfile path: 20 KiB at 10 KiB/s takes ~1 s (10 KiB burst, then
    // paced). Must arrive byte-exact, not just eventually.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);

        const t0 = compat.Instant.now() catch return error.NoClock;
        try writeAll(pair[0], "GET /file/slow.bin HTTP/1.1\r\nHost: test\r\n\r\n");
        var buf: [32 * 1024]u8 = undefined;
        const res = try readHeadBody(pair[0], &buf);
        const t1 = compat.Instant.now() catch return error.NoClock;
        try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));
        try testing.expectEqual(@as(usize, 20 * 1024), res.body_len);
        // Byte-exact against the 0..255 cycling fixture pattern.
        const body = buf[res.head_len..][0..res.body_len];
        var i: usize = 0;
        for (body) |b| {
            try testing.expectEqual(@as(u8, @intCast(i % 256)), b);
            i += 1;
        }
        // Pacing proof: well above an unthrottled loopback transfer.
        try testing.expect(t1.since(t0) >= 700 * std.time.ns_per_ms);
    }
    // Memory path: 8 KiB echo at 10 KiB/s, byte-exact round trip.
    {
        const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer compat.close(pair[0]);
        try sockets.setNonBlock(pair[0]);
        try sockets.setNonBlock(pair[1]);
        const conn = try connection.Connection.create(allocator, pair[1]);
        r.attach(conn);

        var payload: [8 * 1024]u8 = undefined;
        for (&payload, 0..) |*b, j| b.* = @intCast((j * 7 + 3) % 251);
        var head_buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buf, "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: {d}\r\n\r\n", .{payload.len});
        try writeAll(pair[0], head);
        try writeAll(pair[0], &payload);
        var buf: [16 * 1024]u8 = undefined;
        const res = try readHeadBody(pair[0], &buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));
        try testing.expectEqualSlices(u8, &payload, buf[res.head_len..][0..res.body_len]);
    }
}

test "reactor answers Expect: 100-continue before the body arrives" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    // Headers only: the client is waiting for the interim status.
    try writeAll(pair[0], "POST /up HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n1 = try readUntil(pair[0], &buf, "HTTP/1.1 100 Continue\r\n\r\n".len, 3000);
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", buf[0..n1]);

    // Now the body; the final echo response follows on the same connection.
    try writeAll(pair[0], "hello");
    var date_buf: [96]u8 = undefined;
    var want_buf: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "HTTP/1.1 200 OK\r\n{s}Content-Length: 5\r\n\r\nhello", .{testDateLine(&date_buf)}) catch unreachable;
    const n2 = try readUntil(pair[0], &buf, want.len, 3000);
    try testing.expectEqualStrings(want, buf[0..n2]);
}

test "reactor closes the connection for return 444 without a byte" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    // A handler whose /drop route is `return 444;`.
    const cfg = comptime runtime_server.Config.fromConfComptime(
        \\server {
        \\    location /drop {
        \\        return 444;
        \\    }
        \\}
    );
    const srv = runtime_server.Server.init(cfg);
    var r = try Reactor.initWithHandler(allocator, 0, .http, &srv);
    defer r.deinit();
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);

    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /drop HTTP/1.1\r\nHost: x\r\n\r\n");
    // Wait for readability, then a 0-byte read: the server closed with no
    // response bytes.
    var pfds = [_]std.posix.pollfd{.{ .fd = pair[0], .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfds, 3000) catch 0;
    try testing.expect(ready > 0);
    var buf: [64]u8 = undefined;
    const n = std.posix.read(pair[0], &buf) catch 0;
    try testing.expectEqual(@as(usize, 0), n);
}

test "reactor parked proxy honors X-Accel-Redirect to a template route" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const up = try TestUpstream.start("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Accel-Redirect: /fallback\r\n\r\n");
    defer up.stop();

    const router_mod = @import("../dsl/router.zig");
    var ups = [_]router_mod.Upstream{.{
        .host = "127.0.0.1",
        .port = up.port,
        .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", up.port).?,
    }};
    const bindings = [_]router_mod.ModuleBinding{
        .{ .phase = .rewrite, .module = "proxy" },
        .{ .phase = .log, .module = "accel" },
    };
    const routes = [_]router_mod.Route{
        .{
            .path = "/accel",
            .match = .exact,
            .modules = &bindings,
            .upstreams = &ups,
            .accel_enabled = true,
        },
        .{
            .path = "/fallback",
            .match = .exact,
            .response = .{ .status = 200, .body = "internal-ok" },
        },
    };
    var srv = runtime_server.Server.init(.{ .routes = &routes });
    proxy_mod.testResetRoute(&routes[0]);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /accel HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));
    // The origin's empty 200 was replaced by the internal target's body.
    try testing.expectEqualStrings("internal-ok", buf[res.head_len..][0..res.body_len]);
}

test "reactor parked proxy applies proxy_hide_header and proxy_redirect" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    const up = try TestUpstream.start("HTTP/1.1 301 Moved\r\nContent-Length: 0\r\nX-Powered-By: origin\r\nLocation: http://origin.local/x\r\n\r\n");
    defer up.stop();

    const router_mod = @import("../dsl/router.zig");
    var ups = [_]router_mod.Upstream{.{
        .host = "127.0.0.1",
        .port = up.port,
        .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", up.port).?,
    }};
    const bindings = [_]router_mod.ModuleBinding{.{ .phase = .rewrite, .module = "proxy" }};
    const hidden = [_][]const u8{"x-powered-by"};
    const routes = [_]router_mod.Route{.{
        .path = "/",
        .modules = &bindings,
        .upstreams = &ups,
        .proxy_hide = &hidden,
        .proxy_redirect_from = "http://origin.local/",
        .proxy_redirect_to = "https://public.example/",
    }};
    var srv = runtime_server.Server.init(.{ .routes = &routes });
    proxy_mod.testResetRoute(&routes[0]);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /r HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    const head = buf[0..res.head_len];
    try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 301 Moved"));
    try testing.expect(std.mem.indexOf(u8, head, "X-Powered-By") == null);
    try testing.expect(std.mem.indexOf(u8, head, "https://public.example/x") != null);
}

test "reactor parked 502 runs error_page to a named location" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;
    // Reserve-then-close a port so nothing listens.
    const lfd = try compat.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
    addr[0] = 2;
    addr[4] = 127;
    addr[7] = 1;
    try compat.bind(lfd, @ptrCast(&addr), 16);
    var slen: posix.socklen_t = 16;
    var bound: [16]u8 align(@alignOf(u16)) = undefined;
    try compat.getsockname(lfd, @ptrCast(&bound), &slen);
    const dead_port = (@as(u16, bound[2]) << 8) | bound[3];
    compat.close(lfd);

    const router_mod = @import("../dsl/router.zig");
    var ups = [_]router_mod.Upstream{.{
        .host = "127.0.0.1",
        .port = dead_port,
        .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", dead_port).?,
    }};
    const pages = [_]router_mod.ErrorPage{.{ .status = 502, .target = "@fallback" }};
    const bindings = [_]router_mod.ModuleBinding{
        .{ .phase = .rewrite, .module = "proxy" },
        .{ .phase = .log, .module = "error_page" },
    };
    const routes = [_]router_mod.Route{
        .{
            .path = "/",
            .modules = &bindings,
            .upstreams = &ups,
            .error_pages = &pages,
        },
        .{
            .path = "",
            .name = "@fallback",
            .response = .{ .status = 200, .body = "fallback-ok" },
        },
    };
    var srv = runtime_server.Server.init(.{ .routes = &routes });
    proxy_mod.testResetRoute(&routes[0]);

    var r = try Reactor.init(allocator, 0, .http);
    defer r.deinit();
    r.handler = &srv;
    try r.start();
    defer r.join();
    defer r.stop();

    const pair = try compat.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer compat.close(pair[0]);
    try sockets.setNonBlock(pair[0]);
    try sockets.setNonBlock(pair[1]);
    const conn = try connection.Connection.create(allocator, pair[1]);
    r.attach(conn);

    try writeAll(pair[0], "GET /dead HTTP/1.1\r\nHost: test\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const res = try readHeadBody(pair[0], &buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..res.head_len], "HTTP/1.1 200 OK"));
    try testing.expectEqualStrings("fallback-ok", buf[res.head_len..][0..res.body_len]);
}
