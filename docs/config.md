# Zocket configuration

Zocket is configured with an nginx-conf-flavored language (`.conf` files),
compiled **entirely at compile time**: the file is embedded with
`zig build -Dconfig=<file>` and parsed/validated by the comptime parser in
`src/dsl/conf.zig`. The built route table, matching trie, per-route dispatch
specialisation, pre-serialised response templates and upstream sockaddrs all
live in `.rodata` — there is no runtime config parse, no config file reading
at startup.

Consequences of the comptime design:

- An invalid configuration is a **compile error** (`conf:<line>:<col>: ...`),
  never a runtime failure.
- The **only** reload is `--reload-hard`: it rebuilds the binary with the
  conf embedded and zero-downtime swaps the daemon. SIGHUP is deliberately
  not handled.
- `--validate` prints the route table; configs are validated at build time.
- Comptime embeds (`@embedFile`) can only reach files inside the project
  tree (no dot-directories), so conf files — and any `embed` targets — must
  live in the repo.

This file is the full reference: language grammar, every directive, the
variable catalog, location matching, the regex subset, the comptime budget,
and the operation how-tos. `config.example.conf` is a complete working
sample.

## Building and running

```sh
zig build -Dconfig=config.example.conf run                 # build + run, port 8080
zig build -Dconfig=config.example.conf run -- --port 9000  # override the conf's listen
zig build -Dconfig=config.example.conf run -- --threads 4  # physical-core count is best
zig build -Dconfig=config.example.conf -Doptimize=ReleaseFast  # benchmarking
zig build -Dconfig=config.example.conf run -- --start --pidfile /tmp/zocket.pid  # daemonize
zig build -Dconfig=config.example.conf run -- --validate   # print the route table
```

With no `-Dconfig`, the server runs the comptime default: a catch-all prefix
route binding `echo` to the `content` phase (the pre-pipeline hardcoded behavior).

## Language grammar

```
conf     := stmt* EOF
stmt     := directive ';' | block
block    := NAME ARG* '{' stmt* '}'
directive:= NAME ARG* ';'
ARG      := quoted | token | size | number
quoted   := '"' ( any char except '"', with \ escapes: \" \\ \n \r \t ) '"'
           | "'" ( any char except "'" ) "'"
token    := one or more of [A-Za-z0-9_./:$@#!?=+\-%]
size     := number followed by suffix k|K|m|M|g|G  (1024-multipliers)
number   := [0-9]+
comment  := '#' to end of line (outside quoted strings)
```

- Tokens are separated by whitespace; `;`, `{`, `}` terminate
  directives/blocks. Unquoted tokens never contain whitespace.
- Booleans accept `on` / `off`. Values are bare tokens or quoted strings
  (`"..."` with `\" \\ \n \r \t` escapes, `'...'` literal).
- Errors carry `conf:<line>:<col>: <message>`.

The structure is **flat**: top-level directives plus exactly one `server {}`
block (vhosts are future work) holding `location {}` blocks. There is
no `http {}` section.

## Directives

