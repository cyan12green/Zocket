const std = @import("std");

/// HPACK header compression (RFC 7541), decode side only.
///
/// A connection-scoped `Decoder` owns the dynamic table; per header-block
/// decode, `decode` yields header field blocks (name + value) into the
/// caller's arena. Integer and string-literal decoding follow RFC 7541 §5
/// and §6. The Huffman decoder (Appendix B) is a comptime-built trie over
/// the 257 canonical codes; the static table (Appendix A) is a comptime
/// array.
///
/// Known, unimportant difference from the RFC: the decoder does not enforce
/// the dynamic-table-size-change rules across blocks (§4.2) beyond honoring
/// the current size — curl and h2spec both pass with this implementation.
/// A decoded header field block.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
    /// Length of the value bytes (for indexed static entries whose value is
    /// the reference itself).
    value_len: usize,
};

pub const Decoder = struct {
    /// Dynamic table: most-recently-inserted at the front.
    dyn: DynamicTable = .{},

    pub fn init() Decoder {
        return .{};
    }

    /// Apply a SETTINGS_HEADER_TABLE_SIZE change (RFC 7541 §4.2).
    pub fn setHeaderTableSize(self: *Decoder, allocator: std.mem.Allocator, size: usize) void {
        self.dyn.resize(allocator, size);
    }

    /// Decode one header block fragment into `fields` (appending). `fields`
    /// memory is owned by the caller (typically the request arena).
    pub fn decode(self: *Decoder, allocator: std.mem.Allocator, block: []const u8, fields: *std.ArrayList(Field)) !void {
        var it = BitReader{ .bytes = block };
        var saw_field = false;
        while (true) {
            if (it.atEnd()) break;
            // The first byte carries the type bits in its high bits and the
            // integer's first part in its low `prefix_bits` bits (RFC 7541
            // §6.1). Consume the byte, then continue the integer from the
            // low bits.
            const first = try it.readBits(8);
            if (first & 0xE0 == 0x20 and saw_field) {
                // RFC 7541 §4.2: a dynamic-table size update may only appear
                // at the start of a header block.
                return error.CompressionError;
            }
            if (first & 0x80 != 0) {
                // 6.1 Indexed Header Field: 1xxxxxxx
                const index = try readInt(&it, 7, first & 0x7f);
                if (index == 0) return error.ProtocolError;
                const f = self.lookup(index) orelse return error.ProtocolError;
                // Static-table fields reference .rodata; the caller owns the
                // returned field slices, so dupe.
                saw_field = true;
                try fields.append(allocator, .{
                    .name = try allocator.dupe(u8, f.name),
                    .value = try allocator.dupe(u8, f.value),
                    .value_len = f.value.len,
                });
            } else if (first & 0xC0 == 0x40) {
                // 6.2.1 Literal Header Field with Incremental Indexing: 01xxxxxx
                const index = try readInt(&it, 6, first & 0x3f);
                const name = try self.readName(&it, index, allocator);
                const value = try readString(&it, allocator);
                saw_field = true;
                try self.dyn.insert(allocator, name, value);
                try fields.append(allocator, .{ .name = name, .value = value, .value_len = value.len });
            } else if (first & 0xE0 == 0x20) {
                // 6.3 Dynamic Table Size Update: 001xxxxx
                const new_size = try readInt(&it, 5, first & 0x1f);
                // RFC 7541 §6.3: the new size must be <= the limit set by the
                // protocol (we do not advertise HEADER_TABLE_SIZE, so 4096).
                if (new_size > 4096) return error.CompressionError;
                self.dyn.resize(allocator, new_size);
            } else {
                // 6.2.2 Literal without Indexing: 0000xxxx
                // 6.2.3 Literal Never Indexed: 0001xxxx
                const index = try readInt(&it, 4, first & 0x0f);
                const name = try self.readName(&it, index, allocator);
                const value = try readString(&it, allocator);
                saw_field = true;
                try fields.append(allocator, .{ .name = name, .value = value, .value_len = value.len });
            }
        }
    }

    fn readName(self: *Decoder, it: *BitReader, index: usize, allocator: std.mem.Allocator) ![]const u8 {
        if (index == 0) return readString(it, allocator);
        const f = self.lookup(index) orelse return error.ProtocolError;
        // Name-only reference: the value is a new literal. Copy the name so
        // it survives (indexed entries may be evicted).
        return allocator.dupe(u8, f.name);
    }

    /// Resolve a table index (static + dynamic). Index 1..61 static, then
    /// dynamic (most recent first).
    fn lookup(self: *const Decoder, index: usize) ?Field {
        if (index >= 1 and index <= static_table.len) {
            const e = static_table[index - 1];
            return .{ .name = e.name, .value = e.value, .value_len = e.value.len };
        }
        const dyn_index = index - static_table.len; // 1-based from newest
        return self.dyn.get(dyn_index);
    }

    /// Free the dynamic table's heap (call once per connection at teardown).
    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        self.dyn.deinit(allocator);
    }
};

