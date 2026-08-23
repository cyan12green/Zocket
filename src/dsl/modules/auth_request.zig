//! Subrequest authorization (nginx `auth_request` equivalent). Access
//! phase: forwards the route's `auth_request <uri>;` through an internal
//! subrequest (full pipeline, Authorization header inherited). 2xx admits
//! the request; anything else is copied as the client-facing status and
//! stops the chain before content runs.
//!
//! Recursion-safe: a subrequest that itself binds auth_request fails with
//! 500 instead of looping. A missing hook (unit-test contexts) degrades to
//! 500 rather than silently admitting.

const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

var in_subrequest_marker: u8 = 0;

pub const auth_request = registry.Module{
    .name = "auth_request",
    .phase = .access,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const uri = route.auth_request_uri orelse return .pass;
    if (ctx.getState("auth_request") == @as(?*anyopaque, @ptrCast(&in_subrequest_marker))) {
        // We are ALREADY inside an auth subrequest: refuse to recurse.
        return failWith(ctx, .internal_error);
    }
    const hook = ctx.subrequest orelse return failWith(ctx, .internal_error);

    var status: u16 = 0;
    ctx.setState("auth_request", @ptrCast(&in_subrequest_marker));
    defer ctx.setState("auth_request", null);
    hook.call(hook.impl, ctx.req, uri, &status) catch return failWith(ctx, .internal_error);

    if (status >= 200 and status <= 299) return .pass;
    return failWith(ctx, mappedStatus(status));
}

/// Copy the subrequest's verdict where the Status enum can express it;
/// anything unmapped becomes a generic 500 (never admit on confusion).
fn mappedStatus(code: u16) registry.Status {
    return switch (code) {
        400 => .bad_request,
        401 => .unauthorized,
        403 => .forbidden,
        404 => .not_found,
        413 => .payload_too_large,
        429 => .service_unavailable,
        500...599 => .bad_gateway,
        else => .forbidden,
    };
}

fn failWith(ctx: *Context, status: registry.Status) Action {
    ctx.resp.status = status;
    ctx.resp.setBody(status.reasonPhrase());
    return .handled;
}

const Request = registry.Request;
const Response = registry.Response;
const testing = std.testing;

// Test hook plumbing: a global verdict the fake hook returns.
threadlocal var fake_status: u16 = 204;
threadlocal var fake_calls: usize = 0;

fn fakeHook(
    impl: *const anyopaque,
    src_req: *const Request,
    target: []const u8,
    out_status: *u16,
) anyerror!void {
    _ = impl;
    _ = src_req;
    fake_calls += 1;
    try testing.expectEqualStrings("/_auth", target);
    out_status.* = fake_status;
}

const fake_state: u8 = 0;

test "2xx verdicts pass; failures copy the status and claim" {
    inline for (.{ 204, 200 }) |code| {
        fake_status = code;
        var req = Request.init(testing.allocator);
        defer req.deinit();
        var resp = Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.subrequest = .{ .impl = @ptrCast(&fake_state), .call = fakeHook };
        ctx.route = &.{ .path = "/", .auth_request_uri = "/_auth" };
        try testing.expectEqual(Action.pass, try run(&ctx));
    }

    fake_status = 403;
    {
        var req = Request.init(testing.allocator);
        defer req.deinit();
        var resp = Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.subrequest = .{ .impl = @ptrCast(&fake_state), .call = fakeHook };
        ctx.route = &.{ .path = "/", .auth_request_uri = "/_auth" };
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(registry.Status.forbidden, resp.status);
    }

    // Unknown failure codes degrade instead of admitting.
    fake_status = 418;
    {
        var req = Request.init(testing.allocator);
        defer req.deinit();
        var resp = Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.subrequest = .{ .impl = @ptrCast(&fake_state), .call = fakeHook };
        ctx.route = &.{ .path = "/", .auth_request_uri = "/_auth" };
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(registry.Status.forbidden, resp.status);
    }
}

test "missing hook or unconfigured route stays inert or errors safely" {
    // No hook wired (bare test context): 500, never admit.
    var req = Request.init(testing.allocator);
    defer req.deinit();
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .auth_request_uri = "/_auth" };
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.internal_error, resp.status);

    // No URI configured: module inert.
    var req2 = Request.init(testing.allocator);
    defer req2.deinit();
    var resp2 = Response.init(.ok);
    var ctx2 = Context{ .req = &req2, .resp = &resp2 };
    ctx2.route = &.{ .path = "/" };
    try testing.expectEqual(Action.pass, try run(&ctx2));
}
