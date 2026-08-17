const std = @import("std");
const phase_mod = @import("phase.zig");
const router = @import("router.zig");
const registry = @import("registry.zig");

pub const Phase = phase_mod.Phase;
pub const Context = registry.Context;
pub const Action = registry.Action;
pub const Outcome = registry.Outcome;
pub const DispatchFn = registry.DispatchFn;
pub const Request = registry.Request;
pub const Response = registry.Response;
pub const Status = registry.Status;
const vars = @import("vars.zig");

/// Walk the phase chain for one fully-parsed request.
///
/// The `find_config` phase runs the route matcher (exact beats prefix; longest
/// prefix wins) and records the match on the context; it is resolved up front so
/// every phase — including `post_read`/`server_rewrite`, which nginx runs before
/// location config — can carry route-scoped modules. The remaining phases then
/// run in `Phase.all` order. Multiple modules may share a phase on a route: they
/// form a chain executed in config declaration order (nginx-style). Within a
/// chain a module returning `.pass` moves to the next module in the same phase;
/// `.handled` or `.short_circuit` stops the whole walk. If the chain ends
/// without a claim the caller sends the default response.
///
/// `Registry` is the comptime module registry used for dispatch (a `Registry`
/// value from `registry.zig`); it is a parameter so tests can register their
/// own modules.
pub fn run(comptime Registry: type, routes: []const router.Route, ctx: *Context) !Outcome {
    return runWithRouter(Registry, routes, null, ctx);
}

/// Like `run`, but route matching goes through a pre-built `Router` (the
/// comptime trie for struct-literal and conf-derived configs). Pass null to
/// use the linear `matchRoutes` fallback.
///
/// The `log` phase is special: its modules (if bound) run as post-processing
/// after the walk ends — whether a module claimed the request, short-circuited
/// it, or nothing claimed it — so logging and response transforms (gzip) see
/// the final response. The walk loop skips the log phase; this function runs
/// it once at the end, in declaration order.
pub fn runWithRouter(comptime Registry: type, routes: []const router.Route, rtr: ?*const router.Router, ctx: *Context) !Outcome {
    const route = if (rtr) |r| blk: {
        // M-D: the router records regex captures; copy them into the context
        // (the winning route may be a regex route).
        var caps = router.MatchCaps{ .subject = ctx.req.decoded_target };
        const matched = r.match(ctx.req.decoded_target, &caps);
        if (caps.count > 0) {
            ctx.capture_subject = caps.subject;
            ctx.captures = caps.ranges;
            ctx.capture_count = caps.count;
        }
        break :blk matched;
    } else router.matchRoutes(routes, ctx.req.decoded_target);
    ctx.route = route;
    // No route matched: no module can act on this request.
    const r = route orelse return .not_handled;

    // Route opt-in for chunked transfer encoding (config `chunked: true`):
    // the serializer frames this route's response as chunks instead of
    // Content-Length. The flag travels on the response; h2 ignores it.
    if (r.chunked) ctx.resp.chunked = true;

    // Milestone 7: comptime-specialised dispatch (struct-literal configs).
    // Zero loops, zero moduleFor scans, zero Registry.resolve at runtime.
    if (r.dispatch) |f| {
        const out = try f(ctx);
        // Milestone 11: template fallback when no module claimed the request.
        if (out == .not_handled) {
            if (r.response) |t| {
                applyTemplate(ctx, t);
                return .handled;
            }
            // M-B: dynamic (variable-capable) templates render into the arena.
            if (r.response_cv) |t| {
                applyTemplateCV(ctx, t);
                return .handled;
            }
        }
        return out;
    }

    const outcome = blk: {
        for (Phase.all) |phase| {
            if (phase == .log) continue;
            // nginx-style chain: every module bound to this phase runs in
            // config declaration order. `.pass` moves to the next module in
            // the same phase; `.handled`/`.short_circuit` stop the walk.
            for (r.modules) |b| {
                if (b.phase != phase) continue;
                const run_fn = Registry.resolve(b.module) orelse return error.UnknownModule;
                switch (try run_fn(ctx)) {
                    .pass => continue,
                    .handled => break :blk Outcome.handled,
                    .short_circuit => break :blk Outcome.not_handled,
                }
            }
        }
        break :blk Outcome.not_handled;
    };
    // The log phase runs as post-processing: every log-bound module, in
    // declaration order (gzip transforms, access/error logs).
    for (r.modules) |b| {
        if (b.phase != .log) continue;
        const run_fn = Registry.resolve(b.module).?;
        // Post-processing: its action does not change the outcome.
        _ = try run_fn(ctx);
    }
    if (outcome == .not_handled) {
        // Milestone 11: a route with a response template and modules that did
        // not claim the request falls back to the template.
        if (r.response) |t| {
            applyTemplate(ctx, t);
            return .handled;
        }
        // M-B: dynamic templates render per request (variables/captures).
        if (r.response_cv) |t| {
            applyTemplateCV(ctx, t);
            return .handled;
        }
    }
    return outcome;
}

