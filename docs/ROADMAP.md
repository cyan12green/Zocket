# Roadmap

Zocket is a high-performance, modular HTTP server in Zig with an nginx-style
configuration compiled at build time. Delivered work is recorded in
[`milestones.md`](milestones.md); this page tracks what is still open.

Design principles that bind future work:

- Push work into comptime wherever the compiler allows (config validation,
  route resolution, dispatch specialisation, header classification,
  pre-serialised responses).
- One epoll reactor per physical core; no blocking I/O on a reactor thread.
- Every feature ships with tests and documentation; `zig build test` stays
  green and the benchmark suite must not regress.

## HTTP/3 + QUIC (M19)

Planned, not started. The Zig standard library has no QUIC implementation, so
this is a substantial effort (a QUIC transport plus the HTTP/3 framing layer
on top of the existing HTTP/2-style stream state machine). Revisit after the
async upstream work and kTLS have settled; the reactor's transport seam
(`IoHandle`, see below) is the intended integration point.

## Module framework v2 — remaining items

The handler/filter split and the async upstream driver shipped; one
designed item remains on top of that seam:

- **Transport abstraction for upstreams**: the seam exists
  (`IoHandle` in `dsl/registry.zig`; parked async upstreams register
  `ctx.async_handle` with the connection's fd) — grow its variants when
  HTTP/3 arrives rather than re-touching modules. The streaming body
  escape hatch (`streams_response` route/module flag) shipped.
- Subrequests shipped: `ctx.subrequest(uri) -> Subresponse` runs a target
  through the full pipeline and returns the verdict (status, response
  headers, body) copied into the source request's shared arena, under a
  shared depth budget with `auth_request`. Internal redirects remain
  generic (`ctx.internal_redirect_*` in `error_page`/`rewrite`/`try_files`).


## Performance

- **`lb_rr` tail latency**: FIXED — the unified benchmark previously built
  both front and origins with `-Dconfig=bench/unified-zocket.conf`, so
  origins also proxied `/proxied` to each other, creating multi-hop chains
  that inflated p99 tail (~4 ms vs ~2 ms). Origins now build with the
  default echo config and terminate requests; the front proxies. Verified:
  zocket 354k req/s p99 0.87ms vs nginx 206k req/s p99 ~2.1ms (front now
  LEADS nginx on both throughput and tail). Single-origin proxy path was
  already a verified lead (1.02x-1.12x).
- **Comptime candidates** (hot-path CPU, not throughput): a single-pass
  upstream request builder (upper-bound arena buffer with a two-pass
  fallback) and an O(1) value-indexed HPACK static-table map (the
  name-indexed path is already a comptime hash-sorted table).
- **kTLS**: the TX cutover ships (`tls { ktls on; }`): after the handshake the
  reactor exports the application traffic key and hands the encryption to the
  kernel; reads still decrypt in userspace. RX offload (the kernel decrypts
  too) is the next step — it needs the client->server key export and a
  handover that keeps the record sequence counters in step.
- **Pre-rendered Date + Server block**: measured and reverted (a pinned A/B
  showed 0.99x/1.00x — noise), so it stays out of the tree.

## Coverage

The ≥90% line gate is met: **90.6% (32,293/35,655 lines, 42.0% blocks)** at
the last run, with 1,054/1,054 tests green (see `bench/.cache/coverage.json`).
Remaining misses are mostly tool attribution artifacts (defer lines, switch
arms) plus genuinely untested error branches in the largest files
(`net/reactor.zig`, `http2/session.zig`, `dsl/modules/proxy.zig`,
`http/parser.zig`, `sys.zig`). Further test work is optional and should
target those error branches.

## Blocked on an external decision

- **Runtime brotli/zstd encoding**: no encoders in the standard library
  (zstd is decompress-only). Serving precompressed `.br`/`.zstd` twins works
  today; runtime compression needs a vendored codec (C dependency vs a
  pure-Zig port).
- The actix-web and Bun cells build and run from in-tree sources; the Envoy
  cell fetches its pinned release with `bench/build-envoy.sh`.

## Explicitly deferred

- gRPC, `slice`, full SSI, FastCGI, syslog: negative value for a speed-first
  server until a user requires them.
- OpenTelemetry trace spans: designed (per-module counters in shared memory,
  request-id propagation, span points at handler entry / filter exit /
  upstream completion) but not scheduled.
