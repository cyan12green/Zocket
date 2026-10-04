const std = @import("std");

/// MIME type lookup for static-file serving. The extension table is a
/// comptime constant; `mimeForExtension` is an inline-for over it, so every
/// comparison is compile-time-constant and the compiler emits a direct jump
/// (switch) with zero runtime map lookups. A compile-time-known extension
/// folds the whole call to a string literal.
const Table = struct { ext: []const u8, mime: []const u8 };

const table = [_]Table{
    .{ .ext = "html", .mime = "text/html" },
    .{ .ext = "htm", .mime = "text/html" },
    .{ .ext = "css", .mime = "text/css" },
    .{ .ext = "js", .mime = "application/javascript" },
    .{ .ext = "mjs", .mime = "application/javascript" },
    .{ .ext = "json", .mime = "application/json" },
    .{ .ext = "txt", .mime = "text/plain" },
    .{ .ext = "xml", .mime = "application/xml" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "webm", .mime = "video/webm" },
    .{ .ext = "mp3", .mime = "audio/mpeg" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "zip", .mime = "application/zip" },
    .{ .ext = "gz", .mime = "application/gzip" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "ttf", .mime = "font/ttf" },
};

/// MIME type for a file extension (without the leading dot, lower-case), or
/// the octet-stream default when the extension is unknown or absent.
pub fn mimeForExtension(ext: []const u8) []const u8 {
    inline for (table) |entry| {
        if (std.mem.eql(u8, ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

/// MIME type for a file path: the part after the last '.' in the final path
/// segment, lower-cased (pass a query-stripped, percent-decoded path).
pub fn mimeForPath(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.indexOfScalar(u8, p, '?')) |qi| p = p[0..qi];
    const name = std.fs.path.basename(p);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    const ext = name[dot + 1 ..];
    if (std.mem.indexOfAny(u8, ext, "/\\") != null) return "application/octet-stream";
    var lower: [16]u8 = undefined;
    if (ext.len <= lower.len) {
        for (ext, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        return mimeForExtension(lower[0..ext.len]);
    }
    return "application/octet-stream";
}

const testing = std.testing;

test "known extensions resolve to the right MIME type" {
    try testing.expectEqualStrings("text/html", mimeForExtension("html"));
    try testing.expectEqualStrings("text/html", mimeForExtension("htm"));
    try testing.expectEqualStrings("application/json", mimeForExtension("json"));
    try testing.expectEqualStrings("image/png", mimeForExtension("png"));
    try testing.expectEqualStrings("application/wasm", mimeForExtension("wasm"));
}

test "unknown or empty extensions get the octet-stream default" {
    try testing.expectEqualStrings("application/octet-stream", mimeForExtension(""));
    try testing.expectEqualStrings("application/octet-stream", mimeForExtension("exe"));
    try testing.expectEqualStrings("application/octet-stream", mimeForExtension("noext"));
}

test "mimeForPath handles full paths, dotfiles and case" {
    try testing.expectEqualStrings("text/html", mimeForPath("/var/www/index.html"));
    try testing.expectEqualStrings("image/jpeg", mimeForPath("dir/a.JPG"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/noextension"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/dir/.hidden"));
    try testing.expectEqualStrings("text/css", mimeForPath("/dir/style.css?x=1"));
}

test "comptime-known extension folds to a literal" {
    try testing.expectEqualStrings("text/plain", comptime mimeForExtension("txt"));
}

test "extension table has no duplicates" {
    var seen = std.ArrayList([]const u8).empty;
    defer seen.deinit(testing.allocator);
    inline for (table) |entry| {
        for (seen.items) |e| {
            try testing.expect(!std.mem.eql(u8, e, entry.ext));
        }
        try seen.append(testing.allocator, entry.ext);
    }
}

test "every table entry resolves to its own MIME type" {
    inline for (table) |entry| {
        try testing.expectEqualStrings(entry.mime, mimeForExtension(entry.ext));
    }
    // Case-sensitive: upper-case extensions miss (callers lowercase first).
    try testing.expectEqualStrings("application/octet-stream", mimeForExtension("HTML"));
    try testing.expectEqualStrings("application/octet-stream", mimeForExtension("Text"));
}

test "mimeForPath edge cases: long extensions, dots and queries" {
    // Extension longer than the lowercase scratch falls back to default.
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/dir/file.abcdefghijklmnopq"));
    // Query strings strip before lookup; case folds.
    try testing.expectEqualStrings("text/html", mimeForPath("/dir/page.HTML?v=2"));
    // A dotfile with a real extension still resolves.
    try testing.expectEqualStrings("text/plain", mimeForPath("/dir/.hidden.txt"));
    // Trailing dot means an empty extension.
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/dir/file."));
    // Multi-dot paths use the last extension.
    try testing.expectEqualStrings("application/gzip", mimeForPath("/dir/archive.tar.gz"));
}
