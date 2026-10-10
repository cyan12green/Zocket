// Coverage driver: cov_rt area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("sys.zig");
    _ = @import("runtime/config.zig");
    _ = @import("runtime/server.zig");
}
