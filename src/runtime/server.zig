const std = @import("std");
const config_mod = @import("config.zig");
const pipeline = @import("../dsl/pipeline.zig");
const registry = @import("../dsl/registry.zig");
const router_mod = @import("../dsl/router.zig");

pub const Config = config_mod.Config;
const tls_cert = @import("../tls/cert.zig");
pub const default_registry = registry.default_registry;
pub const ServerStats = registry.ServerStats;

/// Shared counters for the default (comptime) server instance.
var default_stats: ServerStats = .{};

/// The config-driven HTTP request processor. A single immutable instance is
/// shared by every reactor; it holds the route table and dispatches each fully
/// parsed request through the DSL phase pipeline.
///
/// Route lookup goes through a trie-backed `Router` (Milestone 7): built at
/// compile time for struct-literal configs (`comptimeInit`), at startup for
/// JSON configs (`initWithTrie`). Struct-literal routes additionally carry
/// comptime-specialised dispatch functions; JSON routes use the loop-walk
/// fallback. `init` (no trie) keeps the linear matcher for tests and plain
/// embedding.
pub const Server = struct {
    cfg: Config,
    router: router_mod.Router = .{},
    /// Shared connection/request counters (Milestone 13). Points at the
    /// process-global `default_stats` for comptime/default servers and at an
    /// allocator-owned struct for JSON-config servers (freed by `deinit`).
    stats: *ServerStats = &default_stats,
    /// TLS credentials (M18): loaded once at startup from the config `tls`
    /// section (cert + key PEM files). The reactor uses them to instantiate
    /// a native TLS 1.3 session per connection. `cert_der` is
    /// allocator-owned; freed by `deinit`.
    tls_creds: ?tls_cert.Credentials = null,

    /// Load the TLS credentials when the config enables TLS (reads the PEM
    /// files once at startup — nginx reads `ssl_certificate` at startup too).
    pub fn loadTls(self: *Server, allocator: std.mem.Allocator) !void {
        if (self.cfg.tls.enabled()) {
            const cert_pem = try std.fs.cwd().readFileAlloc(self.cfg.tls.cert, allocator, .limited(1 << 20));
            defer allocator.free(cert_pem);
            const key_pem = try std.fs.cwd().readFileAlloc(self.cfg.tls.key, allocator, .limited(1 << 20));
            defer allocator.free(key_pem);
            self.tls_creds = try tls_cert.loadCredentials(allocator, cert_pem, key_pem);
        }
    }

    /// Plain constructor: no trie, linear route matching. Kept for tests and
    /// embedders that construct routes at runtime.
    pub fn init(cfg: Config) Server {
        return .{ .cfg = cfg, .router = .{ .routes = cfg.routes } };
    }

    /// Struct-literal configs (Milestone 7): the route trie and the per-route
    /// dispatch functions are built at compile time; the whole route table,
    /// trie and dispatch pointers live in .rodata. Duplicate routes are a
    /// compile error (see `router.comptimeCheckAmbiguous`). The body is
    /// forced through a `comptime` expression so this works from runtime
    /// call sites (`Server.default()`).
    pub fn comptimeInit(comptime cfg: Config) Server {
        return comptime comptimeInitImpl(cfg);
    }

    fn comptimeInitImpl(comptime cfg: Config) Server {
        const routes = pipeline.assignDispatch(registry.default_registry, cfg.routes);
        const trie = router_mod.buildTrie(&routes);
        return .{
            .cfg = .{ .routes = &routes },
            .router = .{ .routes = &routes, .trie = trie },
        };
    }

    /// JSON configs: the trie is built at startup (one-time cost, same shape
    /// as the comptime-built one). The trie buffers are owned by the router;
    /// call `deinit` to free them.
    pub fn initWithTrie(allocator: std.mem.Allocator, cfg: Config) !Server {
        const trie = try router_mod.buildTrieRuntime(allocator, cfg.routes);
        const stats = try allocator.create(ServerStats);
        errdefer allocator.destroy(stats);
        var srv = Server{
            .cfg = cfg,
            .router = .{ .routes = cfg.routes, .trie = trie, .owned = true },
            .stats = stats,
        };
        srv.loadTls(allocator) catch |e| {
            srv.router.deinit(allocator);
            allocator.destroy(stats);
            return e;
        };
        return srv;
    }

    /// Free allocator-owned trie buffers (JSON-config servers only; no-op for
    /// comptime and plain-init servers).
    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        self.router.deinit(allocator);
        if (self.stats != &default_stats) allocator.destroy(self.stats);
        if (self.tls_creds) |*c| allocator.free(c.cert_der);
        self.tls_creds = null;
    }

    /// The default server: echo module on the catch-all route, the pre-pipeline
    /// M3 behavior. Built at compile time (trie + dispatch specialisation).
    pub fn default() Server {
        return comptimeInit(comptime Config.default());
    }

    /// DM2: build a server from a comptime/embedded config, then resolve
    /// static roots at startup — exactly what `fromJson` does at load, but
    /// the comptime route table is immutable .rodata, so the rooted routes
    /// are copied into `allocator` with `root_real` (symlink-escape anchor)
    /// and `root_fd` (O_PATH|O_DIRECTORY for the openat2 fast path) filled
    /// in. The dispatch functions, trie and everything else stay comptime;
    /// the trie's positional route indices apply to the copy unchanged.
    /// Free the allocator-owned copy with `deinitPrepared`.
    /// Like `embeddedInit`, but with the TLS credentials loaded at startup
    /// (the config `tls` section; the cert/key PEM files are runtime files).
    pub fn embeddedInitWithTls(allocator: std.mem.Allocator, comptime cfg: Config) !Server {
        var srv = try embeddedInit(allocator, cfg);
        srv.loadTls(allocator) catch |e| {
            srv.deinitPrepared(allocator);
            return e;
        };
        return srv;
    }

    pub fn embeddedInit(allocator: std.mem.Allocator, comptime cfg: Config) !Server {
        const base = comptimeInit(cfg);
        const routes = try allocator.alloc(router_mod.Route, base.cfg.routes.len);
        errdefer allocator.free(routes);
        var prepared_len: usize = 0;
        errdefer for (routes[0..prepared_len]) |r| {
            if (r.root_real) |rr| allocator.free(rr);
            if (r.root_fd >= 0) std.posix.close(r.root_fd);
        };
        for (base.cfg.routes, 0..) |r, i| {
            var copy = r;
            if (r.root) |root| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved = std.fs.cwd().realpath(root, &buf) catch null;
                if (resolved) |rp| {
                    copy.root_real = try allocator.dupe(u8, rp);
                }
                copy.root_fd = std.posix.open(root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0) catch -1;
            }
            routes[i] = copy;
            prepared_len += 1;
        }
        var s = base;
        s.cfg = .{ .routes = routes, .limits = base.cfg.limits };
        s.router.routes = routes;
        return s;
    }

    /// Free the allocator-owned route copy created by `embeddedInit` (only
    /// the resolved root fields and the array itself; the comptime strings
    /// still live in .rodata).
    pub fn deinitPrepared(self: *Server, allocator: std.mem.Allocator) void {
        for (self.cfg.routes) |r| {
            if (r.root_real) |rr| allocator.free(rr);
            if (r.root_fd >= 0) std.posix.close(r.root_fd);
        }
        allocator.free(self.cfg.routes);
    }

    /// Run one fully-parsed request through the phase pipeline. On
    /// `.not_handled` the caller sends the default (404) response. Module
    /// errors propagate to the caller, which turns them into a 500.
    pub fn handleRequest(self: *const Server, ctx: *pipeline.Context) !pipeline.Outcome {
        return pipeline.runWithRouter(registry.default_registry, self.cfg.routes, &self.router, ctx);
    }

    /// Milestone 11 fast path: when the matched route is a module-less
    /// response template, return its pre-serialised bytes so the caller can
    /// write them straight to the wire — no pipeline, no response builder,
    /// no function call through the phase chain. Returns null when any
    /// module could still act on the request.
    pub fn matchFast(self: *const Server, ctx: *pipeline.Context) ?router_mod.FastResponse {
        const route = self.router.match(ctx.req.target) orelse return null;
        if (route.modules.len != 0) return null;
        const fb = route.response_bytes orelse return null;
        ctx.route = route;
        return fb;
    }
};

