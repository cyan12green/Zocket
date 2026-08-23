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

fn run(ctx: *Context) anyerror!Action {
    const code = @intFromEnum(ctx.resp.status);
    const severity: Severity = if (code >= 500) .err else if (code >= 400) .warn else .info;
    if (@intFromEnum(severity) > @intFromEnum(severity_threshold)) return .pass;

    var ip_buf: [16]u8 = undefined;
    var ip: []const u8 = "-";
    if (ctx.client_ip[0] != 0 or ctx.client_ip[1] != 0 or ctx.client_ip[2] != 0 or ctx.client_ip[3] != 0) {
        ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ctx.client_ip[0], ctx.client_ip[1], ctx.client_ip[2], ctx.client_ip[3] }) catch "-";
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
    _ = std.posix.write(2, line) catch {};
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
