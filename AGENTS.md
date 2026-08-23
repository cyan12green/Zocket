## Project

High-performance TCP server in Zig 0.16.0-dev (pinned in `build.zig.zon`). Through M14: multi-reactor epoll transport, HTTP/1.1, config-driven phase pipeline (`src/dsl/`, `src/runtime/`), static files, reverse proxy, observability, kernel-level optimizations. M15 (benchmark-driven hardening): on-demand request-buffer growth, nginx `open_file_cache`-style static fd + content cache, connection pooling with embedded buffers, request bump arena, cached Date header, experimental io_uring backend. M16: HTTP/2 (HPACK, flow control, h2spec-verified). M17/M18 (TLS): a native Zig TLS 1.3 server (`src/tls/`) — ECDSA certs, X25519, ALPN h2 + http/1.1, stateless session tickets + PSK resumption — wired into the reactor with HTTPS benchmarks beating nginx 1.1-2.9x on the multiplexed workloads (`bench/tlsbench.sh`). M18.5 (conf language, M-A..M-E): the JSON config was replaced by an nginx-flavored `.conf` language compiled entirely at comptime (`src/dsl/conf.zig`, `-Dconfig=<file>`) — no runtime config path, no `--config`/`--reload-soft`/SIGHUP; `--reload-hard` is the only reload; complex-value types (`Frag`/`VarId`/`set`) live in `src/dsl/vars.zig` (M-B/M-C), regex router matching in `src/dsl/regex.zig` (M-D), `proxy_set_header` rendering (M-E). In the nginx/actix/Bun/Caddy/httpx comparison (bench/compare-servers.sh) Zocket leads every measured workload. Future base for a hot-reloadable, nginx-style config-driven HTTP server.

## Commands

