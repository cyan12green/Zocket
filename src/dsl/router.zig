const std = @import("std");
const posix = std.posix;
const phase_mod = @import("phase.zig");
const registry = @import("registry.zig");
const response_mod = @import("../http/response.zig");
const ct_pool = @import("../ct_pool.zig");
const vars = @import("vars.zig");
const htpasswd_mod = @import("htpasswd.zig");
const regex_mod = @import("regex.zig");
const sockets_mod = @import("../net/sockets.zig");

pub const Phase = phase_mod.Phase;
pub const Frag = vars.Frag;
pub const VarId = vars.VarId;
pub const SetVar = vars.SetVar;
pub const LogFormat = vars.LogFormat;
pub const ProxyHeader = vars.ProxyHeader;
pub const CVHeader = vars.CVHeader;
pub const HeaderOp = vars.HeaderOp;
pub const ResponseTemplateCV = vars.ResponseTemplateCV;
pub const CaptureRange = vars.CaptureRange;
pub const Regex = vars.Regex;
pub const RegexState = vars.RegexState;

/// How a route's `path` is matched against the request target.
pub const Match = enum {
    /// The target must equal `path` exactly.
    exact,
    /// The target must start with `path` (nginx-style location prefix; the
    /// longest matching prefix wins).
    prefix,
    /// Regular expression, case-sensitive (`location ~`, M-D).
    regex,
    /// Regular expression, case-insensitive (`location ~*`, M-D).
    regex_ci,
};

/// One module attached to one phase of a route.
pub const ModuleBinding = struct {
    phase: Phase,
    /// Name of a module registered in the module registry.
    module: []const u8,
};

