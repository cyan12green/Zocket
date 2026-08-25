# Zocket benchmarking

Standing benchmark methodology, parameters and current results. Historical,
milestone-by-milestone commentary moved to `bench/HISTORY.md`.

## Machine and environment

Machine: single 4-core Intel Core i7-1185G7 @ 3.00 GHz (8 logical CPUs,
hyperthreading on), Ubuntu 24.04, loopback only, powersave CPU governor
(measured 2.4 GHz under load). Every server build is `ReleaseFast` from the
same tree; when comparing against other servers they are pinned third-party
builds (see `third_party/` and `bench/build-*.sh`).

**Environment caveat**: this is a shared workstation — external builds have
spiked load average above the CPU count mid-run in the past. Every
head-to-head comparison below is interleaved (servers alternate per rep) with
the machine at >85% idle, so drift hits both sides equally; absolute values
still carry run-to-run variance (see the per-rep spread in `bench/results/`).
**Prefer relative comparisons.**

## Methodology

### Load generators

| tool | use | notes |
|---|---|---|
| `bombardier` | HTTP/1.1 sweeps (echo, static, chunked) | metrics fully valid for HTTP responses (verified by `bench/http-check.py` before every sweep) |
| `bench/echo-client.zig` (via `bench/bench2.sh`) | true-capacity raw-echo (M1/M2) | pipelined; verifies every request/echo pair byte-for-byte (`bad=0`). Needed because bombardier is **client-limited** on raw echo: the M1/M2 server returns the request bytes unchanged, which bombardier cannot parse — it saturates at ~2.9k req/s regardless of server |
| `h2load` (nghttp2/1.59.0, built from `third_party/nghttp2`) | HTTP/2 (h2c prior-knowledge) | `-c 4 -m <streams> -n 100000` per rep |
| `bench/echo-check.py`, `bench/http-check.py` | correctness gates | run at the start of every sweep; a failure aborts the run |

### Workloads and parameters

| benchmark | script | request | parameters | servers |
|---|---|---|---|---|
| M1/M2 raw echo | `bench/bench2.sh` | pipelined echo | 8-16 client threads x 50 conns, 3 reps, byte-exact | Zocket `--single` / `--echo --threads N` |
| bombardier echo matrix | `bench/bench.sh` | POST /echo, bodies 1 B-64 KB | `-c 10/100/1000`, 3 reps x 5-10 s | any Zocket build |
| six-server matrix | `bench/compare-servers.sh` | GET empty, POST /echo | `-c 100`, 12 reps, interleaved | Zocket vs actix-web, Bun.serve, httpx.zig, nginx, Caddy (co-resident) |
| static file serving | `bench/compare-servers.sh --static` | GET /static, 1 KB / 1 MB | `-c 100/1000`, 12 reps, interleaved | same six |
| HTTP/2 (h2c) | `bench/h2bench.sh` | GET /echo, GET /static | 4 conns, m=100 / m=1, 8 reps x 100k requests, interleaved, warm-up rep discarded | Zocket vs nginx (`--with-http_v2_module`) |
| chunked transfer | `bench/chunked-bench.sh` | POST echo, 128 B / 8 KB | `-c 10/100/1000`, 3 reps x 5 s, interleaved | Zocket `/chunked` route (`chunked on;` route opt-in) vs nginx `echo -n` + `echo_flush` |

### Protocol

- **Interleaving**: head-to-head servers alternate per rep; medians are taken
  over the reps. A warm-up rep is discarded (nginx's first rep can fail with
  0 req/s if its workers are still starting).
- **Results**: raw per-rep values live in `bench/results/{servers,matrix,
  static,h2,chunked}/`; `python3 bench/graphs.py` renders `bench/graphs/*.png`
  (req/s and latency bars, Zocket vs nginx side by side on one axis).
- **nginx specifics**: `daemon off` runs in the foreground (background it);
  `keepalive_requests 100000` is set in the bench configs (the default 1000
  caps sustained measurements); listen ports are sed-ed per run from script
  constants. The h2c nginx build uses `--with-http_v2_module`; its chunked
  responses come from echo-nginx-module (`echo_flush` forces chunked because
  the length is unknown when the head is sent).
- **Zocket reactor count**: `--threads <physical cores>` (4 on this box) is
  the best configuration; hyperthreading does not help the workloads.

### Correctness under load

- `bench/echo-check.py`: 50 concurrent connections, 40 random-size payloads,
  byte-exact compare — runs before every `bench.sh` sweep.
- The echo client verifies **every** request/echo pair byte-for-byte; sweeps
  complete with `bad=0` (soak: 6.4M requests, 3,200 concurrent connections).
- `bench/http-check.py`: e2e HTTP checks (status, headers, bodies, keep-alive,
  pipelining) before HTTP sweeps.