- `zig build test` — run all tests (two parallel execs: library module + exe tests). Always run before finishing work.
- `zig build h2test` — HTTP/2 end-to-end integration tests (M16): builds the server and verifies it with `curl --http2-prior-knowledge` (GET/POST/HEAD, byte-exact 200 KB round-trip, static, redirect, 10-request multiplexing, HTTP/1.1 regression) plus `h2spec` RFC conformance (must pass ≥130/145). Requires curl with nghttp2 and `h2spec` (go install github.com/summerwind/h2spec/cmd/h2spec@latest). Run after any HTTP/2 or reactor change.
- `zig build run` — run server (`src/main.zig`, default multi-reactor HTTP mode, port 8080).
- `zig build run -- --single` — run the Milestone 1 single-threaded echo server (A/B comparison).
- `zig build run -- --echo` — raw byte-echo protocol (Milestone 1/2 semantics) in the multi-reactor framework.
- `zig build run -- --http` — HTTP/1.1 mode (default): `200 OK` echoing the request body, keep-alive, pipelining.
- `zig build -Dconfig=<file>` — embed a project-root-relative `.conf` file at compile time (nginx-flavored language, parsed + validated by the comptime conf parser in `src/dsl/conf.zig`; invalid configs are compile errors with `conf:<line>:<col>`). The server is built via `Server.comptimeInit` — trie, dispatch specialisation, regex NFAs, complex-value fragment lists, pre-serialised response templates and upstream sockaddrs all in `.rodata`; no startup parse. This is the **only** config path (comptime-only; no `--config`, no runtime reparse). Example: `zig build -Dconfig=config.example.conf run`.
- Daemon control (`--start`/`--stop`/`--status` with `--pidfile`; the daemon records `<pidfile>.state` — config path, optimize mode, port, threads, project root — for reloads). Reloads: `--reload-hard` is the only reload — rebuilds with `zig build -Doptimize=<state> -Dconfig=<state.config_path>` (comptime validation — bad configs abort with the old daemon untouched), execs the fresh `zig-out/bin/zocket --start`, then SIGTERMs the old daemon, which drains (graceful stop: stops accepting, closes its SO_REUSEPORT listeners, finishes connections within 30 s). The comptime embed (`@embedFile`) can only reach files inside the project tree (no dotdirs), so reload configs must live in the repo. SIGHUP is deliberately not handled.
- Comptime branch budget: the config parse, regex compilation, trie build and dispatch assignment share the per-compilation comptime branch quota (default 100000, `-Dconfig_branch_quota=<n>`). `Config.comptimeValidate` measures the config's compile cost and fails with a clear error before the quota is exhausted (safety factor 1.5); calibrate against the raw quota error when the units change.
- `zig build run -- --threads N` — N reactor threads (default: CPU count; use physical-core count, e.g. 4, for best throughput).
- `zig build run -- --port P` — change port.
- `zig build run -- --uring` — experimental io_uring batch I/O backend (epoll is the default; the ring regressed at high connection counts and is kept opt-in for further work).
- `zig build -Doptimize=ReleaseFast` — for benchmarking.
- Benchmark: `bash bench/bench.sh <binary> <tag> [--extra server args]` (bombardier sweeps; set `CHECK=http-check.py` for the HTTP server, default `echo-check.py` for raw echo), `bash bench/bench2.sh <binary> <tag> [--extra server args]` (true-capacity echo-client sweeps); summarize with `bench/summarize.py` / `bench/summarize2.py`; e2e HTTP checks: `bench/http-check.py <port>`; cross-language comparison (actix-web, Bun.serve, httpx.zig, nginx, Caddy as pinned submodules): `bash bench/compare-servers.sh` (single-cell), `--matrix` (payload x conns), `--static "1024 1048576"` (file serving), `--bodies`, `--conns-list`; see `bench/BENCH.md`.
- Verify compilation with `zig build` or `zig build-exe` after any change.
- HTTP/2 benchmarking needs `h2load` from nghttp2, built from `third_party/nghttp2` (clone + `autoreconf -i` + `./configure --enable-app --with-libev --with-libcares` + `make`; the binary lands in `third_party/nghttp2/src/h2load`). System deps for that build: **libev-dev** and **libc-ares-dev** (plus libssl-dev/zlib1g-dev, already present). `h2spec` for conformance: `go install github.com/summerwind/h2spec/cmd/h2spec@latest`.
- `zig build fuzz` (long deterministic fuzz campaign), `zig build h2test` (curl + h2spec end-to-end). TLS gate: the `src/tls/` tests include a full TLS 1.3 handshake + round trip against `std.crypto.tls.Client` over a socketpair; external oracles: `openssl s_client -tls1_3` (see the AGENTS.md note above for the `src/tls/` constraints: ECDSA-only certs, TLS 1.3 only, handshake traffic secrets derive from hash(ClientHello || ServerHello), record sequence numbers reset per key epoch (RFC 8446 §5.3), CCS record sent before the encrypted flight (middlebox compat), Finished verify_data length = Hash length).
- Graphs: `python3 bench/graphs.py` is the single entry point — it runs the
  full comparison suite (matrix + static) with `--run` and/or generates all
  PNGs in `bench/graphs/` (matrix req/s + latency per body size, static
  bars, Zocket-vs-nginx head-to-head with per-request cost) from
  `bench/results/servers/`; the README embeds them. For CI:
  `python3 bench/graphs.py --run`.

## Layout & conventions

