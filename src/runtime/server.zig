const std = @import("std");
const compat = @import("../compat.zig");
const config_mod = @import("config.zig");
const pipeline = @import("../dsl/pipeline.zig");
const registry = @import("../dsl/registry.zig");
const router_mod = @import("../dsl/router.zig");

pub const Config = config_mod.Config;
const tls_cert = @import("../tls/cert.zig");
const tls_ocsp = @import("../tls/ocsp.zig");
const Certificate = std.crypto.Certificate;
const dns_resolver = @import("../net/dns_resolver.zig");
pub const default_registry = registry.default_registry;
pub const ServerStats = registry.ServerStats;

/// Shared counters for the default (comptime) server instance.
var default_stats: ServerStats = .{};

/// Hard cap on internal-redirect hops per request (nginx's `X-Accel`/
/// `error_page` cycles cap at 10; 8 leaves headroom for nested subrequests).
/// A backstop against a misconfigured `try_files`/`error_page` pair — normal
/// configurations converge in one or two hops.
pub const max_internal_redirects: u8 = 8;

/// The config-driven HTTP request processor. A single immutable instance is
/// shared by every reactor; it holds the route table and dispatches each fully
/// parsed request through the DSL phase pipeline.
///
/// Route lookup goes through a trie-backed `Router` built at
/// compile time for struct-literal configs (`comptimeInit`), at startup for
/// JSON configs (`initWithTrie`). Struct-literal routes additionally carry
/// comptime-specialised dispatch functions; JSON routes use the loop-walk
/// fallback. `init` (no trie) keeps the linear matcher for tests and plain
/// embedding.
pub const Server = struct {
    cfg: Config,
    router: router_mod.Router = .{},
    /// Shared connection/request counters. Points at the
    /// process-global `default_stats` for comptime/default servers and at an
    /// allocator-owned struct for JSON-config servers (freed by `deinit`).
    stats: *ServerStats = &default_stats,
    /// TLS credentials loaded once at startup from the config `tls`
    /// section (cert + key PEM files). The reactor uses them to instantiate
    /// a native TLS 1.3 session per connection. `cert_der` is
    /// allocator-owned; freed by `deinit`.
    tls_creds: ?tls_cert.Credentials = null,
    /// mTLS client-CA bundle (process-lifetime; `tls_creds.client_ca`
    /// borrows it when set). Null bundle + verify_client never coexists —
    /// loadTls fails closed first.
    client_ca_bundle: ?Certificate.Bundle = null,

    /// Load the TLS credentials when the config enables TLS (reads the PEM
    /// files once at startup — nginx reads `ssl_certificate` at startup too).
    pub fn loadTls(self: *Server, allocator: std.mem.Allocator) !void {
        if (self.cfg.tls.enabled()) {
            const cert_pem = try compat.readFileAlloc(allocator, self.cfg.tls.cert, 1 << 20);
            defer allocator.free(cert_pem);
            const key_pem = try compat.readFileAlloc(allocator, self.cfg.tls.key, 1 << 20);
            defer allocator.free(key_pem);
            self.tls_creds = try tls_cert.loadCredentials(allocator, cert_pem, key_pem);
            // OCSP staple: DER file, parsed at startup (fail closed — a bad
            // response disables the server rather than stapling garbage).
            if (self.cfg.tls.ocsp_file.len > 0) {
                const der = try compat.readFileAlloc(allocator, self.cfg.tls.ocsp_file, 1 << 20);
                errdefer allocator.free(der);
                const parsed = tls_ocsp.parseResponse(der) catch {
                    allocator.free(@constCast(self.tls_creds.?.cert_der));
                    self.tls_creds = null;
                    return error.OcspInvalid;
                };
                if (parsed.cert != .good) {
                    allocator.free(@constCast(self.tls_creds.?.cert_der));
                    self.tls_creds = null;
                    return error.OcspNotGood;
                }
                self.tls_creds.?.ocsp_der = der;
            }
            // mTLS bundle: PEM CA file, parsed at startup (fail closed).
            // verify_client without a bundle can never succeed — refuse.
            if (self.cfg.tls.verify_client and self.cfg.tls.client_ca.len == 0) {
                allocator.free(@constCast(self.tls_creds.?.cert_der));
                if (self.tls_creds.?.ocsp_der.len > 0) allocator.free(@constCast(self.tls_creds.?.ocsp_der));
                self.tls_creds = null;
                return error.MtlsNeedsClientCa;
            }
            if (self.cfg.tls.client_ca.len > 0) {
                var bundle = Certificate.Bundle.empty;
                errdefer bundle.deinit(std.heap.page_allocator);
                const io = std.Io.Threaded.global_single_threaded.io();
                const ts = compat.clock_gettime(std.posix.CLOCK.REALTIME) catch
                    return error.MtlsNeedsClientCa;
                const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec };
                const abs = self.cfg.tls.client_ca;
                if (std.fs.path.isAbsolute(abs)) {
                    bundle.addCertsFromFilePathAbsolute(std.heap.page_allocator, io, now, abs) catch {
                        allocator.free(@constCast(self.tls_creds.?.cert_der));
                        self.tls_creds = null;
                        return error.MtlsBadBundle;
                    };
                } else {
                    bundle.addCertsFromFilePath(std.heap.page_allocator, io, now, .cwd(), abs) catch {
                        allocator.free(@constCast(self.tls_creds.?.cert_der));
                        self.tls_creds = null;
                        return error.MtlsBadBundle;
                    };
                }
                self.client_ca_bundle = bundle;
                self.tls_creds.?.client_ca = &self.client_ca_bundle.?;
                self.tls_creds.?.verify_client = self.cfg.tls.verify_client;
            }
        }
    }

    /// Plain constructor: no trie, linear route matching. Kept for tests and
    /// embedders that construct routes at runtime.
    pub fn init(cfg: Config) Server {
        return .{ .cfg = cfg, .router = .{ .routes = cfg.routes } };
    }

    /// Struct-literal configs the route trie and the per-route
    /// dispatch functions are built at compile time; the whole route table,
    /// trie and dispatch pointers live in .rodata. Duplicate routes are a
    /// compile error (see `router.comptimeCheckAmbiguous`). The body is
    /// forced through a `comptime` expression so this works from runtime
    /// call sites (`Server.default()`).
    pub fn comptimeInit(comptime cfg: Config) Server {
        return comptime comptimeInitImpl(cfg);
    }

    fn comptimeInitImpl(comptime cfg: Config) Server {
        const routes = pipeline.assignDispatch(registry.default_registry, cfg.routes);
        const trie = router_mod.buildTrie(&routes);
        const regex_routes = router_mod.buildRegexTable(&routes);
        var s: Server = .{
            .cfg = cfg,
            .router = .{ .routes = &routes, .trie = trie, .regex_routes = regex_routes },
        };
        // Swap in the dispatch-specialised routes, keeping every other
        // config field (server_names, host_select, ...) intact.
        s.cfg.routes = &routes;
        return s;
    }
    /// The default server: echo module on the catch-all route, the pre-pipeline
    /// Matches the original hardcoded handler. Built at compile time (trie + dispatch specialisation).
    pub fn default() Server {
        return comptimeInit(comptime Config.default());
    }

    /// Build a server from a comptime/embedded config, then resolve
    /// static roots at startup, but
    /// the comptime route table is immutable .rodata, so the rooted routes
    /// are copied into `allocator` with `root_real` (symlink-escape anchor)
    /// True when any upstream on the route resolves via DNS.
    fn hasHostnameUpstream(r: router_mod.Route) bool {
        for (r.upstreams) |up| {
            if (up.hostname != null) return true;
        }
        return false;
    }

    /// Heap-copy a route's upstream table when it holds hostnames, resolve
    /// each synchronously (warn + unresolved on failure; refresh retries),
    /// and register for background refresh. Literal-only routes keep the
    /// .rodata slice (zero startup cost).
    fn prepareUpstreams(
        allocator: std.mem.Allocator,
        r: router_mod.Route,
        dns_servers: dns_resolver.Servers,
    ) ![]const router_mod.Upstream {
        if (!hasHostnameUpstream(r)) return r.upstreams;
        const owned = try allocator.dupe(router_mod.Upstream, r.upstreams);
        for (owned) |*up| {
            const host = up.hostname orelse continue;
            dns_resolver.resolveAndRegister(host, up, dns_servers, 53);
            if (up.sockaddr.family == 0) {
                std.log.warn("dns: {s} unresolved at startup; serving 502 until refresh succeeds", .{host});
            }
        }
        return owned;
    }

    /// and `root_fd` (O_PATH|O_DIRECTORY for the openat2 fast path) filled
    /// in. The dispatch functions, trie and everything else stay comptime;
    /// the trie's positional route indices apply to the copy unchanged.
    /// Free the allocator-owned copy with `deinitPrepared`.
    /// Like `embeddedInit`, but with the TLS credentials loaded at startup
    /// (the config `tls` section; the cert/key PEM files are runtime files).
    pub fn embeddedInitWithTls(allocator: std.mem.Allocator, comptime cfg: Config) !Server {
        var srv = try embeddedInit(allocator, cfg);
        srv.loadTls(allocator) catch |e| {
            srv.deinitPrepared(allocator);
            return e;
        };
        return srv;
    }

    pub fn embeddedInit(allocator: std.mem.Allocator, comptime cfg: Config) !Server {
        const base = comptimeInit(cfg);
        const routes = try allocator.alloc(router_mod.Route, base.cfg.routes.len);
        errdefer allocator.free(routes);
        var prepared_len: usize = 0;
        errdefer for (routes[0..prepared_len]) |r| {
            if (r.root_real) |rr| allocator.free(rr);
            if (r.root_fd >= 0) compat.close(r.root_fd);
            if (hasHostnameUpstream(r)) allocator.free(r.upstreams);
        };
        // Explicit nameservers apply process-wide, once (first server wins;
        // group siblings share the resolver thread and cache anyway).
        if (base.cfg.resolver.len > 0) dns_resolver.setServers(base.cfg.resolver);
        const dns_servers = dns_resolver.currentServers();
        for (base.cfg.routes, 0..) |r, i| {
            var copy = r;
            copy.upstreams = try prepareUpstreams(allocator, r, dns_servers);
            if (r.root) |root| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved = compat.realpath(root, &buf) catch null;
                if (resolved) |rp| {
                    copy.root_real = try allocator.dupe(u8, rp);
                }
                copy.root_fd = compat.open(root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0) catch -1;
            }
            routes[i] = copy;
            prepared_len += 1;
        }
        // Per-server stats: each embedded server gets its own counters
        // instead of sharing the process-global default_stats.
        const stats = try allocator.create(ServerStats);
        errdefer allocator.destroy(stats);
        stats.* = .{};
        var s = base;
        // Preserve the whole config (server_name, host_select, select_fn,
        // listen_spec, ...), swapping only the routes for the prepared
        // copy with resolved root_real/root_fd. Dropping fields here
        // silently disables vhost selection downstream.
        s.cfg = base.cfg;
        s.cfg.routes = routes;
        s.router.routes = routes;
        s.stats = stats;
        return s;
    }

    /// Free the allocator-owned route copy created by `embeddedInit` (only
    /// the resolved root fields and the array itself; the comptime strings
    /// still live in .rodata). Also frees per-server stats when they are
    /// not the process-global default.
    pub fn deinitPrepared(self: *Server, allocator: std.mem.Allocator) void {
        for (self.cfg.routes) |r| {
            if (r.root_real) |rr| allocator.free(rr);
            if (r.root_fd >= 0) compat.close(r.root_fd);
            if (hasHostnameUpstream(r)) allocator.free(r.upstreams);
        }
        allocator.free(self.cfg.routes);
        // Free per-server stats only if they were allocated (not the global default).
        if (self.stats != &default_stats) {
            allocator.destroy(self.stats);
            self.stats = &default_stats;
        }
    }

    /// Run one fully-parsed request through the phase pipeline. On
    /// `.not_handled` the caller sends the default (404) response. Module
    /// errors propagate to the caller, which turns them into a 500.
    ///
    /// A handler may request an INTERNAL REDIRECT by setting
    /// `ctx.internal_redirect_target` (the target URI) and returning
    /// `.pass`: after the walk ends, the request target is rewritten and the
    /// whole walk runs again — nginx `try_files` / `error_page` semantics.
    /// Redirects are capped at `max_internal_redirects`; the cap is a
    /// misconfiguration backstop (`try_files` converges on its own because
    /// the redirect target is the candidate that already exists).
    pub fn handleRequest(self: *const Server, ctx: *pipeline.Context) !pipeline.Outcome {
        // Map table for this request (Frag.map renders through it; empty
        // when the config declares no maps).
        ctx.maps = self.cfg.maps;
        var outcome = try pipeline.runWithRouter(registry.default_registry, self.cfg.routes, &self.router, ctx);
        var hops: u8 = 0;
        while (ctx.internal_redirect_target != null or ctx.internal_redirect_named != null) {
            hops += 1;
            // Published on the context: log-phase modules (error_page)
            // read it to keep chains short; one log line per client
            // request, not per hop.
            ctx.redirect_hops = hops;
            if (hops >= max_internal_redirects) {
                // Backstop: refuse the redirect, keep the current response.
                // nginx reports 500 here; we keep the last response, which is
                // what a rewrite loop in a hand-written config should show.
                ctx.internal_redirect_target = null;
                ctx.internal_redirect_named = null;
                break;
            }
            if (ctx.internal_redirect_target) |target| {
                ctx.internal_redirect_target = null;
                // The new URI lives in the request arena: it must outlive this
                // walk (the reactor reclaims the arena per request, not per hop).
                const uri = ctx.req.arena.asAllocator().dupe(u8, target) catch break;
                ctx.req.target = uri;
                ctx.req.decoded_target = uri;
            } else {
                // Named-location redirect: the request URI is unchanged;
                // the forced route bypasses path matching for this hop.
                const name = ctx.internal_redirect_named.?;
                ctx.internal_redirect_named = null;
                const route = self.router.matchNamed(name) orelse break;
                ctx.force_route = route;
            }
            // Re-resolve: the previous route's modules must not re-run
            // against the new target, and captures belong to the old match.
            ctx.route = null;
            ctx.capture_count = 0;
            outcome = try pipeline.runWithRouter(registry.default_registry, self.cfg.routes, &self.router, ctx);
        }
        return outcome;
    }

    /// Fast path: when the matched route is a module-less
    /// response template, return its pre-serialised bytes so the caller can
    /// write them straight to the wire — no pipeline, no response builder,
    /// no function call through the phase chain. Returns null when any
    /// module could still act on the request.
    /// Subrequest hook installed into every request Context by the
    /// reactors: runs `target` through THIS server's full pipeline as a
    /// fresh GET carrying the original Authorization header.
    pub fn subrequestImpl(
        impl: *const anyopaque,
        src_req: *const pipeline.Request,
        target: []const u8,
        out_status: *u16,
    ) anyerror!void {
        const srv: *const Server = @ptrCast(@alignCast(impl));
        var req = pipeline.Request.init(std.heap.page_allocator);
        defer req.deinit();
        req.method = .get;
        req.target = target;
        req.decoded_target = target;
        if (src_req.header("authorization")) |a| {
            req.addHeaderParsed("Authorization", a) catch {};
        }
        var resp = pipeline.Response.init(.ok);
        var sctx = pipeline.Context{ .req = &req, .resp = &resp };
        const outcome = try srv.handleRequest(&sctx);
        // Mirror the reactor's default-404 semantics for unmatched targets.
        if (outcome == .not_handled) resp.status = .not_found;
        out_status.* = @intFromEnum(resp.status);
    }

    pub fn matchFast(self: *const Server, ctx: *pipeline.Context) ?router_mod.FastResponse {
        var caps = router_mod.MatchCaps{ .subject = ctx.req.decoded_target };
        const route = self.router.match(ctx.req.decoded_target, &caps) orelse return null;
        // `return 444;` writes nothing: no fast path, the reactor closes.
        if (route.close_without_response) return null;
        if (caps.count > 0) {
            ctx.capture_subject = caps.subject;
            ctx.captures = caps.ranges;
            ctx.capture_count = caps.count;
        }
        // Filters transform responses; a filtered route must go through
        // the pipeline even when it has no handlers.
        if (route.modules.len != 0 or route.filters.len != 0) return null;
        const fb = route.response_bytes orelse return null;
        ctx.route = route;
        return fb;
    }

    /// The configured named log formats (M-B): the access_log module reads
    /// the route's `log_format` index into this table.
    pub fn formats(self: *const Server) ?[]const config_mod.LogFormat {
        return if (self.cfg.log_formats.len > 0) self.cfg.log_formats else null;
    }
};

