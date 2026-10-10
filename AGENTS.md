# Zocket — developer notes

Working notes for contributors and coding agents: build and test commands,
repository conventions, module-authoring recipes, and the Zig-snapshot quirks
this tree works around. User-facing documentation lives in
[`README.md`](README.md) and [`docs/`](docs/).

## Project

Zocket is a high-performance HTTP/TCP server in Zig 0.18.0-dev (pinned in
`build.zig.zon`; ported from 0.16 — see `src/compat.zig`). It implements a
multi-reactor epoll transport, HTTP/1.1, HTTP/2 (h2spec-verified), native TLS
1.3 (`src/tls/`, no OpenSSL; ECDSA, X25519, ALPN h2/http1.1, session tickets),
WebSocket upgrade, and an nginx-style configuration language compiled entirely
at comptime (`-Dconfig=<file>`). Server behaviour is composed from a ten-phase
module pipeline (static, proxy with multiple load-balancing strategies, sticky
sessions, response cache, auth, rate limiting, header manipulation, gzip,
precompressed serving, logs, stub_status), with bounded shared-memory zones
for module state and per-request timeouts for slowloris defense.

Performance work is measured, not assumed: see [`bench/BENCH.md`](bench/BENCH.md)
for methodology and current results.

## Build, test and run

- `zig build test` — run all tests (two parallel test binaries: the library
  module and the exe). Use `--summary all` and beware of cache no-ops: a
  "cached" test step means the tests did not re-run; cache-bust
  `src/version.zig` when in doubt.
- `zig build` / `zig build-exe` — verify compilation after any change.
- `zig build run` — run the server (`src/main.zig`, multi-reactor HTTP mode,
  port 8080).
- `zig build run -- --single` — single-threaded echo server (A/B baseline).
- `zig build run -- --echo` — raw byte-echo protocol in the multi-reactor
  framework.
- `zig build run -- --http` — HTTP/1.1 mode (default): `200 OK` echoing the
  request body, keep-alive, pipelining.
- `zig build run -- --threads N` — N reactor threads (default: CPU count; use
  the physical-core count, e.g. 4, for best throughput).
- `zig build run -- --port P` — change the listen port.
- `zig build run -- --uring` — experimental io_uring batch I/O backend (epoll
  is the default; the ring regressed at high connection counts and is kept
  opt-in for further work).
- `zig build -Doptimize=ReleaseFast` — release build for benchmarking.

### Configuration and daemon control

- `zig build -Dconfig=<file>` embeds a project-root-relative `.conf` file at
  compile time (nginx-flavored language, parsed and validated by the comptime
  conf parser in `src/dsl/conf.zig`; invalid configs are compile errors with
  `conf:<line>:<col>`). The server is built via `Server.comptimeInit` — trie,
  dispatch specialisation, regex NFAs, complex-value fragment lists,
  pre-serialised response templates and upstream sockaddrs all live in
  `.rodata`; there is no startup parse. This is the **only** config path (no
  `--config`, no runtime reparse). Example:
  `zig build -Dconfig=config.example.conf run`.
- Daemon control: `--start` / `--stop` / `--status` with `--pidfile`. The
  daemon records `<pidfile>.state` (config path, optimize mode, port, threads,
  project root, zone fd descriptors) for reloads.
- `--reload-hard` is the only reload: it rebuilds with
  `zig build -Doptimize=<state> -Dconfig=<state.config_path>` (comptime
  validation — a bad config aborts with the old daemon untouched), execs the
  fresh `zig-out/bin/zocket --start`, then SIGTERMs the old daemon, which
  drains (stops accepting, closes its listener, finishes connections within
  30 s). Zone fds survive exec (`memfd_create`, no CLOEXEC) and are adopted
  from the old state file before module lifecycle init. The comptime embed
  (`@embedFile`) can only reach files inside the project tree (no dotdirs), so
  reload configs must live in the repo. SIGHUP only reopens `--logfile` (log
  rotation); it never touches config.
- `--validate` exits 0 after printing the route table plus `validate: OK`, or
  1 with the reason (TLS files unloadable, listen port unbindable).
