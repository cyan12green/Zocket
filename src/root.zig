pub const net = @import("net/server.zig");
pub const server = @import("net/server.zig");
pub const multireactor = @import("net/multireactor.zig");
pub const reactor = @import("net/reactor.zig");
pub const dispatcher = @import("net/dispatcher.zig");
pub const eventfd = @import("net/eventfd.zig");
pub const sockets = @import("net/sockets.zig");
pub const buffer = @import("net/buffer.zig");
pub const connection = @import("net/connection.zig");
pub const timer_wheel = @import("net/timer_wheel.zig");
pub const epoll = @import("net/epoll.zig");
pub const ct_pool = @import("ct_pool.zig");
pub const iouring = @import("net/iouring.zig");
pub const version = @import("version.zig");

pub const http = struct {
    pub const mime = @import("http/mime.zig");
    pub const parser = @import("http/parser.zig");
    pub const response = @import("http/response.zig");
    pub const header_dfa = @import("http/header_dfa.zig");
    pub const websocket = @import("http/websocket.zig");
    pub const shmem = @import("dsl/shmem.zig");
    pub const arena = @import("http/arena.zig");
};

pub const tls = struct {
    pub const conn = @import("tls/conn.zig");
    pub const session = @import("tls/session.zig");
    pub const handshake = @import("tls/handshake.zig");
    pub const record = @import("tls/record.zig");
    pub const keyschedule = @import("tls/keyschedule.zig");
    pub const cert = @import("tls/cert.zig");
    pub const pem = @import("tls/pem.zig");
    pub const testdata = @import("tls/testdata.zig");
};
pub const http2 = struct {
    pub const hpack = @import("http2/hpack.zig");
    pub const frames = @import("http2/frames.zig");
    pub const session = @import("http2/session.zig");
};

pub const fuzz = @import("fuzz.zig");

pub const dsl = struct {
    pub const static_cache = @import("dsl/static_cache.zig");
    pub const limits = @import("dsl/limits.zig");
    pub const phase = @import("dsl/phase.zig");
    pub const router = @import("dsl/router.zig");
    pub const registry = @import("dsl/registry.zig");
    pub const pipeline = @import("dsl/pipeline.zig");
    pub const conf = @import("dsl/conf.zig");
    pub const vars = @import("dsl/vars.zig");
    pub const regex = @import("dsl/regex.zig");
    pub const modules = struct {
        pub const echo = @import("dsl/modules/echo.zig");
        pub const gzip = @import("dsl/modules/gzip.zig");
        pub const cache = @import("dsl/modules/cache.zig");
        pub const static = @import("dsl/modules/static.zig");
        pub const proxy = @import("dsl/modules/proxy.zig");
        pub const access_log = @import("dsl/modules/access_log.zig");
        pub const error_log = @import("dsl/modules/error_log.zig");
        pub const stub_status = @import("dsl/modules/stub_status.zig");
    };
};

pub const runtime = struct {
    pub const config = @import("runtime/config.zig");
    pub const server = @import("runtime/server.zig");
};

// This Zig snapshot only collects `test` blocks that are reachable through
// comptime imports from the test root file; plain `pub const` imports of
// submodules are analyzed lazily and their tests are skipped. Pull every
// submodule in explicitly so `zig build test` actually runs their tests.
comptime {
    _ = @import("net/buffer.zig");
    _ = @import("net/connection.zig");
    _ = @import("net/timer_wheel.zig");
    _ = @import("net/epoll.zig");
    _ = @import("net/eventfd.zig");
    _ = @import("net/sockets.zig");
    _ = @import("net/server.zig");
    _ = @import("net/dispatcher.zig");
    _ = @import("net/reactor.zig");
    _ = @import("net/multireactor.zig");
    _ = @import("http/parser.zig");
    _ = @import("http/response.zig");
    _ = @import("http/mime.zig");
    _ = @import("http/header_dfa.zig");
    _ = @import("http/websocket.zig");
    _ = @import("dsl/modules/headers.zig");
    _ = @import("dsl/modules/auth_basic.zig");
    _ = @import("dsl/modules/limit.zig");
    _ = @import("dsl/shmem.zig");
    _ = @import("dsl/modules/precompressed.zig");
    _ = @import("dsl/modules/auth_request.zig");
    _ = @import("dsl/htpasswd.zig");
    _ = @import("http/arena.zig");
    _ = @import("http2/hpack.zig");
    _ = @import("http2/frames.zig");
    _ = @import("http2/session.zig");
    _ = @import("fuzz.zig");
    _ = @import("dsl/static_cache.zig");
    _ = @import("dsl/limits.zig");
    _ = @import("ct_pool.zig");
    _ = @import("net/iouring.zig");
    _ = @import("version.zig");
    _ = @import("dsl/phase.zig");
    _ = @import("dsl/router.zig");
    _ = @import("dsl/registry.zig");
    _ = @import("dsl/pipeline.zig");
    _ = @import("dsl/conf.zig");
    _ = @import("dsl/vars.zig");
    _ = @import("dsl/regex.zig");
    _ = @import("dsl/modules/echo.zig");
    _ = @import("dsl/modules/gzip.zig");
    _ = @import("dsl/modules/cache.zig");
    _ = @import("dsl/modules/static.zig");
    _ = @import("dsl/modules/proxy.zig");
    _ = @import("dsl/modules/access_log.zig");
    _ = @import("dsl/modules/error_log.zig");
    _ = @import("dsl/modules/stub_status.zig");
    _ = @import("runtime/config.zig");
    _ = @import("runtime/server.zig");
    _ = @import("tls/pem.zig");
    _ = @import("tls/keyschedule.zig");
    _ = @import("tls/record.zig");
    _ = @import("tls/cert.zig");
    _ = @import("tls/handshake.zig");
    _ = @import("tls/session.zig");
}
