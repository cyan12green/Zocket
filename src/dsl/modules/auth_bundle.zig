//! Auth bundle (C3): CORS helper, `secure_link` expiring URLs, JWT-lite
//! (HS256). All three bind to the `access` phase; each is inert unless its
//! config is present, so partial configs fail open into plain HTTP.
//!
//! Config surface (Route fields, parsed from conf):
//!   cors on; cors_origin "*"; cors_methods "GET, POST"; ...
//!   secure_link_secret "key";
//!   auth_jwt_secret "key"; auth_jwt_leeway 60;

const std = @import("std");
const registry = @import("../registry.zig");
const compat = @import("../../compat.zig");

pub const Context = registry.Context;
pub const Action = registry.Action;
pub const Status = registry.Status;

pub const cors = registry.Module{
    .name = "cors",
    .phase = .access,
    .run = runCors,
};

pub const secure_link = registry.Module{
    .name = "secure_link",
    .phase = .access,
    .run = runSecureLink,
};

pub const auth_jwt = registry.Module{
    .name = "auth_jwt",
    .phase = .access,
    .run = runAuthJwt,
};

const default_methods = "GET, HEAD, POST, PUT, DELETE, OPTIONS";

// ---- CORS ----

fn runCors(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    if (!route.cors_enabled) return .pass;
    const origin = route.cors_origin orelse "*";
    ctx.resp.setHeader("Access-Control-Allow-Origin", origin);
    ctx.resp.setHeader("Vary", "Origin");
    if (route.cors_credentials) {
        ctx.resp.setHeader("Access-Control-Allow-Credentials", "true");
    }
    // Preflight: OPTIONS answers in place (204, no body).
    if (ctx.req.method == .options) {
        ctx.resp.setHeader("Access-Control-Allow-Methods", route.cors_methods orelse default_methods);
        if (route.cors_headers) |h| ctx.resp.setHeader("Access-Control-Allow-Headers", h);
        if (route.cors_max_age > 0) {
            ctx.resp.setHeaderFmt("Access-Control-Max-Age", "{d}", .{route.cors_max_age});
        }
        ctx.resp.status = .no_content;
        ctx.resp.body = "";
        return .handled;
    }
    return .pass;
}

// ---- secure_link ----

/// Expected signature: hex(HMAC-SHA256(secret, "{path}|{expires}")) where
/// path is the decoded target without query and expires is the `e` arg.
/// Query carries `?e=<unix>&s=<hex>`. Pure (unit-tested via verifySecureLink).
pub fn verifySecureLink(secret: []const u8, path: []const u8, expires_s: i64, sig_hex: []const u8, now_s: i64) bool {
    if (now_s > expires_s) return false;
    var mac: [32]u8 = undefined;
    var h = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    h.update(path);
    h.update("|");
    var ebuf: [24]u8 = undefined;
    const es = std.fmt.bufPrint(&ebuf, "{d}", .{expires_s}) catch return false;
    h.update(es);
    h.final(&mac);
    if (sig_hex.len != 64) return false;
    var sig: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig, sig_hex) catch return false;
    return std.crypto.timing_safe.eql([32]u8, mac, sig);
}

pub fn signSecureLink(secret: []const u8, path: []const u8, expires_s: i64, out_hex: *[64]u8) void {
    var mac: [32]u8 = undefined;
    var h = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    h.update(path);
    h.update("|");
    var ebuf: [24]u8 = undefined;
    const es = std.fmt.bufPrint(&ebuf, "{d}", .{expires_s}) catch unreachable;
    h.update(es);
    h.final(&mac);
    _ = std.fmt.bufPrint(out_hex, "{s}", .{std.fmt.bytesToHex(mac, .lower)}) catch unreachable;
}

