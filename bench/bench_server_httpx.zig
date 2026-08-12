//! Temporary benchmark server: fixed port, GET / -> 200 with an empty body
//! (mirrors tcp-server's default catch-all behavior for comparison).

const std = @import("std");
const httpx = @import("httpx");

fn emptyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("");
}

fn echoHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const body = ctx.request.body orelse "";
    return ctx.text(body);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
        }
    }

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .max_connections = 10000,
        .keep_alive = true,
        .threads = 4,
    });
    defer server.deinit();

    try server.get("/", emptyHandler);
    try server.post("/echo", echoHandler);
    std.debug.print("httpx bench server on 127.0.0.1:{d}\n", .{port});
    try server.listen();
}
