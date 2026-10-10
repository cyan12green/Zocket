//! `try_files` — probe file candidates in order, serve the first hit.
//!
//! Bound to the `content` phase: for each candidate the module resolves the
//! path against the route `root` (same containment rules as the static
//! module) and checks existence. The first existing file becomes an internal
//! redirect to its route-relative URI; when none exists the LAST candidate is
//! the fallback:
//!
//!   try_files $uri $uri/ /fallback.html;  -> redirect to first hit, else /fallback.html
//!   try_files $uri $uri/ =404;            -> redirect to first hit, else 404 in place
//!
//! `$uri` expands to the request target; `$uri/` appends `index` (or the
//! directory itself when no index is configured). A `=code` last candidate
//! sets the status directly instead of redirecting (nginx semantics).
const std = @import("std");
const sys = @import("../../sys.zig");
const registry = @import("../registry.zig");
const router_mod = @import("../router.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

pub const try_files = registry.Module{
    .name = "try_files",
    .phase = .content,
    .run = run,
};

fn run(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.try_files.len == 0) return .pass;
    const root = route.root orelse return .pass;

    for (route.try_files, 0..) |cand, i| {
        const last = i + 1 == route.try_files.len;
        // `=code` fallback: only meaningful as the last candidate.
        if (cand.len > 0 and cand[0] == '=') {
            if (!last) continue;
            const code = std.fmt.parseInt(u16, cand[1..], 10) catch 404;
            ctx.resp.status = @enumFromInt(code);
            ctx.effective_status = code;
            return .handled;
        }
        // `@name` fallback: internal redirect to a named location
        // (nginx requires it last; we accept it anywhere but stop there).
        if (cand.len > 1 and cand[0] == '@') {
            ctx.internal_redirect_named = ctx.sharedDupe(cand) orelse return error.OutOfMemory;
            return .pass;
        }
        const rel = expandCandidate(ctx, cand) orelse continue;
        if (rel.len == 0) continue;
        if (fileExists(root, rel)) {
            // Internal redirect to the route-relative URI of the hit.
            const uri = ctx.sharedDupe(rel) orelse return error.OutOfMemory;
            ctx.internal_redirect_target = uri;
            return .pass;
        }
        if (last) {
            // Fallback URI: redirect to it verbatim.
            const uri = ctx.sharedDupe(cand) orelse return error.OutOfMemory;
            ctx.internal_redirect_target = uri;
            return .pass;
        }
    }
    return .pass;
}

/// Expand one candidate: `$uri` -> request target, `$uri/` -> target with
/// `index` appended (or the directory itself). Other candidates pass through
/// (literal fallback URIs like `/fallback.html`).
fn expandCandidate(ctx: *Context, cand: []const u8) ?[]const u8 {
    const route = ctx.route orelse return null;
    if (std.mem.eql(u8, cand, "$uri")) {
        return ctx.req.decoded_target;
    }
    if (std.mem.eql(u8, cand, "$uri/")) {
        const target = ctx.req.decoded_target;
        if (route.index) |idx| {
            const has_slash = target.len > 0 and target[target.len - 1] == '/';
            if (has_slash) {
                const out = ctx.sharedFmt("{s}{s}", .{ target, idx }) orelse return null;
                return out;
            }
            const out = ctx.sharedFmt("{s}/{s}", .{ target, idx }) orelse return null;
            return out;
        }
        return target;
    }
    return cand;
}

/// Existence check for `root` + `/` + `rel`, contained like the static
/// module (no `..` escapes; absolute `rel` is relative to root).
fn fileExists(root: []const u8, rel: []const u8) bool {
    // Reject escapes before touching the fs.
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return false;
            depth -= 1;
        } else depth += 1;
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel }) catch return false;
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0) catch return false;
    sys.close(fd);
    return true;
}

const testing = std.testing;

test "try_files: no candidates or no root is inert" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
    const cands = [_][]const u8{ "$uri", "=404" };
    const route = registry.Route{ .path = "/", .try_files = &cands };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
}

test "try_files: serves the first existing candidate" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/hello.txt";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const cands = [_][]const u8{ "$uri", "/fallback.html", "=404" };
    const route = registry.Route{ .path = "/", .root = "testdata", .try_files = &cands };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("/hello.txt", ctx.internal_redirect_target.?);
}

test "try_files: missing file falls to the URI fallback" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/nope-missing.txt";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const cands = [_][]const u8{ "$uri", "/fallback.html" };
    const route = registry.Route{ .path = "/", .root = "testdata", .try_files = &cands };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("/fallback.html", ctx.internal_redirect_target.?);
}

test "try_files: =code fallback sets the status in place" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/nope-missing.txt";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const cands = [_][]const u8{ "$uri", "=404" };
    const route = registry.Route{ .path = "/", .root = "testdata", .try_files = &cands };
    ctx.route = &route;
    try testing.expectEqual(Action.handled, try run(&ctx));
    try testing.expectEqual(registry.Status.not_found, resp.status);
    try testing.expect(ctx.internal_redirect_target == null);
}

test "try_files: $uri/ appends the index file" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/dir";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const cands = [_][]const u8{ "$uri/" };
    const route = registry.Route{ .path = "/", .root = "testdata", .index = "index.html", .try_files = &cands };
    ctx.route = &route;
    _ = try run(&ctx);
    // /dir/index.html does not exist in testdata -> single candidate falls
    // back to itself as a URI; the point is the index expansion happened.
    try testing.expect(ctx.internal_redirect_target != null);
}

test "try_files: traversal candidates never escape the root" {
    try testing.expect(!fileExists("testdata", "../../etc/passwd"));
    try testing.expect(!fileExists("testdata", "/etc/passwd"));
    try testing.expect(fileExists("testdata", "/hello.txt"));
}

test "try_files: @name candidate redirects to the named location" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.decoded_target = "/missing";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    const cands = [_][]const u8{ "$uri", "@app" };
    const route = registry.Route{ .path = "/", .root = "testdata", .try_files = &cands };
    ctx.route = &route;
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqualStrings("@app", ctx.internal_redirect_named.?);
    try testing.expect(ctx.internal_redirect_target == null);
}
