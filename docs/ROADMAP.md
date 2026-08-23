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
  sticky sessions via cookie affinity. Active health checks remain open.
- Open leftovers: active health checks, brotli/zstd codecs, runtime zone
  size knobs beyond `proxy_cache_max_bytes`.
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

DM1/DM2 (comptime JSON config validation, comptime config as primary
path) shipped early and were superseded by M18.5's conf language.
Their records moved to `docs/milestones.md`.
