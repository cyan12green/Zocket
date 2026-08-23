//! htpasswd file parsing for the auth_basic module (nginx
//! `auth_basic_user_file` equivalent). The file is embedded at comptime
//! (`auth_basic_user_file` resolves through the embeds module like static
//! `embed` paths) and parsed into a fixed entry table in .rodata — no
//! runtime parsing, no allocator.
//!
//! Supported hash formats (one `user:secret` per line, `#` comments):
//!   plaintext           user:password            (tests / internal only)
//!   {SHA}               user:{SHA}base64(sha1)   (apr1's portable cousin)
//!   bcrypt              user:$2a$/$2b$/$2y$...   (htpasswd -B default)

const std = @import("std");
const ct_pool = @import("../ct_pool.zig");

pub const Kind = enum { plain, sha1, bcrypt };

pub const Entry = struct {
    user: []const u8,
    kind: Kind,
    /// plaintext password, base64 sha1 digest, or the crypt-format bcrypt
    /// string (kind-dependent).
    secret: []const u8,
};

/// Comptime-parse an htpasswd file body into a frozen entry table.
/// Malformed lines (no colon) are skipped, matching nginx's tolerance of
/// junk lines rather than failing a whole deployment over one.
pub fn parse(comptime text: []const u8) []const Entry {
    @setEvalBranchQuota(100000);
    return comptime blk: {
        var pool = ct_pool.CtPool(Entry, countLines(text)){};
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const user = line[0..colon];
            const rest = line[colon + 1 ..];
            if (user.len == 0 or rest.len == 0) continue;
            const entry: Entry = if (std.mem.startsWith(u8, rest, "{SHA}"))
                .{ .user = user, .kind = .sha1, .secret = rest["{SHA}".len..] }
            else if (rest.len > 3 and rest[0] == '$' and rest[1] == '2')
                .{ .user = user, .kind = .bcrypt, .secret = rest }
            else
                .{ .user = user, .kind = .plain, .secret = rest };
            _ = pool.create(entry);
        }
        break :blk pool.freeze();
    };
}

fn countLines(text: []const u8) usize {
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Verify a candidate password against one entry. Timing-safe for plain and
/// sha1; bcrypt goes through std.crypto.pwhash.
pub fn verify(entry: Entry, password: []const u8) bool {
    switch (entry.kind) {
        .plain => return std.crypto.timing_safe.eql([1]u8, .{@intFromBool(std.mem.eql(u8, entry.secret, password))}, .{1}),
        .sha1 => {
            var digest: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(password, &digest, .{});
            var b64_buf: [28]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(&b64_buf, &digest);
            // Length differs -> not equal; eql on equal-length bytes.
            if (encoded.len != entry.secret.len) return false;
            return std.crypto.timing_safe.eql([1]u8, .{@intFromBool(std.mem.eql(u8, encoded, entry.secret))}, .{1});
        },
        .bcrypt => {
            std.crypto.pwhash.bcrypt.strVerify(entry.secret, password, .{
                .silently_truncate_password = true,
            }) catch return false;
            return true;
        },
    }
}

/// Look a user up and verify their password; returns false for unknown
/// users too (same answer either way — no user enumeration timing split).
pub fn authenticate(entries: []const Entry, user: []const u8, password: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.user, user)) return verify(e, password);
    }
    return false;
}

const testing = std.testing;

test "parse skips comments and junk, classifies all three kinds" {
    const entries = comptime parse(
        \\# comment line
        \\alice:password123
        \\bob:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
        \\carol:$2y$05$/ZOB4fPQ7vJkVTO9nFv6C.ghTdcHh4sFfEGrACsRSTUuB9jUQO8Iy
        \\this-line-has-no-colon
        \\
    );
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(Kind.plain, entries[0].kind);
    try testing.expectEqualStrings("alice", entries[0].user);
    try testing.expectEqual(Kind.sha1, entries[1].kind);
    try testing.expectEqual(Kind.bcrypt, entries[2].kind);
}

test "verify accepts correct passwords and rejects wrong ones" {
    const entries = comptime parse(
        \\alice:password123
        \\bob:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
    );
    // bob's {SHA} is the well-known digest of "password".
    try testing.expect(authenticate(entries, "bob", "password"));
    try testing.expect(!authenticate(entries, "bob", "Password"));
    try testing.expect(authenticate(entries, "alice", "password123"));
    try testing.expect(!authenticate(entries, "alice", ""));
    // Unknown user: same false as a wrong password.
    try testing.expect(!authenticate(entries, "mallory", "anything"));
}

test "bcrypt round-trips through strHash" {
    const allocator = testing.allocator;
    const Hasher = std.crypto.pwhash.bcrypt;
    var hash_buf: [Hasher.hash_length * 2]u8 = undefined;
    const hash = try Hasher.strHash("s3cr3t", .{
        .allocator = allocator,
        .params = .{ .rounds_log = 4, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &hash_buf);
    const entry = Entry{ .user = "dave", .kind = .bcrypt, .secret = hash };
    try testing.expect(verify(entry, "s3cr3t"));
    try testing.expect(!verify(entry, "wrong"));
}
