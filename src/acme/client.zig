//! ACME v2 issuance loop (D3): account → order → http-01 challenge →
//! finalize → download → install, on top of the shipped JWS (`jws.zig`)
//! and http-01 responder (`dsl/modules/acme_challenge.zig`).
//!
//! `runOnce` drives one issuance for every configured domain and writes
//! the certificate + key PEMs over the configured paths (atomic rename).
//! The transport is abstracted for tests: `FakeCA` (below) serves the
//! protocol over loopback HTTP and exercises the full flow; the real
//! transport speaks HTTP/1.1 over TCP, with TLS for https:// URLs.

const std = @import("std");
const sys = @import("../sys.zig");
const jws = @import("jws.zig");
const der = @import("der.zig");
const acme_challenge = @import("../dsl/modules/acme_challenge.zig");
const Certificate = std.crypto.Certificate;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Error = error{
    AcmeConfigInvalid,
    AcmeDirectoryFailed,
    AcmeAccountFailed,
    AcmeOrderFailed,
    AcmeChallengeFailed,
    AcmeFinalizeFailed,
    AcmeDownloadFailed,
    AcmeBadResponse,
    AcmeTimeout,
    OutOfMemory,
};

pub const Config = struct {
    directory: []const u8,
    contact: []const u8 = "",
    domains: []const []const u8,
    /// PEM account key (generated on first use).
    account_key_path: []const u8,
    /// Output paths for the issued certificate chain + private key.
    cert_path: []const u8,
    key_path: []const u8,
};

/// Case-insensitive header lookup in a raw header block (tested).
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Extract a top-level string field from a (small) JSON object — enough
/// for the ACME wire (`"status"`, `"url"`, `"finalize"`, ...). No std.json
/// dependency for the parser hot spots; strings only, no nesting.
pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, json, i, key)) |pos| {
        i = pos + key.len;
        // Must be a quoted key.
        if (pos == 0 or json[pos - 1] != '"') continue;
        if (i >= json.len or json[i] != '"') continue;
        i += 1;
        // Skip spaces and colon.
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
        if (i >= json.len or json[i] != '"') continue;
        i += 1;
        const start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return null;
        return json[start..i];
    }
    return null;
}

/// Same, but for a JSON array of strings under `key` (e.g.
/// `"authorizations":["https://…"]`). Single array level.
pub fn jsonStringArray(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[][]const u8 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    var i = pos + key.len;
    while (i < json.len and json[i] != '[') : (i += 1) {}
    if (i >= json.len) return null;
    i += 1;
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    while (i < json.len and json[i] != ']') {
        if (json[i] == '"') {
            i += 1;
            const start = i;
            while (i < json.len and json[i] != '"') : (i += 1) {}
            if (i >= json.len) return null;
            try out.append(allocator, json[start..i]);
            i += 1;
        } else i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// One HTTP response.
pub const Response = struct {
    status: u16,
    body: []u8,
    /// Replay-Nonce header value (borrowed from `head`).
    nonce: ?[]const u8 = null,
    /// Location header value (borrowed from `head`).
    location: ?[]const u8 = null,
    head: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.head);
    }
};

/// Blocking HTTP/1.1 transport: TCP (+ TLS for https URLs) with
/// Connection: close semantics (one request per connection — ACME rate is
/// low and this keeps the client trivial and robust).
pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    /// Lazily-loaded system trust bundle for https.
    ca: ?*Certificate.Bundle = null,
    mutex: sys.Mutex = .{},
    ca_loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator) HttpTransport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HttpTransport) void {
        if (self.ca) |b| {
            b.deinit(self.allocator);
            self.allocator.destroy(b);
            self.ca = null;
        }
    }

    fn systemCa(self: *HttpTransport) ?*Certificate.Bundle {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ca_loaded) return self.ca;
        self.ca_loaded = true;
        const io = std.Io.Threaded.global_single_threaded.io();
        const bundle = self.allocator.create(Certificate.Bundle) catch return null;
        bundle.* = Certificate.Bundle.empty;
        // System roots (Debian/Ubuntu layout; harmless when missing).
        const ts = sys.clock_gettime(std.posix.CLOCK.REALTIME) catch return null;
        const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec };
        bundle.addCertsFromDirPathAbsolute(self.allocator, io, now, "/etc/ssl/certs") catch {};
        self.ca = bundle;
        return bundle;
    }

    pub fn request(
        self: *HttpTransport,
        method: []const u8,
        url: []const u8,
        content_type: ?[]const u8,
        body: ?[]const u8,
    ) !Response {
        var url_rest = url;
        var tls = false;
        if (std.mem.startsWith(u8, url_rest, "https://")) {
            tls = true;
            url_rest = url_rest["https://".len..];
        } else if (std.mem.startsWith(u8, url_rest, "http://")) {
            url_rest = url_rest["http://".len..];
        } else return error.AcmeBadResponse;
        const slash = std.mem.indexOfScalar(u8, url_rest, '/') orelse return error.AcmeBadResponse;
        const authority = url_rest[0..slash];
        const path = url_rest[slash..];
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        const host = if (colon) |c| authority[0..c] else authority;
        const port: u16 = if (colon) |c|
            std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.AcmeBadResponse
        else if (tls) 443 else 80;

        // Resolve via the async-capable resolver's blocking entry point.
        const resolver = @import("../net/dns_resolver.zig");
        var addrs: [4][4]u8 = undefined;
        var addr_count: usize = 0;
        var port_off: u16 = 0;
        if (parseIp4(host)) |octets| {
            addrs[0] = octets;
            addr_count = 1;
            port_off = port;
        } else {
            const srv = resolver.currentServers();
            const res = resolver.resolveBlocking(host, srv, 53) catch return error.AcmeDirectoryFailed;
            if (res.count == 0) return error.AcmeDirectoryFailed;
            var i: usize = 0;
            while (i < res.count and i < addrs.len) : (i += 1) addrs[i] = res.addrs[i];
            addr_count = @min(res.count, addrs.len);
            port_off = port;
        }

        var connected: ?std.posix.fd_t = null;
        var i: usize = 0;
        while (i < addr_count) : (i += 1) {
            const fd = sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch continue;
            var sa = std.posix.sockaddr{ .family = std.posix.AF.INET, .data = @as([14]u8, @splat(@as(u8, 0))) };
            std.mem.writeInt(u16, sa.data[0..2], port_off, .big);
            @memcpy(sa.data[2..6], &addrs[i]);
            sys.connect(fd, &sa, 16) catch {
                sys.close(fd);
                continue;
            };
            connected = fd;
            break;
        }
        const fd = connected orelse return error.AcmeDirectoryFailed;

        if (tls) {
            const bundle = self.systemCa() orelse {
                sys.close(fd);
                return error.AcmeDirectoryFailed;
            };
            return self.tlsRequest(fd, host, method, path, content_type, body, bundle);
        }
        defer sys.close(fd);

        var req = std.ArrayList(u8).empty;
        defer req.deinit(self.allocator);
        req.print(self.allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, authority }) catch return error.AcmeBadResponse;
        if (content_type) |ct| req.print(self.allocator, "Content-Type: {s}\r\n", .{ct}) catch return error.AcmeBadResponse;
        const blen = if (body) |b| b.len else 0;
        if (body != null) req.print(self.allocator, "Content-Length: {d}\r\n", .{blen}) catch return error.AcmeBadResponse;
        req.appendSlice(self.allocator, "\r\n") catch return error.AcmeBadResponse;
        if (body) |b| req.appendSlice(self.allocator, b) catch return error.AcmeBadResponse;
        try sys.writeAll(fd, req.items);
        return self.readResponse(fd);
    }

    fn tlsRequest(
        self: *HttpTransport,
        fd: std.posix.fd_t,
        host: []const u8,
        method: []const u8,
        path: []const u8,
        content_type: ?[]const u8,
        body: ?[]const u8,
        bundle: *Certificate.Bundle,
    ) !Response {
        defer sys.close(fd);
        // The std TLS client needs blocking-ish semantics; this path runs
        // on the ACME worker thread only (one request at a time).
        const io = std.Io.Threaded.global_single_threaded.io();
        const stream = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
        var rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var trbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var twbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        sys.randomBytes(&entropy);
        var lock = std.Io.RwLock.init;
        var client = std.crypto.tls.Client.init(&reader.interface, &writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = std.heap.page_allocator, .io = io, .lock = &lock, .bundle = bundle } },
            .write_buffer = &twbuf,
            .read_buffer = &trbuf,
            .entropy = &entropy,
            .realtime_now = blk: {
                const ts = sys.clock_gettime(std.posix.CLOCK.REALTIME) catch break :blk .{ .nanoseconds = 0 };
                break :blk .{ .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec };
            },
            .allow_truncation_attacks = true,
        }) catch return error.AcmeDirectoryFailed;

        var req = std.ArrayList(u8).empty;
        defer req.deinit(std.heap.page_allocator);
        const A = std.heap.page_allocator;
        req.print(A, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, host }) catch return error.AcmeBadResponse;
        if (content_type) |ct| req.print(A, "Content-Type: {s}\r\n", .{ct}) catch return error.AcmeBadResponse;
        const blen = if (body) |b| b.len else 0;
        if (body != null) req.print(A, "Content-Length: {d}\r\n", .{blen}) catch return error.AcmeBadResponse;
        req.appendSlice(A, "\r\n") catch return error.AcmeBadResponse;
        if (body) |b| req.appendSlice(A, b) catch return error.AcmeBadResponse;
        client.writer.writeAll(req.items) catch return error.AcmeDirectoryFailed;
        client.writer.flush() catch return error.AcmeDirectoryFailed;
        writer.interface.flush() catch return error.AcmeDirectoryFailed;

        // Read the whole response out of the record layer.
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        while (true) {
            const buffered = client.reader.buffered();
            if (buffered.len > 0) {
                try out.appendSlice(self.allocator, buffered);
                client.reader.toss(buffered.len);
                continue;
            }
            // readSliceShort returns 0 on clean EOF (close_notify).
            var stage: [4096]u8 = undefined;
            const n = client.reader.readSliceShort(stage[0..]) catch return error.AcmeDirectoryFailed;
            if (n == 0) break;
            try out.appendSlice(self.allocator, stage[0..n]);
        }
        return parseHttpResponse(self.allocator, out.items);
    }

    fn readResponse(self: *HttpTransport, fd: std.posix.fd_t) !Response {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(fd, &buf) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return error.AcmeDirectoryFailed,
            };
            if (n == 0) break;
            try out.appendSlice(self.allocator, buf[0..n]);
        }
        return parseHttpResponse(self.allocator, out.items);
    }
};

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn parseIp4(host: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return octets;
}

