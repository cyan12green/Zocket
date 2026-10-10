# Source layout

The project is organized so the exe entrypoint stays thin: `src/main.zig` is
CLI parsing only (flags, config resolution, daemon control); all server logic
lives in the `net/`, `http/`, `http2/`, `dsl/`, `runtime/` and `tls/`
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
  sys.zig             Linux system layer: fd/socket/process syscalls, file
                      helpers, monotonic clock, futex mutex, getrandom (raw
                      `std.os.linux` calls; std moved these behind `std.Io`)
  ct_pool.zig         typed comptime pool for comptime builders
  fuzz.zig            fuzz corpus and test drivers (zig build fuzz)
  fuzz_main.zig       fuzz harness setup
  testdata/           conf fixtures, TLS test certs, static assets
  net/                transport and connection lifecycle
    server.zig        single-threaded epoll echo server (kept for A/B)
    multireactor.zig  shared SO_REUSEPORT listener, accept dispatch,
                      reactor lifecycle, graceful stop (SIGTERM/SIGINT)
    reactor.zig       per-core epoll/io_uring thread: connection queue via
                      mutex + eventfd, HTTP/1.1 + h2c protocol detection,
                      epoll and io_uring I/O paths, static/sendfile flush
    dispatcher.zig    lock-free round-robin connection handoff
    timer_wheel.zig   idle-timeout timer wheel
    connection.zig    pooled connections with embedded 16 KiB buffers
    buffer.zig        growable byte buffer (memmove-safe)
    iouring.zig       io_uring batch I/O backend (opt-in via --uring)
    ktls.zig          kTLS crypto-info + TX/RX configuration (probe-gated)
    epoll.zig         epoll wrapper (raw syscalls)
    eventfd.zig       wakeup primitive
    sockets.zig       raw socket syscall helpers, CIDR parsing, CPU pinning
    sni.zig           TLS ClientHello SNI peek parser (stream proxy)
    stream_proxy.zig  L4 TCP stream proxy with SNI routing
    proxy_proto.zig   PROXY protocol v1/v2 header parsing
    dns.zig           DNS wire codec
    dns_resolver.zig  async TTL-respecting resolver + system nameservers
    body_storage.zig  request-body spooling (memfd-backed)
  http/               HTTP/1.1 layer
    parser.zig        incremental request parser (DFA header classification,
                      chunked request bodies, keep-alive/pipelining,
                      smuggling-vector rejection)
    response.zig      response builder: Content-Length or chunked framing
                      (route opt-in), fast itoa, writev parts
    arena.zig         request bump arena: embedded 16 KiB, zero hot-path
                      allocations
    header_dfa.zig    comptime DFA for header-name classification
    mime.zig          comptime MIME table
    websocket.zig     RFC 6455 handshake and frame codec
  http2/              HTTP/2 core (h2c prior-knowledge and ALPN h2)
    frames.zig        frame layer (all frame types, comptime decode table)
    hpack.zig         HPACK decode/encode (comptime static tables + Huffman)
    session.zig       streams, flow control, CONTINUATION, trailers, RST/
                      GOAWAY; per-connection request pool + arena
  dsl/                configuration and the phase pipeline
    phase.zig         nginx-style phase enum (post_read ... log)
    router.zig        prefix/exact/regex matching + comptime trie
    registry.zig      comptime module registry + Context (a module is a
                      value: name, phase, kind, run(ctx) -> Action)
    pipeline.zig      phase dispatch loop (route match -> per-phase modules)
    conf.zig          comptime-only nginx-flavored conf parser: the only
                      config path (-Dconfig=<file>, conf:<line>:<col>
                      errors, branch-budget check)
    vars.zig          complex values: Frag/VarId/SetVar/LogFormat and
                      $variable getters
    regex.zig         router regex compilation (~ / ~* to NFAs)
    limits.zig        limits defaults and directives (buffer sizes, body and
                      header caps, static cache, connection pool)
    static_cache.zig  open_file_cache-style fd + content cache
    shmem.zig         bounded shared-memory zones (KeyedTable, LruStore)
    memfd.zig         memfd-backed zones that survive --reload-hard
    htpasswd.zig      comptime htpasswd parsing (plaintext/{SHA}/bcrypt)
    testing.zig       module test kit (case builders, mock upstreams)
    modules/          echo, static, proxy, proxy_cache, cache, gzip,
                      gunzip, precompressed, sub_filter, accel, try_files,
                      error_page, rewrite, headers, access, realip, limit,
                      auth_basic, auth_request, auth_bundle, access_log,
                      error_log, stub_status, prometheus, mirror,
                      acme_challenge
  runtime/            config + server wiring
    config.zig        Config: comptime struct literal (Config.default()) or
                      the conf parser (fromConfComptime/fromConfEmbedded);
                      limits + routes + validation (comptimeValidate)
    server.zig        shared Server the reactors call (pipeline Context ->
                      handleRequest -> modules -> response) + ServerGroup
  tls/                native TLS 1.3 server
    pem.zig           PEM/DER loading
    cert.zig          certificate and key parsing (ECDSA P-256/P-384)
    handshake.zig     ClientHello/ServerHello, X25519, HRR, ALPN
    keyschedule.zig   TLS 1.3 key schedule
    record.zig        record layer (AEAD framing)
    session.zig       connection state machine
    conn.zig          wrapper over the supported suites/curves
    tickets.zig       stateless PSK resumption
    ocsp.zig          OCSP stapling (status_request)
    mtls.zig          client-certificate verification
    testdata.zig      certificate fixtures for tests
  acme/               ACME v2 client
    client.zig        account -> order -> challenge -> finalize -> install
    jws.zig           ES256 JWS compact sign/verify, RFC 7638 thumbprints
    der.zig           DER/PKCS#10 writer (CSR, PEM)
  cov_*.zig           per-area coverage drivers (not imported by root.zig)
```

Other top-level files:

```
config.example.conf   reference configuration (globals/limits + server and
                      location blocks)
build.zig / build.zig.zon   build graph; pinned Zig snapshot; -Dconfig=
                      embeds a config file at compile time
embeds.zig            comptime asset embedding (@embedFile wrapper,
                      resolved through the `embeds` module)
examples/             runnable, commented configurations (basics -> TLS/SNI
                      -> ACME -> full feature tours)
docs/
  config.md           configuration language reference
  LAYOUT.md           this file
  milestones.md       milestone delivery record
  ROADMAP.md          open work
bench/
  compare-servers.sh  cross-server matrix and static comparison
  modules-bench.sh    feature-level comparison vs nginx
  unified.sh          unified web/file/load-balancer suite
  h2-bench.sh         HTTP/2 over TLS vs nginx (h2load)
  bench.sh / bench2.sh  bombardier and echo-client sweeps
  graphs.py           renders bench/graphs/*.png from bench/results/
  http-check.py / echo-check.py  end-to-end correctness gates
  h2test.sh           HTTP/2 + h2spec conformance gate
  coverage.sh         zig-cov coverage report
  BENCH.md            methodology and current results
  HISTORY.md          historical per-milestone benchmark records
  results/            raw per-rep values (JSON)
  graphs/             rendered graphs (embedded in README.md)
third_party/          pinned submodules: nginx (+ echo-nginx-module),
                      actix-web, bun, caddy, httpx.zig, nghttp2
```