/// Runtime application of a response template (JSON-config routes, whose
/// templates cannot be pre-serialised at compile time). Comptime routes with
/// modules use this too; module-less comptime routes take the reactor fast
/// path instead.
fn applyTemplate(ctx: *Context, t: router.ResponseTemplate) void {
    ctx.resp.status = @enumFromInt(t.status);
    for (t.headers) |h| {
        ctx.resp.setHeader(h.name, h.value);
    }
    ctx.resp.body = t.body;
}

/// Apply a dynamic (variable-capable) response template: every header value
/// and the body render into the request arena (M-B), then apply like the
/// literal template.
fn applyTemplateCV(ctx: *Context, t: router.ResponseTemplateCV) void {
    ctx.resp.status = @enumFromInt(t.status);
    for (t.headers) |h| {
        const value = vars.renderComplexArena(ctx, h.value, &ctx.req.arena) orelse "";
        ctx.resp.setHeader(h.name, value);
    }
    ctx.resp.body = vars.renderComplexArena(ctx, t.body, &ctx.req.arena) orelse "";
}

/// Comptime-specialised dispatch function for one route (Milestone 7 Part B).
/// The bound modules are called directly, phase by phase — the equivalent of
/// an unrolled switch over the route's bindings with the module resolution
/// resolved at compile time. Modules sharing a phase form a chain in config
/// declaration order (nginx-style), exactly like the loop-walk path:
///
/// ```zig
/// fn dispatch(ctx) !Outcome {
///     switch (try echo.run(ctx)) { .handled => return .handled, else => {} }
///     switch (try static.run(ctx)) { .handled => return .handled, else => {} }
///     return .not_handled;
/// }
/// ```
pub fn dispatchForRoute(comptime Registry: type, comptime route: router.Route) DispatchFn {
    const Impl = struct {
        fn run(ctx: *Context) anyerror!Outcome {
            var outcome: Outcome = .not_handled;
            // nginx-style chains: modules sharing a phase run in declaration
            // order; `.pass` moves to the next, `.handled`/`.short_circuit`
            // stop the walk. The label lets the inner (same-phase) loop stop
            // the outer phase loop too.
            phases: {
                inline for (Phase.all) |phase| {
                    if (phase == .log) continue;
                    inline for (route.modules) |b| {
                        if (b.phase != phase) continue;
                        const run_fn = Registry.resolve(b.module).?;
                        switch (try run_fn(ctx)) {
                            .pass => {},
                            .handled => {
                                outcome = .handled;
                                break :phases;
                            },
                            .short_circuit => {
                                outcome = .not_handled;
                                break :phases;
                            },
                        }
                    }
                }
            }
            // The log phase runs as post-processing (same contract as the
            // loop-walk path): every log-bound module, in declaration order.
            inline for (route.modules) |b| {
                if (b.phase != .log) continue;
                const run_fn = Registry.resolve(b.module).?;
                _ = try run_fn(ctx);
            }
            if (outcome == .handled) return .handled;
            if (route.response) |t| {
                applyTemplate(ctx, t);
                return .handled;
            }
            if (route.response_cv) |t| {
                applyTemplateCV(ctx, t);
                return .handled;
            }
            return .not_handled;
        }
    };
    return Impl.run;
}