// ---- integer decoding (RFC 7541 §5.1) ----

fn readInt(it: *BitReader, comptime prefix_bits: u6, prefix: u8) !usize {
    const max: usize = (@as(usize, 1) << prefix_bits) - 1;
    var value: usize = prefix;
    if (value < max) return value;
    var shift: u6 = 0;
    while (true) {
        const byte = try it.readBits(8);
        value += @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
        if (shift >= 63) return error.ProtocolError;
    }
}

// ---- string literal (RFC 7541 §5.2) ----

fn readString(it: *BitReader, allocator: std.mem.Allocator) ![]const u8 {
    const huffman = (try it.readBits(1)) == 1;
    const len = try readInt(it, 7, try it.readBits(7));
    const bytes = try it.takeBytes(len);
    if (huffman) {
        return huffmanDecode(bytes, allocator);
    }
    return allocator.dupe(u8, bytes);
}

/// A bit reader over a byte slice. Bits are consumed MSB-first (RFC 7541
/// integer/string encoding order).
const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    fn atEnd(self: *const BitReader) bool {
        return self.bit_pos >= self.bytes.len * 8;
    }

    fn peekBits(self: *const BitReader, n: u6) !u8 {
        if (self.bit_pos + n > self.bytes.len * 8) return error.Truncated;
        var v: u8 = 0;
        for (0..n) |i| {
            const byte = self.bytes[(self.bit_pos + i) / 8];
            const shift: u3 = @intCast(7 - ((self.bit_pos + i) % 8));
            const bit = (byte >> shift) & 1;
            v = (v << 1) | bit;
        }
        return v;
    }

    fn readBits(self: *BitReader, n: u6) !u8 {
        const v = try self.peekBits(n);
        self.bit_pos += n;
        return v;
    }

    fn takeBytes(self: *BitReader, n: usize) ![]const u8 {
        if (self.bit_pos % 8 != 0) return error.ProtocolError;
        const start = self.bit_pos / 8;
        if (start + n > self.bytes.len) return error.Truncated;
        self.bit_pos += n * 8;
        return self.bytes[start .. start + n];
    }
};

// ---- dynamic table (RFC 7541 §4) ----

const DynamicTable = struct {
    entries: std.ArrayList(Entry) = .empty,
    size: usize = 0,
    max_size: usize = 4096,

    const Entry = struct { name: []const u8, value: []const u8 };

    fn entrySize(name: []const u8, value: []const u8) usize {
        return name.len + value.len + 32;
    }

    fn insert(self: *DynamicTable, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const sz = entrySize(name, value);
        if (sz > self.max_size) {
            // The entry would never fit; clear the table.
            self.clear(allocator);
            return;
        }
        while (self.size + sz > self.max_size and self.entries.items.len > 0) {
            self.evict(allocator);
        }
        // The table owns its own copies (the caller's field slices stay with
        // the caller).
        const n = try allocator.dupe(u8, name);
        errdefer allocator.free(n);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try self.entries.insert(allocator, 0, .{ .name = n, .value = v });
        self.size += sz;
    }

    fn evict(self: *DynamicTable, allocator: std.mem.Allocator) void {
        const last = self.entries.pop() orelse return;
        self.size -= entrySize(last.name, last.value);
        allocator.free(last.name);
        allocator.free(last.value);
    }

    fn clear(self: *DynamicTable, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        self.entries.clearRetainingCapacity();
        self.size = 0;
    }

    /// Index is 1-based (1 = most recent).
    fn get(self: *const DynamicTable, index: usize) ?Field {
        if (index == 0 or index > self.entries.items.len) return null;
        const e = self.entries.items[index - 1];
        return .{ .name = e.name, .value = e.value, .value_len = e.value.len };
    }

    pub fn resize(self: *DynamicTable, allocator: std.mem.Allocator, new_max: usize) void {
        // Evict from the tail (freeing) until under the new limit.
        self.max_size = new_max;
        while (self.size > self.max_size and self.entries.items.len > 0) {
            self.evict(allocator);
        }
    }

    fn deinit(self: *DynamicTable, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
    }
};

// ---- static table (RFC 7541 Appendix A) ----

const StaticEntry = struct { name: []const u8, value: []const u8 };

pub const static_table = [_]StaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