/// Split a raw HTTP/1.1 response into status + headers + (Content-Length
/// or chunked-decoded) body. Pure over bytes (unit-tested).
pub fn parseHttpResponse(allocator: std.mem.Allocator, raw: []const u8) !Response {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.AcmeBadResponse;
    const head = try allocator.dupe(u8, raw[0..head_end]);
    errdefer allocator.free(head);
    var it = std.mem.splitScalar(u8, head, '\r'); // status line is head[0..line]
    const status_line = std.mem.trim(u8, it.first(), "\r\n ");
    var toks = std.mem.tokenizeAny(u8, status_line, " ");
    _ = toks.next() orelse return error.AcmeBadResponse;
    const code_str = toks.next() orelse return error.AcmeBadResponse;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return error.AcmeBadResponse;
    const body_raw = raw[head_end + 4 ..];
    var body: []u8 = undefined;
    if (headerValue(head, "transfer-encoding")) |te| {
        if (indexOfIgnoreCase(te, "chunked") != null) {
            body = try decodeChunked(allocator, body_raw);
        } else {
            body = try allocator.dupe(u8, body_raw);
        }
    } else {
        body = try allocator.dupe(u8, body_raw);
    }
    errdefer allocator.free(body);
    return .{
        .status = status,
        .body = body,
        .nonce = headerValue(head, "replay-nonce"),
        .location = headerValue(head, "location"),
        .head = head,
    };
}

fn decodeChunked(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        const nl = std.mem.indexOfScalarPos(u8, raw, i, '\n') orelse break;
        var line = std.mem.trim(u8, raw[i..nl], "\r\n ");
        if (std.mem.indexOfScalar(u8, line, ';')) |semi| line = line[0..semi];
        const size = std.fmt.parseInt(usize, line, 16) catch break;
        i = nl + 1;
        if (size == 0) break;
        if (i + size > raw.len) break;
        try out.appendSlice(allocator, raw[i .. i + size]);
        i += size;
        // Skip CRLF.
        while (i < raw.len and (raw[i] == '\r' or raw[i] == '\n')) : (i += 1) {}
    }
    return out.toOwnedSlice(allocator);
}

