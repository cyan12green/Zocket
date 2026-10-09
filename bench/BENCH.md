# Benchmarking Zocket

Methodology, commands, and results for Zocket performance benchmarks.

## Quick start

```bash
# Single entry point: run ALL benchmarks (matrix + static + module features +
# unified) and render every graph referenced by this doc and README.md
python3 bench/graphs.py --run

# Use more reps for release-quality numbers (default 3 reps / 5s per cell)
python3 bench/graphs.py --run --reps 8 --duration 8s

# Individual benchmarks (optional, when you only need one suite)
zig build -Doptimize=ReleaseFast
bash bench/compare-servers.sh --matrix              # echo sweep
bash bench/compare-servers.sh --static "1024 1048576"  # file serving
bash bench/modules-bench.sh                         # feature-level
bash bench/unified.sh                               # unified web/file/LB

# Render graphs from stored results (all PNGs below)
python3 bench/graphs.py
```

`graphs.py --run` runs the four benchmark scripts above (matrix + static +
module features + unified, 3 reps each) and then regenerates every graph
embedded in this file and in `README.md`:

## Methodology

- **Process isolation**: `--rep-label N` starts a fresh server per rep; no shared in-memory state
- **Interleaved A/B**: reps alternate between servers to cancel thermal/load drift
- **Port-bias correction**: layout B swaps ports and repeats
- **Same binary**: `-Doptimize=ReleaseFast` built once, used for all reps
- ** bombardier**: HTTP/1.1 load generator, measures p50/p95/p99 latency + throughput

## Echo matrix (POST, req/s)

Six servers: Zocket, actix-web, Bun.serve, httpx.zig, nginx, Caddy.
Body sizes 1 KB / 8 KB / 64 KB × connections 10 / 100 / 1000.

![Matrix 1 KB](graphs/matrix_1024.png)
![Matrix 8 KB](graphs/matrix_8192.png)
![Matrix 64 KB](graphs/matrix_65536.png)

### Results table (req/s × 1000, 2026-10 re-run, re-verified)

Zocket vs nginx vs Caddy on this machine (actix/Bun/httpx need toolchains
that are not installed here; `SERVERS=` selects the subset). Medians of 3
interleaved reps in both port layouts, 6 s per rep, 4 threads / 4 workers.

| Body | Conns | Zocket | nginx | Caddy | vs nginx | vs Caddy |
|---|---|---:|---:|---:|---:|---:|
| GET / | 100 | 440.0 | 385.7 | 96.9 | 1.14x | 4.54x |
| 1 KB | 10 | 231.8 | 157.1 | 77.5 | 1.48x | 2.99x |
| 1 KB | 100 | 379.4 | 221.4 | 70.8 | 1.71x | 5.36x |
| 1 KB | 1000 | 307.5 | 202.6 | 60.1 | 1.52x | 5.11x |
| 8 KB | 10 | 151.4 | 61.5 | 32.7 | 2.46x | 4.63x |
| 8 KB | 100 | 204.2 | 80.6 | 34.0 | 2.53x | 6.00x |
| 8 KB | 1000 | 156.2 | 101.9 | 33.5 | 1.53x | 4.67x |
| 64 KB | 10 | 59.1 | 21.0 | 10.6 | 2.81x | 5.57x |
| 64 KB | 100 | 44.9 | 32.9 | 11.8 | 1.37x | 3.81x |
| 64 KB | 1000 | 43.6 | 42.1 | 13.3 | 1.04x | 3.28x |

The one near-tie (64 KB @ c=1000) is a tail-latency cell: Zocket p99 26 ms
vs nginx 201 ms — equal throughput, an order of magnitude steadier tail.
(An earlier 64 KB @ c=100 outlier — 124.8k — did not reproduce; the
re-verified numbers above are internally consistent with the c=10/c=1000
cells. This whole table was re-run after the location/trie changes.)

## Static file serving (GET, req/s)

1 KB and 1 MB files, 100 / 1000 connections. `tcp_nopush on` enables TCP_CORK
to batch the HTTP head + sendfile body into one TCP segment.

![Static serving](graphs/static.png)

| File | Conns | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| 1 KB | 10 | 244,786 | 142,430 | 1.72x |
| 1 KB | 100 | 392,152 | 180,957 | 2.17x |
| 1 KB | 1000 | 321,558 | 148,694 | 2.16x |
| 1 MB | 10 | 16,314 | 14,071 | 1.16x |
| 1 MB | 100 | 16,001 | 13,095 | 1.22x |
| 1 MB | 1000 | 15,677 | 12,769 | 1.23x |

