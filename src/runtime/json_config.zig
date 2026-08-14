const std = @import("std");
const config_mod = @import("config.zig");
const dsl_limits = @import("../dsl/limits.zig");
const router = @import("../dsl/router.zig");
const phase_mod = @import("../dsl/phase.zig");
const ct_pool = @import("../ct_pool.zig");

const Config = config_mod.Config;
const Route = router.Route;
const Match = router.Match;
const ModuleBinding = router.ModuleBinding;
const TemplateHeader = router.TemplateHeader;
const ResponseTemplate = router.ResponseTemplate;
const Upstream = router.Upstream;
const Balance = router.Balance;
const Phase = phase_mod.Phase;
const Limits = dsl_limits.Limits;

// Parser pool capacities (compile-time only — the built route table is
// frozen by actual count, so unused capacity costs nothing at runtime).
// Generous for DM2 comptime configs; exhaustion is a compile error.
const route_cap = 1024;
const module_cap = 4096;
const header_cap = 1024;
const upstream_cap = 4096;
const string_cap = 65536;

/// A JSON string value: either a zero-copy slice into the config source (no
/// escapes) or a reference into the comptime decode pool.
const Str = union(enum) {
    src: []const u8,
    pool: PoolStr,

    /// Keys and enum-like values (phase names, match, balance) must be plain
    /// source slices: pooled strings are only allowed as data values.
    fn srcOf(str: Str, comptime msg: []const u8) []const u8 {
        return switch (str) {
            .src => |s| s,
            .pool => @compileError(msg),
        };
    }
};

const PoolStr = struct { start: usize, len: usize };

/// A response-template section as parsed (headers and body unresolved until
/// the pools are frozen).
const ResponseSpec = struct {
    status: u16 = 200,
    headers_start: usize = 0,
    headers_len: usize = 0,
    body: ?Str = null,
    compress: bool = false,
};

/// A route as parsed (strings unresolved).
const RouteSpec = struct {
    path: Str = .{ .src = "" },
    match: Match = .prefix,
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
};

/// Comptime builder: append-only pools for every piece of the route table.
const Builder = struct {
    routes: ct_pool.CtPool(RouteSpec, route_cap) = .{},
    modules: ct_pool.CtPool(ModuleBinding, module_cap) = .{},
    headers: ct_pool.CtPool(TemplateHeader, header_cap) = .{},
    upstreams: ct_pool.CtPool(Upstream, upstream_cap) = .{},
    strings: ct_pool.CtPool(u8, string_cap) = .{},
    limits: Limits = .{},
};

/// Resolve a Str into its final comptime slice: zero-copy for unescaped
/// strings (they point into the config source, itself a comptime constant),
/// otherwise the decoded bytes from the string pool.
fn resolve(str: Str, strings: []const u8) []const u8 {
    return switch (str) {
        .src => |s| s,
        .pool => |p| strings[p.start..][0..p.len],
    };
}