/// A declared route: a target pattern plus the modules attached to each phase.
pub const Route = struct {
    path: []const u8,
    /// Named location (`location @name`): never part of path matching;
    /// reachable only through internal redirects (try_files / error_page
    /// targets). Path is empty for named routes.
    name: ?[]const u8 = null,
    /// `internal;`: invisible to direct client requests; only internal
    /// redirects may land on it (nginx semantics — a public location with
    /// a shorter match serves external hits instead).
    internal: bool = false,
    /// `return 444;`: close the connection without writing a response.
    /// The reactor checks the status, not this flag (it travels on the
    /// response); the flag keeps the fast path off such routes.
    close_without_response: bool = false,
    /// `proxy_hide_header <name>;` names: upstream response headers to
    /// drop before the client sees them (case-insensitive).
    proxy_hide: []const []const u8 = &.{},
    match: Match = .prefix,
    modules: []const ModuleBinding = &.{},
    /// Comptime-specialised dispatch function. Set for
    /// struct-literal configs, where the whole route table is comptime-known;
    /// null for JSON-loaded routes, which use the loop-walk fallback.
    dispatch: ?registry.DispatchFn = null,
    /// Default cache lifetime in seconds: the cache-header
    /// module emits `Cache-Control: max-age=N` from this. 0 = no-cache.
    max_age_seconds: u32 = 0,
    /// Static-file serving: root directory on disk; optional
    /// `index` file for directories; `autoindex` to list them. `embed` names
    /// a file baked into .rodata at compile time (`embed_bytes`).
    root: ?[]const u8 = null,
    /// Resolved realpath of `root`, computed once at JSON config load
    /// (nginx-style: it never realpaths per request either). Null for
    /// comptime/struct-literal routes (immutable) and JSON routes without a
    /// root; the static module falls back to a per-request realpath then.
    root_real: ?[]const u8 = null,
    /// O_PATH|O_DIRECTORY fd of `root`, opened once at JSON config load
    /// Opened once at startup: the static module resolves targets against
    /// it with openat2(RESOLVE_BENEATH), one syscall with kernel-enforced
    /// containment instead of a per-request open + realpath pair. -1 when
    /// unset; the legacy per-request path is used then.
    root_fd: posix.fd_t = -1,
    index: ?[]const u8 = null,
    autoindex: bool = false,
    embed: ?[]const u8 = null,
    embed_bytes: []const u8 = &.{},
    /// Pre-rendered ETag (`"hex"`) for `embed_bytes`, computed at comptime in
    /// the dispatch table build. Empty for hand-built routes (runtime
    /// fallback).
    embed_etag: []const u8 = &.{},
    /// Fixed-response template: a route with `response` (and
    /// no modules) is served from the pre-serialised `response_bytes` — no
    /// pipeline, no response builder. Routes with modules keep the pipeline;
    /// the template is applied when nothing claims the request.
    response: ?ResponseTemplate = null,
    response_bytes: ?FastResponse = null,
    /// Reverse proxy: upstream backends, load-balance
    /// strategy and passive health-check parameters.
    upstreams: []const Upstream = &.{},
    balance: Balance = .round_robin,
    max_fails: u32 = 3,
    fail_timeout_seconds: u32 = 30,
    /// Upstream I/O timeouts in seconds (proxy module): connect / send /
    /// read. 0 selects the compiled default (1 s connect, 1 s send, 5 s
    /// read — the pre-timeout-directive behavior; the 5 s read cap is the
    /// documented sync-driver limitation, not a per-request deadline).
    proxy_connect_timeout_s: u32 = 0,
    proxy_send_timeout_s: u32 = 0,
    proxy_read_timeout_s: u32 = 0,
    /// Retry on the next backend after a transport failure (connect/send/
    /// read error or timeout): `proxy_next_upstream on;`. Off by default —
    /// a retry re-sends the request, which is unsafe for non-idempotent
    /// methods; opt in when backends are interchangeable. Retries each
    /// usable backend at most once per request; HTTP error statuses from a
    /// live backend (5xx etc.) are NOT retried in v1, only transport
    /// failures. Sync forward path only (the parked/async path marks the
    /// failure and answers 502 as before).
    proxy_next_upstream: bool = false,
    /// Status retry mask (`proxy_next_upstream error timeout http_502
    /// http_503 http_504;`): bit0 = transport (error/timeout), bit1 = 502,
    /// bit2 = 503, bit3 = 504. Bare `on` = bit0 only.
    proxy_next_upstream_mask: u8 = 0,
    /// WebSocket passthrough (`proxy_ws on`): forward `Connection: Upgrade`
    /// + `Upgrade` to the backend and relay a 101 back (headers preserved).
    /// v1 covers the handshake only; post-101 duplex byte-pipe rides the
    /// Stage-2 upstream seam.
    proxy_ws: bool = false,
    /// Upstream TLS verification (`proxy_ssl_verify on` + trusted
    /// bundle): reject backends whose chain/hostname don't verify.
    /// Default off (nginx parity) — handshake still negotiates TLS.
    proxy_ssl_verify: bool = false,
    /// PEM CA bundle for upstream verification (`proxy_ssl_trusted_certificate`).
    proxy_ssl_trusted_certificate: ?[]const u8 = null,
    /// SNI/verify hostname override (`proxy_ssl_name`; default: the
    /// upstream hostname, or the literal when verification is off).
    proxy_ssl_name: ?[]const u8 = null,
    /// Keepalive pool tuning (proxy module): max pooled connections per
    /// backend per reactor thread (default 8, clamped to a hard cap of 32)
    /// and pooled-connection idle expiry in seconds (default 60; an idle
    /// connection is closed on next use past the deadline). 0 selects the
    /// default for both.
    proxy_keepalive_max: u32 = 0,
    proxy_keepalive_timeout_s: u32 = 0,
    /// Access control (`allow`/`deny`, first match wins; no match allows):
    /// ordered CIDR rules evaluated in the access phase.
    access_rules: []const AccessRule = &.{},
    /// `expires` response header control (cache_headers filter): off by
    /// default (Cache-Control follows max_age); epoch/max stamp fixed
    /// dates; after(N) stamps now+N and overrides Cache-Control max-age.
    expires: Expires = .off,
    /// `etag on|off` (default on): emit the ETag header when content
    /// metadata is known. Off suppresses emission only; conditional
    /// matching on Last-Modified still applies.
    etag_enabled: bool = true,
    /// Trusted-proxy prefixes (`set_real_ip_from`): when the peer matches,
    /// `client_ip` is replaced from `real_ip_header` (default
    /// X-Forwarded-For) in the post_read phase, so downstream access
    /// decisions see the real client.
    realip_from: []const Cidr = &.{},
    /// Header to read the real client IP from (null = X-Forwarded-For).
    real_ip_header: ?[]const u8 = null,
    /// Walk the header chain right-to-left past trusted proxies instead of
    /// taking the last entry (`real_ip_recursive on`).
    real_ip_recursive: bool = false,
    /// Route opt-in for chunked transfer encoding (HTTP/1.1 only): responses
    /// on this route are framed as a single chunk with
    /// `Transfer-Encoding: chunked` instead of Content-Length. Off by
    /// default — Content-Length is unambiguous and lets the response flush
    /// as one writev; enable for routes whose body size is not known in
    /// advance or when streaming semantics are wanted. Ignored by h2.
    chunked: bool = false,
    /// Route opt-in for TCP_CORK (Linux tcp_nopush equivalent): batches the
    /// HTTP head + sendfile body into one TCP segment for large-file responses.
    /// Off by default — small responses benefit from TCP_NODELAY instead.
    tcp_nopush: bool = false,

    /// `^~` prefix flag (still .prefix; only precedence differs, M-D).
    no_regex: bool = false,
    /// `rewrite` rules in declaration order (rewrite phase; `last`
    /// re-walks matching, `break` stays, redirect/permanent answer 3xx).
    rewrites: []const RewriteRule = &.{},
    /// `error_page` table: status -> alternate URI (or `=code`). The
    /// error_page module reads it in the log phase; a URI target becomes an
    /// internal redirect (Server.handleRequest re-walks against it), a bare
    /// `=code` target rewrites the status in place.
    error_pages: []const ErrorPage = &.{},
    /// `try_files` candidates, in test order. The try_files module probes
    /// each against `root` and internally redirects to the first that
    /// exists; the last entry is the fallback (`=code` or a URI).
    try_files: []const []const u8 = &.{},
    /// Comptime-compiled NFA for .regex / .regex_ci locations (M-D).
    pattern_regex: ?Regex = null,
    /// User variables declared with `set` in this location (M-C).
    set_vars: []const SetVar = &.{},
    /// Dynamic response template (return/add_header with variables, M-B).
    response_cv: ?ResponseTemplateCV = null,
    /// proxy_set_header overrides (M-E).
    proxy_headers: []const ProxyHeader = &.{},
    /// Header-manipulation ops for the `headers` module (log phase =
    /// post-processing): set / add / remove applied in declaration order to
    /// the final module-produced header set.
    headers_ops: []const HeaderOp = &.{},
    /// Basic-auth challenge (auth_basic module): realm string plus the
    /// comptime-embedded htpasswd table. Both must be present for the
    /// module to engage; either directive auto-binds the module.
    auth_basic_realm: ?[]const u8 = null,
    auth_basic_users: []const htpasswd_mod.Entry = &.{},
    /// Rate limiting (limit_req module): sustained requests-per-second plus
    /// burst depth of the leaky bucket. rate == 0 disables.
    limit_req_rate: u32 = 0,
    limit_req_burst: u32 = 0,
    /// Concurrency cap (limit_conn module): max simultaneous in-flight
    /// requests per client key. 0 disables.
    limit_conn_max: u32 = 0,
    /// Refusal statuses (`limit_req_status` / `limit_conn_status`): 429 or
    /// 503. 0 selects the 503 default.
    limit_req_status: u16 = 0,
    limit_conn_status: u16 = 0,
    /// `limit_rate` bytes per second (0 = unlimited). Latched per response
    /// by the reactor, which paces body bytes (memory + sendfile) against
    /// a token bucket. Plain HTTP/1.1 only in v1 (TLS/h2 framing paths
    /// bypass it).
    limit_rate_bps: u64 = 0,
    /// Precompressed serving (precompressed module): look for a `.gz`
    /// sibling of the requested file and serve it with Content-Encoding.
    precompressed: bool = false,
    /// Brotli / zstd twin serving (`precompressed br|zstd;`): same shape
    /// as gzip_static/brotli_static — serve disk twins, never encode.
    precompressed_br: bool = false,
    precompressed_zstd: bool = false,
    /// Response body substitution (`sub_filter` filter): match/replace
    /// pair plus once flag (default true — first occurrence only).
    sub_filter_match: ?[]const u8 = null,
    sub_filter_replacement: ?[]const u8 = null,
    sub_filter_once: bool = true,
    /// `proxy_pass http://host/prefix/;` URI tail: when set and the
    /// request target starts with this route's location path, the matched
    /// prefix is replaced by this URI (query preserved) — nginx rule.
    proxy_pass_uri: ?[]const u8 = null,
    /// Location rewriting (`proxy_redirect <from> <to>;`): prefix-substitute
    /// upstream Location/Refresh values starting with `from`. Null = off.
    proxy_redirect_from: ?[]const u8 = null,
    proxy_redirect_to: ?[]const u8 = null,
    /// X-Accel-Redirect (`accel on;`): honor the backend's internal
    /// redirect header in the log phase.
    accel_enabled: bool = false,
    /// Response caching (proxy_cache modules): enable + fresh window and
    /// stale-while-revalidate grace, both in seconds.
    proxy_cache_enabled: bool = false,
    cache_ttl_seconds: u32 = 0,
    cache_swr_seconds: u32 = 0,
    /// Subrequest authorization (auth_request module): forward this URI
    /// through an internal subrequest; 2xx admits, anything else copies.
    auth_request_uri: ?[]const u8 = null,
    /// CORS helper (cors module): enabled flag + response headers.
    /// `cors_origin` null with enabled = "*" default at run time.
    cors_enabled: bool = false,
    cors_origin: ?[]const u8 = null,
    cors_methods: ?[]const u8 = null,
    cors_headers: ?[]const u8 = null,
    cors_credentials: bool = false,
    cors_max_age: u32 = 0,
    /// Expiring-URL guard (secure_link module): HMAC-SHA256 secret;
    /// requests need `?e=<unix>&s=<hex>` over `{path}|{e}`.
    secure_link_secret: ?[]const u8 = null,
    /// JWT-lite (auth_jwt module): HS256 shared secret + expiry leeway.
    /// ES256/JWKS stays deferred (TLS ECDSA verify reuse is the path).
    auth_jwt_secret: ?[]const u8 = null,
    auth_jwt_leeway_s: u32 = 0,
    /// ES256 key file (PEM certificate; `auth_jwt_key_file`). Wins over
    /// the shared secret when both are set.
    auth_jwt_key_file: ?[]const u8 = null,
    /// Active health checks (proxy module): when `health_check_path` is
    /// set a module-owned checker thread probes every backend on the
    /// interval and applies rise/fall thresholds to flip liveness.
    health_check_path: ?[]const u8 = null,
    health_check_interval_s: u32 = 5,
    health_check_rise: u32 = 2,
    health_check_fall: u32 = 3,
    health_check_timeout_s: u32 = 1,
    /// Sticky sessions (cookie-based affinity): when set, the proxy module
    /// reads this cookie for a previously-assigned backend tag and answers
    /// new clients with a Set-Cookie binding them to their backend.
    sticky_cookie: ?[]const u8 = null,
    /// Index into Config.log_formats; null = none (off). The access_log
    /// module reads it; defaults to index 0 (the `combined` default) when
    /// the route binds `log access_log;` and no `access_log` directive is
    /// present.
    log_format: ?usize = null,

    /// The first module name bound to `phase` on this route, if any. Multiple
    /// modules may share a phase (nginx-style chains); `self.modules` is kept
    /// in config declaration order, so callers that need the whole chain
    /// iterate `self.modules` filtering on `phase` instead of using this.
    /// Response FILTERS bound to this route (declaration order; applied in
    /// reverse after the handler walk and any template fallback). Distinct
    /// from `modules` so kind semantics stay explicit.
    filters: []const ModuleBinding = &.{},

    pub fn moduleFor(self: *const Route, phase: Phase) ?[]const u8 {
        for (self.modules) |b| {
            if (b.phase == phase) return b.module;
        }
        return null;
    }
};

