# Zocket

A high-performance HTTP/1.1 and HTTP/2 server written in Zig, configured with
an nginx-style configuration language that is compiled at build time.

Zocket is a single static binary with no runtime dependencies: multi-reactor
epoll transport, native TLS 1.3, HTTP/2 (h2spec-verified), WebSocket upgrade,
a ten-phase module pipeline, reverse proxying, caching, rate limiting and
built-in ACME certificate management.

```sh
zig build -Dconfig=config.example.conf run
```

## Features

**Transport**
- One shared `SO_REUSEPORT` listener with round-robin accept dispatch into
  per-core epoll loops; optional io_uring backend (`--uring`)
- Connection pooling, per-request timeouts (slowloris defense), idle timeout
  via a timer wheel
- IPv4/IPv6 dual-stack listeners, `max_connections` global and per-IP
  connection ceilings

**Protocols**
- HTTP/1.1: incremental parser, keep-alive, pipelining, chunked transfer
  encoding, `Expect: 100-continue`
- HTTP/2 (h2c prior-knowledge and ALPN `h2`): HPACK, stream multiplexing,
  flow control, CONTINUATION, trailers
- Native TLS 1.3 (`src/tls/`, no OpenSSL): ECDSA P-256/P-384, X25519, ALPN,
  stateless session tickets and PSK resumption, SNI certificate selection,
  OCSP stapling, mTLS client verification
- WebSocket upgrade (RFC 6455) with an in-reactor byte-pipe mode
- PROXY protocol v1/v2 inbound headers and a TLS SNI-aware L4 stream proxy
  (`stream { server { ... } }`)

**Configuration**
- nginx-flavored `.conf` language parsed and validated entirely at build time
  (`-Dconfig=<file>`); invalid configurations are compile errors
- Route trie, dispatch specialisation, response templates and upstream
  addresses all live in `.rodata` — there is no runtime config parse
- `--reload-hard` performs a zero-downtime swap; daemon control via
  `--start` / `--stop` / `--status`

**Modules** (ten-phase pipeline, config-driven bindings)
- Static files: `sendfile`, byte ranges, conditional GETs, autoindex, a
  revalidating fd/content cache, comptime-embedded assets
- Reverse proxy: round-robin, least-conn, ip_hash, consistent_hash and
  least_time balancing, sticky sessions, upstream TLS with keep-alive
  pooling, retries and passive health checks, response caching
- Compression: `gzip`, precompressed `.gz` / `.br` / `.zstd` twins,
  `sub_filter` response rewriting, `gunzip`
- Access control: `auth_basic` (comptime htpasswd), `auth_request`,
  Basic/CORS/JWT (HS256 + ES256, JWKS rotation) authentication, IP access
  lists (`allow`/`deny`) and real-IP restoration (`set_real_ip_from`)
- Traffic: `limit_req` / `limit_conn`, `return 444` silent drops, traffic
  mirroring, header manipulation, `try_files` / `error_page` /
  `X-Accel-Redirect` internal redirects
- Observability: access logs (including JSON format), error logs,
  `stub_status`, Prometheus metrics
- ACME v2 auto-HTTPS: issuance and renewal daemon (http-01), no certbot
  required

## Quick start

```sh
zig build run                                  # HTTP server on :8080
zig build run -- --port 9000                   # custom port
zig build run -- --threads 4                   # reactor thread count
zig build -Dconfig=config.example.conf run     # compiled-in configuration
zig build run -- --help                        # all flags
```

Configuration is embedded at compile time:

```sh
zig build -Dconfig=config.example.conf run -- --validate   # print the route table
zig build -Dconfig=config.example.conf -Doptimize=ReleaseFast
```

See [`docs/config.md`](docs/config.md) for the full configuration reference
and [`examples/`](examples/) for runnable, commented configurations.

## Benchmarks

Measured against nginx on the same hardware, with interleaved repetitions and
CPU pinning; medians only. Summary of the current results (full methodology,
tables and raw data in [`bench/BENCH.md`](bench/BENCH.md)):

| Workload | Zocket vs nginx |
|---|---|
| HTTP echo (1 KB – 64 KB, c=10–1000) | 1.14x – 2.81x |
| Static files (1 KB / 1 MB) | 1.16x – 2.17x |
| Module features (headers, auth, gzip, cache, accel, …) | parity – 1.06x |
| Reverse proxy (single origin) | 1.02x – 1.12x |
| HTTP/2 over TLS (h2load) | 1.03x – 1.07x |
| HTTP/1.1 over TLS | 1.15x |
| Unified suite (web/file/LB) | 0.88x – 1.49x |

![Zocket vs nginx — HTTP/1.1](bench/graphs/readme_http.png)

## Development

```sh
zig build test             # 1,055 tests
zig build h2test           # HTTP/2 end-to-end + h2spec conformance
zig build cov              # line/block coverage report
bash bench/modules-bench.sh   # module features vs nginx
bash bench/unified.sh         # unified web/file/load-balancer suite
python3 bench/graphs.py --run # full benchmark suite + graphs
```

Requires the Zig snapshot pinned in `build.zig.zon`. Development conventions,
module-authoring recipes and the repository layout are documented in
[`AGENTS.md`](AGENTS.md) and [`docs/LAYOUT.md`](docs/LAYOUT.md); see
[`CONTRIBUTING.md`](CONTRIBUTING.md) before sending a change.

The codebase is developed with agentic tooling (DeepSeek V4 Flash via
OpenCode) under human review.

## Documentation

- [`docs/config.md`](docs/config.md) — configuration language reference
- [`docs/LAYOUT.md`](docs/LAYOUT.md) — source layout and architecture
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — roadmap and open items
- [`docs/milestones.md`](docs/milestones.md) — milestone history
- [`bench/BENCH.md`](bench/BENCH.md) — benchmark methodology and results

## License

[MIT](LICENSE.md)
