const std = @import("std");

/// nginx-style request-processing phases, in execution order. The names follow
/// nginx's configuration/rewrite stages; the internal behavior is our own (see
/// the nginx phase model for the mapping).
pub const Phase = enum {
    post_read,
    server_rewrite,
    find_config,
    rewrite,
    post_rewrite,
    preaccess,
    access,
    post_access,
    content,
    log,

    /// All phases in execution order. The phase dispatch loop walks this list.
    pub const all = [_]Phase{
        .post_read,
        .server_rewrite,
        .find_config,
        .rewrite,
        .post_rewrite,
        .preaccess,
        .access,
        .post_access,
        .content,
        .log,
    };

    /// Canonical name (used in config files and module metadata).
    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .post_read => "post_read",
            .server_rewrite => "server_rewrite",
            .find_config => "find_config",
            .rewrite => "rewrite",
            .post_rewrite => "post_rewrite",
            .preaccess => "preaccess",
            .access => "access",
            .post_access => "post_access",
            .content => "content",
            .log => "log",
        };
    }

    /// Parse a phase from its canonical name.
    pub fn parse(n: []const u8) ?Phase {
        inline for (all) |p| {
            if (std.mem.eql(u8, n, p.name())) return p;
        }
        return null;
    }
};

const testing = std.testing;

test "phase enum order and names" {
    const want = [_][]const u8{
        "post_read",
        "server_rewrite",
        "find_config",
        "rewrite",
        "post_rewrite",
        "preaccess",
        "access",
        "post_access",
        "content",
        "log",
    };
    try testing.expectEqual(@as(usize, want.len), Phase.all.len);
    inline for (Phase.all, 0..) |p, i| {
        try testing.expectEqualStrings(want[i], p.name());
    }
}

test "phase name roundtrip" {
    inline for (Phase.all) |p| {
        try testing.expectEqual(p, Phase.parse(p.name()).?);
    }
    try testing.expectEqual(@as(?Phase, null), Phase.parse("bogus_phase"));
}