/// Prefix/exact route matching. An exact match beats every prefix; otherwise
/// the longest matching prefix wins. Regex routes are excluded (they are
/// walked separately by the router's precedence). `matchRoutes` is called
/// from the `find_config` phase of the pipeline.
pub fn matchRoutes(route_list: []const Route, target: []const u8) ?*const Route {
    return matchRoutesAt(route_list, target, false);
}

/// Linear fallback with `internal` filtering: external requests skip
/// `internal;` routes; internal redirects see everything.
pub fn matchRoutesAt(route_list: []const Route, target: []const u8, allow_internal: bool) ?*const Route {
    var best: ?*const Route = null;
    for (route_list) |*r| {
        if (r.name != null) continue;
        if (r.internal and !allow_internal) continue;
        switch (r.match) {
            .exact => {
                if (std.mem.eql(u8, target, r.path)) return r;
            },
            .prefix => {
                if (!std.mem.startsWith(u8, target, r.path)) continue;
                if (best == null or r.path.len > best.?.path.len) best = r;
            },
            // Regex routes are walked separately (M-D); the linear fallback
            // skips them (same as the trie).
            .regex, .regex_ci => {},
        }
    }
    return best;
}

/// Build the declaration-order regex route table for a comptime route list
/// (M-D §7): one entry per .regex/.regex_ci route, with the pattern compiled
/// at comptime into its NFA.
pub fn buildRegexTable(comptime routes: []const Route) []const RegexRoute {
    return comptime blk: {
        var table: [128]RegexRoute = undefined;
        var n: usize = 0;
        for (routes, 0..) |*r, i| {
            if (r.name != null) continue;
            if (r.match == .regex or r.match == .regex_ci) {
                const re = r.pattern_regex orelse
                    @compileError("regex route '" ++ r.path ++ "' has no compiled pattern (M-D)");
                table[n] = .{
                    .re = &re,
                    .route = @intCast(i),
                    .ci = r.match == .regex_ci,
                };
                n += 1;
            }
        }
        const out: [n]RegexRoute = table[0..n].*;
        break :blk &out;
    };
}

/// Sentinel: no route is bound at a trie node.
pub const no_route = std.math.maxInt(u32);

/// One header of a fixed-response template.
pub const TemplateHeader = struct { name: []const u8, value: []const u8 };

/// Load-balance strategy for a proxy route. The dispatch is a
/// comptime switch: dead strategies are eliminated from the binary.
pub const Balance = enum {
    round_robin,
    least_connections,
    ip_hash,
    /// Random among usable backends (xorshift seeded from the request).
    random,
    /// Consistent hash of the client key: same client lands on the same
    /// backend while it stays usable, reshuffling only its share on failure.
    consistent_hash,
    /// Least-latency first: exponential weighted moving average of upstream
    /// response time per backend.
    least_time,

    pub fn parse(s: []const u8) ?Balance {
        if (std.mem.eql(u8, s, "round_robin")) return .round_robin;
        if (std.mem.eql(u8, s, "least_connections")) return .least_connections;
        if (std.mem.eql(u8, s, "ip_hash")) return .ip_hash;
        if (std.mem.eql(u8, s, "random")) return .random;
        if (std.mem.eql(u8, s, "consistent_hash")) return .consistent_hash;
        if (std.mem.eql(u8, s, "least_time")) return .least_time;
        return null;
    }
};

/// `expires` value: off (no Expires header), epoch/max fixed stamps, or a
/// relative offset in seconds from now.
pub const Expires = union(enum) {
    off,
    epoch,
    max,
    after: u32,
};

/// One `error_page` entry: which status it serves, and what to serve.
/// `target` is either a URI (internal redirect, nginx `error_page 404 /404.html`)
/// or `=<code>` (rewrite the status in place, nginx `error_page 404 =200`).
pub const ErrorPage = struct {
    status: u16,
    target: []const u8,

    /// True for the `=code` form (no URI to redirect to).
    pub fn isCodeForm(self: ErrorPage) bool {
        return self.target.len > 0 and self.target[0] == '=';
    }

    /// The status code of the `=code` form (`=503` -> 503); 0 otherwise.
    pub fn codeOf(self: ErrorPage) u16 {
        if (!self.isCodeForm()) return 0;
        return std.fmt.parseInt(u16, self.target[1..], 10) catch 0;
    }
};

/// One `rewrite` rule: match `pattern` against the decoded path, render
/// `replacement` (`$1..$9` from the match), act by `flag`.
pub const RewriteFlag = enum {
    last,
    @"break",
    redirect,
    permanent,
};

pub const RewriteRule = struct {
    pattern: Regex,
    replacement: []const vars.Frag,
    flag: RewriteFlag = .last,
};

