const std = @import("std");
const registry = @import("../registry.zig");
const http_response = @import("../../http/response.zig");

/// Largest request body the echo module echoes. Since Milestone 14 the body
/// goes out via writev (never through the send buffer), so the limit is the
/// receive buffer's growth cap (`connection.Connection.max_recv_buffer`):
/// anything the reactor can buffer can be echoed zero-copy.
pub const max_echo_body = 16 * 1024 * 1024;

/// The echo content module: responds 200 OK with the request body echoed,
/// byte-identical to the Milestone 3 hardcoded HTTP handler. Bodies larger
/// than the echo cap get a 413 and ask the connection to close, exactly like
/// the pre-pipeline reactor path.
pub const echo: registry.Module = .{
    .name = "echo",
    .phase = .content,
    .run = run,
};

fn run(ctx: *registry.Context) !registry.Action {
    // Config `limits.max_body` overrides the compiled default.
    const max_body = if (ctx.limits) |l| l.max_body else max_echo_body;
    if (ctx.req.body.len > max_body) {
        // Mutate in place: earlier-phase modules (cache headers, conditional
        // GETs) may have set response state that must survive content.
        ctx.resp.status = .payload_too_large;
        ctx.resp.setBody(http_response.Status.payload_too_large.reasonPhrase());
        ctx.close_after_write = true;
        return .handled;
    }
    ctx.resp.status = .ok;
    ctx.resp.body = if (ctx.req.body.len > 0) ctx.req.body else &.{};
    return .handled;
}

const testing = std.testing;

test "echo module responds with the request body" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.body = "the payload";

    var resp = http_response.Response.init(.ok);
    var ctx = registry.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(registry.Action.handled, try run(&ctx));
    try testing.expectEqual(http_response.Status.ok, resp.status);
    try testing.expectEqualStrings("the payload", resp.body);
    try testing.expect(!ctx.close_after_write);
}

test "echo module rejects oversized bodies with 413 and close" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    // 16 MiB does not fit a test stack; allocate.
    const body = try testing.allocator.alloc(u8, max_echo_body + 1);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    req.body = body;

    var resp = http_response.Response.init(.ok);
    var ctx = registry.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(registry.Action.handled, try run(&ctx));
    try testing.expectEqual(http_response.Status.payload_too_large, resp.status);
    try testing.expect(ctx.close_after_write);
}

test "empty body produces an empty 200" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();

    var resp = http_response.Response.init(.ok);
    var ctx = registry.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(registry.Action.handled, try run(&ctx));
    try testing.expectEqual(http_response.Status.ok, resp.status);
    try testing.expectEqual(@as(usize, 0), resp.body.len);
}
