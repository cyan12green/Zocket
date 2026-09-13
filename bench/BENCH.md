# Benchmarking Zocket

Methodology, commands, and results for Zocket performance benchmarks.

## Quick start

```bash
# Run the full comparison suite and generate graphs
python3 bench/graphs.py --run

# Or run individual benchmarks
bash bench/compare-servers.sh --matrix              # echo sweep
bash bench/compare-servers.sh --static "1024 1048576"  # file serving
bash bench/backlog-bench.sh                         # module-level
bash bench/unified.sh                               # unified web/file/LB

# Generate graphs from stored results
python3 bench/graphs.py
python3 bench/graphs_backlog.py
python3 bench/unified_graphs.py
python3 bench/graphs_readme.py
```

## Methodology

- **Process isolation**: `--rep-label N` starts a fresh server per rep; no shared in-memory state
- **Interleaved A/B**: reps alternate between servers to cancel thermal/load drift
- **Port-bias correction**: layout B swaps ports and repeats
- **Same binary**: `-Doptimize=ReleaseFast` built once, used for all reps
- ** bombardier**: HTTP/1.1 load generator, measures p50/p95/p99 latency + throughput

## Echo matrix (POST, req/s)

Six servers: Zocket, actix-web, Bun.serve, httpx.zig, nginx, Caddy.
Body sizes 1 KB / 8 KB / 64 KB × connections 10 / 100 / 1000.

![Matrix 1 KB](bench/graphs/matrix_1024.png)
![Matrix 8 KB](bench/graphs/matrix_8192.png)
![Matrix 64 KB](bench/graphs/matrix_65536.png)

### Results table (req/s × 1000)

| Body | Conns | Zocket | actix | Bun | httpx | nginx | Caddy |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 KB | 10 | 117.4 | 82.8 | 50.3 | 2.6 | 62.5 | 31.1 |
| 1 KB | 100 | 195.9 | 158.0 | 43.1 | 2.8 | 114.0 | 35.7 |
| 1 KB | 1000 | 157.5 | 123.9 | 36.9 | 2.6 | 47.0 | 36.1 |
| 8 KB | 10 | 56.0 | 38.4 | 34.4 | 2.6 | 45.8 | 17.9 |
| 8 KB | 100 | 105.8 | 82.8 | 30.2 | 2.4 | 37.0 | 8.7 |
| 8 KB | 1000 | 63.8 | 80.4 | 39.5 | 3.5 | 44.3 | 5.3 |
| 64 KB | 10 | 26.9 | 29.6 | 16.6 | 2.7 | 20.7 | 6.0 |
| 64 KB | 100 | 23.2 | 18.0 | 11.6 | 1.9 | 24.4 | 7.3 |
| 64 KB | 1000 | 16.0 | 14.2 | 14.3 | 2.2 | 15.2 | 9.0 |

## Static file serving (GET, req/s)

1 KB and 1 MB files, 100 / 1000 connections. `tcp_nopush on` enables TCP_CORK
to batch the HTTP head + sendfile body into one TCP segment.

![Static serving](bench/graphs/static.png)

| File | Conns | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| 1 KB | 100 | 168,740 | 131,179 | 1.29x |
| 1 KB | 1000 | 165,241 | 107,472 | 1.54x |
| 1 MB | 100 | 8,203 | 8,308 | 0.99x |
| 1 MB | 1000 | 8,485 | 5,813 | 1.46x |

## Zocket vs nginx (all cells)

Head-to-head across every workload: echo, static, and per-request cost.

![Zocket vs nginx](bench/graphs/nginx_compare.png)

## Backlog modules vs nginx

Module-level comparison on feature-specific endpoints (100 conns, interleaved reps).

![Backlog modules](bench/graphs/backlog_compare.png)

| Cell | Zocket | nginx | Ratio |
|---|---:|---:|---:|
| headers (3 ops/req) | 203,785 | 165,839 | 1.23x |
| auth_basic ({SHA}) | 187,948 | 151,218 | 1.24x |
| precompressed (.gz 8K) | 161,937 | 113,205 | 1.43x |
| proxy_cache (HIT) | 56,968 | 150,208 | 0.38x |
| limit_req (pass-through) | 208,278 | 200,008 | 1.04x |

## Unified benchmark (web/file/LB)

All servers co-resident: Zocket, nginx, HAProxy. 8 workload cells.

![Unified](bench/graphs/unified_web.png)

| Cell | Zocket | nginx | HAProxy |
|---|---:|---:|---:|
| h1_echo | 206,930 | 136,046 | — |
| static_small | 182,081 | 114,375 | — |
| static_large | 9,784 | 9,575 | — |
| precompressed | 176,502 | 119,872 | — |
| headers_ops | 217,990 | 188,421 | — |
| auth_basic | 196,403 | 160,050 | — |
| cache_hit | 211,259 | 159,427 | — |
| lb_rr | 215,242 | 71,347 | 73,152 |

## HTTP/2 (h2c, h2load)

![H2 compare](bench/graphs/h2_compare.png)

## HTTP/2 over TLS

![TLS compare](bench/graphs/tls_compare.png)

## Chunked transfer

![Chunked compare](bench/graphs/chunked_compare.png)

## Reproduce

```bash
# Full suite (matrix + static + graphs)
python3 bench/graphs.py --run

# Individual benchmarks
zig build -Doptimize=ReleaseFast
bash bench/compare-servers.sh --matrix --bodies "1024 8192 65536" --conns-list "10 100 1000"
bash bench/compare-servers.sh --static "1024 1048576" --conns-list "100 1000"
bash bench/backlog-bench.sh
bash bench/unified.sh

# Generate graphs
python3 bench/graphs.py
python3 bench/graphs_backlog.py
python3 bench/unified_graphs.py
python3 bench/graphs_readme.py
```
