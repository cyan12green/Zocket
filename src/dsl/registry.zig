const std = @import("std");
const phase_mod = @import("phase.zig");
const router = @import("router.zig");
const http_parser = @import("../http/parser.zig");
const http_response = @import("../http/response.zig");
const static_cache = @import("static_cache.zig");
const limits_mod = @import("limits.zig");
const arena_mod = @import("../http/arena.zig");

pub const Phase = phase_mod.Phase;
pub const ModuleBinding = router.ModuleBinding;
pub const Route = router.Route;
pub const Request = http_parser.Request;
pub const Response = http_response.Response;
pub const Status = http_response.Status;
pub const Limits = limits_mod.Limits;
pub const CaptureRange = router.CaptureRange;
pub const LogFormat = router.LogFormat;
const vars_mod = @import("vars.zig");
pub const max_user_vars = vars_mod.max_user_vars;

/// Result of a full pipeline walk for one request. Defined here (not in the
/// pipeline) so the router's `DispatchFn` can reference it without an import
/// cycle; the pipeline re-exports it as `pipeline.Outcome`.
pub const Outcome = enum {
    /// A module produced a response (`ctx.resp` is valid).
    handled,
    /// The chain ended without a module claiming the request (no route
    /// matched, a short-circuit, or no module attached). The caller sends the
    /// default response.
    not_handled,
};

/// A comptime-specialised per-route dispatch function: directly
/// calls the modules bound to a route's phases — no phase loop, no moduleFor
/// scans, no Registry.resolve at runtime. Stored on `Route.dispatch` for
/// struct-literal configs; null for JSON-loaded routes (loop-walk fallback).
pub const DispatchFn = *const fn (ctx: *Context) anyerror!Outcome;

/// The kind of a module decides WHERE and WHEN it runs.
///
/// - `.handler` participates in the phase walk (first claim wins; every
///   phase runs in order until something answers). Request-side decisions
///   (auth, rate limiting, content generation) are handlers.
/// - `.filter` runs AFTER any handler produced a response — including the
///   not_handled/template path — in reverse declaration order, always.
///   Filters mutate `ctx.resp` only; they never gate whether content is
///   generated. Response transforms are filters.
pub const Kind = enum { handler, filter };

/// Server-lifecycle hooks: called once per process for every registered
/// module that declares them, at reactor startup (after limits are known)
/// and at shutdown. Modules use init to size shared-memory zones from the
/// configured limits and start background workers; lazy first-use init is
/// no longer needed.
pub const Lifecycle = struct {
    init: *const fn (limits: ?*const Limits) anyerror!void,
    deinit: *const fn () void,
};

/// The standard module interface. A module is a comptime value of this type,
/// exported by its source file; the registry below enumerates them. `run` is
/// the per-request entry point: for handlers it may claim the request and
/// returns an `Action` telling the phase dispatch loop what to do next; for
/// filters it mutates the already-produced response.
pub const Module = struct {
    name: []const u8,
    /// The phase this module attaches to (handlers). Filters ignore this:
    /// they run after the whole walk, ordered per route by declaration.
    phase: Phase,
    run: *const fn (ctx: *Context) anyerror!Action,
    kind: Kind = .handler,
    lifecycle: ?*const Lifecycle = null,
    /// Capability flag: responses produced by this module may arrive
    /// incrementally (streaming). Routes whose claiming handler sets this
    /// bypass response filters (v1: all of them; documented constraint).
    streams_response: bool = false,
    /// Directives owned by this module (comptime names; used for docs,
    /// uniqueness checks, and kind-aware binding errors).
    directives: []const []const u8 = &.{},
};

/// What a module run decided for the current request. `.async` parks the
/// request: the reactor registers `ctx.async_fd` with the connection's
/// event set and dispatches completions back into the module's stored
/// state machine (upstream modules only).
pub const Action = union(enum) {
    /// Do nothing; keep walking the phase chain.
    pass,
    /// A response is ready in `ctx.resp`; stop the chain.
    handled,
    /// Stop the chain without producing a response (the caller sends the
    /// default response). Any phase may short-circuit this way.
    short_circuit,
    /// Park until `ctx.async_fd` is ready (direction carried by the
    /// module's own state machine).
    async,
};