fn queryArg(query: []const u8, name: []const u8) ?[]const u8 {
    // query includes the leading '?' (or is empty).
    var q = query;
    if (q.len > 0 and q[0] == '?') q = q[1..];
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn nowSeconds(ctx: *const Context) i64 {
    if (ctx.now_ns > 0) return @intCast(ctx.now_ns / 1_000_000_000);
    const ts = compat.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec;
}

fn runSecureLink(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const secret = route.secure_link_secret orelse return .pass;
    const q = ctx.req.query_string;
    const e_str = queryArg(q, "e") orelse return forbidden(ctx);
    const s_hex = queryArg(q, "s") orelse return forbidden(ctx);
    const expires = std.fmt.parseInt(i64, e_str, 10) catch return forbidden(ctx);
    // Path without query: decoded_target is already query-stripped.
    const path = if (ctx.req.decoded_target.len > 0) ctx.req.decoded_target else "/";
    if (!verifySecureLink(secret, path, expires, s_hex, nowSeconds(ctx))) return forbidden(ctx);
    return .pass;
}

fn forbidden(ctx: *Context) Action {
    ctx.resp.status = .forbidden;
    ctx.resp.body = Status.forbidden.reasonPhrase();
    return .handled;
}

// ---- JWT-lite (HS256) ----

fn runAuthJwt(ctx: *Context) anyerror!Action {
    const route = ctx.route orelse return .pass;
    const auth = ctx.req.header("authorization") orelse {
        if (route.auth_jwt_secret == null and route.auth_jwt_key_file == null) return .pass;
        return jwtUnauthorized(ctx);
    };
    const trimmed = std.mem.trim(u8, auth, " \t");
    if (trimmed.len < 8 or !std.ascii.eqlIgnoreCase(trimmed[0..6], "Bearer") or trimmed[6] != ' ') {
        if (route.auth_jwt_secret == null and route.auth_jwt_key_file == null) return .pass;
        return jwtUnauthorized(ctx);
    }
    const token = std.mem.trim(u8, trimmed[7..], " \t");
    // ES256 wins when a key file is configured (asymmetric first).
    if (route.auth_jwt_key_file) |kf| {
        const pubkey_bytes = jwtPubkey(kf) orelse return jwtUnauthorized(ctx);
        if (!verifyJwtEs256(&pubkey_bytes, token, nowSeconds(ctx), route.auth_jwt_leeway_s)) {
            return jwtUnauthorized(ctx);
        }
        return .pass;
    }
    const secret = route.auth_jwt_secret orelse return .pass;
    if (!verifyJwtHs256(secret, token, nowSeconds(ctx), route.auth_jwt_leeway_s)) {
        return jwtUnauthorized(ctx);
    }
    return .pass;
}

/// Process-wide SEC1 pubkey cache keyed by PEM path (4 slots; DER lives
/// until replaced — same convention as the proxy CA bundle cache).
/// Null when the file is missing or holds no P-256 certificate.
const max_jwt_keys = 4;
var jwt_key_mutex = compat.Mutex{};
var jwt_key_paths: [max_jwt_keys][]const u8 = @as([max_jwt_keys][]const u8, @splat(@as([]const u8, "")));
var jwt_key_pubs: [max_jwt_keys][65]u8 = undefined;
var jwt_key_filled: usize = 0;

fn jwtPubkey(path: []const u8) ?[65]u8 {
    jwt_key_mutex.lock();
    defer jwt_key_mutex.unlock();
    for (jwt_key_paths[0..jwt_key_filled], 0..) |p, i| {
        if (std.mem.eql(u8, p, path)) return jwt_key_pubs[i];
    }
    if (jwt_key_filled >= max_jwt_keys) return null;
    const pem_mod = @import("../../tls/pem.zig");
    const Certificate = std.crypto.Certificate;
    const pem_bytes = compat.readFileAlloc(std.heap.page_allocator, path, 1 << 20) catch return null;
    defer std.heap.page_allocator.free(pem_bytes);
    var der_buf: [4096]u8 = undefined;
    const der_len = (pem_mod.decodeFirst(pem_bytes, "CERTIFICATE", &der_buf) catch return null) orelse return null;
    const parsed = Certificate.parse(.{ .buffer = der_buf[0..der_len], .index = 0 }) catch return null;
    if (parsed.pub_key_algo != .X9_62_id_ecPublicKey) return null;
    const point = parsed.pubKey();
    if (point.len != 65 or point[0] != 0x04) return null;
    @memcpy(jwt_key_pubs[jwt_key_filled][0..65], point);
    jwt_key_paths[jwt_key_filled] = path;
    jwt_key_filled += 1;
    return jwt_key_pubs[jwt_key_filled - 1];
}

/// Verify `header.payload.sig` (base64url, ES256): header must claim
/// ES256 (confusion with HS256/none fails closed), signature checks
/// against the SEC1 key, `exp` enforced as in the HS256 path.
pub fn verifyJwtEs256(pub_sec1: *const [65]u8, token: []const u8, now_s: i64, leeway_s: u32) bool {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    var it = std.mem.splitScalar(u8, token, '.');
    const h = it.next() orelse return false;
    const p = it.next() orelse return false;
    const s = it.next() orelse return false;
    if (it.next() != null) return false;
    if (h.len == 0 or p.len == 0 or s.len == 0) return false;
    // Header must say ES256 (decode + substring; no JSON parser needed).
    const hlen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(h) catch return false;
    if (hlen > 256) return false;
    var hbuf: [256]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(hbuf[0..hlen], h) catch return false;
    if (std.mem.indexOf(u8, hbuf[0..hlen], "\"alg\":\"ES256\"") == null) return false;
    const pubkey = Ecdsa.PublicKey.fromSec1(pub_sec1) catch return false;
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(s) catch return false;
    if (sig_len != 64) return false;
    var sig_raw: [64]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&sig_raw, s) catch return false;
    const sig = Ecdsa.Signature.fromBytes(sig_raw);
    // ES256 signs the ASCII header.payload directly (SHA-256).
    var msg = std.ArrayList(u8).empty;
    defer msg.deinit(std.heap.page_allocator);
    msg.appendSlice(std.heap.page_allocator, h) catch return false;
    msg.append(std.heap.page_allocator, '.') catch return false;
    msg.appendSlice(std.heap.page_allocator, p) catch return false;
    sig.verify(msg.items, pubkey) catch return false;
    const plen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(p) catch return false;
    if (plen > 4096) return false;
    var pbuf: [4096]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(pbuf[0..plen], p) catch return false;
    if (findExp(pbuf[0..plen])) |exp| {
        if (now_s > exp + @as(i64, leeway_s)) return false;
    }
    return true;
}