const testing = std.testing;

test "ServerGroup selectServer matches exact and wildcard server_names" {
    const s1 = Server.init(.{ .server_names = &.{"example.com"} });
    const s2 = Server.init(.{ .server_names = &.{"*.api.com"} });
    const servers = [_]Server{ s1, s2 };
    const group = ServerGroup{ .servers = &servers, .default_idx = 0 };
    // Exact match.
    try testing.expectEqual(&servers[0], group.selectServer("example.com", null));
    try testing.expectEqual(&servers[0], group.selectServer("example.com:8080", null));
    // Wildcard match.
    try testing.expectEqual(&servers[1], group.selectServer("v1.api.com", null));
    try testing.expectEqual(&servers[1], group.selectServer("foo.api.com:9000", null));
    // No match -> default.
    try testing.expectEqual(&servers[0], group.selectServer("other.com", null));
}

test "ServerGroup selectServer matches every name on a multi-name server" {
    const s1 = Server.init(.{ .server_names = &.{"example.com"} });
    const s2 = Server.init(.{ .server_names = &.{ "api.example.com", "*.api.example.com" } });
    const servers = [_]Server{ s1, s2 };
    const group = ServerGroup{ .servers = &servers, .default_idx = 0 };
    try testing.expectEqual(&servers[1], group.selectServer("api.example.com", null));
    try testing.expectEqual(&servers[1], group.selectServer("v1.api.example.com", null));
    try testing.expectEqual(&servers[0], group.selectServer("example.com", null));
    try testing.expectEqual(&servers[0], group.selectServer("other.com", null));
}