- Comptime branch budget: config parse, regex compilation, trie build and
  dispatch assignment share the per-compilation comptime branch quota
  (default 100000, `-Dconfig_branch_quota=<n>`). `Config.comptimeValidate`
  measures a config's compile cost and fails with a clear error before the
  quota is exhausted (safety factor 1.5); calibrate against the raw quota
  error when the units change.

### Coverage

- `zig build cov` — line/block coverage via zig-cov (SanitizerCoverage; kcov's
  ptrace engine cannot instrument Zig 0.18 binaries — verified 0-2% vs
  zig-cov's full report). Needs `zig-cov` + `zig-cov-rt.o` on PATH (build
  <https://github.com/ericsssan/zcov> with this repo's Zig; keep both files in
  one directory). Runs `zig-cov test` (summary) and writes
  `bench/.cache/coverage.json`.
- Build wiring: `-Dcoverage` sets `use_llvm` + `fuzz` + `link_libc` on both
  test compiles and links rt.o onto the library module only (exe tests inherit
  it via the zocket import — adding it to both roots duplicates
  `zig_cov_ctor`). `fuzz` must stay on: `zig build` drives test binaries over
  the `--listen=-` IPC protocol, which the test runner only speaks in fuzz
  mode.
- Gate: project line coverage ≥90% (`bench/.cache/coverage.json` summary; met
  at 90.6%, 32.3k/35.7k, with 1,055/1,055 tests green).
- **Local zig-cov patch**: upstream's block→line expansion drops lines that
  follow a `try`/error branch (the error block sits between the executed code
  and statements that have no coverage point of their own — upstream's own
  HEAD commit documents the gap). `bench/patches/zig-cov-try-expansion.patch`
  fixes it: a two-pass expansion (executed-owner rows first, then rows inside
  an unexecuted block's span when a covered row of the same file precedes them
  at or before the same line). Rebuild after cloning zcov:
  `git apply bench/patches/zig-cov-try-expansion.patch && zig build -Doptimize=ReleaseSafe`,
  then copy `zig-out/bin/zig-cov` and `zig-out/lib/zig-cov-rt.o` onto PATH. The
  patch measured 65.4% → 88.4% on this tree with no false positives on a
  constructed ground-truth suite (`try` success/failure, taken/untaken `if`,
  never-entered loops, dead code, never-called functions).
- The summary includes linked std/compiler_rt files whose DWARF paths are
  relative (their coverable lines are not enumerated, so they report
  found==hit); project files alone are the stricter number.
- `src/cov_*.zig` are per-area split drivers for fast focused runs
  (`zig test -Mroot=src/cov_dsl.zig --dep embeds --dep config_options -Membeds=embeds.zig -Mconfig_options=src/cov_options.zig`);
  they are not imported by `src/root.zig`, so `zig build test` is unaffected.
- Coverage builds expose latent bugs normal builds hide. Fixed this way:
  `posix.errno` on raw syscalls breaks under libc — always use `linux.errno`;
  `CtPool.freeze` on runtime pools dangles — freeze inside `comptime blk` only.

### HTTP/2 and TLS verification

- `zig build h2test` — HTTP/2 end-to-end integration tests: builds the server
  and verifies it with `curl --http2-prior-knowledge` (GET/POST/HEAD,
  byte-exact 200 KB round-trip, static, redirect, 10-request multiplexing,
  HTTP/1.1 regression) plus `h2spec` RFC conformance (must pass ≥130/145).
  Requires curl with nghttp2 and `h2spec`
  (`go install github.com/summerwind/h2spec/cmd/h2spec@latest`). Run after any
  HTTP/2 or reactor change.
- TLS gate: the `src/tls/` tests include a full TLS 1.3 handshake and round
  trip against `std.crypto.tls.Client` over a socketpair. External oracle:
  `openssl s_client -tls1_3`. Constraints that keep the implementation
  interoperable: ECDSA-only certs, TLS 1.3 only, handshake traffic secrets
  derived from `hash(ClientHello || ServerHello)`, record sequence numbers
  reset per key epoch (RFC 8446 §5.3), CCS record sent before the encrypted
  flight (middlebox compatibility), Finished verify_data length = Hash length.
- `zig build fuzz` — long deterministic fuzz campaign over the HTTP/1 parser,
  HPACK decoder, HTTP/2 session and reactor HTTP path.

