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

const default_pidfile = "/tmp/zocket.pid";

const ServerOpts = struct {
    port: u16 = 8080,
    threads: ?usize = null,
    single: bool = false,
    mode: zocket.reactor.Mode = .http,
    config_path: ?[]const u8 = null,
    idle_timeout: u32 = zocket.reactor.default_idle_timeout_seconds,
    uring: bool = false,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: zocket [options]
        \\
        \\Server modes (default: run the HTTP server in the foreground):
        \\  --start              daemonize: fork + detach, write the pid file,
        \\                       exit when the listener is bound and ready
        \\  --stop               stop the daemon (sends SIGTERM; graceful drain)
        \\  --status             report whether the daemon is running
        \\
        \\Server options:
        \\  --port <n>           listen port (default 8080)
        \\  --threads <n>        reactor threads (default: CPU count)
        \\  --single             Milestone 1 single-threaded echo server
        \\  --echo               raw byte-echo protocol
        \\  --http               HTTP/1.1 + h2c prior-knowledge (default)
        \\  --config <file>      JSON config (routes + per-phase modules)
        \\  --idle-timeout <s>   connection idle timeout, 0 disables
        \\  --uring              use the io_uring I/O backend (experimental)
        \\  --pidfile <file>     pid file for --start/--stop/--status
        \\                       (default /tmp/zocket.pid)
        \\
        \\Utilities:
        \\  --validate           parse and validate the config, print the route
        \\                       table, then exit (0 = valid)
        \\  --version, -v        print the version
        \\  --help, -h           this help
        \\
    , .{});
}

/// Resolve the effective config: the build-time embedded config (DM2), the
/// runtime `--config` file (std.json at startup), or the comptime default.
/// The returned struct owns the config's memory (loaded) and the JSON buffer
/// (freed right after fromJson, which copies every string).
const ResolvedConfig = struct {
    cfg: zocket.runtime.config.Config,
    json_buf: ?[]u8 = null,
    loaded: ?zocket.runtime.config.Config = null,

    fn deinit(self: *ResolvedConfig, allocator: std.mem.Allocator) void {
        if (self.json_buf) |b| allocator.free(b);
        if (self.loaded) |*l| l.deinit(allocator);
    }
};

fn resolveConfig(
    allocator: std.mem.Allocator,
    embedded: ?zocket.runtime.config.Config,
    config_path: ?[]const u8,
) !ResolvedConfig {
    if (embedded) |cfg| return .{ .cfg = cfg };
    if (config_path) |p| {
        const json_buf = try std.fs.cwd().readFileAlloc(p, allocator, .limited(1 << 20));
        errdefer allocator.free(json_buf);
        var loaded = try zocket.runtime.config.Config.fromJson(allocator, json_buf);
        errdefer loaded.deinit(allocator);
        try loaded.validate(zocket.dsl.registry.default_registry);
        return .{ .cfg = loaded, .json_buf = json_buf, .loaded = loaded };
    }
    return .{ .cfg = zocket.runtime.config.Config.default() };
}

fn printConfigSummary(cfg: zocket.runtime.config.Config) void {
    std.debug.print("config OK: {d} routes\n", .{cfg.routes.len});
    for (cfg.routes) |r| {
        std.debug.print("  {s} [{s}]", .{
            r.path,
            switch (r.match) {
                .exact => "exact",
                .prefix => "prefix",
            },
        });
        for (r.modules) |b| {
            std.debug.print(" {s}@{s}", .{ b.module, b.phase.name() });
        }
        std.debug.print("\n", .{});
    }
}

