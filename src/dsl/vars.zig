const std = @import("std");
const registry = @import("registry.zig");
const http_parser = @import("../http/parser.zig");
const arena_mod = @import("../http/arena.zig");
const ct_pool = @import("../ct_pool.zig");

pub const Context = registry.Context;

/// Built-in variable id (M-B). The conf parser resolves `$name` to one of
/// these at compile time; the renderer switches on it per request.
pub const VarId = enum {
    method,
    request_uri,
    uri,
    args,
    query_string,
    host,
    status,
    body_bytes_sent,
    remote_addr,
    remote_port,
    server_protocol,
    scheme,
    request_time,
    content_length,
    content_type,
    ip,
    date,
    request,
    bytes,
    referer,
    user_agent,
    time_local,
    time_iso8601,
};

/// One compiled fragment of a complex value (nginx's "complex value"): a
/// literal slice, a fixed built-in variable, a generic hashed variable
/// (`$http_*`, `$arg_*`, `$cookie_*`), a regex capture `$1..$9`, or a
/// user-variable slot (`set $name`). Built once at compile time by
/// `parseComplexValue`; rendering is a comptime-switched loop.
pub const Frag = union(enum) {
    /// Zero-copy slice into the conf source (.rodata).
    literal: []const u8,
    /// Fixed built-in variable.
    builtin: VarId,
    /// `$http_<name>`: header_hasher.hash of the dashed name.
    http_header: u32,
    /// `$arg_<name>`: FNV-1a (verbatim, case-sensitive) of the param name.
    arg: u32,
    /// `$cookie_<name>`: FNV-1a (lowercased) of the cookie name.
    cookie: u32,
    /// `$1..$9` → index 1..9 into ctx.captures.
    capture: u8,
    /// Slot index into ctx.user_slots (comptime-resolved).
    user: u8,
};

/// A user variable declared with `set` in a location (M-C).
pub const SetVar = struct { name: []const u8, slot: u8, value: []const Frag };

/// A named log format (conf `log_format <name> "<complex value>";`). The
/// value is a compiled complex-value fragment list.
pub const LogFormat = struct {
    name: []const u8,
    value: []const Frag,
};

/// A proxy_set_header override (M-E).
pub const ProxyHeader = struct { name: []const u8, value: []const Frag };

/// A dynamic response template header (M-B).
pub const CVHeader = struct { name: []const u8, value: []const Frag };

/// One header-manipulation operation (headers module, backlog item):
/// `set` replaces the first header of that name or appends, `add` appends,
/// `remove` drops every header of that name. Values are complex values and
/// may reference $variables; they render into the request arena per request.
pub const HeaderOpKind = enum { set, add, remove };
pub const HeaderOp = struct {
    kind: HeaderOpKind,
    name: []const u8,
    value: []const Frag = &.{},
};

/// Dynamic (variable-capable) response template (M-B). Parallel to
/// `ResponseTemplate`; the literal fast path stays untouched.
pub const ResponseTemplateCV = struct {
    status: u16 = 200,
    headers: []const CVHeader = &.{},
    body: []const Frag = &.{},
    compress: bool = false,
};

/// A regex capture range into `capture_subject` (M-D).
pub const CaptureRange = struct { start: u16, end: u16 };

/// A compiled regex NFA (M-D). The engine lives in `regex.zig`.
pub const Regex = struct {
    states: []const RegexState = &.{},
    group_count: u8 = 0,
    /// Character-class bitmaps referenced by kind_class/kind_class_ci
    /// states (`byte` = index into this table).
    class_bitmaps: []const [32]u32 = &.{},
};

/// One NFA state (M-D; shape from the plan §6.2).
pub const RegexState = struct {
    kind: u8 = 1, // 0=consume, 1=epsilon, 2=match
    byte: u16 = 0xFFFF,
    next: u32 = 0,
    next2: u32 = 0,
    cap_start: i16 = -1,
    cap_end: i16 = -1,
};

/// Comptime cap on `set $name` user variables per location.
pub const max_user_vars = 8;

// ---- name → VarId resolution (comptime) ----

