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
bash bench/modules-bench.sh                         # feature-level (12 cells)
#  build-nginx.sh includes gzip + sub_filter now; the feature cells need
#  bench/static/{f8k,sub.txt} and the fixture origin bench/modules-origin.conf
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

## Feature benchmark: every module vs nginx (2026-10)

Twelve cells on identical endpoints, interleaved port layouts, medians of 6
samples (3 reps), 100 connections, 6 s each, 4 threads / 4 workers.
Upstream keepalive is configured on BOTH sides (nginx `keepalive 64`,
Zocket `proxy_keepalive 64`) — compare fairly.

| Cell | Feature | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| headers | 3 response-header ops/req | 437,919 | 381,985 | 1.15x |
| auth_sha | Basic auth from {SHA} htpasswd | 399,898 | 217,240 | 1.84x |
| precompressed | `.gz` twin serving (8 KB) | 323,261 | 164,600 | 1.96x |
| ret | pre-serialised `return` template | 418,658 | 347,706 | 1.20x |
| named | `try_files` miss → named location | 395,041 | 304,804 | 1.30x |
| limit_req | limiter pass-through | 415,449 | 358,765 | 1.16x |
| cache_hit | proxy_cache HIT (warm origin) | 402,747 | 195,950 | 2.06x |
| subf | proxied 8 KB body + `sub_filter` | 43,041 | 47,251 | 0.91x |
| gzip | proxied 8 KB body compressed | 60,392 | 111,390 | 0.54x |
| accel | X-Accel-Redirect → internal file | 69,871 | 104,971 | 0.67x |
| hide | proxied response + `proxy_hide_header` | 71,533 | 159,601 | 0.45x |
| proxy | raw reverse proxy (single origin) | 73,775 | 163,431 | 0.45x |

Notes:
- nginx `/ret` uses the echo module (this benchmark build has no rewrite
  module); Zocket fast-paths the pre-serialised template.
- **Every cell that proxies an upstream response body trails nginx**
  (0.45x–0.91x): the front's per-request upstream path costs ~2x nginx
  today. Raising `proxy_keepalive` from the default 8/thread to 64
  already moved the raw proxy cell 0.30x → 0.45x. This is the active
  optimization target; the request-side/local features (top half of the
  table) all lead.
- The raw cell definitions and the fixture origin live in
  `bench/modules-bench.sh`, `bench/modules-origin.conf`,
  `bench/modules-zocket.conf`, `bench/foreign/nginx/modules.conf.template`.

![Module features](graphs/modules_compare.png)


## Unified benchmark (web/file/LB)

All servers co-resident: Zocket, nginx (HAProxy/Envoy omitted — not
built on this machine; build `bench/.cache/haproxy-build/sbin/haproxy`
or set `ENVOY_BIN=` to include them). 8 workload cells, 2026-10 re-run.

![Unified](graphs/unified_web.png)

| Cell | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| h1_echo | 373,005 | 219,769 | 1.70x |
| static_small | 316,746 | 155,993 | 2.03x |
| static_large | 23,354 | 20,831 | 1.12x |
| precompressed | 306,186 | 152,060 | 2.01x |
| headers_ops | 390,286 | 352,314 | 1.11x |
| auth_basic | 384,707 | 204,446 | 1.88x |
| cache_hit | 392,631 | 189,206 | 2.08x |
| lb_rr | 59,392 | 144,604 | 0.41x |

`lb_rr` proxies through a 4-origin pool — the same upstream-body cost as
the feature table's proxy rows (p50 1.67 ms vs nginx 0.63 ms). An earlier
revision of this table reported `lb_rr 402,308 (2.66x)` for Zocket: those
runs had `unified.sh` building the front with the wrong config, so every
lb_rr/cache_hit zocket request was an instant 502. Fixed; raw JSON under
`bench/results/unified/`.


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
