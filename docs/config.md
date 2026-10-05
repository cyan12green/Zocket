# Configuration

Zocket uses an nginx-flavored `.conf` language compiled entirely at build time
(`zig build -Dconfig=<file>`). The parser, route trie, dispatch specialisation,
response templates and upstream addresses all live in `.rodata` — no runtime
config parse. Invalid configs are compile errors (`conf:<line>:<col>`).

```sh
zig build -Dconfig=config.example.conf run
zig build -Dconfig=config.example.conf run -- --port 9000
zig build -Dconfig=config.example.conf -Doptimize=ReleaseFast  # benchmarking
zig build -Dconfig=config.example.conf run -- --validate       # print route table
```

The only reload is `--reload-hard` (rebuild + zero-downtime swap). SIGHUP is
not handled. Comptime embeds (`@embedFile`) can only reach project-tree files.

## Grammar

```
conf     := stmt* EOF
stmt     := directive ';' | block
block    := NAME ARG* '{' stmt* '}'
directive:= NAME ARG* ';'
ARG      := quoted | token | size | number
quoted   := '"' ( any except '"', escapes: \" \\ \n \r \t ) '"' | "'...'"
token    := [A-Za-z0-9_./:$@#!?=+\-%]+
size     := number (k|K|m|M|g|G)
number   := [0-9]+
comment  := '#' to end of line
```

Booleans: `on`/`off`. Errors: `conf:<line>:<col>: <message>`. Structure: flat
top-level directives + `server {}` blocks holding `location {}` blocks. No
`http {}` section.

## Directives

### Core

| Directive | Syntax | Default | Context | Description |
|---|---|---|---|---|
| `listen` | `listen port;` | 8080 | main, server | Listen port. CLI `--port` wins. Per-server overrides global. |
| `server` | `server { ... }` | — | main | Virtual host block (up to 16). Own routes, port, hostname. |
| `server_name` | `server_name name;` (repeatable) | — | server | Hostname(s) for vhost matching. Repeat the directive for multiple names. `*.domain` wildcards supported. |
| `host_select` | `host_select on\|off;` | on | main | Host-based vhost routing. `off` always uses first server. |
| `location` | `location [= ~ ~* ^~] uri { ... }` | — | server | Route declaration. Modifiers: exact/regex/prefix. |
| `return` | `return code [value];` | — | location | Fixed-response template (pre-serialised). |
| `root` | `root path;` | — | location | Document root for `static` module. |
| `embed` | `embed path;` | — | location | Comptime-embedded static file. |
| `set` | `set $name value;` | — | location | User variable (max 8 per location). |

### Modules (phase bindings)

| Directive | Syntax | Phase | Description |
|---|---|---|---|
| `content echo` | — | content | Echo request body |
| `content static` | — | content | Serve files from `root` |
| `rewrite proxy` | — | proxy to upstreams | Reverse proxy |
| `preaccess conditional_get` | — | preaccess | If-Modified-Since → 304 |
| `post_access cache_headers` | — | post_access | Cache-Control, ETag |
| `log gzip` | — | log | gzip compression |
| `log access_log` | — | log | Access logging |
| `access auth_basic` | — | access | Basic auth (htpasswd) |
| `access auth_request` | — | access | Subrequest auth |
| `access limit_req` | — | access | Rate limiting |
| `access limit_conn` | — | access | Concurrency limiting |
| `access access` | — | access | CIDR allow/deny (auto-bound by `allow`/`deny`) |
| `post_read realip` | — | post_read | Real client IP from trusted proxies (auto-bound by `set_real_ip_from` et al.) |
| `content precompressed` | — | content | .gz sibling serving |
| `rewrite proxy_cache` | — | rewrite | Response cache lookup |
| `content try_files` | — | content | Probe files, fall back (auto-bound by `try_files`) |
| `log error_page` | — | log | Status → alternate URI (auto-bound by `error_page`) |

Filters (run after every outcome, reverse declaration order):

| Directive | Syntax | Description |
|---|---|---|
| `filter headers` | — | Header manipulation (auto-bound by add/set/remove_header) |
| `filter gzip` | — | gzip compression (auto-bound by `gzip on;`) |
| `filter cache_headers` | — | Cache-Control (auto-bound by `max_age`) |
| `filter proxy_cache_store` | — | Cache store (auto-bound by `proxy_cache on;`) |

