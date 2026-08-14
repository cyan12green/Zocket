# Roadmap

**Vision**: high-performance, modular, nginx-style HTTP server in Zig —
static file serving and reverse proxying. Comptime is pushed into every
layer that can benefit: config validation, route resolution, per-route
dispatch specialisation, header-name hashing, compiled response templates,
comptime embedded static assets, comptime pre-compression, and
comptime-precomputed proxy addresses — all so runtime decisions are
reduced to the absolute minimum the Zig 0.16-dev snapshot allows.

The M4 phase pipeline and module registry are the extension seam; every new
module plugs into one of the 10 phases and is wired from config.

**Architecture invariants**:
- One epoll reactor per physical core (M2).
- Incremental HTTP/1.1 parser over `net.Buffer`, never blocks (M3).
- 10-phase nginx-style pipeline, comptime-unrolled module dispatch (M4).
- Prefix/exact route matching, config-driven module bindings (M4).
- `zig build test` is the universal gate; every milestone keeps it green.
- Benchmark methodology: same-day A/B against a checked-out baseline, <5%
  overhead at every measured point (from `bench/BENCH.md`).
- Zig 0.16-dev pinned in `build.zig.zon`; features needing a future
  capability (comptime allocator, comptime std.json) are documented as
  dependent milestones with their unblock event noted.

---

## Milestones in dependency order

### M5 — Connection lifecycle: idle timeout + timer wheel

**Status: DONE** (2026-08-11). `src/net/timer_wheel.zig` ring-buffer wheel
(1024 slots, 100 ms ticks — both comptime constants), `Connection.timer`
entry, reactor advances the wheel each loop iteration and closes expired
connections; `--idle-timeout N` CLI flag (default 60, 0 disables) wired via
`multireactor.Server`. Gates met: 10 wheel unit tests + 3 reactor idle
integration tests, `zig build test` 83/83, `bench/http-check.py` 11/11, M5 A/B
in `bench/BENCH.md` (-2.5% at c500, interleaved).

*Depends on*: M4 (reactor, connection struct).

A ring-buffer timer wheel (`src/net/timer_wheel.zig`, O(1) insert/remove/rearm).
Each `Connection` embeds a `TimerEntry`. The reactor advances the wheel on
every loop iteration; idle connections expire and close. Default
`idle_timeout_seconds = 60` (zero disables).

- `--idle-timeout N` CLI flag, wired via `multireactor.Server`.
- `--echo` and `--single` modes unchanged.

**Verification**: timer wheel unit tests (insert/expire, remove, rearm,
wrap-around, catch-up); reactor integration test (connection closes after
idle timeout, active traffic resets the timer); `bench/http-check.py 11/11`;
M5 A/B recorded in `bench/BENCH.md` (<5% delta).

**Comptime**: wheel slot count and tick granularity are comptime constants.
No snapshot dependency (the wheel is inherently a runtime data structure;
the comptime win is configuration, not algorithm).

---

### M6 — HTTP robustness: chunked encoding + URL decoding + HEAD

**Status: DONE** (2026-08-11). Chunked transfer-encoding in the parser
(`chunk_size`/`chunk_data`/`chunk_crlf`/`chunk_trailers` states; trailer
headers dropped; `max_chunked_body` cap → 413), percent-decoded
`Request.decoded_target` (comptime `[256]u8` hex table; escape-free targets
stay zero-copy) + `Request.query_string` split, HEAD (head-only wire output
with the would-be-body Content-Length), comptime MIME switch
(`src/http/mime.zig`). Gates met: 20 new parser/response/mime/reactor tests,
`zig build test` 103/103, `bench/http-check.py` extended to 15 checks and
passing, M6 A/B in `bench/BENCH.md` (latency floor +0.8%; throughput deltas
inside the same-binary control envelope).

*Depends on*: M3 (parser, response builder).

Fill the HTTP/1.1 gaps that block real content modules.

- **Chunked transfer-encoding** in the parser: `chunk_size` → `chunk_data` →
  `final_chunk` states. Trailer headers dropped. (Currently 501.)
- **URL decoding**: percent-encoded target → `Request.decoded_target`. The
  decoded string is allocated in `Request.storage`; targets without escapes
  are zero-copy slices into the original buffer.
- **Query string split**: `Request.query_string` (slice from `?` onwards).
- **HEAD method**: parser already accepts it; the reactor writes only the
  response head (status line + headers + `\r\n\r\n`, no body).
- **MIME extension table**: a comptime switch over known extensions
  (`extension` → `Content-Type` string literal). Used by the static-file
  module (M10).

**Verification**: new parser tests for chunked (simple, multi-chunk, empty,
size extensions tolerated), URL decoding roundtrips, query string split,
HEAD wire-format tests. `bench/http-check.py` extended. A/B vs M5 <5%.

**Comptime**: the MIME table is a comptime switch — a compile-time mapping
from file extension to MIME string with zero runtime map lookups. The
hex-decoding table for URL decoding (`%XX` → byte) is a comptime
`[256]u8` lookup table. The chunk parser is runtime (no comptime win).

---

### M7 — Comptime route resolution and dispatch

