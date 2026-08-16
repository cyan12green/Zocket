const std = @import("std");
const posix = std.posix;
const phase_mod = @import("phase.zig");
const registry = @import("registry.zig");
const response_mod = @import("../http/response.zig");
const ct_pool = @import("../ct_pool.zig");
const vars = @import("vars.zig");

pub const Phase = phase_mod.Phase;
pub const Frag = vars.Frag;
pub const VarId = vars.VarId;
pub const SetVar = vars.SetVar;
pub const LogFormat = vars.LogFormat;
pub const ProxyHeader = vars.ProxyHeader;
pub const CVHeader = vars.CVHeader;
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
    match: Match = .prefix,
    modules: []const ModuleBinding = &.{},
    /// Comptime-specialised dispatch function (Milestone 7). Set for
    /// struct-literal configs, where the whole route table is comptime-known;
    /// null for JSON-loaded routes, which use the loop-walk fallback.
    dispatch: ?registry.DispatchFn = null,
    /// Default cache lifetime in seconds (Milestone 9): the cache-header
    /// module emits `Cache-Control: max-age=N` from this. 0 = no-cache.
    max_age_seconds: u32 = 0,
    /// Static-file serving (Milestone 10): root directory on disk; optional
    /// `index` file for directories; `autoindex` to list them. `embed` names
    /// a file baked into .rodata at compile time (`embed_bytes`).
    root: ?[]const u8 = null,
    /// Resolved realpath of `root`, computed once at JSON config load
    /// (nginx-style: it never realpaths per request either). Null for
    /// comptime/struct-literal routes (immutable) and JSON routes without a
    /// root; the static module falls back to a per-request realpath then.
    root_real: ?[]const u8 = null,
    /// O_PATH|O_DIRECTORY fd of `root`, opened once at JSON config load
    /// (Milestone 14 follow-up): the static module resolves targets against
    /// it with openat2(RESOLVE_BENEATH), one syscall with kernel-enforced
    /// containment instead of a per-request open + realpath pair. -1 when
    /// unset; the legacy per-request path is used then.
    root_fd: posix.fd_t = -1,
    index: ?[]const u8 = null,
    autoindex: bool = false,
    embed: ?[]const u8 = null,
    embed_bytes: []const u8 = &.{},
    /// Fixed-response template (Milestone 11): a route with `response` (and
    /// no modules) is served from the pre-serialised `response_bytes` — no
    /// pipeline, no response builder. Routes with modules keep the pipeline;
    /// the template is applied when nothing claims the request.
    response: ?ResponseTemplate = null,
    response_bytes: ?FastResponse = null,
    /// Reverse proxy (Milestone 12): upstream backends, load-balance
    /// strategy and passive health-check parameters.
    upstreams: []const Upstream = &.{},
    balance: Balance = .round_robin,
    max_fails: u32 = 3,
    fail_timeout_seconds: u32 = 30,
    /// Route opt-in for chunked transfer encoding (HTTP/1.1 only): responses
    /// on this route are framed as a single chunk with
    /// `Transfer-Encoding: chunked` instead of Content-Length. Off by
    /// default — Content-Length is unambiguous and lets the response flush
    /// as one writev; enable for routes whose body size is not known in
    /// advance or when streaming semantics are wanted. Ignored by h2.
    chunked: bool = false,

    /// `^~` prefix flag (still .prefix; only precedence differs, M-D).
    no_regex: bool = false,
    /// Comptime-compiled NFA for .regex / .regex_ci locations (M-D).
    pattern_regex: ?Regex = null,
    /// User variables declared with `set` in this location (M-C).
    set_vars: []const SetVar = &.{},
    /// Dynamic response template (return/add_header with variables, M-B).
    response_cv: ?ResponseTemplateCV = null,
    /// proxy_set_header overrides (M-E).
    proxy_headers: []const ProxyHeader = &.{},
    /// Index into Config.log_formats; null = none (off). The access_log
    /// module reads it; defaults to index 0 (the `combined` default) when
    /// the route binds `log access_log;` and no `access_log` directive is
    /// present.
    log_format: ?usize = null,

    /// The module name bound to `phase` on this route, if any.
    pub fn moduleFor(self: *const Route, phase: Phase) ?[]const u8 {
        for (self.modules) |b| {
            if (b.phase == phase) return b.module;
        }
        return null;
    }
};

