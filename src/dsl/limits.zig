const std = @import("std");

/// Runtime-tunable server limits (nginx-style): sizes and caps that used to
/// be comptime constants. Carried on the Config as the `limits` section;
/// the reactor applies them to connections, parsers, caches and pools.
/// The values below are the compiled defaults (nginx also ships defaults).
pub const Limits = struct {
    /// Byte budget for the proxy_cache response zone (0 = built-in default).
    proxy_cache_max_bytes: usize = 0,
    /// Entry ceiling for the proxy_cache zone (0 = built-in default 256).
    proxy_cache_max_entries: usize = 0,
    /// Total wall time allowed for the request line + headers, regardless
    /// of activity — the anti-slowloris teeth (dribbling bytes resets the
    /// idle timer but not this deadline). nginx's client_header_timeout is
    /// inactivity-based; this is deliberately stricter. 0 disables.
    client_header_timeout_s: u64 = 10,
    /// Inactivity gap tolerated between request-body bytes (nginx
    /// client_body_timeout semantics). 0 leaves the idle timeout only.
    client_body_timeout_s: u64 = 30,
    /// Initial per-connection receive buffer size.
    recv_buffer_size: usize = 16384,
    /// Initial per-connection send buffer size.
    send_buffer_size: usize = 16384,
    /// Largest request body the server buffers (the recv-buffer growth cap;
    /// requests beyond it are rejected with 431). nginx: client_max_body_size.
    max_body: usize = 16 * 1024 * 1024,
    /// Longest request line / header line (431). nginx: large_client_header_buffers.
    max_line_bytes: usize = 8 * 1024,
    /// Maximum number of request headers (431). nginx: (no direct knob; hard cap).
    max_headers: usize = 32,
    /// Largest chunked request body (413). nginx: client_max_body_size.
    max_chunked_body: usize = 64 * 1024,
    /// Static fd-cache size. nginx: open_file_cache max=N.
    static_cache_entries: usize = 16,
    /// Static cache revalidation window in seconds. nginx: open_file_cache_valid.
    static_cache_valid_seconds: u64 = 1,
    /// Files at most this large are content-cached and served as one writev
    /// (larger ones via sendfile). nginx: sendfile_max_chunk-ish.
    static_content_cache_max: usize = 16384,
    /// Recycled connections held by the per-reactor pool.
    connection_pool_max: usize = 1024,
};
