//! HTTP Basic authentication (nginx `auth_basic` equivalent). Access phase:
//! verifies the Authorization header against the route's comptime-embedded
//! htpasswd table (see dsl/htpasswd.zig). On success the chain continues;
//! otherwise a 401 with the WWW-Authenticate challenge claims the request.
//!
//! Config surface (`Route.auth_basic_realm`/`auth_basic_users`, parsed from
//! conf — directive presence auto-binds the module):
//!   auth_basic "Restricted Area";
//!   auth_basic_user_file "testdata/htpasswd";

const std = @import("std");
const registry = @import("../registry.zig");
const htpasswd = @import("../htpasswd.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;
pub const Request = registry.Request;
pub const Response = registry.Response;
pub const Status = registry.Status;

/// Largest Basic credential we accept (base64 of user:password); longer is
/// rejected as malformed rather than decoded.
const max_credentials = 256;

pub const auth_basic = registry.Module{
    .name = "auth_basic",
    .phase = .access,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    // Both halves must be configured; either alone stays inert so partial
    // configs fail open into plain HTTP instead of locking everything out.
    const realm = route.auth_basic_realm orelse return .pass;
    if (route.auth_basic_users.len == 0) return .pass;

    const auth = ctx.req.header("authorization") orelse return unauthorized(ctx, realm);
    const trimmed = std.mem.trim(u8, auth, " \t");
    if (trimmed.len < 7 or !std.ascii.eqlIgnoreCase(trimmed[0..5], "Basic") or trimmed[5] != ' ') {
        return unauthorized(ctx, realm);
    }
    const encoded = std.mem.trim(u8, trimmed[6..], " \t");
    if (encoded.len == 0 or encoded.len > max_credentials) return unauthorized(ctx, realm);

    var dec_buf: [max_credentials]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return unauthorized(ctx, realm);
    if (size > dec_buf.len) return unauthorized(ctx, realm);
    decoder.decode(dec_buf[0..size], encoded) catch return unauthorized(ctx, realm);

    const colon = std.mem.indexOfScalar(u8, dec_buf[0..size], ':') orelse
        return unauthorized(ctx, realm);
    const user = dec_buf[0..colon];
    const password = dec_buf[colon + 1 .. size];

    if (htpasswd.authenticate(route.auth_basic_users, user, password)) return .pass;
    return unauthorized(ctx, realm);
}

fn unauthorized(ctx: *Context, realm: []const u8) Action {
    ctx.resp.status = .unauthorized;
    ctx.resp.setBody(registry.Status.unauthorized.reasonPhrase());
    ctx.resp.setHeaderFmt("WWW-Authenticate", "Basic realm=\"{s}\", charset=\"UTF-8\"", .{realm});
    return .handled;
}

const testing = std.testing;

test "missing/malformed credentials get a 401 challenge" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{
        .path = "/",
        .auth_basic_realm = "Sec",
        .auth_basic_users = &.{.{ .user = "alice", .kind = .plain, .secret = "pw" }},
    };

    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(Status.unauthorized, resp.status);
    try testing.expectEqualStrings("Unauthorized", resp.body);
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "WWW-Authenticate")) {
            try testing.expectEqualStrings("Basic realm=\"Sec\", charset=\"UTF-8\"", h.value);
        }
    }
}

test "correct credentials pass, wrong ones are challenged" {
    const users = [_]htpasswd.Entry{
        .{ .user = "alice", .kind = .plain, .secret = "secret-pw" },
    };
    const cases = [_]struct {
        auth: []const u8,
        want: Action,
    }{
        // base64("alice:secret-pw")
        .{ .auth = "Basic YWxpY2U6c2VjcmV0LXB3", .want = .pass },
        // base64("alice:wrong")
        .{ .auth = "Basic YWxpY2U6d3Jvbmc=", .want = .handled },
        // base64("bob:secret-pw") — unknown user
        .{ .auth = "Basic Ym9iOnNlY3JldC1wdw==", .want = .handled },
        .{ .auth = "Bearer whatever", .want = .handled },
    };
    for (cases) |c| {
        var req = Request.init(testing.allocator);
        defer req.deinit();
        req.addHeaderParsed("Authorization", c.auth) catch unreachable;
        var resp = Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.route = &.{ .path = "/", .auth_basic_realm = "R", .auth_basic_users = &users };
        try testing.expectEqual(c.want, try run(&ctx));
    }
}

test "inert without realm or without users" {
    var req = Request.init(testing.allocator);
    defer req.deinit();
    var resp = Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/" };
    try testing.expectEqual(Action.pass, try run(&ctx));

    ctx.route = &.{ .path = "/", .auth_basic_realm = "R" };
    try testing.expectEqual(Action.pass, try run(&ctx));

    ctx.route = &.{ .path = "/", .auth_basic_users = &.{.{ .user = "a", .kind = .plain, .secret = "b" }} };
    try testing.expectEqual(Action.pass, try run(&ctx));
}