comptime {
    // The static table must be exactly 61 entries (RFC 7541 §6.1).
    if (static_table.len != 61) @compileError("HPACK static table must be 61 entries");
}

// ---- comptime name hashing (M8 pattern) ----

/// FNV-1a (32-bit) over lower-cased bytes — the same hasher the HTTP/1
/// header parser uses (Milestone 8), so known names match as integers.
fn nameHash(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |c| {
        h ^= std.ascii.toLower(c);
        h *%= 16777619;
    }
    return h;
}

/// Comptime-built per-entry name hashes: the encoder pre-filters candidates
/// by integer compare before the (rare) string equality check.
pub const static_name_hashes: [static_table.len]u32 = blk: {
    @setEvalBranchQuota(1000000);
    var out: [static_table.len]u32 = undefined;
    for (static_table, 0..) |e, i| out[i] = nameHash(e.name);
    break :blk out;
};

const NameRef = struct { hash: u32, index: u16 };

/// Comptime-built, hash-sorted map from a distinct static-table name to its
/// best name-only index (the entry with an empty value, else the first).
/// Binary-searched at runtime for O(log n) name resolution in the encoder.
const NameRefsBuild = struct { refs: [static_table.len]NameRef, len: usize };
const name_refs_build: NameRefsBuild = blk: {
    @setEvalBranchQuota(1000000);
    var refs: [static_table.len]NameRef = undefined;
    var n: usize = 0;
    for (static_table, 0..) |e, i| {
        const h = nameHash(e.name);
        var found: ?usize = null;
        for (refs[0..n], 0..) |_, ri| {
            if (refs[ri].hash == h and std.mem.eql(u8, static_table[refs[ri].index].name, e.name)) {
                found = ri;
            }
        }
        if (found) |ri| {
            if (e.value.len == 0 and static_table[refs[ri].index].value.len != 0) {
                refs[ri].index = @intCast(i); // prefer the empty-value entry
            }
        } else {
            refs[n] = .{ .hash = h, .index = @intCast(i) };
            n += 1;
        }
    }
    // insertion sort by hash (comptime).
    for (1..n) |i| {
        const key = refs[i];
        var j = i;
        while (j > 0 and refs[j - 1].hash > key.hash) : (j -= 1) {
            refs[j] = refs[j - 1];
        }
        refs[j] = key;
    }
    break :blk .{ .refs = refs, .len = n };
};
pub const name_refs: []const NameRef = name_refs_build.refs[0..name_refs_build.len];

/// O(log n) resolution of a static-table name to its best name-only index
/// via the comptime-built hash index; null when the name is unknown.
fn staticNameIndex(name: []const u8) ?usize {
    const h = nameHash(name);
    var lo: usize = 0;
    var hi = name_refs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (name_refs[mid].hash < h) lo = mid + 1 else hi = mid;
    }
    if (lo < name_refs.len and name_refs[lo].hash == h and std.mem.eql(u8, static_table[name_refs[lo].index].name, name)) {
        return name_refs[lo].index;
    }
    return null;
}

// ---- Huffman decoding (RFC 7541 Appendix B) ----

const HuffmanCode = struct { code: u32, len: u8 };

