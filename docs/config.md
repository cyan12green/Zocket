# Zocket configuration

The config has two sections: `routes` (the nginx-style location/phase
mapping) and `limits` (runtime-tunable sizes and caps — nginx's
`http{}`/`server{}` directive equivalents). Any `limits` field may be
omitted; the compiled defaults apply. See `config.example.json` for a
complete sample.

There are two load paths:

- **Comptime (primary, DM2)**: `zig build -Dconfig=<file>` embeds a
  project-root-relative JSON config at compile time. The DM1 validator
  parses it (invalid configs are compile errors) and `Server.comptimeInit`
  builds the route trie, dispatch specialisation, pre-serialised response
  templates and upstream sockaddrs — all in `.rodata`, no startup parsing.
- **Runtime (secondary/development)**: `--config <file.json>` parses the
  config at startup with std.json (startup trie build, SIGHUP reload
  support). Used when no `-Dconfig` was given.

## routes

An array of route blocks. Each block selects the modules bound to the
nginx-style phases for matching requests.

| field | type | default | description |
|---|---|---|---|
| `path` | string | — | URL prefix (`"prefix"`) or exact (`"exact"`) match target. Exact beats prefix; longest prefix wins. |
| `match` | `"prefix"` \| `"exact"` | `"prefix"` | Match mode. |
| `modules` | object | `{}` | Phase → module-name bindings (e.g. `{ "content": "echo" }`). Modules: `echo`, `static`, `gzip`, `cache`, `conditional_get`, `access_log`, `error_log`, `proxy`, `stub_status`. |
| `response` | object | null | Fixed response template (M11): `{ "status": 200, "body": "...", "headers": [{ "name": ..., "value": ... }], "compress": false }`. Module-less template routes are served from pre-serialised bytes. |
| `root` | string | null | Static-file root directory (with the `static` module). |
| `index` | string | null | Directory index file for `root`. |
| `autoindex` | bool | false | List directories when no index file exists. |
| `embed` | string | null | Comptime-embedded file (struct-literal configs only). |
| `max_age` | number | 0 | `Cache-Control: max-age=N` (with the `cache` module). |
| `upstreams` | array | null | Proxy backends: `[{ "host": ..., "port": N }]`. |
| `balance` | `"round_robin"` \| `"least_connections"` \| `"ip_hash"` | `"round_robin"` | Proxy load-balance strategy. |
| `max_fails` | number | 3 | Proxy passive health-check failures before the backend is marked down. |
| `fail_timeout_seconds` | number | 30 | Proxy backend recheck window after failures. |
| `chunked` | bool | false | Route opt-in for HTTP/1.1 chunked responses: the body is framed as a single chunk (`Transfer-Encoding: chunked`) instead of Content-Length — head+size, body and terminator flush as one writev, so it costs nothing extra. Enables streaming when the body size is unknown up front. Ignored over HTTP/2 (frame-based). |

## limits

Runtime-tunable sizes and caps (nginx directive equivalents in the
descriptions). All fields optional.

| field | default | description |
|---|---|---|
| `recv_buffer_size` | `16384` | Initial per-connection receive buffer size (bytes). Larger bodies grow it (up to `max_body`) and the capacity is kept. nginx: `client_body_buffer_size`. |
| `send_buffer_size` | `16384` | Initial per-connection send buffer size (bytes). nginx: `output_buffers`-ish. |
| `max_body` | `16777216` | Largest request body the server buffers; requests beyond it are rejected with 431. Also the echo module's body cap. nginx: `client_max_body_size`. |
| `max_line_bytes` | `8192` | Longest request line / header line (431). nginx: `large_client_header_buffers`. |
| `max_headers` | `32` | Maximum number of request headers (431). |
| `max_chunked_body` | `65536` | Largest chunked request body (413). nginx: `client_max_body_size`. |
| `static_cache_entries` | `16` | Static fd-cache size (per reactor). nginx: `open_file_cache max=N`. |
| `static_cache_valid_seconds` | `1` | Static cache revalidation window: entries are rechecked against the file's size/mtime after this many seconds. nginx: `open_file_cache_valid`. |
| `static_content_cache_max` | `16384` | Files at most this large are content-cached and served as one `writev` (head + bytes, no sendfile); larger files use sendfile. nginx: `sendfile_max_chunk`-ish. |
| `connection_pool_max` | `1024` | Recycled connections held by the per-reactor pool (bounded memory for keep-alive churn). |

## Example

```json
{
  "limits": {
    "max_body": 1048576,
    "max_headers": 64,
    "static_cache_valid_seconds": 60
  },
  "routes": [
    {
      "path": "/",
      "match": "prefix",
      "modules": { "content": "static" },
      "root": "/var/www"
    }
  ]
}
```