fn jwtUnauthorized(ctx: *Context) Action {
    ctx.resp.status = .unauthorized;
    ctx.resp.body = Status.unauthorized.reasonPhrase();
    ctx.resp.setHeader("WWW-Authenticate", "Bearer");
    return .handled;
}

/// Verify `header.payload.sig` (base64url, HS256). Checks the signature
/// and, when the payload carries a numeric `"exp"`, its expiry against
/// now+leeway. Pure (unit-tested).
pub fn verifyJwtHs256(secret: []const u8, token: []const u8, now_s: i64, leeway_s: u32) bool {
    var it = std.mem.splitScalar(u8, token, '.');
    const h = it.next() orelse return false;
    const p = it.next() orelse return false;
    const s = it.next() orelse return false;
    if (it.next() != null) return false;
    if (h.len == 0 or p.len == 0 or s.len == 0) return false;
    // Signature over the ASCII "h.p".
    var mac: [32]u8 = undefined;
    var hm = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hm.update(h);
    hm.update(".");
    hm.update(p);
    hm.final(&mac);
    var sig: [32]u8 = undefined;
    decodeB64Url(s, &sig) orelse return false;
    if (!std.crypto.timing_safe.eql([32]u8, mac, sig)) return false;
    // Expiry: find "exp":<digits> in the decoded payload.
    const plen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(p) catch return false;
    if (plen > 4096) return false;
    var pbuf: [4096]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(pbuf[0..plen], p) catch return false;
    const payload = pbuf[0..plen];
    if (findExp(payload)) |exp| {
        if (now_s > exp + @as(i64, leeway_s)) return false;
    }
    return true;
}

fn decodeB64Url(s: []const u8, out32: *[32]u8) ?void {
    // HMAC-SHA256 sigs decode to exactly 32 bytes; reject anything else.
    const dec_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(s) catch return null;
    if (dec_size != 32) return null;
    std.base64.url_safe_no_pad.Decoder.decode(out32, s) catch return null;
    return {};
}

fn findExp(payload: []const u8) ?i64 {
    // Minimal JSON scan: `"exp"` then `:` then optional spaces/quote digits.
    const key = std.mem.indexOf(u8, payload, "\"exp\"") orelse return null;
    var i = key + 5;
    while (i < payload.len and (payload[i] == ' ' or payload[i] == '\t' or payload[i] == ':')) : (i += 1) {}
    // Skip one colon explicitly if the loop above stopped early; simpler:
    // advance to the first digit or '-' after the key.
    while (i < payload.len and !(payload[i] == '-' or (payload[i] >= '0' and payload[i] <= '9'))) : (i += 1) {}
    if (i >= payload.len) return null;
    var j = i;
    if (payload[j] == '-') j += 1;
    const start = j;
    while (j < payload.len and payload[j] >= '0' and payload[j] <= '9') : (j += 1) {}
    if (j == start) return null;
    // Negative handled via the leading '-' at i.
    return std.fmt.parseInt(i64, payload[i..j], 10) catch null;
}