**Status: DONE** (2026-08-11). Part A: byte-level radix trie in
`dsl/router.zig` (O(path length) lookup; exact beats prefix; prefix nodes
carry their longest-prefix chain; comptime-built into .rodata for
struct-literal configs via `buildTrie`, startup-built for JSON via
`buildTrieRuntime`; duplicate (path, match) routes are a compile error for
struct configs, `error.AmbiguousRoutes` at runtime; `matchRoutes` unchanged
and still used as the no-trie fallback). Part B: `dispatchForRoute` +
`assignDispatch` in `dsl/pipeline.zig` generate a comptime-specialised
`*const fn (ctx) anyerror!Outcome` per route (stored on `Route.dispatch`,
called directly from the pipeline walk). `Server.comptimeInit` builds both at
compile time; `Server.initWithTrie` builds the trie at startup for JSON.
Gates met: 14 new router/pipeline/server tests, `zig build test` 117/117,
100-route A/B in `bench/BENCH.md` (+1.9% @c100, +7.8% @c500 — no regression).

*Depends on*: M4 (`dsl/router.zig`, `dsl/pipeline.zig`).

Two comptime-driven improvements to the per-request hot path.

**Part A — Comptime route trie** (`dsl/router.zig`):

Replace the O(n) linear prefix scan in `router.matchRoutes` with a
comptime-built radix/trie tree. The trie is constructed at compile time
from the route table (struct-literal configs) or at startup (JSON configs).
Lookup is O(path length), not O(routes). Exact leaves win over prefix;
prefix nodes track their longest-prefix chain so a single traversal
produces the best match. The existing `matchRoutes` API is unchanged.

Collision check (ambiguous routes) is a compile error for struct-literal
configs.

**Part B — Comptime per-route dispatch specialisation** (`dsl/pipeline.zig`):

Currently `pipeline.run` does `for (Phase.all) |phase| { r.moduleFor(phase)
... }` — a runtime loop over all 10 phases per request. For a route
binding only `content: echo`, 9 iterations are wasted branch + orelse falls.

Replace this with a comptime-generated dispatch table per route. For
struct-literal configs, each route gets a comptime-built function that
directly calls the modules for its bound phases — zero loops, zero
`moduleFor` scans, zero `Registry.resolve` calls at runtime. The function
signature is `*const fn (ctx: *Context) anyerror!Outcome` stored in a
`dispatch: ?DispatchFn` field on `Route`. For JSON-loaded configs, the
dispatch table is built at startup (same shape, constructed from the
runtime `Config`).

Example — a route with `content: echo` + `log: access_log` generates the
equivalent of:

```
fn dispatch(ctx) !Outcome {
    switch (try echo.run(ctx)) { .handled => {}, else => {} }
    switch (try access_log.run(ctx)) { .handled => {}, else => {} }
    return .not_handled;
}
```

**Verification**: all existing router and pipeline tests pass unchanged.
New tests: trie edge cases (shared prefixes, single-segment paths); dispatch
table correctness (table-driven route produces the same outcome + context
state as the loop-based walk for identical configs). A/B M7 vs M6 at
synthetic 100-route configs: trie + dispatch-specialisation must not
regress latency at any route count. Recorded in `bench/BENCH.md`.

**Comptime**: both the trie and the dispatch table are fully
comptime-constructed for struct-literal configs and live in `.rodata`.
For JSON configs the same structures are built at startup (still a
one-time cost, not per-request). The collision check and phase-binding
resolution run at compile time.

---

### M8 — Comptime header-name hashing

**Status: DONE** (2026-08-11). FNV-1a (32-bit, lower-cased) hashing in
`http/parser.zig`: the known header-name set (`header_hasher.known`) is
collision-checked at compile time (a collision is a compile error);
`Slot.name_hash` stores the wire name's hash; `Request.header(comptime name)`
scans with one integer compare per slot and verifies the string only on a
hash hit; `addHeader` detects content-length/transfer-encoding by hash; the
Connection/Transfer-Encoding value tokens are hash-matched against comptime
constants. `header_hasher` is exported for the response builder's dedup.
Gates met: 4 new parser tests, `zig build test` 121/121 (wire output
byte-identical), micro-benchmark recorded, M8 A/B in `bench/BENCH.md`
(-2.0% / -2.6%, within gate).

*Depends on*: M3 (`http/parser.zig`, `http/response.zig`).

Replace case-insensitive string comparison in header lookups with integer
comparison for the known header-name set (`host`, `content-type`,
`content-length`, `transfer-encoding`, `connection`, `accept-encoding`,
`if-none-match`, `if-modified-since`, `range`, …).

**What changes in the parser**:
- A comptime perfect-hash function is generated over the known-name set at
  compile time. Collision check runs at comptime — a collision is a compile
  error, not a runtime bug.
- The `Slot` struct gains a `name_hash: u32` field.
- `Request.addHeader` computes the hash (via the comptime hash function or a
  fast runtime fallback for unknown names) and stores it alongside the
  name/value offsets.
- `Request.header("content-type")` → comptime hash of the argument → O(1)
  hash-matched slot lookup. Unknown header names fall back to the existing
  linear case-insensitive scan.
