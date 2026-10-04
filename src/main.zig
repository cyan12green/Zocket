const std = @import("std");
const testing = std.testing;
const zocket = @import("zocket");
const compat = zocket.compat;
const build_options = @import("build_options");
const shmem_mod = zocket.dsl.shmem;

/// Comptime config is the primary path. When built with
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
        \\  --single             single-threaded echo server (A/B baseline)
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
        // Single-threaded echo server, kept for A/B comparison.
        var s = try zocket.server.Server.init(allocator, opts.port);
        defer s.deinit();
        std.debug.print("Starting single-threaded TCP echo server on port {}\n", .{opts.port});
        try s.run();
        return;
    }

    const n = opts.threads orelse (std.Thread.getCpuCount() catch 1);

    // Build the server group: one Server per server {} block, each with its
    // own route table, trie, dispatch and per-server stats.
    const embedded = embedded_cfg;
    var http_group: zocket.runtime.server.ServerGroup = if (embedded) |cfg| blk: {
        comptime zocket.runtime.config.Config.comptimeValidate(cfg, zocket.dsl.registry.default_registry);
        break :blk try zocket.runtime.server.ServerGroup.embeddedInitGroupWithTls(allocator, cfg);
    } else blk: {
        const srv = zocket.runtime.server.Server.default();
        break :blk .{ .servers = &[_]zocket.runtime.server.Server{srv}, .default_idx = 0, .host_select = false };
    };
    defer {
        if (embedded != null) {
            var i: usize = 0;
            while (i < http_group.servers.len) : (i += 1) {
                @constCast(&http_group.servers[i]).deinitPrepared(allocator);
            }
            if (http_group.servers_owned) allocator.free(http_group.servers);
        }
    }

    // Collect unique listen ports from server blocks.
    const effective_port = if (opts.port_set) opts.port else if (embedded) |cfg|
        (cfg.listen_port orelse opts.port)
    else
        opts.port;
    var ports_buf: [16]u16 = undefined;
    const ports: []const u16 = if (opts.port_set or http_group.servers.len <= 1)
        &.{effective_port}
    else blk: {
        var count: usize = 0;
        for (http_group.servers) |srv| {
            const p = srv.cfg.listen_port orelse effective_port;
            var dup = false;
            for (ports_buf[0..count]) |ep| {
                if (ep == p) {
                    dup = true;
                    break;
                }
            }
            if (!dup and count < 16) {
                ports_buf[count] = p;
                count += 1;
            }
        }
        if (count == 0) {
            ports_buf[0] = effective_port;
            count = 1;
        }
        break :blk ports_buf[0..count];
    };

    // Per-port server subgroups: each multireactor serves only the
    // servers listening on its port (nginx: the first block on a listen
    // socket is that socket's default). Host selection runs within the
    // subgroup, so a request can never land on another port's routes.
    // Shallow copies sharing the parent's route tables and stats; the
    // parent group owns all deinit.
    var sub_servers: [16][16]zocket.runtime.server.Server = undefined;
    var subgroups: [16]zocket.runtime.server.ServerGroup = undefined;
    const global_listen = if (embedded) |cfg| cfg.listen_port else null;
    for (ports, 0..) |p, pi| {
        var nsub: usize = 0;
        for (http_group.servers) |*srv| {
            // --port overrides every block (legacy single-reactor path).
            if (opts.port_set) {
                sub_servers[pi][nsub] = srv.*;
                nsub += 1;
                continue;
            }
            const ep = srv.cfg.listen_port orelse global_listen orelse effective_port;
            if (ep == p) {
                sub_servers[pi][nsub] = srv.*;
                nsub += 1;
            }
        }
        if (nsub == 0) { // cannot happen (ports derive from servers); stay safe
            sub_servers[pi][0] = http_group.servers[0];
            nsub = 1;
        }
        subgroups[pi] = .{
            .servers = sub_servers[pi][0..nsub],
            .default_idx = 0,
            .host_select = http_group.host_select,
            .servers_owned = false,
        };
    }

    // Create one multireactor per unique port.
    var reactors_buf: [16]zocket.multireactor.Server = undefined;
    var reactors_len: usize = 0;
    errdefer for (reactors_buf[0..reactors_len]) |*r| r.deinit();
    for (ports, 0..) |p, pi| {
        const group = &subgroups[pi];
        // ListenSpec from this port's own servers (IPv6/dual-stack when
        // configured there); bare port otherwise. A dual-stack [::] spec
        // covers v4-mapped clients too unless ipv6_only is set.
        var first_spec: ?zocket.sockets.ListenSpec = null;
        for (group.servers) |*srv| {
            if (srv.cfg.listen_spec) |s| {
                if (first_spec == null) first_spec = s;
                if (s.family == .ipv6) {
                    first_spec = s;
                    break;
                }
            }
        }
        // Use ListenSpec when available (IPv6 / address-bound), fall back to
        // the legacy port-only path for backward compatibility.
        const spec: ?zocket.sockets.ListenSpec = if (first_spec) |s| s else .{ .port = p };
        if (spec) |s| {
            reactors_buf[reactors_len] = try zocket.multireactor.Server.initWithThreadsAndSpec(
                allocator,
                s,
                n,
                opts.mode,
                &group.servers[0],
                group,
                opts.idle_timeout,
            );
        } else {
            reactors_buf[reactors_len] = try zocket.multireactor.Server.initWithThreadsAndHandlerGroup(
                allocator,
                p,
                n,
                opts.mode,
                &group.servers[0],
                group,
                opts.idle_timeout,
            );
        }
        reactors_len += 1;
    }
    defer for (reactors_buf[0..reactors_len]) |*r| r.deinit();

    // Signal handlers: SIGTERM/SIGINT graceful stop.
    zocket.multireactor.installSignalHandlers();

    // Startup messages.
    for (ports) |p| {
        switch (opts.mode) {
            .echo => std.debug.print("Starting multi-reactor TCP echo server on port {} with {} threads\n", .{ p, n }),
            .http => {
                if (embedded) |cfg| {
                    std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (comptime config: {d} routes, {d} servers)\n", .{ p, n, cfg.routes.len, http_group.servers.len });
                } else {
                    std.debug.print("Starting multi-reactor HTTP server on port {} with {} threads (default config)\n", .{ p, n });
                }
            },
        }
    }
    if (opts.idle_timeout > 0) {
        std.debug.print("Idle timeout: {}s\n", .{opts.idle_timeout});
    } else {
        std.debug.print("Idle timeout: disabled\n", .{});
    }

    // Daemon mode: the listeners are bound (init above); signal readiness so
    // the parent can exit 0, then run.
    if (ready) |cb| cb(ready_ctx.?);

    // Run all multireactors. Single port: run directly (blocking).
    // Multiple ports: one thread per port.
    if (reactors_len == 1) {
        try reactors_buf[0].run();
    } else {
        var threads: [16]std.Thread = undefined;
        for (0..reactors_len) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn runner(r: *zocket.multireactor.Server) void {
                    r.run() catch {};
                }
            }.runner, .{&reactors_buf[i]});
        }
        for (0..reactors_len) |i| {
            threads[i].join();
        }
    }
}