/// Copy a comptime route table with the specialised dispatch function
/// assigned to every route. The result is a comptime array that lives in
/// `.rodata` alongside the routes. Forced through a `comptime` expression so
/// it works from runtime call sites.
pub fn assignDispatch(comptime Registry: type, comptime routes: []const router.Route) [routes.len]router.Route {
    return comptime assignDispatchImpl(Registry, routes);
}

fn assignDispatchImpl(comptime Registry: type, comptime routes: []const router.Route) [routes.len]router.Route {
    var out: [routes.len]router.Route = undefined;
    inline for (routes, 0..) |r, i| {
        out[i] = r;
        out[i].dispatch = dispatchForRoute(Registry, r);
        // Milestone 10: comptime-embedded static assets. An invalid embed
        // path is a compile error here. Paths are project-root-relative
        // (the `embeds` module lives at the root for @embedFile).
        if (r.embed) |embed_path| {
            out[i].embed_bytes = @import("embeds").embed(embed_path);
        }
        // Milestone 11: fixed-response templates serialised at compile time.
        if (r.response) |t| {
            out[i].response_bytes = router.serializeResponseTemplate(t);
        }
        // Milestone 12: upstream sockaddrs must be pre-computed at compile
        // time (host literals — no DNS, no runtime byte-swapping). The
        // DM1/DM2 config parser fills them in; struct-literal configs must
        // set `.sockaddr` via `Upstream.makeSockaddr`. A stale default
        // (family 0) would fail the connect at runtime, so reject it here.
        inline for (r.upstreams) |up| {
            if (up.sockaddr.family == 0) {
                @compileError("proxy upstream needs a pre-computed sockaddr (Upstream.makeSockaddr): " ++ up.host);
            }
        }
    }
    return out;
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

/// Multiple modules sharing the content phase (nginx-style chain): three
/// pass modules plus a claiming module, all in the content phase.
const ChainRegistry = registry.Registry(.{
    pass_mod.make("chain_a", .content),
    pass_mod.make("chain_b", .content),
    pass_mod.make("chain_c", .content),
    claim_mod.make("chain_claim", .content),
    pass_mod.make("log_mod", .log),
});

fn runWith(comptime R: type, routes: []const router.Route, req: *Request) !struct { outcome: Outcome, resp: Response } {
    var resp = Response.init(.ok);
    var ctx = Context{ .req = req, .resp = &resp };
    const outcome = try run(R, routes, &ctx);
    return .{ .outcome = outcome, .resp = resp };
}

fn echoRoutes() []const router.Route {
    return &.{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .post_read, .module = "post_read_mod" },
        .{ .phase = .access, .module = "access_mod" },
        .{ .phase = .content, .module = "content_mod" },
        .{ .phase = .log, .module = "log_mod" },
    } }};
}

test "pipeline walks phases in order" {
    const routes = comptime echoRoutes();

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/anything";
    req.decoded_target = "/anything";

    const res = try runWith(OrderRegistry, routes, &req);
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
    req.decoded_target = "/unmatched";

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
    req.decoded_target = "/";

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
    req.decoded_target = "/";

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
    req.decoded_target = "/";

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
    req.decoded_target = "/";

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
    req.decoded_target = "/";

    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectError(error.UnknownModule, run(OrderRegistry, &routes, &ctx));
}

// ---- Same-phase module chains (nginx-style, declaration order) ----

test "same-phase chain runs modules in config order when all pass" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .content, .module = "chain_a" },
        .{ .phase = .content, .module = "chain_b" },
        .{ .phase = .content, .module = "chain_c" },
        .{ .phase = .log, .module = "log_mod" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";
    req.decoded_target = "/";

    const res = try runWith(ChainRegistry, &routes, &req);
    // Nothing claimed: the whole chain walked.
    try testing.expectEqual(Outcome.not_handled, res.outcome);
    // Headers appear in declaration order: chain_a, chain_b, chain_c, log.
    try testing.expectEqual(@as(usize, 4), res.resp.header_count);
    try testing.expectEqualStrings("chain_a", res.resp.headers[0].value);
    try testing.expectEqualStrings("chain_b", res.resp.headers[1].value);
    try testing.expectEqualStrings("chain_c", res.resp.headers[2].value);
    try testing.expectEqualStrings("log_mod", res.resp.headers[3].value);
}

