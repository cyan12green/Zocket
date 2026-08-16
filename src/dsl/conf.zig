const std = @import("std");
const config_mod = @import("../runtime/config.zig");
const dsl_limits = @import("limits.zig");
const router = @import("router.zig");
const phase_mod = @import("phase.zig");
const ct_pool = @import("../ct_pool.zig");
const vars = @import("vars.zig");
const regex_mod = @import("regex.zig");

const Config = config_mod.Config;
const TlsConfig = config_mod.TlsConfig;
const LogFormat = config_mod.LogFormat;
const Route = router.Route;
const Match = router.Match;
const ModuleBinding = router.ModuleBinding;
const TemplateHeader = router.TemplateHeader;
const ResponseTemplate = router.ResponseTemplate;
const ResponseTemplateCV = router.ResponseTemplateCV;
const CVHeader = router.CVHeader;
const SetVar = router.SetVar;
const Regex = router.Regex;
const Upstream = router.Upstream;
const Balance = router.Balance;
const Phase = phase_mod.Phase;
const Limits = dsl_limits.Limits;

/// True when a compiled complex value contains any non-literal fragment
/// (a variable/capture/user slot): such values need the dynamic renderer.
fn hasVariables(frags: []const vars.Frag) bool {
    for (frags) |f| {
        switch (f) {
            .literal => {},
            else => return true,
        }
    }
    return false;
}

// Parser pool capacities (compile-time only — the built route table is
// frozen by actual count, so unused capacity costs nothing at runtime).
const route_cap = 1024;
const module_cap = 4096;
const header_cap = 1024;
const upstream_cap = 4096;
const string_cap = 65536;

