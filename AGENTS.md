## Project

High-performance TCP server in Zig 0.16.0-dev (pinned in `build.zig.zon`). Milestone 2 (multi-reactor) reached: multi-threaded epoll echo server, one epoll loop per core. Future base for a hot-reloadable, nginx-style config-driven HTTP server.

## Commands

- `zig build test` — run all tests (two parallel execs: library module + exe tests). Always run before finishing work.
- `zig build run` — run echo server (`src/main.zig`, default multi-reactor, port 8080).
- `zig build run -- --single` — run the Milestone 1 single-threaded server (A/B comparison).
- `zig build run -- --threads N` — multi-reactor with N reactor threads (default: CPU count; use physical-core count, e.g. 4, for best throughput).
- `zig build run -- --port P` — change port.
- `zig build -Doptimize=ReleaseFast` — for benchmarking.
- Benchmark: `bash bench/bench.sh <binary> <tag> [--extra server args]` (bombardier sweeps + echo-check) and `bash bench/bench2.sh <binary> <tag> [--extra server args]` (true-capacity echo-client sweeps); summarize with `bench/summarize.py` / `bench/summarize2.py`; see `bench/BENCH.md`.
- Verify compilation with `zig build` or `zig build-exe` after any change.

## Layout & conventions

- `src/root.zig` is the library module root; every new submodule MUST be re-exported there (consumer imports `@import("tcp_server")`).
- `src/root.zig` also comptime-imports every submodule: this Zig snapshot only collects `test` blocks reachable via comptime imports from the test root, so new submodules must be added to that block or their tests silently never run.
- `src/main.zig` is the exe entrypoint (CLI flags only; all server logic lives in `src/net/`).
- Planned modules (see `README.md` milestones): `net/` (exists), `http/`, `runtime/`, `dsl/` (router + config DSL). Organization in submodules is a hard requirement — never dump code into main.zig.
- `net/` currently: `server.zig` (Milestone 1 single-threaded epoll loop, kept for A/B), `multireactor.zig` (accept loop + dispatcher + reactor lifecycle), `reactor.zig` (per-core epoll thread; connection queue handed over via mutex + eventfd), `dispatcher.zig` (lock-free round-robin), `eventfd.zig`, `epoll.zig`, `connection.zig`, `buffer.zig`, `sockets.zig` (raw syscall helpers).
- Tests are inline `test` blocks in source files; any new functionality needs tests. Concurrency tests live in `reactor.zig`, `dispatcher.zig`, `multireactor.zig` (integration).
- Performance matters (epoll, multi-reactor per physical core; best throughput at `--threads <physical cores>`); no full RFC compliance needed for HTTP initially.
- Refer to `/home/sid/Personal/zig` for stdlib reference details.

## Known stdlib quirks (pinned 0.16.0-dev snapshot)

- `std.posix.accept` is unusable (its `AcceptError` omits `error.SocketNotListening` which its own body returns). Use `sockets.acceptNonBlock` (raw `accept4`).
- `std.posix.epoll_ctl` panics (`unreachable`) on EBADF — never call `epoll_ctl(DEL)` after closing the epoll fd (close connections before closing the epoll fd).
- `std.ArrayList` is the unmanaged `array_list.Aligned`: use `.empty`, `append(gpa, item)`, `deinit(gpa)`.
- `std.time.sleep` / `std.time.milliTimestamp` do not exist; use `std.posix.nanosleep` (nsec must be < 1e9) and `std.time.Instant`.
- Network sockaddr: `posix.sockaddr` = `{ family: u16, data: [14]u8 }`; `sockaddr_in` layout has NO BSD `sin_len`. Ports/addresses must be written as raw big-endian bytes (`writeInt(..., .big)`, NOT `nativeToBig` + `writeInt` — that double-swaps).

---
name: caveman
description: >
  Ultra-compressed communication mode. Cuts token usage ~75% by speaking like caveman
  while keeping full technical accuracy. Supports intensity levels: lite, full (default), ultra,
  wenyan-lite, wenyan-full, wenyan-ultra.
  Use when user says "caveman mode", "talk like caveman", "use caveman", "less tokens",
  "be brief", or invokes /caveman. Also auto-triggers when token efficiency is requested.
---

Respond terse like smart caveman. All technical substance stay. Only fluff die.

## Persistence

ACTIVE EVERY RESPONSE. No revert after many turns. No filler drift. Still active if unsure. Off only: "stop caveman" / "normal mode".

Default: **full**. Switch: `/caveman lite|full|ultra`.

## Rules

Drop: articles (a/an/the), filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging. Fragments OK. Short synonyms (big not extensive, fix not "implement a solution for"). Technical terms exact. Code blocks unchanged. Errors quoted exact.

Pattern: `[thing] [action] [reason]. [next step].`

Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
Yes: "Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:"

## Intensity

| Level | What change |
|-------|------------|
| **lite** | No filler/hedging. Keep articles + full sentences. Professional but tight |
| **full** | Drop articles, fragments OK, short synonyms. Classic caveman |
| **ultra** | Abbreviate prose words (DB/auth/config/req/res/fn/impl), strip conjunctions, arrows for causality (X → Y), one word when one word enough. Code symbols, function names, API names, error strings: never abbreviate |

Example — "Why React component re-render?"
- lite: "Your component re-renders because you create a new object reference each render. Wrap it in `useMemo`."
- full: "New object ref each render. Inline object prop = new ref = re-render. Wrap in `useMemo`."
- ultra: "Inline obj prop → new ref → re-render. `useMemo`."

Example — "Explain database connection pooling."
- lite: "Connection pooling reuses open connections instead of creating new ones per request. Avoids repeated handshake overhead."
- full: "Pool reuse open DB connections. No new connection per request. Skip handshake overhead."
- ultra: "Pool = reuse DB conn. Skip handshake → fast under load."

## Auto-Clarity

Drop caveman when:
- Security warnings
- Irreversible action confirmations
- Multi-step sequences where fragment order or omitted conjunctions risk misread
- Compression itself creates technical ambiguity (e.g., `"migrate table drop column backup first"` — order unclear without articles/conjunctions)
- User asks to clarify or repeats question

Resume caveman after clear part done.

Example — destructive op:
> **Warning:** This will permanently delete all rows in the `users` table and cannot be undone.
> ```sql
> DROP TABLE users;
> ```
> Caveman resume. Verify backup exist first.