test "a handled module stops the rest of its phase chain" {
    const routes = [_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .content, .module = "chain_a" },
        .{ .phase = .content, .module = "chain_claim" },
        .{ .phase = .content, .module = "chain_c" },
        .{ .phase = .log, .module = "log_mod" },
    } }};

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";
    req.decoded_target = "/";

    const res = try runWith(ChainRegistry, &routes, &req);
    // chain_a passed, chain_claim handled: chain_c in the same phase never ran.
    try testing.expectEqual(Outcome.handled, res.outcome);
    try testing.expectEqual(@as(usize, 3), res.resp.header_count);
    try testing.expectEqualStrings("chain_a", res.resp.headers[0].value);
    try testing.expectEqualStrings("chain_claim", res.resp.headers[1].value);
    // The log phase still runs as post-processing after a handled response.
    try testing.expectEqualStrings("log_mod", res.resp.headers[2].value);
}

test "dispatch specialisation chains same-phase modules like the loop walk" {
    const routes = comptime &[_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .content, .module = "chain_a" },
        .{ .phase = .content, .module = "chain_b" },
        .{ .phase = .content, .module = "chain_claim" },
        .{ .phase = .content, .module = "chain_c" },
        .{ .phase = .log, .module = "log_mod" },
    } }};

    // Loop-walk baseline.
    var req_a = Request.init(testing.allocator);
    defer req_a.deinit();
    req_a.target = "/";
    req_a.decoded_target = "/";
    const res_a = try runWith(ChainRegistry, routes, &req_a);

    // Comptime dispatch.
    const dispatched = comptime assignDispatch(ChainRegistry, routes);
    var req_b = Request.init(testing.allocator);
    defer req_b.deinit();
    req_b.target = "/";
    req_b.decoded_target = "/";
    const res_b = try runWith(ChainRegistry, &dispatched, &req_b);

    // Identical outcome and chain order; chain_c never ran either way.
    try testing.expectEqual(res_a.outcome, res_b.outcome);
    try testing.expectEqual(Outcome.handled, res_b.outcome);
    try testing.expectEqual(@as(usize, 4), res_b.resp.header_count);
    try testing.expectEqualStrings("chain_a", res_b.resp.headers[0].value);
    try testing.expectEqualStrings("chain_b", res_b.resp.headers[1].value);
    try testing.expectEqualStrings("chain_claim", res_b.resp.headers[2].value);
    try testing.expectEqualStrings("log_mod", res_b.resp.headers[3].value);
}

// ---- Milestone 7: comptime dispatch specialisation ----

test "dispatch specialisation matches the loop walk outcome and state" {
    const routes = comptime echoRoutes();
    // The loop-walk baseline (no dispatch functions assigned).
    var req_a = Request.init(testing.allocator);
    defer req_a.deinit();
    req_a.target = "/anything";
    req_a.decoded_target = "/anything";
    const res_a = try runWith(OrderRegistry, routes, &req_a);

    // The same route table with comptime dispatch functions assigned.
    const dispatched = comptime assignDispatch(OrderRegistry, routes);
    var req_b = Request.init(testing.allocator);
    defer req_b.deinit();
    req_b.target = "/anything";
    req_b.decoded_target = "/anything";
    const res_b = try runWith(OrderRegistry, &dispatched, &req_b);

    try testing.expectEqual(res_a.outcome, res_b.outcome);
    try testing.expectEqual(Status.ok, res_b.resp.status);
    try testing.expectEqual(@as(usize, 4), res_b.resp.header_count);
    try testing.expectEqualStrings("post_read_mod", res_b.resp.headers[0].value);
    try testing.expectEqualStrings("access_mod", res_b.resp.headers[1].value);
    try testing.expectEqualStrings("content_mod", res_b.resp.headers[2].value);
    try testing.expectEqualStrings("log_mod", res_b.resp.headers[3].value);
}

