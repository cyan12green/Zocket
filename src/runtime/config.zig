const std = @import("std");
const router = @import("../dsl/router.zig");
const registry = @import("../dsl/registry.zig");
const dsl_limits = @import("../dsl/limits.zig");

pub const Route = router.Route;
pub const ModuleBinding = router.ModuleBinding;
pub const Phase = router.Phase;

/// Server configuration: the route table declaring which modules attach to
/// which phases per route. Backing strings are borrowed:
/// - comptime struct literals (and `Config.default()`) point at comptime
///   constants and must never be deinit'd;
/// - `fromJson` copies everything into the caller's allocator and the result
///   must be freed with `deinit`.
pub const Config = struct {
    routes: []const Route = &.{},
    /// Runtime-tunable server limits (the `limits` JSON section). The
    /// reactor applies them to buffers, parsers, caches and pools.
    limits: dsl_limits.Limits = .{},

    /// Comptime default: a single catch-all prefix route attaching the echo
    /// module to the content phase — the pre-pipeline M3 behavior, reproduced
    /// as config.
    pub fn default() Config {
        return .{
            .routes = &.{
                .{
                    .path = "/",
                    .match = .prefix,
                    .modules = &.{
                        .{ .phase = .content, .module = "echo" },
                    },
                },
            },
        };
    }

    /// Verify every route against the module registry: each binding must name
    /// a registered module and bind a phase at most once.
    pub fn validate(self: *const Config, comptime Registry: type) !void {
        for (self.routes) |*r| {
            var seen = [_]bool{false} ** Phase.all.len;
            for (r.modules) |b| {
                if (!Registry.isRegistered(b.module)) return error.UnknownModule;
                if (seen[@intFromEnum(b.phase)]) return error.DuplicatePhaseBinding;
                seen[@intFromEnum(b.phase)] = true;
            }
        }
    }

    /// Free memory owned by a `fromJson`-loaded config. Must not be called on
    /// comptime struct literals or `Config.default()`.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.routes) |r| {
            for (r.modules) |b| {
                allocator.free(b.module);
            }
            allocator.free(r.modules);
            allocator.free(r.path);
            if (r.root) |root| allocator.free(root);
            if (r.root_real) |rr| allocator.free(rr);
            if (r.root_fd >= 0) std.posix.close(r.root_fd);
            if (r.index) |index| allocator.free(index);
            if (r.response) |*t| {
                for (t.headers) |h| {
                    allocator.free(h.name);
                    allocator.free(h.value);
                }
                allocator.free(t.headers);
                if (t.body.len > 0) allocator.free(t.body);
            }
            for (r.upstreams) |up| allocator.free(up.host);
            allocator.free(r.upstreams);
        }
        allocator.free(self.routes);
    }

    /// Parse a JSON document into a Config using std.json. All strings are
    /// copied into `allocator`, so the source slice only needs to outlive the
    /// call.
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !Config {
        var parsed = try std.json.parseFromSlice(JsonConfig, allocator, json, .{});
        defer parsed.deinit();

        // Merge the optional `limits` section over the compiled defaults.
        var limits = dsl_limits.Limits{};
        if (parsed.value.limits) |jl| {
            if (jl.recv_buffer_size) |v| limits.recv_buffer_size = v;
            if (jl.send_buffer_size) |v| limits.send_buffer_size = v;
            if (jl.max_body) |v| limits.max_body = v;
            if (jl.max_line_bytes) |v| limits.max_line_bytes = v;
            if (jl.max_headers) |v| limits.max_headers = v;
            if (jl.max_chunked_body) |v| limits.max_chunked_body = v;
            if (jl.static_cache_entries) |v| limits.static_cache_entries = v;
            if (jl.static_cache_valid_seconds) |v| limits.static_cache_valid_seconds = v;
            if (jl.static_content_cache_max) |v| limits.static_content_cache_max = v;
            if (jl.connection_pool_max) |v| limits.connection_pool_max = v;
        }

        var routes = std.ArrayList(Route).empty;
        try routes.ensureTotalCapacity(allocator, parsed.value.routes.len);
        errdefer {
            for (routes.items) |r| {
                for (r.modules) |b| allocator.free(b.module);
                allocator.free(r.modules);
                allocator.free(r.path);
            }
            routes.deinit(allocator);
        }

        for (parsed.value.routes) |jr| {
            const path = try allocator.dupe(u8, jr.path);
            errdefer allocator.free(path);

            var bindings = std.ArrayList(ModuleBinding).empty;
            try bindings.ensureTotalCapacity(allocator, Phase.all.len);
            inline for (std.meta.fields(JsonModuleMap)) |f| {
                const name: ?[]const u8 = @field(jr.modules, f.name);
                if (name) |module_name| {
                    const phase = Phase.parse(f.name) orelse return error.UnknownPhase;
                    bindings.appendAssumeCapacity(.{
                        .phase = phase,
                        .module = try allocator.dupe(u8, module_name),
                    });
                }
            }

            const root = if (jr.root) |r| try allocator.dupe(u8, r) else null;
            errdefer if (root) |r| allocator.free(r);
            // Resolve the root realpath once at load (nginx never realpaths
            // per request either): the static module's symlink-escape anchor.
            var root_real: ?[]const u8 = null;
            var root_fd: std.posix.fd_t = -1;
            if (root) |r| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved = std.fs.cwd().realpath(r, &buf) catch null;
                if (resolved) |rp| {
                    root_real = try allocator.dupe(u8, rp);
                }
                // O_PATH|O_DIRECTORY fd for the openat2(RESOLVE_BENEATH)
                // fast path; best-effort (fallback is the realpath check).
                root_fd = std.posix.open(r, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0) catch -1;
            }
            errdefer {
                if (root_real) |rr| allocator.free(rr);
                if (root_fd >= 0) std.posix.close(root_fd);
            }
            const index = if (jr.index) |ix| try allocator.dupe(u8, ix) else null;
            errdefer if (index) |ix| allocator.free(ix);
            // Response template (Milestone 11): status + headers + body are
            // copied; JSON routes apply it through the pipeline at runtime.
            var template: ?router.ResponseTemplate = null;
            if (jr.response) |jrsp| {
                var t_headers = std.ArrayList(router.TemplateHeader).empty;
                if (jrsp.headers) |jh| {
                    try t_headers.ensureTotalCapacity(allocator, jh.len);
                    for (jh) |h| {
                        t_headers.appendAssumeCapacity(.{
                            .name = try allocator.dupe(u8, h.name),
                            .value = try allocator.dupe(u8, h.value),
                        });
                    }
                }
                template = .{
                    .status = jrsp.status,
                    .headers = try t_headers.toOwnedSlice(allocator),
                    .body = if (jrsp.body) |b| try allocator.dupe(u8, b) else &.{},
                    .compress = jrsp.compress,
                };
            }
            var upstreams = std.ArrayList(router.Upstream).empty;
            if (jr.upstreams) |jus| {
                try upstreams.ensureTotalCapacity(allocator, jus.len);
                for (jus) |ju| {
                    const sock = router.Upstream.makeSockaddr(ju.host, ju.port) orelse return error.InvalidUpstreamHost;
                    upstreams.appendAssumeCapacity(.{
                        .host = try allocator.dupe(u8, ju.host),
                        .port = ju.port,
                        .sockaddr = sock,
                    });
                }
            }
            errdefer {
                for (upstreams.items) |up| allocator.free(up.host);
                upstreams.deinit(allocator);
            }
            const balance = if (jr.balance) |b| (router.Balance.parse(b) orelse return error.InvalidBalance) else router.Balance.round_robin;
            errdefer if (template) |*t| {
                for (t.headers) |h| {
                    allocator.free(h.name);
                    allocator.free(h.value);
                }
                allocator.free(t.headers);
            };

            routes.appendAssumeCapacity(.{
                .path = path,
                .match = if (std.mem.eql(u8, jr.match, "exact")) .exact else .prefix,
                .modules = try bindings.toOwnedSlice(allocator),
                .max_age_seconds = jr.max_age,
                .root = root,
                .root_real = root_real,
                .root_fd = root_fd,
                .index = index,
                .autoindex = jr.autoindex,
                .embed = jr.embed,
                .response = template,
                .upstreams = try upstreams.toOwnedSlice(allocator),
                .balance = balance,
                .max_fails = jr.max_fails,
                .fail_timeout_seconds = jr.fail_timeout_seconds,
            });
        }

        return .{ .routes = try routes.toOwnedSlice(allocator), .limits = limits };
    }
};

