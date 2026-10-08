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

Status summary (full delivery records live in `docs/milestones.md`):

| Milestone | Status | One-liner |
|---|---|---|
| M1–M4 | DONE | epoll echo → multi-reactor → HTTP/1.1 → phase pipeline + module registry (`docs/milestones.md`) |
| M5 | DONE | Connection lifecycle: timer wheel, idle timeout |
| M6 | DONE | Chunked encoding, URL decoding, HEAD, MIME table |
| M7 | DONE | Comptime route trie + per-route dispatch specialisation |
| M8 | DONE | Comptime header-name hashing |
| M9 | DONE | gzip, cache headers, conditional GETs |
| M10 | DONE | Static files (disk + comptime embedded) |
| M11 | DONE | Comptime response templates (fast path) |
| M12 | DONE | Reverse proxy: pools, LB, passive health checks |
| M13 | DONE | Observability: access/error log, stub_status |
| M14 | DONE | SO_REUSEPORT accept, sendfile, writev |
| M15 | DONE | Benchmark-driven hardening (buffer growth, fd cache, pooling, arena, cached Date) |
| M16 | DONE | HTTP/2 (h2spec-verified; ALPN with M17) |
| M17 | DONE | Native Zig TLS 1.3 + session resumption |
| M18 | DONE | WebSocket + connection upgrade (RFC 6455) |
| M18.5 | DONE | Conf language, comptime-only (`-Dconfig`) |
| B1 | DONE | Modules batch: headers, auth_basic/auth_request, limit_req/limit_conn, precompressed, proxy_cache, LB extensions + sticky; shared request memory, bounded shmem zones, per-request timeouts |
| B2 | DONE | Reload-surviving zones + vhost readiness audit |
| B3 | DONE | Multi-server vhost pipeline (server_name, Host matching, per-port multireactor) |
| B4 | DONE | Connection limits + parser hardening + IPv6 listeners |
| M19 | PLANNED | HTTP/3 + QUIC (feasibility revisited before pickup) |



Most of these shipped as registry modules (2026-08-23), built on
two framework additions — the shared request memory
(`ctx.sharedAlloc/sharedDupe/sharedFmt`, reclaimed per response) and
bounded shared-memory zones (`dsl/shmem.zig`: capped key tables +
byte-budgeted LRU stores; nothing grows under load):

- DONE Rate limiting: `limit_req` (leaky bucket per client key, full-burst
  start) + `limit_conn` (per-key in-flight cap) with an always-run log-phase
  release half.
- PARTIAL Precompressed serving: `precompressed gz;` serves .gz twins
  (nginx gzip_static). Runtime brotli/zstd need vendored codecs; comptime
  precompression stays deferred (M9 Part B).
- DONE Header manipulation: `add_header` (universal now) / `set_header` /
  `remove_header` with nginx `always` gating and server→location
  inheritance.
- DONE `auth_basic` (comptime htpasswd: plaintext/{SHA}/bcrypt) and
  `auth_request` (internal subrequests via a typed Context hook).
- DONE Per-request timeouts: `client_header_timeout` (TOTAL-from-first-byte,
  anti-slowloris) + `client_body_timeout` (inactivity gap); reactor-level by
  nature.
- DONE Response caching: `proxy_cache` on bounded shmem zones — HIT/STALE/
  conditional revalidation converting upstream 304s back to stored 200s.
- DONE Load balancing: `random`, `consistent_hash`, `least_time` (EWMA);
  sticky sessions via cookie affinity.
- DONE Active health checks: shared backend-health shmem zone (visible to
  every reactor), a module-owned prober thread (TCP connect, optional HEAD
  path probe) applying rise/fall thresholds, `health_check path=... interval=
  rise= fall= timeout=` directive. Passive failures trip the circuit;
  probes revive it after `rise` successes.
- DONE Runtime zone-size knobs: `limits.proxy_cache_max_bytes` /
  `proxy_cache_max_entries` size the response zone at startup; the LruStore
  is runtime-sized with a chained hash directory (O(1) HIT lookups).
- OPEN Module framework v2 (this file): Stage 1 in progress; Stage 2 (async upstreams) follows.
- BLOCKED ON VENDORING Brotli + zstd compression: std.zig has no encoders
  for either (zstd is decompress-only); needs a vendored codec decision
  (C dependency vs pure-Zig port) before pickup.
