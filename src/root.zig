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

pub const http = struct {
    pub const parser = @import("http/parser.zig");
    pub const response = @import("http/response.zig");
};

pub const dsl = struct {
    pub const phase = @import("dsl/phase.zig");
    pub const router = @import("dsl/router.zig");
    pub const registry = @import("dsl/registry.zig");
    pub const pipeline = @import("dsl/pipeline.zig");
    pub const modules = struct {
        pub const echo = @import("dsl/modules/echo.zig");
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
    _ = @import("dsl/phase.zig");
    _ = @import("dsl/router.zig");
    _ = @import("dsl/registry.zig");
    _ = @import("dsl/pipeline.zig");
    _ = @import("dsl/modules/echo.zig");
    _ = @import("runtime/config.zig");
    _ = @import("runtime/server.zig");
}