/// The mutable per-request state the pipeline passes to every module: the
/// parsed request and the response being built. The same types the reactor
/// used before the pipeline, so the content phase produces byte-identical
/// output to the hardcoded handler.
pub const Context = struct {
    req: *Request,
    resp: *Response,
    /// Route matched in the `find_config` phase; null before it runs.
    route: ?*const Route = null,
    /// Ask the connection to close after the response is flushed (e.g. an
    /// error the client cannot keep alive past).
    close_after_write: bool = false,
    /// Allocator for modules that allocate response data (gzip compression).
    /// Set by the reactor; null where allocation is unsupported.
    allocator: ?std.mem.Allocator = null,
    /// Entity metadata a content module exposes before the content phase runs
    /// Consumed by the conditional-GET and cache-header
    /// modules. Set by e.g. a post_read-phase stat.
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    /// IPv4 address of the client (network byte order), for proxy headers
    /// Zeroes when unknown (socketpair tests).
    client_ip: [4]u8 = .{ 0, 0, 0, 0 },
    /// Shared server counters for the stub status page,
    /// updated atomically by the reactors.
    stats: ?*const ServerStats = null,
    /// Static-file fd cache (nginx open_file_cache
    /// equivalent). Owned by the reactor (per-reactor, no locks); null in
    /// tests and module-level invocation.
    static_cache: ?*static_cache.StaticCache = null,
    /// Runtime-tunable server limits (config `limits` section). Set by the
    /// reactor; null in tests and module-level invocation (modules fall
    /// back to the compiled defaults).
    limits: ?*const limits_mod.Limits = null,
    /// Regex capture ranges into `capture_subject` (decoded target,
    /// arena-stable) — M-D. Index 0 = whole match; 1..9 = groups.
    captures: [9]CaptureRange = [_]CaptureRange{.{ .start = 0, .end = 0 }} ** 9,
    capture_count: u8 = 0,
    capture_subject: []const u8 = "",
    /// Lazy-rendered user-variable slots (set $var), slices into req.arena.
    user_slots: [max_user_vars]?[]const u8 = .{null} ** max_user_vars,
    /// Named log formats (config `log_format`); the access_log module reads
    /// the route's `log_format` index into this table. Null in tests and
    /// module-level invocation (the module falls back to `combined`).
    formats: ?[]const LogFormat = null,
    /// Per-request start instant for `$request_time`.
    started: std.time.Instant = undefined,
    /// Monotonic request timestamp in ns (reactor clock; 0 when unset, e.g.
    /// unit tests set it explicitly). Rate buckets and LB timing read this.
    now_ns: u64 = 0,
    /// Named per-module request-state slots, keyed by registry index
    /// (compile-time checked via `state`/`setState`). Each module owns its
    /// slot for the duration of one walk — no cross-module collisions.
    module_states: [max_module_states]?*anyopaque = [_]?*anyopaque{null} ** max_module_states,
    /// .async payload: upstream handle parked for reactor registration.
    async_handle: ?*const IoHandle = null,
    /// Legacy raw-fd mirror of async_handle (reactor fast path).
    async_fd: std.posix.fd_t = -1,
    /// Internal-subrequest recursion depth (hooks increment around their
    /// nested walks; depth > max_subrequest_depth must refuse).
    subrequest_depth: u8 = 0,
    /// Set by a handler to restart request processing against a new target
    /// after the current walk completes (nginx internal-redirect semantics;
    /// capped by the reactor at 8 hops).
    internal_redirect_target: ?[]const u8 = null,
    /// Whether the running I/O backend can park requests (epoll yes;
    /// io_uring/TLS fronts keep the synchronous driver). Set by the
    /// runtime; modules check before returning .async.
    async_supported: bool = false,

    /// Internal-subrequest hook (auth_request): installed by the reactor,
    /// implemented by the runtime Server so modules can run a request
    /// through the full pipeline without touching transport internals.
    /// The subrequest inherits only the Authorization header.
    subrequest: ?SubrequestHook = null,

    /// Shared request memory (the framework's module allocation facility):
    /// every byte a module allocates here is reclaimed wholesale by the
    /// server at the end of the request/response cycle — the arena rewinds
    /// between keep-alive requests on the same connection and dies with the
    /// connection. Allocate per-request intermediate state (keys, rendered
    /// values, records); NEVER store these slices beyond the response.
    ///
    /// The typed helpers below are the supported surface; they fall back to
    /// null when no request arena exists (bare Contexts in unit tests).
    pub fn sharedAlloc(ctx: *Context, n: usize) ?[]u8 {
        return ctx.req.arena.alloc(n);
    }

    pub fn sharedDupe(ctx: *Context, bytes: []const u8) ?[]u8 {
        const out = ctx.req.arena.alloc(bytes.len) orelse return null;
        @memcpy(out, bytes);
        return out;
    }

    pub fn sharedFmt(ctx: *Context, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        return std.fmt.allocPrint(ctx.req.arena.asAllocator(), fmt, args) catch null;
    }

    /// Run the configured subrequest hook against `target`. Depth-guarded
    /// centrally so every caller shares the recursion budget.
    pub fn runSubrequest(ctx: *Context, target: []const u8, out_status: *u16) !void {
        if (ctx.subrequest_depth >= 8) return error.SubrequestDepthExceeded;
        const hook = ctx.subrequest orelse return error.NoSubrequestHook;
        ctx.subrequest_depth += 1;
        defer ctx.subrequest_depth -= 1;
        return hook.call(hook.impl, ctx.req, target, out_status);
    }

    /// This module's private slot for the current request. Typical use:
    /// park a small flag/record in shared memory and store its address so
    /// a later phase of the SAME module can find it.
    pub fn setState(ctx: *Context, comptime module_name: []const u8, ptr: ?*anyopaque) void {
        ctx.module_states[default_registry.indexOf(module_name)] = ptr;
    }

    pub fn getState(ctx: *Context, comptime module_name: []const u8) ?*anyopaque {
        return ctx.module_states[default_registry.indexOf(module_name)];
    }
};

