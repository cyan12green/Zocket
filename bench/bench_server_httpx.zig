//! Temporary benchmark server: GET / -> 200 with an empty body (mirrors
//! Ziglet's default catch-all behavior), POST /echo -> body echo, and
//! GET /static -> a file loaded into memory at startup (--static <path>;
//! httpx.zig has no sendfile path, so the file is preloaded, documented in
//! BENCH.md).

const std = @import("std");
const httpx = @import("httpx");

var static_bytes: []const u8 = &.{};

fn emptyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("");
}

fn echoHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const body = ctx.request.body orelse "";
    return ctx.text(body);
}

fn staticHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text(static_bytes);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var static_path: ?[]const u8 = null;
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
        } else if (std.mem.eql(u8, arg, "--static")) {
            static_path = args.next() orelse return error.MissingStatic;
        }
    }

    if (static_path) |p| {
        const data = try std.fs.cwd().readFileAlloc(p, allocator, .limited(64 * 1024 * 1024));
        static_bytes = data;
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
    try server.get("/static", staticHandler);
    std.debug.print("httpx bench server on 127.0.0.1:{d}\n", .{port});
    try server.listen();
}
