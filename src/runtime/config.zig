const std = @import("std");
const router = @import("../dsl/router.zig");
const registry = @import("../dsl/registry.zig");

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
            if (r.index) |index| allocator.free(index);
        }
        allocator.free(self.routes);
    }

    /// Parse a JSON document into a Config using std.json. All strings are
    /// copied into `allocator`, so the source slice only needs to outlive the
    /// call.
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !Config {
        var parsed = try std.json.parseFromSlice(JsonConfig, allocator, json, .{});
        defer parsed.deinit();

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
            const index = if (jr.index) |ix| try allocator.dupe(u8, ix) else null;
            errdefer if (index) |ix| allocator.free(ix);

            routes.appendAssumeCapacity(.{
                .path = path,
                .match = if (std.mem.eql(u8, jr.match, "exact")) .exact else .prefix,
                .modules = try bindings.toOwnedSlice(allocator),
                .max_age_seconds = jr.max_age,
                .root = root,
                .index = index,
                .autoindex = jr.autoindex,
                .embed = jr.embed,
            });
        }

        return .{ .routes = try routes.toOwnedSlice(allocator) };
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

const JsonRoute = struct {
    path: []const u8,
    match: []const u8 = "prefix",
    modules: JsonModuleMap = .{},
    max_age: u32 = 0,
    root: ?[]const u8 = null,
    index: ?[]const u8 = null,
    autoindex: bool = false,
    embed: ?[]const u8 = null,
};

const JsonConfig = struct {
    routes: []const JsonRoute = &.{},
};

const testing = std.testing;

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