/// One issuance run. `on_progress` is optional logging.
pub fn runOnce(
    allocator: std.mem.Allocator,
    cfg: Config,
    transport: anytype,
    logFn: ?*const fn (msg: []const u8) void,
) !void {
    const log = struct {
        fn call(f: ?*const fn ([]const u8) void, msg: []const u8) void {
            if (f) |ff| ff(msg);
        }
    }.call;

    if (cfg.domains.len == 0 or cfg.directory.len == 0) return error.AcmeConfigInvalid;

    // 1. Account key: load or generate.
    var secret: [32]u8 = undefined;
    if (sys.readFileAlloc(allocator, cfg.account_key_path, 1 << 20)) |pem| {
        defer allocator.free(pem);
        const pem_mod = @import("../tls/pem.zig");
        var buf: [256]u8 = undefined;
        const key_len = (pem_mod.decodeFirst(pem, "EC PRIVATE KEY", &buf) catch null) orelse
            return error.AcmeConfigInvalid;
        secret = parseSec1Scalar(buf[0..key_len]) orelse return error.AcmeConfigInvalid;
    } else |_| {
        const kp = try Ecdsa.KeyPair.generateDeterministic(blk: {
            var seed: [32]u8 = undefined;
            sys.randomBytes(&seed);
            break :blk seed;
        });
        secret = kp.secret_key.toBytes();
        const key_der = try der.sec1PrivateKey(allocator, &secret);
        defer allocator.free(key_der);
        const pem = try der.pemEncode(allocator, "EC PRIVATE KEY", key_der);
        defer allocator.free(pem);
        try sys.writeFile(cfg.account_key_path, pem);
        {
            var mb: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&mb, "acme: generated account key {s}", .{cfg.account_key_path}) catch "acme: account key";
            log(logFn, m);
        }
    }
    const acc_kp = blk: {
        const sk = try Ecdsa.SecretKey.fromBytes(secret);
        break :blk try Ecdsa.KeyPair.fromSecretKey(sk);
    };
    const pub_sec1 = acc_kp.public_key.toUncompressedSec1();
    const thumb = try jws.thumbprint(&pub_sec1);

    // 2. Directory.
    var dir = try transport.request("GET", cfg.directory, null, null);
    defer dir.deinit(allocator);
    if (dir.status != 200) return error.AcmeDirectoryFailed;
    const new_nonce_url = jsonString(dir.body, "newNonce") orelse return error.AcmeDirectoryFailed;
    const new_account_url = jsonString(dir.body, "newAccount") orelse return error.AcmeDirectoryFailed;
    const new_order_url = jsonString(dir.body, "newOrder") orelse return error.AcmeDirectoryFailed;

    // 3. Nonce.
    var nonce_resp = try transport.request("GET", new_nonce_url, null, null);
    defer nonce_resp.deinit(allocator);
    var nonce_buf: [128]u8 = undefined;
    var nonce = nonce_buf[0..copyInto(&nonce_buf, nonce_resp.nonce orelse return error.AcmeDirectoryFailed)];

    // 4. Account (newAccount; existing accounts return 200 + Location).
    const jwk_protected = try buildProtected(allocator, nonce, new_account_url, null, &pub_sec1);
    defer allocator.free(jwk_protected);
    const acc_payload = if (cfg.contact.len > 0)
        try std.fmt.allocPrint(allocator, "{{\"termsOfServiceAgreed\":true,\"contact\":[\"{s}\"]}}", .{cfg.contact})
    else
        try allocator.dupe(u8, "{\"termsOfServiceAgreed\":true}");
    defer allocator.free(acc_payload);
    var acc = try signedPost(allocator, transport, &secret, jwk_protected, new_account_url, acc_payload, null);
    defer acc.deinit(allocator);
    if (acc.status != 200 and acc.status != 201) return error.AcmeAccountFailed;
    const kid = try allocator.dupe(u8, acc.location orelse return error.AcmeAccountFailed);
    defer allocator.free(kid);
    if (acc.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];
    {
        var mb: [512]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "acme: account {s}", .{kid}) catch "acme: account";
        log(logFn, m);
    }

    // 5. Order.
    var order_payload = std.ArrayList(u8).empty;
    defer order_payload.deinit(allocator);
    {
        order_payload.appendSlice(allocator, "{\"identifiers\":[") catch return error.AcmeOrderFailed;
        for (cfg.domains, 0..) |d, i| {
            if (i > 0) order_payload.appendSlice(allocator, ",") catch return error.AcmeOrderFailed;
            order_payload.print(allocator, "{{\"type\":\"dns\",\"value\":\"{s}\"}}", .{d}) catch return error.AcmeOrderFailed;
        }
        order_payload.appendSlice(allocator, "]}") catch return error.AcmeOrderFailed;
    }
    const kid_protected = try buildProtected(allocator, nonce, new_order_url, kid, &pub_sec1);
    defer allocator.free(kid_protected);
    var order = try signedPost(allocator, transport, &secret, kid_protected, new_order_url, order_payload.items, null);
    defer order.deinit(allocator);
    if (order.status != 201 and order.status != 200) return error.AcmeOrderFailed;
    const order_url = try allocator.dupe(u8, order.location orelse new_order_url);
    defer allocator.free(order_url);
    const finalize_url = try allocator.dupe(u8, jsonString(order.body, "finalize") orelse return error.AcmeOrderFailed);
    defer allocator.free(finalize_url);
    const authz_urls = (try jsonStringArray(allocator, order.body, "\"authorizations\"")) orelse
        return error.AcmeOrderFailed;
    defer allocator.free(authz_urls);
    if (order.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];

    // 6. Challenges: fetch each authz, publish keyAuth, trigger, poll.
    for (authz_urls) |authz_url| {
        const kid_p = try buildProtected(allocator, nonce, authz_url, kid, &pub_sec1);
        defer allocator.free(kid_p);
        var authz = try signedPost(allocator, transport, &secret, kid_p, authz_url, "", null);
        defer authz.deinit(allocator);
        if (authz.status != 200) return error.AcmeChallengeFailed;
        if (authz.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];
        // Find the http-01 challenge URL + token (borrowed from the
        // authorization body, valid until `authz` is deinited below).
        const ch_url = findHttp01Url(authz.body) orelse return error.AcmeChallengeFailed;
        const token = findHttp01Token(authz.body) orelse return error.AcmeChallengeFailed;
        var key_auth: [256]u8 = undefined;
        const ka = std.fmt.bufPrint(&key_auth, "{s}.{s}", .{ token, thumb }) catch return error.AcmeChallengeFailed;
        if (!acme_challenge.putChallenge(token, ka)) return error.AcmeChallengeFailed;
        {
            var mb: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&mb, "acme: challenge published for token {s}", .{token}) catch "acme: challenge";
            log(logFn, m);
        }

        const ch_p = try buildProtected(allocator, nonce, ch_url, kid, &pub_sec1);
        defer allocator.free(ch_p);
        var ch = try signedPost(allocator, transport, &secret, ch_p, ch_url, "{}", null);
        defer ch.deinit(allocator);
        if (ch.status != 200) return error.AcmeChallengeFailed;
        if (ch.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];

        // Poll the authorization until it leaves pending.
        var attempts: usize = 0;
        while (attempts < 60) : (attempts += 1) {
            sys.nanosleep(1, 0);
            const poll_p = try buildProtected(allocator, nonce, authz_url, kid, &pub_sec1);
            defer allocator.free(poll_p);
            var state = try signedPost(allocator, transport, &secret, poll_p, authz_url, "", null);
            defer state.deinit(allocator);
            if (state.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];
            const status = jsonString(state.body, "status") orelse "unknown";
            if (std.mem.eql(u8, status, "valid")) break;
            if (std.mem.eql(u8, status, "invalid")) {
                acme_challenge.clearChallenge(token);
                return error.AcmeChallengeFailed;
            }
        }
        acme_challenge.clearChallenge(token);
    }

    // 7. Certificate key + CSR + finalize.
    const cert_kp = try Ecdsa.KeyPair.generateDeterministic(blk: {
        var seed: [32]u8 = undefined;
        sys.randomBytes(&seed);
        break :blk seed;
    });
    const cert_pub = cert_kp.public_key.toUncompressedSec1();
    const built = try der.buildCsr(allocator, cfg.domains, &cert_pub);
    defer allocator.free(built.csr);
    var csr_sig = cert_kp.sign(built.tbs, null) catch return error.AcmeFinalizeFailed;
    var csr_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const csr_sig_der = csr_sig.toDer(&csr_der_buf);
    const csr = try der.finishCsr(allocator, built.tbs, csr_sig_der);
    defer allocator.free(csr);
    const csr_b64 = try jws.b64urlEncode(allocator, csr);
    defer allocator.free(csr_b64);
    var fin_payload = std.ArrayList(u8).empty;
    defer fin_payload.deinit(allocator);
    fin_payload.print(allocator, "{{\"csr\":\"{s}\"}}", .{csr_b64}) catch return error.AcmeFinalizeFailed;

    const fin_p = try buildProtected(allocator, nonce, finalize_url, kid, &pub_sec1);
    defer allocator.free(fin_p);
    var fin = try signedPost(allocator, transport, &secret, fin_p, finalize_url, fin_payload.items, null);
    defer fin.deinit(allocator);
    if (fin.status != 200) return error.AcmeFinalizeFailed;
    if (fin.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];

    // 8. Poll the order for the certificate URL.
    var cert_url: ?[]const u8 = jsonString(fin.body, "certificate");
    var cert_url_owned: ?[]u8 = null;
    defer if (cert_url_owned) |c| allocator.free(c);
    var attempts: usize = 0;
    while (cert_url == null and attempts < 60) : (attempts += 1) {
        sys.nanosleep(1, 0);
        const op = try buildProtected(allocator, nonce, order_url, kid, &pub_sec1);
        defer allocator.free(op);
        var st = try signedPost(allocator, transport, &secret, op, order_url, "", null);
        defer st.deinit(allocator);
        if (st.nonce) |n| nonce = nonce_buf[0..copyInto(&nonce_buf, n)];
        const status = jsonString(st.body, "status") orelse "unknown";
        if (std.mem.eql(u8, status, "invalid")) return error.AcmeFinalizeFailed;
        if (jsonString(st.body, "certificate")) |cu| {
            cert_url_owned = try allocator.dupe(u8, cu);
            cert_url = cert_url_owned.?;
        }
    }
    const cu = cert_url orelse return error.AcmeTimeout;

    // 9. Download the chain (POST-as-GET) and install PEM files.
    const cp = try buildProtected(allocator, nonce, cu, kid, &pub_sec1);
    defer allocator.free(cp);
    var chain = try signedPost(allocator, transport, &secret, cp, cu, "", null);
    defer chain.deinit(allocator);
    if (chain.status != 200) return error.AcmeDownloadFailed;
    try sys.writeFile(cfg.cert_path, chain.body);

    const key_der = try der.sec1PrivateKey(allocator, &cert_kp.secret_key.toBytes());
    defer allocator.free(key_der);
    const key_pem = try der.pemEncode(allocator, "EC PRIVATE KEY", key_der);
    defer allocator.free(key_pem);
    try sys.writeFile(cfg.key_path, key_pem);
    {
        var mb: [512]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "acme: issued for {d} domain(s) -> {s}", .{ cfg.domains.len, cfg.cert_path }) catch "acme: issued";
        log(logFn, m);
    }
}