- HTTP/2: `zig build h2test` (h2spec conformance, ≥130/145) + `zig build
  fuzz` before/after h2 benchmark work.
- `zig build test` (313 tests incl. concurrency) must stay green.

## Current results

### HTTP/1.1 cross-server (final interleaved A/B, c=100, 12-rep medians)

| workload | Zocket | nginx | vs |
|---|---:|---:|---:|
| GET / empty | 292,218 | 278,181 | 1.05x ours |
| 1 KB static | 262-278k | 157-168k | 1.66x ours |
| POST /echo 1 KB | 171-180k | 92-97k | 1.82x ours |
| 1 MB static | 13.2k | 12.8k | parity (bandwidth-bound) |

Zocket leads every workload in the six-server matrix (actix-web, Bun.serve,
httpx.zig, nginx, Caddy); detailed per-server numbers are in
`bench/HISTORY.md`.

### HTTP/2 (h2c) — Zocket vs nginx (h2load)

Date: 2026-08-15. Load generator: `h2load` (nghttp2/1.59.0, built from
`third_party/nghttp2`). Both servers serve h2c prior-knowledge on loopback,
4 reactor/worker threads. nginx built with `--with-http_v2_module`
(echo-nginx-module for `/echo`, sendfile on). Interleaved, warm-up rep
discarded, 8 reps; medians (req/s).

| workload (4 conns) | Zocket | nginx | vs |
|---|---:|---:|---:|
| GET /echo, m=100 streams | 460,567 | 152,211 | **Zocket 3.03x** |
| GET /echo, m=1 | 100,071 | 83,321 | **Zocket 1.20x** |
| GET /static (1 KB), m=100 | 118,435 | 68,210 | **Zocket 1.74x** |

The journey from ~19k to ~460k req/s (24x): `strace` showed 4 mmap+munmap
per request — per-stream `st.headers`/`st.body` ArrayLists and the per-call
response `out` buffer all allocated via `page_allocator` (a syscall per
alloc). Fixed by (1) pooling Requests per session (reused across streams,
arena reset on reuse), (2) decoding HPACK fields AND the st.headers/st.body
containers into the Request's bump arena (`Arena.asAllocator`), (3) a
reusable session scratch for the response HPACK block and a per-connection
`h2_out` response-frame buffer. Frame-type, settings and HPACK-name tables
are comptime-built.

### Chunked transfer encoding (h1) — Zocket vs nginx (bombardier)

Date: 2026-08-15. Load generator: `bombardier` (POST echo, `-m POST -b`),
5 s reps, 3 reps, interleaved; medians (req/s). Zocket: the `/chunked`
route (`chunked on;` route opt-in — the body is framed as
a single chunk; zero-copy: head+size, body, terminator as one writev).
nginx: `echo -n $echo_request_body` + `echo_flush` (echo-nginx-module),
which forces chunked because the length is unknown when the head is sent.
nginx's own chunked framing (separate writes) shows at 8 KB bodies, where
Zocket's single-chunk framing wins ~2x.

| workload | Zocket | nginx | vs |
|---|---:|---:|---:|
| POST echo 128 B, 10 conns | 147,456 | 104,206 | **Zocket 1.42x** |
| POST echo 128 B, 100 conns | 220,645 | 145,768 | **Zocket 1.51x** |
| POST echo 128 B, 1000 conns | 194,215 | 135,382 | **Zocket 1.43x** |
| POST echo 8 KB, 10 conns | 96,473 | 48,335 | **Zocket 2.00x** |
| POST echo 8 KB, 100 conns | 121,147 | 62,494 | **Zocket 1.94x** |
| POST echo 8 KB, 1000 conns | 93,064 | 64,762 | **Zocket 1.44x** |

### HTTP/2 over TLS (h2 via ALPN) — Zocket vs nginx (h2load)

Date: 2026-08-16. Load generator: `h2load` (nghttp2/1.59.0), `-c 4 -m
<streams>`, 100k requests, TLS 1.3 (AES_128_GCM_SHA256), self-signed
cert. nginx-tls: nginx 1.28.0 with `--with-http_ssl_module
--with-http_v2_module` + echo-nginx-module (see `bench/build-nginx-tls.sh`);
Zocket: the native Zig TLS 1.3 server (M17/M18) with `tls` config section.
Interleaved, warm-up rep discarded, 8 reps; medians (req/s).

| workload (4 conns) | Zocket | nginx | vs |
|---|---:|---:|---:|
| GET / (empty), m=100 | 423,531 | 151,535 | **Zocket 2.79x** |
| GET /echo, m=100 | 380,179 | 135,517 | **Zocket 2.81x** |
| GET /echo, m=1 | 65,527 | 73,671 | 0.89x (parity) |
| GET /static (1 KB), m=100 | 91,459 | 95,177 | 0.96x (parity) |