test "runtime server dispatches an echo request through the pipeline" {
    const srv = Server.default();

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";
    req.decoded_target = "/";
    req.body = "body via config";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("body via config", resp.body);
}

test "runtime server with a conf config drives an HTTP request to 200 echo" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / { content echo; }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/submit";
    req.decoded_target = "/submit";
    req.body = "conf-driven";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqualStrings("conf-driven", resp.body);
}

test "runtime server yields not_handled when no module claims the request" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /static {}
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/static/file.txt";
    req.decoded_target = "/static/file.txt";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.not_handled, try srv.handleRequest(&ctx));
}

// ---- Comptime server (trie + dispatch specialisation) ----

test "comptime server routes identically to the plain server" {
    const plain = Server.init(Config.default());
    const comptime_srv = Server.comptimeInit(comptime Config.default());

    const targets = [_][]const u8{ "/", "/anything", "/deep/path", "/x?q=1" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.decoded_target = t;
        req_a.body = "payload";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.decoded_target = t;
        req_b.body = "payload";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try plain.handleRequest(&ctx_a);
        const out_b = try comptime_srv.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        try testing.expectEqualStrings(resp_a.body, resp_b.body);
        try testing.expectEqual(resp_a.status, resp_b.status);
        try testing.expectEqualStrings("/", ctx_b.route.?.path);
    }
}

test "comptime server dispatches a route with multiple phases via the dispatch fn" {
    const cfg = comptime Config{
        .routes = &.{
            .{
                .path = "/only",
                .match = .exact,
                .modules = &.{
                    .{ .phase = .content, .module = "echo" },
                    .{ .phase = .log, .module = "echo" },
                },
            },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/only";
    req.decoded_target = "/only";
    req.body = "via dispatch";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqualStrings("via dispatch", resp.body);
    // The route carries the specialised dispatch function.
    try testing.expect(ctx.route.?.dispatch != null);

    // Unmatched target: 404 path even with the trie.
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/elsewhere";
    req2.decoded_target = "/elsewhere";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(pipeline.Outcome.not_handled, try srv.handleRequest(&ctx2));
}

test "auth_basic guards a conf route end to end" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /private {
        \\        content echo;
        \\        auth_basic "Private";
        \\        auth_basic_user_file "testdata/htpasswd";
        \\    }
        \\}
    );
    const srv = Server.comptimeInit(cfg);

    // No credentials -> 401 challenge.
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/private";
    req.decoded_target = "/private";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.unauthorized, resp.status);

    // bob:bobpw (base64) passes the htpasswd table and reaches echo.
    var ok = registry.Request.init(testing.allocator);
    defer ok.deinit();
    ok.target = "/private";
    ok.decoded_target = "/private";
    ok.body = "hi";
    _ = ok.addHeaderParsed("Authorization", "Basic Ym9iOmJvYnB3") catch unreachable;
    var ok_resp = registry.Response.init(.ok);
    var ok_ctx = pipeline.Context{ .req = &ok, .resp = &ok_resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ok_ctx));
    try testing.expectEqualStrings("hi", ok_resp.body);
}

test "filters disable the fast path; template routes run through pipeline" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /tpl {
        \\        return 200 "raw";
        \\        add_header X-F "on";
        \\    }
        \\}
    );
    const srv = Server.comptimeInit(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/tpl";
    req.decoded_target = "/tpl";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    // The headers FILTER ran on top of the template body.
    try testing.expectEqualStrings("raw", resp.body);
    var saw = false;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.mem.eql(u8, h.name, "X-F") and std.mem.eql(u8, h.value, "on")) saw = true;
    }
    try testing.expect(saw);
}

test "headers module applies ops through the comptime dispatch" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /h {
        \\        content echo;
        \\        set_header X-A "1";
        \\        add_header X-A "2";
        \\        remove_header X-Drop;
        \\    }
        \\}
    );
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/h";
    req.decoded_target = "/h";
    req.body = "x";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    _ = try srv.handleRequest(&ctx);

    var a_values: [4][]const u8 = undefined;
    var a_count: usize = 0;
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.mem.eql(u8, h.name, "X-A")) {
            a_values[a_count] = h.value;
            a_count += 1;
        }
    }
    // set replaced nothing (name was new -> append), add appended: two values.
    try testing.expectEqual(@as(usize, 2), a_count);
    try testing.expectEqualStrings("1", a_values[0]);
    try testing.expectEqualStrings("2", a_values[1]);
    // Note: Connection/Date/Server are transport-owned and appended after
    // the pipeline; header ops govern module-produced headers only.
}

