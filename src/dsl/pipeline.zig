const std = @import("std");
const phase_mod = @import("phase.zig");
const router = @import("router.zig");
const registry = @import("registry.zig");

pub const Phase = phase_mod.Phase;
pub const Context = registry.Context;
pub const Action = registry.Action;
pub const Request = registry.Request;
pub const Response = registry.Response;
pub const Status = registry.Status;

/// Result of a full pipeline walk for one request.
pub const Outcome = enum {
    /// A module produced a response (`ctx.resp` is valid).
    handled,
    /// The chain ended without a module claiming the request (no route
    /// matched, a short-circuit, or no module attached). The caller sends the
    /// default response.
    not_handled,
};

/// Walk the phase chain for one fully-parsed request.
///
/// The `find_config` phase runs the route matcher (exact beats prefix; longest
/// prefix wins) and records the match on the context; it is resolved up front so
/// every phase — including `post_read`/`server_rewrite`, which nginx runs before
/// location config — can carry route-scoped modules. The remaining phases then
/// run in `Phase.all` order, dispatching the module the matched route binds to
/// each phase. Any module may claim the request (`handled`) or short-circuit it;
/// the walk stops immediately in either case. If the chain ends without a claim
/// the caller sends the default response.
///
/// `Registry` is the comptime module registry used for dispatch (a `Registry`
/// value from `registry.zig`); it is a parameter so tests can register their
/// own modules.
pub fn run(comptime Registry: type, routes: []const router.Route, ctx: *Context) !Outcome {
    const route = router.matchRoutes(routes, ctx.req.target);
    ctx.route = route;
    // No route matched: no module can act on this request.
    const r = route orelse return .not_handled;

    for (Phase.all) |phase| {
        const name = r.moduleFor(phase) orelse continue;
        const run_fn = Registry.resolve(name) orelse return error.UnknownModule;
        switch (try run_fn(ctx)) {
            .pass => continue,
            .handled => return .handled,
            .short_circuit => return .not_handled,
        }
    }
    return .not_handled;
}

const testing = std.testing;

/// Test module builders. Each records execution by appending a response header
/// (real context mutation, no global state) and returns the action its variant
/// stands for.
const pass_mod = struct {
    name: []const u8,
    phase: Phase,
    run: *const fn (*Context) anyerror!Action,

    fn make(comptime n: []const u8, comptime p: Phase) pass_mod {
        const Impl = struct {
            fn run(ctx: *Context) !Action {
                ctx.resp.setHeader("X-Order", n);
                return .pass;
            }
        };
        return .{ .name = n, .phase = p, .run = Impl.run };
    }
};

const claim_mod = struct {
    name: []const u8,
    phase: Phase,
    run: *const fn (*Context) anyerror!Action,

    fn make(comptime n: []const u8, comptime p: Phase) claim_mod {
        const Impl = struct {
            fn run(ctx: *Context) !Action {
                ctx.resp.status = .bad_request;
                ctx.resp.setHeader("X-Order", n);
                ctx.resp.setBody("claimed");
                return .handled;
            }
        };
        return .{ .name = n, .phase = p, .run = Impl.run };
    }
};

const short_mod = struct {
    name: []const u8,
    phase: Phase,
    run: *const fn (*Context) anyerror!Action,

    fn make(comptime n: []const u8, comptime p: Phase) short_mod {
        const Impl = struct {
            fn run(ctx: *Context) !Action {
                ctx.resp.setHeader("X-Order", n);
                return .short_circuit;
            }
        };
        return .{ .name = n, .phase = p, .run = Impl.run };
    }
};

/// Modules on post_read, access, content and log — one per phase across the
/// walk. All pass, so a full walk ends not_handled (nothing claims).
const OrderRegistry = registry.Registry(.{
    pass_mod.make("post_read_mod", .post_read),
    pass_mod.make("access_mod", .access),
    pass_mod.make("content_mod", .content),
    pass_mod.make("log_mod", .log),
});

/// access-phase short-circuit + a content module that would run if reached.
const ShortCircuitRegistry = registry.Registry(.{
    short_mod.make("deny", .access),
    pass_mod.make("content_mod", .content),
});

