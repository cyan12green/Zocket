const std = @import("std");
const config_mod = @import("config.zig");
const pipeline = @import("../dsl/pipeline.zig");
const registry = @import("../dsl/registry.zig");

pub const Config = config_mod.Config;
pub const default_registry = registry.default_registry;

/// The config-driven HTTP request processor. A single immutable instance is
/// shared by every reactor; it holds the route table and dispatches each fully
/// parsed request through the DSL phase pipeline.
pub const Server = struct {
    cfg: Config,

    pub fn init(cfg: Config) Server {
        return .{ .cfg = cfg };
    }

    /// The default server: echo module on the catch-all route, the pre-pipeline
    /// M3 behavior.
    pub fn default() Server {
        return .{ .cfg = Config.default() };
    }

    /// Run one fully-parsed request through the phase pipeline. On
    /// `.not_handled` the caller sends the default (404) response. Module
    /// errors propagate to the caller, which turns them into a 500.
    pub fn handleRequest(self: *const Server, ctx: *pipeline.Context) !pipeline.Outcome {
        return pipeline.run(registry.default_registry, self.cfg.routes, ctx);
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