/// FNV-1a hash for directive/key dispatch (same rationale as json_config:
/// comptime `eql` chains cost a backward branch per byte; one hash pass plus
/// a comptime switch is O(1) per candidate).
fn keyHash(key: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (key) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

const H_recv_buffer_size = keyHash("recv_buffer_size");
const H_send_buffer_size = keyHash("send_buffer_size");
const H_max_body = keyHash("max_body");
const H_max_line_bytes = keyHash("max_line_bytes");
const H_max_headers = keyHash("max_headers");
const H_max_chunked_body = keyHash("max_chunked_body");
const H_static_cache_entries = keyHash("static_cache_entries");
const H_static_cache_valid = keyHash("static_cache_valid");
const H_static_content_cache_max = keyHash("static_content_cache_max");
const H_connection_pool_max = keyHash("connection_pool_max");
const H_listen = keyHash("listen");
const H_tls = keyHash("tls");
const H_cert = keyHash("cert");
const H_key = keyHash("key");
const H_log_format = keyHash("log_format");
const H_server = keyHash("server");
const H_location = keyHash("location");
const H_root = keyHash("root");
const H_index = keyHash("index");
const H_autoindex = keyHash("autoindex");
const H_embed = keyHash("embed");
const H_max_age = keyHash("max_age");
const H_chunked = keyHash("chunked");
const H_return = keyHash("return");
const H_add_header = keyHash("add_header");
const H_set = keyHash("set");
const H_proxy_pass = keyHash("proxy_pass");
const H_upstream = keyHash("upstream");
const H_balance = keyHash("balance");
const H_max_fails = keyHash("max_fails");
const H_fail_timeout = keyHash("fail_timeout");
const H_proxy_set_header = keyHash("proxy_set_header");
const H_access_log = keyHash("access_log");
const H_off = keyHash("off");
const H_on = keyHash("on");
const H_post_read = keyHash("post_read");
const H_server_rewrite = keyHash("server_rewrite");
const H_find_config = keyHash("find_config");
const H_rewrite = keyHash("rewrite");
const H_post_rewrite = keyHash("post_rewrite");
const H_preaccess = keyHash("preaccess");
const H_access = keyHash("access");
const H_post_access = keyHash("post_access");
const H_content = keyHash("content");
const H_log = keyHash("log");
const H_round_robin = keyHash("round_robin");
const H_least_connections = keyHash("least_connections");
const H_ip_hash = keyHash("ip_hash");

/// A value argument as parsed: either a zero-copy slice into the conf source
/// (unquoted tokens, quoted strings without escapes) or a reference into the
/// comptime decode pool (quoted strings with escapes).
const Str = union(enum) {
    src: []const u8,
    pool: PoolStr,

    /// Keys and enum-like values must be plain source slices: pooled strings
    /// are only allowed as data values.
    fn srcOf(str: Str, comptime msg: []const u8) []const u8 {
        return switch (str) {
            .src => |s| s,
            .pool => @compileError(msg),
        };
    }
};

const PoolStr = struct { start: usize, len: usize };

/// A location as parsed (strings unresolved until the pools are frozen).
const LocationSpec = struct {
    path: Str = .{ .src = "" },
    match: Match = .prefix,
    no_regex: bool = false,
    /// Comptime-compiled NFA for .regex / .regex_ci locations (M-D).
    pattern_regex: ?Regex = null,
    modules_start: usize = 0,
    modules_len: usize = 0,
    max_age: u32 = 0,
    root: ?Str = null,
    index: ?Str = null,
    autoindex: bool = false,
    embed: ?Str = null,
    response: ?ResponseSpec = null,
    upstreams_start: usize = 0,
    upstreams_len: usize = 0,
    balance: Balance = .round_robin,
    max_fails: u32 = 3,
    fail_timeout_seconds: u32 = 30,
    chunked: bool = false,
    /// `access_log <name>|off` → the log_format name (null = off). The
    /// index into Config.log_formats is resolved in `build`.
    log_format: ?Str = null,
    /// `return` status code (0 = none).
    return_status: u16 = 0,
    return_body: ?Str = null,
    return_headers_start: usize = 0,
    return_headers_len: usize = 0,
    /// `set $name "<cv>";` declarations: range into the builder's set pool
    /// (M-C). Slots are assigned in declaration order (0..max_user_vars-1).
    set_start: usize = 0,
    set_len: usize = 0,
};

/// A `set` declaration as parsed (value unresolved until build).
const SetSpec = struct {
    name: Str = .{ .src = "" },
    value: Str = .{ .src = "" },
};

/// A response-template section as parsed.
const ResponseSpec = struct {
    status: u16 = 200,
    headers_start: usize = 0,
    headers_len: usize = 0,
    body: ?Str = null,
};

/// A named log format as parsed.
const LogFormatSpec = struct {
    name: Str = .{ .src = "" },
    value: Str = .{ .src = "" },
};

/// Comptime builder: append-only pools for every piece of the config.
const Builder = struct {
    routes: ct_pool.CtPool(LocationSpec, route_cap) = .{},
    modules: ct_pool.CtPool(ModuleBinding, module_cap) = .{},
    headers: ct_pool.CtPool(TemplateHeader, header_cap) = .{},
    upstreams: ct_pool.CtPool(Upstream, upstream_cap) = .{},
    strings: ct_pool.CtPool(u8, string_cap) = .{},
    log_formats: ct_pool.CtPool(LogFormatSpec, 16) = .{},
    set_vars: ct_pool.CtPool(SetSpec, 1024) = .{},
    limits: Limits = .{},
    tls_cert: Str = .{ .src = "" },
    tls_key: Str = .{ .src = "" },
    tls_seen: bool = false,
    listen_port: ?u16 = null,
    server_seen: bool = false,
    /// Parse cost in §9 units (recomputed from the built Config at the end).
    cost: usize = 0,
};

fn resolve(str: Str, strings: []const u8) []const u8 {
    return switch (str) {
        .src => |s| s,
        .pool => |p| strings[p.start..][0..p.len],
    };
}

/// Line/column of a byte offset, for error messages (`conf:<line>:<col>: ...`).
fn lineCol(src: []const u8, pos: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    const end = @min(pos, src.len);
    while (i < end) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// The conf tokenizer: whitespace-separated tokens; `;` `{` `}` terminate
/// directives/blocks; `#` starts a comment to end of line (outside quotes).
/// Quoted strings may appear anywhere a token may; unquoted tokens never
/// contain whitespace. Errors carry line/col.
const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn fail(self: *Lexer, comptime msg: []const u8) noreturn {
        const lc = lineCol(self.src, self.pos);
        @compileError(std.fmt.comptimePrint("conf:{d}:{d}: {s}", .{ lc.line, lc.col, msg }));
    }

    fn failAt(self: *Lexer, pos: usize, comptime msg: []const u8) noreturn {
        const lc = lineCol(self.src, pos);
        @compileError(std.fmt.comptimePrint("conf:{d}:{d}: {s}", .{ lc.line, lc.col, msg }));
    }

    fn skipWs(self: *Lexer) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '#' => {
                    // Comment to end of line (outside quoted strings).
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                },
                else => return,
            }
        }
    }

    fn eof(self: *Lexer) bool {
        self.skipWs();
        return self.pos >= self.src.len;
    }

    fn peek(self: *Lexer) u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    /// A bare token: one or more of the token alphabet. Stops at
    /// whitespace, `;`, `{`, `}`, `'`, `"` (the terminators are left in
    /// place for the caller).
    fn token(self: *Lexer) ?Str {
        self.skipWs();
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r', ';', '{', '}', '\'', '"', '#' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == start) return null;
        return .{ .src = self.src[start..self.pos] };
    }

    /// A quoted string ('...' or "..."), with `"`-style escapes. The decoded
    /// bytes go into the string pool when escapes are present.
    fn quoted(self: *Lexer, b: *Builder) Str {
        self.skipWs();
        if (self.pos >= self.src.len) self.fail("expected a quoted string");
        const quote = self.src[self.pos];
        if (quote != '"' and quote != '\'') self.fail("expected a quoted string");
        self.pos += 1;
        const start = self.pos;
        var end = self.pos;
        var has_escape = false;
        while (end < self.src.len) {
            if (self.src[end] == '\\' and quote == '"') {
                has_escape = true;
                end += 2; // skip the escaped char
                continue;
            }
            if (self.src[end] == quote) break;
            end += 1;
        }
        if (end >= self.src.len) self.fail("unterminated string");
        const raw = self.src[start..end];
        self.pos = end + 1;
        if (!has_escape) return .{ .src = raw };

        const pool_start = b.strings.len;
        var i: usize = 0;
        while (i < raw.len) {
            const ch = raw[i];
            if (ch != '\\') {
                _ = b.strings.create(ch);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len) self.fail("dangling escape in string");
            switch (raw[i]) {
                '"' => _ = b.strings.create('"'),
                '\\' => _ = b.strings.create('\\'),
                'n' => _ = b.strings.create('\n'),
                'r' => _ = b.strings.create('\r'),
                't' => _ = b.strings.create('\t'),
                else => self.fail("bad escape in string"),
            }
            i += 1;
        }
        return .{ .pool = .{ .start = pool_start, .len = b.strings.len - pool_start } };
    }

    /// Parse a size with an optional k/m/g suffix (1024-multipliers).
    fn size(self: *Lexer, comptime dir: []const u8) usize {
        const t = self.token() orelse self.fail(dir ++ ": expected a size");
        const s = t.srcOf(dir ++ ": size cannot contain escapes");
        var mult: usize = 1;
        var digits = s;
        if (digits.len > 0) {
            switch (digits[digits.len - 1]) {
                'k', 'K' => {
                    mult = 1024;
                    digits = digits[0 .. digits.len - 1];
                },
                'm', 'M' => {
                    mult = 1024 * 1024;
                    digits = digits[0 .. digits.len - 1];
                },
                'g', 'G' => {
                    mult = 1024 * 1024 * 1024;
                    digits = digits[0 .. digits.len - 1];
                },
                else => {},
            }
        }
        const v = std.fmt.parseInt(usize, digits, 10) catch
            self.fail(dir ++ ": expected a number (optionally with a k/m/g suffix)");
        return v *% mult;
    }

    /// Parse a plain unsigned integer.
    fn number(self: *Lexer, comptime dir: []const u8, comptime T: type) T {
        const t = self.token() orelse self.fail(dir ++ ": expected a number");
        const s = t.srcOf(dir ++ ": number cannot contain escapes");
        return std.fmt.parseInt(T, s, 10) catch self.fail(dir ++ ": expected a number");
    }

    /// Parse `on|off`.
    fn boolOnOff(self: *Lexer, comptime dir: []const u8) bool {
        const t = self.token() orelse self.fail(dir ++ ": expected on|off");
        const s = t.srcOf(dir ++ ": value cannot contain escapes");
        return switch (keyHash(s)) {
            H_on => true,
            H_off => false,
            else => self.fail(dir ++ ": expected on|off"),
        };
    }

    /// A string value (quoted or bare token).
    fn value(self: *Lexer, b: *Builder, comptime dir: []const u8) Str {
        self.skipWs();
        if (self.pos < self.src.len and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
            return self.quoted(b);
        }
        return self.token() orelse self.fail(dir ++ ": expected a value");
    }

    fn expectTerminator(self: *Lexer, comptime dir: []const u8) void {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != ';') {
            self.fail(dir ++ ": expected ';'");
        }
        self.pos += 1;
    }

    fn expectOpen(self: *Lexer, comptime dir: []const u8) void {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            self.fail(dir ++ ": expected '{'");
        }
        self.pos += 1;
    }

    fn expectClose(self: *Lexer, comptime dir: []const u8) void {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != '}') {
            self.fail(dir ++ ": expected '}'");
        }
        self.pos += 1;
    }
};

