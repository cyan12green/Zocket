// Coverage driver: cov_net area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("compat.zig");
    _ = @import("net/server.zig");
    _ = @import("net/buffer.zig");
    _ = @import("net/connection.zig");
    _ = @import("net/timer_wheel.zig");
    _ = @import("net/eventfd.zig");
    _ = @import("net/epoll.zig");
    _ = @import("net/sockets.zig");
    _ = @import("net/dispatcher.zig");
    _ = @import("net/iouring.zig");
    _ = @import("net/body_storage.zig");
    _ = @import("net/proxy_proto.zig");
    _ = @import("net/dns.zig");
    _ = @import("net/dns_resolver.zig");
}