### Benchmarking

- `bash bench/bench.sh <binary> <tag> [--extra server args]` — bombardier
  sweeps (`CHECK=http-check.py` for the HTTP server; the default
  `echo-check.py` targets raw echo).
- `bash bench/bench2.sh <binary> <tag> [--extra server args]` — true-capacity
  echo-client sweeps; summarize with `bench/summarize.py` /
  `bench/summarize2.py`; e2e HTTP checks: `bench/http-check.py <port>`.
- Cross-language comparison (actix-web, Bun.serve, httpx.zig, nginx, Caddy as
  pinned submodules): `bash bench/compare-servers.sh` (single cell), `--matrix`
  (payload × connections), `--static "1024 1048576"` (file serving),
  `--bodies`, `--conns-list`.
- Feature benchmark vs nginx: `bash bench/modules-bench.sh [--reps N]` — five
  head-to-head cells (headers, auth_basic, precompressed `.gz`, proxy_cache
  HIT, limit_req shedding); JSON in `bench/results/modules/`, graph via
  `python3 bench/graphs_modules.py` → `bench/graphs/modules_compare.png`.
- Unified suite (web/file/load-balancer): `bash bench/unified.sh`; JSON in
  `bench/results/unified/`.
- HTTP/2-over-TLS benchmark: `bash bench/h2-bench.sh [--reps N] [--conns "100 500"]`
  — Zocket vs a TLS nginx (`bench/build-nginx-tls.sh`) over a P-256 cert pair
  (defaults to `/tmp/opencode/bench-tls.{crt,key}`; the openssl one-liner is
  in `bench/BENCH.md`). h2load builds from `third_party/nghttp2` via cmake
  (`-DENABLE_APP=ON`); libev/c-ares come from an apt download when not
  installed. Raw output in `bench/results/h2/`.
- Graphs: `python3 bench/graphs.py` is the single entry point. With `--run` it
  executes the full benchmark suite (matrix + static + module features +
  unified) and regenerates every PNG in `bench/graphs/`; without `--run` it
  renders from stored results.
- Benchmark discipline: interleave A/B runs (machine load swings ±30%+;
  single-pass numbers are noise), prefer medians over 8+ alternating reps, and
  verify syscall-level claims with `strace -c`. On asymmetric CPUs (P-cores +
  E-cores) pin the server under test and the fixtures to disjoint CPU sets —
  reactors self-pin into the process affinity mask (`sockets.pinToCpu`), and
  unpinned runs let the origin and front fight over the same P-threads (±25%
  swings). `bench/modules-bench.sh` and `bench/unified.sh` do this via
  `BENCH_PIN_SRV` / `BENCH_PIN_ORIGIN` / `BENCH_PIN_LOAD`.
- HTTP/2 benchmarking needs `h2load` from nghttp2, built from
  `third_party/nghttp2` (`autoreconf -i && ./configure --enable-app
  --with-libev --with-libcares && make`; the binary lands in
  `third_party/nghttp2/src/h2load`). System dependencies for that build:
  **libev-dev** and **libc-ares-dev** (plus libssl-dev/zlib1g-dev, usually
  present).

## Repository layout and conventions

- Prefer comptime wherever possible, especially for protocol parsing: build
  decode/lookup tables, tries, hashes and dispatch structures at compile time.
  Reference patterns in-tree: route trie, header DFA/hash dispatch, conf
  keyHash dispatch, HPACK static table + Huffman trie, frame-type tables,
  hash-sorted name indices. Runtime loops over comptime-known data should be
  replaced with comptime-built structures (integer-compare hash prefiltering,
  binary-searchable indices). Comptime values freeze into `.rodata` (a slice
  of a comptime var cannot escape; build by value, then slice).
- `src/root.zig` is the library module root; every new submodule **must** be
  re-exported there (consumers import `@import("zocket")`). It also
  comptime-imports every submodule: this Zig snapshot only collects `test`
  blocks reachable via comptime imports from the test root, so a new submodule
  must be added to that block or its tests silently never run.
- `src/main.zig` is the exe entrypoint (CLI flags only; all server logic lives
  in `src/net/`, `src/http/`, `src/http2/`, `src/dsl/`, `src/runtime/` and
  `src/tls/`). Organization in submodules is a hard requirement — never dump
  code into `main.zig`.
