const std = @import("std");
const ziglet = @import("ziglet");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var threads: ?usize = null;
    var single = false;
    var mode: ziglet.reactor.Mode = .http;
    var config_path: ?[]const u8 = null;
    var idle_timeout: u32 = ziglet.reactor.default_idle_timeout_seconds;

    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.MissingPortArgument;
            port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const v = args.next() orelse return error.MissingThreadsArgument;
            threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--idle-timeout")) {
            const v = args.next() orelse return error.MissingIdleTimeoutArgument;
            idle_timeout = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--single")) {
            single = true;
        } else if (std.mem.eql(u8, arg, "--echo")) {
            mode = .echo;
        } else if (std.mem.eql(u8, arg, "--http")) {
            mode = .http;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return error.MissingConfigArgument;
        } else if (std.mem.eql(u8, arg, "--uring")) {
            // Experimental: use the io_uring batch I/O path when available
            // (epoll is the default backend).
            ziglet.reactor.force_epoll = false;
        }
    }

    if (single) {
        // Milestone 1 single-threaded echo server, kept for A/B comparison.
        var s = try ziglet.server.Server.init(allocator, port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{port});
        try s.run();
        return;
    }

    // HTTP mode runs through the config-driven pipeline (Milestone 4). The
    // default config (echo on every path) is a comptime struct literal: its
    // route trie and per-route dispatch functions are built at compile time
    // (Milestone 7). An explicit JSON config is parsed at startup with
    // std.json; its trie is built at startup and freed with the server.
    var json_buf: ?[]u8 = null;
    var loaded_cfg: ?ziglet.runtime.config.Config = null;
    if (config_path) |p| {
        json_buf = try std.fs.cwd().readFileAlloc(p, allocator, .limited(1 << 20));
        loaded_cfg = try ziglet.runtime.config.Config.fromJson(allocator, json_buf.?);
        try loaded_cfg.?.validate(ziglet.dsl.registry.default_registry);
    }
    if (json_buf) |b| allocator.free(b);
    defer if (loaded_cfg) |*cfg| cfg.deinit(allocator);

    var http_srv: ziglet.runtime.server.Server = ziglet.runtime.server.Server.default();
    var http_srv_owns_trie = false;
    if (loaded_cfg) |cfg| {
        http_srv = try ziglet.runtime.server.Server.initWithTrie(allocator, cfg);
        http_srv_owns_trie = true;
    }
    defer if (http_srv_owns_trie) http_srv.deinit(allocator);

    const n = threads orelse (std.Thread.getCpuCount() catch 1);
    var s = try ziglet.multireactor.Server.initWithThreadsAndHandlerTimeout(allocator, port, n, mode, &http_srv, idle_timeout);
    defer s.deinit();

    // Graceful reload (Milestone 13): SIGHUP re-parses the config and swaps
    // in a fresh reactor set; old connections drain on the old set. Only
    // meaningful with --config; old handlers stay alive until process exit.
    ziglet.multireactor.installSignalHandlers();
    var reload_handlers = std.ArrayList(*ziglet.runtime.server.Server).empty;
    defer reload_handlers.deinit(allocator);
    if (config_path) |path| {
        const ReloadState = struct {
            allocator: std.mem.Allocator,
            config_path: []const u8,
            handlers: *std.ArrayList(*ziglet.runtime.server.Server),

            fn reload(userdata: *anyopaque) ?*const ziglet.runtime.server.Server {
                const st: *@This() = @ptrCast(@alignCast(userdata));
                const json = std.fs.cwd().readFileAlloc(st.config_path, st.allocator, .limited(1 << 20)) catch return null;
                defer st.allocator.free(json);
                var cfg = ziglet.runtime.config.Config.fromJson(st.allocator, json) catch return null;
                cfg.validate(ziglet.dsl.registry.default_registry) catch return null;
                // The config memory must outlive the handler (the server's
                // route table points into it); it is freed at process exit
                // along with the handler itself (one leak per reload).
                const srv = st.allocator.create(ziglet.runtime.server.Server) catch return null;
                srv.* = ziglet.runtime.server.Server.initWithTrie(st.allocator, cfg) catch {
                    st.allocator.destroy(srv);
                    return null;
                };
                st.handlers.append(st.allocator, srv) catch {
                    st.allocator.destroy(srv);
                    return null;
                };
                std.debug.print("reload: config re-parsed\n", .{});
                return srv;
            }
        };
        var reload_state = ReloadState{
            .allocator = allocator,
            .config_path = path,
            .handlers = &reload_handlers,
        };
        s.reload_fn = ReloadState.reload;
        s.reload_userdata = &reload_state;
    }

    switch (mode) {
        .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ port, n }),
        .http => std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads\n", .{ port, n }),
    }
    if (idle_timeout > 0) {
        std.debug.print("Idle timeout: {}s\n", .{idle_timeout});
    } else {
        std.debug.print("Idle timeout: disabled\n", .{});
    }
    try s.run();
}
