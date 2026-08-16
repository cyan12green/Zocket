const std = @import("std");
const testing = std.testing;
const zocket = @import("zocket");
const build_options = @import("build_options");

/// DM2: comptime config as the primary path. When built with
/// `zig build -Dconfig=<file>`, the conf file is embedded at compile time
/// and parsed by the comptime conf parser; the server below is built with
/// `Server.comptimeInit`, so the route trie, dispatch functions,
/// pre-serialised response templates and upstream sockaddrs all live in
/// .rodata. Invalid configs are compile errors. Null when no build-time
/// config was given — the default config is used then.
const embedded_cfg: ?zocket.runtime.config.Config = if (build_options.config_path) |p|
    zocket.runtime.config.Config.fromConfEmbedded(p)
else
    null;

const default_pidfile = "/tmp/zocket.pid";

const ServerOpts = struct {
    port: u16 = 8080,
    /// True when `--port` was given explicitly (the CLI wins over a conf
    /// `listen` directive; otherwise the conf's `listen_port` applies).
    port_set: bool = false,
    threads: ?usize = null,
    single: bool = false,
    mode: zocket.reactor.Mode = .http,
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
        \\  --stop               stop the daemon (sends SIGTERM; graceful
        \\                       drain of existing connections)
        \\  --status             report whether the daemon is running
        \\  --reload-hard        comptime reload: rebuild with the config
        \\                       embedded at compile time (config validated
        \\                       at compile time), start the new daemon,
        \\                       then hand off — old connections drain
        \\                       (zero downtime; the only reload — configs
        \\                       are comptime-only)
        \\
        \\Server options:
        \\  --port <n>           listen port (default 8080; a conf `listen`
        \\                       directive is overridden by this flag)
        \\  --threads <n>        reactor threads (default: CPU count)
        \\  --single             Milestone 1 single-threaded echo server
        \\  --echo               raw byte-echo protocol
        \\  --http               HTTP/1.1 + h2c prior-knowledge (default)
        \\  --idle-timeout <s>   connection idle timeout, 0 disables
        \\  --uring              use the io_uring I/O backend (experimental)
        \\  --pidfile <file>     pid file for --start/--stop/--status/
        \\                       --reload-hard (default /tmp/zocket.pid)
        \\
        \\Utilities:
        \\  --validate           validate the build-time config (compile-time
        \\                       configs are validated at build; this prints
        \\                       the route table and exits)
        \\  --version, -v        print the version
        \\  --help, -h           this help
        \\
    , .{});
}

