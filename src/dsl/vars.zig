const std = @import("std");

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
/// value is a compiled complex-value fragment list (M-B); until then it is
/// the raw format string.
pub const LogFormat = struct {
    name: []const u8,
    value: []const u8,
};

/// A proxy_set_header override (M-E).
pub const ProxyHeader = struct { name: []const u8, value: []const Frag };

/// A dynamic response template header (M-B).
pub const CVHeader = struct { name: []const u8, value: []const Frag };

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

const testing = std.testing;

test "frag types are plain data (compile-time tables freeze into .rodata)" {
    const frags = [_]Frag{
        .{ .literal = "hello" },
        .{ .builtin = .host },
        .{ .http_header = 0x1234 },
    };
    try testing.expectEqual(@as(usize, 3), frags.len);
}