/// Parse a directive at the top level or inside `server`. Returns true when
/// the directive was a block (which consumed its closing brace).
fn parseGlobalDirective(lx: *Lexer, b: *Builder, comptime name: []const u8) bool {
    switch (keyHash(name)) {
        H_recv_buffer_size => {
            b.limits.recv_buffer_size = lx.size(name);
            lx.expectTerminator(name);
        },
        H_send_buffer_size => {
            b.limits.send_buffer_size = lx.size(name);
            lx.expectTerminator(name);
        },
        H_max_body => {
            b.limits.max_body = lx.size(name);
            lx.expectTerminator(name);
        },
        H_max_line_bytes => {
            b.limits.max_line_bytes = lx.size(name);
            lx.expectTerminator(name);
        },
        H_max_headers => {
            b.limits.max_headers = lx.number(name, usize);
            lx.expectTerminator(name);
        },
        H_max_chunked_body => {
            b.limits.max_chunked_body = lx.size(name);
            lx.expectTerminator(name);
        },
        H_static_cache_entries => {
            b.limits.static_cache_entries = lx.number(name, usize);
            lx.expectTerminator(name);
        },
        H_static_cache_valid => {
            b.limits.static_cache_valid_seconds = lx.number(name, u64);
            lx.expectTerminator(name);
        },
        H_static_content_cache_max => {
            b.limits.static_content_cache_max = lx.size(name);
            lx.expectTerminator(name);
        },
        H_connection_pool_max => {
            b.limits.connection_pool_max = lx.number(name, usize);
            lx.expectTerminator(name);
        },
        H_listen => {
            b.listen_port = lx.number(name, u16);
            lx.expectTerminator(name);
        },
        H_tls => {
            if (b.tls_seen) lx.fail("duplicate tls block");
            b.tls_seen = true;
            lx.expectOpen(name);
            var seen_cert = false;
            var seen_key = false;
            while (true) {
                if (lx.peek() == '}') {
                    lx.pos += 1;
                    break;
                }
                const t = lx.token() orelse lx.fail("tls: expected a directive");
                const dn = t.srcOf("tls: directive cannot contain escapes");
                switch (keyHash(dn)) {
                    H_cert => {
                        if (seen_cert) lx.fail("duplicate tls cert");
                        seen_cert = true;
                        b.tls_cert = lx.value(b, "tls cert");
                        lx.expectTerminator("tls cert");
                    },
                    H_key => {
                        if (seen_key) lx.fail("duplicate tls key");
                        seen_key = true;
                        b.tls_key = lx.value(b, "tls key");
                        lx.expectTerminator("tls key");
                    },
                    else => lx.fail("unknown tls directive '" ++ dn ++ "'"),
                }
            }
            b.cost += 16;
        },
        H_log_format => {
            const fmt_name = lx.value(b, "log_format");
            const fmt_value = lx.value(b, "log_format");
            lx.expectTerminator("log_format");
            _ = b.log_formats.create(.{
                .name = fmt_name,
                .value = fmt_value,
            });
            b.cost += 8;
        },
        else => return false,
    }
    b.cost += 8;
    return true;
}

