// Coverage driver: cov_dsl area. See `zig build cov`.
// Imports the area's files so their `test` blocks run in a
// small binary kcov can instrument (the monolith is too big).
comptime {
    _ = @import("compat.zig");
    _ = @import("ct_pool.zig");
    _ = @import("dsl/phase.zig");
    _ = @import("dsl/router.zig");
    _ = @import("dsl/registry.zig");
    _ = @import("dsl/pipeline.zig");
    _ = @import("dsl/conf.zig");
    _ = @import("dsl/vars.zig");
    _ = @import("dsl/regex.zig");
    _ = @import("dsl/shmem.zig");
    _ = @import("dsl/memfd.zig");
    _ = @import("dsl/static_cache.zig");
    _ = @import("dsl/limits.zig");
    _ = @import("dsl/testing.zig");
    _ = @import("dsl/htpasswd.zig");
    _ = @import("dsl/modules/echo.zig");
    _ = @import("dsl/modules/gzip.zig");
    _ = @import("dsl/modules/cache.zig");
    _ = @import("dsl/modules/static.zig");
    _ = @import("dsl/modules/proxy.zig");
    _ = @import("dsl/modules/access_log.zig");
    _ = @import("dsl/modules/error_log.zig");
    _ = @import("dsl/modules/stub_status.zig");
    _ = @import("dsl/modules/headers.zig");
    _ = @import("dsl/modules/auth_basic.zig");
    _ = @import("dsl/modules/auth_request.zig");
    _ = @import("dsl/modules/limit.zig");
    _ = @import("dsl/modules/precompressed.zig");
    _ = @import("dsl/modules/proxy_cache.zig");
}