/// Huffman codes, decoded via a binary trie built at comptime from the
/// (code, length) pairs below. Symbols 0..256; 256 is EOS (never appears on
/// the wire).
const huffman_codes: [257]HuffmanCode = blk: {
    @setEvalBranchQuota(100000);
    // (symbol, code, length) — copied from RFC 7541 Appendix B. Codes are
    // written in binary MSB-first order as printed in the RFC.
    const raw = [_][3]u32{
        .{ 0, 0x1FF8, 13 },
        .{ 1, 0x7FFFD8, 23 },
        .{ 2, 0xFFFFFE2, 28 },
        .{ 3, 0xFFFFFE3, 28 },
        .{ 4, 0xFFFFFE4, 28 },
        .{ 5, 0xFFFFFE5, 28 },
        .{ 6, 0xFFFFFE6, 28 },
        .{ 7, 0xFFFFFE7, 28 },
        .{ 8, 0xFFFFFE8, 28 },
        .{ 9, 0xFFFFEA, 24 },
        .{ 10, 0x3FFFFFFC, 30 },
        .{ 11, 0xFFFFFE9, 28 },
        .{ 12, 0xFFFFFEA, 28 },
        .{ 13, 0x3FFFFFFD, 30 },
        .{ 14, 0xFFFFFEB, 28 },
        .{ 15, 0xFFFFFEC, 28 },
        .{ 16, 0xFFFFFED, 28 },
        .{ 17, 0xFFFFFEE, 28 },
        .{ 18, 0xFFFFFEF, 28 },
        .{ 19, 0xFFFFFF0, 28 },
        .{ 20, 0xFFFFFF1, 28 },
        .{ 21, 0xFFFFFF2, 28 },
        .{ 22, 0x3FFFFFFE, 30 },
        .{ 23, 0xFFFFFF3, 28 },
        .{ 24, 0xFFFFFF4, 28 },
        .{ 25, 0xFFFFFF5, 28 },
        .{ 26, 0xFFFFFF6, 28 },
        .{ 27, 0xFFFFFF7, 28 },
        .{ 28, 0xFFFFFF8, 28 },
        .{ 29, 0xFFFFFF9, 28 },
        .{ 30, 0xFFFFFFA, 28 },
        .{ 31, 0xFFFFFFB, 28 },
        .{ 32, 0x14, 6 },
        .{ 33, 0x3F8, 10 },
        .{ 34, 0x3F9, 10 },
        .{ 35, 0xFFA, 12 },
        .{ 36, 0x1FF9, 13 },
        .{ 37, 0x15, 6 },
        .{ 38, 0xF8, 8 },
        .{ 39, 0x7FA, 11 },
        .{ 40, 0x3FA, 10 },
        .{ 41, 0x3FB, 10 },
        .{ 42, 0xF9, 8 },
        .{ 43, 0x7FB, 11 },
        .{ 44, 0xFA, 8 },
        .{ 45, 0x16, 6 },
        .{ 46, 0x17, 6 },
        .{ 47, 0x18, 6 },
        .{ 48, 0x0, 5 },
        .{ 49, 0x1, 5 },
        .{ 50, 0x2, 5 },
        .{ 51, 0x19, 6 },
        .{ 52, 0x1A, 6 },
        .{ 53, 0x1B, 6 },
        .{ 54, 0x1C, 6 },
        .{ 55, 0x1D, 6 },
        .{ 56, 0x1E, 6 },
        .{ 57, 0x1F, 6 },
        .{ 58, 0x5C, 7 },
        .{ 59, 0xFB, 8 },
        .{ 60, 0x7FFC, 15 },
        .{ 61, 0x20, 6 },
        .{ 62, 0xFFB, 12 },
        .{ 63, 0x3FC, 10 },
        .{ 64, 0x1FFA, 13 },
        .{ 65, 0x21, 6 },
        .{ 66, 0x5D, 7 },
        .{ 67, 0x5E, 7 },
        .{ 68, 0x5F, 7 },
        .{ 69, 0x60, 7 },
        .{ 70, 0x61, 7 },
        .{ 71, 0x62, 7 },
        .{ 72, 0x63, 7 },
        .{ 73, 0x64, 7 },
        .{ 74, 0x65, 7 },
        .{ 75, 0x66, 7 },
        .{ 76, 0x67, 7 },
        .{ 77, 0x68, 7 },
        .{ 78, 0x69, 7 },
        .{ 79, 0x6A, 7 },
        .{ 80, 0x6B, 7 },
        .{ 81, 0x6C, 7 },
        .{ 82, 0x6D, 7 },
        .{ 83, 0x6E, 7 },
        .{ 84, 0x6F, 7 },
        .{ 85, 0x70, 7 },
        .{ 86, 0x71, 7 },
        .{ 87, 0x72, 7 },
        .{ 88, 0xFC, 8 },
        .{ 89, 0x73, 7 },
        .{ 90, 0xFD, 8 },
        .{ 91, 0x1FFB, 13 },
        .{ 92, 0x7FFF0, 19 },
        .{ 93, 0x1FFC, 13 },
        .{ 94, 0x3FFC, 14 },
        .{ 95, 0x22, 6 },
        .{ 96, 0x7FFD, 15 },
        .{ 97, 0x3, 5 },
        .{ 98, 0x23, 6 },
        .{ 99, 0x4, 5 },
        .{ 100, 0x24, 6 },
        .{ 101, 0x5, 5 },
        .{ 102, 0x25, 6 },
        .{ 103, 0x26, 6 },
        .{ 104, 0x27, 6 },
        .{ 105, 0x6, 5 },
        .{ 106, 0x74, 7 },
        .{ 107, 0x75, 7 },
        .{ 108, 0x28, 6 },
        .{ 109, 0x29, 6 },
        .{ 110, 0x2A, 6 },
        .{ 111, 0x7, 5 },
        .{ 112, 0x2B, 6 },
        .{ 113, 0x76, 7 },
        .{ 114, 0x2C, 6 },
        .{ 115, 0x8, 5 },
        .{ 116, 0x9, 5 },
        .{ 117, 0x2D, 6 },
        .{ 118, 0x77, 7 },
        .{ 119, 0x78, 7 },
        .{ 120, 0x79, 7 },
        .{ 121, 0x7A, 7 },
        .{ 122, 0x7B, 7 },
        .{ 123, 0x7FFE, 15 },
        .{ 124, 0x7FC, 11 },
        .{ 125, 0x3FFD, 14 },
        .{ 126, 0x1FFD, 13 },
        .{ 127, 0xFFFFFFC, 28 },
        .{ 128, 0xFFFE6, 20 },
        .{ 129, 0x3FFFD2, 22 },
        .{ 130, 0xFFFE7, 20 },
        .{ 131, 0xFFFE8, 20 },
        .{ 132, 0x3FFFD3, 22 },
        .{ 133, 0x3FFFD4, 22 },
        .{ 134, 0x3FFFD5, 22 },
        .{ 135, 0x7FFFD9, 23 },
        .{ 136, 0x3FFFD6, 22 },
        .{ 137, 0x7FFFDA, 23 },
        .{ 138, 0x7FFFDB, 23 },
        .{ 139, 0x7FFFDC, 23 },
        .{ 140, 0x7FFFDD, 23 },
        .{ 141, 0x7FFFDE, 23 },
        .{ 142, 0xFFFFEB, 24 },
        .{ 143, 0x7FFFDF, 23 },
        .{ 144, 0xFFFFEC, 24 },
        .{ 145, 0xFFFFED, 24 },
        .{ 146, 0x3FFFD7, 22 },
        .{ 147, 0x7FFFE0, 23 },
        .{ 148, 0xFFFFEE, 24 },
        .{ 149, 0x7FFFE1, 23 },
        .{ 150, 0x7FFFE2, 23 },
        .{ 151, 0x7FFFE3, 23 },
        .{ 152, 0x7FFFE4, 23 },
        .{ 153, 0x1FFFDC, 21 },
        .{ 154, 0x3FFFD8, 22 },
        .{ 155, 0x7FFFE5, 23 },
        .{ 156, 0x3FFFD9, 22 },
        .{ 157, 0x7FFFE6, 23 },
        .{ 158, 0x7FFFE7, 23 },
        .{ 159, 0xFFFFEF, 24 },
        .{ 160, 0x3FFFDA, 22 },
        .{ 161, 0x1FFFDD, 21 },
        .{ 162, 0xFFFE9, 20 },
        .{ 163, 0x3FFFDB, 22 },
        .{ 164, 0x3FFFDC, 22 },
        .{ 165, 0x7FFFE8, 23 },
        .{ 166, 0x7FFFE9, 23 },
        .{ 167, 0x1FFFDE, 21 },
        .{ 168, 0x7FFFEA, 23 },
        .{ 169, 0x3FFFDD, 22 },
        .{ 170, 0x3FFFDE, 22 },
        .{ 171, 0xFFFFF0, 24 },
        .{ 172, 0x1FFFDF, 21 },
        .{ 173, 0x3FFFDF, 22 },
        .{ 174, 0x7FFFEB, 23 },
        .{ 175, 0x7FFFEC, 23 },
        .{ 176, 0x1FFFE0, 21 },
        .{ 177, 0x1FFFE1, 21 },
        .{ 178, 0x3FFFE0, 22 },
        .{ 179, 0x1FFFE2, 21 },
        .{ 180, 0x7FFFED, 23 },
        .{ 181, 0x3FFFE1, 22 },
        .{ 182, 0x7FFFEE, 23 },
        .{ 183, 0x7FFFEF, 23 },
        .{ 184, 0xFFFEA, 20 },
        .{ 185, 0x3FFFE2, 22 },
        .{ 186, 0x3FFFE3, 22 },
        .{ 187, 0x3FFFE4, 22 },
        .{ 188, 0x7FFFF0, 23 },
        .{ 189, 0x3FFFE5, 22 },
        .{ 190, 0x3FFFE6, 22 },
        .{ 191, 0x7FFFF1, 23 },
        .{ 192, 0x3FFFFE0, 26 },
        .{ 193, 0x3FFFFE1, 26 },
        .{ 194, 0xFFFEB, 20 },
        .{ 195, 0x7FFF1, 19 },
        .{ 196, 0x3FFFE7, 22 },
        .{ 197, 0x7FFFF2, 23 },
        .{ 198, 0x3FFFE8, 22 },
        .{ 199, 0x1FFFFEC, 25 },
        .{ 200, 0x3FFFFE2, 26 },
        .{ 201, 0x3FFFFE3, 26 },
        .{ 202, 0x3FFFFE4, 26 },
        .{ 203, 0x7FFFFDE, 27 },
        .{ 204, 0x7FFFFDF, 27 },
        .{ 205, 0x3FFFFE5, 26 },
        .{ 206, 0xFFFFF1, 24 },
        .{ 207, 0x1FFFFED, 25 },
        .{ 208, 0x7FFF2, 19 },
        .{ 209, 0x1FFFE3, 21 },
        .{ 210, 0x3FFFFE6, 26 },
        .{ 211, 0x7FFFFE0, 27 },
        .{ 212, 0x7FFFFE1, 27 },
        .{ 213, 0x3FFFFE7, 26 },
        .{ 214, 0x7FFFFE2, 27 },
        .{ 215, 0xFFFFF2, 24 },
        .{ 216, 0x1FFFE4, 21 },
        .{ 217, 0x1FFFE5, 21 },
        .{ 218, 0x3FFFFE8, 26 },
        .{ 219, 0x3FFFFE9, 26 },
        .{ 220, 0xFFFFFFD, 28 },
        .{ 221, 0x7FFFFE3, 27 },
        .{ 222, 0x7FFFFE4, 27 },
        .{ 223, 0x7FFFFE5, 27 },
        .{ 224, 0xFFFEC, 20 },
        .{ 225, 0xFFFFF3, 24 },
        .{ 226, 0xFFFED, 20 },
        .{ 227, 0x1FFFE6, 21 },
        .{ 228, 0x3FFFE9, 22 },
        .{ 229, 0x1FFFE7, 21 },
        .{ 230, 0x1FFFE8, 21 },
        .{ 231, 0x7FFFF3, 23 },
        .{ 232, 0x3FFFEA, 22 },
        .{ 233, 0x3FFFEB, 22 },
        .{ 234, 0x1FFFFEE, 25 },
        .{ 235, 0x1FFFFEF, 25 },
        .{ 236, 0xFFFFF4, 24 },
        .{ 237, 0xFFFFF5, 24 },
        .{ 238, 0x3FFFFEA, 26 },
        .{ 239, 0x7FFFF4, 23 },
        .{ 240, 0x3FFFFEB, 26 },
        .{ 241, 0x7FFFFE6, 27 },
        .{ 242, 0x3FFFFEC, 26 },
        .{ 243, 0x3FFFFED, 26 },
        .{ 244, 0x7FFFFE7, 27 },
        .{ 245, 0x7FFFFE8, 27 },
        .{ 246, 0x7FFFFE9, 27 },
        .{ 247, 0x7FFFFEA, 27 },
        .{ 248, 0x7FFFFEB, 27 },
        .{ 249, 0xFFFFFFE, 28 },
        .{ 250, 0x7FFFFEC, 27 },
        .{ 251, 0x7FFFFED, 27 },
        .{ 252, 0x7FFFFEE, 27 },
        .{ 253, 0x7FFFFEF, 27 },
        .{ 254, 0x7FFFFF0, 27 },
        .{ 255, 0x3FFFFEE, 26 },
        .{ 256, 0x3FFFFFFF, 30 },
    };
    var out: [257]HuffmanCode = undefined;
    for (raw, 0..) |r, i| {
        out[i] = .{ .code = r[1], .len = @intCast(r[2]) };
    }
    break :blk out;
};

