# Ziglet configuration

Ziglet is configured at startup with `--config <file.json>`. The config has
two sections: `routes` (the nginx-style location/phase mapping) and
`limits` (runtime-tunable sizes and caps — nginx's `http{}`/`server{}`
directive equivalents). Any `limits` field may be omitted; the compiled
defaults apply. See `config.example.json` for a complete sample.

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

Startup: `zig build run -- --config config.json`. For the other run modes
see the README.