- Traffic mirroring (nginx `mirror`).
- Prometheus `/metrics` endpoint and structured JSON access logs.
- OpenTelemetry trace spans.
- DONE Connection limits: `max_connections` (global ceiling) + `server_limit_conn` (per-IP cap) with shmem-backed counters.
- DONE HTTP parser hardening: CL.TE/TE.CL smuggling rejection, duplicate Content-Length detection (RFC 9112 §3.3.3).
- DONE IPv6 listeners (dual-stack): `listen [::]:8080;` syntax, `sockaddr_in6`, IPv4-mapped IPv6 for v4 peers, 16-byte `peer_ip` throughout.
- DONE Multi-server blocks: multiple `server {}` blocks with per-block
  `listen` and `server_name` directives; request routing by Host header
  / SNI to the matching server's route table. Comptime `ServerSelectFn`
  (exact + wildcard match in .rodata), `host_select on|off;` directive,
  per-port multireactor threads, reactor-level Host resolution.

---

## Module framework v2 — handler / filter / upstream (Stage 1 + 2 DONE)

The pipeline currently has one module kind bound to phases, with the `log`
phase doubling as the response-transform slot and the proxy doing blocking
upstream I/O inside a rewrite binding. This work splits the framework along
nginx's proven seams — content handlers vs output filters vs upstreams —
while keeping everything comptime-composed, and codifies the
futureproofing requirements that must hold as it grows.

### Target model

| Kind | Contract | Runs | Examples |
|---|---|---|---|
| **handler** | `run(ctx) -> Action{pass, handled, short_circuit}` | phase walk; first claim wins; every phase runs in order until something answers | echo, static, auth_basic, auth_request, limit_req/limit_conn, conditional_get, precompressed, proxy_cache checker |
| **filter** | post-response transform; `run(ctx)` mutates `ctx.resp` | after ANY outcome (incl. not_handled -> template), **reverse declaration order**, always; composed per route at comptime into direct calls (.rodata, zero indirection) | gzip, headers(set/add/remove), cache_headers, proxy_cache store |
| **upstream** | non-blocking state machine (`on_ready`) over backend I/O handles | owns backend connections; driven by reactor events via a single registration seam | proxy (+ active health checks formally housed here) |

Semantic line: request-side decisions are phase handlers; response-side
transforms are filters; backend I/O is upstream. Filters see only
`ctx.resp` — they never gate whether content is generated (that is what the
access phases and short_circuit are for).

### Config surface: context hierarchy + inheritance (nginx-style)

- New optional `http {}` block wrapping `server {}` blocks; existing
  top-level directives keep working and act as the implicit http scope (no
  mass config breakage).
- `filter <name>;` valid in http / server / location scopes. Directive-
  presence activation keeps working (declaring `add_header ...` binds the
  headers filter into the CURRENT scope).
- Inheritance is all-or-nothing per level: a location that declares no
  filters inherits its server's set; a server that declares none inherits
  the http scope's.
- Handlers stay location-bound via `<phase> <module>;` exactly as today.

### Hard breaks (accepted)

- `log gzip;` / `post_access cache_headers;` style bindings for modules
  migrated to filter kind become compile errors with a migration hint
  (`gzip is a filter: use 'gzip on;' / 'filter gzip;'`).
- Migrated to filters in Stage 1: `gzip`, `headers`, `cache_headers`,
  `proxy_cache_store`. Everything else stays a handler; `access_log` /
  `error_log` remain log-phase handlers (they log, they do not transform).

### Comptime guarantees (unchanged, extended)

- Per-route dispatch = comptime-unrolled handler walk + reversed filter
  nest + upstream entry point, all frozen into `.rodata`; no runtime
  registration, no Registry.resolve on the hot path.
- Kind checking at binding time is a compile error (a filter named in a
  phase directive cannot slip through).
- `matchFast` stays byte-exact: disabled when a route declares any filter.

### Futureproofing requirements (binding for this and future work)

Folded into Stage 1:

1. **Module lifecycle hooks**: `lifecycle: ?*const Lifecycle {init(limits),
   deinit()}` called for every registered module at server start/stop.
   Replaces lazy first-use initialization (zone creation, background thread
   spawn) with an auditable ordered startup/shutdown.
2. **Named per-module state slots**: `ctx.state(module) ?*anyopaque` keyed by
   the module's registry index replaces the collision-prone single
   `mod_state` pointer (limit_conn and proxy_cache cannot coexist today).