- Known header *values* can also be hashed (e.g. `"chunked"`, `"close"`,
  `"keep-alive"`), replacing `eqlIgnoreCase` on values with integer compare.
- The response builder can use the same hash for header dedup.

**Verification**: existing parser/response tests pass byte-identically
(hash must not change wire output). New tests: known-name lookup vs
eqlIgnoreCase, unknown-name fallback, hash-is-collision-free assertion
(passes at comptime). Micro-benchmark: 10-known-headers request — hash
path vs string path. A/B M8 vs M7 <5%.

**Comptime**: the entire known-header set, perfect-hash function, and
collision assertion are computed at compile time. The hash values for
literal header-name arguments (e.g. `"content-type"`) are also computed
at comptime — callers pass `comptime Hash("Content-Type")` to get a
compile-time constant integer.

---

### M9 — Response transformation: gzip, cache headers, conditional GETs

**Status: DONE** (2026-08-12). Part A: `dsl/modules/gzip.zig` (log phase =
pipeline post-processing) — runtime compression with `std.compress.flate`
(gzip container), `Accept-Encoding: gzip` token check via the M8 hasher,
>= 20-byte shrinkable bodies only, `Content-Encoding: gzip` + `Vary`, body
allocated from `ctx.allocator` and freed by the reactor (`resp.body_owned`).
Part B (comptime pre-compression) deliberately deferred to M11 per the
roadmap. Part C: `dsl/modules/cache.zig` — `conditional_get` (preaccess; 304
from `If-None-Match`/`If-Modified-Since` vs `ctx.etag`/`ctx.last_modified`,
with a real IMF-fixdate parser) and `cache_headers` (post_access;
`Cache-Control: max-age=N` from the route's `max_age_seconds`, 0 → no-cache,
plus ETag/Last-Modified). The echo module now mutates the response instead of
resetting it. Gates met: 8 new module tests + e2e curl checks, `zig build
test` 129/129, M9 A/B in `bench/BENCH.md` (-0.9% / +6.7%, within gate).

*Depends on*: M6 (Content-Type) + M8 (header hashing).

Modules that transform or gate responses.

**Part A — Gzip module** (`dsl/modules/gzip.zig`, phase TBD):

Compresses the response body if the client sent `Accept-Encoding: gzip`.
Adds `Content-Encoding: gzip`. Uses `std.compress.gzip` for runtime
compression of dynamic bodies.

**Part B — Comptime pre-compression** (build on M11):

Known static responses — error pages, redirect bodies, health-check
payloads — can be gzip-compressed at compile time. The config declares
a `compress` flag on static response entries; the build produces a
`[N]u8` comptime array of the compressed body in `.rodata`. At runtime,
the gzip module checks "is there a comptime-compressed body available?"
→ write the pre-compressed bytes directly, skipping `std.compress.gzip`
entirely. This is correct because the uncompressed input is a comptime
literal — same input always produces the same gzip output.

**Part C — Cache headers + conditional GETs**:

- `Cache-Control`, `ETag`, `Last-Modified` set by a content-phase helper.
  Route-level config for default `max_age`.
- `If-None-Match` / `If-Modified-Since` parsed in a `preaccess`-phase
  module; respond `304 Not Modified` if content is unchanged. Requires
  the content module to expose `ETag`/`Last-Modified` in the context
  before the content phase runs (e.g. via a `post_read`-phase stat).

**Verification**: gzip roundtrip (compress → `Content-Encoding` →
decompressible output), comptime pre-compressed responses byte-identical
to runtime-compressed ones, 304 response tests, cache header correctness.
Manual: `curl -H 'Accept-Encoding: gzip'`. A/B M9 vs M8 (<5%) recorded.

**Comptime**: error-page pre-compression runs entirely at build time.
The comptime gzip compressor may need `std.compress.gzip` at comptime
(verify the snapshot supports this; if not, fall back to a comptime
deflate implementation or defer this sub-task).

---

### M10 — Static file serving (disk + comptime embedded)

**Status: DONE** (2026-08-12). `dsl/modules/static.zig`: disk serving
(`root`/`index`/`autoindex` route config; `..` traversal blocking and
symlink-escape rejection via realpath comparison; MIME table; ETag
`"mtime-size"` + Last-Modified; single ranges → 206, multi → full 200,
unsatisfiable → 416; If-None-Match / If-Modified-Since → 304) and comptime
embedded assets (`embed` route field resolved at compile time through the
root-level `embeds` module — a compile error on a missing file — served from
.rodata with zero disk I/O and an infinite cache lifetime; JSON configs use
disk only). `testdata/` fixtures. Gates met: 9 new module tests + e2e curl
checks (file/206/416/304/traversal/index/autoindex/embedded), `zig build
test` 138/138, M10 A/B in `bench/BENCH.md` (-1.0% / +0.1%, within gate).

*Depends on*: M6 (URL decoding, Content-Type) + M7 (trie + dispatch) +
M9 (cache headers, gzip).

The first real content module (`dsl/modules/static.zig`). Two serving paths:

**Path A — Disk-based serving** (runtime config):

- Config: `root` directory, optional `index` file, `autoindex` boolean.
- Resolve: decode URL → path relative to root. Block `..` traversal and
  absolute symlink escapes. `stat()` the file.