fn writePidfile(path: []const u8, pid: posix_pid_t) !void {
    const f = try compat.createFile(path);
    defer compat.close(f);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try compat.writeAll(f, s);
}

const posix_pid_t = std.posix.pid_t;

fn startDaemon(allocator: std.mem.Allocator, opts: ServerOpts, pidfile: []const u8) !void {
    // Readiness handshake: the child writes 'R' once the listeners are
    // bound; the parent exits 0 on 'R', non-zero on EOF (child died).
    const fds = try compat.pipe();
    // State for --reload-hard, built before the fork (the child inherits it
    // and writes it out at ready time). The config path is normalized to
    // project-root-relative: the comptime embed (`@embedFile`) resolves
    // against the project root, so --reload-hard can rebuild with it.
    const project_root = resolveProjectRoot(allocator);
    var recorded_config = build_options.config_path;
    if (project_root) |root| {
        if (recorded_config) |p| {
            if (std.fs.path.isAbsolute(p)) {
                recorded_config = compat.relativePath(allocator, root, p) catch p;
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
    const pid = try compat.fork();
    if (pid == 0) {
        // ---- child: detach, then run the server ----
        compat.close(fds[0]);
        _ = compat.setsid() catch 0;
        // stdio to /dev/null: the daemon logs nowhere (a logfile flag could
        // redirect here later).
        const devnull = compat.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch -1;
        if (devnull >= 0) {
            compat.dup2(devnull, 0) catch {};
            compat.dup2(devnull, 1) catch {};
            compat.dup2(devnull, 2) catch {};
            if (devnull > 2) compat.close(devnull);
        }
        const Daemon = struct {
            pipe_fd: std.posix.fd_t,
            pidfile: []const u8,
            state: StateFile,
            pid: posix_pid_t,

            fn ready(ctx: *anyopaque) void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                writePidfile(d.pidfile, d.pid) catch {};
                // Attach zone descriptors from the global registry so the
                // child daemon inherits the memfds across --reload-hard.
                var state_with_zones = d.state;
                if (shmem_mod.global_registry) |*reg| {
                    state_with_zones.zone_fds = reg.descriptors() catch &.{};
                }
                writeStateFile(std.heap.page_allocator, d.pidfile, state_with_zones) catch {};
                if (state_with_zones.zone_fds.len > 0)
                    std.heap.page_allocator.free(state_with_zones.zone_fds);
                _ = compat.write(d.pipe_fd, "R") catch {};
            }
        };
        var daemon = Daemon{
            .pipe_fd = fds[1],
            .pidfile = pidfile,
            .state = state,
            .pid = compat.getpid(),
        };
        // On --reload-hard the new daemon inherits memfd fds from the old
        // one (memfd_create has no CLOEXEC). Adopt them before module
        // lifecycle init so zones survive across reloads.
        var inherited = readStateFile(std.heap.page_allocator, pidfile) catch null;
        defer if (inherited) |*s| freeStateFile(std.heap.page_allocator, s);
        if (inherited) |*s| {
            shmem_mod.adoptInherited(std.heap.page_allocator, s.zone_fds) catch {};
        }
        runServer(allocator, opts, &Daemon.ready, &daemon) catch |e| {
            std.debug.print("zocket: server error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        // Graceful stop (--stop / SIGTERM): remove the pid + state files,
        // but only while we still own them — a --reload-hard swap may have
        // already overwritten them with the new daemon's (same path).
        _ = cleanupOwnedFiles(allocator, pidfile);
        std.process.exit(0);
    }

    // ---- parent: wait for readiness ----
    compat.close(fds[1]);
    var b: [1]u8 = undefined;
    const n = std.posix.read(fds[0], &b) catch 0;
    compat.close(fds[0]);
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
    const err = std.os.linux.errno(rc);
    return err == .SUCCESS or err == .PERM;
}

fn readPidfile(allocator: std.mem.Allocator, pidfile: []const u8) !posix_pid_t {
    const data = try compat.readFileAlloc(allocator, pidfile, 64);
    defer allocator.free(data);
    return std.fmt.parseInt(posix_pid_t, std.mem.trim(u8, data, " \t\r\n"), 10);
}

/// Remove the pid + state files, but only while this process still owns
/// them. Returns true when removed. The ownership check closes the
/// --reload-hard race: the old daemon exits after the new daemon already
/// wrote the same pidfile path, and must not delete the new daemon's files.
fn cleanupOwnedFiles(allocator: std.mem.Allocator, pidfile: []const u8) bool {
    if (readPidfile(allocator, pidfile)) |pf| {
        if (pf == compat.getpid()) {
            compat.deleteFile(pidfile) catch {};
            if (stateFilePath(allocator, pidfile)) |sp| {
                compat.deleteFile(sp) catch {};
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
    var rel_buf: [256]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try compat.realpath(rel, &abs_buf);
    const pidfile = try std.fmt.allocPrint(allocator, "{s}/pid", .{tmp_abs});
    defer allocator.free(pidfile);
    // State file next to the pidfile.
    const state_path = try stateFilePath(allocator, pidfile);
    defer allocator.free(state_path);

    // Case 1: the pidfile names us -> cleanup removes pid + state files.
    try writePidfile(pidfile, compat.getpid());
    try writeStateFile(allocator, pidfile, .{});
    try testing.expect(cleanupOwnedFiles(allocator, pidfile));
    try testing.expectError(error.FileNotFound, compat.statFile(pidfile));
    try testing.expectError(error.FileNotFound, compat.statFile(state_path));

    // Case 2: a reload-hard swap already overwrote the pidfile with the NEW
    // daemon's pid -> the exiting old daemon must leave both files alone.
    try writePidfile(pidfile, compat.getpid() + 1);
    try writeStateFile(allocator, pidfile, .{});
    try testing.expect(!cleanupOwnedFiles(allocator, pidfile));
    _ = try compat.statFile(pidfile);
    _ = try compat.statFile(state_path);
    // The new daemon's files survive the old daemon's exit.
    const data = try compat.readFileAlloc(allocator, pidfile, 64);
    defer allocator.free(data);
    // The pid file still names the NEW daemon (our pid + 1).
    const new_pid = try std.fmt.parseInt(posix_pid_t, std.mem.trim(u8, data, " \t\r\n"), 10);
    try testing.expectEqual(compat.getpid() + 1, new_pid);
}

fn stopDaemon(allocator: std.mem.Allocator, pidfile: []const u8) !void {
    const pid = readPidfile(allocator, pidfile) catch {
        std.debug.print("no pid file at {s} — nothing to stop\n", .{pidfile});
        return;
    };
    if (!processAlive(pid)) {
        // Stale pid file: the daemon is gone.
        compat.deleteFile(pidfile) catch {};
        if (stateFilePath(allocator, pidfile)) |sp| {
            compat.deleteFile(sp) catch {};
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
        compat.nanosleep(0, 50 * std.time.ns_per_ms);
        if (!processAlive(pid)) {
            exited = true;
            break;
        }
    }
    compat.deleteFile(pidfile) catch {};
    if (stateFilePath(allocator, pidfile)) |sp| {
        compat.deleteFile(sp) catch {};
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
/// Zone descriptor carried in the state file across --reload-hard.
/// The fd survives exec (memfd_create uses no CLOEXEC); the new daemon
/// reads the fd number and mmaps the inherited file.
const ZoneInfo = shmem_mod.ZoneInfo;

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
    /// Memfd zone descriptors for reload-surviving shared-memory zones.
    /// The new daemon inherits these fds across exec and mmaps them.
    zone_fds: []const ZoneInfo = &.{},
};

fn stateFilePath(allocator: std.mem.Allocator, pidfile: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.state", .{pidfile});
}

fn writeStateFile(allocator: std.mem.Allocator, pidfile: []const u8, state: StateFile) !void {
    const path = try stateFilePath(allocator, pidfile);
    defer allocator.free(path);
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);
    const f = try compat.createFile(path);
    defer compat.close(f);
    try compat.writeAll(f, json);
}

/// Read the state file; strings are duped into `allocator` (free with
/// `freeStateFile`). Missing or unparseable file is an error.
fn readStateFile(allocator: std.mem.Allocator, pidfile: []const u8) !StateFile {
    const path = try stateFilePath(allocator, pidfile);
    defer allocator.free(path);
    const json = try compat.readFileAlloc(allocator, path, 8192);
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(StateFile, allocator, json, .{});
    defer parsed.deinit();
    var out = parsed.value;
    if (out.config_path) |p| out.config_path = try allocator.dupe(u8, p);
    out.optimize = try allocator.dupe(u8, out.optimize);
    out.mode = try allocator.dupe(u8, out.mode);
    if (out.project_root) |p| out.project_root = try allocator.dupe(u8, p);
    // Dupe zone descriptor names and the array itself.
    if (out.zone_fds.len > 0) {
        const duped = try allocator.alloc(ZoneInfo, out.zone_fds.len);
        for (out.zone_fds, 0..) |z, i| {
            duped[i] = .{
                .name = try allocator.dupe(u8, z.name),
                .fd = z.fd,
                .size = z.size,
            };
        }
        out.zone_fds = duped;
    }
    return out;
}

fn freeStateFile(allocator: std.mem.Allocator, state: *StateFile) void {
    if (state.config_path) |p| allocator.free(p);
    allocator.free(state.optimize);
    allocator.free(state.mode);
    if (state.project_root) |p| allocator.free(p);
    for (state.zone_fds) |z| allocator.free(z.name);
    if (state.zone_fds.len > 0) allocator.free(state.zone_fds);
}

/// Walk up from the executable until a directory with `build.zig.zon` is
/// found: the project root for `--reload-hard` rebuilds. Null when the
/// binary was copied out of the tree (deployed), in which case a rebuild
/// is impossible.
fn resolveProjectRoot(allocator: std.mem.Allocator) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = compat.readlink("/proc/self/exe", &buf) catch return null;
    var dir = std.fs.path.dirname(exe) orelse return null;
    while (true) {
        const marker = std.fs.path.join(allocator, &.{ dir, "build.zig.zon" }) catch return null;
        defer allocator.free(marker);
        if (compat.statFile(marker)) |_| {
            return allocator.dupe(u8, dir) catch null;
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// Rebuild the binary with the config embedded at compile time. Runs
/// `zig build` in `project_root` with the recorded optimization mode (zig
/// from PATH; compile errors go to the terminal). The config is validated
/// by the comptime JSON parser: compile errors are config errors and abort
/// the reload — the old daemon keeps serving untouched.
fn rebuild(allocator: std.mem.Allocator, project_root: []const u8, config_path: []const u8, optimize: []const u8, environ: std.process.Environ) !void {
    const opt_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
    defer allocator.free(opt_flag);
    const cfg_flag = try std.fmt.allocPrint(allocator, "-Dconfig={s}", .{config_path});
    defer allocator.free(cfg_flag);
    const argv = [_][]const u8{ "zig", "build", opt_flag, cfg_flag };
    // The Io carries the real process environment: with an empty environ
    // the child would inherit no PATH and `zig` would not resolve.
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = &argv, .cwd = .{ .path = project_root } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
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
fn hardReload(allocator: std.mem.Allocator, opts: ServerOpts, pidfile: []const u8, environ: std.process.Environ) !void {
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
        const rel = compat.relativePath(allocator, project_root, config_path) catch config_path;
        if (std.fs.path.isAbsolute(rel) or std.mem.startsWith(u8, rel, "../")) {
            std.debug.print("zocket: config {s} lies outside the project tree ({s}) — a comptime embed cannot reach it\n", .{ config_path, project_root });
            return;
        }
        config_path = rel;
    }

    std.debug.print("zocket: rebuilding with -Dconfig={s} (config validated at compile time)...\n", .{config_path});
    rebuild(allocator, project_root, config_path, state.optimize, environ) catch |e| {
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
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var new_child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try new_child.wait(io);
    switch (term) {
        .exited => |code| {
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
        compat.nanosleep(0, 50 * std.time.ns_per_ms);
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

pub fn main(init: std.process.Init.Minimal) !void {
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

    var args = init.args.iterate();
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
        try hardReload(allocator, opts, pidfile, init.environ);
        return;
    }
    if (do_start) {
        try startDaemon(allocator, opts, pidfile);
        return;
    }

    try runServer(allocator, opts, null, null);
}