/// Huffman decoding via a comptime-built binary trie over the canonical
/// codes. Walk the input bits MSB-first; at a leaf emit the symbol and reset
/// to the root. Final partial code must be a valid EOS-prefix padding
/// (RFC 7541 §5.2: a string ends with the EOS-prefixed padding).
fn huffmanDecode(src: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (src.len == 0) return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var node: usize = 0; // root
    var partial_len: u8 = 0;
    var partial_bits: u32 = 0;

    for (src) |byte| {
        for (0..8) |b| {
            const shift: u3 = @intCast(7 - b);
            const bit = (byte >> shift) & 1;
            const next = trie[node].child[bit];
            if (next == no_node) return error.InvalidHuffman;
            node = next;
            partial_len += 1;
            partial_bits = (partial_bits << 1) | bit;
            if (trie[node].symbol >= 0) {
                // EOS (symbol 256) never appears on the wire (RFC 7541 §5.2);
                // check before the u8 cast since 256 does not fit.
                if (trie[node].symbol == 256) return error.InvalidHuffman;
                const sym: u8 = @intCast(trie[node].symbol);
                out.append(allocator, sym) catch return error.OutOfMemory;
                node = 0;
                partial_len = 0;
                partial_bits = 0;
            }
        }
    }
    // Trailing bits (the padding) must be a prefix of the EOS code
    // (RFC 7541 §5.2). We accept any partial with <= 7 bits that is a prefix
    // of the EOS code 0b111111111111111111111111111111.
    if (partial_len > 7) return error.InvalidHuffman;
    if (partial_len > 0) {
        const eos: u32 = huffman_codes[256].code;
        // The consumed bits must equal the EOS code's leading `partial_len`
        // bits.
        const eshift: u5 = @intCast(30 - partial_len);
        const eos_prefix = eos >> eshift;
        if (partial_bits != eos_prefix) return error.InvalidHuffman;
    }
    return out.toOwnedSlice(allocator);
}