/// Run the server: config resolution, multireactor init, reload wiring, then
/// the blocking event loop. `ready` (daemon mode) fires once the listeners
/// are bound, just before `run` enters its loop.
fn runServer(
    allocator: std.mem.Allocator,
    opts: ServerOpts,
    ready: ?*const fn (ctx: *anyopaque) void,
    ready_ctx: ?*anyopaque,
) !void {
    if (opts.single) {
        // Milestone 1 single-threaded echo server, kept for A/B comparison.
        var s = try zocket.server.Server.init(allocator, opts.port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{opts.port});
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
    var resolved = try resolveConfig(allocator, embedded_cfg, opts.config_path);
    defer resolved.deinit(allocator);

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
    if (resolved.loaded) |cfg| {
        http_srv = try zocket.runtime.server.Server.initWithTrie(allocator, cfg);
        http_srv_owns_trie = true;
    }
    defer if (http_srv_owns_trie) http_srv.deinit(allocator);

    const n = opts.threads orelse (std.Thread.getCpuCount() catch 1);
    var s = try zocket.multireactor.Server.initWithThreadsAndHandlerTimeout(allocator, opts.port, n, opts.mode, &http_srv, opts.idle_timeout);
    defer s.deinit();

    // Graceful reload (Milestone 13): SIGHUP re-parses the config and swaps
    // in a fresh reactor set; old connections drain on the old set. Only
    // meaningful with a runtime `--config` file (a build-time embedded config
    // is immutable); old handlers stay alive until process exit.
    zocket.multireactor.installSignalHandlers();
    var reload_handlers = std.ArrayList(*zocket.runtime.server.Server).empty;
    defer reload_handlers.deinit(allocator);
    if (embedded_cfg == null) {
        if (opts.config_path) |path| {
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

    switch (opts.mode) {
        .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ opts.port, n }),
        .http => {
            if (embedded_cfg) |cfg| {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (comptime-embedded config: {d} routes)\n", .{ opts.port, n, cfg.routes.len });
            } else if (opts.config_path) |p| {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (JSON config: {s})\n", .{ opts.port, n, p });
            } else {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (default config)\n", .{ opts.port, n });
            }
        },
    }
    if (opts.idle_timeout > 0) {
        std.debug.print("Idle timeout: {}s\n", .{opts.idle_timeout});
    } else {
        std.debug.print("Idle timeout: disabled\n", .{});
    }

    // Daemon mode: the listeners are bound (init above); signal readiness so
    // the parent can exit 0, then run.
    if (ready) |cb| cb(ready_ctx.?);

    try s.run();
}

fn writePidfile(path: []const u8, pid: posix_pid_t) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try f.writeAll(s);
}

const posix_pid_t = std.posix.pid_t;

fn startDaemon(allocator: std.mem.Allocator, opts: ServerOpts, pidfile: []const u8) !void {
    // Readiness handshake: the child writes 'R' once the listeners are
    // bound; the parent exits 0 on 'R', non-zero on EOF (child died).
    const fds = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        // ---- child: detach, then run the server ----
        std.posix.close(fds[0]);
        _ = std.posix.setsid() catch 0;
        // stdio to /dev/null: the daemon logs nowhere (a logfile flag could
        // redirect here later).
        const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch -1;
        if (devnull >= 0) {
            std.posix.dup2(devnull, 0) catch {};
            std.posix.dup2(devnull, 1) catch {};
            std.posix.dup2(devnull, 2) catch {};
            if (devnull > 2) std.posix.close(devnull);
        }
        const Daemon = struct {
            pipe_fd: std.posix.fd_t,
            pidfile: []const u8,
            pid: posix_pid_t,

            fn ready(ctx: *anyopaque) void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                writePidfile(d.pidfile, d.pid) catch {};
                _ = std.posix.write(d.pipe_fd, "R") catch {};
            }
        };
        var daemon = Daemon{
            .pipe_fd = fds[1],
            .pidfile = pidfile,
            .pid = std.posix.getpid(),
        };
        runServer(allocator, opts, &Daemon.ready, &daemon) catch {
            std.posix.exit(1);
        };
        // Graceful stop (--stop / SIGTERM): clean up the pid file.
        std.fs.cwd().deleteFile(pidfile) catch {};
        std.posix.exit(0);
    }

    // ---- parent: wait for readiness ----
    std.posix.close(fds[1]);
    var b: [1]u8 = undefined;
    const n = std.posix.read(fds[0], &b) catch 0;
    std.posix.close(fds[0]);
    if (n == 1 and b[0] == 'R') {
        std.debug.print("zocket started (pid {d}, pidfile {s})\n", .{ pid, pidfile });
        return;
    }
    std.debug.print("zocket failed to start\n", .{});
    std.process.exit(1);
}


/// SIG-0 liveness probe: this stdlib's SIG enum has no zero value, so the
/// raw syscall is used. False when the pid has exited (ESRCH); a live
/// process we may not signal (EPERM) counts as alive.
fn processAlive(pid: posix_pid_t) bool {
    const rc = std.os.linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, pid))), 0);
    const err = std.posix.errno(rc);
    return err == .SUCCESS or err == .PERM;
}

fn readPidfile(allocator: std.mem.Allocator, pidfile: []const u8) !posix_pid_t {
    const data = try std.fs.cwd().readFileAlloc(pidfile, allocator, .limited(64));
    defer allocator.free(data);
    return std.fmt.parseInt(posix_pid_t, std.mem.trim(u8, data, " \t\r\n"), 10);
}

