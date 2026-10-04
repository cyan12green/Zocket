// Coverage driver: proxy module only, for fast iteration. Pulls the
// transitive deps of dsl/modules/proxy.zig's tests.
comptime {
    _ = @import("dsl/modules/proxy.zig");
    _ = @import("dsl/registry.zig");
    _ = @import("dsl/router.zig");
    _ = @import("compat.zig");
}