/// Parse the phase-directive bindings and route directives inside a location.
fn parseLocationDirective(lx: *Lexer, b: *Builder, spec: *LocationSpec, comptime name: []const u8) void {
    // Phase directives: `<phase> <module>;`.
    if (Phase.parse(name)) |phase| {
        if (spec.modules_len == 0) spec.modules_start = b.modules.len;
        const m = lx.value(b, name);
        const module_name = resolve(m, b.strings.items[0..]);
        _ = b.modules.create(.{ .phase = phase, .module = module_name });
        spec.modules_len += 1;
        lx.expectTerminator(name);
        b.cost += 8;
        return;
    }
    switch (keyHash(name)) {
        H_root => {
            spec.root = lx.value(b, name);
            lx.expectTerminator(name);
        },
        H_index => {
            spec.index = lx.value(b, name);
            lx.expectTerminator(name);
        },
        H_autoindex => {
            spec.autoindex = lx.boolOnOff(name);
            lx.expectTerminator(name);
        },
        H_embed => {
            spec.embed = lx.value(b, name);
            lx.expectTerminator(name);
        },
        H_max_age => {
            spec.max_age = lx.number(name, u32);
            lx.expectTerminator(name);
        },
        H_chunked => {
            spec.chunked = lx.boolOnOff(name);
            lx.expectTerminator(name);
        },
        H_return => {
            const code = lx.token() orelse lx.fail("return: expected a status code");
            const cs = code.srcOf("return: code cannot contain escapes");
            spec.return_status = std.fmt.parseInt(u16, cs, 10) catch lx.fail("return: expected a status code");
            if (lx.peek() == ';') {
                lx.pos += 1;
            } else {
                spec.return_body = lx.value(b, "return");
                lx.expectTerminator("return");
            }
            b.cost += 8;
        },
        H_add_header => {
            const hname = lx.value(b, "add_header");
            const hvalue = lx.value(b, "add_header");
            lx.expectTerminator("add_header");
            const n = resolve(hname, b.strings.items[0..]);
            const v = resolve(hvalue, b.strings.items[0..]);
            if (spec.return_headers_len == 0) spec.return_headers_start = b.headers.len;
            _ = b.headers.create(.{ .name = n, .value = v });
            spec.return_headers_len += 1;
            b.cost += 8;
        },
        H_set => {
            // `set $name "<cv>";` — the name must be a valid identifier
            // `[A-Za-z_][A-Za-z0-9_]*`; `$1..$9`/`$$` are reserved (M-C).
            const name_t = lx.token() orelse lx.fail("set: expected a variable name");
            const ns = name_t.srcOf("set: name cannot contain escapes");
            if (ns.len < 2 or ns[0] != '$') lx.fail("set: expected $name");
            const bare = ns[1..];
            if (bare.len == 0 or !(std.ascii.isAlphabetic(bare[0]) or bare[0] == '_')) {
                lx.fail("set: name must start with a letter or underscore");
            }
            for (bare) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
                    lx.fail("set: name must be [A-Za-z0-9_]*");
                }
            }
            if (std.mem.eql(u8, bare, "$$") or (bare.len == 1 and bare[0] >= '1' and bare[0] <= '9')) {
                lx.fail("set: '$$' and '$1..$9' are reserved");
            }
            // Duplicate name in the same location → compile error.
            for (b.set_vars.items[spec.set_start..][0..spec.set_len]) |existing| {
                if (std.mem.eql(u8, resolve(existing.name, b.strings.items[0..]), bare)) {
                    lx.fail("set: duplicate variable '$" ++ bare ++ "' in this location");
                }
            }
            if (spec.set_len >= vars.max_user_vars) {
                lx.fail("set: too many user variables in one location (max " ++
                    std.fmt.comptimePrint("{d}", .{vars.max_user_vars}) ++ ")");
            }
            if (spec.set_len == 0) spec.set_start = b.set_vars.len;
            const value = lx.value(b, "set");
            lx.expectTerminator("set");
            _ = b.set_vars.create(.{ .name = .{ .src = bare }, .value = value });
            spec.set_len += 1;
            b.cost += 8;
        },
        H_proxy_pass => {
            const t = lx.value(b, "proxy_pass");
            const s = resolve(t, b.strings.items[0..]);
            lx.expectTerminator("proxy_pass");
            const colon = std.mem.indexOfScalar(u8, s, ':') orelse
                lx.fail("proxy_pass: expected host:port");
            const host = s[0..colon];
            const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch
                lx.fail("proxy_pass: expected host:port");
            if (spec.upstreams_len == 0) spec.upstreams_start = b.upstreams.len;
            _ = b.upstreams.create(.{
                .host = host,
                .port = port,
                .sockaddr = Upstream.makeSockaddr(host, port) orelse
                    lx.fail("proxy_pass: host '" ++ host ++ "' is not a valid IPv4 literal"),
            });
            spec.upstreams_len += 1;
            b.cost += 8;
        },
        H_upstream => {
            const t = lx.value(b, "upstream");
            const s = resolve(t, b.strings.items[0..]);
            lx.expectTerminator("upstream");
            const colon = std.mem.indexOfScalar(u8, s, ':') orelse
                lx.fail("upstream: expected host:port");
            const host = s[0..colon];
            const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch
                lx.fail("upstream: expected host:port");
            if (spec.upstreams_len == 0) spec.upstreams_start = b.upstreams.len;
            _ = b.upstreams.create(.{
                .host = host,
                .port = port,
                .sockaddr = Upstream.makeSockaddr(host, port) orelse
                    lx.fail("upstream: host '" ++ host ++ "' is not a valid IPv4 literal"),
            });
            spec.upstreams_len += 1;
            b.cost += 8;
        },
        H_balance => {
            const t = lx.token() orelse lx.fail("balance: expected a strategy");
            const s = t.srcOf("balance: value cannot contain escapes");
            spec.balance = switch (keyHash(s)) {
                H_round_robin => .round_robin,
                H_least_connections => .least_connections,
                H_ip_hash => .ip_hash,
                else => lx.fail("balance: expected round_robin|least_connections|ip_hash"),
            };
            lx.expectTerminator("balance");
            b.cost += 8;
        },
        H_max_fails => {
            spec.max_fails = lx.number("max_fails", u32);
            lx.expectTerminator("max_fails");
        },
        H_fail_timeout => {
            spec.fail_timeout_seconds = lx.number("fail_timeout", u32);
            lx.expectTerminator("fail_timeout");
        },
        H_proxy_set_header => {
            lx.fail("proxy_set_header lands in M-E (this plan milestone is not implemented yet)");
        },
        H_access_log => {
            const t = lx.token() orelse lx.fail("access_log: expected a format name or off");
            const s = t.srcOf("access_log: value cannot contain escapes");
            spec.log_format = if (keyHash(s) == H_off) null else t;
            lx.expectTerminator("access_log");
            b.cost += 8;
        },
        else => lx.fail("unknown location directive '" ++ name ++ "'"),
    }
    b.cost += 8;
}