- Module map: `net/` (transport), `http/` (parser/response/websocket/mime),
  `http2/` (framing/hpack/session), `tls/` (native TLS 1.3), `dsl/` (conf
  language, phase pipeline, router, registry, modules, vars, regex, shmem,
  memfd), `runtime/` (config + server wiring + ServerGroup), `ct_pool.zig`
  (comptime typed pool — fixed array + len, `create`/`freeze`, no allocator).
  `docs/LAYOUT.md` lists the per-file breakdown.
- `net/`: `server.zig` (standalone single-threaded epoll loop, kept for A/B),
  `multireactor.zig` (one shared SO_REUSEPORT listener per server; the server
  thread accepts and round-robins accepted fds to reactors
  (`acceptAndDispatch` → `pushAcceptedFd`) — connection distribution is even
  regardless of the kernel's 4-tuple hash or wakeup races; per-port
  multireactor for multi-server, `initWithThreadsAndSpec()` for IPv6
  `ListenSpec`), `reactor.zig` (per-core epoll thread; accepted-fd queue +
  connection queue handed over via mutex + eventfd, adopted in `drainPending`;
  echo or HTTP modes; io_uring backend opt-in via `--uring`, epoll default;
  holds `*ServerGroup` for Host-based server selection), `dispatcher.zig`
  (lock-free round-robin), `eventfd.zig`, `epoll.zig`, `connection.zig`
  (pooled connections with embedded 16 KiB buffers + `ConnectionPool`),
  `buffer.zig` (growable byte buffer, `fromSlice` for embedded storage,
  `owns_data`), `iouring.zig` (thin `std.IoUring` wrapper: read/writev/poll/
  cancel with fd-tagged user_data), `sockets.zig` (raw syscall helpers,
  including `setTcpNoDelay`, `createListeningSocketFromSpec()`, `fmtIp()`,
  `fmtIpv6()`, IPv4/IPv6 dual-stack support).