/// Extract the 32-byte P-256 scalar from a SEC1 EC private key DER
/// (`04 20 <scalar>` — the OCTET STRING holding the private key).
fn parseSec1Scalar(der_bytes: []const u8) ?[32]u8 {
    var i: usize = 0;
    while (i + 2 + 32 <= der_bytes.len) : (i += 1) {
        if (der_bytes[i] == 0x04 and der_bytes[i + 1] == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, der_bytes[i + 2 ..][0..32]);
            return out;
        }
    }
    return null;
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// JWS protected header for the ACME account key (jwk or kid).
fn buildProtected(
    allocator: std.mem.Allocator,
    nonce: []const u8,
    url: []const u8,
    kid: ?[]const u8,
    pub_sec1: *const [65]u8,
) ![]u8 {
    var plain = std.ArrayList(u8).empty;
    defer plain.deinit(allocator);
    if (kid) |k| {
        plain.print(allocator, "{{\"alg\":\"ES256\",\"nonce\":\"{s}\",\"url\":\"{s}\",\"kid\":\"{s}\"}}", .{ nonce, url, k }) catch return error.OutOfMemory;
    } else {
        const x = try jws.b64urlEncode(allocator, pub_sec1[1..33]);
        defer allocator.free(x);
        const y = try jws.b64urlEncode(allocator, pub_sec1[33..65]);
        defer allocator.free(y);
        plain.print(allocator, "{{\"alg\":\"ES256\",\"nonce\":\"{s}\",\"url\":\"{s}\",\"jwk\":{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{s}\",\"y\":\"{s}\"}}}}", .{ nonce, url, x, y }) catch return error.OutOfMemory;
    }
    return try jws.b64urlEncode(allocator, plain.items);
}

/// POST one JWS-signed request; `payload` is the raw JSON ("" = POST-as-GET).
fn signedPost(
    allocator: std.mem.Allocator,
    transport: anytype,
    secret: *const [32]u8,
    protected_b64: []const u8,
    url: []const u8,
    payload: []const u8,
    _: ?void,
) !Response {
    const payload_b64 = try jws.b64urlEncode(allocator, payload);
    defer allocator.free(payload_b64);
    const body = try jws.signCompact(allocator, secret, protected_b64, payload_b64);
    defer allocator.free(body);
    return transport.request("POST", url, "application/jose+json", body);
}

fn findHttp01Url(body: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, "\"http-01\"") orelse return null;
    // The challenge object: {"type":"http-01","url":"...","token":"..."}
    // Scan forward for "url".
    return jsonString(body[pos..], "url") orelse null;
}
fn findHttp01Token(body: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, "\"http-01\"") orelse return null;
    return jsonString(body[pos..], "token") orelse null;
}

const testing = std.testing;

test "jsonString extracts flat fields" {
    const j = "{\"status\":\"valid\",\"finalize\":\"https://x/fin\",\"n\":3}";
    try testing.expectEqualStrings("valid", jsonString(j, "status").?);
    try testing.expectEqualStrings("https://x/fin", jsonString(j, "finalize").?);
    try testing.expect(jsonString(j, "missing") == null);
}

test "jsonStringArray extracts authorization URLs" {
    const j = "{\"status\":\"pending\",\"authorizations\":[\"https://a/1\",\"https://a/2\"]}";
    const arr = (try jsonStringArray(testing.allocator, j, "\"authorizations\"")).?;
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("https://a/1", arr[0]);
}

test "http response parse handles content-length and chunked" {
    const raw = "HTTP/1.1 201 Created\r\nReplay-Nonce: abc\r\nLocation: https://x/acct\r\nContent-Length: 2\r\n\r\nhi";
    var r = try parseHttpResponse(testing.allocator, raw);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 201), r.status);
    try testing.expectEqualStrings("hi", r.body);
    try testing.expectEqualStrings("abc", r.nonce.?);
    try testing.expectEqualStrings("https://x/acct", r.location.?);

    const chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    var rc = try parseHttpResponse(testing.allocator, chunked);
    defer rc.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", rc.body);
}

test "headerValue is case-insensitive" {
    const head = "HTTP/1.1 200 OK\r\nreplay-NONCE:  zz \r\n";
    try testing.expectEqualStrings("zz", headerValue(head, "Replay-Nonce").?);
}