/// A CIDR prefix for access control and trusted-proxy lists.
pub const Cidr = sockets_mod.Cidr;

/// One `allow`/`deny` rule: first match in declaration order wins.
pub const AccessRule = struct {
    allow: bool,
    cidr: Cidr,
};

/// One proxy backend. The `sockaddr` is pre-computed: at
/// compile time for struct-literal configs (host is a comptime IP literal —
/// no DNS, no runtime byte-swapping), at startup for JSON configs.
pub const Upstream = struct {
    host: []const u8,
    port: u16,
    sockaddr: std.posix.sockaddr = .{ .family = 0, .data = @as([14]u8, @splat(@as(u8, 0))) },
    /// DNS hostname when `host` is not an IP literal (null for literals).
    /// Family-0 sockaddrs are the "unresolved" marker for these: the
    /// resolver fills the octets in at startup/refresh. Never mutated in
    /// .rodata — embeddedInit copies hostname routes onto the heap first.
    hostname: ?[]const u8 = null,
    /// TLS to this backend (`https://` scheme in proxy_pass/upstream).
    /// Handshake uses SNI = proxy_ssl_name orelse hostname orelse (literals
    /// only with verification off). Sync driver only; single-use
    /// connections (no keepalive pooling) in v1.
    tls: bool = false,

    /// Build the kernel sockaddr for an IPv4 host literal ("127.0.0.1").
    /// Works at comptime (struct-literal configs) and at runtime (JSON).
    pub fn makeSockaddr(host: []const u8, port: u16) ?std.posix.sockaddr {
        var octets: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, host, '.');
        var i: usize = 0;
        while (it.next()) |part| {
            if (i >= 4) return null;
            const v = std.fmt.parseInt(u8, part, 10) catch return null;
            octets[i] = v;
            i += 1;
        }
        if (i != 4) return null;
        var addr: std.posix.sockaddr = .{
            .family = std.posix.AF.INET,
            .data = @as([14]u8, @splat(@as(u8, 0))),
        };
        std.mem.writeInt(u16, addr.data[0..2], port, .big);
        std.mem.writeInt(u32, addr.data[2..6], std.mem.readInt(u32, &octets, .big), .big);
        return addr;
    }
};

/// TCP stream proxy (C3): one `stream { server { ... } }` block. The
/// default backend handles plain TCP and SNI-less TLS; `sni_routes`
/// override by ClientHello name (exact, then `*.suffix` wildcard).
pub const StreamSniRoute = struct {
    pattern: []const u8 = "",
    host: []const u8 = "",
    port: u16 = 0,
    sockaddr: std.posix.sockaddr = .{ .family = 0, .data = @as([14]u8, @splat(@as(u8, 0))) },
    hostname: ?[]const u8 = null,
};

pub const StreamServer = struct {
    listen_port: u16 = 0,
    default_host: []const u8 = "",
    default_port: u16 = 0,
    default_sockaddr: std.posix.sockaddr = .{ .family = 0, .data = @as([14]u8, @splat(@as(u8, 0))) },
    default_hostname: ?[]const u8 = null,
    sni_routes: []const StreamSniRoute = &.{},
};

/// A fixed response served from pre-serialised bytes:
/// redirects, healthchecks, error pages.
pub const ResponseTemplate = struct {
    status: u16 = 200,
    headers: []const TemplateHeader = &.{},
    body: []const u8 = &.{},
    /// Comptime pre-compression is DEFERRED: the runtime flate
    /// compressor's dynamic-Huffman path hits a stdlib type-inference bug
    /// under comptime evaluation, and a deterministic comptime encoder
    /// cannot be byte-identical to it. Setting this is a compile error.
    compress: bool = false,
};

/// The pre-serialised fast-path response. `head` is the status line plus the
/// template headers, each line CRLF-terminated; the reactor appends
/// `Connection`, `Content-Length`, the blank line, then `body` — byte
/// order-identical to the pipeline/response-builder equivalent.
pub const FastResponse = struct {
    head: []const u8,
    body: []const u8,
};

/// Serialise a response template at compile time: status line, template
/// headers and (optionally gzip-compressed) body become constant byte arrays
/// in .rodata.
pub fn serializeResponseTemplate(comptime t: ResponseTemplate) FastResponse {
    return comptime blk: {
        if (t.compress) {
            @compileError("template 'compress' (comptime pre-compression) is deferred: " ++
                "the stdlib flate dynamic-Huffman path breaks at comptime in this Zig snapshot; " ++
                "see docs/ROADMAP.md (comptime pre-compression)");
        }
        const body = t.body;

        const head_bound = blk2: {
            var n: usize = 64; // status line slack
            for (t.headers) |h| n += h.name.len + h.value.len + 4;
            break :blk2 n;
        };
        var head: [head_bound]u8 = undefined;
        var used: usize = 0;
        const status_line = std.fmt.bufPrint(head[used..], "HTTP/1.1 {d} {s}\r\n", .{
            t.status,
            response_mod.reasonPhraseForCode(t.status),
        }) catch unreachable;
        used += status_line.len;
        for (t.headers) |h| {
            const line = std.fmt.bufPrint(head[used..], "{s}: {s}\r\n", .{ h.name, h.value }) catch unreachable;
            used += line.len;
        }
        const head_const = head;
        break :blk .{ .head = head_const[0..used], .body = body };
    };
}

/// One trie node: a byte of path plus the routes ending here.
pub const TrieNode = struct {
    /// Range of this node's child edges in the flat edge array.
    edges_start: u32 = 0,
    edge_count: u16 = 0,
    /// Index of a prefix route whose path ends exactly at this node.
    prefix_route: u32 = no_route,
    /// Index of an exact route whose path ends exactly at this node.
    exact_route: u32 = no_route,
    /// Deepest prefix route along the walk to this node (longest-prefix
    /// candidate for the current traversal).
    best_prefix: u32 = no_route,
    /// External-request variants: same as the fields above but only for
    /// non-`internal` routes (client requests skip internal locations;
    /// internal redirects see the full tables).
    prefix_route_ext: u32 = no_route,
    exact_route_ext: u32 = no_route,
    best_prefix_ext: u32 = no_route,
    /// Index of the parent node (for the best-prefix propagation pass).
    parent: u32 = no_route,
};

/// One child edge: a byte and the node it descends into.
pub const TrieEdge = struct {
    byte: u8,
    child: u32,
};

/// A byte-level radix trie over the route table: lookup is O(path length),
/// not O(routes). Exact routes win over prefixes; prefix nodes carry their
/// longest-prefix chain so a single traversal produces the best match.
/// Built at compile time for struct-literal configs (in .rodata) and at
/// startup for JSON configs; both builders share the same core.
pub const Trie = struct {
    nodes: []const TrieNode = &.{},
    edges: []const TrieEdge = &.{},
};