/// post_read claim + a content module that would run if reached.
const HandlerRegistry = registry.Registry(.{
    claim_mod.make("early", .post_read),
    pass_mod.make("content_mod", .content),
});

/// post_read pass + content claim.
const PassThroughRegistry = registry.Registry(.{
    pass_mod.make("post_read_mod", .post_read),
    claim_mod.make("content_claim", .content),
});

fn runWith(comptime R: type, routes: []const router.Route, req: *Request) !struct { outcome: Outcome, resp: Response } {
    var resp = Response.init(.ok);
    var ctx = Context{ .req = req, .resp = &resp };
    const outcome = try run(R, routes, &ctx);
    return .{ .outcome = outcome, .resp = resp };
}

fn echoRoutes() [1]router.Route {
    return .{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .post_read, .module = "post_read_mod" },
        .{ .phase = .access, .module = "access_mod" },
        .{ .phase = .content, .module = "content_mod" },
        .{ .phase = .log, .module = "log_mod" },
    } }};
}

test "pipeline walks phases in order" {
    const routes = echoRoutes();

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/anything";

    const res = try runWith(OrderRegistry, &routes, &req);
    // Nothing claimed the request: the walk covered every phase.
    try testing.expectEqual(Outcome.not_handled, res.outcome);
    try testing.expectEqual(@as(usize, 4), res.resp.header_count);
    // Headers were appended in phase execution order: post_read, access,
    // content, log — proving the chain walked the phases in order.
    try testing.expectEqualStrings("post_read_mod", res.resp.headers[0].value);
    try testing.expectEqualStrings("access_mod", res.resp.headers[1].value);
    try testing.expectEqualStrings("content_mod", res.resp.headers[2].value);
    try testing.expectEqualStrings("log_mod", res.resp.headers[3].value);
}

test "find_config runs the router: non-matching request is not handled" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/unmatched";

    const rs = [_]router.Route{.{ .path = "/api", .match = .exact, .modules = &.{
        .{ .phase = .content, .module = "content_mod" },
    } }};
    const res = try runWith(OrderRegistry, &rs, &req);
    try testing.expectEqual(Outcome.not_handled, res.outcome);
    // The content module never ran.
    try testing.expectEqual(@as(usize, 0), res.resp.header_count);
}

test "absence of module attachment yields a default (not_handled) response" {
    const rs = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{} }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";

    const res = try runWith(OrderRegistry, &rs, &req);
    try testing.expectEqual(Outcome.not_handled, res.outcome);
}

test "module short-circuit skips later phases" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .access, .module = "deny" },
        .{ .phase = .content, .module = "content_mod" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";

    const res = try runWith(ShortCircuitRegistry, &routes, &req);
    try testing.expectEqual(Outcome.not_handled, res.outcome);
    // Only the access module ran; the content module never fired.
    try testing.expectEqual(@as(usize, 1), res.resp.header_count);
    try testing.expectEqualStrings("deny", res.resp.headers[0].value);
}

test "handled module stops the chain and its context mutation is visible" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .post_read, .module = "early" },
        .{ .phase = .content, .module = "content_mod" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";

    const res = try runWith(HandlerRegistry, &routes, &req);
    try testing.expectEqual(Outcome.handled, res.outcome);
    // The post_read module claimed the request; content never ran.
    try testing.expectEqual(Status.bad_request, res.resp.status);
    try testing.expectEqualStrings("claimed", res.resp.body);
    try testing.expectEqual(@as(usize, 1), res.resp.header_count);
    try testing.expectEqualStrings("early", res.resp.headers[0].value);
}

test "passing module lets later phases run" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .post_read, .module = "post_read_mod" },
        .{ .phase = .content, .module = "content_claim" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";

    const res = try runWith(PassThroughRegistry, &routes, &req);
    try testing.expectEqual(Outcome.handled, res.outcome);
    // post_read passed; content claimed. Log did not run.
    try testing.expectEqual(@as(usize, 2), res.resp.header_count);
    try testing.expectEqualStrings("post_read_mod", res.resp.headers[0].value);
    try testing.expectEqualStrings("content_claim", res.resp.headers[1].value);
}

test "unknown module binding is a config error" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .content, .module = "ghost" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";

    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectError(error.UnknownModule, run(OrderRegistry, &routes, &ctx));
}