/// Fake CA for tests: serves the ACME v2 surface over loopback HTTP with
/// fixed answers, exercising the whole `runOnce` flow (directory → nonce →
/// account → order → authz → challenge → finalize → poll → download).
pub const FakeCA = struct {
    listener: std.posix.fd_t,
    port: u16,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    /// Nonce counter.
    nonces: std.atomic.Value(u32) = .init(0),
    /// Certificate chain served at /cert/N.
    cert_pem: []const u8,
    /// Set when the challenge was fetched successfully by the CA.
    challenge_ok: std.atomic.Value(bool) = .init(false),
    /// Key authorization the CA expects for /chal/1 (token.tp).
    expect_key_auth: [300]u8 = undefined,
    expect_key_auth_len: usize = 0,

    pub fn start(allocator: std.mem.Allocator, cert_pem: []const u8, expect_key_auth: []const u8) !*FakeCA {
        const self = try allocator.create(FakeCA);
        const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        try sys.bind(lfd, @ptrCast(&addr), 16);
        try sys.listen(lfd, 16);
        var slen: std.posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try sys.getsockname(lfd, @ptrCast(&bound), &slen);
        self.* = .{
            .listener = lfd,
            .port = (@as(u16, bound[2]) << 8) | bound[3],
            .cert_pem = cert_pem,
        };
        const n = @min(expect_key_auth.len, self.expect_key_auth.len);
        @memcpy(self.expect_key_auth[0..n], expect_key_auth[0..n]);
        self.expect_key_auth_len = n;
        self.thread = try std.Thread.spawn(.{}, runFn, .{self});
        return self;
    }

    pub fn stop(self: *FakeCA) void {
        self.stop_flag.store(true, .release);
        sys.close(self.listener);
        self.thread.join();
    }

    fn url(self: *FakeCA, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch "";
    }

    fn nextNonce(self: *FakeCA, buf: []u8) []const u8 {
        const n = self.nonces.fetchAdd(1, .monotonic);
        return std.fmt.bufPrint(buf, "nonce-{d}", .{n}) catch "nonce";
    }

    fn runFn(self: *FakeCA) void {
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]std.posix.pollfd{.{ .fd = self.listener, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 100) catch break;
            if (ready == 0) continue;
            const cfd = std.os.linux.accept4(self.listener, null, null, 0);
            if (std.os.linux.errno(cfd) != .SUCCESS) break;
            const fd: std.posix.fd_t = @intCast(cfd);
            self.serveOne(fd);
            sys.close(fd);
        }
    }

    fn serveOne(self: *FakeCA, fd: std.posix.fd_t) void {
        var buf: [8192]u8 = undefined;
        var used: usize = 0;
        var head_end: usize = 0;
        // Read the head.
        while (used < buf.len) {
            const n = std.posix.read(fd, buf[used..]) catch return;
            if (n == 0) return;
            used += n;
            if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n")) |he| {
                head_end = he + 4;
                break;
            }
        }
        if (head_end == 0) return;
        const head = buf[0..head_end];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const request_line = lines.next() orelse return;
        var toks = std.mem.tokenizeAny(u8, request_line, " ");
        const method = toks.next() orelse return;
        const path = toks.next() orelse return;
        // Read the body when Content-Length is present.
        var body_len: usize = 0;
        if (headerValue(head, "content-length")) |cl| {
            body_len = std.fmt.parseInt(usize, cl, 10) catch 0;
        }
        while (used < head_end + body_len and used < buf.len) {
            const n = std.posix.read(fd, buf[used..]) catch return;
            if (n == 0) break;
            used += n;
        }
        const body = buf[head_end..@min(used, head_end + body_len)];

        // Request-scoped arena for the payload strings (they must outlive
        // the branch that builds them — a bare defer free would dangle).
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        var resp = std.ArrayList(u8).empty;
        defer resp.deinit(std.heap.page_allocator);
        var status: u16 = 404;
        var payload: []const u8 = "{}";
        var location: []const u8 = "";
        var url_buf: [128]u8 = undefined;

        if (std.mem.eql(u8, path, "/directory")) {
            status = 200;
            var nb: [128]u8 = undefined;
            var ab: [128]u8 = undefined;
            var ob: [128]u8 = undefined;
            payload = std.fmt.allocPrint(arena_state.allocator(),
                "{{\"newNonce\":\"{s}\",\"newAccount\":\"{s}\",\"newOrder\":\"{s}\"}}", .{
                self.url(&nb, "/nonce"),
                self.url(&ab, "/acct"),
                self.url(&ob, "/order"),
            }) catch return;
        } else if (std.mem.eql(u8, path, "/nonce")) {
            status = 200;
            payload = "";
        } else if (std.mem.eql(u8, path, "/acct")) {
            status = 201;
            payload = "{\"status\":\"valid\"}";
            location = self.url(&url_buf, "/acct/1");
        } else if (std.mem.eql(u8, path, "/order")) {
            status = 201;
            var zb: [128]u8 = undefined;
            var fb: [128]u8 = undefined;
            payload = std.fmt.allocPrint(arena_state.allocator(),
                "{{\"status\":\"pending\",\"authorizations\":[\"{s}\"],\"finalize\":\"{s}\"}}", .{
                self.url(&zb, "/authz/1"),
                self.url(&fb, "/finalize/1"),
            }) catch return;
            location = self.url(&url_buf, "/order/1");
        } else if (std.mem.eql(u8, path, "/authz/1")) {
            status = 200;
            var cb: [128]u8 = undefined;
            payload = std.fmt.allocPrint(arena_state.allocator(),
                "{{\"status\":\"valid\",\"challenges\":[{{\"type\":\"http-01\",\"url\":\"{s}\",\"token\":\"tok1\"}}]}}", .{
                self.url(&cb, "/chal/1"),
            }) catch return;
        } else if (std.mem.eql(u8, path, "/chal/1")) {
            status = 200;
            payload = "{}";
            // Best-effort: the CA "validated" the token.
            self.challenge_ok.store(true, .release);
        } else if (std.mem.eql(u8, path, "/finalize/1")) {
            status = 200;
            payload = "{\"status\":\"processing\"}";
        } else if (std.mem.eql(u8, path, "/order/1")) {
            status = 200;
            var cb: [128]u8 = undefined;
            payload = std.fmt.allocPrint(arena_state.allocator(),
                "{{\"status\":\"valid\",\"certificate\":\"{s}\"}}", .{self.url(&cb, "/cert/1")}) catch return;
        } else if (std.mem.eql(u8, path, "/cert/1")) {
            status = 200;
            payload = self.cert_pem;
        } else {
            status = 404;
        }
        _ = method;
        _ = body;

        var nbuf: [64]u8 = undefined;
        const n = self.nextNonce(&nbuf);
        const A = std.heap.page_allocator;
        resp.print(A, "HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nReplay-Nonce: {s}\r\nConnection: close\r\n", .{ status, payload.len, n }) catch return;
        if (location.len > 0) resp.print(A, "Location: {s}\r\n", .{location}) catch return;
        resp.appendSlice(A, "\r\n") catch return;
        resp.appendSlice(A, payload) catch return;
        _ = sys.writeAll(fd, resp.items) catch return;
    }
};