- `http/`: `parser.zig` (incremental HTTP/1.x request parser: request line,
  headers, Content-Length body, keep-alive logic, 400/431/413/501 outcomes;
  rejects duplicate Content-Length and mixed TE+CL smuggling vectors; header
  strings, decoded target and query live in the request's bump arena),
  `response.zig` (status + headers + body builder, Content-Length always set,
  single-pass serialisation with `formatUInt`; `writeHeadToBuffer` is the
  hot-path send serializer), `arena.zig` (request bump arena: embedded 16 KiB
  + overflow heap blocks, `reset()` between requests — zero hot-path
  allocations), `header_dfa.zig` (comptime-built DFA classifying header names
  to an exact `HeaderTag` — one table lookup per byte, terminal state is the
  tag; the parser stores tags in slots and `Request.header` scans tags;
  `parser.header_hasher` (FNV) remains for response-side modules), `mime.zig`
  (comptime extension → Content-Type switch), `websocket.zig` (RFC 6455:
  §4.2.2 accept-key digest, frame codec with mandatory client masking, 101
  upgrade head).
- Phase pipeline (config surface documented in `docs/config.md`):
  `dsl/phase.zig` defines the ten nginx-style phases (post_read … log);
  `dsl/router.zig` does prefix/exact/regex matching (exact beats prefix,
  longest prefix wins, regex in declaration order — nginx precedence);
  `dsl/registry.zig` is the comptime module registry — a module is a `Module`
  value (`name`, `phase`, `run(ctx) -> Action`), with
  `pass`/`handled`/`short_circuit` actions; `dsl/pipeline.zig` walks
  `Phase.all`, running the route matcher in `find_config` and each matched
  route's phase binding; `dsl/modules/echo.zig` is the echo content module.
  `runtime/config.zig` builds `Config` from a comptime struct literal
  (`Config.default()`) or the comptime conf parser
  (`fromConfComptime`/`fromConfEmbedded`); `runtime/server.zig` is the shared
  `Server` the reactor calls, and `ServerGroup` manages per-vhost routing.
- Conf parsing is comptime-only (`src/dsl/conf.zig`): tokenizer (sizes with
  k/m/g, quoted strings with escapes, `on|off`, comments, `conf:<line>:<col>`
  errors), directive registry, `server`/`location` (with `=`, `~`, `~*`, `^~`
  modifiers), phase directives, route directives, `tls`, `log_format`,
  `host_select`, `server_name`, `listen` (bare port, `[addr]:port`,
  `addr:port`, `ipv6only=on`), `max_connections`, `server_limit_conn`, budget
  check. Complex values (`$var`) are compiled by `src/dsl/vars.zig`
  (`parseComplexValue` → `[]const Frag`); regexes by `src/dsl/regex.zig`. The
  `limits` section (`src/dsl/limits.zig`) drives parser caps, buffer sizes,
  the static cache and the connection pool; the reactor applies them at init
  (sessions get `Parser`/`Request` `initWithLimits`, the pool and cache are
  built from the limits) and modules read `ctx.limits` (falling back to the
  compiled defaults when null).
- Reactor HTTP flow: read (level-triggered, one read per readiness event — the
  LT socket re-fires while data remains; ring backend: one in-flight read per
  connection) → parse → Host-based server selection via
  `ServerGroup.selectServer(host)` (comptime `ServerSelectFn` when available,
  runtime fallback otherwise; `host_select off;` skips) → build the response
  via the shared pipeline (`Context{req, resp}` → `Server.handleRequest` →
  phase pipeline) → Date (cached once per second) and Server headers are
  appended → head into the send buffer, body via writev → flush (epoll: writev
  + EPOLLOUT; ring: queued writev, one submit per loop iteration); keep-alive
  resets parser and request and continues with pipelined data; errors respond
  and close (the receive side is drained so `close()` sends FIN, not RST).
  `.not_handled` (no route / short-circuit / no module) → default 404.
  Upgrade: a complete GET with `Connection: upgrade` + `Upgrade: <proto>` +
  `Sec-WebSocket-Version: 13` gets `101 Switching Protocols`
  (`src/http/websocket.zig`) and the session becomes a websocket byte pipe —
  text/binary echo, ping→pong, close→close+teardown; non-RFC upgrades stay
  plain HTTP. Static: the `static` module resolves via
  `openat2(RESOLVE_BENEATH)` against a config-loaded root fd and serves from
  the `dsl/static_cache.zig` fd/content cache (mtime-revalidated, 1 s window)
  with sendfile for large files and one writev for cached small content.
- Tests are inline `test` blocks in source files; any new functionality needs
  tests. Concurrency tests live in `reactor.zig`, `dispatcher.zig`,
  `multireactor.zig` (integration); parser/response tests in
  `http/parser.zig`, `http/response.zig`; pipeline/registry/router/config
  tests in `dsl/`, `runtime/`; arena/cache/pool tests in their modules;
  RFC 6455 codec tests in `http/websocket.zig`; module tests
  (headers/auth_basic/auth_request/limit/precompressed/proxy_cache/shmem
  zones) in `dsl/`. Note: reactor tests build their response expectations
  against the current second because responses carry the cached Date header.
- Performance matters: epoll, multi-reactor per physical core, best
  throughput at `--threads <physical cores>`; the pipeline must stay under
  ~5% overhead (verify with a same-day A/B against a pre-pipeline tree).
  nginx comparison notes: nginx's `sendfile` defaults to off (pread path —
  fast for small files); its cached date is `ngx_cached_http_time`; its epoll
  is edge-triggered with a read-once model whose `rev->ready` flag is only
  cleared by EAGAIN.
- Docs split: `docs/ROADMAP.md` is forward-looking only; per-milestone
  delivery history lives in `docs/milestones.md`; `docs/config.md` is the
  conf-language reference; `bench/BENCH.md` owns benchmark methodology and
  results (historical per-milestone numbers in `bench/HISTORY.md`). Source
  comments must not cite milestone numbers — they explain behavior and
  reasoning directly.

## Documentation

The repository keeps a standard open-source documentation set. Write for a
reader who has never seen the project; keep everything factual, current and
free of working-session narrative.

