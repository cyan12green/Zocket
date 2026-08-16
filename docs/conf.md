# Zocket conf language reference

Zocket's configuration is an nginx-conf-flavored language, parsed and
validated **entirely at compile time** (`zig build -Dconfig=<file>`, via
`src/dsl/conf.zig`). There is no runtime config parse path. The canonical
overview lives in `docs/config.md`; this file is the full language
reference: grammar, directive table, variable catalog, regex subset and
examples.

## 1. Grammar

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
  directives/blocks.
- Quoted strings may appear anywhere a token may; unquoted tokens never
  contain whitespace.
- Errors carry `conf:<line>:<col>: <message>`.

## 2. Structure

- **Flat**: top-level directives (globals/limits/tls) plus exactly one
  `server { }` block holding `location { }` blocks. No `http {}`.
- Phase bindings are directives inside a location: `content echo;`
  (one directive per phase → module binding).

## 3. Directives

### 3.1 Globals (top level; also accepted inside `server {}`)

All `limits.zig` fields become directives with the same name (sizes accept
`k/m/g`, booleans `on|off`):

| Directive | Field | Notes |
|---|---|---|
| `recv_buffer_size <size>;` | `recv_buffer_size` | nginx `client_body_buffer_size` |
| `send_buffer_size <size>;` | `send_buffer_size` | |
| `max_body <size>;` | `max_body` | nginx `client_max_body_size` |
| `max_line_bytes <size>;` | `max_line_bytes` | nginx `large_client_header_buffers` |
| `max_headers <n>;` | `max_headers` | |
| `max_chunked_body <size>;` | `max_chunked_body` | |
| `static_cache_entries <n>;` | `static_cache_entries` | nginx `open_file_cache max=N` |
| `static_cache_valid <n>;` | `static_cache_valid_seconds` | nginx `open_file_cache_valid` |
| `static_content_cache_max <size>;` | `static_content_cache_max` | |
| `connection_pool_max <n>;` | `connection_pool_max` | |
| `listen <port>;` | `Config.listen_port` | null = CLI `--port` default (8080); CLI wins when both present |
| `tls { cert "<path>"; key "<path>"; }` | `TlsConfig` | |
| `log_format <name> "<complex value>";` | `Config.log_formats` | duplicate names → compile error |

Unknown directive or unknown key inside `tls` → `@compileError`.

### 3.2 `server {}`

Exactly one required; multiple → compile error (vhosts are a future
milestone). Contents: any global directive (merged) plus `location` blocks.

### 3.3 `location` blocks

```
location [modifier] <target> { stmt* }
```

| Modifier | Meaning | Match |
|---|---|---|
| (none) | prefix | `.prefix` |
| `=` | exact | `.exact` |
| `~` | regex, case-sensitive | `.regex` |
| `~*` | regex, case-insensitive | `.regex_ci` |
| `^~` | prefix, wins over regex | `.prefix` + `no_regex` |

Location directives (all optional):

| Directive | Effect |
|---|---|
| `<phase> <module>;` | Bind `module` to `phase` (`post_read, server_rewrite, find_config, rewrite, post_rewrite, preaccess, access, post_access, content, log`). Unknown module names are compile errors (via `comptimeValidate`). |
| `root <path>;` | `Route.root` |
| `index <file>;` | `Route.index` |
| `autoindex on\|off;` | `Route.autoindex` |
| `embed <path>;` | `Route.embed` (project-root-relative) |
| `max_age <n>;` | `Route.max_age_seconds` |
| `chunked on\|off;` | `Route.chunked` |
| `return <code> ["<cv>"];` | `Route.response` (literal) or `Route.response_cv` (variable-capable, M-B) |
| `add_header <name> "<cv>";` | append a header to the response template |
| `set $<name> "<cv>";` | declare a user variable (M-C); name `[A-Za-z_][A-Za-z0-9_]*`; `$1..$9`/`$$` reserved; duplicate name in scope → compile error |
| `proxy_pass <host>:<port>;` | single upstream (sugar) |
| `upstream <host>:<port>;` | append an upstream; host must be an IPv4 literal (validated at comptime) |
| `balance <round_robin\|least_connections\|ip_hash>;` | `Route.balance` |
| `max_fails <n>;` | `Route.max_fails` |
| `fail_timeout <n>;` | `Route.fail_timeout_seconds` |
| `proxy_set_header <name> "<cv>";` | `Route.proxy_headers` (M-E) |
| `access_log <format-name>\|off;` | `Route.log_format` (index into `Config.log_formats`) |

