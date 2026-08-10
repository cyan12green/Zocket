const std = @import("std");
const tcp_server = @import("tcp_server");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const port = 8080;
    std.debug.print("Starting TCP echo server on port {}\n", .{port});

    var server = try tcp_server.server.Server.init(allocator, port);
    defer server.deinit();

    try server.run();
}