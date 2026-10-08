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

### Results table (req/s × 1000, 2026-10-08 re-run)

Zocket vs nginx vs Caddy on this machine (actix/Bun/httpx need toolchains
that are not installed here; `SERVERS=` selects the subset). Medians of 3
interleaved reps in both port layouts, 6 s per rep, 4 threads / 4 workers.

| Body | Conns | Zocket | nginx | Caddy | vs nginx | vs Caddy |
|---|---|---:|---:|---:|---:|---:|
| GET / | 100 | 421.7 | 374.3 | 96.7 | 1.13x | 4.36x |
| 1 KB | 10 | 226.1 | 146.2 | 75.4 | 1.55x | 3.00x |
| 1 KB | 100 | 365.2 | 218.6 | 70.0 | 1.67x | 5.22x |
| 1 KB | 1000 | 298.7 | 202.0 | 58.8 | 1.48x | 5.08x |
| 8 KB | 10 | 137.4 | 59.2 | 32.3 | 2.32x | 4.26x |
| 8 KB | 100 | 193.9 | 80.6 | 33.1 | 2.41x | 5.86x |
| 8 KB | 1000 | 156.0 | 100.5 | 32.7 | 1.55x | 4.77x |
| 64 KB | 10 | 58.1 | 20.6 | 10.5 | 2.82x | 5.52x |
| 64 KB | 100 | 124.8 | 32.6 | 11.7 | 3.83x | 10.7x |
| 64 KB | 1000 | 43.2 | 42.0 | 13.1 | 1.03x | 3.31x |

The one near-tie (64 KB @ c=1000) is a tail-latency cell: Zocket p99 27 ms
vs nginx 202 ms — equal throughput, an order of magnitude steadier tail.

## Static file serving (GET, req/s)

1 KB and 1 MB files, 100 / 1000 connections. `tcp_nopush on` enables TCP_CORK
to batch the HTTP head + sendfile body into one TCP segment.

![Static serving](graphs/static.png)

| File | Conns | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| 1 KB | 100 | 233,490 | 146,012 | 1.60x |
| 1 KB | 1000 | 189,346 | 127,745 | 1.48x |
| 1 MB | 100 | 9,774 | 9,313 | 1.05x |
| 1 MB | 1000 | 8,406 | 7,717 | 1.09x |

## Zocket vs nginx (all cells)

Head-to-head across every workload: echo, static, and per-request cost.

![Zocket vs nginx](graphs/nginx_compare.png)

## Module features vs nginx

Feature-specific comparison on module endpoints (100 conns, interleaved reps).

![Module features](graphs/modules_compare.png)

| Cell | Zocket | nginx | Ratio |
|---|---|---:|---:|
| headers (3 ops/req) | 233,894 | 217,518 | 1.08x |
| auth_basic ({SHA}) | 216,632 | 173,749 | 1.25x |
| precompressed (.gz 8K) | 182,087 | 122,575 | 1.49x |
| proxy_cache (HIT) | 219,381 | 165,244 | 1.33x |
| limit_req (pass-through) | 225,491 | 214,374 | 1.05x |

## Unified benchmark (web/file/LB)

All servers co-resident: Zocket, nginx, HAProxy. 8 workload cells.

![Unified](graphs/unified_web.png)

| Cell | Zocket | nginx | HAProxy |
|---|---|---:|---:|---:|
| h1_echo | 218,172 | 136,354 | — |
| static_small | 166,438 | 111,769 | — |
| static_large | 10,415 | 7,659 | — |
| precompressed | 175,828 | 112,237 | — |
| headers_ops | 215,776 | 190,317 | — |
| auth_basic | 164,474 | 159,393 | — |
| cache_hit | 149,983 | 120,698 | — |
| lb_rr | 172,818 | 71,890 | 73,756 |

## HTTP/2 (h2c, h2load)

![H2 compare](graphs/h2_compare.png)

## HTTP/2 over TLS

![TLS compare](graphs/tls_compare.png)

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

# Generate every graph from stored results (what --run does after the suite):
python3 bench/graphs.py
```