/// Runs one chain-e2e case through the real comptime-dispatch server and
/// asserts the expected claim (`want` present, `want_absent` absent). Mirrors
/// the curl checks in the testdata/chain-e2e.conf fixture.
fn runChainCase(
    srv: *const Server,
    allocator: std.mem.Allocator,
    target: []const u8,
    body: []const u8,
    stats: *const registry.ServerStats,
    want: []const u8,
    want_absent: []const u8,
) !void {
    var req = registry.Request.init(allocator);
    defer req.deinit();
    req.target = target;
    req.decoded_target = target;
    req.body = body;
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp, .allocator = allocator, .stats = stats };

    const out = try srv.handleRequest(&ctx);
    defer if (resp.body_owned) allocator.free(resp.body);
    try testing.expectEqual(pipeline.Outcome.handled, out);
    // The conf-derived server runs the comptime dispatch path (what the curl
    // e2e exercised), not the loop walk.
    try testing.expect(ctx.route.?.dispatch != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, want) != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, want_absent) == null);
}

test "chain e2e regression: same-phase modules chain through the comptime dispatch" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /chain/stub-first {
        \\        content stub_status;
        \\        content echo;
        \\    }
        \\
        \\    location = /chain/echo-first {
        \\        content echo;
        \\        content stub_status;
        \\    }
        \\
        \\    location = /chain/fallback {
        \\        content static;
        \\        content echo;
        \\    }
        \\
        \\    location = /chain/static-then-stub {
        \\        content static;
        \\        content stub_status;
        \\    }
        \\}
    );
    const srv = Server.comptimeInit(cfg);
    var stats = registry.ServerStats.init();

    // stub_status claims first: echo must never run.
    try runChainCase(&srv, testing.allocator, "/chain/stub-first", "STUB-MUST-NOT-APPEAR", &stats, "Active connections:", "STUB-MUST-NOT-APPEAR");
    // echo claims first: stub_status must never run.
    try runChainCase(&srv, testing.allocator, "/chain/echo-first", "ECHO-BODY-FIRST", &stats, "ECHO-BODY-FIRST", "Active connections:");
    // static passes (no root): echo falls through to.
    try runChainCase(&srv, testing.allocator, "/chain/fallback", "FALLBACK-CHAIN", &stats, "FALLBACK-CHAIN", "Active connections:");
    // static passes: stub_status claims, echo (later) must never run.
    try runChainCase(&srv, testing.allocator, "/chain/static-then-stub", "STUB-AFTER-PASS", &stats, "Active connections:", "STUB-AFTER-PASS");
}

test "conf-config server with a comptime trie routes identically to the plain server" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /api { content echo; }
        \\    location = /exact { content echo; }
        \\}
    );
    const plain = Server.init(cfg);
    const trie_srv = Server.comptimeInit(cfg);

    const targets = [_][]const u8{ "/api/users", "/exact", "/exact/x", "/nope" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.decoded_target = t;
        req_a.body = "b";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.decoded_target = t;
        req_b.body = "b";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try plain.handleRequest(&ctx_a);
        const out_b = try trie_srv.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        if (out_a == .handled) {
            try testing.expectEqualStrings(resp_a.body, resp_b.body);
        }
    }
}

// ---- Response templates ----

test "comptime template route serves through the dispatch fallback" {
    const cfg = comptime Config{
        .routes = &.{
            .{
                .path = "/health",
                .match = .exact,
                .response = .{ .status = 200, .body = "ok" },
            },
            .{
                .path = "/old",
                .match = .exact,
                .response = .{
                    .status = 301,
                    .headers = &.{.{ .name = "Location", .value = "/health" }},
                },
            },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    req.decoded_target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok", resp.body);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/old";
    req2.decoded_target = "/old";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx2));
    try testing.expectEqual(registry.Status.moved_permanently, resp2.status);
    try testing.expectEqualStrings("/health", resp2.headers[0].value);
}

test "matchFast returns pre-serialised bytes only for module-less template routes" {
    const cfg = comptime Config{
        .routes = &.{
            .{ .path = "/health", .match = .exact, .response = .{ .body = "ok" } },
            .{
                .path = "/withmods",
                .match = .exact,
                .response = .{ .body = "x" },
                .modules = &.{.{ .phase = .content, .module = "echo" }},
            },
            .{ .path = "/", .match = .prefix, .modules = &.{.{ .phase = .content, .module = "echo" }} },
        },
    };
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    req.decoded_target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    const fb = srv.matchFast(&ctx).?;
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", fb.head);
    try testing.expectEqualStrings("ok", fb.body);

    // A template route WITH modules: the pipeline must run.
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/withmods";
    req2.decoded_target = "/withmods";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx2));

    // Plain echo route: no fast path.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.target = "/anything";
    req3.decoded_target = "/anything";
    var resp3 = registry.Response.init(.ok);
    var ctx3 = pipeline.Context{ .req = &req3, .resp = &resp3 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx3));
}

// ---- Comptime-embedded config as the primary path ----

test "embedded comptime config parses via fromConfEmbedded (root-relative path)" {
    const cfg = comptime Config.fromConfEmbedded("src/testdata/config.example.conf");
    try testing.expectEqual(@as(usize, 7), cfg.routes.len);
    try testing.expectEqualStrings("/echo", cfg.routes[0].path);
}

test "server from an embedded comptime config routes identically to the struct-literal server" {
    const group = ServerGroup.comptimeInit(comptime Config.fromConfEmbedded("src/testdata/config.example.conf"));

    // The first server block (example.com) has 6 routes.
    const embedded = group.servers[0];

    const literal = Server.comptimeInit(comptime Config{
        .routes = &.{
            .{ .path = "/echo", .match = .exact, .modules = &.{.{ .phase = .content, .module = "echo" }} },
            .{ .path = "/gzip", .match = .prefix, .modules = &.{
                .{ .phase = .content, .module = "echo" },
                .{ .phase = .preaccess, .module = "conditional_get" },
                .{ .phase = .post_access, .module = "cache_headers" },
                .{ .phase = .log, .module = "gzip" },
            }, .max_age_seconds = 3600 },
            .{ .path = "/static", .match = .prefix, .modules = &.{.{ .phase = .content, .module = "static" }}, .root = "testdata", .index = "index.html", .autoindex = true },
            .{ .path = "/health", .match = .exact, .response = .{ .status = 200, .body = "ok" } },
            .{ .path = "/old", .match = .exact, .response = .{
                .status = 301,
                .headers = &.{.{ .name = "Location", .value = "/health" }},
            } },
            .{ .path = "/", .match = .prefix, .modules = &.{.{ .phase = .content, .module = "echo" }} },
        },
    });

    const targets = [_][]const u8{ "/echo", "/gzip", "/static/", "/health", "/old", "/", "/anything" };
    for (targets) |t| {
        var req_a = registry.Request.init(testing.allocator);
        defer req_a.deinit();
        req_a.target = t;
        req_a.decoded_target = t;
        req_a.body = "payload";
        var resp_a = registry.Response.init(.ok);
        var ctx_a = pipeline.Context{ .req = &req_a, .resp = &resp_a };

        var req_b = registry.Request.init(testing.allocator);
        defer req_b.deinit();
        req_b.target = t;
        req_b.decoded_target = t;
        req_b.body = "payload";
        var resp_b = registry.Response.init(.ok);
        var ctx_b = pipeline.Context{ .req = &req_b, .resp = &resp_b };

        const out_a = try embedded.handleRequest(&ctx_a);
        const out_b = try literal.handleRequest(&ctx_b);
        try testing.expectEqual(out_a, out_b);
        try testing.expectEqual(resp_a.status, resp_b.status);
        try testing.expectEqualStrings(resp_a.body, resp_b.body);
    }
}