test "acme runOnce completes a full issuance against the fake CA" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buf: [std.fs.max_path_bytes]u8 = undefined;
    const acct_path = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/acct.pem", .{tmp.sub_path});
    const cert_path = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});

    const testdata = @import("../tls/testdata.zig");
    const fake = try FakeCA.start(allocator, testdata.cert_pem, "tok1.unused");
    defer {
        fake.stop();
        allocator.destroy(fake);
    }

    var dir_buf: [128]u8 = undefined;
    const directory = try std.fmt.bufPrint(&dir_buf, "http://127.0.0.1:{d}/directory", .{fake.port});
    const domains = [_][]const u8{"example.test"};

    // Certificate key path: runOnce writes it next to the cert path.
    var certkey_buf: [std.fs.max_path_bytes]u8 = undefined;
    const certkey_path = try std.fmt.bufPrint(&certkey_buf, ".zig-cache/tmp/{s}/cert.key", .{tmp.sub_path});

    var transport = HttpTransport.init(allocator);
    defer transport.deinit();

    const LogFn = struct {
        fn log(msg: []const u8) void {
            std.debug.print("  acme-test: {s}\n", .{msg});
        }
    }.log;

    try runOnce(allocator, .{
        .directory = directory,
        .domains = &domains,
        .account_key_path = acct_path,
        .cert_path = cert_path,
        .key_path = certkey_path,
    }, &transport, LogFn);

    // Downloaded chain landed byte-exact; key parses; challenges cleaned.
    const chain = try sys.readFileAlloc(allocator, cert_path, 1 << 20);
    defer allocator.free(chain);
    try testing.expectEqualStrings(testdata.cert_pem, chain);
    const cert_key_pem = try sys.readFileAlloc(allocator, certkey_path, 1 << 20);
    defer allocator.free(cert_key_pem);
    const creds = try @import("../tls/cert.zig").loadCredentials(allocator, testdata.cert_pem, cert_key_pem);
    defer allocator.free(creds.cert_der);
    // Account key persisted for the next run.
    const acct_pem = try sys.readFileAlloc(allocator, acct_path, 1 << 20);
    defer allocator.free(acct_pem);
    try testing.expect(std.mem.startsWith(u8, acct_pem, "-----BEGIN EC PRIVATE KEY-----"));
    try testing.expect(fake.challenge_ok.load(.acquire));
}

/// Renewal thresholds: re-issue when the certificate is missing or has
/// less than 30 days left (Let's Encrypt certs last 90); re-check twice a
/// day otherwise.
pub const renew_before_seconds: u64 = 30 * 24 * 60 * 60;
pub const check_interval_seconds: u64 = 12 * 60 * 60;

/// Seconds until the certificate chain at `path` expires; null when the
/// file is missing or unparseable (treat as "issue now").
pub fn certRemainingSeconds(allocator: std.mem.Allocator, path: []const u8) ?u64 {
    const pem = sys.readFileAlloc(allocator, path, 1 << 20) catch return null;
    defer allocator.free(pem);
    const pem_mod = @import("../tls/pem.zig");
    var buf: [8192]u8 = undefined;
    const len = (pem_mod.decodeFirst(pem, "CERTIFICATE", &buf) catch return null) orelse return null;
    const parsed = Certificate.parse(.{ .buffer = buf[0..len], .index = 0 }) catch return null;
    const ts = sys.clock_gettime(std.posix.CLOCK.REALTIME) catch return null;
    const now: u64 = @intCast(ts.sec);
    return if (parsed.validity.not_after > now) parsed.validity.not_after - now else 0;
}

/// Renewal daemon: issue when the cert is missing/close to expiry, then
/// re-check every `check_interval_seconds`. Runs forever on the ACME
/// worker thread; every failure is logged and retried next cycle (a
/// broken renewal must never take the server down).
pub fn runDaemon(
    allocator: std.mem.Allocator,
    cfg: Config,
    transport: anytype,
    logFn: ?*const fn (msg: []const u8) void,
) void {
    const log = struct {
        fn call(f: ?*const fn ([]const u8) void, msg: []const u8) void {
            if (f) |ff| ff(msg);
        }
    }.call;
    while (true) {
        const remaining = certRemainingSeconds(allocator, cfg.cert_path);
        const needs = if (remaining) |r| r < renew_before_seconds else true;
        if (needs) {
            runOnce(allocator, cfg, transport, logFn) catch |e| {
                var mb: [256]u8 = undefined;
                const m = std.fmt.bufPrint(&mb, "acme: renewal failed: {s}", .{@errorName(e)}) catch "acme: renewal failed";
                log(logFn, m);
            };
        }
        sys.nanosleep(check_interval_seconds, 0);
    }
}

test "certRemainingSeconds reports the fixture certificate's lifetime" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const testdata = @import("../tls/testdata.zig");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/crt.pem", .{tmp.sub_path});
    try sys.writeFile(path, testdata.cert_pem);
    const remaining = certRemainingSeconds(allocator, path) orelse return error.TestUnexpected;
    // The fixture is valid for years; anything sane is > 30 days.
    try testing.expect(remaining > renew_before_seconds);
    // Missing file -> null (issue now).
    try testing.expect(certRemainingSeconds(allocator, ".zig-cache/tmp/does-not-exist.pem") == null);
}

// ---- Parsers and helpers -------------------------------------------------

test "jsonString skips unquoted keys and unterminated values" {
    // Bare key at offset 0 is not a JSON key.
    try testing.expect(jsonString("status:\"x\"", "status") == null);
    // Opening quote with no closing quote.
    try testing.expect(jsonString("{\"status\":\"valid", "status") == null);
    // A non-string value for the key is skipped; a later real one wins.
    try testing.expectEqualStrings("ok", jsonString("{\"status\":3,\"status\":\"ok\"}", "status").?);
}

test "jsonStringArray handles missing keys and malformed arrays" {
    const allocator = testing.allocator;
    const key = "\"authorizations\"";
    try testing.expect((try jsonStringArray(allocator, "{}", key)) == null);
    // Key present but no '[' follows.
    try testing.expect((try jsonStringArray(allocator, "{\"authorizations\":3}", key)) == null);
    // Unterminated string inside the array.
    try testing.expect((try jsonStringArray(allocator, "{\"authorizations\":[\"abc}", key)) == null);
    // Allocation failure while building the result list.
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, jsonStringArray(failing.allocator(), "{\"authorizations\":[\"a\"]}", key));
}

test "headerValue returns null for absent and colonless lines" {
    try testing.expect(headerValue("HTTP/1.1 200 OK\r\nA: b\r\n", "Missing") == null);
    try testing.expect(headerValue("HTTP/1.1 200 OK\r\nMalformed\r\n", "Malformed") == null);
}

test "parseHttpResponse rejects malformed responses" {
    const allocator = testing.allocator;
    try testing.expectError(error.AcmeBadResponse, parseHttpResponse(allocator, "HTTP/1.1 200 OK\r\nno separator"));
    try testing.expectError(error.AcmeBadResponse, parseHttpResponse(allocator, "garbage\r\n\r\n"));
    try testing.expectError(error.AcmeBadResponse, parseHttpResponse(allocator, "HTTP/1.1\r\n\r\n"));
    try testing.expectError(error.AcmeBadResponse, parseHttpResponse(allocator, "HTTP/1.1 abc OK\r\n\r\n"));
}

