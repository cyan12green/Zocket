pub const net = @import("net/server.zig");
pub const server = @import("net/server.zig");
pub const multireactor = @import("net/multireactor.zig");
pub const reactor = @import("net/reactor.zig");
pub const dispatcher = @import("net/dispatcher.zig");
pub const eventfd = @import("net/eventfd.zig");
pub const sockets = @import("net/sockets.zig");
pub const buffer = @import("net/buffer.zig");
pub const connection = @import("net/connection.zig");
pub const epoll = @import("net/epoll.zig");

// This Zig snapshot only collects `test` blocks that are reachable through
// comptime imports from the test root file; plain `pub const` imports of
// submodules are analyzed lazily and their tests are skipped. Pull every
// submodule in explicitly so `zig build test` actually runs their tests.
comptime {
    _ = @import("net/buffer.zig");
    _ = @import("net/connection.zig");
    _ = @import("net/epoll.zig");
    _ = @import("net/eventfd.zig");
    _ = @import("net/sockets.zig");
    _ = @import("net/server.zig");
    _ = @import("net/dispatcher.zig");
    _ = @import("net/reactor.zig");
    _ = @import("net/multireactor.zig");
}