3. **Declared directive schema**: each module publishes its directives and
   parameter names as comptime data; the conf parser validates parse arms
   against them; enables generated docs and `--describe-modules`.
4. **Buffer-ownership contract**: a response body is exactly one of
   {comptime static, shared-arena slice, shmem copy made under lock};
   debug builds poison-check non-owned bodies at flush. Codified next to
   `Response`.
5. **Module test kit** (`dsl/testing.zig`): safe Case builders (the
   self-referential struct trap has bitten twice), mock-upstream helper,
   deterministic clock injection.

Folded into Stage 2 (rides the upstream seam):

6. **First-class subrequests + internal redirects**: generalize the
   auth_request hook into `ctx.subrequest(uri) -> Subresponse` (depth-
   limited mini-pipeline walk) plus `Action.internal_redirect(target)`
   (error_page chains, X-Accel-Redirect style).
7. **Transport abstraction for upstreams**: `on_ready` receives an opaque
   IoHandle (fd today), so QUIC-stream upstreams slot in without touching
   modules again.
8. **Streaming body escape hatch**: modules declare `streams_response`;
   such routes bypass body filters (header filters still run) until an
   incremental filter API exists. Documented constraint, never silent.

Tracked items (design notes recorded here; build later):

9. DONE Reload-surviving zones: memfd_create zones handed through daemon
    state file across `--reload-hard`; `src/dsl/memfd.zig` utility,
    `MmapKeyedTable` in shmem.zig, `ZoneRegistry` for named zone
    acquire/adopt, limit.zig lifecycle init from inherited fds.
10. **Metrics/tracing contract**: per-module counters in shmem, request-id
     propagation, OTel-ready span points (handler entry, filter exit,
     upstream done).
11. DONE Error taxonomy: `ModuleError` enum with central status mapping
     (`statusForModuleError` → 502/503/500); pipeline + reactor catch
     paths wired.
12. DONE Vhost readiness audit: `default_stats` is per-Server (allocated
     in `embeddedInit`, freed in `deinitPrepared`); `default_http_handler`
     documented as test-only fallback.
13. DONE Capability flags: `needs_body`, `streams_response`,
     `touches_headers` declared per module; reactor uses `needsBody` for
     body spooling, conf validates `touches_headers` + filter bindings.
14. HTTP-version conformance gate: CI exercises every built-in module
     over h2 (only some are verified today); enforces protocol-agnostic
     modules ahead of HTTP/3.

### Delivery stages and gates

- **Stage 1** DONE (2026-08-23): `Kind{handler,filter}` with comptime-
  checked bindings (`<phase> <filter>` is a compile error); per-route
  `Route.filters` applied reverse-declaration after walk+template in BOTH
  dispatch and loop-walk paths; `matchFast` gated off for filtered routes;
  conf contexts http/server/location for filters with all-or-nothing
  inheritance (+optional explicit `http {}` block); hard-break migrations
  applied (`log gzip;` -> `gzip on;`, cache_headers/store via presence);
  lifecycle hooks (`initModules(limits)` from reactor startup, gated),
  named state slots (`ctx.setState/getState`) replacing the single
  mod_state, module directive lists, buffer-ownership contract docs,
  `dsl/testing.zig` kit. Migrated to filter kind: gzip, headers,
  cache_headers, proxy_cache_store. 321 tests. Directive-schema arm
  validation is partial (names published + uniqueness checks; generic
  param validation deferred).
- **Stage 2** FUNCTIONALLY DONE, perf gate OPEN (branch module-v2-stage2):
  `Action` is a tagged union with `.async`; the reactor registers upstream
  fds (LT IN|OUT at park, IN after send) and drives proxy's
  send->read->adopt state machine; buffer-ownership fix copies adopted
  header/body slices into the request arena; deterministic socketpair
  unit test covers the driver. Live: 100% successful responses through
  the parked path. Standalone bombardier hits 150-250k req/s but is
  bimodal, and in-suite the proxy cell drops to ~6k (100% success,
  ~16ms/req) — an environment interaction that remains OPEN. The
  synchronous driver stays available via ctx.async_supported=false.
  REGRESSION NOTE (2026-08-24, post d8264e9): the full suite hangs on
  non-proxy cells (auth bombardier never completes; manual curls stall)
  after the subrequest/IoHandle/streaming batch — bisect those three
  commits first when resuming; master is unaffected.
  Bench gate (>=0.85x in-suite) not met yet; items 6-8 (subrequest
  generalization, IoHandle abstraction for QUIC, streaming flag) remain
  designed-not-built on top of this seam.