### Proxy & load balancing

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `proxy_pass` | `proxy_pass host:port;` | — | Single upstream (IPv4 literal). |
| `upstream` | `upstream host:port;` | — | Append backend (max 8 per route). |
| `balance` | `balance round_robin\|least_connections\|ip_hash\|random\|consistent_hash\|least_time` | round_robin | LB strategy. |
| `proxy_set_header` | `proxy_set_header name value;` | — | Override upstream request header. |
| `max_fails` | `max_fails number;` | 3 | Failures before marking backend down. |
| `fail_timeout` | `fail_timeout number;` | 30 | Seconds backend stays down. |
| `proxy_connect_timeout` | `proxy_connect_timeout seconds;` | 1 | Upstream connect deadline. |
| `proxy_send_timeout` | `proxy_send_timeout seconds;` | 1 | Upstream request-write deadline. |
| `proxy_read_timeout` | `proxy_read_timeout seconds;` | 5 | Upstream response-read deadline (SO_RCVTIMEO; sync-driver cap). |
| `proxy_next_upstream` | `proxy_next_upstream on\|off;` | off | Retry transport failures (connect/send/read error or timeout) on the next usable backend, once each. Failover re-offers the sticky tag. HTTP error statuses from a live backend are final. Sync forward path only. |
| `proxy_keepalive` | `proxy_keepalive number;` | 8 | Pooled keepalive connections per backend per thread (clamped to 32). |
| `proxy_keepalive_timeout` | `proxy_keepalive_timeout seconds;` | 60 | Idle expiry for pooled connections (reaped on next use). |
| `health_check` | `health_check path=... interval=... rise=... fall=... timeout=...` | — | Active backend probing. |
| `sticky_cookie` | `sticky_cookie name;` | — | Cookie-based backend affinity. |

### Caching

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `proxy_cache` | `proxy_cache on\|off;` | off | Enable response caching. The lookup is ordered before `proxy` regardless of declaration order (a HIT short-circuits upstream contact). |
| `proxy_cache_valid` | `proxy_cache_valid seconds;` | 60 | Fresh window. |
| `proxy_cache_stale_while_revalidate` | `proxy_cache_stale_while_revalidate seconds;` | 0 | Grace period. |

Zone sizing (in `limits` section): `proxy_cache_max_bytes` (32 MiB),
`proxy_cache_max_entries` (256).

### Internal redirects: try_files & error_page

Both build on the same primitive: a handler sets an internal-redirect
target and the server re-walks the new URI from `find_config` (capped at 8
hops per request; a self-referential entry stops at the cap instead of
spinning).

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `try_files` | `try_files $uri $uri/ /fallback;` or `try_files $uri =404;` | — | Probe each candidate against `root` in order; redirect to the first that exists. `$uri` is the request target, `$uri/` appends `index`. The last entry is the fallback: a URI redirects to it, `=code` answers that status in place. |
| `error_page` | `error_page 404 500 /50x.html;` or `error_page 503 =200;` | — | After the walk, when the outgoing status matches, redirect to the URI (methods other than GET/HEAD become GET) or rewrite the status in place (`=code`). Matches the status the request is heading out with — including 404 when no module claimed it. |

### Access control & real client IP

`allow`/`deny` evaluate in declaration order against `client_ip`
(first match wins; no match allows). Behind a CDN/LB, pair with
`set_real_ip_from` so the decision sees the real client, not the proxy
peer (the realip module runs in `post_read`, before every access check).

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `allow` | `allow 192.168.1.0/24;`, `allow 10.0.0.5;`, `allow all;` | — | Allow matching clients. Binds the `access` module. |
| `deny` | `deny 192.168.1.0/24;`, `deny all;` | — | Deny matching clients (403). Binds the `access` module. |
| `set_real_ip_from` | `set_real_ip_from 10.0.0.0/8;` | — | Trust this prefix: the peer may report the client IP. Binds `realip`. |
| `real_ip_header` | `real_ip_header X-Forwarded-For;` | X-Forwarded-For | Header to read the client IP from. |
| `real_ip_recursive` | `real_ip_recursive on\|off;` | off | Off: take the last header entry. On: walk right-to-left past trusted entries to the first untrusted one. |

### Rate and bandwidth limits

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `limit_req_status` | `limit_req_status 429\|503;` | 503 | Refusal status for rate-limited requests. |
| `limit_conn_status` | `limit_conn_status 429\|503;` | 503 | Refusal status for over-limit connections. |
| `limit_rate` | `limit_rate 100k;` | 0 (unlimited) | Per-connection response bandwidth cap (k/m/g suffixes). Token bucket paced in the reactor: memory and sendfile body bytes; headers/framing bypass. Plain HTTP/1.1 only (TLS/h2 framing paths bypass it). |