const testing = std.testing;

test "runtime server dispatches an echo request through the pipeline" {
    const srv = Server.default();

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";
    req.body = "body via config";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("body via config", resp.body);
}

test "runtime server with a JSON config drives an HTTP request to 200 echo" {
    const json =
        \\{ "routes": [ { "path": "/", "modules": { "content": "echo" } } ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);

    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/submit";
    req.body = "json-driven";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqualStrings("json-driven", resp.body);
}

test "runtime server yields not_handled when no module claims the request" {
    const json =
        \\{ "routes": [ { "path": "/static", "modules": {} } ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);

    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/static/file.txt";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.not_handled, try srv.handleRequest(&ctx));
}

// ---- Milestone 7: comptime server (trie + dispatch specialisation) ----

test "comptime server routes identically to the plain server" {
    const plain = Server.init(Config.default());
    const comptime_srv = Server.comptimeInit(comptime Config.default());

    const targets = [_][]const u8{ "/", "/anything", "/deep/path", "/x?q=1" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.body = "payload";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.body = "payload";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try plain.handleRequest(&ctx_a);
        const out_b = try comptime_srv.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        try testing.expectEqualStrings(resp_a.body, resp_b.body);
        try testing.expectEqual(resp_a.status, resp_b.status);
        try testing.expectEqualStrings("/", ctx_b.route.?.path);
    }
}

test "comptime server dispatches a route with multiple phases via the dispatch fn" {
    const cfg = comptime Config{
        .routes = &.{
            .{
                .path = "/only",
                .match = .exact,
                .modules = &.{
                    .{ .phase = .content, .module = "echo" },
                    .{ .phase = .log, .module = "echo" },
                },
            },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/only";
    req.body = "via dispatch";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqualStrings("via dispatch", resp.body);
    // The route carries the specialised dispatch function.
    try testing.expect(ctx.route.?.dispatch != null);

    // Unmatched target: 404 path even with the trie.
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/elsewhere";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(pipeline.Outcome.not_handled, try srv.handleRequest(&ctx2));
}

test "JSON-config server with a startup trie routes identically to the plain server" {
    const json =
        \\{ "routes": [
        \\    { "path": "/api", "match": "prefix", "modules": { "content": "echo" } },
        \\    { "path": "/exact", "match": "exact", "modules": { "content": "echo" } }
        \\  ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);

    const plain = Server.init(cfg);
    var trie_srv = try Server.initWithTrie(testing.allocator, cfg);
    defer trie_srv.deinit(testing.allocator);

    const targets = [_][]const u8{ "/api/users", "/exact", "/exact/x", "/nope" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.body = "b";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.body = "b";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try plain.handleRequest(&ctx_a);
        const out_b = try trie_srv.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        if (out_a == .handled) {
            try testing.expectEqualStrings(resp_a.body, resp_b.body);
        }
    }
}

// ---- Milestone 11: response templates ----

test "comptime template route serves through the dispatch fallback" {
    const cfg = comptime Config{
        .routes = &.{
            .{
                .path = "/health",
                .match = .exact,
                .response = .{ .status = 200, .body = "ok" },
            },
            .{
                .path = "/old",
                .match = .exact,
                .response = .{
                    .status = 301,
                    .headers = &.{.{ .name = "Location", .value = "/health" }},
                },
            },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok", resp.body);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/old";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx2));
    try testing.expectEqual(registry.Status.moved_permanently, resp2.status);
    try testing.expectEqualStrings("/health", resp2.headers[0].value);
}

test "matchFast returns pre-serialised bytes only for module-less template routes" {
    const cfg = comptime Config{
        .routes = &.{
            .{ .path = "/health", .match = .exact, .response = .{ .body = "ok" } },
            .{
                .path = "/withmods",
                .match = .exact,
                .response = .{ .body = "x" },
                .modules = &.{.{ .phase = .content, .module = "echo" }},
            },
            .{ .path = "/", .match = .prefix, .modules = &.{.{ .phase = .content, .module = "echo" }} },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    const fb = srv.matchFast(&ctx).?;
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", fb.head);
    try testing.expectEqualStrings("ok", fb.body);

    // A template route WITH modules: the pipeline must run.
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/withmods";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx2));

    // Plain echo route: no fast path.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.target = "/anything";
    var resp3 = registry.Response.init(.ok);
    var ctx3 = pipeline.Context{ .req = &req3, .resp = &resp3 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx3));
}

// ---- DM2: comptime-embedded config as the primary path ----

test "embedded comptime config parses via fromEmbedded (root-relative path)" {
    const cfg = comptime Config.fromEmbedded("src/testdata/config.example.json");
    try testing.expectEqual(@as(usize, 6), cfg.routes.len);
    try testing.expectEqualStrings("/echo", cfg.routes[0].path);
    try testing.expectEqualStrings("/", cfg.routes[5].path);
}

test "server from an embedded comptime config routes identically to the JSON server" {
    const embedded = Server.comptimeInit(comptime Config.fromEmbedded("src/testdata/config.example.json"));

    const json = @embedFile("../testdata/config.example.json");
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);
    var json_srv = try Server.initWithTrie(testing.allocator, cfg);
    defer json_srv.deinit(testing.allocator);

    const targets = [_][]const u8{ "/echo", "/gzip", "/static/", "/health", "/old", "/", "/anything" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.body = "payload";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.body = "payload";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try embedded.handleRequest(&ctx_a);
        const out_b = try json_srv.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        try testing.expectEqual(resp_a.status, resp_b.status);
        try testing.expectEqualStrings(resp_a.body, resp_b.body);
    }
}

test "embedded comptime config gets pre-serialised fast responses (M11 path)" {
    const srv = Server.comptimeInit(comptime Config.fromEmbedded("src/testdata/config.example.json"));

    // /health and /old are module-less template routes: served from
    // pre-serialised bytes, no pipeline.
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    const fb = srv.matchFast(&ctx).?;
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", fb.head);
    try testing.expectEqualStrings("ok", fb.body);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/old";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    const fb2 = srv.matchFast(&ctx2).?;
    try testing.expectEqualStrings("HTTP/1.1 301 Moved Permanently\r\nLocation: /health\r\n", fb2.head);
    try testing.expectEqualStrings("", fb2.body);

    // /echo is module-backed: no fast path.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.target = "/echo";
    var resp3 = registry.Response.init(.ok);
    var ctx3 = pipeline.Context{ .req = &req3, .resp = &resp3 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx3));
}

test "embeddedInit resolves static roots at startup (root_real + root_fd)" {
    const cfg = comptime Config.fromJsonComptime(
        \\{ "routes": [ { "path": "/static", "root": "testdata", "modules": { "content": "static" } } ] }
    );
    var srv = try Server.embeddedInit(testing.allocator, cfg);
    defer srv.deinitPrepared(testing.allocator);

    try testing.expectEqual(@as(usize, 1), srv.cfg.routes.len);
    // "testdata" exists at the project root and resolves to an absolute path.
    const rr = srv.cfg.routes[0].root_real orelse return error.SkipZigTest;
    try testing.expect(rr.len > 0 and rr[0] == '/');
    try testing.expect(srv.cfg.routes[0].root_fd >= 0);

    // The copy carries the comptime dispatch fn.
    try testing.expect(srv.cfg.routes[0].dispatch != null);
}

test "JSON template route applies through the pipeline" {
    const json =
        \\{ "routes": [
        \\    { "path": "/health", "match": "exact",
        \\      "response": { "status": 200, "body": "ok-json" } }
        \\  ] }
    ;
    var cfg = try Config.fromJson(testing.allocator, json);
    defer cfg.deinit(testing.allocator);
    try cfg.validate(registry.default_registry);
    var srv = try Server.initWithTrie(testing.allocator, cfg);
    defer srv.deinit(testing.allocator);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok-json", resp.body);
}
