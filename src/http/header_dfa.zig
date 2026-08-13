const std = @import("std");
const ct_pool = @import("../ct_pool.zig");

/// Comptime-built DFA for classifying HTTP header names.
///
/// The transition table is a trie over the known header-name set, generated
/// entirely at compile time into `.rodata`. Classifying a wire header name is
/// one array lookup per byte (the alphabet is mapped to a dense index, with
/// ASCII letters lower-cased so classification is case-insensitive), and the
/// terminal state directly yields the name's tag — no hash computation, no
/// string comparison, no collision handling. Names outside the set (or
/// near-misses like `content-length-x`) land on the "unknown" tag.
///
/// This is the Milestone-8 lookup structure in state-machine form: the same
/// role as `parser.header_hasher` (which remains for the response-side
/// modules), but classification is exact and one pass.

/// Alphabet classes: 'a'-'z' (0-25, lower-cased), '0'-'9' (26-35), '-' (36),
/// and everything else (37, can never match a known name).
pub const alphabet_width = 38;
pub const invalid_class: u8 = alphabet_width - 1;

/// Index into the transition table; no_state marks a missing edge.
pub const no_state: u16 = 0xFFFF;

pub const Node = struct {
    next: [alphabet_width]u16 = [_]u16{no_state} ** alphabet_width,
    /// Tag of the known name ending at this node (accept state); 0 when no
    /// known name ends here.
    tag: u16 = 0,
};

/// Build the DFA for `pairs` (each `.{ .name, .tag }`) and return a type
/// carrying the comptime node table plus the classifier. A name containing a
/// byte outside the alphabet, or duplicated in `pairs`, is a compile error.
pub fn build(comptime pairs: anytype) type {
    return struct {
        // Upper bound on nodes: one per distinct prefix, never more than the
        // total number of name bytes plus the root. The table is a comptime
        // constant in .rodata; trailing nodes are unreachable.
        pub const node_count = blk: {
            var total: usize = 1;
            for (pairs) |p| total += p.name.len;
            break :blk total;
        };

        pub const nodes: [node_count]Node = buildNodes(pairs, node_count);

        /// Classify a header name, returning its tag (0 = unknown).
        /// Case-insensitive; exact for the names the DFA was built over.
        pub inline fn classify(name: []const u8) u16 {
            var state: u16 = 0;
            for (name) |c| {
                const cls = classOf(c);
                if (cls == invalid_class) return 0;
                state = nodes[state].next[cls];
                if (state == no_state) return 0;
            }
            return nodes[state].tag;
        }
    };
}

/// Map a byte to its alphabet class: lower-cased letters land on 0-25 so the
/// DFA is case-insensitive.
pub inline fn classOf(c: u8) u8 {
    if (c >= '0' and c <= '9') return 26 + (c - '0');
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c == '-') return 36;
    return invalid_class;
}

/// Trie build: names share prefix nodes; every distinct prefix gets one node;
/// the node a full name ends at carries the name's tag. Nodes come from a
/// typed comptime pool — the arena of this builder — and the finished array
/// is copied by value into the DFA type's comptime constant.
fn buildNodes(comptime pairs: anytype, comptime max_nodes: usize) [max_nodes]Node {
    var pool = ct_pool.CtPool(Node, max_nodes){};
    _ = pool.create(.{}); // node 0 is the root

    for (pairs) |p| {
        var state: u16 = 0;
        for (p.name) |c| {
            const cls = classOf(c);
            if (cls == invalid_class) {
                @compileError("header DFA name contains a byte outside the alphabet: " ++ p.name);
            }
            const node = &pool.items[state];
            if (node.next[cls] == no_state) {
                const idx: u16 = @intCast(pool.len); // the slot create will use
                _ = pool.create(.{});
                node.next[cls] = idx;
                state = idx;
            } else {
                state = node.next[cls];
            }
        }
        if (pool.items[state].tag != 0) {
            @compileError("duplicate header name in DFA set: " ++ p.name);
        }
        pool.items[state].tag = p.tag;
    }

    return pool.items;
}

const testing = std.testing;

const TestTag = enum(u16) {
    unknown = 0,
    host,
    content_type,
    content_length,
    connection,
};

const test_dfa = build(&.{
    .{ .name = "host", .tag = @intFromEnum(TestTag.host) },
    .{ .name = "content-type", .tag = @intFromEnum(TestTag.content_type) },
    .{ .name = "content-length", .tag = @intFromEnum(TestTag.content_length) },
    .{ .name = "connection", .tag = @intFromEnum(TestTag.connection) },
});

fn tag(name: []const u8) TestTag {
    return @enumFromInt(test_dfa.classify(name));
}

test "classify known names case-insensitively" {
    try testing.expectEqual(TestTag.host, tag("host"));
    try testing.expectEqual(TestTag.host, tag("Host"));
    try testing.expectEqual(TestTag.host, tag("HOST"));
    try testing.expectEqual(TestTag.content_type, tag("content-type"));
    try testing.expectEqual(TestTag.content_type, tag("Content-Type"));
    try testing.expectEqual(TestTag.content_length, tag("content-length"));
    try testing.expectEqual(TestTag.content_length, tag("CONTENT-LENGTH"));
    try testing.expectEqual(TestTag.connection, tag("Connection"));
}

test "near-misses classify as unknown" {
    // Longer than a known name, shares the prefix.
    try testing.expectEqual(TestTag.unknown, tag("content-length-x"));
    try testing.expectEqual(TestTag.unknown, tag("hosting"));
    try testing.expectEqual(TestTag.unknown, tag("connection2"));
    // Prefix of a known name, not a full name.
    try testing.expectEqual(TestTag.unknown, tag("content-"));
    try testing.expectEqual(TestTag.unknown, tag("con"));
    // Missing hyphens.
    try testing.expectEqual(TestTag.unknown, tag("contentlength"));
    // Empty.
    try testing.expectEqual(TestTag.unknown, tag(""));
}

test "bytes outside the alphabet classify as unknown" {
    try testing.expectEqual(TestTag.unknown, tag("content_length"));
    try testing.expectEqual(TestTag.unknown, tag("x y"));
    try testing.expectEqual(TestTag.unknown, tag("host "));
}

test "classOf maps the alphabet densely" {
    try testing.expectEqual(@as(u8, 0), classOf('a'));
    try testing.expectEqual(@as(u8, 0), classOf('A'));
    try testing.expectEqual(@as(u8, 25), classOf('z'));
    try testing.expectEqual(@as(u8, 26), classOf('0'));
    try testing.expectEqual(@as(u8, 35), classOf('9'));
    try testing.expectEqual(@as(u8, 36), classOf('-'));
    try testing.expectEqual(invalid_class, classOf('_'));
    try testing.expectEqual(invalid_class, classOf(' '));
    try testing.expectEqual(invalid_class, classOf(':'));
}

test "classify is comptime-evaluable" {
    const t: TestTag = comptime @enumFromInt(test_dfa.classify("Host"));
    try testing.expectEqual(TestTag.host, t);
}