const JsonModuleMap = struct {
    post_read: ?[]const u8 = null,
    server_rewrite: ?[]const u8 = null,
    find_config: ?[]const u8 = null,
    rewrite: ?[]const u8 = null,
    post_rewrite: ?[]const u8 = null,
    preaccess: ?[]const u8 = null,
    access: ?[]const u8 = null,
    post_access: ?[]const u8 = null,
    content: ?[]const u8 = null,
    log: ?[]const u8 = null,
};

const JsonHeader = struct { name: []const u8, value: []const u8 };

const JsonResponse = struct {
    status: u16 = 200,
    body: ?[]const u8 = null,
    headers: ?[]const JsonHeader = null,
    compress: bool = false,
};

const JsonUpstream = struct {
    host: []const u8,
    port: u16,
};

const JsonRoute = struct {
    path: []const u8,
    match: []const u8 = "prefix",
    modules: JsonModuleMap = .{},
    max_age: u32 = 0,
    root: ?[]const u8 = null,
    index: ?[]const u8 = null,
    autoindex: bool = false,
    embed: ?[]const u8 = null,
    response: ?JsonResponse = null,
    upstreams: ?[]const JsonUpstream = null,
    balance: ?[]const u8 = null,
    max_fails: u32 = 3,
    fail_timeout_seconds: u32 = 30,
};