/// Parse `location [modifier] <target> { ... }`.
fn parseLocation(lx: *Lexer, b: *Builder) void {
    var spec = LocationSpec{};

    // Modifier + target: two leading tokens before the '{'.
    const first = lx.token() orelse lx.fail("location: expected a target");
    const f = first.srcOf("location: target cannot contain escapes");
    if (std.mem.eql(u8, f, "=")) {
        spec.match = .exact;
        const second = lx.token() orelse lx.fail("location: expected a target after '='");
        spec.path = second;
    } else if (std.mem.eql(u8, f, "~")) {
        spec.match = .regex;
        const second = lx.token() orelse lx.fail("location: expected a target after '~'");
        spec.path = second;
    } else if (std.mem.eql(u8, f, "~*")) {
        spec.match = .regex_ci;
        const second = lx.token() orelse lx.fail("location: expected a target after '~*'");
        spec.path = second;
    } else if (std.mem.eql(u8, f, "^~")) {
        spec.match = .prefix;
        spec.no_regex = true;
        const second = lx.token() orelse lx.fail("location: expected a target after '^~'");
        spec.path = second;
    } else {
        spec.path = first;
    }

    // M-D: compile the regex pattern into a Thompson NFA at comptime.
    if (spec.match == .regex or spec.match == .regex_ci) {
        const pat = resolve(spec.path, b.strings.items[0..]);
        spec.pattern_regex = regex_mod.compileRegex(pat);
    }

    lx.expectOpen("location");
    while (true) {
        if (lx.peek() == '}') {
            lx.pos += 1;
            break;
        }
        const t = lx.token() orelse lx.fail("location: expected a directive");
        const dn = t.srcOf("location: directive cannot contain escapes");
        parseLocationDirective(lx, b, &spec, dn);
    }
    _ = b.routes.create(spec);
    b.cost += 16 + 32;
}

fn parseServer(lx: *Lexer, b: *Builder) void {
    if (b.server_seen) lx.fail("multiple server blocks are not supported yet (vhosts are a future milestone)");
    b.server_seen = true;
    lx.expectOpen("server");
    while (true) {
        if (lx.peek() == '}') {
            lx.pos += 1;
            break;
        }
        const t = lx.token() orelse lx.fail("server: expected a directive");
        const dn = t.srcOf("server: directive cannot contain escapes");
        if (std.mem.eql(u8, dn, "location")) {
            parseLocation(lx, b);
            continue;
        }
        if (parseGlobalDirective(lx, b, dn)) continue;
        lx.fail("unknown server directive '" ++ dn ++ "'");
    }
    b.cost += 16;
}

fn parseTop(lx: *Lexer, b: *Builder) void {
    while (true) {
        if (lx.eof()) break;
        const t = lx.token() orelse break;
        const dn = t.srcOf("directive cannot contain escapes");
        if (std.mem.eql(u8, dn, "server")) {
            parseServer(lx, b);
            continue;
        }
        if (parseGlobalDirective(lx, b, dn)) continue;
        lx.fail("unknown directive '" ++ dn ++ "'");
    }
}

/// Resolve an `access_log <name>` directive to its log_format index.
fn logFormatIndex(name: ?Str, table: []const LogFormat, str_pool: []const u8) ?usize {
    if (name == null) return null;
    const n = resolve(name.?, str_pool);
    inline for (table, 0..) |lf, i| {
        if (std.mem.eql(u8, lf.name, n)) return i;
    }
    @compileError("access_log: unknown log format '" ++ n ++ "'");
}