- [access_log](#access_log)
- [add_header](#add_header)
- [autoindex](#autoindex)
- [balance](#balance)
- [chunked](#chunked)
- [connection_pool_max](#connection_pool_max)
- [embed](#embed)
- [fail_timeout](#fail_timeout)
- [index](#index)
- [listen](#listen)
- [location](#location)
- [log_format](#log_format)
- [max_age](#max_age)
- [max_body](#max_body)
- [max_chunked_body](#max_chunked_body)
- [max_fails](#max_fails)
- [max_headers](#max_headers)
- [max_line_bytes](#max_line_bytes)
- [phase module](#phase-module)
- [proxy_pass](#proxy_pass)
- [proxy_set_header](#proxy_set_header)
- [recv_buffer_size](#recv_buffer_size)
- [return](#return)
- [root](#root)
- [send_buffer_size](#send_buffer_size)
- [server](#server)
- [set](#set)
- [static_cache_entries](#static_cache_entries)
- [static_cache_valid](#static_cache_valid)
- [static_content_cache_max](#static_content_cache_max)
- [tls](#tls)
- [upstream](#upstream)

### access_log

Syntax: `access_log format-name | off;`

Default: combined

Context: location

Selects a named `log_format` (see the [log_format](#log_format) directive)
for the `log` phase; the value `off` disables logging for the location. When
a location binds `log access_log;` but declares no `access_log` directive,
the default nginx `combined` format is used:

```
$ip - - [$date] "$request" $status $bytes "$referer" "$user_agent"
```

An unknown format name is a compile error (`access_log: unknown log format
'...'`).

### add_header

Syntax: `add_header name value;`

Default: —

Context: location

Appends a response header to the route's `return` template. The value is a
[complex value](#embedded-variables) (variables allowed). Headers are emitted
in declaration order; the whole template is pre-serialised at compile time
when every value is literal, or rendered per request when any value contains
a variable.

### autoindex

Syntax: `autoindex on | off;`

Default: `autoindex off;`

Context: location

With the `static` module: when a request targets a directory and the
configured `index` file is absent (or no `index` is configured), serve a
generated directory listing instead of 404.

### balance

Syntax: `balance round_robin | least_connections | ip_hash;`

Default: `balance round_robin;`

Context: location

Load-balance strategy the `proxy` module applies across the location's
upstream backends.

### chunked

Syntax: `chunked on | off;`

Default: `chunked off;`

Context: location

Route opt-in for HTTP/1.1 chunked transfer encoding: the response is framed
with `Transfer-Encoding: chunked` instead of Content-Length. Content-Length
lets the response flush as a single writev, so leave off unless the body
size is not known in advance or streaming semantics are wanted. Ignored by
HTTP/2 (which frames responses itself).

### connection_pool_max

Syntax: `connection_pool_max number;`

Default: `connection_pool_max 1024;`

Context: main, server

Maximum recycled connections held by each reactor's pool.

### embed

Syntax: `embed path;`

Default: —

Context: location

Comptime-embedded static file (project-root-relative; the `static` module
serves it from `.rodata`). An invalid path is a compile error. Because the
bytes cannot change, the embedded file is served with an effectively
infinite cache lifetime.

### fail_timeout

Syntax: `fail_timeout number;`

Default: `fail_timeout 30;`

Context: location

Seconds a backend stays marked down after `max_fails` consecutive
connect/read failures (passive health check used by the `proxy` module).

### index

Syntax: `index file;`

Default: —

Context: location

Directory index file for the `static` module (e.g. `index index.html;`).

### listen

Syntax: `listen port;`

Default: `listen 8080;`

Context: main, server

Listen port. Absent = the CLI `--port` default (8080); when both are given
the CLI `--port` flag wins over the conf directive.

### location

Syntax: `location [ = | ~ | ~* | ^~ ] uri { ... }`

Default: —

Context: server

Declares a route. The modifier selects the matching rule (see [Location
matching](#location-matching) for precedence):

| Modifier | Meaning | Match |
|---|---|---|
| (none) | prefix — longest match wins | `prefix` |
| `=` | exact | `exact` |
| `~` | regular expression, case-sensitive | `regex` |
| `~*` | regular expression, case-insensitive | `regex_ci` |
| `^~` | prefix that wins over regex | `prefix` + no-regex |

The body holds [phase bindings](#phase-module) and location directives:
[autoindex](#autoindex), [balance](#balance), [chunked](#chunked),
[embed](#embed), [fail_timeout](#fail_timeout), [index](#index),
[max_age](#max_age), [max_fails](#max_fails), [proxy_pass](#proxy_pass),
[proxy_set_header](#proxy_set_header), [return](#return), [root](#root),
[set](#set), [upstream](#upstream), [access_log](#access_log),
[add_header](#add_header). Unknown directives are compile errors.

### log_format

Syntax: `log_format name value;`

Default: `combined` (`$ip - - [$date] "$request" $status $bytes "$referer" "$user_agent"`)

Context: main, server

Defines a named log format; `value` is a [complex value](#embedded-variables)
compiled once at comptime into a fragment list (no per-request string
scanning). A route selects one with [access_log](#access_log). Up to 16 named
formats may be declared (a 17th is a compile error). The first declared
format fills index 0; the `combined` default is used when no `access_log`
directive is present.

### max_age

Syntax: `max_age number;`

Default: `max_age 0;`

Context: location

Default cache lifetime in seconds; the `cache_headers` module
(`post_access` phase) emits `Cache-Control: max-age=N` from it. 0 = no-cache.

### max_body

Syntax: `max_body size;`

Default: `max_body 16m;`

Context: main, server

Largest request body the server buffers — the receive-buffer growth cap.
Requests beyond it are rejected with **431** (the `echo` module's ceiling is
this value). nginx equivalent: `client_max_body_size`. Chunked request bodies
are capped separately by [max_chunked_body](#max_chunked_body).

### max_chunked_body

Syntax: `max_chunked_body size;`

Default: `max_chunked_body 64k;`

Context: main, server

Largest chunked request body; requests beyond it are rejected with **413**.
nginx equivalent: `client_max_body_size`.

### max_fails

Syntax: `max_fails number;`

Default: `max_fails 3;`

Context: location

Consecutive connect/read failures after which a backend is marked down for
`fail_timeout` seconds (passive health check, `proxy` module).

### max_headers

Syntax: `max_headers number;`

Default: `max_headers 32;`

Context: main, server

Maximum number of request headers; over it the request is rejected with
**431**.

### max_line_bytes

Syntax: `max_line_bytes size;`

Default: `max_line_bytes 8k;`

Context: main, server

Longest request line or header line; longer lines are rejected with **431**.
nginx equivalent: `large_client_header_buffers`.

### phase module

Syntax: `<phase> <module>;`

Default: —

Context: location

Binds a module to a phase. Multiple modules may be bound to the same phase
(nesting is allowed): they form a chain run in config declaration order
(nginx-style). A module that `pass`es lets the next module in the same phase
run; a module that handles the request (or short-circuits) stops the chain.
The `log` phase is post-processing — every log-bound module runs in order
regardless of the walk's outcome. Unknown module names are compile errors.
The pipeline walks the phases in order; `find_config` runs the route matcher
up front so every phase can carry route-scoped modules.

The 10 phases, in execution order (nginx request-processing stages):

| Phase | Notes |
|---|---|
| `post_read` | before any config is matched |
| `server_rewrite` | |
| `find_config` | runs the route matcher; route is set here |
| `rewrite` | e.g. `proxy` |
| `post_rewrite` | |
| `preaccess` | e.g. `conditional_get` |
| `access` | |
| `post_access` | e.g. `cache_headers` |
| `content` | e.g. `echo`, `static`, `stub_status` |
| `log` | runs as post-processing after the walk (gzip transforms, access/error logs) |

Registered modules:

| Module | Phase | What it does |
|---|---|---|
| `echo` | content | 200 OK echoing the request body; bodies over `max_body` get 413 + close |
| `static` | content | serves files from `root` (openat2-contained), embedded files, directory `index`/`autoindex`, fd + content cache, sendfile for large files |
| `stub_status` | content | shared server counters page |
| `proxy` | rewrite | reverse proxy to the route's upstreams; load-balancing, passive health checks, keep-alive pool |
| `conditional_get` | preaccess | If-Modified-Since / If-None-Match → 304 |
| `cache_headers` | post_access | emits `Cache-Control: max-age=N` from `max_age` (and ETag / Last-Modified) |
| `gzip` | log | compresses the final body when the client sent `Accept-Encoding: gzip` and it shrinks (min 20 bytes) |
| `access_log` | log | writes an access line per request (named `log_format` or `combined`) |
| `error_log` | log | error logging |
| `headers` | log | applies the route's `set_header` / `add_header` / `remove_header` ops to the final header set (auto-bound when any is declared) |
| `auth_basic` | access | Basic auth against a comptime-embedded htpasswd table; 401 + challenge on failure |
| `auth_request` | access | forwards `auth_request <uri>` through an internal subrequest; 2xx admits, failures copy status |
| `limit_req` | access | leaky-bucket rate limit per client key (`limit_req rate=N burst=M`), excess → 503 |
| `limit_conn` | access | per-key in-flight cap (`limit_conn N`) |
| `limit_conn_release` | log | releases the limit_conn slot for this request (auto-bound pair) |
| `precompressed` | content | serves `.gz` siblings with Content-Encoding when the client accepts gzip |
| `proxy_cache` | rewrite | response cache lookup: HIT / STALE within grace, conditional revalidation on expiry |
| `proxy_cache_store` | log | stores origin 200s; converts upstream 304 back to the stored 200 |

### auth_basic

Syntax: `auth_basic "<realm>";`

Default: —

Context: location

Enables HTTP Basic authentication for the location. Pairs with
[auth_basic_user_file](#auth_basic_user_file); either directive binds the
module. Failures answer 401 with a `WWW-Authenticate` challenge and stop
the chain before content runs.

### auth_basic_user_file

Syntax: `auth_basic_user_file <path>;`

Default: —

Context: location

Path (root-relative, embedded at comptime like [embed](#embed)) of an
htpasswd file: `user:secret` lines, `#` comments. Secret formats:
plaintext, `{SHA}base64(sha1)` and bcrypt (`$2a$`/`$2b$`/`$2y$`). A missing
file is a compile error.

### auth_request

Syntax: `auth_request <uri>;`

Default: —

Context: location

Runs `<uri>` as an internal subrequest (full pipeline, Authorization
header inherited). A 2xx verdict admits the request; anything else is
copied as the client-facing status. Nested auth_request locations answer
500 instead of recursing.

### balance (extended)

`balance random|consistent_hash|least_time` join round_robin /
least_connections / ip_hash: random picks uniformly among usable
backends; consistent_hash maps the client IP deterministically to one
backend while it stays usable; least_time prefers the lowest EWMA of
upstream latency.

### client_body_timeout

Syntax: `client_body_timeout <seconds>;`

Default: `30`

Context: main

Inactivity gap tolerated between request-body bytes. 0 leaves the idle
timeout as the only guard.

### client_header_timeout

Syntax: `client_header_timeout <seconds>;`

Default: `10`

Context: main

TOTAL wall time allowed for the request line + headers from first byte,
regardless of activity (anti-slowloris). 0 disables.

### health_check

Syntax: `health_check path=<uri> [interval=<s>] [rise=<n>] [fall=<n>]
[timeout=<s>]`

Default: —

Context: location (proxy routes)

Active probing of every upstream on the route by a background checker:
TCP connect, plus a HEAD `<path>` request when `path` is set (2xx/3xx
counts as healthy). A backend goes down after `fall` failed probes
(passive request failures also trip it) and returns after `rise`
successes — visible to all reactors through shared memory. Defaults:
interval 5 s, rise 2, fall 3, timeout 1 s.

### limit_conn

Syntax: `limit_conn <n>;`

Default: —

Context: location

Max simultaneous in-flight requests per client key; excess answers 503.
Binds `limit_conn` + its release half automatically.

### limit_req

Syntax: `limit_req rate=<r> burst=<b>;`

Default: —

Context: location

Leaky bucket per client key: sustained `r` requests/second with room for
`b` burst (defaults to `rate`). Fresh keys start with a full bucket.
Excess answers 503.

### precompressed

Syntax: `precompressed gz;`

Default: —

Context: location

Serve a `.gz` sibling file (same path + `.gz`) with
`Content-Encoding: gzip` when the client accepts it; otherwise falls
through to the next module.

### proxy_cache

Syntax: `proxy_cache on|off;`

Default: `off`

Context: location

Response caching for proxied routes. Binds the lookup + store halves.
Place before `rewrite proxy;`. Fresh entries serve as HIT; expired ones
revalidate conditionally via If-None-Match; see also
[proxy_cache_valid](#proxy_cache_valid).

### proxy_cache_stale_while_revalidate

Syntax: `proxy_cache_stale_while_revalidate <seconds>;`

Default: `0`

Context: location

Grace past expiry during which the stale representation is served
immediately (`X-Cache: STALE`).

### proxy_cache_valid

Syntax: `proxy_cache_valid <seconds>;`

Default: `60`

Context: location

Fresh window of cached responses.

Zone sizing (runtime knobs, `limits` section): `proxy_cache_max_bytes`
(default 32 MiB) and `proxy_cache_max_entries` (default 256) bound the
cache; changing either recreates the zone on startup.

### set_header / remove_header

Syntax: `set_header <name> "<value>";` / `remove_header <name>;`

Default: —

Context: location, server

Response-header manipulation applied by the auto-bound `headers` module:
`add_header` appends (or decorates fixed-response templates), `set_header`
replaces-or-appends, `remove_header` drops every header of that name.
`add_header`/`set_header` accept nginx's trailing `always` flag; without
it they apply only to 200/201/204/206/301/302/303/304/307/308.
Server-scope declarations are inherited by locations that declare none.

### sticky_cookie

Syntax: `sticky_cookie <name>;`

Default: —

Context: location (proxy routes)

Cookie-based backend affinity: clients presenting `<name>=s<idx>` are
pinned to that backend while usable; new clients receive
`Set-Cookie: <name>=s<pick>; Path=/`.

### proxy_pass

Syntax: `proxy_pass host:port;`

Default: —

Context: location

Adds a single upstream backend for the `proxy` module — sugar for
[upstream](#upstream). The host must be an IPv4 literal; any other value is a
compile error (sockaddrs are pre-computed at comptime — no DNS).

### proxy_set_header

Syntax: `proxy_set_header name value;`

Default: —

Context: location

Overrides one request header sent to the upstream. The value is a [complex
value](#embedded-variables) resolved against the location's `set` scope.

### recv_buffer_size

Syntax: `recv_buffer_size size;`

Default: `recv_buffer_size 16k;`

Context: main, server

Initial per-connection receive buffer size. nginx equivalent:
`client_body_buffer_size`.

### return

Syntax: `return code [value];`

Default: —

Context: location

Fixed-response template served from pre-serialised bytes — module-less
routes (redirects, health checks, error pages) skip the pipeline entirely.
`value` is a [complex value](#embedded-variables): when any fragment is a
variable the route uses the dynamic renderer instead, and [add_header](#add_header)
headers apply. `return 301 "";` together with `add_header Location "/...";` is
the idiomatic redirect (see the example below).

### root

Syntax: `root path;`

Default: —

Context: location

Root directory for the `static` module. Targets are resolved against it with
openat2(`RESOLVE_BENEATH`), giving kernel-enforced containment.

### send_buffer_size

Syntax: `send_buffer_size size;`

Default: `send_buffer_size 16k;`

Context: main, server

Initial per-connection send buffer size.

### server

Syntax: `server { ... }`

Default: —

Context: main

The server block. Exactly one is required (a missing or a second one is a
compile error; vhosts are a future milestone). Contents: any global directive
(merged) plus [location](#location) blocks.

### set

Syntax: `set $name value;`

Default: —

Context: location

Declares a user variable scoped to the location. The name must be
`[A-Za-z_][A-Za-z0-9_]*`; `$1..$9` and `$$` are reserved. Duplicate names in
the same location, forward references (before the `set`), and more than 8
variables per location are compile errors. The value is a [complex
value](#embedded-variables) and may reference variables declared before it;
references render lazily into the request arena and are cached per request.

### static_cache_entries

Syntax: `static_cache_entries number;`

Default: `static_cache_entries 16;`

Context: main, server

Static fd-cache size. nginx equivalent: `open_file_cache max=N`.

### static_cache_valid

Syntax: `static_cache_valid number;`

Default: `static_cache_valid 1;`

Context: main, server

Static-cache revalidation window in seconds. nginx equivalent:
`open_file_cache_valid`.

### static_content_cache_max

Syntax: `static_content_cache_max size;`

Default: `static_content_cache_max 16k;`

Context: main, server

Files at most this large are content-cached and served as a single writev;
larger files go through sendfile. nginx equivalent: `sendfile_max_chunk`-ish.

### tls

Syntax: `tls { cert file; key file; }`

Default: —

Context: main, server

Enables HTTPS via the native Zig TLS 1.3 server (`src/tls/`, no OpenSSL).
Without the block the server stays plaintext; a connection is classified on
its first record (TLS ClientHello / HTTP/2 prior-knowledge preface /
HTTP/1.1), and ALPN picks `h2` vs `http/1.1` inside TLS.

- The certificate must be ECDSA (P-256 or P-384) — RSA is unsupported — and
  the key the matching SEC1 EC private key (PKCS#8 accepted).
- Only one `tls` block is allowed; `cert` and `key` are each single-valued.
- `--validate` prints `tls: enabled/disabled`.

### upstream

Syntax: `upstream host:port;`

Default: —

Context: location

Appends an upstream backend for the `proxy` module. The host must be an IPv4
literal (compile error otherwise). Multiple `upstream` directives build the
backend list. A single backend can be written more concisely with
[proxy_pass](#proxy_pass). Note: the `proxy` module tracks at most 8 backends
per route — a route declaring more is silently skipped by the module (the
location yields 404), so keep backend lists within 8.

## Embedded variables

Any value of a variable-capable directive (`log_format`, `return`,
`add_header`, `set`, `proxy_set_header`) is a **complex value**: a compiled
list of fragments built once at compile time and rendered per request by a
comptime-switched getter loop — zero string scanning at runtime.

Syntax: `$name` (variable reference), `$$` (literal `$`), `${name}` (braced
name, allows `-` etc.).

Built-in variables:

| Variable | Value |
|---|---|
| `$method` | request method (GET/HEAD/POST/PUT/DELETE/OPTIONS/PATCH; `?` when unknown) |
| `$request_uri` | raw request target incl. query string |
| `$uri` | decoded request target |
| `$args` / `$query_string` | query string incl. the leading `?` |
| `$host` | `Host` header (`""` when absent) |
| `$status` | response status code |
| `$body_bytes_sent` / `$bytes` | response body length |
| `$remote_addr` / `$ip` | client IPv4 (`-` when unknown) |
| `$remote_port` | `-` (not tracked yet) |
| `$server_protocol` | `HTTP/1.1` etc. |
| `$scheme` | `http` (TLS later) |
| `$request_time` | seconds since request start |
| `$content_length` | request Content-Length |
| `$content_type` | request Content-Type |
| `$date` / `$time_local` | combined-log date (`02/Jan/2006:15:04:05 +0000`) |
| `$time_iso8601` | ISO-8601 timestamp (`2026-08-16T18:00:00+00:00`) |
| `$request` | `METHOD target HTTP/1.1` |
| `$referer` | `Referer` header (`-` when absent) |
| `$user_agent` | `User-Agent` header (`-` when absent) |

Generic variables:

| Variable | Value |
|---|---|
| `$http_<name>` | request header; `_`→`-` (e.g. `$http_user_agent` → `user-agent`), case-insensitive hash match |
| `$arg_<name>` | query parameter (verbatim, case-sensitive) |
| `$cookie_<name>` | cookie (lowercased) |
| `$1..$9` | regex capture groups — valid inside regex-matched locations; `""` when no capture |

Name resolution order: `$1..$9` capture → `http_*` header → `arg_*` query →
`cookie_*` cookie → declared `set` variable in scope → built-in → otherwise a
compile error (`unknown variable '$...'`).

## Location matching

nginx precedence:

1. Exact (`=`) match wins immediately.
2. Longest `^~`-flagged prefix wins immediately (regex skipped).
3. First regex (`~`/`~*`) match in **declaration order** wins immediately
   (captures recorded into `$1..$9`).
4. Otherwise the longest plain prefix wins; else 404 (`not_handled`).

## Regular expressions

The regex subset supported by `location ~` / `~*` (comptime-compiled into a
Thompson NFA, `src/dsl/regex.zig`):

- Literals (escaped metachars: `\. \/ \\ \* \+ \? \( \) \[ \] \{ \} \| \^ \$`).
- `.` matches any byte except `\n`.
- Classes `[...]` and `[^...]` with ranges (`a-z`), escapes
  (`\d \w \s \D \W \S` and escaped metachars); literal `]` as first member.
- `\d` `[0-9]`, `\w` `[A-Za-z0-9_]`, `\s` `[ \t\r\n]`, `\D \W \S` complements.
- Quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` (greedy only).
- Groups `(...)` (capturing) and `(?:...)` (non-capturing).
- Alternation `|`.
- Anchors `^` (start) and `$` (end).

No backreferences, no lookaround, no lazy/possessive modifiers, no `\b`, no
named groups. Malformed patterns are compile errors carrying the pattern
text.

## Comptime branch budget

The config parse, regex compilation, trie build and dispatch assignment share
the per-compilation comptime branch quota (default 100000,
`-Dconfig_branch_quota=<n>`). The validate step measures the config's compile
cost and fails with a clear error before the quota is exhausted (safety
factor 1.5 — it triggers at ~66% of the quota):

```
conf '<embedded>': config compile cost ~N exceeds the comptime branch budget
(<quota>, safety factor 1.5). Reduce the config (routes/regex/length) or
raise the budget: zig build -Dconfig_branch_quota=<n>
```

Cost units: conf byte 1, directive 8, block opened 16, complex-value fragment
4, regex pattern byte 3, regex NFA state 2, route 32.

## Daemon control and reloads

`--start`/`--stop`/`--status`/`--reload-hard` turn the server into a daemon.
The daemon records everything needed to reproduce its build+start in a state
file next to the pidfile: `<pidfile>.state` (JSON: `config_path`, `optimize`,
`port`, `threads`, `mode`, `idle_timeout`, `uring`, `single`, `embedded`,
`project_root`). `--pidfile` defaults to `/tmp/zocket.pid`.

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
     there is no acceptance gap.
  3. The old daemon gets SIGTERM and drains: it stops accepting, closes its
     listeners (so every new connection goes to the new daemon), serves any
     connections already in its accept backlog, and finishes its in-flight
     requests before exiting. The only loss window is the µs between the
     drain request and the listener close.
  4. The pid/state files are only removed by a daemon that still owns them:
     the old daemon checks the pidfile before cleaning up, so it cannot
     delete the new daemon's files.
  Conf paths must resolve inside the project tree — the comptime embed
  (`@embedFile`) cannot reach outside it (dot-directories like `.zig-cache`
  are excluded too).

SIGHUP is deliberately not handled (configs are comptime-only).

## Examples

### Basic

```
max_body 16m;
max_line_bytes 8k;
max_headers 64;

tls {
    cert "server.pem";
    key "server.key";
}

server {
    listen 8080;

    location = /health {
        return 200 "ok";
    }

    location / {
        content echo;
    }
}
```

### Redirect, variables, captures and templates

```
log_format combined "$ip - - [$date] \"$request\" $status $bytes \"$referer\" \"$user_agent\"";
log_format short "$request $status";

server {
    location = /old {
        return 301 "";
        add_header Location "/health";
    }

    location ~ ^/api/([0-9]+)/ {
        content echo;
        set $api_ver "$1";
        add_header X-API-Version "$api_ver";
        access_log combined;
    }

    location / {
        content echo;
        access_log short;
    }
}
```

### Static files and proxying

```
server {
    location ^~ /static/ {
        content static;
        root testdata;
        index index.html;
        autoindex on;
        max_age 3600;
    }

    location /proxy {
        rewrite proxy;
        proxy_pass 127.0.0.1:9000;
        proxy_set_header X-Forwarded-Host "$host";
    }

    location /lb {
        rewrite proxy;
        upstream 10.0.0.1:8000;
        upstream 10.0.0.2:8001;
        balance least_connections;
        max_fails 5;
        fail_timeout 15;
    }
}
```

### Comptime embedded asset

```
server {
    location /favicon.ico {
        content static;
        embed static/favicon.ico;
    }
}
```

See `config.example.conf` for the full reference sample, including the
gzip/conditional-GET/cache-headers pipeline (`log gzip;`,
`preaccess conditional_get;`, `post_access cache_headers;`).