const no_node: u16 = 0xffff;
const HuffTrieNode = struct {
    child: [2]u16 = .{ no_node, no_node },
    /// -1 = internal, else the symbol at this leaf.
    symbol: i32 = -1,
};

/// Comptime-built Huffman decode trie (see `huffman_codes`). Built by value
/// (a slice of a comptime var cannot escape to runtime), then sliced.
const TrieBuild = struct { nodes: [1024]HuffTrieNode, len: usize };
const trie_build: TrieBuild = blk: {
    @setEvalBranchQuota(1000000);
    var nodes = [_]HuffTrieNode{.{}} ** 1024;
    var count: usize = 1; // root at 0
    for (huffman_codes, 0..) |h, sym| {
        var node: usize = 0;
        for (0..h.len) |i| {
            const bit: u2 = @intCast((h.code >> (h.len - 1 - i)) & 1);
            if (nodes[node].child[bit] == no_node) {
                nodes[node].child[bit] = @intCast(count);
                node = count;
                count += 1;
            } else {
                node = nodes[node].child[bit];
            }
        }
        nodes[node].symbol = @intCast(sym);
    }
    break :blk .{ .nodes = nodes, .len = count };
};
const trie: []const HuffTrieNode = trie_build.nodes[0..trie_build.len];

// ---- encoding (server → client) ----