/// Build the final `Config` from the parsed pools, freezing them into
/// comptime constants (`.rodata`).
fn build(b: *const Builder) Config {
    const route_specs = b.routes.freeze();
    const mods = b.modules.freeze();
    const strings = b.strings.freeze();
    const headers = b.headers.freeze();
    const upstreams = b.upstreams.freeze();
    const log_specs = b.log_formats.freeze();
    const set_specs = b.set_vars.freeze();

    const Range = struct { start: usize, len: usize };

    const ModTable = struct { items: [module_cap]ModuleBinding, ranges: [route_cap]Range };
    const mod_table: ModTable = comptime blk: {
        var items: [module_cap]ModuleBinding = undefined;
        var ranges: [route_cap]Range = undefined;
        var pos: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            ranges[ri] = .{ .start = pos, .len = spec.modules_len };
            for (mods[spec.modules_start..][0..spec.modules_len]) |m| {
                items[pos] = m;
                pos += 1;
            }
        }
        break :blk .{ .items = items, .ranges = ranges };
    };

    const HeadTable = struct { items: [header_cap]TemplateHeader, ranges: [route_cap]Range };
    const head_table: HeadTable = comptime blk: {
        var items: [header_cap]TemplateHeader = undefined;
        var ranges: [route_cap]Range = undefined;
        var pos: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            ranges[ri] = .{ .start = pos, .len = spec.return_headers_len };
            for (headers[spec.return_headers_start..][0..spec.return_headers_len]) |h| {
                items[pos] = h;
                pos += 1;
            }
        }
        break :blk .{ .items = items, .ranges = ranges };
    };

    const UpTable = struct { items: [upstream_cap]Upstream, ranges: [route_cap]Range };
    const up_table: UpTable = comptime blk: {
        var items: [upstream_cap]Upstream = undefined;
        var ranges: [route_cap]Range = undefined;
        var pos: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            ranges[ri] = .{ .start = pos, .len = spec.upstreams_len };
            for (upstreams[spec.upstreams_start..][0..spec.upstreams_len]) |u| {
                items[pos] = u;
                pos += 1;
            }
        }
        break :blk .{ .items = items, .ranges = ranges };
    };

    const LogTable = struct { items: [16]LogFormat, len: usize };
    const log_table: LogTable = comptime blk: {
        var items: [16]LogFormat = undefined;
        var len: usize = 0;
        for (log_specs) |ls| {
            items[len] = .{
                .name = resolve(ls.name, strings),
                .value = vars.parseComplexValue(resolve(ls.value, strings), &.{}),
            };
            len += 1;
        }
        break :blk .{ .items = items, .len = len };
    };

    // Resolve an `access_log <name>` directive to its log_format index.
    const SetTable = struct { items: [1024]SetVar, ranges: [route_cap]Range };
    const set_table: SetTable = comptime blk: {
        var items: [1024]SetVar = undefined;
        var ranges: [route_cap]Range = undefined;
        var pos: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            ranges[ri] = .{ .start = pos, .len = spec.set_len };
            // Resolve set values in declaration order with a growing scope:
            // a set may reference sets declared before it (forward references
            // are compile errors, plan §5.3).
            const scope_start = pos;
            for (set_specs[spec.set_start..][0..spec.set_len], 0..) |ss, si| {
                const name = resolve(ss.name, strings);
                const value_text = resolve(ss.value, strings);
                const scope = items[scope_start .. scope_start + si];
                items[pos] = .{
                    .name = name,
                    .slot = @intCast(si),
                    .value = vars.parseComplexValue(value_text, scope),
                };
                pos += 1;
            }
        }
        break :blk .{ .items = items, .ranges = ranges };
    };

    const Routes = struct { items: [route_cap]Route, len: usize };
    const routes_built: Routes = comptime blk: {
        var items: [route_cap]Route = undefined;
        var len: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            const mr = mod_table.ranges[ri];
            const sr = set_table.ranges[ri];
            const route_sets = set_table.items[sr.start..][0..sr.len];
            var resp: ?ResponseTemplate = null;
            var resp_cv: ?ResponseTemplateCV = null;
            if (spec.return_status != 0) {
                const hr = head_table.ranges[ri];
                const body_text = if (spec.return_body) |bd| resolve(bd, strings) else "";
                // M-B: variable-capable? Parse the body and every header value
                // as complex values; if any fragment is non-literal the route
                // uses the dynamic template (response_cv), else the literal
                // fast path (response + pre-serialised bytes) is kept.
                const body_frags = vars.parseComplexValue(body_text, route_sets);
                var dynamic = hasVariables(body_frags);
                const hcount = hr.len;
                const CVArray = struct { items: [header_cap]CVHeader };
                const cv_arr: CVArray = cv_blk: {
                    var a: [header_cap]CVHeader = undefined;
                    var n: usize = 0;
                    for (head_table.items[hr.start..][0..hcount]) |h| {
                        const hf = vars.parseComplexValue(h.value, route_sets);
                        if (hasVariables(hf)) dynamic = true;
                        a[n] = .{ .name = h.name, .value = hf };
                        n += 1;
                    }
                    break :cv_blk .{ .items = a };
                };
                const LitArray = struct { items: [header_cap]TemplateHeader };
                const lit_arr: LitArray = lit_blk: {
                    var a: [header_cap]TemplateHeader = undefined;
                    var n: usize = 0;
                    for (head_table.items[hr.start..][0..hcount]) |h| {
                        a[n] = h;
                        n += 1;
                    }
                    break :lit_blk .{ .items = a };
                };
                if (dynamic) {
                    resp_cv = .{
                        .status = spec.return_status,
                        .headers = cv_arr.items[0..hcount],
                        .body = body_frags,
                    };
                } else {
                    resp = .{
                        .status = spec.return_status,
                        .headers = lit_arr.items[0..hcount],
                        .body = body_text,
                    };
                }
            }
            const ur = up_table.ranges[ri];
            items[len] = .{
                .path = resolve(spec.path, strings),
                .match = spec.match,
                .no_regex = spec.no_regex,
                .pattern_regex = spec.pattern_regex,
                .modules = mod_table.items[mr.start..][0..mr.len],
                .max_age_seconds = spec.max_age,
                .root = if (spec.root) |r| resolve(r, strings) else null,
                .index = if (spec.index) |i| resolve(i, strings) else null,
                .autoindex = spec.autoindex,
                .embed = if (spec.embed) |e| resolve(e, strings) else null,
                .response = resp,
                .response_cv = resp_cv,
                .set_vars = route_sets,
                .upstreams = up_table.items[ur.start..][0..ur.len],
                .balance = spec.balance,
                .max_fails = spec.max_fails,
                .fail_timeout_seconds = spec.fail_timeout_seconds,
                .chunked = spec.chunked,
                .log_format = logFormatIndex(spec.log_format, log_table.items[0..log_table.len], strings),
            };
            len += 1;
        }
        break :blk .{ .items = items, .len = len };
    };

    const routes: []const Route = routes_built.items[0..routes_built.len];
    return .{
        .routes = routes,
        .limits = b.limits,
        .tls = .{
            .cert = resolve(b.tls_cert, strings),
            .key = resolve(b.tls_key, strings),
        },
        .listen_port = b.listen_port,
        .log_formats = log_table.items[0..log_table.len],
    };
}

const config_options = @import("config_options");