const H_method = keyHash("method");
const H_request_uri = keyHash("request_uri");
const H_uri = keyHash("uri");
const H_args = keyHash("args");
const H_query_string = keyHash("query_string");
const H_host = keyHash("host");
const H_status = keyHash("status");
const H_body_bytes_sent = keyHash("body_bytes_sent");
const H_remote_addr = keyHash("remote_addr");
const H_remote_port = keyHash("remote_port");
const H_server_protocol = keyHash("server_protocol");
const H_scheme = keyHash("scheme");
const H_request_time = keyHash("request_time");
const H_content_length = keyHash("content_length");
const H_content_type = keyHash("content_type");
const H_ip = keyHash("ip");
const H_date = keyHash("date");
const H_request = keyHash("request");
const H_bytes = keyHash("bytes");
const H_referer = keyHash("referer");
const H_user_agent = keyHash("user_agent");
const H_time_local = keyHash("time_local");
const H_time_iso8601 = keyHash("time_iso8601");

/// Resolve a built-in variable name to its VarId; null when not a built-in.
pub fn resolveBuiltin(comptime name: []const u8) ?VarId {
    return switch (keyHash(name)) {
        H_method => .method,
        H_request_uri => .request_uri,
        H_uri => .uri,
        H_args => .args,
        H_query_string => .query_string,
        H_host => .host,
        H_status => .status,
        H_body_bytes_sent => .body_bytes_sent,
        H_remote_addr => .remote_addr,
        H_remote_port => .remote_port,
        H_server_protocol => .server_protocol,
        H_scheme => .scheme,
        H_request_time => .request_time,
        H_content_length => .content_length,
        H_content_type => .content_type,
        H_ip => .ip,
        H_date => .date,
        H_request => .request,
        H_bytes => .bytes,
        H_referer => .referer,
        H_user_agent => .user_agent,
        H_time_local => .time_local,
        H_time_iso8601 => .time_iso8601,
        else => null,
    };
}