test "dispatch specialisation handles short-circuit and handled modules" {
    // Short-circuit route: access denies; content never runs.
    const short_routes = comptime &[_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .access, .module = "deny" },
        .{ .phase = .content, .module = "content_mod" },
    } }};
    const short_dispatched = comptime assignDispatch(ShortCircuitRegistry, short_routes);

    var req_a = Request.init(testing.allocator);
    defer req_a.deinit();
    req_a.target = "/";
    req_a.decoded_target = "/";
    const res_a = try runWith(ShortCircuitRegistry, short_routes, &req_a);

    var req_b = Request.init(testing.allocator);
    defer req_b.deinit();
    req_b.target = "/";
    req_b.decoded_target = "/";
    const res_b = try runWith(ShortCircuitRegistry, &short_dispatched, &req_b);

    try testing.expectEqual(res_a.outcome, res_b.outcome);
    try testing.expectEqual(Outcome.not_handled, res_b.outcome);
    try testing.expectEqual(@as(usize, 1), res_b.resp.header_count);
    try testing.expectEqualStrings("deny", res_b.resp.headers[0].value);

    // Handled route: post_read claims; content never runs.
    const claim_routes = comptime &[_]router.Route{.{ .path = "/", .match = .prefix, .modules = &.{
        .{ .phase = .post_read, .module = "early" },
        .{ .phase = .content, .module = "content_mod" },
    } }};
    const claim_dispatched = comptime assignDispatch(HandlerRegistry, claim_routes);

    var req_c = Request.init(testing.allocator);
    defer req_c.deinit();
    req_c.target = "/";
    req_c.decoded_target = "/";
    const res_c = try runWith(HandlerRegistry, &claim_dispatched, &req_c);
    try testing.expectEqual(Outcome.handled, res_c.outcome);
    try testing.expectEqual(Status.bad_request, res_c.resp.status);
    try testing.expectEqualStrings("claimed", res_c.resp.body);
    try testing.expectEqual(@as(usize, 1), res_c.resp.header_count);
}

test "dispatched routes route identically through a trie-backed router" {
    const routes = comptime &[_]router.Route{
        .{ .path = "/", .match = .prefix, .modules = &.{
            .{ .phase = .content, .module = "content_claim" },
        } },
        .{ .path = "/skip", .match = .exact, .modules = &.{} },
    };
    const dispatched = comptime assignDispatch(PassThroughRegistry, routes);
    const trie = router.buildTrie(&dispatched);
    var rtr = router.Router{ .routes = &dispatched, .trie = trie };

    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/somewhere";
    req.decoded_target = "/somewhere";
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const res = try runWithRouter(PassThroughRegistry, &dispatched, &rtr, &ctx);
    try testing.expectEqual(Outcome.handled, res);

    // /skip binds no modules: not_handled despite the route match.
    var req2 = Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/skip";
    req2.decoded_target = "/skip";
    var resp2 = Response.init(.ok);
    var ctx2 = Context{ .req = &req2, .resp = &resp2 };
    const res2 = try runWithRouter(PassThroughRegistry, &dispatched, &rtr, &ctx2);
    try testing.expectEqual(Outcome.not_handled, res2);
}

test "response_cv renders set user variables lazily with caching" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    req.addHeaderParsed("host", "example.com") catch unreachable;
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const set_frags = comptime vars.parseComplexValue("hi-$host", &.{});
    const route_set = router.SetVar{ .name = "greeting", .slot = 0, .value = set_frags };
    const body_frags = comptime vars.parseComplexValue("g=$greeting again=$greeting", &.{.{ .name = "greeting", .slot = 0, .value = set_frags }});
    var route = router.Route{
        .path = "/",
        .response_cv = .{ .status = 200, .body = body_frags },
        .set_vars = &.{route_set},
    };
    ctx.route = &route;
    applyTemplateCV(&ctx, route.response_cv.?);
    try testing.expectEqualStrings("g=hi-example.com again=hi-example.com", resp.body);
    // Cached after first render.
    try testing.expectEqualStrings("hi-example.com", ctx.user_slots[0].?);
}