TLS costs Zocket ~15-20% over the h2c numbers (460k → 380k on echo m=100)
while nginx loses ~9%; the multiplexed workloads still lead by ~2.8x.
m=1 is latency-bound and lands at parity, as does the 1 KB static file
(the benchmark file exceeds the 16 KB content-cache threshold only at
larger sizes; static results sit at parity run-to-run on this shared
workstation).

## Reproducing

```sh
zig build -Doptimize=ReleaseFast

# raw echo (M1/M2): true capacity via the pipelined echo client
bench/bench2.sh zig-out/bin/zocket single_threaded --single
bench/bench2.sh zig-out/bin/zocket multi_threaded_4 --threads 4 --echo

# HTTP/1.1: valid bombardier sweeps
CHECK=http-check.py bench/bench.sh zig-out/bin/zocket http_4threads --http --threads 4
python3 bench/summarize.py bench/results <tag>

# six-server matrix + static (needs the pinned third-party builds)
bash bench/compare-servers.sh --matrix --bodies 1024 8192 65536 --conns-list 10 100 1000 --reps 3 --duration 5s
bash bench/compare-servers.sh --static 1024 1048576 --conns-list 100 1000 --reps 3 --duration 5s

# HTTP/2 vs nginx (needs nginx-v2 + h2load, see AGENTS.md)
bash bench/h2bench.sh

# chunked transfer vs nginx (needs nginx-v2 + echo-nginx-module)
bash bench/chunked-bench.sh

# HTTP/2 over TLS vs nginx (needs nginx-tls: --with-http_ssl_module --with-http_v2_module)
bash bench/tlsbench.sh

# graphs for everything (matrix/static/nginx/h2/chunked)
python3 bench/graphs.py
```

Historical milestone-by-milestone numbers and the full six-server tables:
`bench/HISTORY.md`.

## Backlog modules vs nginx (`backlog-bench.sh`, FINAL — stage 2 async)

bombardier c=100, 6 port-swapped reps per cell (medians; crashed-rep filter):

| Cell | Endpoint | Zocket | nginx 1.28 | Ratio |
|---|---|---:|---:|---:|
| headers (3 ops/req) | GET /h | 237.8k | 207.6k | **1.15x** |
| auth_basic ({SHA}, verified) | GET /auth | 203.3k | 166.0k | **1.23x** |
| precompressed (.gz 8 KiB) | GET /f8k | 169.8k | 110.5k | **1.54x** |
| reverse proxy (async hybrid) | GET /proxied | 151.4k | 91.8k | **1.65x** |
| proxy_cache HIT | GET /cached | 229.6k | 162.5k | **1.41x** |
| limit_req pass-through | GET /limited | 227.5k | 215.6k | **1.05x** |

Zocket leads ALL six cells. The proxy runs the framework-v2 hybrid driver:
inline-complete when the origin answers on the first non-blocking sweep
(sync-driver cost), park-and-yield on genuine blocks (reactor stays free
for other connections). Fixed en route: benchmark credentials now match
the htpasswd fixture (earlier auth/proxy cells measured 401-floods),
IN|OUT park registration (unsent-request starvation), proxy/reactor clock
unification, eager-pump arena rewind, adopted-slice ownership.

Graph: `bench/graphs/backlog_compare.png`; JSON in `bench/results/backlog/`.

## Unified suite (official, 6 port-swapped reps — 2026-08-24)

Group A webserver/fileserver + LB cell, all servers on identical endpoints
(`bench/unified.sh`, c=100, medians; p50/p99 in µs):

| Cell | Zocket | nginx | HAProxy |
|---|---:|---:|---:|
| h1_echo | **217.3k** / 291 | 144.1k / 366 | — |
| headers_ops | **227.2k** / 278 | 215.5k / 333 | — |
| auth_basic ({SHA}) | **222.9k** / 287 | 176.4k / 474 | — |
| static_small | **185.9k** / 344 | 123.3k / 665 | — |
| precompressed (.gz) | **180.1k** / 343 | 124.0k / 646 | — |
| lb_rr (4-origin pool) | **227.1k** / 277 | 77.4k / 1060 | 77.8k / 1116 |
| proxy_cache HIT | **225.3k** / 294 | 162.7k / 512 | — |
| static_large (1 MiB) | 9.7k / 8089 | 9.6k / 8647 | — |

Zocket leads every applicable cell; static_large is loopback-wire
saturated (~9.7 GB/s both). The rep-loop restart stall was eliminated by
driving each labeled rep as its own process (`--rep-label`), which is now
the official methodology.

Graph: `bench/graphs/unified_web.png`; JSON in `bench/results/unified/`.