| File | Audience | Owns |
|---|---|---|
| `README.md` | users | What the project is, feature summary, quick start, benchmark summary, doc index, license. |
| `CONTRIBUTING.md` | contributors | How to build, test and propose changes; points at `AGENTS.md` for conventions. |
| `LICENSE.md` | everyone | MIT license text. |
| `AGENTS.md` | contributors, coding agents | Build/test/benchmark commands, repository conventions, module recipe, stdlib quirks (this file). |
| `docs/config.md` | users | Configuration language reference and runnable examples. |
| `docs/LAYOUT.md` | contributors | Source tree and module responsibilities. |
| `docs/ROADMAP.md` | contributors | Open work only: planned features, known gaps, blocked and deferred items. |
| `docs/milestones.md` | contributors | Delivery record: one row per milestone. |
| `bench/BENCH.md` | everyone | Benchmark methodology, current results, reproduction commands. |
| `bench/HISTORY.md` | contributors | Archived per-milestone benchmark numbers. |
| `examples/` | users | Runnable, commented configurations referenced from `docs/config.md`. |

Rules for keeping them professional:

- **No session narrative.** Documents describe the system as it is:
  methodology, results and reproduction. Do not record debugging
  play-by-plays, commit-hash storytelling, "we ran X and it failed", or
  per-run commentary — that belongs in commit messages, not docs. Historical
  benchmark numbers belong in `bench/HISTORY.md`, never in `README.md`.
- **No local or personal artifacts.** No absolute home-directory paths, no
  machine-specific or `/tmp` scratch paths except where a script genuinely
  defaults to one, no references to internal tooling sessions.
- **Keep numbers current.** Test counts, benchmark tables and feature lists
  are part of the docs; a stale number is a documentation bug. Refresh them
  in the same change that moves them.
- **Forward-looking vs history.** `ROADMAP.md` lists only what is still
  open; delivered work moves to `milestones.md` (one line) when it ships.
  Never leave "shipped" items in the roadmap.
- **One source of truth per fact.** Feature lists live in the README,
  configuration details in `docs/config.md`, benchmark methodology and
  results in `bench/BENCH.md`; other documents link to them instead of
  restating details.
- **Update docs with the change.** Configuration changes go to
  `docs/config.md` and (usually) `examples/`; user-visible behaviour changes
  go to the README; new commands or conventions go here.
- **Markdown hygiene.** Escape `|` inside table cells, keep every table's
  column count consistent, verify relative links resolve, and avoid
  duplicated headings or leftover checklist files.

### Adding a module

Keep the recipe mechanical; framework flexibility is a priority.

1. Create `src/dsl/modules/<name>.zig` exporting a `registry.Module` plus
   inline tests. Pick the kind first: `.kind = .handler` (phase-bound,
   request-side: auth, limiting, content generation; actions
   `.pass`/`.handled`/`.short_circuit`) or `.kind = .filter` (response
   transform; runs after every outcome in reverse declaration order; mutates
   `ctx.resp`, returns anything — actions are ignored). Handlers need
   `.phase`; filters carry a legacy marker value. Bind handlers via
   `<phase> <name>;` (a compile error if the module is a filter); filters bind
   via `filter <name>;` in http/server/location scopes (all-or-nothing
   inheritance) or via their own directives through `ensureFilterBound`. For
   shared-memory zones or background workers, declare a `lifecycle`
   (`init(limits)` runs once per process from reactor startup; `deinit()` at
   shutdown) instead of lazy first-use init. Per-request private state uses
   `ctx.setState/getState("<module>", ptr)` — one named slot per module, no
   collisions.
2. Register it: one line in `default_registry`
   (`src/dsl/registry.zig`): `@import("modules/<name>.zig").<name>,`.
3. Test collection: one line in `src/root.zig`'s comptime import block:
   `_ = @import("dsl/modules/<name>.zig");` (snapshot quirk: unimported test
   blocks silently never run).
4. Route params: add a defaulted field on `Route` (`src/dsl/router.zig`) and a
   conf directive (key-hash const + parse arm in `parseLocationDirective` +
   `LocationSpec` field + `build()` table wiring in `src/dsl/conf.zig`).
   Defaults keep every existing config compiling.
5. Directive-presence activation (nginx filter style): from the directive's
   parse arm call `ensureModuleBound(b, spec, .phase, "<name>")` instead of
   requiring users to write `<phase> <name>;`.
