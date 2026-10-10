// Coverage driver: cov_reactor area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("sys.zig");
    _ = @import("net/reactor.zig");
    _ = @import("net/multireactor.zig");
    _ = @import("fuzz.zig");
}