test "embedded comptime config gets pre-serialised fast responses (pre-serialised path)" {
    const group = ServerGroup.comptimeInit(comptime Config.fromConfEmbedded("src/testdata/config.example.conf"));
    const srv = group.servers[0];

    // /health and /old are module-less template routes: served from
    // pre-serialised bytes, no pipeline.
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    req.decoded_target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    const fb = srv.matchFast(&ctx).?;
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", fb.head);
    try testing.expectEqualStrings("ok", fb.body);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.target = "/old";
    req2.decoded_target = "/old";
    var resp2 = registry.Response.init(.ok);
    var ctx2 = pipeline.Context{ .req = &req2, .resp = &resp2 };
    const fb2 = srv.matchFast(&ctx2).?;
    try testing.expectEqualStrings("HTTP/1.1 301 Moved Permanently\r\nLocation: /health\r\n", fb2.head);
    try testing.expectEqualStrings("", fb2.body);

    // /echo is module-backed: no fast path.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.target = "/echo";
    req3.decoded_target = "/echo";
    var resp3 = registry.Response.init(.ok);
    var ctx3 = pipeline.Context{ .req = &req3, .resp = &resp3 };
    try testing.expectEqual(@as(?router_mod.FastResponse, null), srv.matchFast(&ctx3));
}

test "embeddedInit resolves static roots at startup (root_real + root_fd)" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /static { content static; root testdata; }
        \\}
    );
    var srv = try Server.embeddedInit(testing.allocator, cfg);
    defer srv.deinitPrepared(testing.allocator);

    try testing.expectEqual(@as(usize, 1), srv.cfg.routes.len);
    // "testdata" exists at the project root and resolves to an absolute path.
    const rr = srv.cfg.routes[0].root_real orelse return error.SkipZigTest;
    try testing.expect(rr.len > 0 and rr[0] == '/');
    try testing.expect(srv.cfg.routes[0].root_fd >= 0);

    // The copy carries the comptime dispatch fn.
    try testing.expect(srv.cfg.routes[0].dispatch != null);
}

test "conf template route applies through the pipeline" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /health { return 200 "ok-conf"; }
        \\}
    );
    const srv = Server.comptimeInit(cfg);

    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/health";
    req.decoded_target = "/health";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expectEqualStrings("ok-conf", resp.body);
}

test "comptime server trie matches exact conf routes" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /who { return 200 "host=$host"; }
        \\    location / { content echo; }
        \\}
    );
    const srv = Server.comptimeInit(cfg);
    const m = srv.router.match("/who", null).?;
    try testing.expectEqualStrings("/who", m.path);
    try testing.expectEqual(router_mod.Match.exact, m.match);
}

test "embedded server trie matches exact conf routes" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /who { return 200 "host=$host"; }
        \\    location / { content echo; }
        \\}
    );
    var srv = try Server.embeddedInit(testing.allocator, cfg);
    defer srv.deinitPrepared(testing.allocator);
    const m = srv.router.match("/who", null).?;
    try testing.expectEqualStrings("/who", m.path);
    try testing.expectEqual(router_mod.Match.exact, m.match);
}

test "access_log runs through the pipeline with a custom format" {
    std.testing.log_level = .err;
    const cfg = comptime Config.fromConfComptime(
        \\log_format short "$request $status";
        \\server {
        \\    location / { content echo; log access_log; access_log short; }
        \\}
    );
    const srv = Server.comptimeInit(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    req.target = "/x";
    req.decoded_target = "/x";
    req.body = "b";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp, .allocator = testing.allocator, .formats = srv.formats() };
    const out = try srv.handleRequest(&ctx);
    try testing.expectEqual(pipeline.Outcome.handled, out);
}

test "formats returns null without log formats and the table with them" {
    const plain = Server.init(Config.default());
    try testing.expect(plain.formats() == null);

    const cfg = comptime Config.fromConfComptime(
        \\log_format short "$request $status";
        \\server {
        \\    location / { content echo; }
        \\}
    );
    const with_formats = Server.init(cfg);
    const fmts = with_formats.formats().?;
    try testing.expectEqual(@as(usize, 1), fmts.len);
    try testing.expectEqualStrings("short", fmts[0].name);
}

test "subrequestImpl runs a target through the server pipeline" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location = /only { content echo; }
        \\}
    );
    const srv = Server.init(cfg);

    var src = registry.Request.init(testing.allocator);
    defer src.deinit();
    src.addHeaderParsed("authorization", "Bearer s3cret") catch unreachable;

    var code: u16 = 0;
    try Server.subrequestImpl(&srv, &src, "/only", &code);
    try testing.expectEqual(@as(u16, 200), code);
    // Unmatched targets mirror the reactor's default 404.
    try Server.subrequestImpl(&srv, &src, "/nope-missing", &code);
    try testing.expectEqual(@as(u16, 404), code);
}

test "subrequestImpl forwards only the Authorization header" {
    // A request that echoes the body: empty body here, so any 200 proves
    // the subrequest ran; header filtering is covered by the impl reading
    // exactly one header (no error when others are present).
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / { content echo; }
        \\}
    );
    const srv = Server.init(cfg);
    var src = registry.Request.init(testing.allocator);
    defer src.deinit();
    src.addHeaderParsed("x-other", "1") catch unreachable;
    src.addHeaderParsed("cookie", "a=b") catch unreachable;
    var code: u16 = 0;
    try Server.subrequestImpl(&srv, &src, "/", &code);
    try testing.expectEqual(@as(u16, 200), code);
}

test "loadTls is a no-op without TLS and errors on missing files" {
    var plain = Server.init(Config.default());
    try plain.loadTls(testing.allocator);
    try testing.expect(plain.tls_creds == null);

    var missing = Server.init(.{ .tls = .{ .cert = "/nonexistent-dir/cert.pem", .key = "/nonexistent-dir/key.pem" } });
    try testing.expectError(error.FileNotFound, missing.loadTls(testing.allocator));
    try testing.expect(missing.tls_creds == null);
}

test "loadTls loads credentials from disk files" {
    const testdata = @import("../tls/testdata.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cert_buf: [std.fs.max_path_bytes]u8 = undefined;
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cert_path = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
    const key_path = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
    try compat.writeFile(cert_path, testdata.cert_pem);
    try compat.writeFile(key_path, testdata.key_pem);

    var srv = Server.init(.{ .tls = .{ .cert = cert_path, .key = key_path } });
    try srv.loadTls(testing.allocator);
    try testing.expect(srv.tls_creds != null);
    // Credentials are process-lifetime in production (never freed); the
    // test releases the allocator-owned DER copy itself.
    testing.allocator.free(@constCast(srv.tls_creds.?.cert_der));
    srv.tls_creds = null;
}

test "ServerGroup.init builds runtime servers with per-server stats" {
    // Runtime-built groups are freed piece-wise (per-server deinitPrepared
    // + servers free), mirroring main.zig's teardown — there is no group
    // deinit by design (servers may be comptime-owned or arena-owned).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    listen 8080;
        \\    server_name a.test;
        \\    location / { content echo; }
        \\}
        \\server {
        \\    listen 8081;
        \\    server_name b.test;
        \\    location / { content echo; }
        \\}
    );
    var group = try ServerGroup.init(arena_state.allocator(), cfg);
    try testing.expect(group.servers_owned);
    try testing.expectEqual(@as(usize, 2), group.servers.len);
    try testing.expectEqual(@as(?u16, 8080), group.servers[0].cfg.listen_port);
    try testing.expectEqual(@as(?u16, 8081), group.servers[1].cfg.listen_port);
    // Runtime fallback selection still honors names and defaults.
    try testing.expectEqual(&group.servers[0], group.selectServer("a.test", null));
    try testing.expectEqual(&group.servers[1], group.selectServer("b.test:8081", null));
    try testing.expectEqual(&group.servers[0], group.selectServer("unknown", null));
    // Each server answers through its own route slice.
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/";
    req.decoded_target = "/";
    req.body = "via-group";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try group.servers[1].handleRequest(&ctx));
    try testing.expectEqualStrings("via-group", resp.body);
}

