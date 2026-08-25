# Unified Benchmark Plan — webserver / load-balancer / fileserver

Single entry point (to be built): `bench/unified.sh` — same skeleton as
`backlog-bench.sh` (interleaved reps, port-swap bias correction, crashed-rep
filter, medians). Servers: Zocket, nginx, HAProxy, Envoy; each enabled only
for cells it can legitimately serve (documented per cell).

## Benchmark points

### A. Webserver / fileserver cells (nginx + Zocket)
| Cell | Endpoint | Measures |
|---|---|---|
| h1_echo | POST /echo, 1 KB | raw handler cost |
| static_small | GET /f8k | fd-cache + writev path |
| static_large | GET /f1m | sendfile path |
| precompressed | GET /f8k (.gz twin) | gzip_static-style serving |
| cache_hit | GET /cached | response-cache HIT path |
| headers_ops | GET /h (3 ops) | filter-chain overhead |
| auth_basic | GET /auth ({SHA}) | credential verify overhead |
| limit_passthrough | GET /limited (rate=∞) | limiter overhead |
| limit_shed | GET /limited2 (rate=2k) | accepted/s + shed correctness |
| tls_h1 / tls_h2 | https GET | TLS handshake+throughput |

### B. Load-balancer cells (HAProxy + Envoy + nginx + Zocket)
All through each LB's proxy to the SAME origin pool (4 zocket echo backends);
LB-only comparison — no local content generation:
| Cell | Measures |
|---|---|
| lb_rr_c100 / lb_rr_c1000 | round-robin throughput/latency at 2 conns scales |
| lb_lc | least-connections |
| lb_hash | consistent-hash affinity correctness + throughput |
| lb_sticky | cookie affinity: correct backend pinning under churn |
| lb_failover | kill one origin mid-run: error rate + recovery time |
| lb_health | active checks on/off delta |

### C. Envoy-specific extras (Envoy + Zocket where applicable)
- HTTP/2 → HTTP/1 upstream termination
- retry policy (2 retries on 5xx) vs Zocket's passive failover

## Methodology (binding)
1. Co-resident servers, pinned `--threads <physical cores>`; origin pool on
   separate ports.
2. bombardier, c=100 default (c=1000 sweep for lb_rr), 6 s, 6 interleaved
   reps, port-layout swap halfway; medians only.
3. Status-code accounting every cell (2xx/3xx = good); crashed-rep filter
   (zero-completion reps dropped).
4. Latency p50/p95/p99 recorded from bombardier JSON.
5. Warm every cached path before its cell.
6. Machine fingerprint (CPU model, cores, governor, kernel) dumped to
   results header for cross-machine comparability.
7. Replication: fresh clone → `bash bench/unified.sh --quick` (1 rep/cell)
   or `--full`; requires only `zig build` + docker-less native binaries via
   `bench/build-{nginx,haproxy,envoy}.sh`.

## Deliverables per run
`bench/results/unified/<cell>/<server>_r<N>.json`, summary table,
`bench/graphs/unified_<group>.png` (one chart per group A/B/C).

## Build prerequisites (new)
- HAProxy 3.x: `bench/build-haproxy.sh` (make TARGET=linux-glibc USE_ZLIB=1)
- Envoy: official binary release pinned by version in script (Bazel build
  is not reproducible locally); config via static Bootstrap YAML template.

## STATUS (first run)
Group A harness validated end-to-end; KNOWN ISSUE: nginx served its old
3-endpoint template, so nginx numbers for f8k/f1m/precompressed/etc. are
invalid until unified.sh renders an nginx config mirroring ALL cells
(reuse foreign/nginx/backlog template + /echo + /f1m). Zocket
static_large 9.4k x 1MiB ~= 9.4 GB/s is real wire saturation.
Next: mirrored nginx template, HAProxy lb cells (build-haproxy.sh ready),
graphs renderer, README graph swap.