---
---

## Dependent milestones (blocked on Zig snapshot)

DM1/DM2 (comptime JSON config validation, comptime config as primary
path) shipped early and were superseded by M18.5's conf language.
Their records moved to `docs/milestones.md`.

---

## Next feature batches (researched 2026-10, ranked by value/cost)

Sized against this codebase (comptime config + 10-phase pipeline + bounded
shmem zones). S = days, M = 1–2 weeks, L = month+.

### Batch C1 — routing and resilience (SHIPPED 2026-10)

- `try_files` ✅: `try_files $uri $uri/ /fallback;` / `=404` (content
  phase, root-contained probes; named locations not supported — the
  fallback is a URI or `=code`).
- `error_page` + `internal_redirect` ✅: `error_page 404 500 /50x;` /
  `=200` (log phase, matches the outgoing status incl. unclaimed-404;
  non-GET/HEAD downgraded to GET on URI targets). Redirect loop in
  `Server.handleRequest`, capped at 8 hops (`redirect_hops` published,
  `effective_status` set before the log phase).
- `rewrite` ✅: `rewrite <pattern> <replacement> [last|break|redirect|
  permanent]` (rewrite phase, NFA patterns, `$1..$9`; directive shadows
  the `rewrite <module>` phase binding by arity). Regex `match()` went
  longest-wins so greedy captures extend.
- Upstream timeouts ✅: `proxy_connect/send/read_timeout` (seconds,
  0 = 1s/1s/5s defaults), threaded through connect/send/recv in both the
  sync and parked paths; probes bound by their own timeout.
- `proxy_next_upstream` ✅: `on|off` (default off — retries re-send the
  body); transport failures retry each usable backend once with sticky
  re-tagging on failover. 5xx from a live backend is final; sync path
  only.
- Upstream keepalive tuning ✅: `proxy_keepalive N` (default 8, hard cap
  32) / `proxy_keepalive_timeout S` (default 60s idle reap).
  Slice of the original plan deferred: per-request query preservation in
  rewrites is minimal (query re-appended, no `?`-override args handling);
  `proxy_next_upstream` has no `http_502`-style status retry and does not
  cover the parked path.

### Batch C2 — security and traffic control (SHIPPED 2026-10)

- `allow`/`deny` + `realip` ✅: CIDR ACLs in the access phase
  (first-match-wins, 403); `set_real_ip_from` + `real_ip_header`
  (default X-Forwarded-For) + `real_ip_recursive` restore `client_ip` in
  `post_read`. Shared v4/v6 + CIDR parsing in `sockets.zig`.
- PROXY protocol inbound (v1+v2) ✅: `listen ... proxy_protocol`
  (unified trailing-flag parser, all address forms); one header consumed
  per connection before TLS/h2/HTTP sniffing, source becomes the peer IP;
  garbage drops the connection.
- `limit_rate` + `limit_req_status` / `limit_conn_status` ✅: 429 joins the
  Status enum; refusal statuses configurable (429|503); per-connection
  token-bucket pacing (memory + sendfile bodies, shared pump helper,
  per-loop kick list) with a live pacing proof. Plain HTTP/1.1 only.
- `map` ✅: top-level blocks desugaring dests into synthetic per-route
  sets; lazy per-request eval with caching and a cyclic backstop.
  Sources/values see builtins + http/arg/cookie + captures (no set vars,
  no chaining); max_user_vars raised 8→16 for the slot budget.
- `expires` / `etag` + `gunzip` ✅: off/epoch/max/duration stamps (+
  max-age override semantics); `etag off` suppresses emission only;
  gunzip filter inflates for non-gzip clients (memory bodies,
  pass-through on corrupt/file bodies).
- Ops ✅: `--validate` exits 0/1 (TLS files load, listen port dry-binds);
  `--logfile` with SIGHUP reopen, recorded for `--reload-hard`.
  Slice deferred: per-request query override in rewrites, status-based
  `proxy_next_upstream` retry, parked-path retry, Prometheus/JSON logs
  (moved to C3).

### Batch C3 — cloud and protocol reach (M each)

- DNS resolver (async, TTL-respecting) ✅ SHIPPED 2026-10: hostnames in
  `proxy_pass`/`upstream` (`resolver 1.1.1.1 valid=30s;`, family-0 sockaddrs
  as unresolved markers, startup warn + 502 never startup failure, refresh
  thread with TTL cache + loopback Stub in tests).
