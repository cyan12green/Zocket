# Zocket configuration

Zocket uses an nginx-conf-flavored configuration language (`.conf` files),
compiled **entirely at compile time**: the config is embedded with
`zig build -Dconfig=<file>` and parsed/validated by the comptime conf
parser in `src/dsl/conf.zig`. The built route table, trie, dispatch
functions, pre-serialised response templates and upstream sockaddrs all
live in `.rodata`. **There is no runtime config path** — an invalid config
is a compile error, and `--reload-hard` (rebuild + SO_REUSEPORT swap) is
the only reload. See `config.example.conf` for a complete sample and
`docs/conf.md` for the full language reference (grammar, directive table,
variable catalog, regex subset).

## Language shape (summary)

```
# comments
<global directive>;                    # limits, listen, tls, log_format
tls { cert "file.pem"; key "file.pem"; }
server {
    location [modifier] <target> {     # modifier: = | ~ | ~* | ^~ | (none)
        <phase> <module>;              # content echo; log access_log; ...
        <location directive>;          # root, index, return, add_header, ...
    }
}
```

Sizes accept `k`/`m`/`g` suffixes (`16m` = 16 MiB); booleans accept
`on|off`; values are bare tokens or quoted strings (`"..."` with `\" \\ \n
\r \t` escapes, `'...'` literal).

## Global directives

All `limits` fields become directives with the same name (sizes accept the
`k/m/g` suffix, booleans `on|off`); also accepted inside `server {}`:

| Directive | Field | Notes |
|---|---|---|
| `recv_buffer_size <size>;` | `recv_buffer_size` | nginx `client_body_buffer_size` |
| `send_buffer_size <size>;` | `send_buffer_size` | |
| `max_body <size>;` | `max_body` | nginx `client_max_body_size` (431 over) |
| `max_line_bytes <size>;` | `max_line_bytes` | nginx `large_client_header_buffers` |
| `max_headers <n>;` | `max_headers` | |
| `max_chunked_body <size>;` | `max_chunked_body` | (413 over) |
| `static_cache_entries <n>;` | `static_cache_entries` | nginx `open_file_cache max=N` |
| `static_cache_valid <n>;` | `static_cache_valid_seconds` | nginx `open_file_cache_valid` |
| `static_content_cache_max <size>;` | `static_content_cache_max` | |
| `connection_pool_max <n>;` | `connection_pool_max` | |
| `listen <port>;` | `Config.listen_port` | CLI `--port` wins when both |
| `tls { cert "<path>"; key "<path>"; }` | `TlsConfig` | |
| `log_format <name> "<cv>";` | `Config.log_formats` | duplicate names → compile error |

Unknown directives → `@compileError` with `conf:<line>:<col>`.

## `server {}` and `location` blocks

Exactly one `server {}` is required (vhosts are a future milestone).
Locations select routes by modifier: `=` exact, `~` regex (case-sensitive),
`~*` regex (case-insensitive), `^~` prefix that wins over regex, or plain
prefix. nginx precedence: exact → `^~` prefix → first regex in declaration
order → longest plain prefix → 404.

Location directives (all optional):

| Directive | Effect |
|---|---|
| `<phase> <module>;` | Bind a module to a phase (`post_read, server_rewrite, find_config, rewrite, post_rewrite, preaccess, access, post_access, content, log`). Unknown module names are compile errors. |
| `root <path>;` / `index <file>;` / `autoindex on\|off;` | Static-file serving (with the `static` module). |
| `embed <path>;` | Comptime-embedded file (project-root-relative). |
| `max_age <n>;` | `Cache-Control: max-age=N`. |
| `chunked on\|off;` | HTTP/1.1 single-chunk responses. |
| `return <code> ["<cv>"];` | Fixed-response template (module-less routes are served from pre-serialised bytes). |
| `add_header <name> "<cv>";` | Append a response header to a `return` template. |
| `set $name "<cv>";` | User variable (M-C). |
| `proxy_pass <host>:<port>;` / `upstream <host>:<port>;` | Proxy backends (IPv4 literals only). |
| `balance <round_robin\|least_connections\|ip_hash>;` | Load-balance strategy. |
| `max_fails <n>;` / `fail_timeout <n>;` | Passive health checks. |
| `proxy_set_header <name> "<cv>";` | Upstream header overrides (M-E). |
| `access_log <format-name>\|off;` | Select a named `log_format` for the log phase. |

## Example

```
max_body 1m;
max_headers 64;
static_cache_valid 60;

tls {
    cert "server.pem";
    key "server.key";
}

server {
    location / {
        content static;
        root /var/www;
    }

    location = /health {
        return 200 "ok";
    }
}
```

Startup: `zig build -Dconfig=config.conf run` (the only path).

## Daemon control and reloads

`--start`/`--stop`/`--status`/`--reload-hard` turn the server into a
daemon. The daemon records everything needed to reproduce its build+start in
a state file next to the pidfile: `<pidfile>.state` (JSON: `config_path`,
`optimize`, `port`, `threads`, `mode`, `idle_timeout`, `uring`, `single`,
`embedded`, `project_root`). `--pidfile` defaults to `/tmp/zocket.pid`.

Example lifecycle:

```sh
zocket --start --port 8080 --threads 4 \
        --pidfile /tmp/zocket.pid     # daemonize; exit 0 once listening
zocket --status --pidfile /tmp/zocket.pid
# ...edit the conf...
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
- `zocket --reload-hard` — **comptime reload** (the only reload): rebuilds
  the binary with the conf embedded at compile time, then swaps:
  1. `zig build -Doptimize=<recorded> -Dconfig=<conf>` in the recorded
     project root (`zig` from PATH). The comptime conf parser validates at
     compile time: **an invalid config is a compile error and aborts the
     reload — the old daemon keeps serving untouched**.
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
  Conf paths must resolve inside the project tree — the comptime embed
  (`@embedFile`) cannot reach outside it (dot-directories like `.zig-cache`
  are excluded too).

SIGHUP is deliberately not handled (configs are comptime-only).

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

Enable HTTPS with the `tls` block:

```
tls {
    cert "path/to/cert.pem";
    key "path/to/key.pem";
}
```

- The cert must be ECDSA (P-256 or P-384); the key must be the matching
  SEC1 EC private key (PKCS#8 also accepted).
- A connection is classified on its first record: TLS ClientHello, the
  HTTP/2 prior-knowledge preface, or HTTP/1.1. ALPN picks `h2` vs
  `http/1.1` inside TLS; no ALPN means HTTP/1.1.
- `--validate` prints `tls: enabled/disabled`; without the block the
  server stays plaintext.

## Comptime branch budget

The comptime branch quota is shared per compilation (config parse, regex
compile, trie build, dispatch assignment, the h2/tls comptime tables).
`Config.comptimeValidate` measures the config's compile cost (routes × 32 +
fragments × 4 + source length + ...) and raises a clear compile error when
it exceeds ~66% of the budget (safety factor 1.5):

```
conf '<embedded>': config compile cost ~N exceeds the comptime branch budget
(<quota>, safety factor 1.5). Reduce the config (routes/regex/length) or
raise the budget: zig build -Dconfig_branch_quota=<n>
```