- Headers: `Content-Type` from MIME table (M6), `Content-Length` from file
  size, `Last-Modified` from mtime, `ETag` from `"mtime-size"`.
- Body: `sendfile()` if available; otherwise a read loop.
- Range requests: parse `Range: bytes=N-M` → 206 Partial Content. Multiple
  ranges → 200 full body (multipart deferred).
- Conditional GETs: 304 path via M9.

**Path B — Comptime embedded assets** (struct-literal config):

A route can declare an `embed` field whose value is a file path. At compile
time `@embedFile(path)` bakes the file's contents into `.rodata`. On
request, the module writes directly from the comptime `[]const u8` without
any disk I/O — no `stat`, no `open`, no `read`, no `sendfile`. The file
has an effective infinite cache lifetime.

Config example (struct literal):
```zig
.{ .path = "/robots.txt", .match = .exact, .modules = &.{
    .{ .phase = .content, .module = "static" },
}, .embed = "public/robots.txt" }
```

For JSON configs, `@embedFile` cannot be used; the JSON path uses
disk-based serving only. A comptime struct-literal config is required for
Path B.

**Verification**: Path A (disk): path safety tests (block `..` and
`/etc/passwd`-style traversal), MIME detection, range parsing (single →
206, multi → 200, invalid → 416), 304 path, byte-identical file bodies.
Path B (embedded): comptime-embedded file produces byte-identical response
to the equivalent disk-served file. `testdata/` with small test files.
Integration: `--config config.example.json` mapping `/` → static, curl
multiple paths. A/B M10 vs M9 (<5%) recorded.

**Comptime**: MIME table (M6). `@embedFile` does not need comptime
allocator — it works today. The embedded path uses zero runtime I/O
beyond the socket write. Path-safety checks for embedded files are
compile-time: an invalid path to `@embedFile` is a compile error.

---

### M11 — Comptime response templates (fast-path responses)

**Status: DONE** (2026-08-12). A route `response` block (status + headers +
body) is serialised at compile time (`Route.response_bytes`, in .rodata);
module-less template routes are served by the reactor straight from those
bytes (`Server.matchFast` — no pipeline, no response builder, byte-identical
to the builder equivalent), routes with modules keep the pipeline and fall
back to the template when nothing claims the request, and JSON-config
templates apply through the pipeline at runtime. Comptime pre-compression
(M9 Part B) is **deferred**: the stdlib flate dynamic-Huffman path breaks
under comptime evaluation (u0 depth-field inference bug — verified), and a
deterministic comptime encoder cannot be byte-identical to the runtime
compressor; `compress: true` is a compile error documenting the deferral
(the roadmap's fallback clause). Gates met: 5 new tests (serialisation
byte-identity, matchFast gating, dispatch/loop-walk fallbacks, JSON
templates, reactor wire test incl. pipelining), `zig build test` 143/143,
fast-path-vs-pipeline and M11 A/B in `bench/BENCH.md` (+0.7% / +0.4%).

*Depends on*: M7 (trie + dispatch) + M9 (cache headers).

Routes that produce fixed responses (redirects, healthchecks, error pages)
bypass the pipeline entirely. The config declares a `response` block with
status + headers + body; the route's full wire bytes are serialised at
comptime and stored in the trie leaf or dispatch table. On match, the
reactor writes the pre-built bytes directly into the send buffer — no
module dispatch, no response builder, no function call through the
pipeline.

The fast path only fires when no upstream module has claimed the request,
so `rewrite`/`access` modules can still override. This composes with M9's
comptime pre-compression: a static response can declare both `response`
and `compress: gzip` to get comptime-compressed fast-path bytes.

Config example:
```json
{ "path": "/health", "match": "exact", "response": { "status": 200, "body": "ok" } }
```

**Verification**: fast-path response is byte-identical to the equivalent
pipeline response. Benchmark: fast-path latency vs pipeline for a trivial
`200 OK "ok"` response → expect lower p50 (zero function calls in the
hot path). A/B M11 vs M10 <5%.

**Comptime**: the entire wire serialisation runs at comptime. The `"ok"`
body and `200 OK\r\n...` status line become constant byte arrays in
`.rodata`. With M9 pre-compression, the gzip-compressed version also lives
in `.rodata`.

---

### M12 — Reverse proxy

**Status: DONE** (2026-08-12). `dsl/modules/proxy.zig` (rewrite phase):
per-backend keep-alive connection pool (thread-local, one socket per backend
per reactor, lazily reaped after idle), request forwarding with Host
rewriting, hop-by-hop header stripping and Content-Length bodies, comptime-
switched load balancing (round-robin / least-connections / ip_hash), passive
failure detection (skip for `fail_timeout_seconds` after `max_fails`
consecutive errors, then retry), pre-computed upstream sockaddrs (comptime
for struct configs — no DNS — startup for JSON), X-Forwarded-For/X-Real-IP
from the peer address captured at accept (`Connection.peer_ip` +
`Context.client_ip`). Upstream TLS deferred (roadmap note). Gates met:
2 unit tests (comptime sockaddr byte-identity, balance parse) + e2e
verification with `bench/config-proxy.json` (bodies echoed, pool reuse via
the upstream connection counter, XFF observed, 502 on a dead upstream,
round-robin), `zig build test` 145/145, M12 A/B in `bench/BENCH.md`
(-3.6% / +6.5%, within gate).

