const std = @import("std");
const registry = @import("../registry.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Conditional-GET handling. Bound to the `preaccess`
/// phase: when the content metadata (`ctx.etag` / `ctx.last_modified`, set
/// before content, e.g. by a post_read stat) matches `If-None-Match` /
/// `If-Modified-Since`, the request is answered with 304 Not Modified and the
/// pipeline stops. Otherwise passes through to content.
pub const conditional_get = registry.Module{
    .name = "conditional_get",
    .phase = .preaccess,
    .run = conditionalRun,
};

/// Cache-header emission. Bound to the `post_access`
/// phase: writes `Cache-Control` (from the route's `max_age_seconds`; 0 →
/// no-cache) and, when the content metadata is known, `ETag` and
/// `Last-Modified`.
pub const cache_headers = registry.Module{
    .kind = .filter,
    .name = "cache_headers",
    .phase = .post_access,
    .run = cacheRun,
};

fn conditionalRun(ctx: *Context) anyerror!Action {
    const etag = ctx.etag orelse "";
    const lm = ctx.last_modified orelse "";
    if (etag.len == 0 and lm.len == 0) return .pass;

    if (ctx.req.header("if-none-match")) |inm| {
        if (etag.len > 0 and etagMatches(inm, etag)) return notModified(ctx);
    }
    if (ctx.req.header("if-modified-since")) |ims| {
        if (lm.len > 0) {
            const since = parseHttpDate(ims) orelse return .pass;
            const modified = parseHttpDate(lm) orelse return .pass;
            // 304 when the entity was not modified after the client's copy.
            if (modified <= since) return notModified(ctx);
        }
    }
    return .pass;
}

fn notModified(ctx: *Context) Action {
    ctx.resp.status = .not_modified;
    ctx.resp.body = &.{};
    return .handled;
}

/// True if a comma-separated If-None-Match value matches `etag` (a strong
/// tag). `*` matches anything; `W/` weak prefixes are tolerated. Exported for
/// content modules (e.g. static) that answer their own conditional requests.
pub fn etagMatches(value: []const u8, etag: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, value, ",");
    while (tokens.next()) |t| {
        var tok = std.mem.trim(u8, t, " \t");
        if (std.mem.eql(u8, tok, "*")) return true;
        if (std.mem.startsWith(u8, tok, "W/")) tok = tok[2..];
        if (std.mem.eql(u8, tok, etag)) return true;
    }
    return false;
}

fn cacheRun(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (route.max_age_seconds > 0) {
        ctx.resp.setHeaderFmt("Cache-Control", "max-age={d}", .{route.max_age_seconds});
    } else {
        ctx.resp.setHeader("Cache-Control", "no-cache");
    }
    if (ctx.etag) |etag| ctx.resp.setHeader("ETag", etag);
    if (ctx.last_modified) |lm| ctx.resp.setHeader("Last-Modified", lm);
    return .pass;
}

// ---- HTTP date handling (IMF-fixdate, RFC 9110 §5.6.7) ----

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Format seconds since the Unix epoch as an IMF-fixdate
/// ("Sun, 06 Nov 1994 08:49:37 GMT").
pub fn formatHttpDate(epoch_secs: u64, buf: []u8) ?[]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const yad = day.calculateYearDay();
    const md = yad.calculateMonthDay();
    const ds = es.getDaySeconds();
    // 1970-01-01 was a Thursday.
    const weekday = (day.day + 4) % 7;
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[weekday],
        md.day_index + 1,
        month_names[@intFromEnum(md.month) - 1],
        yad.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch null;
}

/// Parse an IMF-fixdate into seconds since the Unix epoch.
pub fn parseHttpDate(s: []const u8) ?u64 {
    if (s.len != 29) return null;
    if (!std.mem.eql(u8, s[26..], "GMT")) return null;

    const day = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const month = monthIndex(s[8..11]) orelse return null;
    const year = std.fmt.parseInt(u32, s[12..16], 10) catch return null;
    const hh = std.fmt.parseInt(u32, s[17..19], 10) catch return null;
    const mm = std.fmt.parseInt(u32, s[20..22], 10) catch return null;
    const ss = std.fmt.parseInt(u32, s[23..25], 10) catch return null;
    if (year < 1970 or day < 1 or day > 31 or hh > 23 or mm > 59 or ss > 59) return null;

    const days = daysFromCivil(year, month, day);
    return days * 86400 + @as(u64, hh) * 3600 + @as(u64, mm) * 60 + ss;
}

fn monthIndex(abbr: []const u8) ?u32 {
    for (month_names, 0..) |m, i| {
        if (std.mem.eql(u8, abbr, m)) return @intCast(i + 1);
    }
    return null;
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(year: u32, month: u32, day: u32) u64 {
    const y = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @as(i64, month) + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @intCast(era * 146097 + doe - 719468);
}

const testing = std.testing;

fn dateRoundtrip(secs: u64) !void {
    var buf: [64]u8 = undefined;
    const formatted = formatHttpDate(secs, &buf).?;
    const parsed = parseHttpDate(formatted).?;
    try testing.expectEqual(secs, parsed);
}

test "http date format/parse roundtrip" {
    try dateRoundtrip(0);
    try dateRoundtrip(946684800); // 2000-01-01
    try dateRoundtrip(1622924906);
    try dateRoundtrip(1773705600); // 2026-03-14

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        formatHttpDate(0, &buf).?,
    );
    try testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        formatHttpDate(784111777, &buf).?,
    );
    try testing.expectEqual(@as(?u64, null), parseHttpDate("garbage"));
    try testing.expectEqual(@as(?u64, null), parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC"));
}