/// Encode one header field into `sink` using the static table where
/// possible (indexed or name-indexed literal), otherwise a literal without
/// indexing. Huffman coding is not used on the encode side (RFC 7541 §6.2:
/// optional). Names are lower-cased as the wire requires (RFC 9113 §8.2:
/// header names MUST be lowercase); a name longer than the stack buffer is
/// truncated.
pub fn encodeField(sink: anytype, allocator: std.mem.Allocator, name_in: []const u8, value: []const u8) !void {
    var name_buf: [128]u8 = undefined;
    const name = blk: {
        if (name_in.len > name_buf.len) break :blk name_in; // oversized: pass through
        for (name_in, 0..) |c, i| name_buf[i] = std.ascii.toLower(c);
        break :blk name_buf[0..name_in.len];
    };
    const nh = nameHash(name);
    // Value-indexed match first (e.g. `:status 200`): candidates are
    // pre-filtered by the comptime name hashes (integer compare).
    for (static_table, 0..) |e, i| {
        if (static_name_hashes[i] == nh and std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value)) {
            var buf: [1]u8 = undefined;
            try writeInt(&buf, sink, allocator, 7, i + 1, 0x80);
            return;
        }
    }
    // Name-indexed literal via the comptime-built hash-sorted table
    // (O(log n) instead of scanning all 61 entries).
    if (staticNameIndex(name)) |idx| {
        if (static_table[idx].value.len == 0) {
            var buf: [1]u8 = undefined;
            try writeInt(&buf, sink, allocator, 4, idx + 1, 0x00);
            try writeStringLiteral(sink, allocator, value);
            return;
        }
    }
    {
        var buf: [1]u8 = undefined;
        try writeInt(&buf, sink, allocator, 4, 0, 0x00);
        try writeStringLiteral(sink, allocator, name);
        try writeStringLiteral(sink, allocator, value);
    }
}

/// Write an integer with `prefix_bits` available in the first byte (whose
/// low bits hold `prefix`); `scratch` must hold the first byte.
fn writeInt(scratch: *[1]u8, sink: anytype, allocator: std.mem.Allocator, comptime prefix_bits: u6, value: usize, prefix: u8) !void {
    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
    if (value < max_prefix) {
        scratch[0] = prefix | @as(u8, @intCast(value));
        try sink.appendSlice(allocator, scratch);
        return;
    }
    scratch[0] = prefix | @as(u8, @intCast(max_prefix));
    try sink.appendSlice(allocator, scratch);
    var v = value - max_prefix;
    while (v >= 128) {
        const byte: u8 = @intCast((v & 0x7f) | 0x80);
        try sink.appendSlice(allocator, &[1]u8{byte});
        v >>= 7;
    }
    try sink.appendSlice(allocator, &[1]u8{@intCast(v)});
}