fn printConfigSummary(cfg: zocket.runtime.config.Config) void {
    std.debug.print("config OK: {d} routes\n", .{cfg.routes.len});
    if (cfg.tls.enabled()) {
        std.debug.print("tls: enabled (cert {s}, key {s})\n", .{ cfg.tls.cert, cfg.tls.key });
    } else {
        std.debug.print("tls: disabled\n", .{});
    }
    for (cfg.routes) |r| {
        std.debug.print("  {s} [{s}]", .{
            r.path,
            switch (r.match) {
                .exact => "exact",
                .prefix => "prefix",
                .regex => "regex",
                .regex_ci => "regex_ci",
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
    //   2. the comptime default (echo on every path), as `Server.default()`.
    var http_srv: zocket.runtime.server.Server = if (embedded_cfg) |cfg| blk: {
        // DM2: registry membership is validated at compile time (comptime
        // conf parser checks structure/registry via comptimeValidate).
        // Static roots are resolved at startup too (realpath + O_PATH fd per
        // rooted route), mirroring the old JSON load path.
        comptime zocket.runtime.config.Config.comptimeValidate(cfg, zocket.dsl.registry.default_registry);
        break :blk try zocket.runtime.server.Server.embeddedInitWithTls(allocator, cfg);
    } else zocket.runtime.server.Server.default();
    defer if (embedded_cfg != null) {
        http_srv.deinitPrepared(allocator);
    };

    const n = opts.threads orelse (std.Thread.getCpuCount() catch 1);
    // Effective port: an explicit CLI --port wins; otherwise the conf's
    // `listen` directive applies; otherwise the 8080 default.
    const port = if (opts.port_set) opts.port else if (embedded_cfg) |cfg|
        (cfg.listen_port orelse opts.port)
    else
        opts.port;
    var s = try zocket.multireactor.Server.initWithThreadsAndHandlerTimeout(allocator, port, n, opts.mode, &http_srv, opts.idle_timeout);
    defer s.deinit();

    // Signal handlers: SIGTERM/SIGINT graceful stop. SIGHUP is not handled —
    // configs are comptime-only, so --reload-hard (rebuild + SO_REUSEPORT
    // swap) is the only reload.
    zocket.multireactor.installSignalHandlers();

    switch (opts.mode) {
        .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ port, n }),
        .http => {
            if (embedded_cfg) |cfg| {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (comptime-embedded config: {d} routes)\n", .{ port, n, cfg.routes.len });
            } else {
                std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (default config)\n", .{ port, n });
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
    // State for --reload-hard, built before the fork (the child inherits it
    // and writes it out at ready time). The config path is normalized to
    // project-root-relative: the comptime embed (`@embedFile`) resolves
    // against the project root, so --reload-hard can rebuild with it.
    const project_root = resolveProjectRoot(allocator);
    var recorded_config = build_options.config_path;
    if (project_root) |root| {
        if (recorded_config) |p| {
            if (std.fs.path.isAbsolute(p)) {
                recorded_config = std.fs.path.relative(allocator, root, p) catch p;
            }
        }
    }
    const state = StateFile{
        .config_path = recorded_config,
        // Record the effective port (CLI --port wins; else conf listen; else
        // 8080) so --reload-hard reproduces the daemon's listener.
        .port = if (opts.port_set) opts.port else if (embedded_cfg) |cfg|
            (cfg.listen_port orelse opts.port)
        else
            opts.port,
        .threads = opts.threads,
        .mode = @tagName(opts.mode),
        .idle_timeout = opts.idle_timeout,
        .uring = opts.uring,
        .single = opts.single,
        .embedded = embedded_cfg != null,
        .project_root = project_root,
    };
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
            state: StateFile,
            pid: posix_pid_t,

            fn ready(ctx: *anyopaque) void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                writePidfile(d.pidfile, d.pid) catch {};
                writeStateFile(std.heap.page_allocator, d.pidfile, d.state) catch {};
                _ = std.posix.write(d.pipe_fd, "R") catch {};
            }
        };
        var daemon = Daemon{
            .pipe_fd = fds[1],
            .pidfile = pidfile,
            .state = state,
            .pid = std.posix.getpid(),
        };
        runServer(allocator, opts, &Daemon.ready, &daemon) catch {
            std.posix.exit(1);
        };
        // Graceful stop (--stop / SIGTERM): remove the pid + state files,
        // but only while we still own them — a --reload-hard swap may have
        // already overwritten them with the new daemon's (same path).
        _ = cleanupOwnedFiles(allocator, pidfile);
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

/// Remove the pid + state files, but only while this process still owns
/// them. Returns true when removed. The ownership check closes the
/// --reload-hard race: the old daemon exits after the new daemon already
/// wrote the same pidfile path, and must not delete the new daemon's files.
fn cleanupOwnedFiles(allocator: std.mem.Allocator, pidfile: []const u8) bool {
    if (readPidfile(allocator, pidfile)) |pf| {
        if (pf == std.posix.getpid()) {
            std.fs.cwd().deleteFile(pidfile) catch {};
            if (stateFilePath(allocator, pidfile)) |sp| {
                std.fs.cwd().deleteFile(sp) catch {};
                allocator.free(sp);
            } else |_| {}
            return true;
        }
    } else |_| {}
    return false;
}

test "daemon cleanup only removes pid/state files it still owns (reload-hard race)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_abs);
    const pidfile = try std.fmt.allocPrint(allocator, "{s}/pid", .{tmp_abs});
    defer allocator.free(pidfile);
    // State file next to the pidfile.
    const state_path = try stateFilePath(allocator, pidfile);
    defer allocator.free(state_path);

    // Case 1: the pidfile names us -> cleanup removes pid + state files.
    try writePidfile(pidfile, std.posix.getpid());
    try writeStateFile(allocator, pidfile, .{});
    try testing.expect(cleanupOwnedFiles(allocator, pidfile));
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(pidfile, .{}));
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(state_path, .{}));

    // Case 2: a reload-hard swap already overwrote the pidfile with the NEW
    // daemon's pid -> the exiting old daemon must leave both files alone.
    try writePidfile(pidfile, std.posix.getpid() + 1);
    try writeStateFile(allocator, pidfile, .{});
    try testing.expect(!cleanupOwnedFiles(allocator, pidfile));
    try std.fs.cwd().access(pidfile, .{});
    try std.fs.cwd().access(state_path, .{});
    // The new daemon's files survive the old daemon's exit.
    const data = try std.fs.cwd().readFileAlloc(pidfile, allocator, .limited(64));
    defer allocator.free(data);
    // The pid file still names the NEW daemon (our pid + 1).
    const new_pid = try std.fmt.parseInt(posix_pid_t, std.mem.trim(u8, data, " \t\r\n"), 10);
    try testing.expectEqual(std.posix.getpid() + 1, new_pid);
}

fn stopDaemon(allocator: std.mem.Allocator, pidfile: []const u8) !void {
    const pid = readPidfile(allocator, pidfile) catch {
        std.debug.print("no pid file at {s} — nothing to stop\n", .{pidfile});
        return;
    };
    if (!processAlive(pid)) {
        // Stale pid file: the daemon is gone.
        std.fs.cwd().deleteFile(pidfile) catch {};
        if (stateFilePath(allocator, pidfile)) |sp| {
            std.fs.cwd().deleteFile(sp) catch {};
            allocator.free(sp);
        } else |_| {}
        std.debug.print("not running (stale pid file {s} removed)\n", .{pidfile});
        return;
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch return;
    // Graceful drain: poll for process exit (SIGTERM → graceful stop; the
    // drain cap is 30 s, so allow up to 35 s).
    var exited = false;
    for (0..700) |_| {
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
        if (!processAlive(pid)) {
            exited = true;
            break;
        }
    }
    std.fs.cwd().deleteFile(pidfile) catch {};
    if (stateFilePath(allocator, pidfile)) |sp| {
        std.fs.cwd().deleteFile(sp) catch {};
        allocator.free(sp);
    } else |_| {}
    if (exited) {
        std.debug.print("zocket stopped (pid {d})\n", .{pid});
    } else {
        std.debug.print("zocket pid {d} did not exit within 35s (check logs)\n", .{pid});
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

// ---- state file (--start records; --reload-hard consumes) ----

/// Everything needed to reproduce a daemon's build + start for
/// `--reload-hard`: written by the daemon child at --start next to the
/// pidfile (`<pidfile>.state`), read back by --reload-hard. The config
/// path is project-root-relative (same rule as `-Dconfig` at build time).
const StateFile = struct {
    config_path: ?[]const u8 = null,
    optimize: []const u8 = @tagName(@import("builtin").mode),
    port: u16 = 8080,
    threads: ?usize = null,
    mode: []const u8 = "http",
    idle_timeout: u32 = 0,
    uring: bool = false,
    single: bool = false,
    /// True when the daemon runs a comptime-embedded config (built with
    /// -Dconfig). Configs are comptime-only, so this is always true for
    /// daemons started from a build; --reload-hard is the only reload.
    embedded: bool = false,
    project_root: ?[]const u8 = null,
};

fn stateFilePath(allocator: std.mem.Allocator, pidfile: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.state", .{pidfile});
}

fn writeStateFile(allocator: std.mem.Allocator, pidfile: []const u8, state: StateFile) !void {
    const path = try stateFilePath(allocator, pidfile);
    defer allocator.free(path);
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(json);
}

/// Read the state file; strings are duped into `allocator` (free with
/// `freeStateFile`). Missing or unparseable file is an error.
fn readStateFile(allocator: std.mem.Allocator, pidfile: []const u8) !StateFile {
    const path = try stateFilePath(allocator, pidfile);
    defer allocator.free(path);
    const json = try std.fs.cwd().readFileAlloc(path, allocator, .limited(8192));
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(StateFile, allocator, json, .{});
    defer parsed.deinit();
    var out = parsed.value;
    if (out.config_path) |p| out.config_path = try allocator.dupe(u8, p);
    out.optimize = try allocator.dupe(u8, out.optimize);
    out.mode = try allocator.dupe(u8, out.mode);
    if (out.project_root) |p| out.project_root = try allocator.dupe(u8, p);
    return out;
}

fn freeStateFile(allocator: std.mem.Allocator, state: *StateFile) void {
    if (state.config_path) |p| allocator.free(p);
    allocator.free(state.optimize);
    allocator.free(state.mode);
    if (state.project_root) |p| allocator.free(p);
}

/// Walk up from the executable until a directory with `build.zig.zon` is
/// found: the project root for `--reload-hard` rebuilds. Null when the
/// binary was copied out of the tree (deployed), in which case a rebuild
/// is impossible.
fn resolveProjectRoot(allocator: std.mem.Allocator) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.posix.readlink("/proc/self/exe", &buf) catch return null;
    var dir = std.fs.path.dirname(exe) orelse return null;
    while (true) {
        const marker = std.fs.path.join(allocator, &.{ dir, "build.zig.zon" }) catch return null;
        defer allocator.free(marker);
        if (std.fs.cwd().access(marker, .{})) |_| {
            return allocator.dupe(u8, dir) catch null;
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// Rebuild the binary with the config embedded at compile time (DM2). Runs
/// `zig build` in `project_root` with the recorded optimization mode (zig
/// from PATH; compile errors go to the terminal). The config is validated
/// by the comptime JSON parser: compile errors are config errors and abort
/// the reload — the old daemon keeps serving untouched.
fn rebuild(allocator: std.mem.Allocator, project_root: []const u8, config_path: []const u8, optimize: []const u8) !void {
    const opt_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
    defer allocator.free(opt_flag);
    const cfg_flag = try std.fmt.allocPrint(allocator, "-Dconfig={s}", .{config_path});
    defer allocator.free(cfg_flag);
    const argv = [_][]const u8{ "zig", "build", opt_flag, cfg_flag };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = project_root;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.RebuildFailed;
        },
        else => return error.RebuildFailed,
    }
}

/// Comptime reload (--reload-hard): rebuild the binary with the config
/// embedded at compile time, start the new daemon, then hand off — the old
/// daemon drains (stops accepting, closes its SO_REUSEPORT listeners,
/// finishes its connections within the 30 s cap) and exits. Zero downtime
/// for new connections: both daemons bind the port via SO_REUSEPORT while
/// the old one drains. Invalid configs abort at compile time.
fn hardReload(allocator: std.mem.Allocator, opts: ServerOpts, pidfile: []const u8) !void {
    _ = opts;
    const old_pid = readPidfile(allocator, pidfile) catch {
        std.debug.print("zocket: no pid file at {s} — nothing to reload\n", .{pidfile});
        return;
    };
    if (!processAlive(old_pid)) {
        std.debug.print("zocket: daemon pid {d} is not running (stale pid file)\n", .{old_pid});
        return;
    }
    var state = readStateFile(allocator, pidfile) catch {
        std.debug.print("zocket: no state file (run --start first) — nothing to reload\n", .{});
        return;
    };
    defer freeStateFile(allocator, &state);

    // Config source: the recorded path from --start. The comptime embed
    // (@embedFile) can only reach files inside the project tree, so the
    // config must resolve there; normalize absolute paths against the
    // recorded project root.
    var config_path = state.config_path orelse {
        std.debug.print("zocket: no config to recompile (daemon started without one)\n", .{});
        return;
    };
    const project_root = state.project_root orelse {
        std.debug.print("zocket: project root unknown (binary outside the source tree?) — cannot rebuild\n", .{});
        return;
    };
    if (std.fs.path.isAbsolute(config_path)) {
        const rel = std.fs.path.relative(allocator, project_root, config_path) catch config_path;
        if (std.fs.path.isAbsolute(rel) or std.mem.startsWith(u8, rel, "../")) {
            std.debug.print("zocket: config {s} lies outside the project tree ({s}) — a comptime embed cannot reach it\n", .{ config_path, project_root });
            return;
        }
        config_path = rel;
    }

    std.debug.print("zocket: rebuilding with -Dconfig={s} (config validated at compile time)...\n", .{config_path});
    rebuild(allocator, project_root, config_path, state.optimize) catch |e| {
        std.debug.print("zocket: rebuild failed ({s}) — old daemon untouched\n", .{@errorName(e)});
        std.process.exit(1);
    };

    // Start the new daemon by exec'ing the freshly built binary with the
    // recorded options via `--start` (bind → pid/state files → readiness
    // handshake → exit 0). The config is baked into the binary at compile
    // time (configs are comptime-only). SO_REUSEPORT: both daemons bind the
    // port while the old one drains, so there is no acceptance gap.
    const exe_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/zocket", .{project_root});
    defer allocator.free(exe_path);
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{state.port});
    defer allocator.free(port_str);
    const idle_str = try std.fmt.allocPrint(allocator, "{d}", .{state.idle_timeout});
    defer allocator.free(idle_str);
    // NOTE: every string appended to `argv` must outlive the spawn; the
    // frees are deferred to the end of this function, after the exec.
    const threads_str: ?[]const u8 = if (state.threads) |t|
        try std.fmt.allocPrint(allocator, "{d}", .{t})
    else
        null;
    defer if (threads_str) |s| allocator.free(s);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.append(allocator, "--start");
    try argv.append(allocator, "--port");
    try argv.append(allocator, port_str);
    if (state.threads) |_| {
        try argv.append(allocator, "--threads");
        try argv.append(allocator, threads_str.?);
    }
    try argv.append(allocator, "--idle-timeout");
    try argv.append(allocator, idle_str);
    try argv.append(allocator, "--pidfile");
    try argv.append(allocator, pidfile);
    if (state.uring) try argv.append(allocator, "--uring");
    if (state.single) {
        try argv.append(allocator, "--single");
    } else {
        try argv.append(allocator, if (std.mem.eql(u8, state.mode, "echo")) "--echo" else "--http");
    }
    var new_child = std.process.Child.init(argv.items, allocator);
    const term = try new_child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.NewDaemonFailed;
        },
        else => return error.NewDaemonFailed,
    }
    std.debug.print("zocket: new daemon up (config compiled in)\n", .{});

    // Hand off: the old daemon drains and exits (30 s cap + margin).
    std.debug.print("zocket: handing off from pid {d} (graceful drain)...\n", .{old_pid});
    std.posix.kill(old_pid, std.posix.SIG.TERM) catch |e| {
        std.debug.print("zocket: cannot signal old daemon: {s}\n", .{@errorName(e)});
        return;
    };
    var exited = false;
    for (0..800) |_| {
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
        if (!processAlive(old_pid)) {
            exited = true;
            break;
        }
    }
    if (exited) {
        std.debug.print("zocket: reload complete — old daemon {d} drained and exited\n", .{old_pid});
    } else {
        std.debug.print("zocket: old daemon {d} still draining past 40s\n", .{old_pid});
    }
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
    var do_reload_hard = false;

    var args = std.process.args();
    var arg_index: usize = 0;
    while (args.next()) |arg| {
        arg_index += 1;
        if (arg_index == 1) continue; // argv[0]: the program name
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.MissingPortArgument;
            opts.port = try std.fmt.parseInt(u16, v, 10);
            opts.port_set = true;
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
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--start")) {
            do_start = true;
        } else if (std.mem.eql(u8, arg, "--stop")) {
            do_stop = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            do_status = true;
        } else if (std.mem.eql(u8, arg, "--reload-hard")) {
            do_reload_hard = true;
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
        // Configs are compile-time validated by `-Dconfig`; --validate prints
        // the built route table (the embedded config, or the default).
        if (embedded_cfg) |cfg| {
            printConfigSummary(cfg);
        } else {
            printConfigSummary(zocket.runtime.config.Config.default());
        }
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
    if (do_reload_hard) {
        try hardReload(allocator, opts, pidfile);
        return;
    }
    if (do_start) {
        try startDaemon(allocator, opts, pidfile);
        return;
    }

    try runServer(allocator, opts, null, null);
}