### Listen directive

| Syntax | Description |
|---|---|
| `listen 8080;` | Bind to all interfaces on port 8080 (IPv4). |
| `listen [::]:8080;` | Bind to all interfaces on port 8080 (IPv6, dual-stack). |
| `listen 127.0.0.1:3000;` | Bind to a specific IPv4 address and port. |
| `listen 8080 proxy_protocol;` | Expect a PROXY protocol header (v1 or v2) on every accepted connection; the header source becomes the peer IP before any HTTP/TLS/h2 parsing. Malformed headers drop the connection. Combines with `ipv6only=` in any order. |
| `listen 8080 ipv6only=on;` | Bare port with IPv6-only flag (no IPv4-mapped). |

The `listen` directive is valid in `server {}` blocks. If omitted, defaults
to port 8080 on all interfaces. IPv6 addresses use bracket syntax (`[addr]:port`).
The `ipv6only=on` flag sets `IPV6_V6ONLY` on the socket.

### Limits & buffers

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `max_body` | `max_body size;` | 16m | Max request body (431 on overflow). |
| `max_chunked_body` | `max_chunked_body size;` | 64k | Max chunked body (413). |
| `max_headers` | `max_headers number;` | 32 | Max request headers (431). |
| `max_line_bytes` | `max_line_bytes size;` | 8k | Max header/request line (431). |
| `recv_buffer_size` | `recv_buffer_size size;` | 16k | Per-connection recv buffer. |
| `send_buffer_size` | `send_buffer_size size;` | 16k | Per-connection send buffer. |
| `connection_pool_max` | `connection_pool_max number;` | 1024 | Max pooled connections per reactor. |
| `max_connections` | `max_connections number;` | 0 | Global ceiling on concurrent connections. 0 = unlimited. New accepts are rejected when active connections reach this limit. |
| `server_limit_conn` | `server_limit_conn number;` | 0 | Per-IP concurrent-connection cap at the server level (across all routes). 0 = unlimited. |
| `proxy_cache_max_bytes` | `proxy_cache_max_bytes size;` | 32m | mmap zone size for response cache entries. |
| `proxy_cache_max_entries` | `proxy_cache_max_entries number;` | 256 | Max distinct URL cache slots. |
| `client_header_timeout` | `client_header_timeout seconds;` | 10 | Total time for request line + headers (anti-slowloris). 0 disables. |
| `client_body_timeout` | `client_body_timeout seconds;` | 30 | Inactivity gap between body bytes. |

### Static file tuning

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `index` | `index file;` | — | Directory index file. |
| `autoindex` | `autoindex on\|off;` | off | Directory listing fallback. |
| `static_cache_entries` | `static_cache_entries number;` | 16 | fd-cache size. |
| `static_cache_valid` | `static_cache_valid seconds;` | 1 | Revalidation window. |
| `static_content_cache_max` | `static_content_cache_max size;` | 16k | Content-cache threshold. |

### Logging

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `log_format` | `log_format name value;` | combined | Named log format (max 16). |
| `access_log` | `access_log format\|off;` | combined | Per-route log format. |

### TLS

| Directive | Syntax | Description |
|---|---|---|
| `tls { cert file; key file; }` | — | Enable TLS 1.3 (ECDSA only, no RSA). One block max. |

### Response headers

| Directive | Syntax | Context | Description |
|---|---|---|---|
| `add_header` | `add_header name value;` | location | Append response header. |
| `set_header` | `set_header name value;` | location, server | Replace-or-append response header. |
| `remove_header` | `remove_header name;` | location, server | Drop response header. |

`always` flag applies to all status codes; without it, only 2xx/3xx/4xx.
Server-scope declarations inherit to child locations.

### Misc

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `chunked` | `chunked on\|off;` | off | Route opt-in for chunked transfer encoding. |
| `tcp_nopush` | `tcp_nopush on\|off;` | off | Batch head+sendfile into one TCP segment (Linux tcp_nopush). |
| `max_age` | `max_age seconds;` | 0 | Cache-Control max-age for cache_headers module. |

## Embedded variables

Complex values in `log_format`, `return`, `add_header`, `set`,
`proxy_set_header` support `$name` references (rendered per-request,
zero runtime string scanning).

