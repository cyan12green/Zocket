// Coverage driver: cov_http area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("compat.zig");
    _ = @import("http/parser.zig");
    _ = @import("http/response.zig");
    _ = @import("http/arena.zig");
    _ = @import("http/mime.zig");
    _ = @import("http/header_dfa.zig");
    _ = @import("http/websocket.zig");
}