fn keyHash(key: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (key) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

// ---- parseComplexValue (comptime) ----

/// Parse a complex value at compile time into a fragment list. Grammar:
/// `$$` → literal `$`; `${name}` → braced name; `$name` → variable;
/// anything else is a literal. Name resolution order (plan §5.4):
/// 1. `$1..$9` → capture
/// 2. `http_<name>` → http_header (hash of dashed name)
/// 3. `arg_<name>` → arg (verbatim hash)
/// 4. `cookie_<name>` → cookie (lowercased hash)
/// 5. declared `set` name in scope → user slot
/// 6. built-in VarId by exact name
/// 7. else compile error
pub fn parseComplexValue(
    comptime text: []const u8,
    comptime set_vars: []const SetVar,
) []const Frag {
    @setEvalBranchQuota(10000);
    return comptime blk: {
        var pool = ct_pool.CtPool(Frag, text.len + 1){};
        var i: usize = 0;
        var lit_start: usize = 0;
        while (i < text.len) {
            if (text[i] != '$') {
                i += 1;
                continue;
            }
            // A '$' at position i.
            if (i > lit_start) {
                _ = pool.create(.{ .literal = text[lit_start..i] });
            }
            if (i + 1 < text.len and text[i + 1] == '$') {
                // $$ → literal '$'
                _ = pool.create(.{ .literal = "$" });
                i += 2;
                lit_start = i;
                continue;
            }
            if (i + 1 < text.len and text[i + 1] == '{') {
                // ${name}
                const close = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse
                    @compileError("unterminated ${...} in complex value");
                const name = text[i + 2 .. close];
                _ = pool.create(resolveName(name, set_vars, "complex value"));
                i = close + 1;
                lit_start = i;
                continue;
            }
            // $name
            var end = i + 1;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            const name = text[i + 1 .. end];
            _ = pool.create(resolveName(name, set_vars, "complex value"));
            i = end;
            lit_start = i;
        }
        if (i > lit_start) {
            _ = pool.create(.{ .literal = text[lit_start..i] });
        }
        break :blk pool.freeze();
    };
}

/// Resolve one `$name` reference to a Frag (the resolution order above).
fn resolveName(comptime name: []const u8, comptime set_vars: []const SetVar, comptime where: []const u8) Frag {
    // 1. captures $1..$9
    if (name.len == 1 and name[0] >= '1' and name[0] <= '9') {
        return .{ .capture = name[0] - '0' };
    }
    // 2. $http_<name>
    if (std.mem.startsWith(u8, name, "http_")) {
        var dashed: [name.len - 5]u8 = undefined;
        for (name[5..], 0..) |c, j| {
            dashed[j] = if (c == '_') '-' else c;
        }
        return .{ .http_header = http_parser.header_hasher.hash(&dashed) };
    }
    // 3. $arg_<name> (verbatim, case-sensitive)
    if (std.mem.startsWith(u8, name, "arg_")) {
        return .{ .arg = hashFn(name[4..]) };
    }
    // 4. $cookie_<name> (lowercased)
    if (std.mem.startsWith(u8, name, "cookie_")) {
        return .{ .cookie = hashLower(name[7..]) };
    }
    // 5. declared set vars in scope
    inline for (set_vars) |sv| {
        if (std.mem.eql(u8, sv.name, name)) {
            return .{ .user = sv.slot };
        }
    }
    // 6. built-in VarId
    if (resolveBuiltin(name)) |id| {
        return .{ .builtin = id };
    }
    // 7. unknown
    @compileError("unknown variable '$" ++ name ++ "' in " ++ where);
}

/// FNV-1a (32-bit) verbatim (query args are case-sensitive).
pub fn hashFn(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

/// FNV-1a (32-bit) over lower-cased bytes (cookies).
pub fn hashLower(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |c| {
        h ^= std.ascii.toLower(c);
        h *%= 16777619;
    }
    return h;
}

// ---- runtime getters ----

/// Scratch for digit/formatted getters (option (a) from the plan: getters
/// write into a caller-provided scratch; the renderer owns one on the stack).
const GetterScratch = struct {
    buf: [128]u8 = undefined,
    used: usize = 0,

    fn set(self: *GetterScratch, s: []const u8) []const u8 {
        self.used = s.len;
        @memcpy(self.buf[0..s.len], s);
        return self.buf[0..s.len];
    }

    fn fmt(self: *GetterScratch, comptime f: []const u8, args: anytype) []const u8 {
        const s = std.fmt.bufPrint(&self.buf, f, args) catch return "-";
        self.used = s.len;
        return s;
    }
};

/// Render one built-in variable into a caller-owned scratch. Returns a
/// zero-copy slice (from req/ctx) or a slice into `scratch` (digits /
/// formatted values); the renderer appends immediately, so scratch lifetime
/// is the call.
fn getBuiltin(ctx: *Context, id: VarId, scratch: *GetterScratch) []const u8 {
    const req = ctx.req;
    switch (id) {
        .method => return methodName(req.method),
        .request_uri => return req.target,
        .uri => {
            return req.decoded_target;
        },
        .args, .query_string => return req.query_string,
        .host => return req.header("host") orelse "",
        .status => return scratch.fmt("{d}", .{@intFromEnum(ctx.resp.status)}),
        .body_bytes_sent, .bytes => return scratch.fmt("{d}", .{ctx.resp.body.len}),
        .remote_addr, .ip => {
            const ip = ctx.client_ip;
            if (ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0) return "-";
            return scratch.fmt("{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        },
        .remote_port => return "-", // not tracked on Context yet (plan §5.2)
        .server_protocol => return switch (req.version.major) {
            0 => "HTTP/?",
            else => if (req.version.minor == 0) "HTTP/1.0" else "HTTP/1.1",
        },
        .scheme => return "http",
        .request_time => {
            // Instant.now can fail (hostile seccomp); started zeroed → 0.
            const now = std.time.Instant.now() catch return "0";
            const us = if (ctx.started.timestamp.sec == 0 and ctx.started.timestamp.nsec == 0)
                0
            else
                now.since(ctx.started);
            return scratch.fmt("{d}", .{@divTrunc(us, std.time.ns_per_s)});
        },
        .content_length => return scratch.fmt("{d}", .{req.content_length}),
        .content_type => return req.header("content-type") orelse "",
        .date, .time_local => {
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
            var buf: [64]u8 = undefined;
            return scratch.set(logDate(@intCast(@max(0, ts.sec)), &buf));
        },
        .time_iso8601 => {
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
            var buf: [64]u8 = undefined;
            return scratch.set(iso8601Date(@intCast(@max(0, ts.sec)), &buf));
        },
        .request => return scratch.fmt("{s} {s} HTTP/1.1", .{ methodName(req.method), req.target }),
        .referer => return req.header("referer") orelse "-",
        .user_agent => return req.header("user-agent") orelse "-",
    }
}

fn methodName(m: http_parser.Method) []const u8 {
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
pub fn logDate(epoch_secs: u64, buf: []u8) []const u8 {
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

/// `2026-08-16T18:00:00+00:00` — ISO-8601.
fn iso8601Date(epoch_secs: u64, buf: []u8) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const yad = day.calculateYearDay();
    const md = yad.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        yad.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "-";
}

pub const monthNames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

// ---- generic variable lookups ($http_*, $arg_*, $cookie_*) ----

/// `$http_<name>`: scan request header slots comparing the lowercased hash.
fn getHttpHeader(ctx: *Context, h: u32) []const u8 {
    const req = ctx.req;
    for (0..req.headerCount()) |i| {
        const slot = req.headerAt(i);
        if (http_parser.header_hasher.hash(slot.name) == h) return slot.value;
    }
    return "";
}

/// `$arg_<name>`: split the query string once on & and =, hash verbatim.
fn getArg(ctx: *Context, h: u32) []const u8 {
    var qs = ctx.req.query_string;
    if (std.mem.startsWith(u8, qs, "?")) qs = qs[1..];
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        // Value excludes the '='; a bare name (no '=') yields "".
        if (hashFn(pair[0..eq]) == h) return if (eq < pair.len) pair[eq + 1 ..] else "";
    }
    return "";
}

/// `$cookie_<name>`: split the Cookie header once on ;, trim, split on =.
fn getCookie(ctx: *Context, h: u32) []const u8 {
    const cookie_header = ctx.req.header("cookie") orelse return "";
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (hashLower(trimmed[0..eq]) == h) return trimmed[eq + 1 ..];
    }
    return "";
}

/// A regex capture range (`$1..$9`): slices `ctx.capture_subject`.
fn getCapture(ctx: *Context, index: u8) []const u8 {
    if (index >= ctx.capture_count) return "";
    const r = ctx.captures[index];
    const s = ctx.capture_subject;
    if (r.start >= s.len or r.end > s.len or r.end < r.start) return "";
    return s[r.start..r.end];
}

// ---- sinks ----

/// A sink is anything exposing `appendAll([]const u8) !void`.
pub const ArrayListSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn appendAll(self: *ArrayListSink, s: []const u8) !void {
        try self.list.appendSlice(self.allocator, s);
    }
};

pub const ArenaSink = struct {
    arena: *arena_mod.Arena,

    pub fn appendAll(self: *ArenaSink, s: []const u8) !void {
        const dst = self.arena.alloc(s.len) orelse return error.OutOfMemory;
        @memcpy(dst, s);
    }
};

// ---- renderComplex (runtime) ----

/// Render a compiled complex value into `sink`. Zero allocations except
/// when the sink materializes (ArenaSink) or a user variable renders.
pub fn renderComplex(ctx: *Context, value: []const Frag, sink: anytype) !void {
    var scratch = GetterScratch{};
    for (value) |frag| {
        switch (frag) {
            .literal => |lit| try sink.appendAll(lit),
            .builtin => |id| try sink.appendAll(getBuiltin(ctx, id, &scratch)),
            .http_header => |h| try sink.appendAll(getHttpHeader(ctx, h)),
            .arg => |h| try sink.appendAll(getArg(ctx, h)),
            .cookie => |h| try sink.appendAll(getCookie(ctx, h)),
            .capture => |idx| try sink.appendAll(getCapture(ctx, idx)),
            .user => |slot| {
                // Lazy render-on-first-use into the request arena, cached in
                // ctx.user_slots[slot] (M-C). The route's SetVar table is
                // reached through ctx.route.
                if (ctx.user_slots[slot]) |cached| {
                    try sink.appendAll(cached);
                    continue;
                }
                const route = ctx.route orelse continue;
                const sv = route.set_vars[slot];
                const rendered = renderComplexArena(ctx, sv.value, &ctx.req.arena) orelse
                    return error.OutOfMemory;
                ctx.user_slots[slot] = rendered;
                try sink.appendAll(rendered);
            },
        }
    }
}

/// Render a compiled complex value into the request arena and return a
/// single slice. Two-pass: compute the rendered length first, allocate
/// once in the arena, then fill (no fragmentation, one bump).
pub fn renderComplexArena(ctx: *Context, value: []const Frag, arena: *arena_mod.Arena) ?[]const u8 {
    var len: usize = 0;
    {
        var scratch = GetterScratch{};
        for (value) |frag| {
            len += fragLen(ctx, frag, &scratch) orelse return null;
        }
    }
    const dst = arena.alloc(len) orelse return null;
    var pos: usize = 0;
    var scratch = GetterScratch{};
    for (value) |frag| {
        const s = fragSlice(ctx, frag, &scratch) orelse return null;
        @memcpy(dst[pos..][0..s.len], s);
        pos += s.len;
    }
    return dst[0..pos];
}

/// Rendered length of one fragment (null when the user-variable cache
/// render fails).
fn fragLen(ctx: *Context, frag: Frag, scratch: *GetterScratch) ?usize {
    return switch (frag) {
        .literal => |lit| lit.len,
        .builtin => |id| getBuiltin(ctx, id, scratch).len,
        .http_header => |h| getHttpHeader(ctx, h).len,
        .arg => |h| getArg(ctx, h).len,
        .cookie => |h| getCookie(ctx, h).len,
        .capture => |idx| getCapture(ctx, idx).len,
        .user => |slot| blk: {
            if (ctx.user_slots[slot]) |cached| break :blk cached.len;
            const route = ctx.route orelse break :blk 0;
            const sv = route.set_vars[slot];
            const rendered = renderComplexArena(ctx, sv.value, &ctx.req.arena) orelse return null;
            ctx.user_slots[slot] = rendered;
            break :blk rendered.len;
        },
    };
}

/// The slice of one fragment (a scratch-backed getter's slice is copied
/// into the arena by the caller; user slots return the cached slice).
fn fragSlice(ctx: *Context, frag: Frag, scratch: *GetterScratch) ?[]const u8 {
    return switch (frag) {
        .literal => |lit| lit,
        .builtin => |id| getBuiltin(ctx, id, scratch),
        .http_header => |h| getHttpHeader(ctx, h),
        .arg => |h| getArg(ctx, h),
        .cookie => |h| getCookie(ctx, h),
        .capture => |idx| getCapture(ctx, idx),
        .user => |slot| ctx.user_slots[slot] orelse "",
    };
}

// ---- tests ----

const testing = std.testing;

test "parseComplexValue: literals, $$, braced names and variables" {
    const frags = parseComplexValue("a$host-b$$c", &.{});
    // "a" | $host | "-b" | "$" | "c"
    try testing.expectEqual(@as(usize, 5), frags.len);
    try testing.expectEqualStrings("a", frags[0].literal);
    try testing.expectEqual(VarId.host, frags[1].builtin);
    try testing.expectEqualStrings("-b", frags[2].literal);
    try testing.expectEqualStrings("$", frags[3].literal);
    try testing.expectEqualStrings("c", frags[4].literal);
}

test "parseComplexValue: braced names and http_/arg_/cookie_ hashing" {
    const frags = parseComplexValue("${request_uri} $http_user_agent $arg_q $cookie_session", &.{});
    try testing.expectEqual(@as(usize, 7), frags.len);
    try testing.expectEqual(VarId.request_uri, frags[0].builtin);
    try testing.expectEqual(
        comptime http_parser.header_hasher.hash("user-agent"),
        frags[2].http_header,
    );
    try testing.expectEqual(comptime hashFn("q"), frags[4].arg);
    try testing.expectEqual(comptime hashLower("session"), frags[6].cookie);
}

test "parseComplexValue: captures $1..$9" {
    const frags = parseComplexValue("api/$1/$2", &.{});
    try testing.expectEqual(@as(u8, 1), frags[1].capture);
    try testing.expectEqual(@as(u8, 2), frags[3].capture);
}

test "parseComplexValue: set vars resolve to user slots" {
    const set_vars = [_]SetVar{
        .{ .name = "api_ver", .slot = 0, .value = &.{} },
        .{ .name = "region", .slot = 1, .value = &.{} },
    };
    const frags = parseComplexValue("v=$api_ver/$region", &set_vars);
    try testing.expectEqual(@as(u8, 0), frags[1].user);
    try testing.expectEqual(@as(u8, 1), frags[3].user);
}

test "renderComplex renders builtins and literals" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/hello?x=1";
    req.decoded_target = "/hello";
    req.query_string = "?x=1";
    req.addHeaderParsed("host", "example.com") catch unreachable;

    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const frags = parseComplexValue("$host:$request_uri args=$args", &.{});
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var sink = ArrayListSink{ .list = &out, .allocator = testing.allocator };
    try renderComplex(&ctx, frags, &sink);
    try testing.expectEqualStrings("example.com:/hello?x=1 args=?x=1", out.items);
}

test "renderComplex renders http_/arg_/cookie_ lookups" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.query_string = "?q=zig&lang=zt";
    req.addHeaderParsed("user-agent", "curl/8") catch unreachable;
    req.addHeaderParsed("cookie", "session=abc123; theme=dark") catch unreachable;

    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const frags = parseComplexValue("ua=$http_user_agent q=$arg_q c=$cookie_session", &.{});
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var sink = ArrayListSink{ .list = &out, .allocator = testing.allocator };
    try renderComplex(&ctx, frags, &sink);
    try testing.expectEqualStrings("ua=curl/8 q=zig c=abc123", out.items);
}

