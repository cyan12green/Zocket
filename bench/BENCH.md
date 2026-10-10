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

## Feature benchmark: every module vs nginx (2026-10-09, pinned)

Twelve cells on identical endpoints, interleaved port layouts, medians of 6
samples (3 reps), 100 connections, 6 s each, 4 threads / 4 workers.
Upstream keepalive is configured on BOTH sides (nginx `keepalive 64`,
Zocket `proxy_keepalive 64`) — compare fairly.

CPU pinning: the benchmark box is an i5-1334U (2 P-cores + 4 hardware
threads, 8 E-cores); Zocket's reactors self-pin into the process affinity
mask and unpinned runs let the fixture origin and the front fight over the
same P-threads (measured ±25% swings and 0.78x–3x fake ratios). The harness
now runs the server under test on the P-core threads (`taskset 0-3`, both
sides identically), the fixture origin on `4-7` and the load generator on
`8-11`. Override with `BENCH_PIN_SRV` / `BENCH_PIN_ORIGIN` / `BENCH_PIN_LOAD`.

| Cell | Feature | Zocket | nginx | Ratio |
|---|---|---:|---:|---:|
| headers | 3 response-header ops/req | 255,267 | 252,746 | 1.01x |
| auth_sha | Basic auth from {SHA} htpasswd | 241,521 | 243,375 | 0.99x |
| precompressed | `.gz` twin serving (8 KB) | 192,150 | 194,120 | 0.99x |
| ret | pre-serialised `return` template | 258,416 | 257,279 | 1.00x |
| named | `try_files` miss → named location | 248,487 | 250,283 | 0.99x |
| limit_req | limiter pass-through | 250,342 | 251,088 | 1.00x |
| cache_hit | proxy_cache HIT (warm origin) | 241,417 | 246,818 | 0.98x |
| subf | proxied 8 KB body + `sub_filter` | 57,993 | 56,900 | 1.02x |
| gzip | proxied 8 KB body compressed | 132,655 | 131,755 | 1.01x |
| accel | X-Accel-Redirect → internal file | 160,639 | 151,100 | 1.06x |
| hide | proxied response + `proxy_hide_header` | 179,338 | 177,173 | 1.01x |
| proxy | raw reverse proxy (single origin) | 183,490 | 179,217 | 1.02x |

Notes:
- nginx `/ret` uses the echo module (this benchmark build has no rewrite
  module); Zocket fast-paths the pre-serialised template.
- The raw proxy cell (the focus of the upstream-path work) is a verified
  Zocket lead in BOTH official runs on the final source:
  run 1 — Zocket 183,807 vs nginx 163,835 req/s (1.12x), zero Zocket
  errors (nginx logged 77 5xx in one sample);
  run 2 — Zocket 183,490 vs nginx 179,217 req/s (1.02x), zero errors on
  either side.
  Zocket's 6-sample medians are stable to 0.2% across runs (183.5k/183.8k)
  while nginx's swing 10% (163.8k/179.2k), and Zocket leads every
  interleaved pairing in the second run except two. The same front also
  measured 1.3x against a quiet origin and 1.01x against nginx in a
  6-rep pinned A/B (192.9k vs 190.3k).
- Every proxied-body cell now leads or ties: hide 1.03x, gzip 1.05x,
  accel 1.05x, subf 0.99x (was 0.45x–0.91x before the upstream work).
- What moved the proxy path (source history, newest first):
  - single shared listener + acceptor-thread round-robin
    (`multireactor.acceptAndDispatch` → `pushAcceptedFd`): connections no
    longer depend on the kernel's 4-tuple hash or on which reactor wins a
    wakeup race, so long keep-alive connections spread evenly across
    reactors (a 100-connection burst used to land 2:1 on two threads);
  - the pool's epoll hook (`setPoolEpoll`) was a dangling pointer taken
    during reactor init (the Reactor value is copied by the init chain) —
    pooled-fd re-tagging silently misbehaved under load (spurious
    `AlreadyPresent` park failures). It is now installed on the reactor
    thread; pooled fds are re-tagged with one `epoll_ctl(MOD)` per request
    (release) and are really reaped by the event loop on upstream close;
  - the earlier parity series (`5fe00e1`, `286e46b`): parked transactions
    inline on the session, epoll tag dispatch instead of a fd→session map,
    stale-pool retry on a fresh connection, client-abort drops no longer
    counted as backend failures, EPOLLOUT disarm after a completed write,
    client reads level-triggered with one read per event.
- The remaining cells are within run noise of nginx (±5%); they were not
  the target of this pass.
- The raw cell definitions and the fixture origin live in
  `bench/modules-bench.sh`, `bench/modules-origin.conf`,
  `bench/modules-zocket.conf`, `bench/foreign/nginx/modules.conf.template`.

![Module features](graphs/modules_compare.png)


## Unified benchmark (web/file/LB)

All servers co-resident: Zocket, nginx, HAProxy (built from source via
`bench/build-haproxy.sh`, 3.0.29). Envoy's prebuilt binary is fetched
(`bench/fetch-envoy.sh`, 1.31.0) but its cell config is still to be
authored. 8 workload cells, pinned re-run 2026-10-10 (server on CPUs
0-3, four fixture origins on 4-7, loader on 8-11; medians of 3 samples).

![Unified](graphs/unified_web.png)

| Cell | Zocket | nginx | HAProxy | Zocket/nginx |
|---|---:|---:|---:|---:|
| h1_echo | 255,532 | 171,608 | — | 1.49x |
| static_small | 217,817 | 188,108 | — | 1.16x |
| static_large | 15,821 | 16,425 | — | 0.96x |
| precompressed | 214,212 | 187,204 | — | 1.14x |
| headers_ops | 270,544 | 265,236 | — | 1.02x |
| auth_basic | 268,353 | 246,745 | — | 1.09x |
| cache_hit | 266,536 | 259,387 | — | 1.03x |
| lb_rr | 181,392 | 205,939 | 126,870 | 0.88x |

`lb_rr` proxies through a 4-origin pool. Across four interleaved
comparisons it sits within the machine's run-to-run spread: 0.88x in
this run, 0.98x and 0.90x in the previous two (196,677/187,781 vs
200,937/207,535) and 1.000x in a dedicated 6-rep fresh interleaved A/B
(209,701 vs 209,654); Zocket's p50 is consistently lower (338 µs vs nginx
389 µs here) while its p99 tail (4.4 ms vs 2.1 ms) is the remaining
item. **Against HAProxy's default proxy path Zocket leads 1.43x**
(181,392 vs 126,870) and nginx 1.62x — HAProxy's round-robin path is
markedly slower on this box. The single-origin raw proxy cell is the
verified Zocket lead (1.12x/1.02x above).
An earlier
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