Unknown directive in a location → `@compileError`.

### 3.4 Location precedence (nginx)

1. Exact (`=`) trie match wins immediately.
2. Longest `^~`-flagged prefix wins immediately (regex skipped).
3. First regex (`~`/`~*`) match in **declaration order** wins immediately
   (captures recorded).
4. Otherwise the longest plain prefix wins; else 404.

## 4. Complex values & variables

Any value of a variable-capable directive (`log_format`, `return`,
`add_header`, `set`, `proxy_set_header`) is a **complex value**: a compiled
list of fragments (`Frag`), built once at compile time and rendered per
request with a comptime-switched getter loop — zero string scanning at
runtime.

### 4.1 Syntax

- `$name` → variable reference.
- `$$` → literal `$`.
- `${name}` → braced name (allows `-` etc.).

### 4.2 Built-in variables

| Var | Source |
|---|---|
| `$method` | request method (GET/HEAD/POST/...) |
| `$request_uri` | raw target incl. query |
| `$uri` | decoded target |
| `$args` / `$query_string` | query string (incl. leading `?`) |
| `$host` | `Host` header |
| `$status` | response status |
| `$body_bytes_sent` / `$bytes` | response body length |
| `$remote_addr` / `$ip` | client IPv4 (`-` when unknown) |
| `$remote_port` | `-` (not tracked yet) |
| `$server_protocol` | `HTTP/1.1` etc. |
| `$scheme` | `http` (TLS later) |
| `$request_time` | seconds since request start |
| `$content_length` | request Content-Length |
| `$content_type` | request Content-Type |
| `$date` / `$time_local` | combined-log date |
| `$request` | `METHOD target HTTP/1.1` |
| `$referer` | `Referer` header (`-` when absent) |
| `$user_agent` | `User-Agent` header (`-` when absent) |
| `$time_iso8601` | ISO-8601 timestamp |

### 4.3 Generic variables

- `$http_<name>` — request header, name with `_`→`-` (e.g. `$http_user_agent`
  → `user-agent`), case-insensitive hash match.
- `$arg_<name>` — query parameter (verbatim, case-sensitive).
- `$cookie_<name>` — cookie (lowercased).
- `$1..$9` — regex capture groups (valid inside regex-matched locations;
  renders `""` when no capture).

### 4.4 User variables (`set`)

`set $name "<cv>";` declares a variable scoped to the location. References
render lazily into the request arena and are cached for the request.
Forward references (before the `set`) and unknown names are compile errors.
Cap: `max_user_vars` (8) per location.

## 5. Regex subset (`location ~` / `~*`)

- Literals (escaped metachars: `\. \/ \\ \* \+ \? \( \) \[ \] \{ \} \| \^ \$`).
- `.` matches any byte except `\n`.
- Classes `[...]` and `[^...]` with ranges (`a-z`), escapes (`\d \w \s \D
  \W \S` and escaped metachars), literal `]` as first member.
- `\d` `[0-9]`, `\w` `[A-Za-z0-9_]`, `\s` `[ \t\r\n]`, `\D \W \S` complements.
- Quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` (greedy only).
- Groups `(...)` (capturing) and `(?:...)` (non-capturing).
- Alternation `|`.
- Anchors `^` (start) and `$` (end).
- No backrefs, no lookaround, no lazy/possessive modifiers, no `\b`, no
  named groups.

Malformed patterns are compile errors carrying the pattern text.

## 6. Comptime branch budget

The config parse, regex compilation, trie build and dispatch assignment
share the per-compilation comptime branch quota (default 100000). The
validate step measures the config's compile cost and fails with a clear
error before the quota is exhausted:

```
conf '<embedded>': config compile cost ~N exceeds the comptime branch budget
(<quota>, safety factor 1.5). Reduce the config (routes/regex/length) or
raise the budget: zig build -Dconfig_branch_quota=<n>
```

Cost units: conf byte 1, directive 8, block opened 16, complex-value
fragment 4, regex pattern byte 3, regex NFA state 2, route 32.

## 7. Examples

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

### Variables, captures and templates

```
log_format combined "$ip - - [$date] \"$request\" $status $bytes \"$referer\" \"$user_agent\"";
log_format short "$request $status";

server {
    location ~ ^/api/([0-9]+)/ {
        content echo;
        set $api_ver "$1";
        add_header X-API-Version "$api_ver";
        access_log combined;
    }

    location /old {
        return 301 "/health";
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
        content proxy;
        proxy_pass 127.0.0.1:9000;
        proxy_set_header X-Forwarded-Host "$host";
    }
}
```