fn stopDaemon(allocator: std.mem.Allocator, pidfile: []const u8) !void {
    const pid = readPidfile(allocator, pidfile) catch {
        std.debug.print("no pid file at {s} — nothing to stop\n", .{pidfile});
        return;
    };
    if (!processAlive(pid)) {
        // Stale pid file: the daemon is gone.
        std.fs.cwd().deleteFile(pidfile) catch {};
        std.debug.print("not running (stale pid file {s} removed)\n", .{pidfile});
        return;
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch return;
    // Graceful drain: poll for process exit (SIGTERM → graceful stop).
    var exited = false;
    for (0..100) |_| {
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
        if (!processAlive(pid)) {
            exited = true;
            break;
        }
    }
    std.fs.cwd().deleteFile(pidfile) catch {};
    if (exited) {
        std.debug.print("zocket stopped (pid {d})\n", .{pid});
    } else {
        std.debug.print("zocket pid {d} did not exit within 5s (check logs)\n", .{pid});
    }
}

fn statusDaemon(allocator: std.mem.Allocator, pidfile: []const u8) !void {
    const pid = readPidfile(allocator, pidfile) catch {
        std.debug.print("zocket not running (no pid file at {s})\n", .{pidfile});
        return;
    };
    if (!processAlive(pid)) {
        std.debug.print("zocket not running (stale pid file {s} has pid {d})\n", .{ pidfile, pid });
        return;
    }
    std.debug.print("zocket running (pid {d}, pidfile {s})\n", .{ pid, pidfile });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var opts = ServerOpts{};
    var pidfile: []const u8 = default_pidfile;
    var help = false;
    var show_version = false;
    var validate = false;
    var do_start = false;
    var do_stop = false;
    var do_status = false;

    var args = std.process.args();
    var arg_index: usize = 0;
    while (args.next()) |arg| {
        arg_index += 1;
        if (arg_index == 1) continue; // argv[0]: the program name
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.MissingPortArgument;
            opts.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const v = args.next() orelse return error.MissingThreadsArgument;
            opts.threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--idle-timeout")) {
            const v = args.next() orelse return error.MissingIdleTimeoutArgument;
            opts.idle_timeout = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--pidfile")) {
            pidfile = args.next() orelse return error.MissingPidfileArgument;
        } else if (std.mem.eql(u8, arg, "--single")) {
            opts.single = true;
        } else if (std.mem.eql(u8, arg, "--echo")) {
            opts.mode = .echo;
        } else if (std.mem.eql(u8, arg, "--http")) {
            opts.mode = .http;
        } else if (std.mem.eql(u8, arg, "--config")) {
            opts.config_path = args.next() orelse return error.MissingConfigArgument;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--start")) {
            do_start = true;
        } else if (std.mem.eql(u8, arg, "--stop")) {
            do_stop = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            do_status = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--uring")) {
            // Experimental: use the io_uring batch I/O path when available
            // (epoll is the default backend).
            zocket.reactor.force_epoll = false;
        } else {
            std.debug.print("zocket: unknown argument '{s}' (see --help)\n", .{arg});
            std.process.exit(1);
        }
    }

    if (help) {
        printUsage();
        return;
    }
    if (show_version) {
        std.debug.print("Zocket {s}\n", .{zocket.version.version});
        return;
    }

    if (validate) {
        // An explicit --config wins here: the user asks "is THIS file
        // valid?". The build-time embedded config is the fallback.
        if (opts.config_path) |p| {
            const json_buf = std.fs.cwd().readFileAlloc(p, allocator, .limited(1 << 20)) catch |e| {
                std.debug.print("zocket: cannot read config {s}: {s}\n", .{ p, @errorName(e) });
                std.process.exit(1);
            };
            defer allocator.free(json_buf);
            var loaded = zocket.runtime.config.Config.fromJson(allocator, json_buf) catch |e| {
                std.debug.print("zocket: config invalid: {s}\n", .{@errorName(e)});
                std.process.exit(1);
            };
            defer loaded.deinit(allocator);
            loaded.validate(zocket.dsl.registry.default_registry) catch |e| {
                std.debug.print("zocket: config invalid: {s}\n", .{@errorName(e)});
                std.process.exit(1);
            };
            printConfigSummary(loaded);
            return;
        }
        var resolved = resolveConfig(allocator, embedded_cfg, null) catch |e| {
            std.debug.print("zocket: config invalid: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer resolved.deinit(allocator);
        printConfigSummary(resolved.cfg);
        return;
    }
    if (do_stop) {
        try stopDaemon(allocator, pidfile);
        return;
    }
    if (do_status) {
        try statusDaemon(allocator, pidfile);
        return;
    }
    if (do_start) {
        try startDaemon(allocator, opts, pidfile);
        return;
    }

    try runServer(allocator, opts, null, null);
}
