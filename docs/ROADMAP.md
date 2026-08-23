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
| B1 | DONE | Backlog batch as modules: headers, auth_basic/auth_request, limit_req/limit_conn, precompressed, proxy_cache, LB extensions + sticky; shared request memory, bounded shmem zones, per-request timeouts |
| M19 | PLANNED | HTTP/3 + QUIC (feasibility revisited before pickup) |



Most of this backlog SHIPPED as registry modules (2026-08-23), built on
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
- Connection limits (`max_connections`) and accept-backlog tuning.
- HTTP parser fuzzing + request-smuggling audit (TE/CL conflicts, RFC
  9110 §6.3).
- gRPC proxying (on top of M16).
- IPv6 listeners (dual-stack).

---

## Module framework v2 — handler / filter / upstream (PLANNED → Stage 1 in progress)

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

Tracked backlog (design notes recorded here; build later):

9. **Reload-surviving zones**: `--reload-hard` execs a fresh process today,
   resetting limit buckets and caches. Direction: back named shmem zones
   with memfd_create handed through the daemon state file.
10. **Metrics/tracing contract**: per-module counters in shmem, request-id
    propagation, OTel-ready span points (handler entry, filter exit,
    upstream done).
11. **Error taxonomy**: `ModuleError` enum with central status mapping
    (502/500/503 semantics) replacing anyerror guesswork.
12. **Vhost readiness audit**: globals assuming a single server block
    (health-route registry, default stats) get keyed by server before
    vhosts land.
13. **Capability flags**: `needs_body`, `streams_response`,
    `touches_headers` declared per module; reactor can spool huge uploads
    and validate bindings smarter.
14. **HTTP-version conformance gate**: CI exercises every built-in module
    over h2 (only some are verified today); enforces protocol-agnostic
    modules ahead of HTTP/3.

### Delivery stages and gates

- **Stage 1** (kinds + filters + contexts + items 1-5): registry/router/
  pipeline/conf + `dsl/testing.zig`. Hard-break migrations applied. Gate:
  full suite green, backlog bench numbers hold (filters add zero
  indirection), example conf builds.
- **Stage 2** (async upstreams + items 6-8): `Action.async{fd, want}`
  outcome; reactor registers upstream fds into the connection epoll set
  tagged by session; completions dispatch to the module's `on_ready`.
  Proxy migrates (connect -> send -> read_head -> read_body state machine,
  buffers in HttpSession); blocking path deleted. Bench gate: proxy cell
  >= 0.85x vs nginx, all other cells hold.

---
---

## Dependent milestones (blocked on Zig snapshot)

DM1/DM2 (comptime JSON config validation, comptime config as primary
path) shipped early and were superseded by M18.5's conf language.
Their records moved to `docs/milestones.md`.
