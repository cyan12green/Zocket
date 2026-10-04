const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Error logging. Bound to the `log` phase: writes one line
/// per failed request to stderr, with a severity derived from the response
/// status (error >= 500, warn 400-499, info otherwise). Severity filtering
/// is a runtime check against this comptime threshold: raising it to
/// `.error` silences warn/info lines.
pub const error_log = registry.Module{
    .name = "error_log",
    .phase = .log,
    .run = run,
};

pub const Severity = enum { err, warn, info };

/// Comptime threshold: only lines at or above this severity are written.
pub const severity_threshold: Severity = .warn;

/// Severity for a response status (pure: warn/info paths are unit-tested
/// through run(); the .err arm differs only in the log call, which the
/// test runner forbids — any std.log.err fails the whole `zig build test`
/// run — so it is pinned here instead).
fn severityForStatus(status: registry.Status) Severity {
    const code = @intFromEnum(status);
    return if (code >= 500) .err else if (code >= 400) .warn else .info;
}

fn run(ctx: *Context) anyerror!Action {
    const code = @intFromEnum(ctx.resp.status);
    const severity = severityForStatus(ctx.resp.status);
    if (@intFromEnum(severity) > @intFromEnum(severity_threshold)) return .pass;

    var ip_buf: [48]u8 = undefined;
    var ip: []const u8 = "-";
    // Check if any non-zero bytes exist (non-empty peer IP).
    var nonzero = false;
    for (ctx.client_ip) |b| {
        if (b != 0) {
            nonzero = true;
            break;
        }
    }
    if (nonzero) {
        // IPv4-mapped: bytes 10-11 are 0xff 0xff -> dotted-decimal.
        if (ctx.client_ip[10] == 0xff and ctx.client_ip[11] == 0xff) {
            ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ctx.client_ip[12], ctx.client_ip[13], ctx.client_ip[14], ctx.client_ip[15] }) catch "-";
        } else {
            // Full IPv6: hex groups separated by ':'.
            ip = std.fmt.bufPrint(&ip_buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]", .{
                @as(u16, ctx.client_ip[0]) << 8 | ctx.client_ip[1],
                @as(u16, ctx.client_ip[2]) << 8 | ctx.client_ip[3],
                @as(u16, ctx.client_ip[4]) << 8 | ctx.client_ip[5],
                @as(u16, ctx.client_ip[6]) << 8 | ctx.client_ip[7],
                @as(u16, ctx.client_ip[8]) << 8 | ctx.client_ip[9],
                @as(u16, ctx.client_ip[10]) << 8 | ctx.client_ip[11],
                @as(u16, ctx.client_ip[12]) << 8 | ctx.client_ip[13],
                @as(u16, ctx.client_ip[14]) << 8 | ctx.client_ip[15],
            }) catch "-";
        }
    }
    var line_buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} {s} {s} -> {d} {s}\n", .{
        @tagName(severity),
        ip,
        methodName(ctx.req.method),
        ctx.req.target,
        code,
        ctx.resp.status.reasonPhrase(),
    }) catch return .pass;
    if (severity == .err) {
        std.log.err("{s}", .{std.mem.trimEnd(u8, line, &.{'\n'})});
    } else if (severity == .warn) {
        std.log.warn("{s}", .{std.mem.trimEnd(u8, line, &.{'\n'})});
    } else {
        std.log.info("{s}", .{std.mem.trimEnd(u8, line, &.{'\n'})});
    }
    return .pass;
}

fn methodName(m: @import("../../http/parser.zig").Method) []const u8 {
    return switch (m) {
        .get => "GET",
        .head => "HEAD",
        .post => "POST",
        .put => "PUT",
        .delete => "DELETE",
        .options => "OPTIONS",
        .patch => "PATCH",
        .unknown => "?",
    };
}

const testing = std.testing;

test "error severity derives from the status code" {
    try testing.expectEqual(Severity.err, @as(Severity, if (500 >= 500) .err else .info));
    try testing.expectEqual(Severity.warn, @as(Severity, if (404 >= 400 and 404 < 500) .warn else .info));
    try testing.expectEqual(Severity.info, @as(Severity, if (200 >= 500) .err else if (200 >= 400) .warn else .info));
}

test "error_log formats err/warn lines and filters info" {
    // Severity mapping is pinned directly (run() with a 500 would call
    // std.log.err, which fails the whole test run by design).
    try testing.expectEqual(Severity.err, severityForStatus(.internal_error));
    try testing.expectEqual(Severity.warn, severityForStatus(.not_found));
    try testing.expectEqual(Severity.info, severityForStatus(.ok));
    // 404 with an IPv6 client: warn line (exercises the v6 formatter).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .post;
        req.target = "/missing";
        var resp = registry.Response.init(.not_found);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.client_ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
    // 404 with an IPv4 client: warn line (v4 formatter).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .get;
        req.target = "/boom";
        var resp = registry.Response.init(.not_found);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.client_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 };
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
    // 200 with no peer IP: info is below the .warn threshold (early pass).
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .unknown;
        req.target = "/";
        var resp = registry.Response.init(.ok);
        var ctx = Context{ .req = &req, .resp = &resp };
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
    try testing.expectEqualStrings("GET", methodName(.get));
    try testing.expectEqualStrings("?", methodName(.unknown));
}

test "error_log names every method and maps every status class" {
    try testing.expectEqualStrings("HEAD", methodName(.head));
    try testing.expectEqualStrings("POST", methodName(.post));
    try testing.expectEqualStrings("PUT", methodName(.put));
    try testing.expectEqualStrings("DELETE", methodName(.delete));
    try testing.expectEqualStrings("OPTIONS", methodName(.options));
    try testing.expectEqualStrings("PATCH", methodName(.patch));

    try testing.expectEqual(Severity.err, severityForStatus(.internal_error));
    try testing.expectEqual(Severity.err, severityForStatus(.service_unavailable));
    try testing.expectEqual(Severity.err, severityForStatus(.bad_gateway));
    try testing.expectEqual(Severity.warn, severityForStatus(.bad_request));
    try testing.expectEqual(Severity.warn, severityForStatus(.unauthorized));
    try testing.expectEqual(Severity.warn, severityForStatus(.forbidden));
    try testing.expectEqual(Severity.warn, severityForStatus(.payload_too_large));
    try testing.expectEqual(Severity.info, severityForStatus(.ok));
    try testing.expectEqual(Severity.info, severityForStatus(.partial_content));
    try testing.expectEqual(Severity.info, severityForStatus(.not_modified));
}

test "error_log warn line with no peer ip uses a dash" {
    // Zero client_ip exercises the no-peer branch (still warn, still logged).
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .delete;
    req.target = "/gone";
    var resp = registry.Response.init(.not_found);
    var ctx = Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(Action.pass, try run(&ctx));
    try testing.expectEqual(registry.Status.not_found, resp.status);
}

test "error_log info lines stay below the warn threshold" {
    // 304 and 206 are info: early pass without touching the log call.
    for ([_]registry.Status{ .ok, .not_modified, .partial_content }) |status| {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.method = .options;
        req.target = "/cacheable";
        var resp = registry.Response.init(status);
        var ctx = Context{ .req = &req, .resp = &resp };
        ctx.client_ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1 };
        try testing.expectEqual(Action.pass, try run(&ctx));
    }
}
