const std = @import("std");
const phase_mod = @import("phase.zig");

pub const Phase = phase_mod.Phase;

/// How a route's `path` is matched against the request target.
pub const Match = enum {
    /// The target must equal `path` exactly.
    exact,
    /// The target must start with `path` (nginx-style location prefix; the
    /// longest matching prefix wins).
    prefix,
};

/// One module attached to one phase of a route.
pub const ModuleBinding = struct {
    phase: Phase,
    /// Name of a module registered in the module registry.
    module: []const u8,
};

/// A declared route: a target pattern plus the modules attached to each phase.
pub const Route = struct {
    path: []const u8,
    match: Match = .prefix,
    modules: []const ModuleBinding = &.{},

    /// The module name bound to `phase` on this route, if any.
    pub fn moduleFor(self: *const Route, phase: Phase) ?[]const u8 {
        for (self.modules) |b| {
            if (b.phase == phase) return b.module;
        }
        return null;
    }
};

/// Prefix/exact route matching. An exact match beats every prefix; otherwise
/// the longest matching prefix wins. `matchRoutes` is called from the
/// `find_config` phase of the pipeline.
pub fn matchRoutes(route_list: []const Route, target: []const u8) ?*const Route {
    var best: ?*const Route = null;
    for (route_list) |*r| {
        switch (r.match) {
            .exact => {
                if (std.mem.eql(u8, target, r.path)) return r;
            },
            .prefix => {
                if (!std.mem.startsWith(u8, target, r.path)) continue;
                if (best == null or r.path.len > best.?.path.len) best = r;
            },
        }
    }
    return best;
}

const testing = std.testing;

fn routes() [3]Route {
    return .{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/api", .match = .prefix },
        .{ .path = "/api/v1", .match = .prefix },
    };
}

test "exact match wins over prefix" {
    const rs = [_]Route{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/api/v1", .match = .exact },
    };
    try testing.expectEqualStrings("/api/v1", matchRoutes(&rs, "/api/v1").?.path);
}

test "longest prefix wins" {
    const rs = routes();
    try testing.expectEqualStrings("/api/v1", matchRoutes(&rs, "/api/v1/users").?.path);
    try testing.expectEqualStrings("/api", matchRoutes(&rs, "/api/users").?.path);
}

test "catch-all prefix matches everything" {
    const rs = [_]Route{.{ .path = "/", .match = .prefix }};
    for ([_][]const u8{ "/", "/x", "/api", "/anything/else" }) |t| {
        try testing.expectEqualStrings("/", matchRoutes(&rs, t).?.path);
    }
}

test "exact does not match a longer target" {
    const rs = [_]Route{.{ .path = "/only", .match = .exact }};
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/only/x"));
}

test "no match yields null" {
    const rs = [_]Route{.{ .path = "/only", .match = .exact }};
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/other"));
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/only/x"));
}

test "moduleFor returns the bound module for a phase" {
    var r = Route{
        .path = "/",
        .modules = &.{
            .{ .phase = .content, .module = "echo" },
            .{ .phase = .access, .module = "deny" },
        },
    };
    try testing.expectEqualStrings("echo", r.moduleFor(.content).?);
    try testing.expectEqualStrings("deny", r.moduleFor(.access).?);
    try testing.expectEqual(@as(?[]const u8, null), r.moduleFor(.log));
}