fn hex4(s: []const u8) ?u32 {
    var v: u32 = 0;
    for (s) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

/// FNV-1a hash. The parser keys on hashes instead of `std.mem.eql` chains:
/// every comptime `eql` comparison costs a backward branch per compared byte,
/// and long if/else-if key chains can eat a large slice of the comptime
/// budget (1000 backwards branches per compilation). One hash pass over the
/// key (its length in branches) plus a comptime `switch` on pre-hoisted
/// candidate hashes is O(1) per candidate.
fn keyHash(key: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (key) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

// Candidate hashes are hoisted into file-scope consts: a `keyHash("...")`
// call inside a switch prong is re-evaluated on every comptime invocation of
// the switch, which alone can blow the budget.
const H_limits = keyHash("limits");
const H_routes = keyHash("routes");
const H_recv_buffer_size = keyHash("recv_buffer_size");
const H_send_buffer_size = keyHash("send_buffer_size");
const H_max_body = keyHash("max_body");
const H_max_line_bytes = keyHash("max_line_bytes");
const H_max_headers = keyHash("max_headers");
const H_max_chunked_body = keyHash("max_chunked_body");
const H_static_cache_entries = keyHash("static_cache_entries");
const H_static_cache_valid_seconds = keyHash("static_cache_valid_seconds");
const H_static_content_cache_max = keyHash("static_content_cache_max");
const H_connection_pool_max = keyHash("connection_pool_max");
const H_path = keyHash("path");
const H_match = keyHash("match");
const H_modules = keyHash("modules");
const H_max_age = keyHash("max_age");
const H_root = keyHash("root");
const H_index = keyHash("index");
const H_autoindex = keyHash("autoindex");
const H_embed = keyHash("embed");
const H_response = keyHash("response");
const H_upstreams = keyHash("upstreams");
const H_balance = keyHash("balance");
const H_max_fails = keyHash("max_fails");
const H_fail_timeout_seconds = keyHash("fail_timeout_seconds");
const H_exact = keyHash("exact");
const H_prefix = keyHash("prefix");
const H_round_robin = keyHash("round_robin");
const H_least_connections = keyHash("least_connections");
const H_ip_hash = keyHash("ip_hash");
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
const H_status = keyHash("status");
const H_body = keyHash("body");
const H_headers = keyHash("headers");
const H_compress = keyHash("compress");
const H_name = keyHash("name");
const H_value = keyHash("value");
const H_host = keyHash("host");
const H_port = keyHash("port");

fn markSeen(seen: *[16]u64, n: *usize, h: u64, key: []const u8) void {
    for (seen[0..n.*]) |k| {
        if (k == h) @compileError("duplicate key '" ++ key ++ "' in config object");
    }
    seen[n.*] = h;
    n.* += 1;
}

const Cursor = struct {
    src: []const u8,
    pos: usize = 0,

    fn fail(self: *Cursor, comptime msg: []const u8) noreturn {
        @compileError(msg ++ " at byte " ++ std.fmt.comptimePrint("{d}", .{self.pos}));
    }

    fn skipWs(self: *Cursor) void {
        inline while (self.pos < self.src.len) switch (self.src[self.pos]) {
            ' ', '\t', '\n', '\r' => self.pos += 1,
            else => break,
        };
    }

    fn peek(self: *Cursor) u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn expect(self: *Cursor, c: u8) void {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != c) {
            self.fail(std.fmt.comptimePrint("expected '{c}'", .{c}));
        }
        self.pos += 1;
    }

    fn parseString(self: *Cursor, b: *Builder) Str {
        self.expect('"');
        const start = self.pos;
        var end = self.pos;
        var has_escape = false;
        inline while (end < self.src.len and self.src[end] != '"') {
            if (self.src[end] == '\\') has_escape = true;
            end += 1;
        }
        if (end >= self.src.len) self.fail("unterminated string");
        const raw = self.src[start..end];
        self.pos = end + 1;
        if (!has_escape) return .{ .src = raw };

        const pool_start = b.strings.len;
        var i: usize = 0;
        inline while (i < raw.len) {
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
                '/' => _ = b.strings.create('/'),
                'b' => _ = b.strings.create(0x08),
                'f' => _ = b.strings.create(0x0c),
                'n' => _ = b.strings.create('\n'),
                'r' => _ = b.strings.create('\r'),
                't' => _ = b.strings.create('\t'),
                'u' => {
                    if (i + 5 > raw.len) self.fail("bad \\u escape");
                    const cp = hex4(raw[i + 1 .. i + 5]) orelse self.fail("bad \\u escape");
                    if (cp < 0x80) {
                        _ = b.strings.create(@intCast(cp));
                    } else if (cp < 0x800) {
                        _ = b.strings.create(@intCast(0xC0 | (cp >> 6)));
                        _ = b.strings.create(@intCast(0x80 | (cp & 0x3F)));
                    } else {
                        _ = b.strings.create(@intCast(0xE0 | (cp >> 12)));
                        _ = b.strings.create(@intCast(0x80 | ((cp >> 6) & 0x3F)));
                        _ = b.strings.create(@intCast(0x80 | (cp & 0x3F)));
                    }
                    i += 5;
                },
                else => self.fail("bad escape in string"),
            }
            i += 1;
        }
        return .{ .pool = .{ .start = pool_start, .len = b.strings.len - pool_start } };
    }

    /// Parse an object key. Keys are plain source slices (never escapes);
    /// the FNV-1a hash is folded into the same scan that finds the closing
    /// quote, so keys are read once instead of once by the scan and again by
    /// `keyHash`.
    const Key = struct { key: []const u8, hash: u64 };

    fn parseKey(self: *Cursor) Key {
        self.expect('"');
        const start = self.pos;
        var end = self.pos;
        var h: u64 = 1469598103934665603;
        inline while (end < self.src.len and self.src[end] != '"') {
            if (self.src[end] == '\\') self.fail("object keys cannot contain escapes");
            h = (h ^ self.src[end]) *% 1099511628211;
            end += 1;
        }
        if (end >= self.src.len) self.fail("unterminated string");
        const key = self.src[start..end];
        self.pos = end + 1;
        return .{ .key = key, .hash = h };
    }

    fn parseUInt(self: *Cursor, comptime field: []const u8, comptime T: type) T {
        self.skipWs();
        var v: T = 0;
        var any = false;
        inline while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
            v = v *% 10 +% (self.src[self.pos] - '0');
            any = true;
            self.pos += 1;
        }
        if (!any) self.fail(field ++ ": expected a number");
        if (self.pos < self.src.len and (self.src[self.pos] == '.' or self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.fail(field ++ ": must be an integer");
        }
        return v;
    }

    fn parseBool(self: *Cursor, comptime field: []const u8) bool {
        self.skipWs();
        if (self.pos + 4 <= self.src.len and std.mem.eql(u8, self.src[self.pos..][0..4], "true")) {
            self.pos += 4;
            return true;
        }
        if (self.pos + 5 <= self.src.len and std.mem.eql(u8, self.src[self.pos..][0..5], "false")) {
            self.pos += 5;
            return false;
        }
        self.fail(field ++ ": expected true or false");
    }

    fn parseTop(self: *Cursor, b: *Builder) void {
        self.skipWs();
        if (self.pos >= self.src.len) self.fail("empty config");
        self.expect('{');
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_limits => parseLimits(self, b),
                H_routes => parseRoutes(self, b),
                else => self.fail("unknown top-level key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}'"),
            }
        }
        self.skipWs();
        if (self.pos != self.src.len) self.fail("trailing data after config object");
    }

    fn parseLimits(self: *Cursor, b: *Builder) void {
        self.expect('{');
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_recv_buffer_size => b.limits.recv_buffer_size = self.parseUInt(k.key, usize),
                H_send_buffer_size => b.limits.send_buffer_size = self.parseUInt(k.key, usize),
                H_max_body => b.limits.max_body = self.parseUInt(k.key, usize),
                H_max_line_bytes => b.limits.max_line_bytes = self.parseUInt(k.key, usize),
                H_max_headers => b.limits.max_headers = self.parseUInt(k.key, usize),
                H_max_chunked_body => b.limits.max_chunked_body = self.parseUInt(k.key, usize),
                H_static_cache_entries => b.limits.static_cache_entries = self.parseUInt(k.key, usize),
                H_static_cache_valid_seconds => b.limits.static_cache_valid_seconds = self.parseUInt(k.key, u64),
                H_static_content_cache_max => b.limits.static_content_cache_max = self.parseUInt(k.key, usize),
                H_connection_pool_max => b.limits.connection_pool_max = self.parseUInt(k.key, usize),
                else => self.fail("unknown limits key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in limits"),
            }
        }
    }

    fn parseRoutes(self: *Cursor, b: *Builder) void {
        self.expect('[');
        inline while (true) {
            if (self.peek() == ']') {
                self.pos += 1;
                return;
            }
            parseRoute(self, b);
            switch (self.peek()) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    return;
                },
                else => self.fail("expected ',' or ']' in routes"),
            }
        }
    }

    fn parseRoute(self: *Cursor, b: *Builder) void {
        self.expect('{');
        var spec = RouteSpec{ .path = .{ .src = "" } };
        var has_path = false;
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') break;
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_path => {
                    spec.path = self.parseString(b);
                    has_path = true;
                },
                H_match => {
                    const m = self.parseString(b);
                    const ms = m.srcOf("match cannot contain escapes");
                    spec.match = switch (keyHash(ms)) {
                        H_exact => .exact,
                        H_prefix => .prefix,
                        else => self.fail("match must be 'prefix' or 'exact'"),
                    };
                },
                H_modules => {
                    spec.modules_start = b.modules.len;
                    parseModules(self, b, &spec.modules_len);
                },
                H_max_age => spec.max_age = self.parseUInt(k.key, u32),
                H_root => spec.root = self.parseString(b),
                H_index => spec.index = self.parseString(b),
                H_autoindex => spec.autoindex = self.parseBool(k.key),
                H_embed => spec.embed = self.parseString(b),
                H_response => spec.response = parseResponse(self, b),
                H_upstreams => {
                    spec.upstreams_start = b.upstreams.len;
                    parseUpstreams(self, b, &spec.upstreams_len);
                },
                H_balance => {
                    const s = self.parseString(b);
                    const bs = s.srcOf("balance cannot contain escapes");
                    spec.balance = switch (keyHash(bs)) {
                        H_round_robin => .round_robin,
                        H_least_connections => .least_connections,
                        H_ip_hash => .ip_hash,
                        else => self.fail("balance must be 'round_robin', 'least_connections' or 'ip_hash'"),
                    };
                },
                H_max_fails => spec.max_fails = self.parseUInt(k.key, u32),
                H_fail_timeout_seconds => spec.fail_timeout_seconds = self.parseUInt(k.key, u32),
                else => self.fail("unknown route key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in route"),
            }
        }
        if (!has_path) self.fail("route missing 'path'");
        _ = b.routes.create(spec);
    }

    fn parseModules(self: *Cursor, b: *Builder, modules_len: *usize) void {
        self.expect('{');
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const pk = self.parseKey();
            markSeen(&seen, &seen_len, pk.hash, pk.key);
            self.expect(':');
            const phase = switch (pk.hash) {
                H_post_read => Phase.post_read,
                H_server_rewrite => Phase.server_rewrite,
                H_find_config => Phase.find_config,
                H_rewrite => Phase.rewrite,
                H_post_rewrite => Phase.post_rewrite,
                H_preaccess => Phase.preaccess,
                H_access => Phase.access,
                H_post_access => Phase.post_access,
                H_content => Phase.content,
                H_log => Phase.log,
                else => self.fail("unknown phase '" ++ pk.key ++ "'"),
            };
            const m = self.parseString(b);
            const module_name = resolve(m, b.strings.items[0..]);
            // Module names are NOT validated here: `resolve` would compare
            // against every registered module at comptime (~54 backward
            // branches per binding, a large slice of the budget for configs
            // with many modules). `Config.validate` re-checks the table at
            // startup and unknown names fail there.
            _ = b.modules.create(.{ .phase = phase, .module = module_name });
            modules_len.* += 1;
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in modules"),
            }
        }
    }

    fn parseResponse(self: *Cursor, b: *Builder) ResponseSpec {
        self.expect('{');
        var spec = ResponseSpec{};
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_status => spec.status = self.parseUInt(k.key, u16),
                H_body => spec.body = self.parseString(b),
                H_headers => {
                    self.expect('[');
                    spec.headers_start = b.headers.len;
                    inline while (true) {
                        if (self.peek() == ']') {
                            self.pos += 1;
                            break;
                        }
                        parseHeader(self, b);
                        spec.headers_len += 1;
                        switch (self.peek()) {
                            ',' => self.pos += 1,
                            ']' => {
                                self.pos += 1;
                                break;
                            },
                            else => self.fail("expected ',' or ']' in headers"),
                        }
                    }
                },
                H_compress => spec.compress = self.parseBool(k.key),
                else => self.fail("unknown response key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in response"),
            }
        }
        return spec;
    }

    fn parseHeader(self: *Cursor, b: *Builder) void {
        self.expect('{');
        var name: ?Str = null;
        var value: ?Str = null;
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') break;
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_name => name = self.parseString(b),
                H_value => value = self.parseString(b),
                else => self.fail("unknown header key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in header"),
            }
        }
        const n = name orelse self.fail("header missing 'name'");
        const v = value orelse self.fail("header missing 'value'");
        _ = b.headers.create(.{
            .name = resolve(n, b.strings.items[0..]),
            .value = resolve(v, b.strings.items[0..]),
        });
    }

    fn parseUpstreams(self: *Cursor, b: *Builder, upstreams_len: *usize) void {
        self.expect('[');
        inline while (true) {
            if (self.peek() == ']') {
                self.pos += 1;
                return;
            }
            parseUpstream(self, b);
            upstreams_len.* += 1;
            switch (self.peek()) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    return;
                },
                else => self.fail("expected ',' or ']' in upstreams"),
            }
        }
    }

    fn parseUpstream(self: *Cursor, b: *Builder) void {
        self.expect('{');
        var host: ?Str = null;
        var port: ?u16 = null;
        var seen: [16]u64 = undefined;
        var seen_len: usize = 0;
        inline while (true) {
            if (self.peek() == '}') break;
            const k = self.parseKey();
            markSeen(&seen, &seen_len, k.hash, k.key);
            self.expect(':');
            switch (k.hash) {
                H_host => host = self.parseString(b),
                H_port => port = self.parseUInt(k.key, u16),
                else => self.fail("unknown upstream key '" ++ k.key ++ "'"),
            }
            switch (self.peek()) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => self.fail("expected ',' or '}' in upstream"),
            }
        }
        const h = host orelse self.fail("upstream missing 'host'");
        const p = port orelse self.fail("upstream missing 'port'");
        const hs = resolve(h, b.strings.items[0..]);
        _ = b.upstreams.create(.{
            .host = hs,
            .port = p,
            .sockaddr = Upstream.makeSockaddr(hs, p) orelse
                @compileError("upstream host '" ++ hs ++ "' is not a valid IPv4 literal"),
        });
    }
};