- Upstream TLS (`proxy_pass https://`) ✅ SHIPPED 2026-10 (v1): SNI
  (`proxy_ssl_name` orelse hostname), verify
  (`proxy_ssl_verify on` + `proxy_ssl_trusted_certificate` bundle, cached
  process-wide, build fails without bundle), poll-bounded nonblocking record
  I/O (no EAGAIN panic, timeouts from route timeouts), `allow_truncation`
  on (origins closing without close_notify still 502 on short bodies via
  exact Content-Length). Sync driver only, single-use connections (no
  keepalive pooling, no parked-path TLS yet). No client-cert or session
  reuse in v1 (`std.crypto.tls.Client` has no client-cert surface).
  `std.crypto.tls.Client` already used as test oracle; config
  surface is the bulk; pool keyed by (host, port, tls).
- `ws://` proxy passthrough ✅ SHIPPED 2026-10 (v1 handshake): `proxy_ws on`
  forwards `Connection: Upgrade` (only when the client sent `Upgrade`) and
  relays 101s with `Connection` preserved end-to-end (sync + TLS + parked
  adopt paths); non-101s still strip hop-by-hop headers. Full duplex
  byte-pipe handoff needs the streaming escape hatch (Stage 2 upstream
  seam) — documented, not silent.
- TCP stream proxy + SNI preread routing ✅ SHIPPED 2026-10 (v1): L4
  `stream { server { listen; proxy_pass; sni ...; } }` with a ClientHello
  peek parser (`net/sni.zig`, zero-copy), exact→wildcard→default selection
  (`selectSni`), poll-driven `relayPair` splice and a per-connection-thread
  accept loop started from main alongside the HTTP reactors. Literals only;
  no LB/shmem-health reuse yet (single backend + SNI overrides).
- Prometheus `/metrics` + JSON access logs + status API ✅ SHIPPED 2026-10
  (v1): `prometheus` content module (exposition gauges from the six
  `ServerStats` counters) + `status_json` (same counters as JSON) +
  `jsonEscape` helper + JSON `log_format` preset documented (shmem
  per-module counters and comptime-tokenized renderer reuse deferred).
- Auth bundle ✅ SHIPPED 2026-10 (v1): CORS helper (`cors on` + origin/
  methods/headers/credentials/max_age, preflight 204), `secure_link`
  (HMAC-SHA256 `?e=&s=` over `{path}|{e}`, 403 on bad/expired), JWT-lite
  (`auth_jwt_secret` HS256 + `exp` + leeway, 401 on bad/missing/expired;
  static `jwks_file`/ES256 deferred — TLS ECDSA verify is the path).
- OCSP stapling ✅ SHIPPED 2026-10: `tls ocsp_file` (DER, parsed +
  good-status enforced at startup/`--validate`, fail closed), `status_request`
  parsed from ClientHello, response stapled as the CertificateEntry extension
  (RFC 8446 §4.4.2.1); unstapled flight byte-identical.
- mTLS client-cert verify ✅ SHIPPED 2026-10: `tls client_ca` (PEM bundle,
  parsed at startup, fail closed) + `tls verify_client` (refused without a
  bundle); CertificateRequest flight (both ECDSA schemes advertised),
  chain verify (leaf or via presented intermediates) + CertificateVerify
  signature over the transcript; Finished without a verified cert fails
  `certificate_required`. Tested message-level with openssl fixtures
  (chain/signature/flight-diff/gate); std's client answers no
  CertificateRequest, so network e2e stays hand-rolled (next: curl --cert
  against a verify listener).
- kTLS offload (attacks the ~15% TLS-over-h2c tax in `bench/BENCH.md`,
  restores sendfile zero-copy under TLS) — FOUNDATION SHIPPED 2026-10
  (`net/ktls.zig`: linux/tls.h-exact crypto_info for AES-GCM/ChaCha,
  cached probe, TX/RX configure with fail-closed fallback; session
  `exportTxKeys`; `tls ktls` toggle + startup probe log). Cutover
  (processHttpTls post-application arm via exportTxKeys→configure, then
  sendfile) needs a kTLS kernel to validate — this machine lacks it
  (CONFIG_TLS=m unloaded), so activation stays off by default.
