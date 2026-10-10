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

The handler/filter split and the async upstream driver shipped; three
designed items remain on top of that seam:

- **Subrequests and internal redirects**: generalize the `auth_request` hook
  into `ctx.subrequest(uri) -> Subresponse` (a depth-limited mini-pipeline
  walk) plus `Action.internal_redirect(target)` for `error_page`-style chains.
- **Transport abstraction for upstreams**: `on_ready` should receive an
  opaque I/O handle (an fd today) so QUIC streams can slot in without
  touching modules again.
- **Streaming body escape hatch**: modules declare `streams_response`; such
  routes bypass body filters (header filters still run) until an incremental
  filter API exists. The constraint is documented rather than silent.

## Performance

- **`lb_rr` tail latency**: the multi-origin load-balancing cell sits at
  parity with nginx within run-to-run spread, but its p99 tail is worse
  (~4 ms vs ~2 ms). The single-origin proxy path is a verified lead.
- **Comptime candidates** (hot-path CPU, not throughput): a single-pass
  upstream request builder (upper-bound arena buffer with a two-pass
  fallback), a pre-rendered Date + Server block spliced into the response
  head, and an O(1) value-indexed HPACK static-table map (the name-indexed
  path is already a comptime hash-sorted table).
- **kTLS cutover**: the foundation (crypto-info, probe, TX/RX configuration,
  key export) is in `net/ktls.zig` but activation needs a kTLS-capable kernel
  to validate; this machine does not have one.

## Coverage

The ≥90% line gate is met (see `bench/.cache/coverage.json`). Remaining
misses are mostly tool attribution artifacts (defer lines, switch arms) plus
genuinely untested error branches in the largest files (`net/reactor.zig`,
`http2/session.zig`, `dsl/modules/proxy.zig`, `http/parser.zig`,
`sys.zig`). Further test work is optional and should target those error
branches.

## Blocked on an external decision

- **Runtime brotli/zstd encoding**: no encoders in the standard library
  (zstd is decompress-only). Serving precompressed `.br`/`.zstd` twins works
  today; runtime compression needs a vendored codec (C dependency vs a
  pure-Zig port).
- **Cross-server comparison cells**: the actix-web and httpx.zig cells need
  toolchains/submodule pins that are not currently available; the Envoy
  unified cell has a fetched binary but no authored cell configuration.

## Explicitly deferred

- gRPC, `slice`, full SSI, FastCGI, syslog: negative value for a speed-first
  server until a user requires them.
- OpenTelemetry trace spans: designed (per-module counters in shared memory,
  request-id propagation, span points at handler entry / filter exit /
  upstream completion) but not scheduled.
