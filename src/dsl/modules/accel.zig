//! X-Accel-Redirect (nginx internal file redirect): a backend answers
//! with `X-Accel-Redirect: /internal/path` instead of a body, and the
//! server re-walks the new URI (same redirect loop as error_page/try_files,
//! capped at 8 hops by `Server.handleRequest`). Bound by `accel on;` in
//! the log phase (runs after every outcome, so proxied responses qualify).
//!
//! Only same-method GET-safe targets redirect (nginx downgrades methods;
//! here only GET/HEAD proceed, others pass through with the header intact
//! stripped? No — non-GET/HEAD keep the header and the original body).

const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const accel = registry.Module{
    .name = "accel",
    .phase = .log,
    .run = run,
    .directives = &.{"accel"},
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (!route.accel_enabled) return .pass;
    const target = headerValue(ctx.resp, "X-Accel-Redirect") orelse return .pass;
    if (target.len == 0 or target[0] != '/') return .pass;
    // GET/HEAD only (mirrors error_page's downgrade rule in reverse:
    // unsafe methods keep the backend's answer untouched).
    if (ctx.req.method != .get and ctx.req.method != .head) return .pass;
    removeHeader(ctx.resp, "X-Accel-Redirect");
    ctx.internal_redirect_target = target;
    return .pass;
}

fn headerValue(resp: *const registry.Response, comptime name: []const u8) ?[]const u8 {
    const parser = @import("../../http/parser.zig");
    for (resp.headers[0..resp.header_count]) |h| {
        if (parser.header_hasher.hash(h.name) == comptime parser.header_hasher.hash(name)) return h.value;
    }
    return null;
}

fn removeHeader(resp: *registry.Response, comptime name: []const u8) void {
    const parser = @import("../../http/parser.zig");
    var i: usize = 0;
    while (i < resp.header_count) {
        if (parser.header_hasher.hash(resp.headers[i].name) == comptime parser.header_hasher.hash(name)) {
            var j = i;
            while (j + 1 < resp.header_count) : (j += 1) {
                resp.headers[j] = resp.headers[j + 1];
            }
            resp.header_count -= 1;
        } else {
            i += 1;
        }
    }
}

const testing = std.testing;

test "accel redirects GETs to the internal target, header stripped" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    var resp = registry.Response.init(.ok);
    resp.setBody("backend-body");
    resp.setHeader("X-Accel-Redirect", "/internal/file");
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .accel_enabled = true };
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("/internal/file", ctx.internal_redirect_target.?);
    try testing.expect(headerValue(&resp, "X-Accel-Redirect") == null);
}

test "accel stays inert without the flag, header, or on POST" {
    const run_case = struct {
        fn go(accel_on: bool, method: @FieldType(registry.Request, "method"), hdr: bool) !?[]const u8 {
            var req = registry.Request.init(testing.allocator);
            defer req.deinit();
            req.method = method;
            var resp = registry.Response.init(.ok);
            if (hdr) resp.setHeader("X-Accel-Redirect", "/x");
            var ctx = Context{ .req = &req, .resp = &resp };
            ctx.route = &.{ .path = "/", .accel_enabled = accel_on };
            try testing.expectEqual(Action.pass, try run(&ctx));
            return ctx.internal_redirect_target;
        }
    }.go;
    try testing.expect(try run_case(false, .get, true) == null);
    try testing.expect(try run_case(true, .get, false) == null);
    try testing.expect(try run_case(true, .post, true) == null);
}