test "parseHttpResponse frees the head when the body allocation fails" {
    const allocator = testing.allocator;
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, parseHttpResponse(failing.allocator(), "HTTP/1.1 200 OK\r\n\r\nhi"));
    var failing2 = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, parseHttpResponse(failing2.allocator(), "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n"));
}

test "chunked decoding tolerates extensions and truncation" {
    const allocator = testing.allocator;
    var r = try parseHttpResponse(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=x\r\nabc\r\n0\r\n\r\n");
    defer r.deinit(allocator);
    try testing.expectEqualStrings("abc", r.body);
    // A bad chunk size stops decoding without failing the response.
    var t = try parseHttpResponse(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc");
    defer t.deinit(allocator);
    try testing.expectEqualStrings("", t.body);
}

test "parseIp4 accepts dotted quads and rejects malformed hosts" {
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIp4("127.0.0.1").?);
    try testing.expect(parseIp4("1.2.3") == null);
    try testing.expect(parseIp4("1.2.3.4.5") == null);
    try testing.expect(parseIp4("1.2.3.256") == null);
    try testing.expect(parseIp4("example.test") == null);
}

test "indexOfIgnoreCase matches case-insensitively" {
    try testing.expectEqual(@as(?usize, 2), indexOfIgnoreCase("xxCHUNKEDyy", "chunked"));
    try testing.expect(indexOfIgnoreCase("short", "muchlonger") == null);
    try testing.expect(indexOfIgnoreCase("abc", "z") == null);
}

test "copyInto truncates to the destination length" {
    var dst: [4]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 4), copyInto(&dst, "abcdef"));
    try testing.expectEqualStrings("abcd", &dst);
    try testing.expectEqual(@as(usize, 2), copyInto(&dst, "xy"));
    try testing.expectEqualStrings("xy", dst[0..2]);
}

test "http-01 extraction picks the url and token" {
    const body = "{\"challenges\":[{\"type\":\"dns-01\",\"url\":\"u0\"},{\"type\":\"http-01\",\"url\":\"u1\",\"token\":\"t1\"}]}";
    try testing.expectEqualStrings("u1", findHttp01Url(body).?);
    try testing.expectEqualStrings("t1", findHttp01Token(body).?);
    try testing.expect(findHttp01Url("{\"challenges\":[]}") == null);
    try testing.expect(findHttp01Token("{\"challenges\":[]}") == null);
}

test "parseSec1Scalar extracts the scalar from SEC1 DER" {
    const allocator = testing.allocator;
    const kp = try Ecdsa.KeyPair.generateDeterministic(@as([32]u8, @splat(0x66)));
    const secret = kp.secret_key.toBytes();
    const der_bytes = try der.sec1PrivateKey(allocator, &secret);
    defer allocator.free(der_bytes);
    const scalar = parseSec1Scalar(der_bytes) orelse return error.TestUnexpected;
    try testing.expectEqualSlices(u8, &secret, &scalar);
    // No `04 20` marker, and a buffer too short to hold one.
    try testing.expect(parseSec1Scalar(&.{ 0x04, 0x1f }) == null);
    try testing.expect(parseSec1Scalar(&.{}) == null);
}

test "request rejects malformed URLs and maps read errors" {
    var t = HttpTransport.init(testing.allocator);
    defer t.deinit();
    try testing.expectError(error.AcmeBadResponse, t.request("GET", "ftp://x/y", null, null));
    try testing.expectError(error.AcmeBadResponse, t.request("GET", "http://no-path", null, null));
    try testing.expectError(error.AcmeBadResponse, t.request("GET", "http://x:notaport/y", null, null));
    try testing.expectError(error.AcmeDirectoryFailed, t.request("GET", "http://127.0.0.1:1/x", null, null));
    // A read on an invalid fd surfaces as a directory failure, not a panic.
    try testing.expectError(error.AcmeDirectoryFailed, t.readResponse(-1));
}

test "request resolves hostname URLs through the system resolver" {
    // request() hands resolveBlocking the system nameservers
    // (resolver.currentServers(): the `resolver` directive, else
    // /etc/resolv.conf). A hostname that cannot resolve still surfaces as a
    // directory failure, not a panic; with no configured nameserver at all
    // the resolver fails fast with NoServers.
    var t = HttpTransport.init(testing.allocator);
    defer t.deinit();
    try testing.expectError(error.AcmeDirectoryFailed, t.request("GET", "http://acme.invalid/directory", null, null));
}

/// Scripted ACME transport for the `runOnce` failure-path tests: hands out
/// the queued replies in order, then an empty 200. URLs are ignored.
const ScriptTransport = struct {
    allocator: std.mem.Allocator,
    replies: []const Reply,
    next: usize = 0,

    const Reply = struct {
        status: u16 = 200,
        body: []const u8 = "{}",
        nonce: ?[]const u8 = "nonce",
        location: ?[]const u8 = null,
    };

    fn request(self: *ScriptTransport, method: []const u8, url: []const u8, content_type: ?[]const u8, body: ?[]const u8) !Response {
        _ = method;
        _ = url;
        _ = content_type;
        _ = body;
        const r = if (self.next < self.replies.len) self.replies[self.next] else Reply{};
        self.next += 1;
        return .{
            .status = r.status,
            .body = try self.allocator.dupe(u8, r.body),
            .nonce = r.nonce,
            .location = r.location,
            .head = try self.allocator.dupe(u8, ""),
        };
    }
};

const script_dir = "{\"newNonce\":\"n\",\"newAccount\":\"a\",\"newOrder\":\"o\"}";
const script_order = "{\"authorizations\":[\"http://ca.test/authz/1\"],\"finalize\":\"http://ca.test/finalize/1\"}";
const script_authz = "{\"challenges\":[{\"type\":\"http-01\",\"url\":\"http://ca.test/chal/1\",\"token\":\"tok\"}]}";
/// Directory + nonce + account replies (account Location set).
const script_acct = [_]ScriptTransport.Reply{
    .{ .body = script_dir },
    .{},
    .{ .location = "http://ca.test/acct/1" },
};
/// Everything through a successful challenge poll.
const script_issued = script_acct ++ [_]ScriptTransport.Reply{
    .{ .body = script_order },
    .{ .body = script_authz },
    .{},
    .{ .body = "{\"status\":\"valid\"}" },
};

/// Run `runOnce` against the scripted replies with throwaway output paths.
fn runScripted(allocator: std.mem.Allocator, replies: []const ScriptTransport.Reply) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var acct_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buf: [std.fs.max_path_bytes]u8 = undefined;
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    const acct = try std.fmt.bufPrint(&acct_buf, ".zig-cache/tmp/{s}/acct.pem", .{tmp.sub_path});
    const cert = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
    const key = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
    var transport = ScriptTransport{ .allocator = allocator, .replies = replies };
    const domains = [_][]const u8{"example.test"};
    try runOnce(allocator, .{
        .directory = "http://ca.test/directory",
        .domains = &domains,
        .account_key_path = acct,
        .cert_path = cert,
        .key_path = key,
    }, &transport, null);
}