/// Build the final `Config` from the parsed pools. Everything is resolved
/// into comptime-const tables by value so the resulting slices reference
/// comptime constants and freeze into .rodata (a slice of a comptime var
/// cannot escape into runtime values).
fn build(b: *const Builder) Config {
    const route_specs = b.routes.freeze();
    const mods = b.modules.freeze();
    const strings = b.strings.freeze();
    const headers = b.headers.freeze();
    const upstreams = b.upstreams.freeze();

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
            if (spec.response) |rs| {
                ranges[ri] = .{ .start = pos, .len = rs.headers_len };
                for (headers[rs.headers_start..][0..rs.headers_len]) |h| {
                    items[pos] = h;
                    pos += 1;
                }
            } else {
                ranges[ri] = .{ .start = 0, .len = 0 };
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

    const Routes = struct { items: [route_cap]Route, len: usize };
    const routes_built: Routes = comptime blk: {
        var items: [route_cap]Route = undefined;
        var len: usize = 0;
        for (route_specs, 0..) |spec, ri| {
            const mr = mod_table.ranges[ri];
            var resp: ?ResponseTemplate = null;
            if (spec.response) |rs| {
                const hr = head_table.ranges[ri];
                resp = .{
                    .status = rs.status,
                    .headers = head_table.items[hr.start..][0..hr.len],
                    .body = if (rs.body) |bd| resolve(bd, strings) else "",
                    .compress = rs.compress,
                };
            }
            const ur = up_table.ranges[ri];
            items[len] = .{
                .path = resolve(spec.path, strings),
                .match = spec.match,
                .modules = mod_table.items[mr.start..][0..mr.len],
                .max_age_seconds = spec.max_age,
                .root = if (spec.root) |r| resolve(r, strings) else null,
                .index = if (spec.index) |i| resolve(i, strings) else null,
                .autoindex = spec.autoindex,
                .embed = if (spec.embed) |e| resolve(e, strings) else null,
                .response = resp,
                .upstreams = up_table.items[ur.start..][0..ur.len],
                .balance = spec.balance,
                .max_fails = spec.max_fails,
                .fail_timeout_seconds = spec.fail_timeout_seconds,
            };
            len += 1;
        }
        break :blk .{ .items = items, .len = len };
    };

    const routes: []const Route = routes_built.items[0..routes_built.len];
    return .{ .routes = routes, .limits = b.limits };
}

/// Parse a JSON config at compile time. Invalid input, unknown keys, unknown
/// module/phase names, duplicate keys and out-of-range numbers are compile
/// errors carrying the offending byte position.
///
/// The default comptime budget (1000 backward branches) is shared by every
/// `parse()` evaluation in a compilation; a config's parse cost is roughly
/// its size in scanned characters, so a single quota bump covers both one
/// large config and several small ones.
pub fn parse(comptime json: []const u8) Config {
    @setEvalBranchQuota(100000);
    return comptime blk: {
        var b = Builder{};
        var c = Cursor{ .src = json };
        c.parseTop(&b);
        break :blk build(&b);
    };
}



const testing = std.testing;

test "comptime parse of the default-style config" {
    const cfg = parse(
        \\{ "routes": [ { "path": "/", "match": "prefix", "modules": { "content": "echo" } } ] }
    );
    try testing.expectEqual(@as(usize, 1), cfg.routes.len);
    try testing.expectEqualStrings("/", cfg.routes[0].path);
    try testing.expectEqualStrings("echo", cfg.routes[0].modules[0].module);
}