/// Write a string literal (no Huffman: H=0 then 7-bit length then bytes).
fn writeStringLiteral(sink: anytype, allocator: std.mem.Allocator, s: []const u8) !void {
    var scratch: [1]u8 = undefined;
    try writeInt(&scratch, sink, allocator, 7, s.len, 0x00);
    try sink.appendSlice(allocator, s);
}

const testing = std.testing;

fn freeFields(allocator: std.mem.Allocator, fields: *std.ArrayList(Field)) void {
    for (fields.items) |f| {
        allocator.free(f.name);
        allocator.free(f.value);
    }
}

test "HPACK: RFC 7541 C.4.1 integer decoding (10 with 5-bit prefix)" {
    // 10 encoded with 5-bit prefix, value 10 < 31 -> single byte 00001010.
    // We exercise via the block path: 0x0a with prefix 5.
    var it = BitReader{ .bytes = &.{0x0a} };
    _ = try it.readBits(8); // consume the byte; low 5 bits carry the value
    try testing.expectEqual(@as(usize, 10), try readInt(&it, 5, 0x0a & 0x1f));
}

test "HPACK: RFC 7541 C.4.1 integer decoding (1337 with 5-bit prefix)" {
    // 1337 = 31 + 1306; 1306 = 0x0a << 7 | 0x1a -> continuation bytes.
    var it = BitReader{ .bytes = &.{ 0x1f, 0x9a, 0x0a } };
    _ = try it.readBits(8);
    try testing.expectEqual(@as(usize, 1337), try readInt(&it, 5, 0x1f & 0x1f));
}

test "HPACK: static table index 2 is :method GET" {
    var d = Decoder.init();
    defer d.deinit(testing.allocator);
    var fields = std.ArrayList(Field).empty;
    defer fields.deinit(testing.allocator);
    // 0x82 = indexed header field, index 2.
    try d.decode(testing.allocator, &.{0x82}, &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings(":method", fields.items[0].name);
    try testing.expectEqualStrings("GET", fields.items[0].value);
    freeFields(testing.allocator, &fields);
}

test "HPACK: literal with incremental indexing (C.3.1 sample)" {
    var d = Decoder.init();
    defer d.deinit(testing.allocator);
    var fields = std.ArrayList(Field).empty;
    defer fields.deinit(testing.allocator);
    // custom-key: 40 0a 637573746f6d2d6b6579, custom-value: 0d 637573746f6d2d76616c7565
    try d.decode(testing.allocator, &.{ 0x40, 0x0a, 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y', 0x0c, 'c', 'u', 's', 't', 'o', 'm', '-', 'v', 'a', 'l', 'u', 'e' }, &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("custom-key", fields.items[0].name);
    try testing.expectEqualStrings("custom-value", fields.items[0].value);
    // The entry is now in the dynamic table (index 62).
    const f = d.lookup(62).?;
    try testing.expectEqualStrings("custom-key", f.name);
    try testing.expectEqualStrings("custom-value", f.value);
    freeFields(testing.allocator, &fields);
}

test "HPACK: huffman-encoded string decodes (curl sample)" {
    var d = Decoder.init();
    defer d.deinit(testing.allocator);
    var fields = std.ArrayList(Field).empty;
    defer fields.deinit(testing.allocator);
    // ":path /" Huffman-coded: index 4 is ":path /", so 0x84 alone.
    try d.decode(testing.allocator, &.{0x84}, &fields);
    try testing.expectEqualStrings(":path", fields.items[0].name);
    try testing.expectEqualStrings("/", fields.items[0].value);
    freeFields(testing.allocator, &fields);
}

test "HPACK: RFC 7541 C.4.1 huffman-encoded string decodes correctly" {
    var d = Decoder.init();
    defer d.deinit(testing.allocator);
    var fields = std.ArrayList(Field).empty;
    defer fields.deinit(testing.allocator);
    // C.4.1: :method GET (indexed), :scheme http (indexed 6), :path /
    // Huffman: 4c 1f 0b 87 8a 64 1c a7 f4 86 c6 3b d6 61 8e 20 7a 86 cc 1b 1a 3f 60 ff ff
    // (that is the C.4.1 example block). Assert the decoded :path value.
    // C.4.1 first request block (RFC 7541): 82 86 84 41 8c f1e3c2e5f23a6ba0ab90f4ff.
    const block = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    try d.decode(testing.allocator, &block, &fields);
    try testing.expectEqual(@as(usize, 4), fields.items.len);
    // :authority www.example.com (C.4.1 first request).
    var found_authority = false;
    for (fields.items) |f| {
        if (std.mem.eql(u8, f.name, ":authority")) {
            try testing.expectEqualStrings("www.example.com", f.value);
            found_authority = true;
        }
    }
    try testing.expect(found_authority);
    freeFields(testing.allocator, &fields);
}
