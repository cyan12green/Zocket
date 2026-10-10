# Milestones

Zocket is developed in numbered milestones. This page is the delivery record;
forward-looking work lives in [`ROADMAP.md`](ROADMAP.md).

| Milestone | Description |
|---|---|
| M1 | Single-threaded epoll echo server (`src/net/server.zig`, kept as an A/B baseline). |
| M2 | Multi-reactor: one epoll loop per core, connection handoff via mutex + eventfd. Best throughput at `--threads <physical cores>`. |
| M3 | HTTP/1.1: incremental request parser, response builder, HTTP reactor mode. |
| M4 | Config-driven phase pipeline: comptime module registry, ten nginx-style phases, prefix/exact routing, echo module. |
| M5 | Connection lifecycle: ring-buffer timer wheel, idle timeout (`--idle-timeout`, default 60 s). |
| M6 | HTTP robustness: chunked transfer-encoding, URL decoding, HEAD, comptime MIME table. |
| M7 | Comptime route trie (O(path) lookup) and per-route dispatch specialisation. |
| M8 | Comptime header-name hashing (integer-compare lookups instead of string compares). |
| M9 | Response transforms: gzip, cache headers, conditional GETs (304). |
| M10 | Static files: disk serving (root/index/autoindex, byte ranges, 304) plus comptime-embedded assets. |
| M11 | Comptime response templates: module-less template routes pre-serialised into `.rodata`. |
| M12 | Reverse proxy: per-backend keep-alive pools, load balancing (round-robin / least-connections / ip_hash), passive health checks, `X-Forwarded-For` / `X-Real-IP`. |
| M13 | Observability: access log, error log, `stub_status`. (Its SIGHUP reload was replaced by `--reload-hard` in M18.5.) |
| M14 | Kernel-level work: `SO_REUSEPORT` per-reactor accept, `sendfile` for static bodies, `writev` for head + body. |
| M15 | Benchmark-driven hardening: request-buffer growth, static fd/content cache, connection pooling with embedded buffers, request bump arena, cached Date header, configurable limits, experimental io_uring backend. |
| M16 | HTTP/2 (RFC 9113, h2c prior-knowledge): HPACK, framing, stream multiplexing, flow control, CONTINUATION, trailers; h2spec-verified. ALPN `h2` landed with M17. |
| M17 | TLS/HTTPS: native Zig TLS 1.3 (no OpenSSL) — ECDSA certs, X25519, ALPN h2 + http/1.1, stateless session tickets and PSK resumption. |
| M18 | WebSocket / connection upgrade (RFC 6455): handshake digest, frame codec with mandatory client masking, reactor byte-pipe mode; non-RFC upgrades stay HTTP. |
| M18.5 | Conf language: an nginx-flavored `.conf` compiled entirely at comptime (`-Dconfig=<file>`) replaced the JSON config; complex values (`$var`), `set`, regex routing, `proxy_set_header`; `--reload-hard` is the only reload. |
| B1 | Modules batch: headers, `auth_basic`, `auth_request`, `limit_req`/`limit_conn`, precompressed serving, `proxy_cache`, LB random/consistent_hash/least_time with cookie sticky sessions; framework additions: shared request memory, bounded shmem zones, per-request timeouts. |
| B2 | Reload-surviving zones and vhost readiness audit: memfd-backed named shmem zones handed through the daemon state file, `MmapKeyedTable`, `ZoneRegistry`, lifecycle init from inherited fds, per-server stats, `ModuleError` status mapping, capability flags, memfd body spooling. |
| B3 | Multi-server vhost pipeline: `server_name` (exact + `*.domain` wildcard), multiple `server {}` blocks with per-block listen ports, `host_select`, comptime `ServerSelectFn`, `ServerGroup` with per-request Host resolution. |
| P18 | Zig 0.16 → 0.18 port and verification hardening: the removed std surface was shimmed (now `src/sys.zig`); all gates green on 0.18; coverage tooling (`zig build cov`, zig-cov with a local expansion patch, per-area `src/cov_*.zig` drivers) with a ≥90% line gate. |
| M19 | HTTP/3 + QUIC (planned). |

Dependency milestones DM1 (comptime JSON config validation) and DM2
(comptime config as the primary path) shipped early and were superseded by
the M18.5 conf language.
