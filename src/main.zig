const std = @import("std");
const tcp_server = @import("tcp_server");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var threads: ?usize = null;
    var single = false;

    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.MissingPortArgument;
            port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const v = args.next() orelse return error.MissingThreadsArgument;
            threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--single")) {
            single = true;
        }
    }

    if (single) {
        // Milestone 1 single-threaded server, kept for A/B comparison.
        var s = try tcp_server.server.Server.init(allocator, port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{port});
        try s.run();
        return;
    }

    const n = threads orelse (std.Thread.getCpuCount() catch 1);
    var s = try tcp_server.multireactor.Server.initWithThreads(allocator, port, n);
    defer s.deinit();
    std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ port, n });
    try s.run();
}
