const std = @import("std");
const registry = @import("../registry.zig");
const router = @import("../router.zig");
const sys = @import("../../sys.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// nginx `mirror` equivalent: fire-and-forget duplication of every request
/// to a shadow backend (`mirror addr:port;` on the route). The copy is sent
/// on a scratch connection with a bounded connect wait (10 ms) and the
/// shadow's response is never read; the real request proceeds unaffected.
/// Failures are silent by design.
pub const mirror = registry.Module{
    .name = "mirror",
    .phase = .rewrite,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const up = route.mirror orelse return .pass;
    sendMirror(ctx, &up) catch {}; // fire and forget
    return .pass;
}

fn sendMirror(ctx: *Context, up: *const router.Upstream) !void {
    const fd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    defer sys.close(fd);
    sys.connect(fd, &up.sockaddr, 16) catch |e| switch (e) {
        error.WouldBlock => {
            // In-progress connect: wait briefly; a slow shadow is skipped.
            var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
            if ((std.posix.poll(&pfds, 10) catch 0) == 0) return error.ConnectTimeout;
        },
        else => return e,
    };

    // Build the mirrored request into the request arena (reclaimed with the
    // request): request line, Host, forwarded headers (hop-by-hop removed),
    // Content-Length, body.
    const arena = ctx.req.arena.asAllocator();
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(arena);
    try buf.appendSlice(arena, methodName(ctx.req.method));
    try buf.appendSlice(arena, " ");
    try buf.appendSlice(arena, ctx.req.target);
    try buf.appendSlice(arena, " HTTP/1.1\r\nHost: ");
    try buf.appendSlice(arena, up.host);
    try buf.appendSlice(arena, ":");
    {
        var num_buf: [8]u8 = undefined;
        const port_s = std.fmt.bufPrint(&num_buf, "{d}", .{up.port}) catch return error.OutOfMemory;
        try buf.appendSlice(arena, port_s);
    }
    try buf.appendSlice(arena, "\r\n");
    for (0..ctx.req.headerCount()) |i| {
        const tag = ctx.req.headerTagAt(i);
        if (tag == .host or tag == .connection or tag == .content_length or tag == .transfer_encoding) continue;
        const h = ctx.req.headerAt(i);
        try buf.appendSlice(arena, h.name);
        try buf.appendSlice(arena, ": ");
        try buf.appendSlice(arena, h.value);
        try buf.appendSlice(arena, "\r\n");
    }
    try buf.appendSlice(arena, "Content-Length: ");
    {
        var num_buf: [24]u8 = undefined;
        const cl_s = std.fmt.bufPrint(&num_buf, "{d}", .{ctx.req.body.len}) catch return error.OutOfMemory;
        try buf.appendSlice(arena, cl_s);
    }
    try buf.appendSlice(arena, "\r\n\r\n");
    try buf.appendSlice(arena, ctx.req.body);

    var sent: usize = 0;
    while (sent < buf.items.len) {
        const n = sys.write(fd, buf.items[sent..]) catch return error.WriteFailed;
        sent += n;
    }
}

fn methodName(m: @import("../../http/parser.zig").Method) []const u8 {
    return switch (m) {
        .get => "GET",
        .head => "HEAD",
        .post => "POST",
        .put => "PUT",
        .delete => "DELETE",
        .options => "OPTIONS",
        .patch => "PATCH",
        .unknown => "GET",
    };
}

const testing = std.testing;

test "mirror forwards the request line, filtered headers and body" {
    const allocator = testing.allocator;
    // Shadow backend: a bound listener the module connects to.
    const sockets = @import("../../net/sockets.zig");
    const listener = try sockets.createListeningSocketReusePort(0, 4);
    defer sys.close(listener);
    const port = try sockets.boundPort(listener);

    var req = registry.Request.init(allocator);
    defer req.deinit();
    req.method = .post;
    req.target = "/shadow";
    req.body = "b";
    try req.addHeaderParsed("X-Test", "1");
    try req.addHeaderParsed("Host", "example");

    var resp = registry.Response.init(.ok);
    var route = router.Route{ .path = "/", .match = .prefix };
    route.mirror = .{
        .host = "127.0.0.1",
        .port = port,
        .sockaddr = router.Upstream.makeSockaddr("127.0.0.1", port).?,
    };
    var ctx = Context{ .req = &req, .resp = &resp, .allocator = allocator, .route = &route };

    try testing.expectEqual(Action.pass, try run(&ctx));

    // The shadow receives the mirrored request.
    const linux = std.os.linux;
    const conn = linux.accept4(listener, null, null, 0);
    if (linux.errno(conn) != .SUCCESS) return error.NoShadowConnection;
    defer sys.close(@intCast(conn));
    var got: [512]u8 = undefined;
    const n = try std.posix.read(@intCast(conn), &got);
    const seen = got[0..n];
    try testing.expect(std.mem.startsWith(u8, seen, "POST /shadow HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen, "Host: 127.0.0.1:") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "X-Test: 1\r\n") != null);
    // The client's Host is not duplicated (the mirror supplies its own).
    try testing.expect(std.mem.indexOf(u8, seen, "Host: example") == null);
    try testing.expect(std.mem.endsWith(u8, seen, "\r\n\r\nb"));
}
