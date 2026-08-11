const std = @import("std");
const tcp_server = @import("tcp_server");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var threads: ?usize = null;
    var single = false;
    var mode: tcp_server.reactor.Mode = .http;
    var config_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--echo")) {
            mode = .echo;
        } else if (std.mem.eql(u8, arg, "--http")) {
            mode = .http;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return error.MissingConfigArgument;
        }
    }

    if (single) {
        // Milestone 1 single-threaded echo server, kept for A/B comparison.
        var s = try tcp_server.server.Server.init(allocator, port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{port});
        try s.run();
        return;
    }

    // HTTP mode runs through the config-driven pipeline (Milestone 4). The
    // default config (echo on every path) is a comptime struct literal; an
    // explicit JSON config is parsed at startup with std.json and lives for
    // the process duration.
    var json_buf: ?[]u8 = null;
    var loaded_cfg: ?tcp_server.runtime.config.Config = null;
    if (config_path) |p| {
        json_buf = try std.fs.cwd().readFileAlloc(p, allocator, .limited(1 << 20));
        loaded_cfg = try tcp_server.runtime.config.Config.fromJson(allocator, json_buf.?);
        try loaded_cfg.?.validate(tcp_server.dsl.registry.default_registry);
    }
    if (json_buf) |b| allocator.free(b);
    defer if (loaded_cfg) |*cfg| cfg.deinit(allocator);

    var http_srv: tcp_server.runtime.server.Server = tcp_server.runtime.server.Server.default();
    if (loaded_cfg) |cfg| http_srv = tcp_server.runtime.server.Server.init(cfg);

    const n = threads orelse (std.Thread.getCpuCount() catch 1);
    var s = try tcp_server.multireactor.Server.initWithThreadsAndHandler(allocator, port, n, mode, &http_srv);
    defer s.deinit();
    switch (mode) {
        .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ port, n }),
        .http => std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads\n", .{ port, n }),
    }
    try s.run();
}