- Prefer comptime wherever possible, especially for protocol parsing: build decode/lookup tables, tries, hashes and dispatch structures at compile time (M7 trie, M8 header-hash/DFA, the conf keyHash dispatch, and M16's HPACK static table + Huffman trie + frame-type table + settings table + hash-sorted name index are the reference patterns). Runtime loops over comptime-known data should be replaced with comptime-built structures (integer-compare hash prefiltering, binary-searchable indices). Remember comptime values freeze into `.rodata` (a slice of a comptime var cannot escape; build by value then slice).
- `src/root.zig` is the library module root; every new submodule MUST be re-exported there (consumer imports `@import("zocket")`).
- `src/root.zig` also comptime-imports every submodule: this Zig snapshot only collects `test` blocks reachable via comptime imports from the test root, so new submodules must be added to that block or their tests silently never run.
- `src/main.zig` is the exe entrypoint (CLI flags only; all server logic lives in `src/net/`, `src/http/`, `src/dsl/`, `src/runtime/`).
- Module map: `net/` (M1/M2 transport), `http/` (M3 parser/response), `dsl/` (M4 phase pipeline: `phase.zig`, `router.zig`, `registry.zig`, `pipeline.zig`, `modules/`), `runtime/` (M4 config + server wiring: `config.zig`, `server.zig`), `ct_pool.zig` (comptime typed pool — the arena for comptime builders: fixed array + len, `create`/`freeze`, no allocator). Organization in submodules is a hard requirement — never dump code into main.zig.
- `net/` currently: `server.zig` (Milestone 1 single-threaded epoll loop, kept for A/B), `multireactor.zig` (accept loop + dispatcher + reactor lifecycle), `reactor.zig` (per-core epoll thread; connection queue handed over via mutex + eventfd; echo or HTTP modes; io_uring backend opt-in via `--uring`, epoll default), `dispatcher.zig` (lock-free round-robin), `eventfd.zig`, `epoll.zig`, `connection.zig` (pooled connections with embedded 16 KiB buffers + `ConnectionPool`, M15), `buffer.zig` (growable byte buffer, `fromSlice` for embedded storage, `owns_data`), `iouring.zig` (thin std.IoUring wrapper: read/writev/poll/cancel with fd-tagged user_data, M15), `sockets.zig` (raw syscall helpers, incl. `setTcpNoDelay`).
- `http/` currently: `parser.zig` (incremental HTTP/1.x request parser: request line, headers, Content-Length body, keep-alive logic, 400/431/413/501 outcomes; header strings/decoded target/query live in the request's bump arena), `response.zig` (status + headers + body builder, Content-Length always set, single-pass serialisation with `formatUInt`; `writeHeadToBuffer` is the hot-path send serializer), `arena.zig` (request bump arena: embedded 16 KiB + overflow heap blocks, `reset()` between requests — zero hot-path allocations, M15), `header_dfa.zig` (comptime-built DFA classifying header names to an exact `HeaderTag` — one table lookup per byte, terminal state is the tag; the parser stores tags in slots and `Request.header` scans tags; `parser.header_hasher` (FNV) remains for response-side modules), `mime.zig` (comptime extension -> Content-Type switch), `websocket.zig` (RFC 6455: §4.2.2 accept-key digest, frame codec with mandatory client masking, 101 upgrade head).
- M4 phase pipeline (see `docs/config.md` for the config surface): `dsl/phase.zig` defines the 10 nginx-style phases (post_read … log); `dsl/router.zig` does prefix/exact/regex matching (exact beats prefix, longest prefix wins, regex in declaration order — nginx precedence); `dsl/registry.zig` is the comptime module registry — a module is a `Module` value (`name`, `phase`, `run(ctx) -> Action`), `pass`/`handled`/`short_circuit`; `dsl/pipeline.zig` walks `Phase.all`, running the route matcher in `find_config` and each matched route's phase binding; `dsl/modules/echo.zig` is the echo content module. `runtime/config.zig` builds `Config` from a comptime struct literal (`Config.default()`) or the comptime conf parser (`fromConfComptime`/`fromConfEmbedded`); `runtime/server.zig` is the shared `Server` the reactor calls. New modules: export a `Module` in `dsl/modules/`, add it to `default_registry` in `dsl/registry.zig`, re-export in root.zig.
- Conf parsing is comptime-only (`src/dsl/conf.zig`): tokenizer (sizes with k/m/g, quoted strings with escapes, `on|off`, comments, `conf:<line>:<col>` errors), directive registry, `server`/`location` (with `=`, `~`, `~*`, `^~` modifiers), phase directives, route directives, `tls`, `log_format`, budget check. Complex values (`$var`) are compiled by `src/dsl/vars.zig` (`parseComplexValue` → `[]const Frag`); regexes by `src/dsl/regex.zig` (M-D). The `limits` section (src/dsl/limits.zig) drives parser caps, buffer sizes, the static cache and the connection pool; the reactor applies them at init (sessions get Parser/Request initWithLimits, the pool/cache are built from the limits) and modules read `ctx.limits` (falling back to the compiled defaults when null).
- Reactor HTTP flow: read (edge-triggered drain; ring backend: one in-flight read per connection) → parse → build response via the shared M4 pipeline (Context{req, resp} → runtime.Server.handleRequest → phase pipeline) → Date (cached once per second) + Server headers are appended → head into the send buffer, body via writev → flush (epoll: writev + EPOLLOUT; ring: queued writev, one submit per loop iteration); keep-alive resets parser+request and continues with pipelined data; errors respond and close (receive side drained so close() sends FIN, not RST). `.not_handled` (no route / short-circuit / no module) → default 404. Upgrade (M18): a complete GET with `Connection: upgrade` + `Upgrade: <proto>` + `Sec-WebSocket-Version: 13` gets `101 Switching Protocols` (`src/http/websocket.zig`) and the session becomes a websocket byte pipe — text/binary echo, ping→pong, close→close+teardown; non-RFC upgrades stay plain HTTP. Static: the `static` module resolves via openat2(RESOLVE_BENEATH) against a root fd (config-loaded), serves from the `dsl/static_cache.zig` fd/content cache (mtime-revalidated, 1 s window) with sendfile for large files and one writev for cached small content.
- Tests are inline `test` blocks in source files; any new functionality needs tests. Concurrency tests live in `reactor.zig`, `dispatcher.zig`, `multireactor.zig` (integration); parser/response tests in `http/parser.zig`, `http/response.zig`; pipeline/registry/router/config tests in `dsl/`, `runtime/`; arena/cache/pool tests in their modules; RFC 6455 codec tests in `http/websocket.zig` (280 total). Note: reactor tests build their response expectations against the current second because responses carry the cached Date header.
- Performance matters (epoll, multi-reactor per physical core; best throughput at `--threads <physical cores>`; the M4 pipeline must stay under ~5% overhead — verify with same-day A/B against the pre-M4 tree). Benchmark discipline: interleave A/B runs (the box load swings ±30%+; single-pass numbers are noise), prefer medians over 8+ alternating reps, and verify syscall-level claims with `strace -c` (e.g. per-request mmap/munmap pairs, the EAGAIN drain probe). nginx comparison notes: nginx's `sendfile` defaults OFF (pread path — fast for small files); its cached date is `ngx_cached_http_time`; its epoll is edge-triggered with a read-once model whose `rev->ready` flag is only cleared by EAGAIN. No full RFC compliance needed for HTTP initially.
- Refer to `/home/sid/Personal/zig` for stdlib reference details.

## Known stdlib quirks (pinned 0.16.0-dev snapshot)

- `std.posix.accept` is unusable (its `AcceptError` omits `error.SocketNotListening` which its own body returns). Use `sockets.acceptNonBlock` (raw `accept4`).
- `std.posix.epoll_ctl` panics (`unreachable`) on EBADF — never call `epoll_ctl(DEL)` after closing the epoll fd (close connections before closing the epoll fd).
- `std.ArrayList` is the unmanaged `array_list.Aligned`: use `.empty`, `append(gpa, item)`, `deinit(gpa)`.
- `std.time.sleep` / `std.time.milliTimestamp` do not exist; use `std.posix.nanosleep` (nsec must be < 1e9) and `std.time.Instant`.
- Network sockaddr: `posix.sockaddr` = `{ family: u16, data: [14]u8 }`; `sockaddr_in` layout has NO BSD `sin_len`. Ports/addresses must be written as raw big-endian bytes (`writeInt(..., .big)`, NOT `nativeToBig` + `writeInt` — that double-swaps).
- `std.time.timestamp()` does not exist either — wall seconds come from `posix.clock_gettime(posix.CLOCK.REALTIME)` (the reactor's Date cache) and `std.time.Instant` is BOOTTIME (monotonic).
- io_uring: `std.os.linux.IoUring` — `copy_cqes` already advances the CQ head (do NOT call `cq_advance` again); iovec arrays passed to readv/writev SQEs must outlive the op (store them in the session/connection, never the flush stack); CQ overflow parks completions until an `enter(GETEVENTS)` — `drain` must not skip that flush; ring ops on O_NONBLOCK fds block instead of EAGAIN-ing (that is the point); closing an fd does not cancel in-flight ops — use `cancel()` + a deferred close, and capture the fd before destroying the connection (use-after-free).

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