*Depends on*: M8 (header hashing) + M7 (trie + dispatch) + M5 (connection lifecycle).

A `rewrite`-phase proxy module (`dsl/modules/proxy.zig`).

- **Upstream connection pool**: per-backend pool of keep-alive TCP
  connections. Created on first request, reaped after idle timeout.
- **Request forwarding**: build an HTTP/1.1 request from the parsed
  `Request` (method, target, headers), send to upstream, read headers +
  body, copy into `ctx.resp`. Reuses the existing parser and response
  builder for the upstream response.
- **Load balancing**: round-robin (default), least-connections, IP-hash.
  Strategy dispatch is a comptime switch; dead functions are eliminated.
- **Comptime upstream sockaddr**: for backends declared in a struct-literal
  config, the `sockaddr` (IP + port in kernel network byte order) is
  pre-computed at compile time — no runtime `getaddrinfo()`, no DNS, no
  runtime byte-swapping. JSON configs compute `sockaddr` at startup.
- **Health checks**: passive failure detection (mark a backend failed after
  N consecutive connect/read errors, retry after M seconds). Active health
  checks deferred.
- **Proxy headers**: `X-Forwarded-For`, `X-Real-IP`, `Host` rewriting.
- **Upstream TLS**: deferred to a future Zig snapshot with `std.crypto.tls`.

**Verification**: integration test — run an echo server on a known port,
configure a proxy route, send a request, verify body echoed. Pool reuse:
two sequential requests use the same upstream socket. Failure handling:
point proxy at a dead port, verify 502 Bad Gateway + automatic retry.
Comptime sockaddr: verify the pre-computed address is byte-identical to a
runtime-resolved one. A/B M12 vs M11 <5%.

**Comptime**: load-balancing strategy dispatch is a comptime switch; pool
sizes are comptime constants from struct-literal configs. Upstream
`sockaddr` is pre-computed at compile time for known backends. Host-header
rewriting rules can be validated at comptime for struct-literal configs.

---

### M13 — Observability + graceful reload

**Status: DONE** (2026-08-12). `access_log` module (log phase): the combined
format string is parsed at comptime into a token sequence (zero per-request
string scanning), buffered per-reactor stderr writes. `error_log` module:
severity derived from the status, filtered against a comptime threshold; the
reactor also logs parse errors directly (they never reach the pipeline).
`stub_status` module: nginx_status-style page from shared atomic server
counters (`ServerStats`; accepted/active/requests/reading/writing/waiting,
updated by the reactors and accept loop). SIGHUP graceful reload:
`installSignalHandlers` + `multireactor.Server.reload_fn` — the main loop
re-parses the config, swaps in a fresh reactor set with the new handler and
dispatcher (new connections get the new config), and drains the old reactors
(no new accepts; existing connections finish; join when empty or after 30 s).
Gates met: 4 new unit tests + e2e verification (combined-format lines on
stderr, parse-error warn lines, stub counters under load, the full SIGHUP
config-A→B dance with old-connection drain), `zig build test` 149/149,
M13 A/B in `bench/BENCH.md` (+0.6% / -0.7%, within gate).

*Depends on*: M10 (static files for log content) + M12 (proxy metrics).

- **Access log module** (`dsl/modules/access_log.zig`, `log` phase):
  configurable format string (combined/common format). The format string is
  parsed at comptime into a sequence of tokens, so per-request log
  formatting does zero string scanning — it walks a comptime-built token
  list. Buffered writes per reactor.
- **Error log**: `stderr` output with severity levels (error, warn, info)
  and per-connection error-format lines. Severity filtering is a runtime
  check against a comptime threshold.
- **Stub status page** (`/nginx_status`-style): active connections, accepted,
  requests, reading/writing/waiting. Uses M11 comptime response templates
  for the HTML skeleton; counter fields are updated atomically from shared
  reactor counters at response time.
- **Graceful reload**: on `SIGHUP`, the main thread re-parses the config,
  creates a new set of reactors with the new route table, and slowly drains
  the old reactors (stop accepting, let existing connections finish, join).
  New connections get the new config. This is the "hot-reloadable" target
  from the project description.

**Verification**: access log output matches the expected combined/common
format. Stub status counters increment under load. SIGHUP integration test:
start server with config A, send SIGHUP with config B, verify new
connections see config B while old connections drain.

**Comptime**: log format string parsed at comptime into a token sequence.
Stub-status HTML skeleton is a comptime literal (M11). Error-log severity
filter is comptime-configurable via struct literal.

---

### M14 — Kernel-level optimizations