## Zocket vs nginx (all cells)

Head-to-head across every workload: echo, static, and per-request cost.

![Zocket vs nginx](graphs/nginx_compare.png)

## Module features vs nginx

Feature-specific comparison on module endpoints (100 conns, interleaved reps).

![Module features](graphs/modules_compare.png)

| Cell | Zocket | nginx | Ratio |
|---|---|---:|---:|
| headers (3 ops/req) | 459,233 | 396,580 | 1.16x |
| auth_basic ({SHA}) | 394,351 | 217,094 | 1.82x |
| precompressed (.gz 8K) | 329,123 | 168,706 | 1.95x |
| proxy_cache (HIT) | 416,010 | 200,496 | 2.07x |
| limit_req (pass-through) | 419,293 | 356,618 | 1.18x |

## Unified benchmark (web/file/LB)

All servers co-resident: Zocket, nginx (HAProxy/Envoy omitted — not
built on this machine; build `bench/.cache/haproxy-build/sbin/haproxy`
or set `ENVOY_BIN=` to include them). 8 workload cells.

![Unified](graphs/unified_web.png)

| Cell | Zocket | nginx | Ratio |
|---|---|---:|---:|
| h1_echo | 420,798 | 230,884 | 1.82x |
| static_small | 311,590 | 168,204 | 1.85x |
| static_large | 22,056 | 20,551 | 1.07x |
| precompressed | 328,473 | 169,595 | 1.94x |
| headers_ops | 398,918 | 378,942 | 1.05x |
| auth_basic | 410,957 | 216,408 | 1.90x |
| cache_hit | 417,176 | 202,354 | 2.06x |
| lb_rr | 402,308 | 150,990 | 2.66x |

## HTTP/2 over TLS (h2load) — 2026-10

`bash bench/h2-bench.sh --reps 3 --duration 6 --conns "100 500"` — h2load
(from the pinned `third_party/nghttp2`, cmake build), 4 threads / 4 nginx
workers, 10 concurrent streams per connection, alternating port layouts.
Medians of 6 samples per server and cell.

| Cell | Zocket | nginx | Ratio | mean RTT Zocket | mean RTT nginx |
|---|---:|---:|---:|---:|---:|
| h2 100 conns x 10 streams | 425,842 | 412,053 | 1.03x | 2.12 ms | 2.13 ms |
| h2 500 conns x 10 streams | 402,158 | 375,125 | 1.07x | 11.2 ms | 11.0 ms |

HTTP/1.1 over the same TLS listener (bombardier `-k`, GET /, c=100,
medians of 3): Zocket 310,419 vs nginx 268,957 req/s (1.15x).

The historical h2/h2c graphs above stay from the earlier suite; the TLS
nginx build (`bench/build-nginx-tls.sh`) and h2load are the current
oracles for this section.

## Chunked transfer

![Chunked compare](graphs/chunked_compare.png)

## Reproduce

```bash
# Full suite (all benchmarks + all graphs), single command:
python3 bench/graphs.py --run --reps 8 --duration 8s

# Or step by step:
zig build -Doptimize=ReleaseFast
bash bench/compare-servers.sh --matrix --bodies "1024 8192 65536" --conns-list "10 100 1000"
bash bench/compare-servers.sh --static "1024 1048576" --conns-list "100 1000"
bash bench/modules-bench.sh
bash bench/unified.sh

# HTTP/2 over TLS (needs h2load + a TLS nginx + a P-256 cert pair):
cmake -B third_party/nghttp2/build -DENABLE_APP=ON -DENABLE_EXAMPLES=OFF \
      -DENABLE_HPACK_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build third_party/nghttp2/build --target h2load -j
bash bench/build-nginx-tls.sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /tmp/opencode/bench-tls.key -out /tmp/opencode/bench-tls.crt \
      -days 30 -nodes -subj "/CN=localhost"
bash bench/h2-bench.sh --reps 3 --duration 6 --conns "100 500"

# Generate every graph from stored results (what --run does after the suite):
python3 bench/graphs.py
```

Graph rendering needs `python3-matplotlib`; on machines without it the
tables above (and the raw JSON under `bench/results/`) are the source of
truth — `bench/graphs.py --run` still runs fine up to the render step.