/// Bounds the trie can need: one node per path byte (plus the root) and one
/// edge per node past the root. Shared by the comptime and runtime builders.
fn trieBounds(routes: []const Route) struct { nodes: usize, edges: usize } {
    var nodes: usize = 1;
    for (routes) |r| nodes += r.path.len;
    return .{ .nodes = nodes, .edges = nodes - 1 };
}

fn findEdgeInRange(edges: []const TrieEdge, start: usize, count: usize, byte: u8) ?u32 {
    for (edges[start .. start + count]) |e| {
        if (e.byte == byte) return e.child;
    }
    return null;
}

/// Insert a child edge into node `cur`'s contiguous range, keeping the range
/// sorted by edge byte. Everything at/after the insertion point shifts right;
/// the ranges of later nodes (whose edges_start is at or past the insertion
/// point) follow. Node ranges stay laid out in node-id order.
fn insertEdge(
    edges: []TrieEdge,
    nodes: []TrieNode,
    edge_count: *usize,
    node_count: usize,
    cur: u32,
    byte: u8,
    child: u32,
) void {
    const start = nodes[cur].edges_start;
    const cnt = nodes[cur].edge_count;
    var pos: usize = 0;
    while (pos < cnt and edges[start + pos].byte < byte) pos += 1;
    const insert_at = start + pos;

    var k = edge_count.*;
    while (k > insert_at) : (k -= 1) edges[k] = edges[k - 1];
    edges[insert_at] = .{ .byte = byte, .child = child };
    edge_count.* += 1;
    nodes[cur].edge_count += 1;

    // Ranges at or past the insertion point moved right by one. `cur` itself
    // is excluded: its range starts at `start <= insert_at` (equal only for a
    // still-empty range, which must keep its placeholder edges_start).
    for (0..node_count) |i| {
        if (i != cur and nodes[i].edge_count > 0 and nodes[i].edges_start >= insert_at) {
            nodes[i].edges_start += 1;
        }
    }
}

/// Build the trie for `routes` into caller-provided buffers (the core shared
/// by the comptime and runtime builders). Duplicate (path, match) pairs are
/// an error: the old linear matcher silently let the first one win, which a
/// deterministic router must not do.
fn buildCore(routes: []const Route, nodes: []TrieNode, edges: []TrieEdge) error{AmbiguousRoutes}!Trie {
    var node_count: usize = 1; // root at index 0
    var edge_count: usize = 0;
    nodes[0] = .{};

    for (routes, 0..) |r, ri| {
        // Named locations are not trie material: they are looked up by
        // name only, never by path.
        if (r.name != null) continue;
        var cur: u32 = 0;
        for (r.path) |byte| {
            const found = findEdgeInRange(edges, nodes[cur].edges_start, nodes[cur].edge_count, byte);
            if (found) |child| {
                cur = child;
            } else {
                const child_idx: u32 = @intCast(node_count);
                node_count += 1;
                nodes[child_idx] = .{ .parent = cur };
                if (nodes[cur].edge_count == 0) {
                    nodes[cur].edges_start = @intCast(edge_count);
                }
                insertEdge(edges, nodes, &edge_count, node_count, cur, byte, child_idx);
                cur = child_idx;
            }
        }
        const n = &nodes[cur];
        switch (r.match) {
            .prefix => {
                if (n.prefix_route != no_route) return error.AmbiguousRoutes;
                n.prefix_route = @intCast(ri);
                if (!r.internal) n.prefix_route_ext = @intCast(ri);
            },
            .exact => {
                if (n.exact_route != no_route) return error.AmbiguousRoutes;
                n.exact_route = @intCast(ri);
                if (!r.internal) n.exact_route_ext = @intCast(ri);
            },
            // Regex routes are not trie material (M-D): they are walked
            // separately in declaration order.
            .regex, .regex_ci => {},
        }
    }

    // Best-prefix propagation: node ids are creation order, so parents always
    // precede children. A node carrying a prefix route is the deepest prefix
    // along its own path; otherwise it inherits its parent's.
    for (0..node_count) |i| {
        if (nodes[i].prefix_route != no_route) {
            nodes[i].best_prefix = nodes[i].prefix_route;
        } else if (nodes[i].parent != no_route) {
            nodes[i].best_prefix = nodes[nodes[i].parent].best_prefix;
        }
        if (nodes[i].prefix_route_ext != no_route) {
            nodes[i].best_prefix_ext = nodes[i].prefix_route_ext;
        } else if (nodes[i].parent != no_route) {
            nodes[i].best_prefix_ext = nodes[nodes[i].parent].best_prefix_ext;
        }
    }

    return .{
        .nodes = nodes[0..node_count],
        .edges = edges[0..edge_count],
    };
}

/// Compile-time ambiguity check for struct-literal route tables: duplicate
/// (path, match) pairs are a compile error, not a runtime surprise.
pub fn comptimeCheckAmbiguous(comptime routes: []const Route) void {
    inline for (routes, 0..) |r, i| {
        inline for (routes[i + 1 ..]) |o| {
            if (r.name != null or o.name != null) continue;
            if (std.mem.eql(u8, r.path, o.path) and r.match == o.match) {
                @compileError("ambiguous routes: duplicate " ++ r.path ++ " (" ++
                    (if (r.match == .exact) "exact" else "prefix") ++ ")");
            }
        }
    }
}

/// Build the trie at compile time from a comptime route table. The result —
/// nodes, edges and all — lives in .rodata. Duplicate routes are a compile
/// error (see `comptimeCheckAmbiguous`). The inner body is forced through a
/// `comptime` expression so this works even when the call site is runtime
/// code (e.g. `Server.default()`).
pub fn buildTrie(comptime routes: []const Route) Trie {
    return comptime buildTrieImpl(routes);
}

fn buildTrieImpl(comptime routes: []const Route) Trie {
    // The trie build walks every route plus one node/edge pass per
    // trie-node; large configs (large embedded configs) exceed the default
    // 1000-backward-branch comptime budget.
    @setEvalBranchQuota(100000);
    comptimeCheckAmbiguous(routes);
    const bounds = trieBounds(routes);
    // Typed comptime pools are the builder's arena: `buildCore` writes into
    // their arrays, and once the pools are comptime constants their frozen
    // slices are plain static data in .rodata (comptime *var* pointers
    // cannot escape into runtime values, so the pools are broken out of a
    // comptime block first).
    const built = blk: {
        var nodes = ct_pool.CtPool(TrieNode, bounds.nodes){};
        var edges = ct_pool.CtPool(TrieEdge, bounds.edges){};
        const trie = buildCore(routes, nodes.items[0..], edges.items[0..]) catch unreachable;
        nodes.len = trie.nodes.len;
        edges.len = trie.edges.len;
        break :blk .{ .nodes = nodes, .edges = edges };
    };
    return .{
        .nodes = built.nodes.freeze(),
        .edges = built.edges.freeze(),
    };
}

