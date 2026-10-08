// Coverage driver: cov_tls area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("compat.zig");
    _ = @import("tls/conn.zig");
    _ = @import("tls/session.zig");
    _ = @import("tls/handshake.zig");
    _ = @import("tls/record.zig");
    _ = @import("tls/keyschedule.zig");
    _ = @import("tls/cert.zig");
    _ = @import("tls/pem.zig");
    _ = @import("tls/testdata.zig");
    _ = @import("tls/tickets.zig");
    _ = @import("tls/ocsp.zig");
}