- ACME/auto-HTTPS ✅ CORE SHIPPED 2026-10 (http-01): `acme { directory;
  contact; domain ...; }` (validated at build: https directory, mailto
  contact, DNS names) + ES256 JWS compact sign/verify + RFC 7638
  thumbprints + `acme_challenge` responder (bounded table, 404s unknown).
  The account→order→poll→finalize→download→install exchange loop follows;
  certs stay file-loaded, never `@embedFile`.

### Batch D — nginx parity + auto-HTTPS completion (researched 2026-10)

Sized the same way as C1–C3. Goal: every feature below exists in
nginx/Caddy today; each ships with tests + docs + its own commit, then
the comparison benchmarks must show Zocket ahead (iterate until green).

- D1 content parity ✅: precompressed `.br`/`.zstd` twins (no encoders —
  serve sibling twins like gzip_static/brotli_static), `sub_filter`
  response-body substitution (single + `once` semantics), `proxy_redirect`
  Location rewriting, X-Accel-Redirect internal file redirect. All shipped
  2026-10.
- D1.10 `proxy_hide_header` ✅ SHIPPED 2026-10: route-scoped upstream
  response-header filtering (repeatable, case-insensitive, both adopt
  paths).
- D1.9 `return 444;` ✅ SHIPPED 2026-10: nginx's silent connection drop
  (no response bytes, keep-alive forced off for the route; the fast path
  declines such routes).
- D1.8 location ergonomics ✅ SHIPPED 2026-10: named locations
  (`location @name`, excluded from path matching; reached via
  `try_files ... @name` and `error_page 5xx = @name`, URI preserved,
  method preserved) with a forced-route hop in the server's internal
  redirect loop; `internal;` locations (dual exact/prefix trie fields:
  external matching skips them, internal redirects land on them).
- D1.7 proxy parity ✅ SHIPPED 2026-10: `proxy_pass http://host/uri/;`
  URI-tail rewriting (nginx location-prefix replacement, query preserved).
- D1.6 protocol extras ✅ SHIPPED 2026-10: `Expect: 100-continue` answered
  immediately on HTTP/1.1 (plaintext + TLS) and HTTP/2 (interim :status 100
  HEADERS), so waiting clients upload without the ~1 s continue timer;
  upstream responses may now be arbitrarily large (arena-backed, 64 MiB
  cap) and `Transfer-Encoding: chunked` upstream bodies are decoded.
- D1.5 TLS parity ✅ SHIPPED 2026-10: server-scope `tls {}` blocks with
  SNI-based certificate selection at handshake time (exact > wildcard >
  default; cert-less vhost falls back to a server with creds;
  `--validate` checks every override). Upstream TLS keepalive pooling
  (per-backend, idle-reaped, reconnect-on-stale) also shipped 2026-10.
- D2 auth/resilience: JWT ES256 ✅ + `jwks_file` deferred (TLS ECDSA
  verify reuse done; JWKS rotation still deferred),
  `proxy_next_upstream` status retry (`http_502|http_503|...`), upstream
  TLS keepalive pooling (pool keyed by host/port/tls) + parked-path TLS.
- D3 ACME issuance loop ✅ SHIPPED 2026-10: full v2 exchange in
  `src/acme/client.zig` + PKCS#10/CSR/PEM writer (`src/acme/der.zig`,
  OpenSSL-verified) — account key generated/persisted, directory/nonce,
  newAccount, newOrder, http-01 publish via the challenge module, poll,
  finalize, download, install over the configured cert/key paths.
  Startup-triggered renewal daemon: re-checks every 12 h, renews inside
  the last 30 days (or when the file is missing), best-effort, transport
  over HTTP/TLS (system roots). Covered end-to-end by a fake-CA test.
- D4 head-to-head: nginx + Caddy + python baseline on this machine
  (`bench/compare-servers.sh` + `modules-bench.sh`); close any gap found,
  re-run until Zocket leads every cell; update `bench/BENCH.md`.

### Explicitly deferred

- HTTP/3 + QUIC (M19): man-year without std support; revisit after async
  upstreams + kTLS. Not started.
- Runtime brotli/zstd encode: no std encoders; ship precompressed
  `.br`/`.zstd` twins only. Runtime encode stays deferred.
- gRPC, `slice`, full SSI, FastCGI, syslog: negative value/cost for a
  speed-first server; say no until a user demands them.
- Traffic `mirror`, OpenTelemetry spans: designed (async subrequest
  clone; hook contract in shmem counters) but behind C1–C3.
