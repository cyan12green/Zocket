// Coverage driver: cov_http2 area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("compat.zig");
    _ = @import("http2/hpack.zig");
    _ = @import("http2/frames.zig");
    _ = @import("http2/session.zig");
}
