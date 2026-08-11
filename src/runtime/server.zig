const std = @import("std");
const config_mod = @import("config.zig");
const pipeline = @import("../dsl/pipeline.zig");
const registry = @import("../dsl/registry.zig");
const router_mod = @import("../dsl/router.zig");

pub const Config = config_mod.Config;
pub const default_registry = registry.default_registry;

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
        return .{
            .cfg = cfg,
            .router = .{ .routes = cfg.routes, .trie = trie, .owned = true },
        };
    }

    /// Free allocator-owned trie buffers (JSON-config servers only; no-op for
    /// comptime and plain-init servers).
    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        self.router.deinit(allocator);
    }

    /// The default server: echo module on the catch-all route, the pre-pipeline
    /// M3 behavior. Built at compile time (trie + dispatch specialisation).
    pub fn default() Server {
        return comptimeInit(comptime Config.default());
    }

    /// Run one fully-parsed request through the phase pipeline. On
    /// `.not_handled` the caller sends the default (404) response. Module
    /// errors propagate to the caller, which turns them into a 500.
    pub fn handleRequest(self: *const Server, ctx: *pipeline.Context) !pipeline.Outcome {
        return pipeline.runWithRouter(registry.default_registry, self.cfg.routes, &self.router, ctx);
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