fn parseRequest(allocator: std.mem.Allocator, wire: []const u8) !struct { req: registry.Request, parser: @import("../../http/parser.zig").Parser, buf: *@import("../../net/buffer.zig").Buffer } {
    var req = registry.Request.init(allocator);
    var p = @import("../../http/parser.zig").Parser.init(allocator);
    const buffer_mod = @import("../../net/buffer.zig");
    var buf = try buffer_mod.Buffer.init(allocator);
    _ = buf.writeSlice(wire);
    try testing.expectEqual(@import("../../http/parser.zig").Outcome.complete, p.parse(buf, &req));
    return .{ .req = req, .parser = p, .buf = buf };
}

test "conditional_get answers 304 on a matching If-None-Match" {
    const allocator = testing.allocator;
    var st = try parseRequest(allocator, "GET / HTTP/1.1\r\nIf-None-Match: \"abc123\"\r\n\r\n");
    defer st.req.deinit();
    defer st.parser.deinit();
    defer st.buf.deinit(allocator);

    var resp = registry.Response.init(.ok);
    resp.setBody("full body");
    var ctx = Context{ .req = &st.req, .resp = &resp, .etag = "\"abc123\"" };

    try testing.expectEqual(Action.handled, try conditional_get.run(&ctx));
    try testing.expectEqual(registry.Status.not_modified, resp.status);
    try testing.expectEqual(@as(usize, 0), resp.body.len);

    // A non-matching tag passes through to content.
    var st2 = try parseRequest(allocator, "GET / HTTP/1.1\r\nIf-None-Match: \"other\"\r\n\r\n");
    defer st2.req.deinit();
    defer st2.parser.deinit();
    defer st2.buf.deinit(allocator);
    var resp2 = registry.Response.init(.ok);
    resp2.setBody("full body");
    var ctx2 = Context{ .req = &st2.req, .resp = &resp2, .etag = "\"abc123\"" };
    try testing.expectEqual(Action.pass, try conditional_get.run(&ctx2));
    try testing.expectEqual(registry.Status.ok, resp2.status);
}

test "conditional_get answers 304 on a matching If-Modified-Since" {
    const allocator = testing.allocator;
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const lm = formatHttpDate(946684800, &buf_a).?;
    const later = formatHttpDate(946684801, &buf_b).?;

    var wire_buf: [256]u8 = undefined;
    const wire = std.fmt.bufPrint(&wire_buf, "GET / HTTP/1.1\r\nIf-Modified-Since: {s}\r\n\r\n", .{later}) catch unreachable;
    var st = try parseRequest(allocator, wire);
    defer st.req.deinit();
    defer st.parser.deinit();
    defer st.buf.deinit(allocator);

    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &st.req, .resp = &resp, .last_modified = lm };
    try testing.expectEqual(Action.handled, try conditional_get.run(&ctx));
    try testing.expectEqual(registry.Status.not_modified, resp.status);

    // A client copy older than the entity: pass through.
    var wire2: [256]u8 = undefined;
    var buf_c: [64]u8 = undefined;
    const wire2s = std.fmt.bufPrint(&wire2, "GET / HTTP/1.1\r\nIf-Modified-Since: {s}\r\n\r\n", .{formatHttpDate(946684799, &buf_c).?}) catch unreachable;
    var st2 = try parseRequest(allocator, wire2s);
    defer st2.req.deinit();
    defer st2.parser.deinit();
    defer st2.buf.deinit(allocator);
    var resp2 = registry.Response.init(.ok);
    var ctx2 = Context{ .req = &st2.req, .resp = &resp2, .last_modified = lm };
    try testing.expectEqual(Action.pass, try conditional_get.run(&ctx2));
}

test "conditional_get passes when no entity metadata is set" {
    const allocator = testing.allocator;
    var st = try parseRequest(allocator, "GET / HTTP/1.1\r\nIf-None-Match: \"x\"\r\n\r\n");
    defer st.req.deinit();
    defer st.parser.deinit();
    defer st.buf.deinit(allocator);
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &st.req, .resp = &resp };
    try testing.expectEqual(Action.pass, try conditional_get.run(&ctx));
}

test "cache_headers emits Cache-Control, ETag and Last-Modified" {
    const allocator = testing.allocator;
    var st = try parseRequest(allocator, "GET / HTTP/1.1\r\n\r\n");
    defer st.req.deinit();
    defer st.parser.deinit();
    defer st.buf.deinit(allocator);

    const route = registry.Route{
        .path = "/",
        .max_age_seconds = 3600,
    };
    var resp = registry.Response.init(.ok);
    var ctx = Context{
        .req = &st.req,
        .resp = &resp,
        .route = &route,
        .etag = "\"mtime-size\"",
        .last_modified = "Sun, 06 Nov 1994 08:49:37 GMT",
    };

    try testing.expectEqual(Action.pass, try cache_headers.run(&ctx));
    try testing.expectEqualStrings("max-age=3600", resp.headers[0].value);
    try testing.expectEqualStrings("Cache-Control", resp.headers[0].name);
    try testing.expectEqualStrings("\"mtime-size\"", resp.headers[1].value);
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", resp.headers[2].value);
}

test "cache_headers emits no-cache when max_age is zero" {
    const allocator = testing.allocator;
    var st = try parseRequest(allocator, "GET / HTTP/1.1\r\n\r\n");
    defer st.req.deinit();
    defer st.parser.deinit();
    defer st.buf.deinit(allocator);

    const route = registry.Route{ .path = "/" };
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &st.req, .resp = &resp, .route = &route };
    try testing.expectEqual(Action.pass, try cache_headers.run(&ctx));
    try testing.expectEqualStrings("no-cache", resp.headers[0].value);
}