| Variable | Value |
|---|---|
| `$method`, `$uri`, `$args`, `$host`, `$status` | request/response fields |
| `$ip`, `$remote_addr`, `$server_protocol`, `$scheme` | connection fields |
| `$date`, `$time_local`, `$time_iso8601`, `$request_time` | timestamps |
| `$bytes`, `$body_bytes_sent`, `$request`, `$referer`, `$user_agent` | logging |
| `$http_<name>`, `$arg_<name>`, `$cookie_<name>` | generic accessors |
| `$1..$9` | regex capture groups |

Resolution: captures → headers → args → cookies → set variables → builtins.

## Location matching

1. Exact (`=`) wins immediately.
2. Longest `^~` prefix wins (regex skipped).
3. First regex (`~`/`~*`) in declaration order wins (captures → `$1..$9`).
4. Longest plain prefix wins; else 404.

## Regex subset

Literals, `.`, `[...]`/`[^...]` with ranges and `\d \w \s \D \W \S`,
quantifiers `* + ? {n,m}`, groups `(...)`/`(?:...)`, alternation `|`,
anchors `^ $`. No backreferences, lookaround, lazy modifiers, `\b`,
named groups. Comptime-compiled Thompson NFA (`src/dsl/regex.zig`).

## Comptime budget

Config parse, regex compilation, trie build and dispatch share the comptime
branch quota (default 100k, `-Dconfig_branch_quota=<n>`). Cost measured in
units: byte 1, directive 8, block 16, fragment 4, regex byte 3, NFA state 2,
route 32. Over-budget is a compile error.

## Daemon control

```sh
zocket --start --port 8080 --threads 4 --pidfile /tmp/zocket.pid
zocket --stop --pidfile /tmp/zocket.pid
zocket --status --pidfile /tmp/zocket.pid
zocket --reload-hard --pidfile /tmp/zocket.pid  # rebuild + zero-downtime swap
```

`--reload-hard` rebuilds with `zig build -Doptimize=<state> -Dconfig=<conf>`,
execs the fresh binary (SO_REUSEPORT bind), then SIGTERMs the old daemon
which drains (30 s cap). Invalid configs abort the reload — old daemon
untouched. State file (`<pidfile>.state`) records config path, port, threads,
project root, zone fd descriptors.

## Examples

### Basic

```
max_body 16m;
tls { cert "server.pem"; key "server.key"; }
server {
    listen 8080;
    location = /health { return 200 "ok"; }
    location / { content echo; }
}
```

### Redirects and variables

```
server {
    location = /old {
        return 301 "";
        add_header Location "/health";
    }
    location ~ ^/api/([0-9]+)/ {
        content echo;
        set $api_ver "$1";
        add_header X-API-Version "$api_ver";
    }
    location / { content echo; }
}
```

### Static + proxy

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
    }
}
```

### Virtual hosts

```
server {
    listen 8080;
    server_name example.com;
    location / { content static; root /var/www/main; }
}
server {
    listen 9090;
    server_name api.example.com;
    server_name *.api.example.com;
    location / { rewrite proxy; upstream 10.0.0.1:8000; }
}
server {
    listen 8080;
    location / { return 404 "not found"; }
}
```

Matching: exact name → longest wildcard → first server on that port (default).
Repeat `server_name` for multiple names on one block. Each `listen` port is
served only by the blocks listening on it; `--port` overrides every block
(single group, Host selection across all blocks).

## Examples directory

Detailed, commented configs for each feature live in `examples/`:

| File | Feature |
|---|---|
| `examples/01-basics.conf` | Echo, health check, fixed responses |
| `examples/02-static.conf` | Static file serving, root, index, autoindex |
| `examples/03-gzip.conf` | Gzip compression, conditional GET, precompressed |
| `examples/04-proxy.conf` | Upstreams, LB strategies, health checks, sticky |
| `examples/05-proxy-cache.conf` | Response caching, stale-while-revalidate |
| `examples/06-auth.conf` | Basic auth (htpasswd) + subrequest auth |
| `examples/07-rate-limit.conf` | Rate limiting (limit_req) + connection limiting |
| `examples/08-headers.conf` | Response header manipulation |
| `examples/09-tls.conf` | TLS 1.3 with ECDSA certificates |
| `examples/10-vhosts.conf` | Virtual hosts, server_name, host_select |
| `examples/11-full.conf` | All features combined |

Run any example:

```sh
zig build -Dconfig=examples/01-basics.conf run
```