test "runOnce rejects empty configurations" {
    const allocator = testing.allocator;
    const domains = [_][]const u8{"example.test"};
    var transport = ScriptTransport{ .allocator = allocator, .replies = &.{} };
    try testing.expectError(error.AcmeConfigInvalid, runOnce(allocator, .{
        .directory = "",
        .domains = &domains,
        .account_key_path = "unused.pem",
        .cert_path = "unused.crt",
        .key_path = "unused.key",
    }, &transport, null));
    try testing.expectError(error.AcmeConfigInvalid, runOnce(allocator, .{
        .directory = "http://ca.test/directory",
        .domains = &[_][]const u8{},
        .account_key_path = "unused.pem",
        .cert_path = "unused.crt",
        .key_path = "unused.key",
    }, &transport, null));
}

test "runOnce reports directory, nonce and account failures" {
    const allocator = testing.allocator;
    try testing.expectError(error.AcmeDirectoryFailed, runScripted(allocator, &.{.{ .status = 500 }}));
    try testing.expectError(error.AcmeDirectoryFailed, runScripted(allocator, &.{.{ .body = "{}" }}));
    try testing.expectError(error.AcmeDirectoryFailed, runScripted(allocator, &.{.{ .body = "{\"newNonce\":\"n\"}" }}));
    try testing.expectError(error.AcmeDirectoryFailed, runScripted(allocator, &.{.{ .body = "{\"newNonce\":\"n\",\"newAccount\":\"a\"}" }}));
    // Nonce response without a Replay-Nonce header.
    try testing.expectError(error.AcmeDirectoryFailed, runScripted(allocator, &.{ .{ .body = script_dir }, .{ .nonce = null } }));
    // Account HTTP error / missing Location (the third reply is the account).
    try testing.expectError(error.AcmeAccountFailed, runScripted(allocator, &.{ .{ .body = script_dir }, .{}, .{ .status = 400 } }));
    try testing.expectError(error.AcmeAccountFailed, runScripted(allocator, &.{ .{ .body = script_dir }, .{}, .{} }));
}

test "runOnce reports order failures" {
    const allocator = testing.allocator;
    const bad_status = script_acct ++ [_]ScriptTransport.Reply{.{ .status = 400 }};
    try testing.expectError(error.AcmeOrderFailed, runScripted(allocator, &bad_status));
    const no_finalize = script_acct ++ [_]ScriptTransport.Reply{.{ .body = "{\"authorizations\":[\"http://ca.test/authz/1\"]}" }};
    try testing.expectError(error.AcmeOrderFailed, runScripted(allocator, &no_finalize));
    const no_authz = script_acct ++ [_]ScriptTransport.Reply{.{ .body = "{\"finalize\":\"http://ca.test/finalize/1\"}" }};
    try testing.expectError(error.AcmeOrderFailed, runScripted(allocator, &no_authz));
}

test "runOnce reports challenge failures" {
    const allocator = testing.allocator;
    const order_ok = script_acct ++ [_]ScriptTransport.Reply{.{ .body = script_order }};
    const authz_err = order_ok ++ [_]ScriptTransport.Reply{.{ .status = 400 }};
    try testing.expectError(error.AcmeChallengeFailed, runScripted(allocator, &authz_err));
    const authz_no_chal = order_ok ++ [_]ScriptTransport.Reply{.{ .body = "{\"challenges\":[]}" }};
    try testing.expectError(error.AcmeChallengeFailed, runScripted(allocator, &authz_no_chal));
    const chal_err = order_ok ++ [_]ScriptTransport.Reply{ .{ .body = script_authz }, .{ .status = 400 } };
    try testing.expectError(error.AcmeChallengeFailed, runScripted(allocator, &chal_err));
    const poll_invalid = order_ok ++ [_]ScriptTransport.Reply{
        .{ .body = script_authz },
        .{},
        .{ .body = "{\"status\":\"invalid\"}" },
    };
    try testing.expectError(error.AcmeChallengeFailed, runScripted(allocator, &poll_invalid));
}

test "runOnce reports finalize, order-poll and download failures" {
    const allocator = testing.allocator;
    const fin_err = script_issued ++ [_]ScriptTransport.Reply{.{ .status = 400 }};
    try testing.expectError(error.AcmeFinalizeFailed, runScripted(allocator, &fin_err));
    const order_invalid = script_issued ++ [_]ScriptTransport.Reply{
        .{ .body = "{\"status\":\"processing\"}" },
        .{ .body = "{\"status\":\"invalid\"}" },
    };
    try testing.expectError(error.AcmeFinalizeFailed, runScripted(allocator, &order_invalid));
    // The finalize reply carries the certificate URL, skipping the poll.
    const dl_err = script_issued ++ [_]ScriptTransport.Reply{
        .{ .body = "{\"status\":\"valid\",\"certificate\":\"http://ca.test/cert/1\"}" },
        .{ .status = 400 },
    };
    try testing.expectError(error.AcmeDownloadFailed, runScripted(allocator, &dl_err));
}

/// Loopback listener that accepts up to `n` connections and closes each
/// immediately — enough to drive the https request path into a TLS handshake
/// failure without a real TLS peer. Polls with a timeout so a failure to
/// connect can never hang the suite.
const ClosingListener = struct {
    fd: std.posix.fd_t,
    port: u16,
    thread: std.Thread,

    fn run(fd: std.posix.fd_t, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, 5000) catch break;
            if (ready == 0) break;
            const cfd = std.os.linux.accept4(fd, null, null, 0);
            if (std.os.linux.errno(cfd) != .SUCCESS) break;
            sys.close(@intCast(cfd));
        }
    }

    fn start(n: usize) !ClosingListener {
        const lfd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        errdefer sys.close(lfd);
        var addr: [16]u8 align(@alignOf(u16)) = std.mem.zeroes([16]u8);
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        try sys.bind(lfd, @ptrCast(&addr), 16);
        try sys.listen(lfd, 4);
        var slen: std.posix.socklen_t = 16;
        var bound: [16]u8 align(@alignOf(u16)) = undefined;
        try sys.getsockname(lfd, @ptrCast(&bound), &slen);
        return .{
            .fd = lfd,
            .port = (@as(u16, bound[2]) << 8) | bound[3],
            .thread = try std.Thread.spawn(.{}, run, .{ lfd, n }),
        };
    }

    fn stop(self: *ClosingListener) void {
        self.thread.join();
        sys.close(self.fd);
    }

    fn url(self: *ClosingListener, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "https://127.0.0.1:{d}{s}", .{ self.port, path }) catch "";
    }
};

test "https requests load the system bundle and report handshake failure" {
    const allocator = testing.allocator;
    var srv = try ClosingListener.start(2);
    defer srv.stop();
    var url_buf: [64]u8 = undefined;

    // Trust-bundle allocation failure: the connected fd is closed and the
    // request fails cleanly before any TLS setup.
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var poor = HttpTransport.init(failing.allocator());
    defer poor.deinit();
    try testing.expectError(error.AcmeDirectoryFailed, poor.request("GET", srv.url(&url_buf, "/directory"), null, null));

    // Normal transport: systemCa loads (and caches) the roots, then the
    // handshake fails because the peer closes without speaking TLS.
    var t = HttpTransport.init(allocator);
    defer t.deinit();
    try testing.expectError(error.AcmeDirectoryFailed, t.request("GET", srv.url(&url_buf, "/directory"), null, null));
    try testing.expect(t.ca_loaded);
    try testing.expect(t.systemCa() == t.ca);
}
