//! Test kit for module authors: safe request-case construction (the
//! Context points INTO the returned Case, which must outlive it — build
//! with `var c: Case = undefined; case(&c, ...)`), deterministic clock
//! helpers, and tiny route factories. Everything here is test-only by
//! convention; do not link from the server.

const std = @import("std");
const registry = @import("registry.zig");
const Method = @import("../http/parser.zig").Method;

pub const Request = registry.Request;
pub const Response = registry.Response;
pub const Context = registry.Context;
pub const Route = registry.Route;

/// Self-referential triple (ctx.req/ctx.resp point into the struct).
/// Construct IN PLACE: `var c: Case = undefined; case(&c, .get, "/x");`
pub const Case = struct {
    req: Request,
    resp: Response,
    ctx: Context,
    base_ns: u64 = 1_000_000_000_000,

    pub fn deinit(self: *Case) void {
        self.req.deinit();
    }

    /// Monotonic clock for tests: advances by `ns` each call.
    pub fn tick(self: *Case, ns: u64) u64 {
        self.base_ns += ns;
        self.ctx.now_ns = self.base_ns;
        return self.base_ns;
    }

    pub fn header(self: *Case, name: []const u8, value: []const u8) void {
        self.req.addHeaderParsed(name, value) catch unreachable;
    }
};

pub fn case(c: *Case, method: Method, target: []const u8) void {
    c.* = .{
        .req = undefined,
        .resp = undefined,
        .ctx = undefined,
    };
    c.req = Request.init(std.testing.allocator);
    c.req.method = method;
    c.req.target = target;
    c.req.decoded_target = target;
    c.resp = Response.init(.ok);
    c.ctx = Context{ .req = &c.req, .resp = &c.resp };
    c.ctx.now_ns = c.base_ns;
}

/// A route binding `mods` as handlers in declaration order.
pub fn routeWith(comptime path: []const u8, mods: []const registry.ModuleBinding) Route {
    return .{ .path = path, .modules = mods };
}