**Status: DONE** (2026-08-12). SO_REUSEPORT: each reactor binds its own
listener on the same port and accepts directly (accept loop, dispatcher and
per-connection eventfd wakeup removed; reload gives new reactors fresh
listeners that coexist with the draining ones). `sendfile()` for static
bodies >= 16 KB (head with the real Content-Length; ranges keep offsets;
also fixes the pre-existing >16 KB-file empty-response bug). `writev()`:
bodies stay out of the send buffer and flush with the head in one syscall
(module-allocated bodies freed once sent). io_uring: explored and deferred
(integrating std.Io's io_uring into the epoll reactor is a rewrite; roadmap
allows deferral). Gates met: `zig build test` 149/149, `bench/http-check.py`
15/15, 100 KB file byte-identical via sendfile (full + range), reload e2e
with per-reactor listeners, per-optimization A/Bs in `bench/BENCH.md`
(port-bias-corrected: +0.1/+0.6%, +1.0%, +1.2% — all within gate; a ~6%
port-position bias was discovered and corrected for).

*Depends on*: M10 (static files for `sendfile`) + M12 (proxy for socket pools).

Optimizations that reduce syscall count and per-request overhead.

- **SO_REUSEPORT**: each reactor binds the listen socket independently.
  The kernel distributes inbound connections across reactors, removing the
  accept/dispatch hop and its eventfd wakeup.
- **sendfile()**: for static file bodies, `sendfile()` pushes file content
  into the socket without copying through userspace.
- **writev()**: batch the status line, headers, and body into one `writev()`
  syscall instead of serialising into the send buffer + `write()`.
- **io_uring**: if the snapshot or a future Zig version supports it, explore
  batched recv/send via io_uring for further latency reduction.

**Verification**: each optimization has its own A/B recorded in
`bench/BENCH.md`. SO_REUSEPORT: compare per-request latency with and without
dispatch at 4-reactor, high-connection counts.

**Comptime**: none (these are kernel-level; comptime wins happen in
userspace before the syscall boundary).

---

### M15 — Benchmark-driven hardening (nginx comparison)

**Status: DONE** (2026-08-13). Motivated by cross-framework comparison
(Zocket vs actix-web, Bun.serve, httpx.zig, nginx, Caddy — all pinned
as `third_party/` submodules, driven by `bench/compare-servers.sh`): fix
what the benchmarks exposed, then replicate nginx's per-request recipe
with comptime improvements.

- **Request-buffer growth** (`connection.zig`, `buffer.zig`): the recv
  buffer was a fixed 16 KiB and the parser needs the whole Content-Length
  body buffered, so every POST over ~16 KiB was rejected with 431. The
  buffer now grows on demand (doubling to a 16 MiB per-connection cap;
  past the cap still 431). Grown capacity is kept for the connection
  (per-request shrink was ~4 mmap+munmap pairs per 64 KiB request) and
  the echo module's stale 15 KiB cap was raised to match (writev made it
  moot). Regression test: 64 KiB POST -> 200 + full echo + keep-alive.
- **Static fd cache** (`dsl/static_cache.zig`, nginx `open_file_cache`
  equivalent): per-reactor cache of open fds + metadata + preformatted
  ETag/Last-Modified, mtime-revalidated in a 1 s window. Serving a cached
  file costs zero open/stat/close syscalls and zero date formatting. For
  files <= 16 KiB the cache also holds the content: head + bytes go out in
  ONE writev (no sendfile syscall), ranges slice the cached memory.
  openat2(RESOLVE_BENEATH) against a config-loaded root fd replaced the
  per-request open + realpath pair (one kernel-enforced syscall, no
  TOCTOU; falls back to the legacy realpath path when unavailable).
- **Connection pool** (`connection.zig` ConnectionPool): page_allocator
  made each connection 5 allocations (struct + 2 buffer structs + 2 x
  16 KiB data) = 5 mmap/munmap pairs. Buffers are embedded in the
  Connection (one allocation; grows switch to heap and keep capacity) and
  connections recycle through a per-reactor free list (cap 1024), so warm
  accept/close is allocation-free. mmap+munmap pairs per connection under
  churn: 7.0 -> 2.0 (with the arena).
- **Request bump arena** (`http/arena.zig`): header strings, decoded
  target and query live in a bump arena (embedded 16 KiB + overflow heap
  blocks kept warm); `reset()` rewinds between requests; typical requests
  cost zero heap allocations. `Slot` stores slices (arena blocks are not
  contiguous).
- **Cached Date header** (nginx `ngx_cached_http_time` equivalent): the
  IMF-fixdate string is formatted once per wall-clock second into a
  reactor cache and copied into every pipeline response, plus a comptime
  `Server: Zocket` header; per-request date formatting is zero.
