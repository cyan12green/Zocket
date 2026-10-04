//! `error_page` — serve an alternate response for a given status code.
//!
//! Bound to the `log` phase (post-processing): it runs after every outcome,
//! so it sees the status the request is actually heading out with
//! (`ctx.effective_status`, which the pipeline sets to 404 when no module
//! claimed the request). Two target forms, both nginx-compatible:
//!
//!   error_page 404 /404.html;   -> internal redirect to that URI
//!   error_page 404 500 /50x;    -> the same URI serves 404 AND 500
//!   error_page 503 =200;        -> rewrite the status in place
//!
//! A self-referential entry (`error_page 404 /same-uri`) terminates at
//! `Server.max_internal_redirects` — the server owns the hop budget, so the
//! module itself is guard-free and every match redirects.
const std = @import("std");
const registry = @import("../registry.zig");
const router_mod = @import("../router.zig");
const parser = @import("../../http/parser.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const error_page = registry.Module{
    .name = "error_page",
    .phase = .log,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.error_pages.len == 0) return .pass;
    const status = ctx.effective_status;

    for (route.error_pages) |ep| {
        if (ep.status != status) continue;
        if (ep.isCodeForm()) {
            // `=code`: replace the status, keep everything else.
            if (ep.codeOf() != 0) {
                ctx.resp.status = @enumFromInt(ep.codeOf());
                ctx.effective_status = ep.codeOf();
            }
            return .pass;
        }
        // URI form: nginx switches to GET for non-GET/HEAD so the alternate
        // page (usually a static file) is fetched, not posted to.
        if (ctx.req.method != .get and ctx.req.method != .head) ctx.req.method = .get;
        ctx.resp.status = @enumFromInt(ep.status);
        ctx.internal_redirect_target = ep.target;
        return .pass;
    }
    return .pass;
}

const testing = std.testing;

test "error_page: no table is inert" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.not_found);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expect(ctx.internal_redirect_target == null);
}

test "error_page: code form rewrites the status in place" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.service_unavailable);
    var ctx = Context{ .req = &req, .resp = &resp, .effective_status = 503 };
    const pages = [_]router_mod.ErrorPage{
        .{ .status = 404, .target = "/404.html" },
        .{ .status = 503, .target = "=200" },
    };
    const route = registry.Route{ .path = "/", .error_pages = &pages };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    // A code form never redirects.
    try testing.expect(ctx.internal_redirect_target == null);
}

test "error_page: uri form sets the redirect and downgrades the method" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .post;
    var resp = registry.Response.init(.not_found);
    var ctx = Context{ .req = &req, .resp = &resp, .effective_status = 404 };
    const pages = [_]router_mod.ErrorPage{.{ .status = 404, .target = "/errors/404.html" }};
    const route = registry.Route{ .path = "/", .error_pages = &pages };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("/errors/404.html", ctx.internal_redirect_target.?);
    try testing.expectEqual(parser.Method.get, req.method);
    // GET requests keep their method.
    req.method = .get;
    ctx.internal_redirect_target = null;
    _ = try run(&ctx);
    try testing.expectEqual(parser.Method.get, req.method);
}

test "error_page: non-matching status is inert" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.not_found);
    var ctx = Context{ .req = &req, .resp = &resp, .effective_status = 500 };
    const pages = [_]router_mod.ErrorPage{.{ .status = 404, .target = "/404.html" }};
    const route = registry.Route{ .path = "/", .error_pages = &pages };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expect(ctx.internal_redirect_target == null);
    // Repeat matches keep redirecting: the SERVER owns the hop budget
    // (max_internal_redirects), not the module — a self-referential entry
    // terminates there, never here.
    ctx.effective_status = 404;
    ctx.redirect_hops = 7;
    _ = try run(&ctx);
    try testing.expectEqualStrings("/404.html", ctx.internal_redirect_target.?);
}

test "ErrorPage helpers parse the =code form" {
    const uri = router_mod.ErrorPage{ .status = 404, .target = "/x" };
    try testing.expect(!uri.isCodeForm());
    try testing.expectEqual(@as(u16, 0), uri.codeOf());
    const code = router_mod.ErrorPage{ .status = 503, .target = "=204" };
    try testing.expect(code.isCodeForm());
    try testing.expectEqual(@as(u16, 204), code.codeOf());
    const bad = router_mod.ErrorPage{ .status = 500, .target = "=oops" };
    try testing.expect(bad.isCodeForm());
    try testing.expectEqual(@as(u16, 0), bad.codeOf());
}
