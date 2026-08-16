# Plan: nginx-style conf language + complex variables (comptime-only)

Status: **M-A done (conf language core), M-B done (complex values & variables),
M-C done (set user variables), M-D done (regex engine + router precedence),
M-E pending**. This is the implementation blueprint for replacing the JSON
config with a custom nginx-conf-flavored language, compiled entirely at comptime,
with an nginx-style variable ("complex value") system and regex `location`
matching. A future agent session should be able to implement this end-to-end from
this document alone.

---

## 0. Goal & scope

1. Replace the JSON config with an nginx-conf-flavored custom language
   (`server {}` / `location {}` blocks, `directive value;` statements, `#` comments,
   size suffixes, `on|off` booleans).
2. Everything is **comptime-only**: the config is embedded at compile time
   (`zig build -Dconfig=<file>`), parsed and validated at compile time, and the
   built route table, variable tables, regex NFAs, complex-value fragment lists all
   live in `.rodata`. There is **no runtime config parse path** any more.
3. **Complex values** (the core feature): any directive value may contain
   `$variable` references. These are compiled at comptime into a `Frag` fragment
   list (nginx's "complex value") and rendered per request with a comptime-switched
   getter loop — zero string scanning at runtime.
4. **Variables**: built-in nginx-style variables (`$request_uri`, `$uri`, `$host`,
   `$http_*`, `$arg_*`, `$cookie_*`, ...), regex captures `$1..$9`, and user-defined
   variables via `set $name "<complex value>";` — resolved at comptime to slot
   indices.
5. **Regex**: `location ~` / `location ~*` matching (and `^~`) with a comptime
   Thompson-NFA compiler (solid subset, see §6), capture groups usable as
   `$1..$9` in any complex value within the location.
6. **Comptime branch budget is handled by `validate`** (§9): the validate step
   measures the config's compile cost and raises a clear, actionable compile error
   when a config would exhaust the shared comptime branch quota — instead of a deep
   cryptic branch-quota error.

Out of scope (future milestones, not this effort):
- `rewrite ... last|break` and `if (...) { }` blocks. These will be implemented as
  ordinary modules on the existing phase/module framework, reusing the variable,
  capture and regex infra built here.
- Multi-`server` vhost routing (Host-based). The config accepts exactly one
  `server` block for now.
- `upstream {}` named groups, `map {}`/`geo {}` variable setters, named regex
  captures `(?<name>...)`.

---

## 1. Decisions (locked)

These were decided with the project owner. Do not re-open them.

| Topic | Decision |
|---|---|
| Syntax nesting | **Flat**: top-level directives (globals/limits/tls) + exactly one `server { }` block holding `location { }` blocks. No `http {}`. |
| Phase bindings | Phase names are **directives** inside a location: `content echo;`, `log access_log;`. One directive per phase→module binding. |
| Runtime path | **Comptime-only**. The JSON runtime path (`--config`, `fromJson`, SIGHUP soft reload) is removed. Conf is embed-only. `--reload-hard` (rebuild + SO_REUSEPORT swap) remains the only reload. |
| Regex scope | Solid subset: literals, `.`, `[...]`/`[^...]` (ranges + escapes), `\d \w \s \D \W \S`, escaped metachars, `* + ? {n} {n,} {n,m}`, `( ... )` capture, `(?: ... )` non-capture, `|`, `^ $`. No backrefs, lookaround, or lazy modifiers. |
| rewrite / if | Future milestone as modules on the existing framework. |
| Budget | `validate` (comptime) owns the branch-budget check (§9). |

---

## 2. Current architecture summary (reference for the implementer)

The reader needs no prior exploration beyond this section plus the files named.

### 2.1 Config flow today

- **Comptime path (DM1/DM2, primary)**: `zig build -Dconfig=<file>` embeds a
  project-root-relative JSON file. `build.zig` (lines 38–46) exposes
  `b.option([]const u8, "config", ...)` into `build_options` as
  `config_path: ?[]const u8`. `src/main.zig` passes it to
  `Config.fromEmbedded(path)` → `json_config.parse(@import("embeds").embed(path))`
  → `Server.comptimeInit(cfg)`.
- **Runtime path (secondary, to be removed)**: `--config <file.json>` parsed at
  startup via `Config.fromJson` (std.json), trie built at startup, SIGHUP soft
  reload re-parses in-process.

### 2.2 Key types & files

- `src/runtime/config.zig` — `Config { routes: []const Route, limits: Limits, tls: TlsConfig }`;
  `TlsConfig { cert, key }`; `Config.default()` (parses a JSON literal at comptime);
  `fromJsonComptime`, `fromEmbedded`, `validate(comptime Registry: type)`,
  `deinit`, `fromJson`. Also the `Json*` mirror structs (`JsonConfig`, `JsonRoute`,
  `JsonModuleMap`, `JsonLimits`, `JsonTls`, `JsonResponse`, `JsonHeader`,
  `JsonUpstream`).
- `src/runtime/json_config.zig` — the DM1 comptime JSON validator/parser: `Str`
  union (`src` zero-copy / `pool` decoded), `RouteSpec`, `Builder` (CtPools:
  `routes/modules/headers/upstreams/strings` + `limits` + `tls_cert`/`tls_key`),
  `resolve`, `keyHash` (FNV-1a, comptime-keyed), hoisted `H_*` hash consts,
  `Cursor` (comptime recursive-descent over the JSON text with `@compileError`
  + byte positions), `parseTop/parseLimits/parseRoutes/parseRoute/parseModules/
  parseResponse/parseHeader/parseUpstreams/parseUpstream`, and `build(b) Config`
  which freezes the pools into comptime const arrays and slices them into the
  final `Config`. `parse()` sets `@setEvalBranchQuota(100000)`.
- `src/dsl/router.zig` — `Match { exact, prefix }`; `ModuleBinding { phase, module }`;
  `Route` (fields below); `matchRoutes` (linear); `TrieNode/TrieEdge/Trie`,
  `buildCore` (shared builder), `buildTrie` (comptime), `buildTrieRuntime` +
  `deinitTrie` (runtime, to be removed), `trieMatch`, `Router { routes, trie, owned }`;
  `TemplateHeader { name, value }`; `ResponseTemplate { status, headers, body, compress }`;
  `FastResponse { head, body }`; `serializeResponseTemplate(comptime t)`;
  `Balance { round_robin, least_connections, ip_hash }`; `Upstream { host, port,
  sockaddr }` + `makeSockaddr`.
  `Route` fields: `path, match, modules, dispatch: ?DispatchFn, max_age_seconds,
  root, root_real, root_fd, index, autoindex, embed, embed_bytes, response:
  ?ResponseTemplate, response_bytes: ?FastResponse, upstreams, balance, max_fails,
  fail_timeout_seconds, chunked`.
- `src/dsl/registry.zig` — `Outcome { handled, not_handled }`; `DispatchFn`;
  `Module { name, phase, run }`; `Action { pass, handled, short_circuit }`;
  `Context` (fields below); `ServerStats`; `Registry(comptime modules) type` with
  `resolve`, `infos`, `validateBindings`, `isRegistered`; `default_registry`
  (echo, gzip, conditional_get, cache_headers, static, proxy, access_log,
  error_log, stub_status).
  `Context` fields: `req: *Request, resp: *Response, route: ?*const Route,
  close_after_write: bool, allocator: ?std.mem.Allocator, etag, last_modified,
  client_ip: [4]u8, stats: ?*const ServerStats, static_cache:
  ?*StaticCache, limits: ?*const Limits`.
- `src/dsl/pipeline.zig` — `run`, `runWithRouter` (find_config via router → walk
  `Phase.all`, log phase post-processing, template fallback via `applyTemplate`),
  `dispatchForRoute` (comptime unrolled dispatch fn), `assignDispatch` (also
  resolves `embed` bytes, pre-serialises `response_bytes`, validates upstream
  sockaddrs at comptime). `applyTemplate(ctx, t: ResponseTemplate)` sets
  `ctx.resp` status/headers/body.
- `src/runtime/server.zig` — `Server { cfg, router, stats, tls_creds }`;
  `loadTls`, `init` (no trie, for tests), `comptimeInit`/`comptimeInitImpl`,
  `initWithTrie` (runtime trie, to be removed), `deinit`, `default()`,
  `embeddedInitWithTls`, `embeddedInit` (copies routes into allocator and fills
  `root_real`/`root_fd` at startup — the rooted-route copy), `deinitPrepared`,
  `handleRequest`, `matchFast` (returns `FastResponse` only for module-less
  routes with `response_bytes`).
- `src/net/reactor.zig` — `handleHttpRequest` builds `ctx` (lines ~1150–1159) with
  `req/resp/allocator/client_ip/stats/static_cache/limits`; fast path calls
  `handler.matchFast(&ctx)` and writes `fb.head` + `Connection/Content-Length` +
  `fb.body` directly (lines ~1162–1191). Non-fast path calls `handleRequest` and
  serializes via `writevHeadParts` / sendfile / chunked framing.
- `src/http/parser.zig` — `Request` fields: `method, target, decoded_target,
  query_string, version, keep_alive, content_length, body, allocator, max_headers,
  arena: Arena, body_storage, slots, header_count, transfer_chunked`.
  `header(comptime name)` (DFA-tag scan for known names, case-insensitive string
  scan for unknown), `headerAt(i)`, `addHeaderParsed`. `header_hasher` (FNV-1a
  32-bit, lowercased), `HeaderTag` + `header_dfa` (comptime DFA), `known` set.
- `src/http/response.zig` — `Response { status, body, headers, header_count,
  body_owned, scratch: [96]u8, scratch_used, body_from_file, file_fd, ...,
  chunked }`; `setHeader`, `setHeaderFmt`, `setBody`, `writevParts`,
  `writevHeadParts`, `writeHeadToBuffer[WithLength]`, `writeChunkedHeadToBuffer`.
- `src/http/arena.zig` — bump arena, `alloc(n) ?[]u8`, `reset()`, embedded 16 KiB
  + warm heap blocks. Slices valid until `reset()`. Request-scoped rendering pool.
- `src/dsl/modules/access_log.zig` — **the existing seed of this plan**: `$var`
  format strings parsed at comptime into a `Token` union
  (`parseFormat`/`fieldToken`/`formatTokenCount`, lines 24–103), `combined_format`,
  `tokens`, `run` renders into a threadlocal buffered line. This ad-hoc system is
  replaced by the general complex-value infra (§5).
- `src/dsl/modules/proxy.zig` — `run`, `sendUpstreamRequest` (builds the upstream
  request text), `UpstreamReader`. Will gain `proxy_set_header`.
- `src/dsl/limits.zig` — `Limits` struct, 10 fields, compiled defaults.
- `src/root.zig` — library root; re-exports every submodule AND comptime-imports
  every submodule in the `comptime { }` block so their `test` blocks run
  (`zig build test` collects tests only via comptime imports from the test root).
  **Every new submodule must be added to both**.
- `embeds.zig` (project root) — `pub fn embed(comptime path) []const u8 {
  return @embedFile(path); }`. Wired as the `embeds` module in `build.zig`.
  `@embedFile` can only reach files inside the project tree (no dotdirs).
- `src/main.zig` — CLI: `--config`, `--reload-soft`, `--reload-hard`, `--start/
  --stop/--status`, `--pidfile`, `--port`, `--threads`, `--uring`, `--single`,
  `--echo`, `--http`. SIGHUP soft-reload machinery (lines ~561+), reload-soft flag
  handling (~743–754, ~817), `-Dconfig` embed wiring (~148–196).
- `src/net/multireactor.zig` — SIGHUP reload handler + reactor-set re-creation
  (lines 37, 175, 230, 515–531).

### 2.3 Comptime conventions to preserve

- Prefer comptime structures: build decode/lookup tables, tries, hash-dispatch and
  NFA tables at comptime; runtime loops over comptime-known data are replaced by
  comptime-built tables (integer-compare hash prefiltering, binary-searchable
  indices).
- Comptime values freeze into `.rodata`. A slice of a *comptime var* cannot
  escape into a runtime value — always build by value then `freeze()` the CtPool
  (see `ct_pool.zig` `CtPool.create/freeze`) or break the built structs out of a
  `comptime` block.
- Comptime branch quota is **shared per compilation** across every comptime
  evaluation (AGENTS.md documents the 1000-backward-branch default and the
  `json_config` 100000 bump). Cost accounting is §9's job.
- Module/phase validation at comptime: `assignDispatch` already calls
  `Registry.resolve(name).?` per binding, so an unknown module name is already a
  comptime panic/error in the comptime path — the conf parser does **not** need to
  validate module names itself (matches the `json_config` budget comment).
- New submodules MUST be re-exported from `src/root.zig` AND added to its
  `comptime { _ = @import(...); }` block.

---

## 3. Language spec

### 3.1 Grammar

```
conf     := stmt* EOF
stmt     := directive ';' | block
block    := NAME ARG* '{' stmt* '}'
directive:= NAME ARG* ';'
ARG      := quoted | token | size | number
quoted   := '"' ( any char except '"', with '\' escapes: \" \\ \n \r \t ) '"'
           | "'" ( any char except "'" ) "'"
token    := one or more of [A-Za-z0-9_./:$@#!?=+\-%]  (no whitespace, no ; { } ' ")
size     := number followed by suffix k|K|m|M|g|G  (1024-multipliers)
number   := [0-9]+
comment  := '#' to end of line (outside quoted strings)
```

- Tokens are separated by whitespace. `;`, `{`, `}` terminate directives/blocks.
- Quoted strings may appear anywhere a token may; unquoted tokens never contain
  whitespace. Complex values are the *quoted string or token text* of any value
  that the directive declares variable-capable (see §5; `parseComplexValue` runs
  on the raw text).
- Line/column tracking for error messages: record the byte offset like
  `json_config.Cursor` and format
  `@compileError("conf:<line>:<col>: <message>")`. Compute line/col from offset on
  failure.

### 3.2 Example

```
# Zocket config
max_body 16m;
max_line_bytes 8k;
max_headers 64;
static_cache_valid 60;

log_format combined "$ip - - [$date] \"$request\" $status $bytes \"$referer\" \"$user_agent\"";
log_format short "$request $status";

tls {
    cert "server.pem";
    key "server.key";
}

server {
    listen 8080;

    location = /health {
        return 200 "ok";
    }

    location ~ ^/api/([0-9]+)/ {
        content echo;
        set $api_ver "$1";
        add_header X-API-Version "$api_ver";
        access_log combined;
    }

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

    location /old {
        return 301 "/health";
    }

    location / {
        content echo;
    }
}
```

### 3.3 Directives

#### 3.3.1 Global directives (top level; also accepted inside `server {}`)

All `limits.zig` fields become directives with the same name; sizes accept the
`k/m/g` suffix, booleans accept `on|off`. Directive name → `Limits` field:

| Directive | Field | Notes |
|---|---|---|
| `recv_buffer_size <size>;` | `recv_buffer_size` | nginx `client_body_buffer_size` |
| `send_buffer_size <size>;` | `send_buffer_size` | |
| `max_body <size>;` | `max_body` | nginx `client_max_body_size` |
| `max_line_bytes <size>;` | `max_line_bytes` | nginx `large_client_header_buffers` |
| `max_headers <n>;` | `max_headers` | |
| `max_chunked_body <size>;` | `max_chunked_body` | |
| `static_cache_entries <n>;` | `static_cache_entries` | nginx `open_file_cache max=N` |
| `static_cache_valid <n>;` | `static_cache_valid_seconds` | nginx `open_file_cache_valid` (directive uses `valid`, field keeps `_seconds`) |
| `static_content_cache_max <size>;` | `static_content_cache_max` | |
| `connection_pool_max <n>;` | `connection_pool_max` | |

Other globals:
- `listen <port>;` → new `Config.listen_port: ?u16` (null = CLI `--port` default
  8080; CLI wins when set).
- `tls { cert "<path>"; key "<path>"; }` → `TlsConfig`.
- `log_format <name> "<complex value>";` → `Config.log_formats:
  []const LogFormat { name: []const u8, value: []const Frag }`. Duplicate names
  → compile error.

Unknown directive or unknown key inside `tls`/`log_format` → `@compileError`.

#### 3.3.2 `server { }` block

Exactly one `server` block required. Multiple → compile error (vhosts are a
future milestone). Contents: any global directive (merged) plus `location`
blocks.

#### 3.3.3 `location` blocks

```
location [modifier] <target> { stmt* }
```

| Modifier | Meaning | Match enum |
|---|---|---|
| (none) | prefix | `.prefix` (existing trie path) |
| `=` | exact | `.exact` (existing trie path) |
| `~` | regex, case-sensitive | `.regex` |
| `~*` | regex, case-insensitive | `.regex_ci` |
| `^~` | prefix, wins over regex | `.prefix` + new `no_regex: true` flag (still a trie prefix route; only precedence changes) |

Location directives (all optional):

| Directive | Effect |
|---|---|
| `<phase> <module>;` | Bind `module` to `phase` on this route (`Phase.all` names: `post_read, server_rewrite, find_config, rewrite, post_rewrite, preaccess, access, post_access, content, log`). Module names NOT validated by the parser (see §2.3; `assignDispatch` catches unknowns at comptime). |
| `root <path>;` | `Route.root` |
| `index <file>;` | `Route.index` |
| `autoindex on\|off;` | `Route.autoindex` |
| `embed <path>;` | `Route.embed` |
| `max_age <n>;` | `Route.max_age_seconds` |
| `chunked on\|off;` | `Route.chunked` |
| `return <code> ["<cv>"];` | `Route.response_cv` (see §4.3). Code is an int → status. Body is a complex value (default empty). |
| `add_header <name> "<cv>";` | append a header to `response_cv.headers` |
| `set $<name> "<cv>";` | declare a user variable (see §5.3). Name must be a valid identifier `[A-Za-z_][A-Za-z0-9_]*`; `$1..$9`/`$$` reserved. Duplicate `set` name in scope → compile error. |
| `proxy_pass <host>:<port>;` | single upstream (sugar for one `upstream`) |
| `upstream <host>:<port>;` | append an upstream; `host` must be an IPv4 literal (validated at comptime via `Upstream.makeSockaddr`, like `json_config` does — host literals only, no DNS). Repeatable. |
| `balance <round_robin\|least_connections\|ip_hash>;` | `Route.balance` |
| `max_fails <n>;` | `Route.max_fails` |
| `fail_timeout <n>;` | `Route.fail_timeout_seconds` |
| `proxy_set_header <name> "<cv>";` | `Route.proxy_headers` (see §4.2) |
| `access_log <format-name>\|off;` | select a named `log_format` for the log phase (or disable); stored as `Route.log_format: ?usize` (index into `Config.log_formats`). The `access_log` module reads it; defaults to index 0 (the `combined` default) when the route binds `log access_log;` and no `access_log` directive is present. `off` forces `null`. |

Unknown directive in a location → `@compileError`. `location` target: for
regex modifiers the target is compiled via the regex engine (§6); for prefix/
exact it is a literal path.

### 3.4 Location precedence (nginx)

Implemented in `Router.match` (§7). Order:
1. Exact (`=`) trie match wins immediately.
2. Longest `^~`-flagged prefix: if found, wins immediately (regex skipped).
3. First regex (`~`/`~*`) match in **declaration order** wins immediately
   (captures recorded into the context).
4. Otherwise the longest plain prefix wins; else no match (404).

The existing trie already returns exact-over-prefix and longest-prefix; regex and
`^~` are additive. Regex routes must NOT go into the trie (they are walked
separately in declaration order).

---

## 4. Data model changes

### 4.1 `Route` additions (`src/dsl/router.zig`)

```zig
pub const Match = enum { exact, prefix, regex, regex_ci };

pub const Route = struct {
    // existing fields unchanged ...
    /// new:
    /// `^~` prefix flag (still .prefix; only precedence differs).
    no_regex: bool = false,
    /// Comptime-compiled NFA for .regex / .regex_ci locations.
    pattern_regex: ?Regex = null,
    /// User variables declared with `set` in this location.
    set_vars: []const SetVar = &.{},
    /// Dynamic response template (return/add_header with variables).
    response_cv: ?ResponseTemplateCV = null,
    /// proxy_set_header overrides.
    proxy_headers: []const ProxyHeader = &.{},
    /// Index into Config.log_formats; null = none (off), usize = name index.
    log_format: ?usize = null,
};
```

`Match.regex`/`regex_ci` routes are excluded from the trie; `trieMatch` is only
built over `exact`/`prefix` routes (the trie builder must skip regex routes and
`^~`/plain prefixes behave as today). A comptime-built **regex table** holds
`{ re: *const Regex, route_index: u32 }` in declaration order (see §7).

### 4.2 Proxy header overrides

```zig
pub const ProxyHeader = struct { name: []const u8, value: []const Frag };
```

### 4.3 Dynamic response template

The existing literal `ResponseTemplate` + `FastResponse`/`response_bytes`
pre-serialization stays untouched for literal-only templates. Variable-capable
templates use a new parallel type so the literal fast path and its tests are
unchanged:

```zig
pub const CVHeader = struct { name: []const u8, value: []const Frag };
pub const ResponseTemplateCV = struct {
    status: u16 = 200,
    headers: []const CVHeader = &.{},
    body: []const Frag = &.{},   // empty Frag slice = empty body
    compress: bool = false,
};
```

`Route.response` (literal) and `Route.response_cv` (dynamic) are mutually
exclusive (config produces one or the other; `return` with a literal-only body
*without* `add_header`-variables still yields the literal `response` + fast path;
any variable or variable header forces `response_cv`). `assignDispatch`
pre-serialises `response_bytes` only when `response` is set (unchanged);
`matchFast` already returns null when `response_bytes == null`, so dynamic
templates fall through to the pipeline automatically.

### 4.4 `Config` additions (`src/runtime/config.zig`)

```zig
pub const Config = struct {
    routes: []const Route = &.{},
    limits: Limits = .{},
    tls: TlsConfig = .{},
    /// new:
    listen_port: ?u16 = null,
    log_formats: []const LogFormat = &.{},
};

pub const LogFormat = struct { name: []const u8, value: []const Frag };
```

### 4.5 `Context` additions (`src/dsl/registry.zig`)

```zig
pub const Context = struct {
    // existing fields unchanged ...
    /// regex capture ranges into `capture_subject` (decoded target, arena-stable).
    captures: [9]CaptureRange = .{ .{ .start = 0, .end = 0 } } ** 9,
    capture_count: u8 = 0,
    capture_subject: []const u8 = "",
    /// Lazy-rendered user-variable slots (set $var), slices into req.arena.
    user_slots: [max_user_vars]?[]const u8 = .{null} ** max_user_vars,
    /// Per-request start instant for `$request_time`.
    started: std.time.Instant = undefined,
};
pub const CaptureRange = struct { start: u16, end: u16 };
```

`max_user_vars` is a comptime cap (start at 8) — the conf parser assigns `set`
names to slots 0..N-1 and errors when N exceeds it. The reactor's `ctx`
construction (`src/net/reactor.zig` ~line 1150) must set `started =
std.time.Instant.now() catch ...` (guarded: `Instant.now` can fail; on failure
leave zeroed and `$request_time` renders `0`).

---

## 5. Complex values & variables — `src/dsl/vars.zig` (new)

### 5.1 The `Frag` fragment type

nginx's "complex value" = a compiled list of fragments, built once at config
load. Here it is built at comptime; rendering is a comptime-switched loop.

```zig
/// One compiled fragment of a complex value.
pub const Frag = union(enum) {
    literal: []const u8,   // zero-copy slice into the conf source (.rodata)
    builtin: VarId,        // fixed built-in variable
    http_header: u32,      // $http_<name>: header_hasher.hash of the dashed name
    arg: u32,              // $arg_<name>: FNV-1a (lowercased) of the param name
    cookie: u32,           // $cookie_<name>: hash of the cookie name
    capture: u8,           // $1..$9 → index 1..9 into ctx.captures
    user: u8,              // slot index into ctx.user_slots (comptime-resolved)
};
```

- Literal fragments alias the conf source bytes (zero-copy, `.rodata`), exactly
  like `json_config.Str.src`.
- Generic variables carry a **comptime-computed hash** so runtime dispatch is an
  integer compare (`header_hasher` style). `$http_user_agent` → the
  `header_hasher.hash("user-agent")`; `$arg_q`/`$cookie_session` → a FNV-1a hash
  of the name (lowercased for cookies; query args are case-sensitive — hash
  verbatim, do NOT lowercase). See §5.5.
- `$host`, `$uri`, etc. (fixed names) use `builtin: VarId`.

### 5.2 `VarId` and the built-in catalog

```zig
pub const VarId = enum {
    method, request_uri, uri, args, query_string, host,
    status, body_bytes_sent, remote_addr, remote_port,
    server_protocol, scheme, request_time,
    content_length, content_type,
    // access_log short aliases (keep these working):
    ip, date, request, bytes, referer, user_agent,
    time_local, time_iso8601,
    // future: request_filename, document_root, hostname, ...
};
```

Comptime name→VarId resolution via `keyHash`-style hashed switch (`json_config`
pattern). Getter contract: `fn getVar(comptime id: VarId, ctx: *Context) []const u8`
returns a **zero-copy slice** (from `req`, `ctx`, or a caller-owned scratch the
renderer must copy). Mapping:

| Var | Source |
|---|---|
| `method` | `ctx.req.method` → name via the `methodName` switch in `access_log.zig` |
| `request_uri` | `ctx.req.target` (raw, incl. query) |
| `uri` | `ctx.req.decoded_target` |
| `args` / `query_string` | `ctx.req.query_string` (both aliases; note it includes the leading `?`) |
| `host` | `ctx.req.header("host") orelse ""` |
| `status` | `ctx.resp.status` → digits (needs scratch — see below) |
| `body_bytes_sent` | `ctx.resp.body.len` → digits |
| `remote_addr` | `ctx.client_ip` → "d.d.d.d" (skip when all-zero → `"-"` like access_log does) |
| `remote_port` | not tracked on Context yet → render `"-"` (note in code) |
| `server_protocol` | `"HTTP/{major}.{minor}"` from `ctx.req.version` |
| `scheme` | `"http"` (TLS later) |
| `request_time` | `(now - ctx.started)` seconds → digits |
| `content_length` | `ctx.req.content_length` → digits |
| `content_type` | `ctx.req.header("content-type") orelse ""` |
| `ip` | alias of `remote_addr` |
| `date` / `time_local` | the `logDate(epoch_secs, buf)` helper from `access_log.zig` (clock_gettime REALTIME) |
| `request` | `"{method} {target} HTTP/1.1"` (bufPrint, as access_log does) |
| `bytes` | alias of `body_bytes_sent` |
| `referer` | `ctx.req.header("referer") orelse "-"` |
| `user_agent` | `ctx.req.header("user-agent") orelse "-"` |

**Digit / formatted values**: getters that produce digits or formatted strings
need scratch. Two options, pick the simpler:
(a) getters write into a caller-provided `[64]u8` scratch; `renderComplex` owns a
stack scratch and appends the slice (copies on the stack — fine, bounded).
(b) reuse `resp.scratch` — but that is consumed by response serialisation and is
small; prefer (a) with a dedicated render scratch passed into `renderComplex`.

### 5.3 User variables (`set`)

```zig
pub const SetVar = struct { name: []const u8, slot: u8, value: []const Frag };
```

- The parser accumulates `set` declarations per location in parse order; name →
  slot index (0..`max_user_vars`-1). Duplicate name in the same location →
  compile error. `$<name>` references *after* the `set` resolve at comptime to
  `.user = slot`. References *before* the `set` (or to an undeclared name) →
  compile error "unknown variable".
- Rendering is lazy: the first fragment referencing slot `s` calls
  `renderComplex` for that `SetVar.value` into the **request arena**
  (`ctx.req.arena.alloc`), stores the slice in `ctx.user_slots[s]`, and caches;
  later references reuse the cached slice. (A tiny `[8]bool` rendered-flag array
  or `null` sentinel in the slot itself handles the cache.)

### 5.4 `parseComplexValue` (comptime)

```zig
pub fn parseComplexValue(comptime text: []const u8) []const Frag
```

Scanner:
- `$$` → literal `$`.
- `$` followed by `{...}` → braced name (allows `-` and anything not `}`; used
  for names like `${request_uri}`).
- `$` followed by `[A-Za-z0-9_]+` → name.
- Otherwise: literal `$` (or error — pick: treat bare trailing `$` as literal,
  matching nginx leniency).
- Name resolution order:
  1. `$1..$9` (single digit) → `.capture` (captures valid inside regex-matched
     locations; rendering when `capture_count == 0` or out of range yields `""`).
  2. prefix `http_` → `.http_header` with `header_hasher.hash(name[5..])` with
     `_`→`-` (so `$http_user_agent` hashes "user-agent").
  3. prefix `arg_` → `.arg` with hash of `name[4..]` (verbatim, case-sensitive).
  4. prefix `cookie_` → `.cookie` with hash of `name[7..]` (lowercased).
  5. declared `set` name in scope → `.user = slot`.
  6. built-in `VarId` by exact name.
  7. else `@compileError("unknown variable '${name}' at <line:col>")`.

Return value: a `[]const Frag` — build in a comptime block via a
`ct_pool.CtPool(Frag, bound)` where `bound = text.len + 1`, then `freeze()` and
slice (slices of comptime consts freeze into `.rodata`).

### 5.5 Generic-variable runtime lookup

- `.http_header`: `const h = header_hasher.hash(dashed_name)` is comptime-known;
  render by scanning `req.slots` comparing `header_hasher.hash(slot.name)` to `h`
  (case-insensitive by construction — exactly the existing `header_hasher`
  semantics; note slot names are already stored; a `Request`-side helper
  `headerByHash(h: u32) ?[]const u8` is a clean addition, sharing the hash
  prefiltering idea from AGENTS.md).
- `.arg`: parse `ctx.req.query_string` once (strip leading `?`, split on `&`,
  then `=`), hash each param name verbatim, first match wins. Result cached where
  sensible (see §5.6). Percent-decoding of arg values is out of scope (raw slice).
- `.cookie`: parse `ctx.req.header("cookie")` once, split on `;`, trim, split on
  `=`, hash name lowercased, first match wins.

### 5.6 `renderComplex` (runtime)

```zig
pub fn renderComplex(ctx: *Context, value: []const Frag, sink: anytype) !void
```

- `sink` exposes `appendAll([]const u8) !void`. Adapters:
  - `ArrayListSink { list: *std.ArrayList(u8), allocator }`.
  - `ArenaSink { arena: *Arena }` — copies fragments into the arena, returns a
    single slice (`renderComplexArena(ctx, value, arena) ?[]const u8` convenience).
  - a fixed-stack-buffer sink for the small getter scratch.
- Loop over fragments, `switch (frag)` with a comptime-unrolled builtin getter
  switch; literal append; generic hash lookups per §5.5; captures slice
  `ctx.capture_subject[start..end]`; user slots render-on-first-use into the
  arena (then cache in `ctx.user_slots[slot]`).
- Hot-path constraint: **zero allocations** unless a value is being materialized
  into the arena (only for response headers/body and user vars). Log lines and
  upstream request text render directly into their ArrayList.

---

## 6. Regex engine — `src/dsl/regex.zig` (new)

### 6.1 Feature set (locked)

- Literals (escaped metachars: `\. \/ \\ \* \+ \? \( \) \[ \] \{ \} \| \^ \$`).
- `.` matches any byte except `\n`.
- Classes `[...]` and `[^...]` with ranges (`a-z`), escapes (`\d \w \s \D \W \S`
  and the escaped metachars), and literal `]` as first member.
- `\d` `[0-9]`, `\w` `[A-Za-z0-9_]`, `\s` `[ \t\r\n]`, `\D \W \S` complements.
- Quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` (greedy; no lazy variants).
- Groups `(...)` (capturing) and `(?:...)` (non-capturing).
- Alternation `|`.
- Anchors `^` (start of subject) and `$` (end of subject).
- No backrefs, no lookaround, no lazy/possessive modifiers, no `\b`, no named
  groups. Document the subset in the module header and docs/conf.md.
- Malformed pattern (unbalanced paren, bad class, bad quantifier, dangling `\`,
  empty `{}`) → `@compileError` with the pattern text.

### 6.2 API

```zig
pub const Regex = struct {
    /// Thompson NFA: flat transition table; every index is a state id.
    states: []const State = &.{},
    /// Number of capture groups (excl. group 0 = whole match).
    group_count: u8 = 0,
};

pub const State = struct {
    /// (c < 256): consume byte c. (c == 256): epsilon.
    kind: u8,   // 0=consume, 1=epsilon, 2=match
    byte: u16,  // 0..255, or 0xFFFF for the match state
    next: u32,
    next2: u32,  // second target (epsilon branch / alternation); = next when unused
    /// non-negative: this state is the *start* of capture group g.
    cap_start: i16 = -1,
    /// non-negative: this state is the *end* of capture group g.
    cap_end: i16 = -1,
};
```

- Character classes compile to a `[32]u32` bitmask table stored separately in
  the `Regex` (or inline as a special state kind referencing a class index —
  pick the simpler; a `class_bitmap: []const [32]u32` slice next to `states` is
  clean).
- `compileRegex(comptime pattern: []const u8) Regex` — parse to an AST at
  comptime (recursive descent over the pattern), then emit NFA states via the
  standard Thompson construction (two-out epsilon merges for `|`, fragment
  splitting for `* + ? {n,m}`), marking capture-group start/end states. Run in a
  `comptime` block with `@setEvalBranchQuota` (§9.4). The compiled table is a
  comptime const → `.rodata`.
- `match(re: *const Regex, subject: []const u8, caps: []CaptureRange, start: usize) bool`
  — backtracking over the NFA with a visited/on-path epsilon-closure guard (or a
  simple exponential-worst-case backtracker — fine for config-authored patterns
  and short URIs; document the worst case). On success fills `caps[0..group_count]`
  with start/end offsets into `subject` (group 0 = whole match at `caps[0]`).
  `^` forces `start == 0`; `$` requires the match to end at `subject.len`.
- `matchRegexLiteral(re, subject, caps)` → wraps `match(..., 0)`.
- Case-insensitive (`~*`): fold both pattern and subject through `ascii.toLower`
  during consumption (or pre-lowercase the subject slice on a scratch); simplest
  is lowering in the byte-compare.

### 6.3 Comptime budget note

Regex NFA compilation is the most expensive comptime step (one branch per pattern
byte plus per-state emission). Cost accounting lives in §9.

---

## 7. Router changes (`src/dsl/router.zig`)

- `Match` gains `regex`/`regex_ci` (§4.1). `Route.no_regex` for `^~`.
- The trie builders (`buildCore`, `buildTrie`) must **skip regex routes** (they
  are not trie material) but keep exact/prefix (incl. `^~`, which is just a
  prefix route carrying `no_regex: true`). `trieBounds`/node accounting must
  exclude regex routes.
- New comptime-built **regex table**:
  ```zig
  pub const RegexRoute = struct { re: *const Regex, route: u32, ci: bool };
  // Router gains:
  regex_routes: []const RegexRoute = &.{},
  ```
  Built by `buildTrie`/`comptimeInitImpl` in declaration order. `buildTrieRuntime`
  is deleted (§11).
- **Precedence algorithm** in `Router.match` (per §3.4). `match` must also record
  captures, so change the signature:
  ```zig
  pub fn match(self: *const Router, target: []const u8, caps: ?*MatchCaps) ?*const Route
  pub const MatchCaps = struct {
      subject: []const u8,
      ranges: [9]CaptureRange,
      count: u8,
  };
  ```
  The pipeline's `runWithRouter` builds a `MatchCaps` over `ctx.req.decoded_target`
  (arena-stable), passes it to `match`, and copies the result into `ctx.captures/
  capture_subject/capture_count`. Regex routes must check `Route.no_regex` on the
  trie best-prefix (a `^~` prefix short-circuits before the regex pass; a plain
  prefix is remembered and only returned if no regex matched).
  Steps:
  1. `trieMatch` exact → return (record no captures).
  2. longest `^~` prefix via the trie's `best_prefix` walk + `no_regex` flag →
     return.
  3. walk `regex_routes` in order; first `match(...)` success → return, fill caps.
  4. longest plain prefix from the trie walk → return.
  5. null.
  The linear fallback `matchRoutes` (used by `Server.init` tests) must implement
  the same order for correctness parity.
- `no_route`, `TrieNode`, `TrieEdge`, `trieMatch`, `Router` layout stay otherwise
  intact.

---

## 8. Pipeline & module changes

### 8.1 `src/dsl/pipeline.zig`

- `runWithRouter`: build `MatchCaps{ .subject = ctx.req.decoded_target, ... }`,
  call `rtr.match(ctx.req.target, &caps)`, then set `ctx.capture_subject/captures/
  capture_count` from `caps`. (Only populated when the winning route is a regex
  route.)
- New `applyTemplateCV(ctx, t: *const ResponseTemplateCV)`: render each header
  value and the body into `ctx.req.arena` (`renderComplexArena`), then apply like
  `applyTemplate` (status enum, setHeader, body). Called from the
  `dispatchForRoute` not_handled fallback and the loop-walk fallback (both places
  `applyTemplate` is currently called), when `response_cv` is set instead of
  `response`.
- `assignDispatchImpl`: when `r.response_cv != null`, **do not** pre-serialise
  `response_bytes` (it stays null → `matchFast` returns null → pipeline path). If
  `r.response` (literal) is set, pre-serialise as today. Add comptime validation:
  a `response_cv` requires the route to be module-less OR have modules (same
  semantics as today's `response` fallback — both allowed).

### 8.2 `src/net/reactor.zig`

- `ctx` construction (line ~1150) adds `started`.
- `matchFast` path unchanged (dynamic templates have `response_bytes == null`).
  No other reactor change expected; the arena rendering works because the request
  arena is live until `reset()`.

### 8.3 `src/dsl/modules/access_log.zig`

Replace the ad-hoc `Token`/`parseFormat`/`fieldToken`/`formatTokenCount` machinery
with the general infra:
- `access_log` module reads `ctx.route.log_format` (index into
  `ctx`/`Config.log_formats`; modules can reach `log_formats` via a new
  `Context.formats: ?[]const LogFormat` field set by the reactor, or keep the
  default `combined` as a comptime const when the index is null). Default:
  `combined_format` remains as the index-0 `log_format` when none is declared.
- `run` renders the format's `[]const Frag` directly into the threadlocal line
  buffer via `renderComplex` with an `ArrayListSink` (drop the manual per-token
  switch and the duplicated date/ip/request formatting — the getters now own it).
- Keep the `logDate` helper and `monthNames` in `vars.zig` (moved) or re-exported.
- `$status`/`$bytes` now render via getters (scratch-backed).

### 8.4 `src/dsl/modules/proxy.zig`

- `sendUpstreamRequest`: after the existing headers, apply `route.proxy_headers`
  — each `{ name, value: []const Frag }` rendered via `renderComplex` into the
  same `out` ArrayList. Skip/override logic: proxy_set_header replaces the
  client-forwarded header of the same name (append only if the name isn't already
  emitted; keep the existing hop-by-hop skip list).
- `proxy_pass` single-upstream routes are just `upstreams.len == 1`.

---

## 9. Comptime branch budget handled by `validate` (locked refinement)

### 9.1 Problem

Comptime branch quota is shared across the whole compilation
(AGENTS.md). A large conf (many routes/regexes/variables) can blow the quota in
`parseConfComptime`, `compileRegex`, `parseComplexValue`, or the trie/dispatch
build — surfacing as a deep, cryptic "evaluated X branches at comptime and
exceeded the branch quota" error deep inside a stdlib or parser call, with no
actionable guidance.

### 9.2 Design

The **validate step owns the budget check**. In the comptime-only world the
validation entry point is `Config.comptimeValidate` (see §10), which is forced
`comptime` and invoked from `Server.comptimeInit`, `embeddedInit`,
`embeddedInitWithTls`, and `Config.default()`. It:

1. Performs the existing registry checks (module registered, phase bound once) —
   the logic of today's `Config.validate`, but at comptime.
2. **Measures the config's compile cost** using a cost counter the parser
   accumulates (see 9.3).
3. Compares cost against a budget-derived threshold and, when over, raises a
   single clear `@compileError` (below) — so budget pressure surfaces at
   `validate` time with the conf's name and an actionable fix, not as a random
   deep error.

Zig has no comptime *warning*; the "warning/error" the user wants is therefore
implemented as `@compileError` with a precise, actionable message.

### 9.3 Cost accounting

`parseConfComptime` maintains a `cost: usize` on the `Builder`, incremented with
cheap, deterministic units (no attempt to count real branches — approximate and
calibrated):

| Unit | Cost |
|---|---|
| conf byte scanned | 1 |
| directive parsed | 8 |
| location/server/tls block opened | 16 |
| complex-value fragment produced | 4 |
| regex pattern byte | 3 |
| regex NFA state emitted | 2 |
| route built | 32 |

`compileRegex` and `parseComplexValue` return/append their cost into the same
counter (they already run during parse, so thread it through or compute after the
fact by walking the built structures). Simple and robust: at the end of
`parseConfComptime`, recompute cost by walking the *built* `Config` (route count
× 32 + total regex state count × 2 + total fragment count × 4 + source length),
so the parser itself does not need threading — the validate step recomputes from
the frozen result. Prefer the recompute approach (less invasive).

### 9.4 Quota mechanism

- The comptime parser functions (`parseConfComptime`, `compileRegex`,
  `parseComplexValue`) keep their own `@setEvalBranchQuota` bumps. Expose one
  knob: a build option `-Dconfig_branch_quota=<n>` (default `100000`, the current
  `json_config` value), plumbed through `build.zig` `build_options` like
  `config_path` (§2.1) into a new `config_options` module the conf code imports.
- `comptimeValidate` reads `quota` and enforces
  `if (cost * safety_factor > quota) @compileError(...)` with
  `safety_factor ≈ 1/1.5` (i.e. fail when cost > ~66% of quota, leaving headroom
  for the rest of the compilation: trie build, dispatch assignment, the h2/tls
  comptime tables, and other parses sharing the same quota).
- Error text (format with `std.fmt.comptimePrint`):
  ```
  conf '<path>': config compile cost ~<cost> exceeds the comptime branch budget
  (<quota>, safety factor 1.5). Reduce the config (routes/regex/length) or raise
  the budget: zig build -Dconfig_branch_quota=<n>
  ```
- Because quota is shared per compilation, cost must be computed against the
  *same* compilation that parses the conf — since `comptimeValidate` is forced
  comptime and receives the built `Config`, and the conf is embedded via
  `@embedFile` in that same compilation, the accounting is self-consistent.

### 9.5 Calibration instructions (do this in M-A/M-D)

- Generate confs of increasing size (N routes, N regexes), build with
  `-Dconfig_branch_quota=100000`, and record where the raw quota error fires.
- Tune the per-unit costs (9.3) and `safety_factor` (9.4) so that `comptimeValidate`
  fires *before* the raw error for the same config (i.e. the validate error always
  leads the underlying budget error). Add a unit test that a deliberately huge
  synthetic conf triggers the validate error (comptime-tested via a build of a
  test fixture, not a `test` block — a comptime `@compileError` can be asserted
  with `zig build` against a fixture or via `@compileLog` checks).

---

## 10. Config API / entry points (`src/runtime/config.zig`)

Replace the JSON-facing API. Keep the struct-literal `Config{...}` API (tests use
it heavily).

```zig
pub fn default() Config          // plain struct literal (echo on "/", catch-all
                                 // prefix, content phase) — NO parse at all now
pub fn fromConfComptime(comptime text: []const u8) Config
pub fn fromConfEmbedded(comptime path: []const u8) Config
                                 // = fromConfComptime(@import("embeds").embed(path))
pub fn comptimeValidate(comptime cfg: Config, comptime Registry: type) void
                                 // registry checks (ex-validate logic, comptime)
                                 // + budget check (§9). Forced comptime.
```

- `default()`: a plain `Config{ .routes = &.{.{ .path = "/", .match = .prefix,
  .modules = &.{.{ .phase = .content, .module = "echo" }} }} }` — no parser call.
- `fromConfComptime` is the single new parser entry (`src/dsl/conf.zig`), modeled
  on `json_config.parse` (quota bump, `comptime` block, `Builder` + CtPools,
  `build(b) Config` freezing pools into `.rodata`). It also validates structural
  invariants at comptime: one `server`, no duplicate `log_format` names, no
  duplicate `set` names per location, unique (path, match) routes (the existing
  `comptimeCheckAmbiguous` still runs in `buildTrie`), regex patterns compile.
- `comptimeValidate` is called at the end of `comptimeInitImpl` /
  `embeddedInit` / `embeddedInitWithTls` / `default()` (§2.2). `Server.init(cfg)`
  (test/no-trie path) stays but skips the comptime budget check (it's not forced
  comptime); struct-literal configs in tests that want validation call
  `comptimeValidate` directly.
- `Config.validate(comptime Registry: type)` (runtime, existing) may be kept for
  struct-literal tests, or folded into `comptimeValidate`; keep both working.

---

## 11. Comptime-only migration & removals

### 11.1 Delete

- `src/runtime/json_config.zig` (whole file) and `src/runtime/json_config_tests.zig`.
- `Config.fromJson`, `Config.deinit`, `Config.fromJsonComptime`, `Config.fromEmbedded`
  (JSON), and the `Json*` structs in `src/runtime/config.zig` (§2.2).
- `Server.initWithTrie`, `Server.deinit`, `router.buildTrieRuntime`,
  `router.deinitTrie`, `Router.owned` (and its deinit), `Trie.alloc_nodes/
  alloc_edges` if only the runtime path used them.
- `src/main.zig`: `--config` flag, `--reload-soft`, the SIGHUP reparse function
  (line ~561+), the runtime-config load branches (~72–95, ~196, ~789); the CLI
  usage text (~40–55) drops `--config`/`--reload-soft`.
- `src/net/multireactor.zig`: SIGHUP soft-reload handler and reactor-set
  re-creation (lines 37, 175, 230, 515–531). SIGHUP is no longer handled (or is
  ignored); SIGTERM/SIGINT graceful stop stays.
- `config.example.json`, `src/testdata/config.example.json` (replaced by
  `.conf`). Any `@embedFile`/embedded references to them (e.g.
  `src/runtime/server.zig` tests lines 437–508, `src/http2/session.zig` line 1001,
  `src/net/reactor.zig` tests lines 2256/2421) must migrate.

### 11.2 Behavior notes

- `--reload-hard` stays and is now the **only** reload: it rebuilds with
  `-Doptimize=<state> -Dconfig=<state.config_path>`; a bad conf is a compile
  error and aborts the reload with the old daemon untouched (unchanged property,
  now even stronger: conf validation happens at compile time, before exec).
- Daemon state file (`<pidfile>.state`) keeps `config_path` etc. unchanged;
  drop any `mode`/`embedded` nuance only if trivial.
- `zig build -Dconfig=` now expects a `.conf` file (extension-agnostic; docs say
  `.conf`).

---

## 12. build.zig / main.zig / daemon wiring

- `build.zig` (lines 38–46): rename the option help text to "conf file",
  add `b.option(usize, "config_branch_quota", ...)` → a `config_options` module
  exporting `pub const branch_quota: usize`. Wire the module into the `zocket`
  module imports and the exe.
- `src/main.zig`:
  - `-Dconfig` path: `Config.fromConfEmbedded(embed_path)` + `comptimeInit`
    (comptime budget check runs inside).
  - Remove runtime-config branches and reload-soft (§11.1).
  - `--port` CLI still overrides a config `listen` when both are present.
- `docs/config.md`: rewritten for the conf language (or folded into
  `docs/conf.md`; keep `docs/config.md` as the canonical reference pointing to
  `docs/conf.md` for syntax + directive reference).
- `AGENTS.md`: update the commands/`-Dconfig`/reload sections (drop `--config`,
  `--reload-soft`; note `.conf`, budget knob, validate-owned budget check).

---

## 13. File-by-file change list

**New files**
- `src/dsl/conf.zig` — tokenizer + directive registry + recursive-descent parser
  + `Builder` (CtPools: routes, modules, headers, upstreams, strings, frags,
  set_vars, proxy_headers, regexes, log_formats) + `build(b) Config` +
  `parseConfComptime(comptime text) Config` (+ recomputed cost for §9).
- `src/dsl/vars.zig` — `Frag`, `VarId`, `LogFormat`, `SetVar`, built-in getters,
  `parseComplexValue`, `renderComplex`/`renderComplexArena`, sinks, moved
  `logDate`/`monthNames`, `max_user_vars`.
- `src/dsl/regex.zig` — `Regex`, `State`, `compileRegex`, `match`,
  case-insensitive wrapper, tests.
- `config.example.conf` — the §3.2 example (matches the semantics of the old
  `config.example.json` where possible).
- `docs/conf.md` — language reference: grammar, directive table, variable catalog,
  regex subset, examples.
- `docs/plan.md` — this document.

**Modified**
- `src/runtime/config.zig` — §10 API, drop JSON, add `listen_port`/`log_formats`.
- `src/dsl/router.zig` — §4.1/§7: Match, Route fields, regex table, precedence,
  `MatchCaps`, trie skip-regex, delete runtime trie fns.
- `src/dsl/registry.zig` — §4.5 Context fields, `CaptureRange`; `Context.formats`.
- `src/dsl/pipeline.zig` — §8.1 MatchCaps wiring, `applyTemplateCV`.
- `src/dsl/modules/access_log.zig` — §8.3.
- `src/dsl/modules/proxy.zig` — §8.4.
- `src/runtime/server.zig` — §10/§11: `comptimeValidate` calls, drop JSON/runtime
  trie, migrate tests to struct literals/conf.
- `src/net/reactor.zig` — `ctx.started`; migrate JSON tests (lines 2256, 2421).
- `src/net/multireactor.zig` — remove SIGHUP reload.
- `src/main.zig`, `build.zig` — §12.
- `src/root.zig` — re-export `dsl.conf`, `dsl.vars`, `dsl.regex` AND add
  `_ = @import("dsl/conf.zig"); _ = @import("dsl/vars.zig");
  _ = @import("dsl/regex.zig");` to the comptime test-collection block.
- `embeds.zig` — unchanged (conf embeds through it).
- Tests across `server.zig`/`reactor.zig`/`http2/session.zig` that call
  `fromJsonComptime`/`fromJson` — migrate to struct literals or `fromConfComptime`.

**Deleted**
- `src/runtime/json_config.zig`, `src/runtime/json_config_tests.zig`,
  `config.example.json`, `src/testdata/config.example.json`
  (replace with `src/testdata/config.example.conf` if tests need an embedded conf
  fixture), and the runtime-only code paths in §11.1.

---

## 14. Milestones & implementation order

Each milestone ends green on `zig build test`. Do not move on until the previous
one is fully green.

### M-A — Conf language core
- `src/dsl/conf.zig`: tokenizer (tokens, sizes, `on|off`, comments, line/col
  errors), directive registry, global directives, `tls`, `log_format` (as plain
  strings for now — complex-value wiring is M-B), `server`/`location`, phase
  directives, all non-variable route directives, `listen`.
- `Config` API (§10): `fromConfComptime`, `fromConfEmbedded`, `default()` as
  struct literal, `comptimeValidate` (registry checks only, budget stub).
- §9 cost accounting + quota knob + budget check (calibrate with synthetic confs).
- §11 removals (JSON path, `--config`, reload-soft, SIGHUP) + §12 wiring +
  docs + migrate all existing tests/examples to struct literals or conf.
- New conf tests: tokenizer, sizes, unknown-directive/phase/dup-`log_format`
  errors, `server`-count error, `Config.default()` parity with the old default.

### M-B — Complex values & variables
- `src/dsl/vars.zig`: `Frag`, `VarId`, getters, `parseComplexValue`, sinks,
  `renderComplex(Arena)`.
- `return`/`add_header`/`log_format` accept complex values; literal-only templates
  keep `response_bytes` fast path; `matchFast` unchanged.
- `access_log` rewritten on `LogFormat` + fragments (§8.3).
- Tests: parse of `"$host/$request_uri $http_user_agent"`, render vs
  hand-built expected bytes, unknown-var compile error, `$$` escape, braced
  names, `http_`/`arg_`/`cookie_` hashing + lookup, zero-copy/literal-fragment
  alias checks.

### M-C — User variables (`set`)
- Per-route `set_vars` (slot assignment), lazy arena render into
  `ctx.user_slots`, `.user` fragment resolution, `max_user_vars` cap error,
  forward-reference error.
- Tests: render-once caching (two references produce one render), scope errors,
  use in `return`/`add_header`/`log_format`.

### M-D — Regex engine + location matching
- `src/dsl/regex.zig` (§6) with exhaustive matcher tests (feature matrix,
  anchors, quantifiers, classes, alternation, captures, malformed-pattern
  compile errors).
- Router precedence (§7): `~`/`~*`/`^~`, regex table, `MatchCaps`, captures into
  `ctx`, `$1..$9` usable in complex values, trie excludes regex routes, linear
  fallback parity.
- Tests: nginx precedence table (exact / `^~` / regex-order / longest-prefix /
  404), captures correctness, `~*` case folding.

### M-E — proxy_set_header + audit + bench
- `proxy_set_header` rendering (§8.4).
- Full `zig build test`, `zig build h2test` (variables render off `Request`; verify
  h2 requests work — they populate `Request` via `addHeaderParsed`),
  `-Doptimize=ReleaseFast` build.
- Bench A/B against the pre-change tree (the AGENTS.md M4 constraint: pipeline
  overhead <5%). Conf path removes startup parse (strictly faster at startup);
  ensure the fragment render loop stays allocation-free on the log/proxy hot
  paths, and that literal-only templates still hit `matchFast`.

### Future milestones (not this effort)
- `rewrite <regex> <replacement> <last|break>` module (re-dispatch via
  find_config on the rewritten `$uri`).
- `if (cond) { }` module (comparisons: `=`/`!=` on variables, `~`/`~*` regex
  tests, `-f`/`!-f` file tests).
- Named upstream groups (`upstream name { server host:port; ... }`), `map`,
  `geo`, vhost multi-`server`.

---

## 15. Test plan

- **Parser** (`src/dsl/conf.zig`): tokenizer; size suffix parsing; quoted strings
  + escapes; `on|off`; comments; line/col on errors; every directive mapping to
  the right field; unknown directive/key/modifier errors; missing `server`;
  multiple `server`; duplicate `log_format` name; duplicate `set` name;
  forward/unknown variable refs; `$1..$9` out of capture context renders `""`.
  Use `comptime { _ = parseConfComptime(...) }` blocks for parse-error fixtures,
  or assert with `std.testing` on `fromConfComptime` success cases (parse errors
  are `@compileError`, so they are asserted by *build* failures — a fixture build
  step or `@compileError`-containing `comptime` blocks; see §9.5 for the budget
  fixture).
- **vars**: parse/render round trips for every builtin; generic `http_`/`arg_`/
  `cookie_`; `set` caching; `$$`; braced names; scratch-backed digit getters.
- **regex**: feature matrix vs hand-written expectations; worst-case simple
  pathological patterns (`(a|a)*a` on `aaaa...`) to keep time bounded in tests;
  malformed pattern compile errors.
- **router**: precedence table incl. `^~` and regex ordering; capture recording;
  trie excludes regex; linear fallback parity (reuse the existing
  "comptime trie agrees with the linear matcher" test pattern).
- **pipeline/integration**: dynamic-template routes render correctly end to end;
  literal routes still serve `response_bytes`; `access_log` with a custom
  `log_format`; proxy `proxy_set_header`; reactor-level tests (extend the
  existing `src/net/reactor.zig` harness) exercising a regex route + captures +
  variable template over a real socket.
- **budget**: fixture conf sized to trip §9.4; assert the validate error text via
  a build fixture.
- Keep the total test count growing in the inline-`test` style of the codebase;
  every new module's tests must be reachable through `src/root.zig`'s comptime
  import block (see §2.3).

---

## 16. Migration checklist (existing tests/examples)

- `src/runtime/server.zig` tests using `Config.fromJson(...)` /
  `fromJsonComptime` / `fromEmbedded` (lines ~211, 232, 320, 437–508, 511, 534):
  rewrite as struct-literal `Config` or `fromConfComptime` strings.
- `src/http2/session.zig` line ~1001: `Config.fromJsonComptime(...)` →
  struct literal or conf.
- `src/net/reactor.zig` tests lines 2256, 2421 and `src/net/multireactor.zig`
  line 472: JSON configs → conf/struct literals.
- `src/testdata/config.example.json` → `.conf` (used by the embedded-config
  parity test in `server.zig`; keep a parity test: embedded conf vs the same
  config as a struct literal produce identical routing).
- `config.example.json` → `config.example.conf` (root; used by README/AGENTS
  examples).
- `docs/config.md`, README, `docs/milestones.md`, `docs/ROADMAP.md`,
  `AGENTS.md`: update config references, command examples (`-Dconfig=...conf`),
  drop `--config`/`--reload-soft` mentions.
- Bench scripts (`bench/*.sh`) that launch with `--config` — update to
  `-Dconfig` or drop the flag; keep default-mode benches unchanged.

---

## 17. Risks & notes

- **Comptime budget** is the top risk; §9 owns it. Calibrate early (M-A) and
  re-calibrate when regex lands (M-D) since NFA emission is the priciest unit.
- **`@embedFile` reach**: conf paths must stay inside the project tree (existing
  reload-hard constraint). Document in `docs/conf.md` and AGENTS.md.
- **h2 parity**: variables/captures/templates must behave identically over h2
  (`zig build h2test`). h2 populates `Request` via `addHeaderParsed`; `$http_*`
  and `decoded_target`/`query_string` need h2 to keep populating those fields
  (verify; h2 session may not set `query_string` — if so, `$args` renders `""`
  over h2; acceptable and documented).
- **`.` vs `\n`**: `.` excludes `\n` (POSIX-ish). URIs are single-line; document.
- **Greedy-only quantifiers**: document that lazy modifiers are unsupported;
  config authors write greedy forms.
- **`$request_time`** requires `Instant.now()` at request start; on failure it
  renders `0`. The reactor ctx already exists; adding `started` is one field.
- **Keep the M4 overhead constraint**: the fragment render loop is hot only for
  routes that actually use variables. Ensure `matchFast` still covers the common
  literal case with zero added cost (its gate is unchanged).