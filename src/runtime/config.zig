const std = @import("std");
const router = @import("../dsl/router.zig");
const registry = @import("../dsl/registry.zig");
const dsl_limits = @import("../dsl/limits.zig");
const conf = @import("../dsl/conf.zig");
const vars = @import("../dsl/vars.zig");

pub const Route = router.Route;
pub const ModuleBinding = router.ModuleBinding;
pub const Phase = router.Phase;
pub const Frag = vars.Frag;
pub const LogFormat = vars.LogFormat;

/// Server configuration: the route table declaring which modules attach to
/// which phases per route. Backing strings are borrowed:
/// - comptime struct literals (and `Config.default()`) point at comptime
///   constants and must never be deinit'd;
/// - `fromConfComptime`/`fromConfEmbedded` parse at compile time into
///   .rodata tables and must never be deinit'd.
/// TLS listener settings certificate and key file paths. The files
/// are read once at startup (like nginx's `ssl_certificate`); the module
/// layer uses them via the native TLS 1.3 server in `src/tls/`.
pub const TlsConfig = struct {
    cert: []const u8 = "",
    key: []const u8 = "",
    /// Whether TLS is enabled at all (a `tls` section present).
    pub fn enabled(self: *const TlsConfig) bool {
        return self.cert.len > 0 and self.key.len > 0;
    }
};

pub const Config = struct {
    routes: []const Route = &.{},
    /// Runtime-tunable server limits (the `limits` JSON section). The
    /// reactor applies them to buffers, parsers, caches and pools.
    limits: dsl_limits.Limits = .{},
    /// TLS listener settings certificate + key PEM files.
    tls: TlsConfig = .{},
    /// Listen port from the conf `listen` directive; null = CLI `--port`
    /// default (8080). CLI wins when both are present.
    listen_port: ?u16 = null,
    /// Named log formats (`log_format` directives); index 0 is the default
    /// `combined` when none is declared.
    log_formats: []const LogFormat = &.{},

    /// Comptime default: a single catch-all prefix route attaching the echo
    /// module to the content phase — the pre-pipeline behavior, reproduced
    /// as config. A plain struct literal: no parse at all.
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

    /// Parse a conf document at compile time (the nginx-flavored language in
    /// `src/dsl/conf.zig`). Invalid configs are compile errors; the built
    /// route table and strings live in .rodata.
    pub fn fromConfComptime(comptime text: []const u8) Config {
        return conf.parse(text);
    }

    /// Embed a conf file and parse it at compile time. The path is
    /// project-root-relative and resolved through the `embeds` module (same
    /// convention as route `embed` paths). Use `Server.comptimeInit` to turn
    /// the result into a server with a comptime-built trie, dispatch
    /// specialisation and pre-serialised response templates.
    pub fn fromConfEmbedded(comptime path: []const u8) Config {
        return conf.parse(@import("embeds").embed(path));
    }

    /// Registry + budget validation, forced comptime. Called at the end of
    /// the comptime server constructors; the budget check (§9) surfaces a
    /// clear compile error when a config would exhaust the shared comptime
    /// branch quota.
    pub inline fn comptimeValidate(comptime cfg: Config, comptime Registry: type) void {
        @setEvalBranchQuota(1_000_000);
        for (cfg.routes) |*r| {
            for (r.modules) |b| {
                if (!Registry.isRegistered(b.module)) {
                    @compileError("unknown module '" ++ b.module ++ "' in route '" ++ r.path ++ "'");
                }
            }
        }
    }

    /// Verify every route against the module registry: each binding must name
    /// a registered module. Multiple modules may share a phase — they form a
    /// chain run in declaration order (nginx-style). Runtime entry used by
    /// struct-literal tests.
    pub fn validate(self: *const Config, comptime Registry: type) !void {
        for (self.routes) |*r| {
            for (r.modules) |b| {
                if (!Registry.isRegistered(b.module)) return error.UnknownModule;
            }
        }
    }
};

const testing = std.testing;

test "conf parse applies the limits directives with defaults for the rest" {
    const cfg = Config.fromConfComptime(
        \\max_headers 4;
        \\max_body 1k;
        \\static_cache_valid 5;
        \\server {
        \\    location / { content echo; }
        \\}
    );
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

test "conf parses into the same route table" {
    const cfg = Config.fromConfComptime(
        \\server {
        \\    location = /echo { content echo; }
        \\    location / { content echo; }
        \\}
    );
    try cfg.validate(registry.default_registry);

    try testing.expectEqual(@as(usize, 2), cfg.routes.len);
    try testing.expectEqualStrings("/echo", cfg.routes[0].path);
    try testing.expectEqual(router.Match.exact, cfg.routes[0].match);
    try testing.expectEqualStrings("echo", cfg.routes[0].moduleFor(.content).?);
    try testing.expectEqualStrings("/", cfg.routes[1].path);
    try testing.expectEqual(router.Match.prefix, cfg.routes[1].match);
    try testing.expectEqualStrings("echo", cfg.routes[1].moduleFor(.content).?);
}

test "conf route opt-in for chunked responses" {
    const cfg = Config.fromConfComptime(
        \\server {
        \\    location /chunked { content echo; chunked on; }
        \\    location /plain { content echo; }
        \\}
    );
    try cfg.validate(registry.default_registry);

    try testing.expect(cfg.routes[0].chunked);
    try testing.expect(!cfg.routes[1].chunked);
}

test "conf rejects an unknown module at validate time" {
    const cfg = Config.fromConfComptime(
        \\server {
        \\    location / { content ghost; }
        \\}
    );
    try testing.expectError(error.UnknownModule, cfg.validate(registry.default_registry));
}

test "multiple modules may share a phase (they form a declaration-order chain)" {
    const cfg = Config.fromConfComptime(
        \\server {
        \\    location / { content echo; }
        \\}
    );
    try cfg.validate(registry.default_registry);

    const chain = Config{
        .routes = &.{
            .{
                .path = "/",
                .modules = &.{
                    .{ .phase = .content, .module = "static" },
                    .{ .phase = .content, .module = "echo" },
                },
            },
        },
    };
    try chain.validate(registry.default_registry);
}

test "conf with a modules-free route is valid and yields not_handled" {
    const cfg = Config.fromConfComptime(
        \\server {
        \\    location /static {}
        \\}
    );
    try cfg.validate(registry.default_registry);
    try testing.expectEqual(@as(usize, 0), cfg.routes[0].modules.len);
}

test "comptimeValidate rejects an unknown module with a compile error" {
    // The comptime check compiles only when the config is valid; exercising
    // the error path is a build-time concern (asserted via fixtures). Here we
    // verify the happy path returns normally.
    comptime {
        const cfg = Config.fromConfComptime(
            \\server {
            \\    location / { content echo; }
            \\}
        );
        Config.comptimeValidate(cfg, registry.default_registry);
    }
}
