//! Response-header manipulation module (nginx `headers_filter`-equivalent,
//! backlog item). Bound to the log phase — the pipeline's post-processing
//! slot, which runs even after a content module claimed the request — so
//! set/add/remove apply to the final module-produced header set. Note the
//! transport-owned Connection/Date/Server headers are appended by the
//! reactor serializer afterwards and are not governed by these ops.
//!
//! Config surface (`Route.headers_ops`, parsed from conf):
//!   header_set X-Frame-Options "DENY";     — replace-or-append
//!   header_add Link "</s.css>; rel=style"; — append
//!   header_remove Server;                  — drop all of that name
//! Values are complex values ($variables render into the request arena).

const std = @import("std");
const registry = @import("../registry.zig");
const vars = @import("../vars.zig");

pub const Context = registry.Context;
pub const Request = registry.Request;
pub const Response = registry.Response;
pub const Route = registry.Route;
pub const Status = registry.Status;
pub const Action = registry.Action;

pub const headers = registry.Module{
    .name = "headers",
    .phase = .log,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.headers_ops.len == 0) return .pass;

    for (route.headers_ops) |op| {
        if (!op.always and !statusCarriesHeaders(ctx.resp.status)) continue;
        switch (op.kind) {
            .remove => _ = ctx.resp.removeHeader(op.name),
            .set, .add => {
                const value = vars.renderComplexArena(ctx, op.value, &ctx.req.arena) orelse "";
                if (op.kind == .set) {
                    ctx.resp.replaceHeader(op.name, value);
                } else if (ctx.resp.header_count < ctx.resp.headers.len) {
                    // Append semantics for `add` (duplicates allowed).
                    ctx.resp.setHeader(op.name, value);
                }
            },
        }
    }
    return .pass;
}

/// Statuses that carry application headers by nginx's rule (add_header
/// without `always` applies to exactly these).
fn statusCarriesHeaders(status: Status) bool {
    return switch (@intFromEnum(status)) {
        200, 201, 204, 206, 301, 302, 303, 304, 307, 308 => true,
        else => false,
    };
}

const testing = std.testing;

test "headers applies set, add and remove in declaration order" {
    var req = Request.init(testing.allocator);
    defer req.deinit();

    var resp = Response.init(.ok);
    resp.setHeader("X-Old", "stale");
    resp.setHeader("X-Keep", "yes");
    var ctx = Context{ .req = &req, .resp = &resp };
    const route = registry.Route{
        .path = "/",
        .headers_ops = &.{
            .{ .kind = .set, .name = "X-Old", .value = &.{.{ .literal = "fresh" }} },
            .{ .kind = .add, .name = "X-Extra", .value = &.{.{ .literal = "one" }} },
            .{ .kind = .add, .name = "X-Extra", .value = &.{.{ .literal = "two" }} },
            .{ .kind = .remove, .name = "x-old" },
        },
    };
    ctx.route = &route;

    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(@as(?[]const u8, null), headerOf(&resp, "X-Old"));
    try testing.expectEqualStrings("yes", headerOf(&resp, "X-Keep").?);
    // Both adds survive; set replaced in place when the name existed.
    const extras = countNamed(&resp, "X-Extra");
    try testing.expectEqual(@as(usize, 2), extras);
}

test "headers with no route or no ops passes through" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));

    const route = registry.Route{ .path = "/" };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
}

fn headerOf(resp: *const Response, name: []const u8) ?[]const u8 {
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn countNamed(resp: *const Response, name: []const u8) usize {
    var n: usize = 0;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) n += 1;
    }
    return n;
}
