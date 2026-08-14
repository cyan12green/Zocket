const std = @import("std");
const zocket = @import("zocket");
const build_options = @import("build_options");

/// DM2: comptime config as the primary path. When built with
/// `zig build -Dconfig=<file>`, the JSON config is embedded at compile time
/// and parsed by the DM1 validator; the server below is built with
/// `Server.comptimeInit`, so the route trie, dispatch functions,
/// pre-serialised response templates and upstream sockaddrs all live in
/// .rodata. Invalid configs are compile errors. Null when no build-time
/// config was given — the runtime `--config` path (secondary) or the default
/// config is used then.
const embedded_cfg: ?zocket.runtime.config.Config = if (build_options.config_path) |p|
    zocket.runtime.config.Config.fromEmbedded(p)
else null;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var port: u16 = 8080;
    var threads: ?usize = null;
    var single = false;
    var mode: zocket.reactor.Mode = .http;
    var config_path: ?[]const u8 = null;
    var show_version = false;
    var idle_timeout: u32 = zocket.reactor.default_idle_timeout_seconds;

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
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--uring")) {
            // Experimental: use the io_uring batch I/O path when available
            // (epoll is the default backend).
            zocket.reactor.force_epoll = false;
        }
    }

    if (show_version) {
        std.debug.print("Zocket {s}\n", .{zocket.version.version});
        return;
    }

    if (single) {
        // Milestone 1 single-threaded echo server, kept for A/B comparison.
        var s = try zocket.server.Server.init(allocator, port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{port});
        try s.run();
        return;
    }

    // HTTP mode runs through the config-driven pipeline (Milestone 4). The
    // config source is, in priority order:
    //   1. DM2: the config embedded at build time (`-Dconfig=<file>`); the
    //      server is built at compile time (trie + dispatch specialisation),
    //      everything in .rodata;
    //   2. the `--config` file, parsed at startup with std.json; its trie is
    //      built at startup and freed with the server (secondary path);
    //   3. the comptime default (echo on every path), as `Server.default()`.
    var json_buf: ?[]u8 = null;
    var loaded_cfg: ?zocket.runtime.config.Config = null;
    if (embedded_cfg == null) {
        if (config_path) |p| {
            json_buf = try std.fs.cwd().readFileAlloc(p, allocator, .limited(1 << 20));
            loaded_cfg = try zocket.runtime.config.Config.fromJson(allocator, json_buf.?);
            try loaded_cfg.?.validate(zocket.dsl.registry.default_registry);
        }
    }
    if (json_buf) |b| allocator.free(b);
    defer if (loaded_cfg) |*cfg| cfg.deinit(allocator);

    var http_srv: zocket.runtime.server.Server = if (embedded_cfg) |cfg| blk: {
        // DM2: module names are validated at startup (the DM1 comptime
        // parser checks structure/phases; registry membership is a runtime
        // check, consistent with the runtime `--config` path). Static roots
        // are resolved at startup too (realpath + O_PATH fd per rooted
        // route), mirroring the JSON load path.
        try cfg.validate(zocket.dsl.registry.default_registry);
        break :blk try zocket.runtime.server.Server.embeddedInit(allocator, cfg);
    } else
        zocket.runtime.server.Server.default();
    var http_srv_owns_trie = false;
    defer if (embedded_cfg != null) {
        http_srv.deinitPrepared(allocator);
    };
    if (loaded_cfg) |cfg| {
        http_srv = try zocket.runtime.server.Server.initWithTrie(allocator, cfg);
        http_srv_owns_trie = true;
    }
    defer if (http_srv_owns_trie) http_srv.deinit(allocator);

    const n = threads orelse (std.Thread.getCpuCount() catch 1);
    var s = try zocket.multireactor.Server.initWithThreadsAndHandlerTimeout(allocator, port, n, mode, &http_srv, idle_timeout);
    defer s.deinit();

    // Graceful reload (Milestone 13): SIGHUP re-parses the config and swaps
    // in a fresh reactor set; old connections drain on the old set. Only
    // meaningful with a runtime `--config` file (a build-time embedded config
    // is immutable); old handlers stay alive until process exit.
    zocket.multireactor.installSignalHandlers();
    var reload_handlers = std.ArrayList(*zocket.runtime.server.Server).empty;
    defer reload_handlers.deinit(allocator);
    if (embedded_cfg == null) {
        if (config_path) |path| {
        const ReloadState = struct {
            allocator: std.mem.Allocator,
            config_path: []const u8,
            handlers: *std.ArrayList(*zocket.runtime.server.Server),

            fn reload(userdata: *anyopaque) ?*const zocket.runtime.server.Server {
                const st: *@This() = @ptrCast(@alignCast(userdata));
                const json = std.fs.cwd().readFileAlloc(st.config_path, st.allocator, .limited(1 << 20)) catch return null;
                defer st.allocator.free(json);
                var cfg = zocket.runtime.config.Config.fromJson(st.allocator, json) catch return null;
                cfg.validate(zocket.dsl.registry.default_registry) catch return null;
                // The config memory must outlive the handler (the server's
                // route table points into it); it is freed at process exit
                // along with the handler itself (one leak per reload).
                const srv = st.allocator.create(zocket.runtime.server.Server) catch return null;
                srv.* = zocket.runtime.server.Server.initWithTrie(st.allocator, cfg) catch {
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
    }

    switch (mode) {
        .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ port, n }),
        .http => {
            if (embedded_cfg) |cfg| {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (comptime-embedded config: {d} routes)\n", .{ port, n, cfg.routes.len });
            } else if (config_path) |p| {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (JSON config: {s})\n", .{ port, n, p });
            } else {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (default config)\n", .{ port, n });
            }
        },
    }
    if (idle_timeout > 0) {
        std.debug.print("Idle timeout: {}s\n", .{idle_timeout});
    } else {
        std.debug.print("Idle timeout: disabled\n", .{});
    }
    try s.run();
}