Startup:
- Comptime: `zig build -Dconfig=config.json run` (primary path, DM2).
- Runtime: `zig build run -- --config config.json` (secondary path).

## Daemon control and reloads

`--start`/`--stop`/`--status`/`--reload-*` turn the server into a daemon
with config reloads. The daemon records everything needed to reproduce its
build+start in a state file written next to the pidfile: `<pidfile>.state`
(JSON: `config_path`, `optimize`, `port`, `threads`, `mode`, `idle_timeout`,
`uring`, `single`, `embedded`, `project_root`). `--pidfile` defaults to
`/tmp/zocket.pid`.

Example lifecycle:

```sh
zocket --start --config config.example.json --port 8080 --threads 4 \
        --pidfile /tmp/zocket.pid     # daemonize; exit 0 once listening
zocket --status --pidfile /tmp/zocket.pid
# ...edit the config...
zocket --reload-soft --pidfile /tmp/zocket.pid   # fast in-process reparse
# ...or for a full compile-time reload...
zocket --reload-hard --pidfile /tmp/zocket.pid   # rebuild + zero-downtime swap
zocket --stop --pidfile /tmp/zocket.pid          # graceful drain + exit
```

- `zocket --start [options]` — daemonize (fork + detach, stdio to
  /dev/null), bind, write pidfile + state, then exit 0 only after the
  listeners are ready.
- `zocket --stop` — SIGTERM with a graceful drain: the daemon stops
  accepting, closes its SO_REUSEPORT listeners and finishes existing
  connections (30 s cap) before exiting.
- `zocket --status` — running / not running (stale pidfile detection).
- `zocket --reload-soft` — **runtime reload**: sends SIGHUP; the daemon
  re-parses its `--config` in-process (no rebuild, no restart). Only
  applies when the daemon runs a runtime config — an embedded config is
  immutable at runtime (use `--reload-hard`).
- `zocket --reload-hard [--config <file>]` — **comptime reload**: rebuilds
  the binary with the config embedded at compile time, then swaps:
  1. `zig build -Doptimize=<recorded> -Dconfig=<config>` in the recorded
     project root (`zig` from PATH). The DM1 validator runs at compile time:
     **an invalid config is a compile error and aborts the reload — the old
     daemon keeps serving untouched** (module names are checked when the new
     daemon starts; the old daemon is still untouched either way).
  2. The freshly built `zig-out/bin/zocket --start` is exec'd with the
     recorded options — both daemons bind the port via SO_REUSEPORT, so
     there is no acceptance gap (verified: 2M requests across a swap, 0
     errors).
  3. The old daemon gets SIGTERM and drains: it stops accepting, closes its
     listeners (so every new connection goes to the new daemon), serves any
     connections already in its accept backlog, and finishes its in-flight
     requests before exiting. The only loss window is the µs between the
     drain request and the listener close (a connection whose SYN lands
     exactly there is reset — the same instant nginx's reload has).
  4. The pid/state files are only removed by a daemon that still owns them:
     the old daemon checks the pidfile before cleaning up, so it cannot
     delete the new daemon's files (the reload-hard cleanup race, covered
     by a test).
  `--config` overrides the recorded path. Config paths must resolve inside
  the project tree — the comptime embed (`@embedFile`) cannot reach outside
  it (dot-directories like `.zig-cache` are excluded too).

SIGHUP alone (e.g. `kill -HUP <pid>`) still performs the fast runtime
reparse, identical to `--reload-soft`.

For the other run modes see the README.

## TLS (M18)

The `src/tls/` module provides a native Zig TLS 1.3 server (no OpenSSL):
ECDSA P-256/P-384 certificates (RSA unsupported — `std.crypto` has none),
X25519 ECDHE, AES-128-GCM-SHA256 / ChaCha20-Poly1305-SHA256 /
AES-256-GCM-SHA384, ALPN (`h2` / `http/1.1`), HelloRetryRequest, in-place
record decryption, and stateless session tickets (PSK resumption). Verified
against `std.crypto.tls.Client`, `openssl s_client` (handshake, encrypted
round trip, close_notify) and `openssl s_client -sess_in` (resumption
reports `Reused, TLSv1.3`).

Enable HTTPS with the `tls` config section:

```json
{
  "tls": { "cert": "path/to/cert.pem", "key": "path/to/key.pem" },
  "routes": [ ... ]
}
```

- The cert must be ECDSA (P-256 or P-384); the key must be the matching
  SEC1 EC private key (PKCS#8 also accepted).
- A connection is classified on its first record: TLS ClientHello, the
  HTTP/2 prior-knowledge preface, or HTTP/1.1. ALPN picks `h2` vs
  `http/1.1` inside TLS; no ALPN means HTTP/1.1.
- `--validate` prints `tls: enabled/disabled`; without the section the
  server stays plaintext.
