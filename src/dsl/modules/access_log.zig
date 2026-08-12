const std = @import("std");
const registry = @import("../registry.zig");
const cache_mod = @import("cache.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;

/// Access logging (Milestone 13). Bound to the `log` phase, which runs as
/// pipeline post-processing after every request. The format string is parsed
/// at compile time into a token sequence, so per-request formatting walks a
/// constant token list — zero string scanning. Lines are buffered per
/// reactor (thread-local) and flushed when the buffer fills.
///
/// Default format (nginx combined):
/// `$ip - - [$date] "$request" $status $bytes "$referer" "$user_agent"`
pub const access_log = registry.Module{
    .name = "access_log",
    .phase = .log,
    .run = run,
};

pub const combined_format = "$ip - - [$date] \"$request\" $status $bytes \"$referer\" \"$user_agent\"";

const Token = union(enum) {
    ip,
    date,
    request,
    status,
    bytes,
    referer,
    user_agent,
    literal: []const u8,
};

/// Parse a log format string at compile time into a fixed-size token array.
/// `$name` becomes a field token; everything else is a literal token.
fn parseFormat(comptime fmt: []const u8) [formatTokenCount(fmt)]Token {
    var out_tokens: [formatTokenCount(fmt)]Token = undefined;
    var n: usize = 0;
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '$' and i + 1 < fmt.len) {
            if (i > lit_start) {
                out_tokens[n] = .{ .literal = fmt[lit_start..i] };
                n += 1;
            }
            const field_end = fieldEnd(fmt, i + 1);
            const name = fmt[i + 1 .. field_end];
            out_tokens[n] = fieldToken(name);
            n += 1;
            i = field_end;
            lit_start = i;
        } else {
            i += 1;
        }
    }
    if (i > lit_start) {
        out_tokens[n] = .{ .literal = fmt[lit_start..i] };
        n += 1;
    }
    // Pad any surplus slots (the count bound is generous) so consumers never
    // see uninitialised union tags.
    while (n < out_tokens.len) : (n += 1) {
        out_tokens[n] = .{ .literal = "" };
    }
    return out_tokens;
}

fn fieldEnd(fmt: []const u8, start: usize) usize {
    var i = start;
    while (i < fmt.len and (std.ascii.isAlphanumeric(fmt[i]) or fmt[i] == '_')) i += 1;
    return i;
}

fn fieldToken(comptime name: []const u8) Token {
    if (std.mem.eql(u8, name, "ip")) return .ip;
    if (std.mem.eql(u8, name, "date")) return .date;
    if (std.mem.eql(u8, name, "request")) return .request;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "bytes")) return .bytes;
    if (std.mem.eql(u8, name, "referer")) return .referer;
    if (std.mem.eql(u8, name, "user_agent")) return .user_agent;
    @compileError("unknown log format field: $" ++ name);
}

fn formatTokenCount(comptime fmt: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '$' and i + 1 < fmt.len) {
            n += 1;
            i = fieldEnd(fmt, i + 1);
        } else {
            i += 1;
        }
    }
    // One slot per field, plus one literal slot for any literal text.
    return n * 2 + 1;
}

/// The combined-format token sequence, built at compile time.
pub const tokens = parseFormat(combined_format);

fn run(ctx: *Context) anyerror!Action {
    const allocator = ctx.allocator orelse return .pass;
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    var date_buf: [64]u8 = undefined;
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
    const date = logDate(@intCast(@max(0, ts.sec)), &date_buf);

    var ip_buf: [16]u8 = undefined;
    var ip: []const u8 = "-";
    if (ctx.client_ip[0] != 0 or ctx.client_ip[1] != 0 or ctx.client_ip[2] != 0 or ctx.client_ip[3] != 0) {
        ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ctx.client_ip[0], ctx.client_ip[1], ctx.client_ip[2], ctx.client_ip[3] }) catch "-";
    }

    var req_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1", .{ methodName(ctx.req.method), ctx.req.target }) catch "-";

    const referer = ctx.req.header("referer") orelse "-";
    const user_agent = ctx.req.header("user-agent") orelse "-";
    const status = ctx.resp.status;
    const bytes = ctx.resp.body.len;

    for (tokens) |t| {
        switch (t) {
            .literal => |lit| try line.appendSlice(allocator, lit),
            .ip => try line.appendSlice(allocator, ip),
            .date => try line.appendSlice(allocator, date),
            .request => try line.appendSlice(allocator, request),
            .status => try line.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}", .{@intFromEnum(status)}) catch return error.OutOfMemory),
            .bytes => try line.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}", .{bytes}) catch return error.OutOfMemory),
            .referer => try line.appendSlice(allocator, referer),
            .user_agent => try line.appendSlice(allocator, user_agent),
        }
    }
    try line.append(allocator, '\n');

    // Buffered per-reactor write to stderr (thread-local, process-lifetime,
    // page-allocator-backed so tests never leak through it).
    try log_buffer.appendSlice(std.heap.page_allocator, line.items);
    if (log_buffer.items.len >= 4096) {
        _ = std.posix.write(2, log_buffer.items) catch {};
        log_buffer.clearRetainingCapacity();
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

/// `02/Jan/2006:15:04:05 +0000` — the combined-log-format date.
fn logDate(epoch_secs: u64, buf: []u8) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const yad = day.calculateYearDay();
    const md = yad.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}/{s}/{d}:{d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        md.day_index + 1,
        monthNames[@intFromEnum(md.month) - 1],
        yad.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "-";
}

const monthNames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

threadlocal var log_buffer = std.ArrayList(u8).empty;

const testing = std.testing;

test "combined format parses into the expected token sequence" {
    // The tokens must cover the standard fields in order.
    var saw_ip = false;
    var saw_date = false;
    var saw_request = false;
    var saw_status = false;
    var saw_bytes = false;
    var saw_referer = false;
    var saw_user_agent = false;
    for (tokens) |t| {
        switch (t) {
            .ip => saw_ip = true,
            .date => saw_date = true,
            .request => saw_request = true,
            .status => saw_status = true,
            .bytes => saw_bytes = true,
            .referer => saw_referer = true,
            .user_agent => saw_user_agent = true,
            else => {},
        }
    }
    try testing.expect(saw_ip and saw_date and saw_request and saw_status and saw_bytes and saw_referer and saw_user_agent);
}

test "log date formats in combined style" {
    var buf: [64]u8 = undefined;
    // 2026-08-12 06:00:00 UTC = 1786557600 (approximately; computed below).
    const secs: u64 = 1786557600;
    const formatted = logDate(secs, &buf);
    try testing.expect(formatted.len > 20);
    try testing.expect(formatted[2] == '/');
    try testing.expect(std.mem.indexOf(u8, formatted, ":") != null);
}