const JsonLimits = struct {
    recv_buffer_size: ?usize = null,
    send_buffer_size: ?usize = null,
    max_body: ?usize = null,
    max_line_bytes: ?usize = null,
    max_headers: ?usize = null,
    max_chunked_body: ?usize = null,
    static_cache_entries: ?usize = null,
    static_cache_valid_seconds: ?u64 = null,
    static_content_cache_max: ?usize = null,
    connection_pool_max: ?usize = null,
};

const JsonConfig = struct {
    routes: []const JsonRoute = &.{},
    limits: ?JsonLimits = null,
};

const testing = std.testing;


test "fromJson parses the limits section with defaults for the rest" {
    const json =
        \\{ "limits": { "max_headers": 4, "max_body": 1024, "static_cache_valid_seconds": 5 },
        \\  "routes": [] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), cfg.limits.max_headers);
    try testing.expectEqual(@as(usize, 1024), cfg.limits.max_body);
    try testing.expectEqual(@as(u64, 5), cfg.limits.static_cache_valid_seconds);
    // Unset fields keep the compiled defaults.
    try testing.expectEqual(@as(usize, 8192), cfg.limits.max_line_bytes);
    try testing.expectEqual(@as(usize, 16), cfg.limits.static_cache_entries);
}

test "default config declares echo on the catch-all prefix route" {
    const cfg = Config.default();
    try testing.expectEqual(@as(usize, 1), cfg.routes.len);
    try testing.expectEqualStrings("/", cfg.routes[0].path);
    try testing.expectEqual(router.Match.prefix, cfg.routes[0].match);
    try testing.expectEqualStrings("echo", cfg.routes[0].moduleFor(.content).?);
}

test "default config validates against the registry" {
    const cfg = Config.default();
    try cfg.validate(registry.default_registry);
}

test "JSON config parses into the same route table" {
    const json =
        \\{
        \\  "routes": [
        \\    { "path": "/echo", "match": "exact", "modules": { "content": "echo" } },
        \\    { "path": "/", "match": "prefix", "modules": { "content": "echo" } }
        \\  ]
        \\}
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);

    try testing.expectEqual(@as(usize, 2), cfg.routes.len);
    try testing.expectEqualStrings("/echo", cfg.routes[0].path);
    try testing.expectEqual(router.Match.exact, cfg.routes[0].match);
    try testing.expectEqualStrings("echo", cfg.routes[0].moduleFor(.content).?);
    try testing.expectEqualStrings("/", cfg.routes[1].path);
    try testing.expectEqual(router.Match.prefix, cfg.routes[1].match);
    try testing.expectEqualStrings("echo", cfg.routes[1].moduleFor(.content).?);
}

test "JSON config rejects an unknown module at validate time" {
    const json =
        \\{ "routes": [ { "path": "/", "modules": { "content": "ghost" } } ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try testing.expectError(error.UnknownModule, cfg.validate(registry.default_registry));
}

test "JSON config rejects duplicate phase bindings" {
    const json =
        \\{ "routes": [ { "path": "/", "modules": { "content": "echo", "log": "echo" } } ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    // echo binds content; log binds echo again but to a different phase — so
    // this one is legal. Build the duplicate directly instead.
    try cfg.validate(registry.default_registry);

    const dup = Config{
        .routes = &.{
            .{
                .path = "/",
                .modules = &.{
                    .{ .phase = .content, .module = "echo" },
                    .{ .phase = .content, .module = "echo" },
                },
            },
        },
    };
    try testing.expectError(error.DuplicatePhaseBinding, dup.validate(registry.default_registry));
}

test "JSON config with a modules-free route is valid and yields not_handled" {
    const json =
        \\{ "routes": [ { "path": "/static", "modules": {} } ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);
    try testing.expectEqual(@as(usize, 0), cfg.routes[0].modules.len);
}