// §9 cost accounting units: conf byte scanned 1, directive parsed 8,
// block opened 16, complex-value fragment 4, regex pattern byte 3,
// regex NFA state 2, route built 32. The budget check recomputes the cost
// from the built Config (route count × 32 + fragment count × 4 + source
// length), so the parser itself does not need to thread a counter.
fn configCost(comptime text: []const u8, comptime cfg: Config) usize {
    var cost: usize = text.len;
    cost += cfg.routes.len * 32;
    for (cfg.routes) |r| {
        cost += r.modules.len * 8;
        cost += r.upstreams.len * 8;
        if (r.response) |t| {
            cost += t.headers.len * 8;
            if (t.body.len > 0) cost += 4;
        }
    }
    return cost;
}

/// The §9 budget check: fail with a clear, actionable compile error when a
/// config's measured cost would exhaust the shared comptime branch quota.
pub fn checkBudget(comptime text: []const u8, comptime cfg: Config) void {
    const quota = config_options.branch_quota;
    const cost = configCost(text, cfg);
    // Safety factor ≈ 1/1.5: fail when cost > ~66% of quota, leaving
    // headroom for the trie build, dispatch assignment, the h2/tls comptime
    // tables and other parses sharing the same quota.
    if (cost * 3 > quota * 2) {
        @compileError(
            "conf '<embedded>': config compile cost ~" ++ std.fmt.comptimePrint("{d}", .{cost}) ++
                " exceeds the comptime branch budget (" ++ std.fmt.comptimePrint("{d}", .{quota}) ++
                ", safety factor 1.5). Reduce the config (routes/regex/length) or raise the budget: " ++
                "zig build -Dconfig_branch_quota=<n>",
        );
    }
}

/// Parse a conf document at compile time. Invalid input, unknown directives,
/// duplicate blocks and bad values are compile errors carrying line:col.
pub fn parse(comptime text: []const u8) Config {
    // The comptime branch quota is shared per compilation. `checkBudget`
    // fails with a clear error before the raw quota is exhausted; the
    // parser itself gets headroom above the config budget so it can always
    // finish building the config the check measures (calibrated: measured
    // cost is ~1/4 of actual branches for typical confs, see §9).
    @setEvalBranchQuota(config_options.branch_quota * 4);
    return comptime blk: {
        var b = Builder{};
        var lx = Lexer{ .src = text };
        parseTop(&lx, &b);
        if (!b.server_seen) {
            const lc = lineCol(text, text.len);
            @compileError(std.fmt.comptimePrint("conf:{d}:{d}: missing server block", .{ lc.line, lc.col }));
        }
        const cfg = build(&b);
        checkBudget(text, cfg);
        break :blk cfg;
    };
}

const testing = std.testing;