/// Upper bound for registered modules; asserted against the registry at
/// comptime in root-level tests.
pub const max_module_states = 32;

/// Shared connection/request counters: updated atomically by
/// the reactors, rendered by the stub_status module. Defined here so the
/// Context can reference it without an import cycle; the runtime Server
/// re-exports it.
pub const SubrequestHook = struct {
    impl: *const anyopaque,
    call: *const fn (
        impl: *const anyopaque,
        src_req: *const Request,
        target: []const u8,
        out_status: *u16,
    ) anyerror!void,
};

pub const ServerStats = struct {
    accepted: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),
    reading: std.atomic.Value(u64) = .init(0),
    writing: std.atomic.Value(u64) = .init(0),
    waiting: std.atomic.Value(u64) = .init(0),

    pub fn init() ServerStats {
        return .{};
    }
};

pub const ModuleInfo = struct {
    name: []const u8,
    phase: Phase,
};

/// A comptime module registry: a fixed, compile-time list of `Module` values.
/// `resolve` dispatches a runtime module name to its run function through a
/// comptime-unrolled switch, which is how config-declared names (from JSON or
/// a struct literal) reach the concrete modules. There is no dynamic loading:
/// every module a config can name must be in the list.
/// Opaque upstream I/O handle: an fd today; QUIC streams etc. slot in
/// here without touching modules again (drivers dispatch on the tag).
pub const IoHandle = union(enum) {
    fd: std.posix.fd_t,
};

/// One-per-process lifecycle gate shared by every registry instantiation
/// (only default_registry declares lifecycles in practice).
var lifecycle_init_gate = std.atomic.Value(bool).init(false);