fn respHeader(resp: *const registry.Response, name: []const u8) ?[]const u8 {
    for (resp.headers[0..resp.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

const testing = std.testing;

test "cors attaches origin and answers preflight" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    req.method = .get;
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .cors_enabled = true, .cors_origin = "https://a.example" };
    try testing.expectEqual(Action.pass, try runCors(&ctx));
    try testing.expectEqualStrings("https://a.example", respHeader(&resp, "Access-Control-Allow-Origin").?);

    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.method = .options;
    var resp2 = registry.Response.init(.ok);
    var ctx2 = Context{ .req = &req2, .resp = &resp2 };
    ctx2.route = &.{ .path = "/", .cors_enabled = true, .cors_max_age = 600 };
    try testing.expectEqual(Action.handled, try runCors(&ctx2));
    try testing.expectEqual(Status.no_content, resp2.status);
    try testing.expect(respHeader(&resp2, "Access-Control-Allow-Methods") != null);
    try testing.expectEqualStrings("600", respHeader(&resp2, "Access-Control-Max-Age").?);
}

test "cors inert when disabled" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/" };
    try testing.expectEqual(Action.pass, try runCors(&ctx));
    try testing.expect(respHeader(&resp, "Access-Control-Allow-Origin") == null);
}

test "secure_link round-trips and rejects tampered/expired" {
    var sig: [64]u8 = undefined;
    signSecureLink("k", "/file", 9_999_999_999, &sig);
    try testing.expect(verifySecureLink("k", "/file", 9_999_999_999, &sig, 1_000));
    try testing.expect(!verifySecureLink("k", "/file", 500, &sig, 1_000)); // expired (also wrong e)
    var bad = sig;
    bad[0] = if (bad[0] == 'a') 'b' else 'a';
    try testing.expect(!verifySecureLink("k", "/file", 9_999_999_999, &bad, 1_000));
    try testing.expect(!verifySecureLink("other", "/file", 9_999_999_999, &sig, 1_000));
}

test "secure_link handler gates on query sig" {
    var sig: [64]u8 = undefined;
    signSecureLink("sek", "/dl", 9_999_999_999, &sig);
    var target_buf: [128]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "/dl?e=9999999999&s={s}", .{sig}) catch unreachable;
    const run_case = struct {
        fn go(target_str: []const u8, now: u64) !Action {
            var req = registry.Request.init(testing.allocator);
            defer req.deinit();
            req.method = .get;
            req.target = target_str;
            // query_string includes '?'; decoded_target is the path.
            if (std.mem.indexOfScalar(u8, target_str, '?')) |off| {
                req.query_string = target_str[off..];
                req.decoded_target = target_str[0..off];
            } else {
                req.query_string = "";
                req.decoded_target = target_str;
            }
            var resp = registry.Response.init(.ok);
            var ctx = Context{ .req = &req, .resp = &resp, .now_ns = now };
            ctx.route = &.{ .path = "/", .secure_link_secret = "sek" };
            const a = try runSecureLink(&ctx);
            try testing.expectEqual(if (a == .pass) Status.ok else Status.forbidden, resp.status);
            return a;
        }
    }.go;
    try testing.expectEqual(Action.pass, try run_case(target, 1_000 * 1_000_000_000));
    try testing.expectEqual(Action.handled, try run_case("/dl?e=1&s=00", 1_000 * 1_000_000_000));
    try testing.expectEqual(Action.handled, try run_case("/dl", 1_000 * 1_000_000_000));
}

test "jwt-lite accepts valid HS256 and rejects bad/expired" {
    // Build a token with the same primitives the verifier uses.
    const secret = "jwt-key";
    const h = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}
    const p = "eyJleHAiOjk5OTk5OTk5OTl9"; // {"exp":9999999999}
    var mac: [32]u8 = undefined;
    var hm = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hm.update(h);
    hm.update(".");
    hm.update(p);
    hm.final(&mac);
    var sig_buf: [64]u8 = undefined;
    const sig = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &mac);
    var tok_buf: [256]u8 = undefined;
    const token = std.fmt.bufPrint(&tok_buf, "{s}.{s}.{s}", .{ h, p, sig }) catch unreachable;
    try testing.expect(verifyJwtHs256(secret, token, 1_000, 60));
    try testing.expect(!verifyJwtHs256("wrong", token, 1_000, 60));
    // Expired payload.
    const pe = "eyJleHAiOjF9"; // {"exp":1}
    var mac2: [32]u8 = undefined;
    var hm2 = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hm2.update(h);
    hm2.update(".");
    hm2.update(pe);
    hm2.final(&mac2);
    var sig2_buf: [64]u8 = undefined;
    const sig2 = std.base64.url_safe_no_pad.Encoder.encode(&sig2_buf, &mac2);
    var tok2_buf: [256]u8 = undefined;
    const token2 = std.fmt.bufPrint(&tok2_buf, "{s}.{s}.{s}", .{ h, pe, sig2 }) catch unreachable;
    try testing.expect(!verifyJwtHs256(secret, token2, 1_000, 60));
    try testing.expect(verifyJwtHs256(secret, token2, 0, 60)); // within leeway
}

