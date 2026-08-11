# Benchmark: Milestone 1 vs Milestone 2 (multi-reactor)

Date: 2026-08-10. Machine: single 4-core Intel Core i7-1185G7 @ 3.00 GHz
(8 logical CPUs, hyperthreading on), Ubuntu 24.04, kernel loopback only.
Both server builds are `ReleaseFast` from the same tree.

## Protocol caveat

The server is a raw byte-echo: it returns the request bytes unchanged. HTTP
benchmark clients (bombardier) therefore cannot parse the echoed response and
report every request as a response-parse error; they also cap out at ~2.9k
req/s on this machine regardless of server (client-side limit, see below).
To measure true server capacity a custom pipelined echo client
(`bench/echo-client.zig`) is used as the primary tool; it verifies every echo
byte-for-byte and reports an error count (`bad`).

## Reproducing

```sh
zig build -Doptimize=ReleaseFast

# bombardier sweeps (client-limited; consistent comparison)
bench/bench.sh zig-out/bin/tcp_server --single single_threaded
bench/bench.sh zig-out/bin/tcp_server multi_threaded_4 --threads 4

# true-capacity sweeps with the custom echo client
bench/bench2.sh zig-out/bin/tcp_server single_threaded --single
bench/bench2.sh zig-out/bin/tcp_server multi_threaded_2 --threads 2
bench/bench2.sh zig-out/bin/tcp_server multi_threaded_4 --threads 4
bench/bench2.sh zig-out/bin/tcp_server multi_threaded_8 --threads 8

python3 bench/summarize.py bench/results <tag>   # bombardier table
python3 bench/summarize2.py bench/results        # echo-client table
```

Raw results live in `bench/results/` (`*_c*_r*.json` = bombardier,
`*_ct*_r*.txt` = echo client).

## Correctness under load

`bench/echo-check.py` (50 concurrent connections, 40 random-size payloads,
byte-exact compare) runs at the start of every `bench.sh` run. In addition the
echo client verifies **every** request/echo pair byte-for-byte; every sweep
below completed with `bad=0`:

- bombardier sweeps: 2000/2000 byte-exact echoes (echo-check)
- echo-client sweeps: 1.6M–3.2M verified round trips per run, `bad=0`
- soak run (MT-4): 6.4M requests, 3,200 concurrent connections, `bad=0`

`zig build test` is green throughout (11 tests: buffer, epoll, eventfd,
dispatcher round-robin + cross-thread balance, reactor startup/shutdown,
reactor echo via socketpair, concurrent dispatch from 8 threads, and the
multi-reactor accept-under-concurrency integration test).

## Single-threaded baseline (Milestone 1)

bombardier (client-limited; median of 3 x 10s runs):

| connections | reqs/sec | latency p50 | latency p95 | throughput |
|---|---:|---:|---:|---:|
| 10 | 2864 | 2.75 ms | 7.54 ms | 0.89 MB/s |
| 100 | 2767 | 34.45 ms | 48.67 ms | 0.86 MB/s |
| 500 | 2627 | 183.48 ms | 231.64 ms | 0.82 MB/s |

echo client (true capacity; median req/s):

| client threads | req/s |
|---|---:|
| 8 x 50 conns | 161,133 |
| 16 x 50 conns | 133,634 |

## Multi-threaded results (Milestone 2)

echo client (median req/s; 3 reps each, byte-exact, bad=0):

| config | 8 client threads | 16 client threads |
|---|---:|---:|
| single_threaded | 161,133 | 133,634 |
| multi_threaded_2 | 195,828 | 184,927 |
| multi_threaded_4 | **205,405** | **220,773** |
| multi_threaded_8 | 123,584 | 184,116 |

bombardier (client-limited, MT-4): c=10: 2203 req/s; c=100: 2355; c=500: 2596
— not representative of server capacity (client saturates at ~2.9k req/s with
either server; see protocol caveat).

## Analysis

- The multi-reactor server scales with the number of reactors up to the number
  of **physical** cores. Best config: `--threads 4` (one epoll loop per
  physical core): **+27%** at 8 client threads (205k vs 161k) and **+65%** at
  16 client threads (221k vs 134k) over the single-threaded baseline.
- `--threads 8` regresses at light client load (8 pinned reactor threads +
  8+ client threads thrash 4 physical cores); at 16 client threads it is on
  par with MT-2. Hyperthreading does not help this workload.
- The numbers are still client-supply-limited (16 threads x 50 conns cannot
  saturate MT-4); the improvement is therefore a lower bound.
- Bombardier's absolute numbers are client-limited and identical across
  servers; it is retained in the harness because it is the tool required by
  the milestone, and its relative results are consistent.

## How to push further (not done here)

- SO_REUSEPORT so each reactor accepts directly (removes the single
  accept/dispatch hop and its eventfd wakeup per connection).
- Lower per-request syscall count (send from the recv path, avoid the extra
  EPOLLOUT round trip when the send buffer is empty).
- Batched epoll_ctl / writev; zero-copy via io_uring.