test "conf: parses globals, tls, server and locations" {
    const cfg = parse(
        \\max_body 16m;
        \\max_headers 64;
        \\listen 8080;
        \\tls {
        \\    cert "server.pem";
        \\    key "server.key";
        \\}
        \\server {
        \\    location /health {
        \\        return 200 "ok";
        \\    }
        \\    location / {
        \\        content echo;
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), cfg.limits.max_body);
    try testing.expectEqual(@as(usize, 64), cfg.limits.max_headers);
    try testing.expectEqual(@as(?u16, 8080), cfg.listen_port);
    try testing.expect(cfg.tls.enabled());
    try testing.expectEqualStrings("server.pem", cfg.tls.cert);
    try testing.expectEqualStrings("server.key", cfg.tls.key);
    try testing.expectEqual(@as(usize, 2), cfg.routes.len);
    try testing.expectEqualStrings("/health", cfg.routes[0].path);
    try testing.expectEqual(@as(u16, 200), cfg.routes[0].response.?.status);
    try testing.expectEqualStrings("ok", cfg.routes[0].response.?.body);
    try testing.expectEqualStrings("/", cfg.routes[1].path);
    try testing.expectEqualStrings("echo", cfg.routes[1].moduleFor(.content).?);
}

test "conf: size suffixes and on|off" {
    const cfg = parse(
        \\recv_buffer_size 32k;
        \\send_buffer_size 1m;
        \\static_cache_valid 5;
        \\server {
        \\    location / {
        \\        autoindex on;
        \\        chunked off;
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 32 * 1024), cfg.limits.recv_buffer_size);
    try testing.expectEqual(@as(usize, 1024 * 1024), cfg.limits.send_buffer_size);
    try testing.expectEqual(@as(u64, 5), cfg.limits.static_cache_valid_seconds);
    try testing.expect(cfg.routes[0].autoindex);
    try testing.expect(!cfg.routes[0].chunked);
}

test "conf: phase directives bind modules" {
    const cfg = parse(
        \\server {
        \\    location /gzip {
        \\        content echo;
        \\        preaccess conditional_get;
        \\        post_access cache_headers;
        \\        log gzip;
        \\    }
        \\}
    );
    const r = cfg.routes[0];
    try testing.expectEqualStrings("echo", r.moduleFor(.content).?);
    try testing.expectEqualStrings("conditional_get", r.moduleFor(.preaccess).?);
    try testing.expectEqualStrings("cache_headers", r.moduleFor(.post_access).?);
    try testing.expectEqualStrings("gzip", r.moduleFor(.log).?);
    try testing.expectEqual(@as(usize, 4), r.modules.len);
}

test "conf: quoted strings with escapes" {
    const cfg = parse(
        \\server {
        \\    location / {
        \\        return 301 "a\"b\n";
        \\    }
        \\}
    );
    const body = cfg.routes[0].response.?.body;
    try testing.expectEqual(@as(usize, 4), body.len);
    try testing.expectEqual('a', body[0]);
    try testing.expectEqual('"', body[1]);
    try testing.expectEqual('b', body[2]);
    try testing.expectEqual('\n', body[3]);
}

test "conf: comments are ignored" {
    const cfg = parse(
        \\# top-level comment
        \\max_headers 8; # trailing comment
        \\server {
        \\    # inside server
        \\    location / { # inside location
        \\        content echo; # trailing
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 8), cfg.limits.max_headers);
    try testing.expectEqual(@as(usize, 1), cfg.routes.len);
}

test "conf: log_format and access_log directive" {
    const cfg = parse(
        \\log_format combined "$ip - - [$date] \"$request\" $status";
        \\log_format short "$request $status";
        \\server {
        \\    location / {
        \\        content echo;
        \\        access_log short;
        \\    }
        \\    location /plain {
        \\        content echo;
        \\        access_log off;
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 2), cfg.log_formats.len);
    try testing.expectEqualStrings("combined", cfg.log_formats[0].name);
    try testing.expectEqualStrings("short", cfg.log_formats[1].name);
    try testing.expectEqual(@as(?usize, 1), cfg.routes[0].log_format);
    try testing.expectEqual(@as(?usize, null), cfg.routes[1].log_format);
}

test "conf: proxy_pass and upstream build the upstream list" {
    const cfg = parse(
        \\server {
        \\    location /proxy {
        \\        content proxy;
        \\        proxy_pass 127.0.0.1:9000;
        \\    }
        \\    location /multi {
        \\        content proxy;
        \\        upstream 10.0.0.1:8000;
        \\        upstream 10.0.0.2:8001;
        \\        balance least_connections;
        \\        max_fails 5;
        \\        fail_timeout 15;
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 1), cfg.routes[0].upstreams.len);
    try testing.expectEqualStrings("127.0.0.1", cfg.routes[0].upstreams[0].host);
    try testing.expectEqual(@as(u16, 9000), cfg.routes[0].upstreams[0].port);
    try testing.expectEqual(@as(usize, 2), cfg.routes[1].upstreams.len);
    try testing.expectEqual(Balance.least_connections, cfg.routes[1].balance);
    try testing.expectEqual(@as(u32, 5), cfg.routes[1].max_fails);
    try testing.expectEqual(@as(u32, 15), cfg.routes[1].fail_timeout_seconds);
}

test "conf: root/index/embed/max_age" {
    const cfg = parse(
        \\server {
        \\    location ^~ /static/ {
        \\        content static;
        \\        root testdata;
        \\        index index.html;
        \\        max_age 3600;
        \\    }
        \\}
    );
    const r = cfg.routes[0];
    try testing.expectEqualStrings("/static/", r.path);
    try testing.expectEqualStrings("testdata", r.root.?);
    try testing.expectEqualStrings("index.html", r.index.?);
    try testing.expectEqual(@as(u32, 3600), r.max_age_seconds);
}

test "conf: exact and regex location modifiers parse" {
    const cfg = parse(
        \\server {
        \\    location = /health {
        \\        return 200 "ok";
        \\    }
        \\    location ~ ^/api/([0-9]+)/ {
        \\        content echo;
        \\    }
        \\    location ~* \\.png$ {
        \\        content echo;
        \\    }
        \\}
    );
    try testing.expectEqual(Match.exact, cfg.routes[0].match);
    try testing.expectEqualStrings("/health", cfg.routes[0].path);
    try testing.expectEqual(Match.regex, cfg.routes[1].match);
    try testing.expectEqualStrings("^/api/([0-9]+)/", cfg.routes[1].path);
    try testing.expect(cfg.routes[1].pattern_regex != null);
    try testing.expectEqual(Match.regex_ci, cfg.routes[2].match);
    try testing.expect(cfg.routes[2].pattern_regex != null);
}

test "conf: gzip route binds 4 distinct phases" {
    const cfg = parse(
        \\server {
        \\    location /gzip {
        \\        content echo;
        \\        preaccess conditional_get;
        \\        post_access cache_headers;
        \\        log gzip;
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 4), cfg.routes[0].modules.len);
}

test "conf: variable return body produces response_cv" {
    const cfg = parse(
        \\server {
        \\    location = /who {
        \\        return 200 "host=$host";
        \\    }
        \\}
    );
    try testing.expect(cfg.routes[0].response == null);
    try testing.expect(cfg.routes[0].response_cv != null);
    try testing.expectEqual(@as(usize, 2), cfg.routes[0].response_cv.?.body.len);
    try testing.expectEqualStrings("host=", cfg.routes[0].response_cv.?.body[0].literal);
    try testing.expectEqual(vars.VarId.host, cfg.routes[0].response_cv.?.body[1].builtin);
}

test "conf: exact and prefix routes match via the trie" {
    const cfg = comptime parse(
        \\server {
        \\    location = /who { return 200 "host=$host"; }
        \\    location / { content echo; }
        \\}
    );
    const trie = router.buildTrie(cfg.routes);
    const rtr = router.Router{ .routes = cfg.routes, .trie = trie };
    const m = rtr.match("/who", null).?;
    try testing.expectEqualStrings("/who", m.path);
    try testing.expectEqual(Match.exact, m.match);
    try testing.expectEqualStrings("/", rtr.match("/anything", null).?.path);
}

test "conf: set variables resolve to user slots and render" {
    const cfg = parse(
        \\server {
        \\    location = /user {
        \\        set $greeting "hi-$host";
        \\        return 200 "g=$greeting";
        \\    }
        \\}
    );
    const r = cfg.routes[0];
    try testing.expectEqual(@as(usize, 1), r.set_vars.len);
    try testing.expectEqualStrings("greeting", r.set_vars[0].name);
    try testing.expectEqual(@as(u8, 0), r.set_vars[0].slot);
    // The set value references $host (builtin) → 2 fragments.
    try testing.expectEqual(@as(usize, 2), r.set_vars[0].value.len);
    // The return body references $greeting → a user fragment.
    try testing.expectEqual(@as(u8, 0), r.response_cv.?.body[1].user);
}