test "renderComplex renders captures and request_time" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.capture_subject = "/api/42/x";
    ctx.captures = .{ .{ .start = 0, .end = 9 }, .{ .start = 5, .end = 7 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } };
    ctx.capture_count = 2;

    const frags = parseComplexValue("id=$1 none=$9", &.{});
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var sink = ArrayListSink{ .list = &out, .allocator = testing.allocator };
    try renderComplex(&ctx, frags, &sink);
    try testing.expectEqualStrings("id=42 none=", out.items);
}

test "logDate formats in combined style" {
    var buf: [64]u8 = undefined;
    const formatted = logDate(1786557600, &buf);
    try testing.expect(formatted.len > 20);
    try testing.expect(formatted[2] == '/');
}

test "renderComplexArena renders a full dynamic body" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/who?q=zig";
    req.decoded_target = "/who";
    req.query_string = "?q=zig";
    req.addHeaderParsed("host", "example.com") catch unreachable;

    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const frags = parseComplexValue("host=$host path=$request_uri arg=$arg_q", &.{});
    const rendered = renderComplexArena(&ctx, frags, &req.arena).?;
    try testing.expectEqualStrings("host=example.com path=/who?q=zig arg=zig", rendered);
}

test "renderComplexArena with http_ and full request state" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/who?q=zig";
    req.decoded_target = "/who";
    req.query_string = "?q=zig";
    req.addHeaderParsed("host", "example.com") catch unreachable;
    req.addHeaderParsed("user-agent", "curl/8") catch unreachable;

    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };

    const frags = parseComplexValue("host=$host path=$request_uri ua=$http_user_agent arg=$arg_q", &.{});
    const rendered = renderComplexArena(&ctx, frags, &req.arena).?;
    try testing.expectEqualStrings("host=example.com path=/who?q=zig ua=curl/8 arg=zig", rendered);
}

test "parseComplexValue resolves request and status builtins" {
    const frags = parseComplexValue("$request $status", &.{});
    try testing.expectEqual(@as(usize, 3), frags.len);
    try testing.expectEqual(VarId.request, frags[0].builtin);
    try testing.expectEqualStrings(" ", frags[1].literal);
    try testing.expectEqual(VarId.status, frags[2].builtin);
}

test "getBuiltin request renders method and target" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/who?q=1";
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    var scratch = GetterScratch{};
    const s = getBuiltin(&ctx, .request, &scratch);
    try testing.expectEqualStrings("GET /who?q=1 HTTP/1.1", s);
}