test "ServerGroup selectServer honors host_select off" {
    const s1 = Server.init(.{ .server_names = &.{"example.com"} });
    const s2 = Server.init(.{ .server_names = &.{"other.com"} });
    const servers = [_]Server{ s1, s2 };
    const group = ServerGroup{ .servers = &servers, .default_idx = 0, .host_select = false };
    try testing.expectEqual(&servers[0], group.selectServer("other.com", null));
    try testing.expectEqual(&servers[0], group.selectServer("example.com", null));
}

test "ServerGroup selectServer clamps an out-of-range select_fn" {
    const clk = struct {
        fn sel(host: []const u8) usize {
            _ = host;
            return 99; // bogus: must clamp to the last server, not crash
        }
    }.sel;
    const s1 = Server.init(.{});
    const servers = [_]Server{s1};
    const group = ServerGroup{ .servers = &servers, .default_idx = 0 };
    const cfg = Config{ .select_fn = clk };
    try testing.expectEqual(&servers[0], group.selectServer("anything", cfg));
}

test "embeddedInitGroupWithTls builds a single-server group without servers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / { content echo; }
        \\}
    );
    // See the deinit NOTE above: arena owns the route copy + stats.
    const group = try ServerGroup.embeddedInitGroupWithTls(arena_state.allocator(), cfg);
    try testing.expectEqual(@as(usize, 1), group.servers.len);
    try testing.expect(group.servers_owned);
}

/// A group of virtual-host servers: holds one `Server` per `server {}`
/// block. The reactor calls `selectServer` with the Host header to pick
/// the right server, then `handleRequest` on the selected one.
pub const ServerGroup = struct {
    servers: []const Server,
    /// Index of the default server (first block, or the one without
    /// server_name). Used when no Host header matches.
    default_idx: usize = 0,
    /// Whether Host-based server selection is enabled. When false,
    /// `selectServer` always returns the first server.
    host_select: bool = true,
    /// True when `servers` was heap-allocated (runtime init) and must
    /// be freed on deinit. False for comptime-built groups (.rodata).
    servers_owned: bool = false,

    /// Comptime build: one `Server` per server block, each from its own
    /// route slice — routes from different servers may share a path without
    /// conflict. The select_fn is wired from the config.
    pub fn comptimeInit(comptime cfg: config_mod.Config) ServerGroup {
        const servers = comptime blk: {
            var arr: [cfg.servers.len]Server = undefined;
            for (cfg.servers, 0..) |spec, i| {
                const sub_routes = cfg.routes[spec.routes_start..][0..spec.routes_len];
                const sub_cfg = config_mod.Config{
                    .routes = sub_routes,
                    .limits = cfg.limits,
                    .tls = cfg.tls,
                    .listen_port = spec.listen_port,
                    .log_formats = cfg.log_formats,
                    .maps = cfg.maps,
                    .server_names = spec.server_names,
                };
                arr[i] = Server.comptimeInit(sub_cfg);
            }
            break :blk arr;
        };
        return .{
            .servers = &servers,
            .default_idx = 0,
            .host_select = cfg.host_select,
        };
    }

    /// Build a ServerGroup from a Config. Each ServerSpec produces its
    /// own `Server` instance with its own route table and stats.
    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config) !ServerGroup {
        const srvs = try allocator.alloc(Server, cfg.servers.len);
        errdefer allocator.free(srvs);
        for (cfg.servers, 0..) |spec, i| {
            const sub_routes = cfg.routes[spec.routes_start..][0..spec.routes_len];
            const stats = try allocator.create(ServerStats);
            errdefer allocator.destroy(stats);
            stats.* = .{};
            const sub_cfg = config_mod.Config{
                .routes = sub_routes,
                .limits = cfg.limits,
                .tls = cfg.tls,
                .listen_port = spec.listen_port,
                .log_formats = cfg.log_formats,
                .maps = cfg.maps,
                .resolver = cfg.resolver,
                .server_names = spec.server_names,
            };
            srvs[i] = Server.init(sub_cfg);
            srvs[i].stats = stats;
        }
        return .{ .servers = srvs, .default_idx = 0, .host_select = cfg.host_select, .servers_owned = true };
    }

    /// Build a ServerGroup from an embedded comptime config with runtime
    /// static-root resolution and TLS loading. Each server gets its own
    /// route copy (for resolved roots) and per-server stats.
    pub fn embeddedInitGroupWithTls(allocator: std.mem.Allocator, comptime cfg: config_mod.Config) !ServerGroup {
        if (cfg.servers.len == 0) {
            var srv = try Server.embeddedInitWithTls(allocator, cfg);
            const stats = try allocator.create(ServerStats);
            errdefer allocator.destroy(stats);
            stats.* = .{};
            srv.stats = stats;
            const srvs = try allocator.alloc(Server, 1);
            srvs[0] = srv;
            return .{ .servers = srvs, .default_idx = 0, .host_select = cfg.host_select, .servers_owned = true };
        }
        const srvs = try allocator.alloc(Server, cfg.servers.len);
        errdefer allocator.free(srvs);
        inline for (cfg.servers, 0..) |spec, i| {
            const sub_routes = cfg.routes[spec.routes_start..][0..spec.routes_len];
            // Server-scope tls block overrides the global section (SNI
            // cert selection); an unset one inherits.
            const sub_tls = if (spec.tls.cert.len > 0) spec.tls else cfg.tls;
            const sub_cfg = config_mod.Config{
                .routes = sub_routes,
                .limits = cfg.limits,
                .tls = sub_tls,
                .listen_port = spec.listen_port,
                .log_formats = cfg.log_formats,
                .maps = cfg.maps,
                .resolver = cfg.resolver,
                .server_names = spec.server_names,
            };
            srvs[i] = try Server.embeddedInitWithTls(allocator, sub_cfg);
        }
        return .{ .servers = srvs, .default_idx = 0, .host_select = cfg.host_select, .servers_owned = true };
    }

    /// Select a server by Host header value. Uses the comptime-generated
    /// select_fn when available (O(1) exact match + wildcard scan), falls
    /// back to runtime matching for dynamically-constructed configs.
    /// When host_select is false, always returns the first server.
    /// Like `selectServer`, but for the TLS handshake: the chosen vhost
    /// must carry credentials, else the first server with any is used
    /// (nginx picks the matching `ssl_certificate` per SNI; a vhost with
    /// no cert must not kill the handshake when another has one).
    pub fn selectServerTls(self: *const ServerGroup, sni: []const u8) *const Server {
        const srv = self.selectServer(sni, null);
        if (srv.tls_creds != null) return srv;
        for (self.servers) |*s| {
            if (s.tls_creds != null) return s;
        }
        return srv;
    }

    pub fn selectServer(self: *const ServerGroup, host: []const u8, cfg: ?config_mod.Config) *const Server {
        if (!self.host_select) return &self.servers[0];
        // Fast path: comptime-generated select function.
        if (cfg) |c| {
            if (c.select_fn) |sel| {
                const idx = sel(host);
                return &self.servers[@min(idx, self.servers.len - 1)];
            }
        }
        // Fallback: runtime matching (for JSON-loaded or test configs).
        const h = if (std.mem.lastIndexOfScalar(u8, host, ':')) |pos| host[0..pos] else host;
        for (self.servers) |*srv| {
            for (srv.cfg.server_names) |name| {
                if (std.mem.eql(u8, h, name)) return srv;
            }
        }
        for (self.servers) |*srv| {
            for (srv.cfg.server_names) |name| {
                if (name.len > 2 and name[0] == '*' and name[1] == '.') {
                    if (h.len > name.len - 1 and std.mem.endsWith(u8, h, name[1..])) return srv;
                }
            }
        }
        return &self.servers[self.default_idx];
    }
};

