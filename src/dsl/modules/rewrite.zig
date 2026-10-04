//! `rewrite` — URI mutation in the rewrite phase.
//!
//!   rewrite ^/old/(.*) /new/$1 last;
//!   rewrite ^/tmp/(.*) /cache/$1 break;
//!   rewrite ^/moved$ /elsewhere redirect;      -> 302
//!   rewrite ^/gone$ /elsewhere permanent;      -> 301
//!
//! Rules run in declaration order against `decoded_target` (query string
//! preserved unless the replacement contains `?`). The pattern is the same
//! comptime Thompson NFA as `location ~`; `$1..$9` in the replacement render
//! from the match captures. Flags:
//!
//!   last      — redirect to the new URI (re-walks location matching).
//!   break     — rewrite in place, stop processing rules, stay in this
//!               location (no re-match).
//!   redirect  — answer 302 with Location (handled).
//!   permanent — answer 301 with Location (handled).
//!
//! No flag defaults to `last` (the re-matching form is the least surprising
//! when the target location differs; use `break` for in-location rewrites).
const std = @import("std");
const registry = @import("../registry.zig");
const router_mod = @import("../router.zig");
const vars = @import("../vars.zig");
const regex_mod = @import("../regex.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const rewrite = registry.Module{
    .name = "rewrite",
    .phase = .rewrite,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.rewrites.len == 0) return .pass;

    for (route.rewrites) |rule| {
        // Match against the path only; the query string is preserved
        // separately (nginx `rewrite` semantics).
        const target = ctx.req.decoded_target;
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |q| target[0..q] else target;
        var ranges: [9]vars.CaptureRange = @as([9]vars.CaptureRange, @splat(@as(vars.CaptureRange, .{ .start = 0, .end = 0 })));
        if (!regex_mod.match(&rule.pattern, path, &ranges, 0, false)) continue;

        // Publish the match captures so `$1..$9` render in the replacement.
        ctx.capture_subject = path;
        ctx.captures = ranges;
        ctx.capture_count = rule.pattern.group_count + 1;

        const new_path = vars.renderComplexArena(ctx, rule.replacement, &ctx.req.arena) orelse return error.OutOfMemory;
        const next = if (std.mem.indexOfScalar(u8, new_path, '?') != null)
            new_path
        else if (qmark) |q|
            ctx.sharedFmt("{s}{s}", .{ new_path, target[q..] }) orelse return error.OutOfMemory
        else
            new_path;

        switch (rule.flag) {
            .@"break" => {
                const uri = ctx.sharedDupe(next) orelse return error.OutOfMemory;
                ctx.req.target = uri;
                ctx.req.decoded_target = uri;
                return .pass;
            },
            .last => {
                const uri = ctx.sharedDupe(next) orelse return error.OutOfMemory;
                ctx.internal_redirect_target = uri;
                return .pass;
            },
            .redirect, .permanent => {
                ctx.resp.status = if (rule.flag == .permanent) .moved_permanently else .found;
                ctx.resp.setHeader("Location", next);
                ctx.resp.body = &.{};
                return .handled;
            },
        }
    }
    return .pass;
}

const testing = std.testing;

fn ruleWith(comptime pattern: []const u8, replacement: []const vars.Frag, flag: router_mod.RewriteFlag) router_mod.RewriteRule {
    return .{
        .pattern = comptime regex_mod.compileRegex(pattern),
        .replacement = replacement,
        .flag = flag,
    };
}

test "rewrite: no rules is inert" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
}

test "rewrite: last redirects with captures expanded" {
    const repl = comptime vars.parseComplexValue("/new/$1", &.{});
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/old/page";
    req.target = "/old/page";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const rules = [_]router_mod.RewriteRule{ruleWith("^/old/(.*)", repl, .last)};
    const route = registry.Route{ .path = "/", .rewrites = &rules };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("/new/page", ctx.internal_redirect_target.?);
}

test "rewrite: break rewrites in place without redirecting" {
    const repl = comptime vars.parseComplexValue("/cache/$1", &.{});
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/tmp/file";
    req.target = "/tmp/file";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const rules = [_]router_mod.RewriteRule{ruleWith("^/tmp/(.*)", repl, .@"break")};
    const route = registry.Route{ .path = "/", .rewrites = &rules };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expect(ctx.internal_redirect_target == null);
    try testing.expectEqualStrings("/cache/file", req.decoded_target);
}

test "rewrite: redirect and permanent answer with Location" {
    const repl = comptime vars.parseComplexValue("/elsewhere", &.{});
    for ([_]struct { flag: router_mod.RewriteFlag, status: registry.Status }{
        .{ .flag = .redirect, .status = .found },
        .{ .flag = .permanent, .status = .moved_permanently },
    }) |c| {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.decoded_target = "/moved";
        req.target = "/moved";
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        const rules = [_]router_mod.RewriteRule{ruleWith("^/moved$", repl, c.flag)};
        const route = registry.Route{ .path = "/", .rewrites = &rules };
        ctx.route = &route;
        try testing.expectEqual(Action.handled, try run(&ctx));
        try testing.expectEqual(c.status, resp.status);
        var found_loc = false;
        for (resp.headers[0..resp.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "location")) {
                try testing.expectEqualStrings("/elsewhere", h.value);
                found_loc = true;
            }
        }
        try testing.expect(found_loc);
    }
}

test "rewrite: non-matching rule passes, query strings survive" {
    const repl = comptime vars.parseComplexValue("/new/$1", &.{});
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/other/x?keep=1";
    req.target = "/other/x?keep=1";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const rules = [_]router_mod.RewriteRule{ruleWith("^/old/(.*)", repl, .last)};
    const route = registry.Route{ .path = "/", .rewrites = &rules };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expect(ctx.internal_redirect_target == null);

    // Matching with a query string: the query is preserved.
    req.decoded_target = "/old/x?keep=1";
    req.target = "/old/x?keep=1";
    ctx.internal_redirect_target = null;
    _ = try run(&ctx);
    try testing.expectEqualStrings("/new/x?keep=1", ctx.internal_redirect_target.?);
}
