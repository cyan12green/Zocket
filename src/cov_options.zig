// Stub `config_options` module for the coverage drivers (`zig build cov`).
// The real build generates this via `b.addOptions()` (branch quota for the
// comptime conf parser); drivers need the same constant. Keep in sync with
// build.zig's `config_branch_quota` default.
pub const branch_quota: usize = 100000;