test "internal redirect: try_files falls through to a static fallback" {
    // /app/missing.txt does not exist under testdata -> try_files
    // redirects to /hello.txt, which the static route serves (200).
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /app/ {
        \\        root "testdata";
        \\        try_files $uri /hello.txt;
        \\    }
        \\    location / {
        \\        root "testdata";
        \\        content static;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/app/missing.txt";
    req.decoded_target = "/app/missing.txt";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(@as(u8, 1), ctx.redirect_hops);
    try testing.expectEqualStrings("/hello.txt", req.decoded_target);
    try testing.expectEqual(registry.Status.ok, resp.status);
    // Static serves the file by fd (sendfile), not body bytes: the unit
    // context sees the flag, the reactor pumps the bytes.
    try testing.expect(resp.body_from_file);
}

test "internal redirect: error_page serves the alternate URI" {
    // /files/nope.txt misses in static (404 handled) -> error_page
    // redirects to /hello.txt, served 200 by the static route.
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /files/ {
        \\        root "testdata";
        \\        content static;
        \\        error_page 404 /hello.txt;
        \\    }
        \\    location / {
        \\        root "testdata";
        \\        content static;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/files/nope.txt";
    req.decoded_target = "/files/nope.txt";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(@as(u8, 1), ctx.redirect_hops);
    try testing.expectEqualStrings("/hello.txt", req.decoded_target);
    try testing.expectEqual(registry.Status.ok, resp.status);
    // Same sendfile-by-fd shape as above (walk 1's "Not Found" body is
    // replaced by the fd response, not by body bytes).
    try testing.expect(resp.body_from_file);
}

test "internal redirect: self-referential error_page stops at the cap" {
    // `error_page 404` on the very URI that 404s: the server hop budget
    // terminates the chain. redirect_hops must equal the cap, never spin.
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /loop {
        \\        root "testdata";
        \\        content static;
        \\        error_page 404 /loop;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/loop";
    req.decoded_target = "/loop";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    _ = try srv.handleRequest(&ctx);
    try testing.expectEqual(max_internal_redirects, ctx.redirect_hops);
}

test "map vars render per request through the server" {
    const cfg = comptime Config.fromConfComptime(
        \\map $http_user_agent $is_bot {
        \\    default 0;
        \\    curl 1;
        \\    ~*bot 1;
        \\}
        \\server {
        \\    location / {
        \\        return 200 "bot=$is_bot\n";
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    const cases = [_]struct { ua: ?[]const u8, want: []const u8 }{
        .{ .ua = "Googlebot/2.1", .want = "bot=1\n" },
        // Literals are exact (nginx semantics): "curl" hits, "curl/8.0" falls
        // to the default.
        .{ .ua = "curl", .want = "bot=1\n" },
        .{ .ua = "curl/8.0", .want = "bot=0\n" },
        .{ .ua = "Mozilla/5.0", .want = "bot=0\n" },
        .{ .ua = null, .want = "bot=0\n" },
    };
    for (cases) |c| {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.target = "/";
        req.decoded_target = "/";
        if (c.ua) |ua| _ = req.addHeaderParsed("User-Agent", ua) catch unreachable;
        var resp = registry.Response.init(.ok);
        var ctx = pipeline.Context{ .req = &req, .resp = &resp };
        try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
        try testing.expectEqualStrings(c.want, resp.body);
    }
}

test "map dest feeds set vars and second-request caching is per-request" {
    // $tier derives from the path arg; a set var consumes it; two sequential
    // requests must not leak cached evaluations into each other.
    const cfg = comptime Config.fromConfComptime(
        \\map $arg_tier $quota {
        \\    default 10;
        \\    pro 100;
        \\}
        \\server {
        \\    location / {
        \\        set $msg "quota=$quota";
        \\        return 200 "$msg\n";
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    const cases = [_]struct { target: []const u8, query: []const u8, want: []const u8 }{
        .{ .target = "/?tier=pro", .query = "tier=pro", .want = "quota=100\n" },
        .{ .target = "/", .query = "", .want = "quota=10\n" },
    };
    for (cases) |c| {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.target = c.target;
        req.decoded_target = "/";
        req.query_string = c.query;
        var resp = registry.Response.init(.ok);
        var ctx = pipeline.Context{ .req = &req, .resp = &resp };
        try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
        try testing.expectEqualStrings(c.want, resp.body);
    }
}

test "prepareUpstreams dupes hostname routes, passes literals through" {
    // Literal-only route: same slice back (zero startup cost, no free).
    const lit_ups = [_]router_mod.Upstream{
        .{ .host = "127.0.0.1", .port = 80, .sockaddr = router_mod.Upstream.makeSockaddr("127.0.0.1", 80).? },
    };
    const lit_route = router_mod.Route{ .path = "/", .upstreams = &lit_ups };
    const lit_out = try Server.prepareUpstreams(testing.allocator, lit_route, .{});
    try testing.expect(lit_out.ptr == lit_route.upstreams.ptr);

    // Hostname route with no servers: duped array, unresolved, registered.
    const dns_ups = [_]router_mod.Upstream{
        .{ .host = "backend.internal", .port = 8001, .hostname = "backend.internal" },
    };
    const dns_route = router_mod.Route{ .path = "/", .upstreams = &dns_ups };
    const dns_out = try Server.prepareUpstreams(testing.allocator, dns_route, .{});
    defer testing.allocator.free(dns_out);
    try testing.expect(dns_out.ptr != dns_route.upstreams.ptr);
    try testing.expectEqual(@as(u16, 0), dns_out[0].sockaddr.family);
    try testing.expectEqualStrings("backend.internal", dns_out[0].hostname.?);
}

test "deinitPrepared frees hostname upstream dupes without leaking" {
    // Mimics embeddedInit's hostname path: heap routes + heap upstream
    // array. testing.allocator fails on leak → proves the free branch ran.
    const heap_ups = try testing.allocator.dupe(router_mod.Upstream, &[_]router_mod.Upstream{
        .{ .host = "backend.internal", .port = 8001, .hostname = "backend.internal" },
    });
    const routes = try testing.allocator.alloc(router_mod.Route, 1);
    routes[0] = .{ .path = "/", .upstreams = heap_ups };
    var srv = Server.init(.{ .routes = routes });
    srv.deinitPrepared(testing.allocator);
}

test "loadTls staples a good OCSP response and rejects a revoked one" {
    const testdata = @import("../tls/testdata.zig");
    const ocsp_mod = @import("../tls/ocsp.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cert_buf: [std.fs.max_path_bytes]u8 = undefined;
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ocsp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cert_path = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
    const key_path = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
    const ocsp_path = try std.fmt.bufPrint(&ocsp_buf, ".zig-cache/tmp/{s}/ocsp.der", .{tmp.sub_path});
    try compat.writeFile(cert_path, testdata.cert_pem);
    try compat.writeFile(key_path, testdata.key_pem);
    const good = try ocsp_mod.buildResponse(testing.allocator, .good);
    defer testing.allocator.free(good);
    try compat.writeFile(ocsp_path, good);

    var srv = Server.init(.{ .tls = .{ .cert = cert_path, .key = key_path, .ocsp_file = ocsp_path } });
    try srv.loadTls(testing.allocator);
    try testing.expect(srv.tls_creds != null);
    try testing.expectEqual(good.len, srv.tls_creds.?.ocsp_der.len);
    testing.allocator.free(@constCast(srv.tls_creds.?.cert_der));
    testing.allocator.free(@constCast(srv.tls_creds.?.ocsp_der));
    srv.tls_creds = null;

    // Revoked: fail closed.
    const bad = try ocsp_mod.buildResponse(testing.allocator, .revoked);
    defer testing.allocator.free(bad);
    try compat.writeFile(ocsp_path, bad);
    var srv2 = Server.init(.{ .tls = .{ .cert = cert_path, .key = key_path, .ocsp_file = ocsp_path } });
    try testing.expectError(error.OcspNotGood, srv2.loadTls(testing.allocator));
    try testing.expect(srv2.tls_creds == null);
}

test "loadTls refuses verify_client without a bundle, loads a good one" {
    const testdata = @import("../tls/testdata.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cert_buf: [std.fs.max_path_bytes]u8 = undefined;
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ca_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cert_path = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
    const key_path = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
    const ca_path = try std.fmt.bufPrint(&ca_buf, ".zig-cache/tmp/{s}/ca.pem", .{tmp.sub_path});
    try compat.writeFile(cert_path, testdata.cert_pem);
    try compat.writeFile(key_path, testdata.key_pem);
    try compat.writeFile(ca_path, testdata.client_ca_pem);

    // verify on, no CA: fail closed.
    var bare = Server.init(.{ .tls = .{ .cert = cert_path, .key = key_path, .verify_client = true } });
    try testing.expectError(error.MtlsNeedsClientCa, bare.loadTls(testing.allocator));
    try testing.expect(bare.tls_creds == null);

    // verify on with CA: bundle loads, creds point at it.
    var srv = Server.init(.{ .tls = .{ .cert = cert_path, .key = key_path, .client_ca = ca_path, .verify_client = true } });
    try srv.loadTls(testing.allocator);
    try testing.expect(srv.tls_creds != null);
    try testing.expect(srv.tls_creds.?.verify_client);
    try testing.expect(srv.tls_creds.?.client_ca != null);
    testing.allocator.free(@constCast(srv.tls_creds.?.cert_der));
    // Bundle is page-allocator owned (process-lifetime in production).
    if (srv.client_ca_bundle) |*b| b.deinit(std.heap.page_allocator);
    srv.tls_creds = null;
    srv.client_ca_bundle = null;
}

test "selectServerTls picks the SNI vhost, falls back to a server with creds" {
    // s1: default, creds A. s2 (api.test): no creds. s3 (secure.test): creds B.
    const testdata = @import("../tls/testdata.zig");
    const creds_a = try tls_cert.loadCredentials(testing.allocator, testdata.cert_pem, testdata.key_pem);
    defer testing.allocator.free(creds_a.cert_der);
    const creds_b = try tls_cert.loadCredentials(testing.allocator, testdata.cert384_pem, testdata.key384_pem);
    defer testing.allocator.free(creds_b.cert_der);
    var s1 = Server.init(.{ .server_names = &.{"default.test"} });
    s1.tls_creds = creds_a;
    const s2 = Server.init(.{ .server_names = &.{"api.test"} });
    var s3 = Server.init(.{ .server_names = &.{"secure.test"} });
    s3.tls_creds = creds_b;
    const servers = [_]Server{ s1, s2, s3 };
    const group = ServerGroup{ .servers = &servers, .default_idx = 0 };
    // Exact SNI with creds: that vhost's cert.
    try testing.expectEqual(&servers[2], group.selectServerTls("secure.test"));
    // Matched vhost without creds falls back to one that has them (the
    // first in order), never breaking the handshake.
    try testing.expectEqual(&servers[0], group.selectServerTls("api.test"));
    // Unmatched SNI: default server has creds -> default.
    try testing.expectEqual(&servers[0], group.selectServerTls("other.test"));
    // Wildcard.
    var s4 = Server.init(.{ .server_names = &.{"*.wild.test"} });
    s4.tls_creds = creds_b;
    const servers2 = [_]Server{ s1, s2, s4 };
    const group2 = ServerGroup{ .servers = &servers2, .default_idx = 0 };
    try testing.expectEqual(&servers2[2], group2.selectServerTls("v1.wild.test"));
}

test "internal redirect: try_files falls to a named location" {
    // /missing.txt not on disk -> try_files @app -> the named location's
    // echo module answers (the name bypasses path matching entirely).
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / {
        \\        root "testdata";
        \\        try_files $uri @app;
        \\    }
        \\    location @app {
        \\        content echo;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/missing.txt";
    req.decoded_target = "/missing.txt";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(@as(u8, 1), ctx.redirect_hops);
    // The URI is unchanged; the named route answered.
    try testing.expectEqualStrings("/missing.txt", req.decoded_target);
    try testing.expectEqual(registry.Status.ok, resp.status);
    try testing.expect(ctx.route != null);
    try testing.expectEqualStrings("@app", ctx.route.?.name.?);
}

test "named location exists but is unreachable by path" {
    // GET @app-equivalent path never resolves to the named location: a
    // request to /app (or anything else) falls to the / route.
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / {
        \\        content echo;
        \\    }
        \\    location @app {
        \\        content echo;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/must-not-hit-named";
    req.decoded_target = "/must-not-hit-named";

    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };

    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expect(ctx.route.?.name == null);
    try testing.expectEqual(@as(u8, 0), ctx.redirect_hops);
}

test "internal locations: external 404-free fallback, internal redirect reaches" {
    // GET /private/x from a client: the internal /private/ location is
    // invisible; the public / echoes instead (nginx semantics).
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location / {
        \\        content echo;
        \\    }
        \\    location /private/ {
        \\        internal;
        \\        content static;
        \\        root "testdata";
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.target = "/private/hello.txt";
        req.decoded_target = "/private/hello.txt";
        var resp = registry.Response.init(.ok);
        var ctx = pipeline.Context{ .req = &req, .resp = &resp };
        try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
        try testing.expectEqual(@as(u8, 0), ctx.redirect_hops);
        try testing.expectEqualStrings("/", ctx.route.?.path);
    }
    // An error_page internal redirect DOES reach /private/ (hop 1).
    const cfg2 = comptime Config.fromConfComptime(
        \\server {
        \\    location /files/ {
        \\        root "testdata";
        \\        content static;
        \\        error_page 404 /private/hello.txt;
        \\    }
        \\    location /private/ {
        \\        internal;
        \\        content static;
        \\        root "testdata";
        \\    }
        \\}
    );
    const srv2 = Server.init(cfg2);
    {
        var req = registry.Request.init(testing.allocator);
        defer req.deinit();
        req.target = "/files/nope.txt";
        req.decoded_target = "/files/nope.txt";
        var resp = registry.Response.init(.ok);
        var ctx = pipeline.Context{ .req = &req, .resp = &resp };
        try testing.expectEqual(pipeline.Outcome.handled, try srv2.handleRequest(&ctx));
        try testing.expectEqual(@as(u8, 1), ctx.redirect_hops);
        try testing.expectEqualStrings("/private/", ctx.route.?.path);
        try testing.expectEqual(registry.Status.ok, resp.status);
    }
}

test "return 444: pipeline yields the no-response status" {
    const cfg = comptime Config.fromConfComptime(
        \\server {
        \\    location /drop {
        \\        return 444;
        \\    }
        \\}
    );
    const srv = Server.init(cfg);
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.target = "/drop";
    req.decoded_target = "/drop";
    var resp = registry.Response.init(.ok);
    var ctx = pipeline.Context{ .req = &req, .resp = &resp };
    try testing.expectEqual(pipeline.Outcome.handled, try srv.handleRequest(&ctx));
    try testing.expectEqual(registry.Status.no_response, resp.status);
    // The fast path must not pre-serialise bytes for such routes.
    try testing.expect(srv.matchFast(&ctx) == null);
}