- **io_uring backend** (`net/iouring.zig`, opt-in `--uring`): batch
  connection reads/writes on a ring (one in-flight read per connection,
  no EAGAIN drain probe; completions drained via the ring fd on epoll;
  sendfile resumed via poll_add; deferred close via async cancel). nginx
  1.28.0 contains zero io_uring code — its probe-free model comes from
  edge-triggered epoll + read-once semantics whose `rev->ready` flag is
  only cleared by EAGAIN. Measured at parity with epoll on keep-alive and
  regressing at high connection counts, so it is opt-in and epoll stays
  the default. (A pure epoll read-once variant was tried and reverted:
  15k vs 304k on GET — the drain loop's probe is not the bottleneck.)
- **Configurable limits** (nginx-style): the `limits` JSON section (and
  comptime Config field) makes every hardcoded size/cap runtime-tunable -
  recv/send buffer sizes, max_body (client_max_body_size), max_line_bytes,
  max_headers, max_chunked_body, static_cache_entries/valid/content_max
  (open_file_cache *), connection_pool_max. The reactor applies them at
  init; modules read `ctx.limits` with compiled defaults as fallback.
  Reference: docs/config.md.
- **Lean state machines**: comptime DFA header classification
  (`header_dfa.zig`, 60-292 ns parse), single-pass response serialisation
  with a table itoa, two-iov flush (the zero-copy writev-parts variant
  regressed ~8%: 13 iovecs per writev cost more than the serialisation
  saved).

**Verification**: every step has its A/B in `bench/BENCH.md` (1 KB static:
  47.9k -> 268k co-resident, gap to nginx 4.6x -> 1.66x ours; 64 KiB
  POST error path -> real echo; churn mmap pairs 7 -> 2 per connection;
  GET / empty 12-rep interleaved 292k vs nginx 278k). Final interleaved
  comparison: Zocket leads every workload (GET / 1.05x, 1 KB static
  1.66x, POST /echo 1.82x, 1 MB static parity). 175 tests.

**Comptime**: DFA transition table, MIME/date tables, header templates and
the registry are comptime-built; the request arena and connection pool
eliminate runtime allocation entirely on the hot path.


### M16 — HTTP/2

**Status: PLANNED** (protocol completeness — the biggest gap vs nginx, which
ships `ngx_http_v2`). HTTP/2 (RFC 9113) over the existing HTTP/1.1
transport: framing, HPACK header compression (RFC 7541), stream
multiplexing with per-stream and per-connection flow control
(WINDOW_UPDATE), stream priorities, and optional server push.

- **Framing**: 9-byte frame header decode/encode from the connection recv
  buffer; SETTINGS exchange, PING, GOAWAY, RST_STREAM, DATA, HEADERS,
  CONTINUATION, PRIORITY frames.
- **HPACK**: static + dynamic table, Huffman decoding for header names;
  the comptime DFA (`header_dfa.zig`) classifies names before table
  lookups. The request arena (`http/arena.zig`) holds decoded headers.
- **Streams**: per-connection session state (stream table keyed by id),
  lifecycle (idle -> open -> half-closed -> closed), concurrency limits,
  and the existing phase pipeline runs per stream. Responses reuse the
  fast serializer, wrapped in HEADERS + DATA frames; the small-file
  content cache and sendfile path adapt to frame-sized writes.
- **Negotiation**: `h2c` prior-knowledge and the HTTP/1.1 `Upgrade: h2c`
  path now, ALPN `h2` after M17 (TLS) for the internet path. The listener
  must reject HTTP/1.x framing after the h2 preface (`PRI * HTTP/2.0`).
- **Server push** (optional, after the core): PUSH_PROMISE for
  module-tagged assets.

**Verification**: `h2spec` conformance, curl --http2 / http2 clients,
pipelining-equivalent multiplexed A/B vs HTTP/1.1, and the multi-client
benchmark. The HTTP/2 stream model is also the base for gRPC proxying
(later).

**Comptime**: HPACK static table (61 entries, RFC 7541 appendix A) built
at comptime; frame-type and flags decode tables.

---

### M17 — TLS/HTTPS

**Status: PLANNED**. Server-side TLS (1.2/1.3) with SNI and ALPN.
Prerequisite for HTTP/2 on the internet (ALPN `h2`) and for HTTP/3.

- **Backend**: OpenSSL C bindings (the repo's raw-syscall style already
  holds C deps via third-party submodules). `std.crypto.tls` is deferred
  (immature in the pinned snapshot); the choice is documented in the
  module. Per-listener cert/key from the config (`limits`-style section or
  a `server` block: `ssl_certificate`, `ssl_certificate_key`,
  `ssl_protocols`).
- **Handshake**: accept-time async handshake on the reactor (the epoll
  loop already drives fd readiness); session resumption (TLS 1.3 0-RTT
  later), SNI to select the cert, ALPN to select h2/h1.
- **Write path**: the response serializer feeds the OpenSSL BIO; sendfile
  falls back to buffered writes under TLS (no file splicing through TLS).

**Verification**: `openssl s_client -tls1_3 -alpn h2`, curl https, h2spec
over TLS, and the standard A/B (the cipher path adds measurable
per-request cost — document it separately from plaintext numbers).

---

### M18 — WebSocket and connection upgrade

**Status: PLANNED**. The parser already classifies `upgrade`; implement
protocol switching: on `Connection: upgrade` + `Upgrade: <proto>` return
101 and hand the connection over (the reactor stops HTTP parsing and the
session becomes a raw byte pipe, or a websocket content module owns the
connection). RFC 6455 framing (FIN/opcode/mask/length) for a native
websocket echo module; upstream passthrough for proxied `ws://`.

**Verification**: ws clients (e.g. `websocat`), the existing socketpair
reactor tests extended for the post-101 raw phase.

---

### M19 — HTTP/3 + QUIC

**Status: PLANNED** (after M16 + M17; nginx `v3`, Caddy and h2o all ship
it). RFC 9000 (QUIC) + RFC 9114 (HTTP/3): connection migration, 0-RTT,
UDP transport. The largest single item — realistically via a QUIC C
dependency (quiche / lsquic) or by waiting for Zig std support; scope and
feasibility are revisited once M16/M17 land. Delivery is incremental: UDP
receive path -> QUIC handshake -> HTTP/3 framing -> ALPN `h3`.

---

## Planned after protocol completeness

Lower-priority backlog (nginx module parity, proxy, observability,
robustness) tracked here; formal milestone numbers are assigned when each
is picked up.

- Rate limiting: `limit_req` (leaky bucket per key) + `limit_conn`
  (per-IP concurrency cap).
- Brotli + zstd compression, and serving precompressed `.gz`/`.br`
  (comptime precompression — the deferred M9 Part B).
- Request/response header manipulation module (`headers_filter`/`map`
  equivalent): add/remove/rewrite headers per route.
- `auth_basic` (htpasswd) and `auth_request` (subrequest auth).
- Per-request timeouts: `client_header_timeout`, `client_body_timeout`
  (slowloris defense beyond the existing idle timeout).
- HTTP response caching (`proxy_cache`-style) with LRU +
  stale-while-revalidate on the existing ETag/304 infrastructure.
- Load balancing: `random`, consistent-hash (`upstream_hash`),
  `least_time` (per-backend latency EWMA); active health checks.
- Sticky sessions (cookie-based).
- Traffic mirroring (nginx `mirror`).
- Prometheus `/metrics` endpoint and structured JSON access logs.
- OpenTelemetry trace spans.
- Connection limits (`max_connections`) and accept-backlog tuning.
- HTTP parser fuzzing + request-smuggling audit (TE/CL conflicts, RFC
  9110 §6.3).
- gRPC proxying (on top of M16).
- IPv6 listeners (dual-stack).

---
---

## Dependent milestones (blocked on Zig snapshot)

### DM1 — Comptime JSON config validation ✅ DONE

**Status**: shipped. `std.json`'s DOM cannot run at comptime (no allocator,
`@intFromPtr` in `std.mem`), so `src/runtime/json_config.zig` implements a
DOM-free comptime JSON parser/validator for the config schema: objects,
arrays, strings, integers, booleans, escapes (`\u` included). Malformed
input, unknown keys, unknown phases, duplicate keys and out-of-range numbers
are `@compileError` carrying the offending byte position. The parsed route
table, decoded strings and precomputed upstream sockaddrs freeze into
`.rodata` (multi-pass comptime-const table build — a slice of a comptime var
cannot escape). Module-name registry checks deliberately happen at startup
via `Config.validate` (comptime registry lookup costs ~50 eval branches per
binding).