/// Prefix/exact route matching. An exact match beats every prefix; otherwise
/// the longest matching prefix wins. `matchRoutes` is called from the
/// `find_config` phase of the pipeline.
pub fn matchRoutes(route_list: []const Route, target: []const u8) ?*const Route {
    var best: ?*const Route = null;
    for (route_list) |*r| {
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

/// Sentinel: no route is bound at a trie node.
pub const no_route = std.math.maxInt(u32);

/// One header of a fixed-response template.
pub const TemplateHeader = struct { name: []const u8, value: []const u8 };

/// Load-balance strategy for a proxy route (Milestone 12). The dispatch is a
/// comptime switch: dead strategies are eliminated from the binary.
pub const Balance = enum {
    round_robin,
    least_connections,
    ip_hash,

    pub fn parse(s: []const u8) ?Balance {
        if (std.mem.eql(u8, s, "round_robin")) return .round_robin;
        if (std.mem.eql(u8, s, "least_connections")) return .least_connections;
        if (std.mem.eql(u8, s, "ip_hash")) return .ip_hash;
        return null;
    }
};

/// One proxy backend (Milestone 12). The `sockaddr` is pre-computed: at
/// compile time for struct-literal configs (host is a comptime IP literal —
/// no DNS, no runtime byte-swapping), at startup for JSON configs.
pub const Upstream = struct {
    host: []const u8,
    port: u16,
    sockaddr: std.posix.sockaddr = .{ .family = 0, .data = [_]u8{0} ** 14 },

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
            .data = [_]u8{0} ** 14,
        };
        std.mem.writeInt(u16, addr.data[0..2], port, .big);
        std.mem.writeInt(u32, addr.data[2..6], std.mem.readInt(u32, &octets, .big), .big);
        return addr;
    }
};

/// A fixed response served from pre-serialised bytes (Milestone 11):
/// redirects, healthchecks, error pages.
pub const ResponseTemplate = struct {
    status: u16 = 200,
    headers: []const TemplateHeader = &.{},
    body: []const u8 = &.{},
    /// Comptime pre-compression (M9 Part B) is DEFERRED: the runtime flate
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
                "see docs/ROADMAP.md M9 Part B");
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
            },
            .exact => {
                if (n.exact_route != no_route) return error.AmbiguousRoutes;
                n.exact_route = @intCast(ri);
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
    // trie-node; large configs (DM2 embedded configs) exceed the default
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
pub fn trieMatch(trie: *const Trie, target: []const u8) ?u32 {
    var node: u32 = 0;
    var best: u32 = no_route;
    if (trie.nodes[0].best_prefix != no_route) best = trie.nodes[0].best_prefix;
    var consumed = true;
    for (target) |byte| {
        const child = findEdge(trie, node, byte) orelse {
            consumed = false;
            break;
        };
        node = child;
        const n = trie.nodes[node];
        if (n.best_prefix != no_route) best = n.best_prefix;
    }
    if (consumed and trie.nodes[node].exact_route != no_route) {
        return trie.nodes[node].exact_route;
    }
    return if (best != no_route) best else null;
}

/// A built route table: the routes plus their trie. `match` is the lookup the
/// pipeline's find_config phase uses. With an empty trie it falls back to the
/// linear `matchRoutes` (plain `Server.init` / direct test usage).
pub const Router = struct {
    routes: []const Route = &.{},
    trie: Trie = .{},

    pub fn match(self: *const Router, target: []const u8) ?*const Route {
        if (self.trie.nodes.len == 0) return matchRoutes(self.routes, target);
        const idx = trieMatch(&self.trie, target) orelse return null;
        return &self.routes[idx];
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

// ---- Milestone 7: comptime route trie ----

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
        const got = trieMatch(&trie, t);
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
    try testing.expectEqual(@as(u32, 1), trieMatch(&trie, "/a").?);
    // The prefix route still serves longer targets.
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/a/b").?);
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
        try testing.expectEqualStrings(want.path, rs[trieMatch(&trie, t).?].path);
    }
}

test "trie: exact does not match a longer target" {
    const rs = [_]Route{.{
        .path = "/only",
        .match = .exact,
    }};
    const trie = buildTrie(&rs);
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/only").?);
    try testing.expectEqual(@as(?u32, null), trieMatch(&trie, "/only/x"));
}

test "trie: single-segment paths" {
    const rs = [_]Route{
        .{ .path = "/a", .match = .exact },
        .{ .path = "/b", .match = .prefix },
    };
    const trie = buildTrie(&rs);
    try testing.expectEqual(@as(u32, 0), trieMatch(&trie, "/a").?);
    try testing.expectEqual(@as(u32, 1), trieMatch(&trie, "/b").?);
    try testing.expectEqual(@as(?u32, null), trieMatch(&trie, "/c"));
}

test "Router.match falls back to the linear matcher without a trie" {
    var rtr = Router{ .routes = &trie_routes };
    // "/nothing/here" matches the catch-all "/" prefix route.
    try testing.expectEqualStrings("/", rtr.match("/nothing/here").?.path);
    try testing.expectEqual(@as(?*const Route, null), rtr.match(""));

    var with_trie = Router{ .routes = &trie_routes, .trie = buildTrie(&trie_routes) };
    try testing.expectEqualStrings("/api", with_trie.match("/api/users").?.path);
    try testing.expectEqual(@as(?*const Route, null), with_trie.match(""));
}

// ---- Milestone 11: comptime response templates ----

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
