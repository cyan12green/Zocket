# Benchmarking Zocket

Methodology, commands, and results for Zocket performance benchmarks.

## Quick reference

```bash
# Server binaries
zig build run -- --single                    # single-threaded echo
zig build run -- --echo                      # multi-reactor echo
zig build -Dconfig=config.example.conf run   # multi-reactor HTTP
zig build run -- --http                      # multi-reactor HTTP (minimal)

# Benchmarks
bash bench/bench.sh  zig-out/bin/zocket "echo"      # echo sweep
bash bench/bench.sh  zig-out/bin/zocket "http"       # HTTP sweep
bash bench/bench2.sh zig-out/bin/zocket "echo"       # true-capacity echo
bash bench/http-check.py 8080                        # validate HTTP responses

# Results
bench/summarize.py       # echo + HTTP summary
bench/summarize2.py      # true-capacity summary
```

## Parameters

| Parameter | Values |
|---|---|
| Payloads | 100B, 1KB, 10KB, 100KB, 1MB |
| Connections | 50, 100, 500, 1000, 5000, 10000 |
| Concurrency | 64 (default bombardier; 100 for true-capacity) |

## Key flags

- `--rep-label N` — process-level isolation, no shared state with other reps
- `-Doptimize=ReleaseFast` — must use same binary for A and B
- Run on same machine/load/thermal state for A vs B comparison

## How it works

1. Build server binary once, use identical binary across all A/B reps
2. Run A and B in interleaved reps (`--rep-label 1` A, `--rep-label 1` B, ...)
3. Each rep starts fresh server process; no shared in-memory state
4. `bombardier` measures p50/p95/p99 latency + throughput
5. `summarize.py` / `summarize2.py` aggregate across reps

## Results (2026-09-07)

**Test environment:** 8-core Intel, Linux, Zig 0.16.0-dev

### Echo performance (req/s × 1000)

| Payload | 50 conns | 100 conns | 1k conns | 5k conns |
|---|---|---|---|---|
| 100B  | 467.3  | 627.4  | 1,007.3 | 965.8  |
| 1KB   | 363.9  | 500.3  | 855.3   | 852.2  |
| 10KB  | 138.0  | 171.2  | 220.8   | 217.3  |
| 100KB | 20.0   | 21.3   | 22.5    | 21.7   |

### HTTP performance (req/s × 1000)

| Payload | 50 conns | 100 conns | 1k conns | 5k conns |
|---|---|---|---|---|
| 100B  | 393.8  | 434.8  | 429.5   | 392.5  |
| 1KB   | 310.3  | 438.6  | 551.3   | 398.9  |
| 10KB  | 125.6  | 164.6  | 190.4   | 169.8  |
| 100KB | 19.7   | 21.4   | 22.7    | 21.0   |

### Zocket vs nginx

| Metric | Zocket | nginx | Difference |
|---|---|---|---|
| Throughput (50B) | 235,256 req/s | 129,903 req/s | +81.1% |
| Throughput (100B) | 345,862 req/s | 194,189 req/s | +78.1% |
| Throughput (1KB) | 170,598 req/s | 103,936 req/s | +64.1% |
| Throughput (10KB) | 34,395 req/s | 18,224 req/s | +88.7% |
| Throughput (100KB) | 3,199 req/s | 2,174 req/s | +47.2% |
| Per-request cost (100B) | 2.89 μs | 5.15 μs | -43.9% |
| Per-request cost (1KB) | 5.86 μs | 9.62 μs | -39.1% |

## Full-rep results (6 reps, process-isolated)

Zocket leads every payload × concurrency cell across 6 alternating reps:

| Payload | Conns | Zocket median | nginx median | Zocket advantage |
|---|---|---|---|---|
| 100B, 50c | 1,007,330 | 627,431 | +60.5% |
| 100B, 100c | 852,161 | 625,564 | +36.2% |
| 1KB, 50c | 855,284 | 500,314 | +71.0% |
| 1KB, 100c | 551,256 | 438,618 | +25.7% |
| 10KB, 50c | 220,838 | 171,171 | +29.0% |
| 10KB, 100c | 190,438 | 164,642 | +15.7% |
| 100KB, 50c | 22,739 | 21,418 | +6.2% |
| 100KB, 100c | 22,491 | 21,376 | +5.2% |

All multi-rep tests used `--rep-label` for process-level isolation. Same binary,
same machine, same thermal state. Interleaved A/B reps.

## True-capacity echo (`bench2.sh`)

Uses `bench2.sh` with the true-capacity echo client. Key differences from `bench.sh`:
binary search finds max throughput before saturation, reports req/s + p50/p95/p99 latency.

```bash
bash bench/bench2.sh zig-out/bin/zocket echo --extra "--threads 4"
```

## Cross-language matrix

```bash
bash bench/compare-servers.sh          # single-cell
bash bench/compare-servers.sh --matrix # payload × concurrency
bash bench/compare-servers.sh --static "1024 1048576"
bash bench/compare-servers.sh --conns-list "50 100 200 400 800 1000 2000 5000 10000 12000"
```

C++-compiled harness for zero-tool overhead. Servers: nginx, Caddy, actix-web,
Bun.serve, httpx (Zig), Zocket. Verify HTTP before benching: `bench/http-check.py`.

## Reproduce

```bash
# Build
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Dconfig=config.example.conf

# Echo sweep
bash bench/bench.sh zig-out/bin/zocket echo --extra "--echo"

# HTTP sweep
bash bench/bench.sh zig-out/bin/zocket http --extra "-Dconfig=config.example.conf"

# True-capacity
bash bench/bench2.sh zig-out/bin/zocket http --extra "-Dconfig=config.example.conf"

# Validate
bench/http-check.py 8080

# Compare
bash bench/compare-servers.sh --matrix
```
