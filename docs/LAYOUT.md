# Zocket source layout

The project is organised so the exe entrypoint stays thin: `src/main.zig`
is CLI parsing only (flags, config resolution, daemon control); all server
logic lives in the `net/`, `http/`, `http2/`, `dsl/` and `runtime/`
submodules. `src/root.zig` is the library root — every submodule is
re-exported there, and every submodule is comptime-imported so its `test`
blocks are collected (this Zig snapshot only runs tests reachable from the
test root).

```
src/
  main.zig            CLI entry: --help, --version, --validate, --start/
                      --stop/--status (pidfile daemon), --reload-hard,
                      --port, --threads, --single, --echo, --http,
                      --idle-timeout, --uring (flags only; logic below)
  root.zig            library root; re-exports + comptime test imports
  version.zig         version constant (comptime)
  ct_pool.zig         typed comptime arena for comptime builders (M15)
  fuzz.zig            fuzz driver entry (zig build fuzz)
  fuzz_main.zig       fuzz harness setup
  testdata/           conf fixture (config.example.conf) + TLS test certs;
                      backend.json/proxy.json/stub.json are legacy JSON
                      fixtures (unused since M18.5)
  net/                transport + lifecycle (M1/M2/M5/M13/M14/M15/M16)
    server.zig        M1 single-threaded epoll echo (kept for A/B)
    multireactor.zig  SO_REUSEPORT accept + reactor lifecycle + graceful
                      stop (SIGTERM/SIGINT); no SIGHUP (comptime-only confs)
    reactor.zig       per-core epoll/io_uring thread: connection queue via
                      mutex+eventfd, HTTP/1.1 + h2c protocol detection,
                      epoll and io_uring I/O paths, static/sendfile flush
    dispatcher.zig    lock-free round-robin (M2; superseded by SO_REUSEPORT)
    timer_wheel.zig   idle-timeout timer wheel (M5)
    connection.zig    pooled connections with embedded 16 KiB buffers (M15)
    buffer.zig        growable byte buffer (memmove-safe)
    iouring.zig       io_uring batch I/O backend (opt-in, M15)
    epoll.zig         epoll wrapper (raw syscalls)
    eventfd.zig       wakeup primitive
    sockets.zig       raw socket syscall helpers
  http/               HTTP/1.1 layer (M3/M6/M8/M15)
    parser.zig        incremental request parser (DFA header classification,
                      chunked request bodies, keep-alive/pipelining)
    response.zig      response builder: Content-Length or chunked framing
                      (route opt-in), fast itoa, writev parts
    arena.zig         request bump arena: embedded 16 KiB, zero allocs (M15)
    mime.zig          comptime MIME table (M6)
    header_dfa.zig    comptime DFA for header-name classification (M15)
  http2/              HTTP/2 core (M16, h2c prior-knowledge)
    frames.zig        frame layer (all frame types, comptime decode table)
    hpack.zig         HPACK decode/encode (comptime static tables + Huffman)
    session.zig       streams, flow control, CONTINUATION, trailers, RST/
                      GOAWAY; per-connection request pool + arena
  dsl/                config pipeline (M4/M7/M9-M12/M15/M18.5)
    phase.zig         nginx-style phase enum (post_read ... log)
    router.zig        prefix/exact/regex matching + comptime trie (M7/M-D)
    registry.zig      comptime module registry + Context (module = value:
                      name, phase, run(ctx) -> Action)
    pipeline.zig      phase dispatch loop (route match -> per-phase modules)
    conf.zig          comptime-only nginx-flavored conf parser (M18.5): the
                      only config path (`-Dconfig=<file>`, `conf:<line>:<col>`
                      errors, budget check)
    vars.zig          complex values: Frag/VarId/SetVar/LogFormat + $variable
                      getters (M-B/M-C)
    regex.zig         router regex compilation (M-D, ~ / ~* to NFAs)
    limits.zig        limits defaults/directives (recv/send sizes, max_body,
                      max_headers, static cache, connection pool)
    static_cache.zig  nginx open_file_cache equivalent: fd + content cache (M15)
    modules/          echo, gzip, cache (304/Conditional-GET), access_log,
                      error_log, proxy, static, stub_status
  runtime/            config + server wiring (M4/M18.5)
    config.zig        Config: comptime struct literal (Config.default()) or
                      the conf parser (fromConfComptime/fromConfEmbedded);
                      limits + routes + validation (comptimeValidate)
    server.zig        shared Server the reactors call (pipeline Context ->
                      handleRequest -> modules -> response)
  tls/                native TLS 1.3 server (M17/M18): pem, cert (ECDSA
                      P-256/P-384), handshake (X25519, HRR, ALPN), keyschedule,
                      record, session, tickets (stateless PSK resumption)
```

Other top-level files:

```
config.example.conf  reference config: globals/limits + server/location
                     blocks (nginx-flavored)
build.zig / build.zig.zon  pinned Zig snapshot; -Dconfig= embeds a config
embeds.zig           comptime asset embedding (@embedFile wrapper, project
                     root; resolved via the `embeds` module)
docs/
  config.md          conf language reference + config how-to (grammar,
                     directives, vars, regex subset, budget, reloads)
  LAYOUT.md          this file
  milestones.md      milestone log (M1-M18.5)
  ROADMAP.md         remaining roadmap
bench/
  bench.sh / bench2.sh     bombardier + echo-client sweeps (echo protocols)
  compare-servers.sh       six-server matrix + static comparison
  h2bench.sh               HTTP/2 vs nginx (h2load)
  chunked-bench.sh         chunked transfer vs nginx (bombardier)
  graphs.py                renders bench/graphs/*.png from bench/results/
  summarize.py / summarize2.py  result tables
  http-check.py / echo-check.py  e2e correctness gates
  h2test.sh / BENCH.md / HISTORY.md  h2spec gate, methodology, history
  results/                  raw per-rep values (servers/matrix/static/h2/chunked)
  graphs/                   rendered graphs (embedded in README.md)
third_party/          pinned submodules: actix-web, bun, caddy, httpx.zig,
                      nginx (+ echo-nginx-module), nghttp2 (h2load for h2)
```