pub fn Registry(comptime modules: anytype) type {
    return struct {
        pub const all = modules;

        /// Resolve a module name to its run function, or null if the name is
        /// not registered.
        pub fn resolve(name: []const u8) ?*const fn (ctx: *Context) anyerror!Action {
            inline for (all) |m| {
                if (std.mem.eql(u8, m.name, name)) return m.run;
            }
            return null;
        }

        /// Comptime-known description of every registered module.
        pub fn infos() [all.len]ModuleInfo {
            var out: [all.len]ModuleInfo = undefined;
            inline for (all, 0..) |m, i| {
                out[i] = .{ .name = m.name, .phase = m.phase };
            }
            return out;
        }

        /// Check that every binding names a registered module.
        pub fn validateBindings(bindings: []const ModuleBinding) error{UnknownModule}!void {
            for (bindings) |b| {
                if (resolve(b.module) == null) return error.UnknownModule;
            }
        }

        /// True if `name` is registered (comptime-known set membership check
        /// used by config validation).
        pub fn isRegistered(name: []const u8) bool {
            return resolve(name) != null;
        }

        /// Registry index of `name` (compile error when unknown): the key
        /// for named per-module request-state slots on Context.
        pub fn indexOf(comptime name: []const u8) usize {
            inline for (all, 0..) |m, i| {
                if (comptime std.mem.eql(u8, m.name, name)) return i;
            }
            @compileError("unknown module: " ++ name);
        }

        pub fn kindOf(name: []const u8) ?Kind {
            inline for (all) |m| {
                if (std.mem.eql(u8, m.name, name)) return m.kind;
            }
            return null;
        }

        pub fn isHandler(name: []const u8) bool {
            return kindOf(name) == .handler;
        }

        /// Whether `name` declares streaming responses (its routes bypass
        /// response filters — v1: all of them).
        pub fn streamsResponse(name: []const u8) bool {
            inline for (all) |m| {
                if (std.mem.eql(u8, m.name, name)) return m.streams_response;
            }
            return false;
        }

        pub fn isFilter(name: []const u8) bool {
            return kindOf(name) == .filter;
        }

        /// Run every declared module lifecycle init exactly once per
        /// process (guarded; multiple reactors call this). Modules size
        /// their shmem zones from `limits` here.
        pub fn initModules(limits: ?*const Limits) void {
            if (lifecycle_init_gate.swap(true, .acq_rel)) return;
            inline for (all) |m| {
                if (m.lifecycle) |lc| lc.init(limits) catch |e| {
                    std.debug.print("module '{s}' init failed: {s}\n", .{ m.name, @errorName(e) });
                };
            }
        }

        /// Symmetric shutdown (best-effort; process exit tolerates leaks).
        pub fn deinitModules() void {
            if (!lifecycle_init_gate.load(.acquire)) return;
            inline for (all) |m| {
                if (m.lifecycle) |lc| lc.deinit();
            }
            lifecycle_init_gate.store(false, .release);
        }
};
}

/// The registry used by the server: enumerate every built-in module here. Each
/// module file self-registers by exporting a `Module` value.
pub const default_registry = Registry(.{
    @import("modules/echo.zig").echo,
    @import("modules/gzip.zig").gzip,
    @import("modules/cache.zig").conditional_get,
    @import("modules/cache.zig").cache_headers,
    @import("modules/static.zig").static,
    @import("modules/proxy.zig").proxy,
    @import("modules/access_log.zig").access_log,
    @import("modules/error_log.zig").error_log,
    @import("modules/stub_status.zig").stub_status,
    @import("modules/headers.zig").headers,
    @import("modules/auth_basic.zig").auth_basic,
    @import("modules/limit.zig").limit_req,
    @import("modules/limit.zig").limit_conn,
    @import("modules/limit.zig").limit_conn_release,
    @import("modules/precompressed.zig").precompressed,
    @import("modules/auth_request.zig").auth_request,
    @import("modules/proxy_cache.zig").proxy_cache,
    @import("modules/proxy_cache.zig").proxy_cache_store,
});

const testing = std.testing;

test "modules register themselves with a name and a phase" {
    const infos = default_registry.infos();
        // Count derives from the registry itself: adding a module must not
    // require touching this test (uniqueness below is the real invariant).
    try testing.expect(infos.len >= 9);
    try testing.expectEqualStrings("echo", infos[0].name);
    try testing.expectEqual(Phase.content, infos[0].phase);
}

test "names in the registry are unique" {
    const infos = default_registry.infos();
    for (infos, 0..) |a, i| {
        for (infos[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "resolve dispatches registered names and rejects unknown ones" {
    try testing.expect(default_registry.resolve("echo") != null);
    try testing.expectEqual(@as(?*const fn (*Context) anyerror!Action, null), default_registry.resolve("nope"));
}

test "config wiring: validateBindings accepts registered names only" {
    const ok = [_]ModuleBinding{.{ .phase = .content, .module = "echo" }};
    try default_registry.validateBindings(&ok);

    const bad = [_]ModuleBinding{.{ .phase = .content, .module = "missing_module" }};
    try testing.expectError(error.UnknownModule, default_registry.validateBindings(&bad));
}

test "resolve runs the echo module to a handled response" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.body = "hello pipeline";

    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const run_fn = default_registry.resolve("echo").?;
    try testing.expectEqual(Action.handled, try run_fn(&ctx));
    try testing.expectEqual(Status.ok, resp.status);
    try testing.expectEqualStrings("hello pipeline", resp.body);
}
