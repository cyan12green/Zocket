# Milestones

The milestone history of Ziglet. Current status: M1–M15 complete.

| Milestone | Status | Description |
|---|---:|---|
| M1 | DONE | Single-threaded epoll echo server (`src/net/server.zig`, kept for A/B). Baseline in `bench/BENCH.md`. |
| M2 | DONE | Multi-reactor: one epoll loop per core, connection handoff via mutex + eventfd. Best at `--threads <physical cores>`. |
| M3 | DONE | HTTP/1.1: incremental request parser, response builder, HTTP reactor mode. |
| M4 | DONE | Config-driven phase pipeline: comptime module registry, 10 nginx-style phases, prefix/exact routing, echo module, JSON or comptime config. See `docs/config.md`. |
| M5 | DONE | Connection lifecycle: ring-buffer timer wheel, idle timeout (`--idle-timeout`, default 60 s). |
| M6 | DONE | HTTP robustness: chunked transfer-encoding, URL decoding, HEAD, comptime MIME table. |
| M7 | DONE | Comptime route trie (O(path) lookup) + per-route dispatch specialisation. |
| M8 | DONE | Comptime header-name hashing (integer-compare lookups). |
| M9 | DONE | Response transforms: gzip, cache headers, conditional GETs (304). |
| M10 | DONE | Static files: disk (root/index/autoindex, ranges 206/416, 304) + comptime embedded assets (zero disk I/O). |
| M11 | DONE | Comptime response templates: module-less template routes pre-serialised and served from `.rodata`. |
| M12 | DONE | Reverse proxy: per-backend keep-alive pools, load balancing (round-robin / least-connections / ip_hash), passive health checks, X-Forwarded-For / X-Real-IP. |
| M13 | DONE | Observability: access log, error log, stub_status page, SIGHUP graceful reload. |
| M14 | DONE | Kernel-level: SO_REUSEPORT per-reactor accept, sendfile for static bodies, writev for head+body. |
| M15 | DONE | Benchmark-driven hardening: on-demand request-buffer growth (large bodies), nginx `open_file_cache`-style static fd cache (+ small-file content cache served as one writev), connection pooling with embedded buffers, request bump arena (zero hot-path allocations), cached Date header, configurable `limits`, experimental io_uring backend (opt-in `--uring`). |

The future roadmap is in `docs/ROADMAP.md`.
