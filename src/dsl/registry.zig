const std = @import("std");
const phase_mod = @import("phase.zig");
const router = @import("router.zig");
const http_parser = @import("../http/parser.zig");
const http_response = @import("../http/response.zig");

pub const Phase = phase_mod.Phase;
pub const ModuleBinding = router.ModuleBinding;
pub const Route = router.Route;
pub const Request = http_parser.Request;
pub const Response = http_response.Response;
pub const Status = http_response.Status;

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
});

const testing = std.testing;

test "modules register themselves with a name and a phase" {
    const infos = default_registry.infos();
    try testing.expectEqual(@as(usize, 1), infos.len);
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