fn findEdge(trie: *const Trie, node: u32, byte: u8) ?u32 {
    const n = trie.nodes[node];
    const start = n.edges_start;
    var lo: usize = 0;
    var hi: usize = n.edge_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = trie.edges[start + mid];
        if (e.byte == byte) return e.child;
        if (e.byte < byte) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// Match a target against the trie in O(path length). Exact routes win when
/// the target ends at their node; otherwise the deepest prefix route along
/// the walk wins (longest-prefix semantics). Returns the winning route index
/// or null.
/// `ext` = external-request view: `internal;` routes are invisible.
pub fn trieMatch(trie: *const Trie, target: []const u8, ext: bool) ?u32 {
    var node: u32 = 0;
    var best: u32 = no_route;
    const root = trie.nodes[0];
    const root_best = if (ext) root.best_prefix_ext else root.best_prefix;
    if (root_best != no_route) best = root_best;
    var consumed = true;
    for (target) |byte| {
        const child = findEdge(trie, node, byte) orelse {
            consumed = false;
            break;
        };
        node = child;
        const n = trie.nodes[node];
        const bp = if (ext) n.best_prefix_ext else n.best_prefix;
        if (bp != no_route) best = bp;
    }
    if (consumed) {
        const n = trie.nodes[node];
        const er = if (ext) n.exact_route_ext else n.exact_route;
        if (er != no_route) return er;
    }
    return if (best != no_route) best else null;
}

/// Capture ranges + subject for a regex match (M-D). `ranges[0]` is the
/// whole match; `count` = number of populated ranges.
pub const MatchCaps = struct {
    subject: []const u8,
    ranges: [9]CaptureRange = @as([9]CaptureRange, @splat(@as(CaptureRange, .{ .start = 0, .end = 0 }))),
    count: u8 = 0,
};

/// One regex route in the declaration-order table (M-D).
pub const RegexRoute = struct {
    re: *const Regex,
    route: u32,
    ci: bool,
};

/// A built route table: the routes plus their trie. `match` is the lookup the
/// pipeline's find_config phase uses. With an empty trie it falls back to the
/// linear `matchRoutes` (plain `Server.init` / direct test usage).
pub const Router = struct {
    routes: []const Route = &.{},
    trie: Trie = .{},
    /// Regex routes in declaration order (M-D), walked only after exact and
    /// `^~` prefixes have been ruled out (nginx precedence).
    regex_routes: []const RegexRoute = &.{},
    /// Regex table building must be comptime-only for struct-literal configs;
    /// `Server.comptimeInitImpl` fills it via `buildRegexTable`.
    regex_table_built: bool = false,

    /// Match a target with nginx location precedence (plan §7):
    /// 1. exact trie match wins immediately (no captures);
    /// 2. longest `^~`-flagged prefix wins (regex skipped);
    /// 3. first regex (~ / ~*) match in declaration order wins (captures
    ///    recorded into `caps`);
    /// 4. longest plain prefix wins; else null.
    /// External-request match: `internal;` locations are invisible.
    pub fn match(self: *const Router, target: []const u8, caps: ?*MatchCaps) ?*const Route {
        return self.matchAt(target, caps, false);
    }

    /// Match with `internal` visibility control: `allow_internal` is set
    /// for internal redirect hops (try_files / error_page / accel), where
    /// `internal;` locations become reachable.
    pub fn matchAt(self: *const Router, target: []const u8, caps: ?*MatchCaps, allow_internal: bool) ?*const Route {
        if (self.trie.nodes.len == 0) return matchRoutesAt(self.routes, target, allow_internal);
        const idx = trieMatch(&self.trie, target, !allow_internal) orelse return null;
        const trie_route = &self.routes[idx];

        // 1. exact match wins immediately.
        if (trie_route.match == .exact) return trie_route;

        // 2. `^~` prefix wins (regex skipped).
        if (trie_route.no_regex) return trie_route;

        // 3. regex routes in declaration order; first match wins, captures
        // recorded into `caps`.
        const best_prefix: ?*const Route = if (trie_route.match == .prefix) trie_route else null;
        for (self.regex_routes) |rr| {
            const r = &self.routes[rr.route];
            if (r.internal and !allow_internal) continue;
            if (r.pattern_regex) |*re| {
                var mcaps: MatchCaps = .{ .subject = target };
                if (regex_mod.match(re, target, &mcaps.ranges, 0, rr.ci)) {
                    mcaps.count = re.group_count + 1;
                    if (caps) |c| c.* = mcaps;
                    return r;
                }
            }
        }
        // 4. longest plain prefix.
        return best_prefix;
    }

    /// Look up a named location (`location @name`). Named locations are
    /// excluded from path matching, so this is the only route to them.
    pub fn matchNamed(self: *const Router, name: []const u8) ?*const Route {
        for (self.routes) |*r| {
            if (r.name) |n| {
                if (std.mem.eql(u8, n, name)) return r;
            }
        }
        return null;
    }

    pub fn deinit(self: *const Router, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const testing = std.testing;

fn route_fixture() [3]Route {
    return .{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/api", .match = .prefix },
        .{ .path = "/api/v1", .match = .prefix },
    };
}

test "exact match wins over prefix" {
    const rs = [_]Route{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/api/v1", .match = .exact },
    };
    try testing.expectEqualStrings("/api/v1", matchRoutes(&rs, "/api/v1").?.path);
}

test "longest prefix wins" {
    const rs = route_fixture();
    try testing.expectEqualStrings("/api/v1", matchRoutes(&rs, "/api/v1/users").?.path);
    try testing.expectEqualStrings("/api", matchRoutes(&rs, "/api/users").?.path);
}

test "catch-all prefix matches everything" {
    const rs = [_]Route{.{ .path = "/", .match = .prefix }};
    for ([_][]const u8{ "/", "/x", "/api", "/anything/else" }) |t| {
        try testing.expectEqualStrings("/", matchRoutes(&rs, t).?.path);
    }
}

test "exact does not match a longer target" {
    const rs = [_]Route{.{ .path = "/only", .match = .exact }};
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/only/x"));
}

test "no match yields null" {
    const rs = [_]Route{.{ .path = "/only", .match = .exact }};
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/other"));
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/only/x"));
}

test "moduleFor returns the bound module for a phase" {
    var r = Route{
        .path = "/",
        .modules = &.{
            .{ .phase = .content, .module = "echo" },
            .{ .phase = .access, .module = "deny" },
        },
    };
    try testing.expectEqualStrings("echo", r.moduleFor(.content).?);
    try testing.expectEqualStrings("deny", r.moduleFor(.access).?);
    try testing.expectEqual(@as(?[]const u8, null), r.moduleFor(.log));
}

// ---- Comptime route trie ----

const trie_routes = [_]Route{
    .{ .path = "/", .match = .prefix },
    .{ .path = "/api", .match = .prefix },
    .{ .path = "/api/v1", .match = .prefix },
    .{ .path = "/api/v1/health", .match = .exact },
    .{ .path = "/static", .match = .exact },
    .{ .path = "/static/js", .match = .prefix },
};

const trie_targets = [_][]const u8{
    "/",
    "/x",
    "/api",
    "/api/",
    "/api/users",
    "/api/v1",
    "/api/v1/users",
    "/api/v1/health",
    "/api/v1/health/extra",
    "/static",
    "/static/",
    "/static/js",
    "/static/js/app.js",
    "/other",
    "",
    "/api/v1/health/deep/deeper",
};

test "comptime trie agrees with the linear matcher on shared prefixes" {
    const trie = buildTrie(&trie_routes);
    for (trie_targets) |t| {
        const want = matchRoutes(&trie_routes, t);
        const got = trieMatch(&trie, t, false);
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w.path, trie_routes[got.?].path);
        } else {
            try testing.expectEqual(@as(?u32, null), got);
        }
    }
}

test "trie: exact beats prefix at the same path" {
    const rs = [_]Route{
        .{ .path = "/a", .match = .prefix },
        .{ .path = "/a", .match = .exact },
    };
    const trie = buildTrie(&rs);
    try testing.expectEqual(@as(u32, 1), trieMatch(&trie, "/a", false).?);
    // The prefix route still serves longer targets.
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/a/b", false).?);
}

test "trie: longest prefix wins across a deep chain" {
    const rs = [_]Route{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/a", .match = .prefix },
        .{ .path = "/a/b", .match = .prefix },
        .{ .path = "/a/b/c/d", .match = .prefix },
    };
    const trie = buildTrie(&rs);
    const targets = [_][]const u8{ "/a/b/c/d/e", "/a/b/x", "/a/y", "/z" };
    for (targets) |t| {
        const want = matchRoutes(&rs, t).?;
        try testing.expectEqualStrings(want.path, rs[trieMatch(&trie, t, false).?].path);
    }
}

test "trie: exact does not match a longer target" {
    const rs = [_]Route{.{
        .path = "/only",
        .match = .exact,
    }};
    const trie = buildTrie(&rs);
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/only", false).?);
    try testing.expectEqual(@as(?u32, null), trieMatch(&trie, "/only/x", false));
}

test "trie: single-segment paths" {
    const rs = [_]Route{
        .{ .path = "/a", .match = .exact },
        .{ .path = "/b", .match = .prefix },
    };
    const trie = buildTrie(&rs);
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/a", false).?);
    try testing.expectEqual(@as(u32, 1), trieMatch(&trie, "/b", false).?);
    try testing.expectEqual(@as(?u32, null), trieMatch(&trie, "/c", false));
}

test "Router.match falls back to the linear matcher without a trie" {
    var rtr = Router{ .routes = &trie_routes };
    // "/nothing/here" matches the catch-all "/" prefix route.
    try testing.expectEqualStrings("/", rtr.match("/nothing/here", null).?.path);
    try testing.expectEqual(@as(?*const Route, null), rtr.match("", null));

    var with_trie = Router{ .routes = &trie_routes, .trie = buildTrie(&trie_routes) };
    try testing.expectEqualStrings("/api", with_trie.match("/api/users", null).?.path);
    try testing.expectEqual(@as(?*const Route, null), with_trie.match("", null));
}

// ---- Comptime response templates ----

test "template serialisation is byte-identical to the response builder" {
    const t = ResponseTemplate{
        .status = 200,
        .headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = "ok",
    };
    const fb = serializeResponseTemplate(t);

    // The reactor appends Connection + Content-Length + blank line, then the
    // body — exactly what the response builder emits for the same template.
    const suffix = "Connection: keep-alive\r\nContent-Length: 2\r\n\r\n";

    var resp = response_mod.Response.init(.ok);
    resp.setHeader("Content-Type", "text/plain");
    resp.setBody("ok");
    resp.setHeader("Connection", "keep-alive");

    const buffer_mod = @import("../net/buffer.zig");
    const buf = try buffer_mod.Buffer.init(testing.allocator);
    defer buf.deinit(testing.allocator);
    try resp.writeToBuffer(buf);

    const expected = buf.peek();
    try testing.expectEqual(fb.head.len + suffix.len + fb.body.len, expected.len);
    try testing.expectEqualStrings(fb.head, expected[0..fb.head.len]);
    try testing.expectEqualStrings(suffix, expected[fb.head.len .. fb.head.len + suffix.len]);
    try testing.expectEqualStrings(fb.body, expected[expected.len - fb.body.len ..]);
}

// ---- M-D: nginx location precedence ----

test "nginx precedence: exact beats regex beats longest prefix" {
    const routes = comptime [_]Route{
        .{ .path = "/static", .match = .exact },
        .{ .path = "^/static/.*", .match = .regex, .pattern_regex = regex_mod.compileRegex("^/static/.*") },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    const regex_tbl = buildRegexTable(&routes);
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = regex_tbl };
    // Exact /static wins.
    try testing.expectEqualStrings("/static", rtr.match("/static", null).?.path);
    // Regex ^/static/.* wins over the / prefix for /static/x.
    try testing.expectEqualStrings("^/static/.*", rtr.match("/static/x", null).?.path);
    // Longest plain prefix for /other.
    try testing.expectEqualStrings("/", rtr.match("/other", null).?.path);
}

test "nginx precedence: caret-prefix (^~) skips regex" {
    const routes = comptime [_]Route{
        .{ .path = "/static/", .match = .prefix, .no_regex = true },
        .{ .path = "^/static/.*", .match = .regex, .pattern_regex = regex_mod.compileRegex("^/static/.*") },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    const regex_tbl = buildRegexTable(&routes);
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = regex_tbl };
    // ^~ prefix wins immediately (regex skipped).
    try testing.expectEqualStrings("/static/", rtr.match("/static/x", null).?.path);
    // Plain prefix falls to regex.
    try testing.expectEqualStrings("/", rtr.match("/other", null).?.path);
}

test "nginx precedence: first regex in declaration order wins" {
    const routes = comptime [_]Route{
        .{ .path = "^/a/", .match = .regex, .pattern_regex = regex_mod.compileRegex("^/a/") },
        .{ .path = "^/a/b", .match = .regex, .pattern_regex = regex_mod.compileRegex("^/a/b") },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    const regex_tbl = buildRegexTable(&routes);
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = regex_tbl };
    // Both match /a/b/c; declaration order picks ^/a/.
    try testing.expectEqualStrings("^/a/", rtr.match("/a/b/c", null).?.path);
}

test "Router.match records captures into MatchCaps" {
    const routes = comptime [_]Route{
        .{ .path = "^/api/([0-9]+)/$", .match = .regex, .pattern_regex = regex_mod.compileRegex("^/api/([0-9]+)/$") },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    const regex_tbl = buildRegexTable(&routes);
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = regex_tbl };
    var caps = MatchCaps{ .subject = "" };
    const r = rtr.match("/api/42/", &caps).?;
    try testing.expectEqualStrings("^/api/([0-9]+)/$", r.path);
    try testing.expectEqual(@as(u8, 2), caps.count);
    // Whole match (group 0) spans the full match; groups below are exact.
    try testing.expectEqualStrings("/api/42/", caps.subject[caps.ranges[0].start..caps.ranges[0].end]);
    try testing.expectEqualStrings("42", caps.subject[caps.ranges[1].start..caps.ranges[1].end]);
    // Without caps the same route still matches.
    try testing.expectEqualStrings("^/api/([0-9]+)/$", rtr.match("/api/42/", null).?.path);
    // Non-matching target falls through to the prefix route.
    try testing.expectEqualStrings("/", rtr.match("/api/xyz/", null).?.path);
}

test "Router.match serves case-insensitive (~*) regex routes" {
    // ~* folds the subject to lowercase: the pattern is written lowercase.
    const routes = comptime [_]Route{
        .{ .path = "\\.png$", .match = .regex_ci, .pattern_regex = regex_mod.compileRegex("\\.png$") },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    const regex_tbl = buildRegexTable(&routes);
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = regex_tbl };
    try testing.expectEqualStrings("\\.png$", rtr.match("/img/photo.png", null).?.path);
    try testing.expectEqualStrings("\\.png$", rtr.match("/img/photo.PNG", null).?.path);
    try testing.expectEqualStrings("/", rtr.match("/img/photo.jpg", null).?.path);
}

test "Router.match skips regex routes without a compiled pattern" {
    const routes = [_]Route{
        .{ .path = "^/x/", .match = .regex, .pattern_regex = null },
        .{ .path = "/", .match = .prefix },
    };
    const trie = buildTrie(&routes);
    // Hand-built table (buildRegexTable would reject the null pattern).
    const tbl = [_]RegexRoute{.{ .re = undefined, .route = 0, .ci = false }};
    var rtr = Router{ .routes = &routes, .trie = trie, .regex_routes = &tbl };
    // The patternless regex route is skipped; the prefix serves.
    try testing.expectEqualStrings("/", rtr.match("/x/1", null).?.path);
    rtr.deinit(testing.allocator); // no-op, keeps the allocator param covered
}

test "matchRoutes skips regex routes in the linear fallback" {
    const rs = [_]Route{
        .{ .path = "^/api/", .match = .regex, .pattern_regex = null },
        .{ .path = "^/img/", .match = .regex_ci, .pattern_regex = null },
    };
    try testing.expectEqual(@as(?*const Route, null), matchRoutes(&rs, "/api/1"));
}

const distinct_routes = [_]Route{
    .{ .path = "/", .match = .prefix },
    .{ .path = "/", .match = .exact }, // same path, different kind: fine
    .{ .path = "/a", .match = .prefix },
};

test "same path with different kinds is not ambiguous" {
    // NOTE: do not call comptimeCheckAmbiguous directly here. A direct
    // call from test context misfires @compileError for this table in
    // this Zig snapshot (pairwise dump proves every guard is false), while
    // the identical call inside buildTrieImpl's explicit `comptime` block
    // evaluates correctly. All production tables go through buildTrie, so
    // only the direct-call shape is affected. This test pins the
    // production path: same path + different kind builds fine.
    const trie = buildTrie(&distinct_routes);
    try testing.expect(trie.nodes.len > 0);
    // And the routes still match with exact-beats-prefix semantics.
    var rtr = Router{ .routes = &distinct_routes, .trie = trie };
    try testing.expectEqualStrings("/", rtr.match("/", null).?.path);
}

test "Upstream.makeSockaddr parses IPv4 literals and rejects the rest" {
    const good = Upstream.makeSockaddr("127.0.0.1", 9000).?;
    try testing.expectEqual(std.posix.AF.INET, good.family);
    try testing.expectEqual(@as(u16, 9000), std.mem.readInt(u16, good.data[0..2], .big));
    try testing.expectEqual(@as(u32, 0x7F000001), std.mem.readInt(u32, good.data[2..6], .big));
    try testing.expect(Upstream.makeSockaddr("10.0.0", 80) == null); // too few
    try testing.expect(Upstream.makeSockaddr("10.0.0.1.5", 80) == null); // too many
    try testing.expect(Upstream.makeSockaddr("10.0.x.1", 80) == null); // non-numeric
    try testing.expect(Upstream.makeSockaddr("10.0.0.300", 80) == null); // out of range
    try testing.expect(Upstream.makeSockaddr("", 80) == null);
    try testing.expect(Upstream.makeSockaddr("example.com", 80) == null);
}

test "template serialisation covers statuses and header lists" {
    const t = comptime ResponseTemplate{
        .status = 301,
        .headers = &.{
            .{ .name = "Location", .value = "/new" },
            .{ .name = "Cache-Control", .value = "no-cache" },
        },
        .body = "",
    };
    const fb = serializeResponseTemplate(t);
    try testing.expectEqualStrings("HTTP/1.1 301 Moved Permanently\r\nLocation: /new\r\nCache-Control: no-cache\r\n", fb.head);
    try testing.expectEqualStrings("", fb.body);
}

test "named locations are excluded from path matching" {
    const rs = [_]Route{
        .{ .path = "/", .match = .prefix },
        .{ .path = "", .name = "@fallback", .match = .prefix },
    };
    // Path matching never lands on the named route (its empty path would
    // otherwise swallow every request).
    try testing.expectEqual(&rs[0], matchRoutes(&rs, "/anything").?);
    const trie = buildTrie(&rs);
    var rt = Router{ .routes = &rs, .trie = trie, .regex_routes = &.{} };
    try testing.expectEqual(&rs[0], rt.match("/x", null).?);
    // Named lookup is the only way in.
    try testing.expectEqual(&rs[1], rt.matchNamed("@fallback").?);
    try testing.expect(rt.matchNamed("@missing") == null);
}

test "internal routes are invisible to external matching, reachable internally" {
    const rs = [_]Route{
        .{ .path = "/", .match = .prefix },
        .{ .path = "/private", .match = .prefix, .internal = true },
        .{ .path = "/private/exact", .match = .exact, .internal = true },
    };
    var rt = Router{ .routes = &rs, .trie = buildTrie(&rs), .regex_routes = &.{} };
    // External: the internal prefixes are skipped; the public / serves.
    try testing.expectEqualStrings("/", rt.match("/private/x", null).?.path);
    try testing.expectEqualStrings("/", rt.match("/private/exact", null).?.path);
    // External: with no public match at all -> no route.
    const only_internal = [_]Route{.{ .path = "/secret", .match = .prefix, .internal = true }};
    var rt2 = Router{ .routes = &only_internal, .trie = buildTrie(&only_internal), .regex_routes = &.{} };
    try testing.expect(rt2.match("/secret/x", null) == null);
    // Internal redirects see them.
    try testing.expectEqualStrings("/private", rt.matchAt("/private/x", null, true).?.path);
    try testing.expectEqualStrings("/private/exact", rt.matchAt("/private/exact", null, true).?.path);
    // Linear fallback (no trie) honours the same rule.
    try testing.expectEqualStrings("/", matchRoutes(&rs, "/private/x").?.path);
    try testing.expectEqualStrings("/private", matchRoutesAt(&rs, "/private/x", true).?.path);
}
