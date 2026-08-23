const std = @import("std");
const phase_mod = @import("phase.zig");
const router = @import("router.zig");
const http_parser = @import("../http/parser.zig");
const http_response = @import("../http/response.zig");
const static_cache = @import("static_cache.zig");
const limits_mod = @import("limits.zig");

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

/// A comptime-specialised per-route dispatch function (Milestone 7): directly
/// calls the modules bound to a route's phases — no phase loop, no moduleFor
/// scans, no Registry.resolve at runtime. Stored on `Route.dispatch` for
/// struct-literal configs; null for JSON-loaded routes (loop-walk fallback).
pub const DispatchFn = *const fn (ctx: *Context) anyerror!Outcome;

/// The standard module interface. A module is a comptime value of this type,
/// exported by its source file; the registry below enumerates them. `run` is
/// the per-request handler: it may mutate the context and returns an `Action`
/// telling the phase dispatch loop what to do next.
pub const Module = struct {
    name: []const u8,
    /// The phase this module attaches to.
    phase: Phase,
    run: *const fn (ctx: *Context) anyerror!Action,
};

/// What a module run decided for the current request.
pub const Action = enum {
    /// Do nothing; keep walking the phase chain.
    pass,
    /// A response is ready in `ctx.resp`; stop the chain.
    handled,
    /// Stop the chain without producing a response (the caller sends the
    /// default response). Any phase may short-circuit this way.
    short_circuit,
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
    /// (Milestone 9): consumed by the conditional-GET and cache-header
    /// modules. Set by e.g. a post_read-phase stat.
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    /// IPv4 address of the client (network byte order), for proxy headers
    /// (Milestone 12). Zeroes when unknown (socketpair tests).
    client_ip: [4]u8 = .{ 0, 0, 0, 0 },
    /// Shared server counters for the stub status page (Milestone 13),
    /// updated atomically by the reactors.
    stats: ?*const ServerStats = null,
    /// Static-file fd cache (Milestone 14 follow-up, nginx open_file_cache
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
};

/// Shared connection/request counters (Milestone 13): updated atomically by
/// the reactors, rendered by the stub_status module. Defined here so the
/// Context can reference it without an import cycle; the runtime Server
/// re-exports it.
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
});

const testing = std.testing;

test "modules register themselves with a name and a phase" {
    const infos = default_registry.infos();
    try testing.expectEqual(@as(usize, 10), infos.len);
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
