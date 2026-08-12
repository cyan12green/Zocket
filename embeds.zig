/// Comptime-embedded assets (Milestone 10). A route's `embed` path is
/// relative to the project root; this file lives at the root (outside src/)
/// so `@embedFile` resolves it there. Wired into the build as the `embeds`
/// module.
pub fn embed(comptime path: []const u8) []const u8 {
    return @embedFile(path);
}