test "jwt handler 401s without a bearer token" {
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .auth_jwt_secret = "k" };
    try testing.expectEqual(Action.handled, try runAuthJwt(&ctx));
    try testing.expectEqual(Status.unauthorized, resp.status);
}

test "jwt es256 verifies with the fixture pair, rejects confusion" {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const testdata = @import("../../tls/testdata.zig");
    const cert_mod = @import("../../tls/cert.zig");
    // Sign header.payload with the fixture client key.
    const creds = try cert_mod.loadCredentials(testing.allocator, testdata.client_cert_pem, testdata.client_key_pem);
    defer testing.allocator.free(creds.cert_der);
    const h = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"ES256","typ":"JWT"}
    const p = "eyJleHAiOjk5OTk5OTk5OTl9"; // {"exp":9999999999}
    var msg: [256]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, "{s}.{s}", .{ h, p }) catch unreachable;
    var digest: [32]u8 = undefined;
    Ecdsa.Hash.hash(m, &digest, .{});
    const sk = try Ecdsa.SecretKey.fromBytes(creds.key.secret_key[0..Ecdsa.SecretKey.encoded_length].*);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    const sig = kp.sign(m, null) catch unreachable;
    const raw = sig.toBytes();
    var sig_b64: [128]u8 = undefined;
    const sig_s = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &raw);
    var tok: [512]u8 = undefined;
    const token = std.fmt.bufPrint(&tok, "{s}.{s}.{s}", .{ h, p, sig_s }) catch unreachable;
    // Pubkey from the fixture leaf.
    const leaf = blk: {
        const pem_mod = @import("../../tls/pem.zig");
        var lb: [4096]u8 = undefined;
        const ll = (try pem_mod.decodeFirst(testdata.client_cert_pem, "CERTIFICATE", &lb)) orelse return error.TestUnexpected;
        const parsed = try std.crypto.Certificate.parse(.{ .buffer = lb[0..ll], .index = 0 });
        var sec1: [65]u8 = undefined;
        @memcpy(&sec1, parsed.pubKey());
        break :blk sec1;
    };
    try testing.expect(verifyJwtEs256(&leaf, token, 1_000, 60));
    // HS256 token against the EC key: alg confusion fails closed.
    const hs = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjk5OTk5OTk5OTl9.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try testing.expect(!verifyJwtEs256(&leaf, hs, 1_000, 60));
    // Tampered payload fails.
    var bad_tok: [512]u8 = undefined;
    @memcpy(bad_tok[0..token.len], token);
    bad_tok[token.len - 3] ^= 0x01;
    try testing.expect(!verifyJwtEs256(&leaf, bad_tok[0..token.len], 1_000, 60));
}

test "jwt es256 handler gates on the key file" {
    const testdata = @import("../../tls/testdata.zig");
    const path = "/tmp/zocket-jwt-key-test.pem";
    compat.deleteFile(path) catch {};
    try compat.writeFile(path, testdata.client_cert_pem);
    defer compat.deleteFile(path) catch {};
    // Missing Authorization with key configured: 401 (fail closed).
    var req = registry.Request.init(testing.allocator);
    defer req.deinit();
    var resp = registry.Response.init(.ok);
    var ctx = Context{ .req = &req, .resp = &resp };
    ctx.route = &.{ .path = "/", .auth_jwt_key_file = path };
    try testing.expectEqual(Action.handled, try runAuthJwt(&ctx));
    try testing.expectEqual(Status.unauthorized, resp.status);
    // Garbage token: 401.
    var req2 = registry.Request.init(testing.allocator);
    defer req2.deinit();
    req2.addHeaderParsed("Authorization", "Bearer junk") catch unreachable;
    var resp2 = registry.Response.init(.ok);
    var ctx2 = Context{ .req = &req2, .resp = &resp2 };
    ctx2.route = &.{ .path = "/", .auth_jwt_key_file = path };
    try testing.expectEqual(Action.handled, try runAuthJwt(&ctx2));
    // Bad key path: 401, never pass.
    var req3 = registry.Request.init(testing.allocator);
    defer req3.deinit();
    req3.addHeaderParsed("Authorization", "Bearer junk") catch unreachable;
    var resp3 = registry.Response.init(.ok);
    var ctx3 = Context{ .req = &req3, .resp = &resp3 };
    ctx3.route = &.{ .path = "/", .auth_jwt_key_file = "/nonexistent/key.pem" };
    try testing.expectEqual(Action.handled, try runAuthJwt(&ctx3));
}