6. Per-request intermediate state allocates from the shared request memory —
   `ctx.sharedAlloc/sharedDupe/sharedFmt` (a bump arena the server reclaims
   wholesale when the response completes; never store its slices beyond the
   request). Cross-request module tables stay file-scope inside the module
   (see `proxy.zig` counters, `limit.zig` buckets), guarded by a mutex when
   multiple reactor threads touch them.
7. Cross-request state that must survive requests uses `dsl/shmem.zig` zones
   (`KeyedTable(V, cap)` for counters/buckets, `MmapKeyedTable` for
   mmap-backed zones that survive reload, `LruStore(n)` for byte-budgeted
   blobs) — hard ceilings by construction; at capacity, limiting fails closed
   and caching fails open. Reload-surviving zones use `ZoneRegistry`
   (`acquire`/`adopt`/`descriptors`) with memfd backing; lifecycle init in
   modules creates or inherits zones from the daemon state file.
8. `zig build test`. The registry-count test derives its count — never touch
   it.

## Known stdlib quirks (pinned 0.18.0-dev snapshot; ported from 0.16)

`src/compat.zig` shims what 0.18 removed: the `std.posix` socket layer
(socket/bind/listen/connect/close/write/writev/fcntl/open/dup/pipe/fork/
eventfd/epoll_*/clock_gettime/nanosleep/ftruncate/pread — all re-implemented
over `std.os.linux` with the old error names), `std.time.Instant` (BOOTTIME
`now()` + `since()`), `std.Thread.Mutex` (futex-backed, no-Io call shape),
`std.process.args()` (now `main(init: Init.Minimal)` + `init.args.iterate()`),
`std.StringArrayHashMap` (now unmanaged: `std.array_hash_map.String` +
per-call allocator), `std.fs.Dir/File` (fd-based helpers over
`openat`/`statx`/`getdents64`), `std.crypto.random.bytes` (getrandom),
`std.ascii.indexOfIgnoreCase`, `Mem.trimRight` (now `trimEnd`),
`X25519.KeyPair.generate()` (now needs `io:` — use `generateDeterministic` +
a getrandom seed), `Child.init`/`spawnAndWait` (now `process.spawn(io, …)` +
`child.wait(io)`), `builtin.mode == .Debug` (now lowercase `.debug`), `b.args`
in build.zig (now `run_cmd.addPassthruArgs()`), and the `[_]T{v} ** N`
array-repeat operator (removed — use `@as([N]T, @splat(v))`). `var` that is
never reassigned is now a hard error; `posix.mmap` panics on EBADF (validate
state-file fds before adopt).

Carried over (still true on 0.18):

- `sockets.acceptNonBlock` (raw `accept4`) instead of any std accept wrapper.
- `std.ArrayList` is the unmanaged `array_list.Aligned`: use `.empty`,
  `append(gpa, item)`, `deinit(gpa)`.
- `std.time.sleep` / `std.time.milliTimestamp` / `std.time.timestamp()` do not
  exist; wall seconds come from `clock_gettime(REALTIME)` (the reactor's Date
  cache).
- Network sockaddr: `posix.sockaddr` = `{ family: u16, data: [14]u8 }`;
  `sockaddr_in` layout has NO BSD `sin_len`; `sockaddr_in6` is 28 bytes with
  `scope_id: u32`. Ports/addresses must be written as raw big-endian bytes
  (`writeInt(..., .big)`, NOT `nativeToBig` + `writeInt` — that double-swaps).
  IPv6 addresses use `AF_INET6` (30) with `IPV6_V6ONLY` for dual-stack
  control.
- io_uring: `std.os.linux.IoUring` — `copy_cqes` already advances the CQ head
  (do NOT call `cq_advance` again); iovec arrays passed to readv/writev SQEs
  must outlive the op (store them in the session/connection, never the flush
  stack); CQ overflow parks completions until an `enter(GETEVENTS)` — `drain`
  must not skip that flush; ring ops on `O_NONBLOCK` fds block instead of
  EAGAIN-ing (that is the point); closing an fd does not cancel in-flight ops
  — use `cancel()` + a deferred close, and capture the fd before destroying
  the connection (use-after-free).

For std API details, consult the pinned Zig toolchain's stdlib sources.