Comptime budget notes (pinned 0.16.0-dev): the 1000-backward-branch quota is
shared by every `parse()` in a compilation and is sensitive to analysis
order (intermittent "evaluation exceeded 1000 backwards branches" without a
bump). `parse` therefore sets `@setEvalBranchQuota(100000)`, which also
allows large configs (a 100-route config parses fine). Keying on FNV-1a
hashes instead of `std.mem.eql` chains keeps per-token dispatch O(1) — every
comptime `eql` costs a branch per compared byte.

`Config.fromJsonComptime(json)` and `Config.fromEmbedded(path)` parse at
compile time; `Config.default()` now goes through the validator too.

---

### DM2 — Comptime config as the primary path ✅ DONE

**Status**: shipped. Build with `zig build -Dconfig=<file>` to embed a
project-root-relative JSON config at compile time (resolved through the
`embeds` module, same convention as M10 route `embed` paths). The config is
parsed by the DM1 validator at compile time (invalid configs are compile
errors), then `Server.comptimeInit` builds the route trie, per-route dispatch
functions, pre-serialised response templates (`response_bytes`, M11) and
upstream sockaddrs — everything in `.rodata`, no startup parsing, no
allocator, no trie build at boot. The runtime `--config` flag remains the
secondary path for development/dynamic uses (startup std.json parse +
startup trie + SIGHUP reload). Config source priority: `-Dconfig` (embedded)
> `--config` (runtime) > default.

Details:
- `Config.fromEmbedded(path)` is now root-relative via `embeds.embed`.
- Parser pool capacities are compile-time only (frozen slices use actual
  counts) and generous: 1024 routes, 4096 module/upstream bindings.
- Large embedded configs need comptime quota bumps: `json_config.parse`
  sets `@setEvalBranchQuota(100000)` (DM1), and `router.buildTrieImpl` now
  does too — a 100-route embedded config compiles and runs.
- Module names are validated at startup (`Config.validate`), consistent with
  the runtime path; structure/phase/key errors are compile errors.
- Tests: embedded server routes byte-identically to the JSON server across
  every route in `config.example.json`, and module-less template routes take
  the pre-serialised fast path (`matchFast`).

---

## Suggested starting milestone (next session)

**M16 — HTTP/2** is the next milestone: the biggest remaining gap versus
nginx, self-contained on the existing transport, and the prerequisite for
the gRPC/observability track. It should start with framing + HPACK +
single-stream correctness, then multiplexing and the A/B vs HTTP/1.1.
M17 (TLS) can proceed in parallel once the OpenSSL binding pattern is
established.
