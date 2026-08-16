const std = @import("std");
const vars = @import("vars.zig");
const ct_pool = @import("../ct_pool.zig");

pub const Regex = vars.Regex;
pub const RegexState = vars.RegexState;
pub const CaptureRange = vars.CaptureRange;

/// Comptime regex engine for `location ~` / `location ~*` (plan M-D).
///
/// Feature set (locked, plan §6.1):
/// - Literals (escaped metachars: `\. \/ \\ \* \+ \? \( \) \[ \] \{ \} \| \^ \$`).
/// - `.` matches any byte except `\n`.
/// - Classes `[...]` / `[^...]` with ranges (`a-z`), escapes (`\d \w \s \D
///   \W \S` and escaped metachars), literal `]` as the first member.
/// - `\d` `[0-9]`, `\w` `[A-Za-z0-9_]`, `\s` `[ \t\r\n]`, complements.
/// - Quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` (greedy only).
/// - Groups `(...)` (capturing) and `(?:...)` (non-capturing).
/// - Alternation `|`.
/// - Anchors `^` (start) and `$` (end).
/// No backrefs, no lookaround, no lazy/possessive modifiers, no `\b`, no
/// named groups. Malformed patterns are compile errors carrying the pattern
/// text.
///
/// Compilation is comptime (Thompson NFA construction). Matching is a
/// backtracking walk over the NFA with a per-path epsilon/visited guard
/// (exponential worst case — fine for config-authored patterns over short
/// URIs; the guard bounds `a*`-style loops).
///
/// NFA encoding (plan §6.2): every index is a state id.
/// - kind 0 = consume byte `byte` (0..255)
/// - kind 1 = epsilon (two targets via next/next2)
/// - kind 2 = match (accept)
/// - kind 3 = consume with a class bitmap (`byte` = class index)
/// - kind 4 = consume any byte except `\n` (`.`)
/// - kind 5 = anchor start (`^`)
/// - kind 6 = anchor end (`$`)
/// - kind 7 = consume lowercased byte (case-insensitive, `~*`)
/// - kind 8 = consume class on lowercased byte
/// `cap_start`/`cap_end` mark capture group boundaries (index 0 = whole
/// match).
pub const kind_literal: u8 = 0;
pub const kind_epsilon: u8 = 1;
pub const kind_match: u8 = 2;
pub const kind_class: u8 = 3;
pub const kind_dot: u8 = 4;
pub const kind_anchor_start: u8 = 5;
pub const kind_anchor_end: u8 = 6;
pub const kind_literal_ci: u8 = 7;
pub const kind_class_ci: u8 = 8;

const max_states = 8192;
const max_classes = 256;
const max_groups = 9;

const RegexErr = error{
    UnbalancedParen,
    BadClass,
    BadQuantifier,
    DanglingEscape,
    EmptyBraces,
    QuantifierNotApplicable,
};

/// Compile a regex pattern at compile time into a Thompson NFA.
pub fn compileRegex(comptime pattern: []const u8) Regex {
    @setEvalBranchQuota(200000);
    return comptime blk: {
        var c = Compiler{ .pattern = pattern };
        const frag = c.parseAlternation() catch
            @compileError("regex: malformed pattern '" ++ pattern ++ "'");
        if (c.pos != pattern.len) {
            @compileError("regex: unexpected trailing characters in '" ++ pattern ++ "'");
        }
        // Patch the fragment's open epsilon targets to the accept state.
        const accept = c.newState(.{ .kind = kind_match, .byte = 0xFFFF });
        frag.patch(&c, accept);
        break :blk .{
            .states = c.states.freeze(),
            .group_count = c.group_count,
            .class_bitmaps = c.classes.freeze(),
        };
    };
}

/// A fragment: a start state plus a list of unpatched epsilon "out" states.
/// `outs` are indices of epsilon states whose `next` slot is self-referring
/// until patched (the Thompson bookkeeping trick).
const Frag = struct {
    start: u32,
    out: [8]u32 = undefined,
    out_count: usize = 0,

    fn add(self: *Frag, s: u32) void {
        if (self.out_count < self.out.len) {
            self.out[self.out_count] = s;
            self.out_count += 1;
        }
    }

    fn patch(self: Frag, c: *Compiler, target: u32) void {
        for (self.out[0..self.out_count]) |o| {
            var st = &c.states.items[o];
            if (st.next == o) {
                st.next = target;
                if (st.next2 == o) st.next2 = target;
            } else if (st.next2 == o) {
                st.next2 = target;
            }
        }
    }
};

const Compiler = struct {
    pattern: []const u8,
    pos: usize = 0,
    states: ct_pool.CtPool(RegexState, max_states) = .{},
    classes: ct_pool.CtPool([32]u32, max_classes) = .{},
    group_count: u8 = 0,

    fn newState(self: *Compiler, s: RegexState) u32 {
        const p = self.states.create(s);
        return @intCast(p - &self.states.items[0]);
    }

    fn peek(self: *Compiler) u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else 0;
    }

    fn next(self: *Compiler) u8 {
        const c = self.peek();
        if (self.pos < self.pattern.len) self.pos += 1;
        return c;
    }

    /// An unpatched epsilon state: next = next2 = itself.
    fn epsilon(self: *Compiler) u32 {
        const id = self.newState(.{ .kind = kind_epsilon });
        self.states.items[id].next = id;
        self.states.items[id].next2 = id;
        return id;
    }

    fn literal(self: *Compiler, b: u8) Frag {
        const id = self.newState(.{ .kind = kind_literal, .byte = b });
        var f = Frag{ .start = id };
        const e = self.epsilon();
        f.add(e);
        self.states.items[id].next = e;
        return f;
    }

    fn dot(self: *Compiler) Frag {
        const id = self.newState(.{ .kind = kind_dot });
        var f = Frag{ .start = id };
        const e = self.epsilon();
        f.add(e);
        self.states.items[id].next = e;
        return f;
    }

    fn anchorStart(self: *Compiler) Frag {
        const id = self.newState(.{ .kind = kind_anchor_start });
        var f = Frag{ .start = id };
        const e = self.epsilon();
        f.add(e);
        self.states.items[id].next = e;
        return f;
    }

    fn anchorEnd(self: *Compiler) Frag {
        const id = self.newState(.{ .kind = kind_anchor_end });
        var f = Frag{ .start = id };
        const e = self.epsilon();
        f.add(e);
        self.states.items[id].next = e;
        return f;
    }

    /// A class-fragment: consume a byte matching the bitmap. `negate`
    /// complements the class (the `[^...]` form).
    fn classFrag(self: *Compiler, bitmap: [32]u32, negate: bool) Frag {
        var bm = bitmap;
        if (negate) {
            for (&bm) |*w| w.* = ~w.*;
        }
        const class_id: u32 = @intCast(self.classes.len);
        _ = self.classes.create(bm);
        const id = self.newState(.{ .kind = kind_class, .byte = class_id });
        var f = Frag{ .start = id };
        const e = self.epsilon();
        f.add(e);
        self.states.items[id].next = e;
        return f;
    }

    fn parseAlternation(self: *Compiler) RegexErr!Frag {
        const left = try self.parseConcatenation();
        if (self.peek() != '|') return left;
        // Build a chain of alternations: split -> left.start | right.start.
        var acc = left;
        while (self.peek() == '|') {
            _ = self.next();
            const right = try self.parseConcatenation();
            const split = self.epsilon();
            self.states.items[split].next = acc.start;
            self.states.items[split].next2 = right.start;
            // The alternation's outs = acc.outs + right.outs (both branches
            // flow into the split's epsilon chain; the split itself is the
            // start). Each branch's outs stay open (patched by the caller).
            var f = Frag{ .start = split };
            for (acc.out[0..acc.out_count]) |o| f.add(o);
            for (right.out[0..right.out_count]) |o| f.add(o);
            acc = f;
        }
        return acc;
    }

    fn parseConcatenation(self: *Compiler) RegexErr!Frag {
        var result: ?Frag = null;
        var first_start: u32 = 0;
        while (true) {
            const c = self.peek();
            if (c == 0 or c == '|' or c == ')') break;
            const atom_start = self.pos;
            const atom = try self.parseAtom();
            var f = atom;
            // Quantifier?
            const q = self.peek();
            if (q == '*' or q == '+' or q == '?') {
                _ = self.next();
                f = self.quantify(f, q);
            } else if (q == '{') {
                // Unroll `{n,m}` by re-parsing the atom for each repetition:
                // each copy needs FRESH states (reusing the same fragment
                // would self-loop instead of repeat).
                _ = self.next();
                const n = try self.parseNumber();
                var max_val: ?usize = null;
                var bounded = false;
                if (self.peek() == ',') {
                    _ = self.next();
                    if (self.peek() != '}') {
                        max_val = try self.parseNumber();
                    }
                    bounded = true;
                }
                if (self.next() != '}') return error.BadQuantifier;
                // Position just past the closing '}' — restored after each
                // atom re-parse so the loop continues correctly.
                const quant_end = self.pos;
                const min = n;
                // `{n}` exact: max = min. `{n,}` unbounded. `{n,m}` bounded.
                const max = if (!bounded) n else (max_val orelse std.math.maxInt(usize));
                if (min > max) return error.BadQuantifier;
                // min mandatory copies (re-parsed fresh each time).
                var acc = f;
                var i: usize = 1;
                while (i < min) : (i += 1) {
                    self.pos = atom_start;
                    const copy = try self.parseAtom();
                    self.pos = quant_end;
                    acc.patch(self, copy.start);
                    acc = copy;
                }
                if (max == std.math.maxInt(usize)) {
                    // Unbounded: append a `*`-loop over the atom.
                    self.pos = atom_start;
                    const copy = try self.parseAtom();
                    self.pos = quant_end;
                    const loop = self.epsilon();
                    const skip = self.epsilon();
                    self.states.items[loop].next = copy.start;
                    self.states.items[loop].next2 = skip;
                    copy.patch(self, loop);
                    acc.patch(self, loop);
                    // The quantifier's start is the ORIGINAL atom's start;
                    // the outs flow through the loop to skip.
                    f = Frag{ .start = f.start };
                    f.add(skip);
                } else {
                    // (max - min) optional copies.
                    var j = min;
                    while (j < max) : (j += 1) {
                        self.pos = atom_start;
                        const copy = try self.parseAtom();
                        self.pos = quant_end;
                        const split = self.epsilon();
                        const skip = self.epsilon();
                        self.states.items[split].next = copy.start;
                        self.states.items[split].next2 = skip;
                        copy.patch(self, skip);
                        acc.patch(self, split);
                        var r = Frag{ .start = acc.start };
                        r.add(skip);
                        acc = r;
                    }
                    // The quantifier's start is the ORIGINAL atom's start; only
                    // the outs chain changed.
                    f = Frag{ .start = f.start };
                    for (acc.out[0..acc.out_count]) |o| f.add(o);
                }
            }
            if (result) |prev| {
                // Chain: prev.outs -> f.start; the chain's outs become f's.
                prev.patch(self, f.start);
                result = f;
            } else {
                first_start = f.start;
                result = f;
            }
        }
        if (result) |r| {
            // The concatenation's start is the FIRST fragment's start; the
            // outs are the last fragment's (still open).
            var concat = Frag{ .start = first_start };
            for (r.out[0..r.out_count]) |o| concat.add(o);
            return concat;
        }
        // Empty concatenation: a zero-width epsilon fragment.
        const e = self.epsilon();
        var zf = Frag{ .start = e };
        zf.add(e);
        return zf;
    }

    fn parseAtom(self: *Compiler) RegexErr!Frag {
        const c = self.next();
        switch (c) {
            0 => return error.UnbalancedParen,
            '(' => {
                // Capture or non-capture.
                if (self.peek() == '?' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == ':') {
                    self.pos += 2;
                    const inner = try self.parseAlternation();
                    if (self.next() != ')') return error.UnbalancedParen;
                    return inner;
                }
                if (self.group_count >= max_groups) return error.UnbalancedParen;
                const group = self.group_count + 1;
                self.group_count += 1;
                const start_marker = self.newState(.{ .kind = kind_epsilon, .cap_start = @intCast(group) });
                self.states.items[start_marker].next = start_marker;
                self.states.items[start_marker].next2 = start_marker;
                const inner = try self.parseAlternation();
                if (self.next() != ')') return error.UnbalancedParen;
                const end_marker = self.newState(.{ .kind = kind_epsilon, .cap_end = @intCast(group) });
                self.states.items[end_marker].next = end_marker;
                self.states.items[end_marker].next2 = end_marker;
                // Chain: start_marker -> inner.start, inner.outs -> end_marker.
                var f = Frag{ .start = start_marker };
                self.states.items[start_marker].next = inner.start;
                f.add(end_marker);
                inner.patch(self, end_marker);
                return f;
            },
            ')' => return error.UnbalancedParen,
            '[' => return self.parseClass(),
            '.' => return self.dot(),
            '^' => return self.anchorStart(),
            '$' => return self.anchorEnd(),
            '\\' => {
                const e = self.next();
                if (e == 0) return error.DanglingEscape;
                switch (e) {
                    'd' => return self.classFrag(classesDigits, false),
                    'D' => return self.classFrag(classesDigits, true),
                    'w' => return self.classFrag(classesWord, false),
                    'W' => return self.classFrag(classesWord, true),
                    's' => return self.classFrag(classesSpace, false),
                    'S' => return self.classFrag(classesSpace, true),
                    else => {
                        // Escaped metachar: literal.
                        return self.literal(e);
                    },
                }
            },
            '*', '+', '?' => return error.QuantifierNotApplicable,
            '{' => return error.QuantifierNotApplicable,
            else => return self.literal(c),
        }
    }

    fn quantify(self: *Compiler, f: Frag, comptime q: u8) Frag {
        switch (q) {
            '?' => {
                // zero or one: split -> f.start and skip
                const split = self.epsilon();
                self.states.items[split].next = f.start;
                const skip = self.epsilon();
                self.states.items[split].next2 = skip;
                var out = Frag{ .start = split };
                out.add(skip);
                f.patch(self, skip);
                // The fragment's outs now flow into skip's epsilon; keep the
                // outs of the whole: split's two paths both end at skip.
                var r = Frag{ .start = split };
                r.add(skip);
                return r;
            },
            '*' => {
                // zero or more: split -> f.start and skip; f.outs -> split.
                const split = self.epsilon();
                const skip = self.epsilon();
                self.states.items[split].next = f.start;
                self.states.items[split].next2 = skip;
                f.patch(self, split);
                var r = Frag{ .start = split };
                r.add(skip);
                return r;
            },
            '+' => {
                // one or more: f, then a *-loop on the end.
                const loop = self.epsilon();
                const skip = self.epsilon();
                self.states.items[loop].next = f.start;
                self.states.items[loop].next2 = skip;
                f.patch(self, loop);
                var r = Frag{ .start = f.start };
                r.add(skip);
                return r;
            },
            else => unreachable,
        }
    }

    /// `{n}`, `{n,}`, `{n,m}`.
    fn parseNumber(self: *Compiler) RegexErr!usize {
        var v: usize = 0;
        var any = false;
        while (std.ascii.isDigit(self.peek())) {
            v = v * 10 + (self.next() - '0');
            any = true;
        }
        if (!any) return error.EmptyBraces;
        return v;
    }

    fn parseClass(self: *Compiler) RegexErr!Frag {
        // self.pos points just after '['.
        var bitmap = [_]u32{0} ** 32;
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            _ = self.next();
        }
        // A literal ']' as the first member.
        var first = true;
        while (true) {
            const c = self.next();
            if (c == 0) return error.BadClass;
            if (c == ']' and !first) break;
            first = false;
            if (c == '\\') {
                const e = self.next();
                if (e == 0) return error.DanglingEscape;
                switch (e) {
                    'd' => self.setBits(&bitmap, classesDigits),
                    'D' => self.setBits(&bitmap, complement(classesDigits)),
                    'w' => self.setBits(&bitmap, classesWord),
                    'W' => self.setBits(&bitmap, complement(classesWord)),
                    's' => self.setBits(&bitmap, classesSpace),
                    'S' => self.setBits(&bitmap, complement(classesSpace)),
                    else => self.setBit(&bitmap, e),
                }
            } else {
                // Range?
                if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                    _ = self.next(); // '-'
                    const hi = self.next();
                    if (hi == '\\') {
                        const e2 = self.next();
                        if (e2 == 0) return error.DanglingEscape;
                        if (c <= e2) {
                            var b = c;
                            while (b <= e2) : (b += 1) self.setBit(&bitmap, b);
                        }
                    } else {
                        if (c <= hi) {
                            var b = c;
                            while (b <= hi) : (b += 1) self.setBit(&bitmap, b);
                        }
                    }
                } else {
                    self.setBit(&bitmap, c);
                }
            }
        }
        return self.classFrag(bitmap, negate);
    }

    fn setBit(self: *Compiler, bitmap: *[32]u32, b: u8) void {
        _ = self;
        bitmap[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    }

    fn setBits(self: *Compiler, bitmap: *[32]u32, src: [32]u32) void {
        _ = self;
        for (0..32) |i| bitmap[i] |= src[i];
    }
};

const classesDigits = blk: {
    var bm = [_]u32{0} ** 32;
    var b: u8 = '0';
    while (b <= '9') : (b += 1) bm[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    break :blk bm;
};

const classesWord = blk: {
    var bm = [_]u32{0} ** 32;
    var b: u8 = 'a';
    while (b <= 'z') : (b += 1) bm[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    b = 'A';
    while (b <= 'Z') : (b += 1) bm[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    b = '0';
    while (b <= '9') : (b += 1) bm[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    bm['_' / 32] |= @as(u32, 1) << @intCast('_' % 32);
    break :blk bm;
};

const classesSpace = blk: {
    var bm = [_]u32{0} ** 32;
    for ([_]u8{ ' ', '\t', '\r', '\n' }) |b| bm[b / 32] |= @as(u32, 1) << @intCast(b % 32);
    break :blk bm;
};

fn complement(src: [32]u32) [32]u32 {
    var out: [32]u32 = undefined;
    for (0..32) |i| out[i] = ~src[i];
    return out;
}

/// The `Regex` type in vars.zig has no class_bitmaps field yet — extend the
/// match walk accordingly (the type is defined in vars.zig; the engine adds
/// the class table accessor here).
/// Match the compiled regex against `subject` starting at `start`. On
/// success fills `caps[0..group_count+1]` (0 = whole match). `ci` folds the
/// subject to lowercase for `~*` semantics.
///
/// Pike VM (Russ Cox "Regular Expression Matching: the Virtual Machine
/// Approach"): two thread sets per position, epsilon-closure at each step —
/// O(subject × states), linear in the input even for `a*`/alternation-heavy
/// patterns. Each thread carries the capture start/end positions it has
/// accumulated, so group boundaries are recorded exactly. Threads dedupe on
/// (state, starts, ends): two threads at the same state with identical
/// capture state are equivalent.
pub fn match(re: *const Regex, subject: []const u8, caps: []CaptureRange, start: usize, ci: bool) bool {
    if (re.states.len == 0) return false;
    const max_caps = max_groups + 1;

    var curr: [max_threads]Thread = undefined;
    var next: [max_threads]Thread = undefined;
    var curr_len: usize = 0;
    var next_len: usize = 0;
    var matched: ?Thread = null;

    var s = start;
    while (s <= subject.len) : (s += 1) {
        const st0 = re.states[0];
        if (st0.kind == kind_anchor_start and s != 0) {
            // Anchored at start: only position 0 can match.
            if (s > start) break;
            continue;
        }
        // Initial thread: state 0, empty capture state.
        curr_len = 0;
        addThread(&curr, &curr_len, 0, emptyCaps());
        closure(re, &curr, &curr_len, s, subject.len, ci);

        // Check for a match state in the initial closure (empty match).
        matched = findMatch(&curr, curr_len);

        var pos = s;
        while (matched == null and pos < subject.len) : (pos += 1) {
            const ch = if (ci) std.ascii.toLower(subject[pos]) else subject[pos];
            next_len = 0;
            for (curr[0..curr_len]) |t| {
                const st = re.states[t.state];
                if (consumes(st, ch, re)) {
                    addThread(&next, &next_len, st.next, t.caps);
                }
            }
            closure(re, &next, &next_len, pos + 1, subject.len, ci);
            // Swap sets (copy arrays).
            const saved_curr = curr;
            const saved_len = curr_len;
            curr = next;
            curr_len = next_len;
            next = saved_curr;
            _ = saved_len;
            matched = findMatch(&curr, curr_len);
        }
        if (matched) |t| {
            const ng = @min(caps.len, max_caps);
            for (0..ng) |g| {
                caps[g] = .{
                    .start = @intCast(@max(0, t.caps[g].start)),
                    .end = @intCast(@max(0, t.caps[g].end)),
                };
            }
            return true;
        }
        if (st0.kind == kind_anchor_start) break;
    }
    return false;
}

fn emptyCaps() [max_groups + 1]CaptureRange {
    return [_]CaptureRange{.{ .start = 0, .end = 0 }} ** (max_groups + 1);
}

fn findMatch(set: []Thread, len: usize) ?Thread {
    for (set[0..len]) |t| {
        if (t.match) return t;
    }
    return null;
}

fn addThread(set: []Thread, len: *usize, st: u32, caps: [max_groups + 1]CaptureRange) void {
    // Dedup: same state + same capture state is equivalent.
    for (set[0..len.*]) |t| {
        if (t.state == st and capsEqual(&t.caps, &caps)) return;
    }
    if (len.* < max_threads) {
        set[len.*] = .{ .state = st, .caps = caps, .match = false };
        len.* += 1;
    }
}

fn capsEqual(a: *const [max_groups + 1]CaptureRange, b: *const [max_groups + 1]CaptureRange) bool {
    for (0..max_groups + 1) |i| {
        if (a[i].start != b[i].start or a[i].end != b[i].end) return false;
    }
    return true;
}

fn consumes(st: RegexState, ch: u8, re: *const Regex) bool {
    switch (st.kind) {
        kind_literal => return ch == @as(u8, @intCast(st.byte)),
        kind_literal_ci => return ch == @as(u8, @intCast(st.byte)),
        kind_dot => return ch != '\n',
        kind_class, kind_class_ci => {
            const bm = re.class_bitmaps[st.byte];
            return (bm[ch / 32] & (@as(u32, 1) << @intCast(ch % 32))) != 0;
        },
        else => return false,
    }
}

/// Epsilon-closure of a thread set at `pos` (subject end = `subj_len` for
/// `$`). Follows epsilon edges, applying capture markers and anchors.
fn closure(
    re: *const Regex,
    set: []Thread,
    len: *usize,
    pos: usize,
    subj_len: usize,
    ci: bool,
) void {
    _ = ci;
    var i: usize = 0;
    while (i < len.*) : (i += 1) {
        const st = re.states[set[i].state];
        switch (st.kind) {
            kind_match => {
                set[i].match = true;
            },
            kind_epsilon => {
                var caps = set[i].caps;
                if (st.cap_start >= 0) {
                    const g: usize = @intCast(st.cap_start);
                    caps[g] = .{ .start = @intCast(pos), .end = caps[g].end };
                }
                if (st.cap_end >= 0) {
                    const g: usize = @intCast(st.cap_end);
                    caps[g] = .{ .start = caps[g].start, .end = @intCast(pos) };
                }
                addThread(set, len, st.next, caps);
                if (st.next2 != st.next) addThread(set, len, st.next2, caps);
            },
            kind_anchor_start => {
                if (pos == 0) addThread(set, len, st.next, set[i].caps);
            },
            kind_anchor_end => {
                if (pos == subj_len) addThread(set, len, st.next, set[i].caps);
            },
            else => {},
        }
    }
}

const Thread = struct {
    state: u32,
    caps: [max_groups + 1]CaptureRange,
    match: bool,
};

const max_threads = 512;

// ---- tests ----

const testing = std.testing;

fn m(comptime pattern: []const u8, subject: []const u8) bool {
    const re = compileRegex(pattern);
    var caps: [max_groups + 1]CaptureRange = undefined;
    return match(&re, subject, &caps, 0, false);
}

test "regex: literals and anchors" {
    try testing.expect(m("^/api/v1$", "/api/v1"));
    try testing.expect(!m("^/api/v1$", "/api/v1/x"));
    try testing.expect(m("hello", "xxhello world"));
    try testing.expect(m("^abc", "abcdef"));
    try testing.expect(m("cde$", "abcde"));
    try testing.expect(!m("^abc$", "xabcx"));
}

test "regex: dot and escaped metachars" {
    try testing.expect(m("a.c", "abc"));
    try testing.expect(m("a.c", "a.c"));
    try testing.expect(!m("a.c", "a\nc"));
    try testing.expect(m("a\\.c", "a.c"));
    try testing.expect(m("\\$5", "$5"));
    try testing.expect(m("\\*", "*"));
    try testing.expect(m("\\/path", "/path"));
}

test "regex: character classes" {
    try testing.expect(m("^[0-9]+$", "12345"));
    try testing.expect(!m("^[0-9]+$", "12a5"));
    try testing.expect(m("^[a-z]+$", "hello"));
    try testing.expect(m("^[^0-9]+$", "abc"));
    try testing.expect(!m("^[^0-9]+$", "ab1c"));
    try testing.expect(m("^[\\d]+$", "42"));
    try testing.expect(m("^[\\w]+$", "abc_123"));
    try testing.expect(m("^[\\s]+$", " \t\n"));
    try testing.expect(m("^[\\D]+$", "abc"));
    try testing.expect(m("^[\\W]+$", "@!"));
    try testing.expect(m("^[a-f0-9]+$", "deadbeef"));
}

test "regex: quantifiers" {
    try testing.expect(m("^a*$", "aaaa"));
    try testing.expect(m("^a*$", ""));
    try testing.expect(m("^a+$", "a"));
    try testing.expect(!m("^a+$", ""));
    try testing.expect(m("^ab?c$", "ac"));
    try testing.expect(m("^ab?c$", "abc"));
    try testing.expect(m("^a{2}$", "aa"));
    try testing.expect(!m("^a{2}$", "aaa"));
    try testing.expect(m("^a{2,}$", "aaaa"));
    try testing.expect(m("^a{2,3}$", "aaa"));
    try testing.expect(!m("^a{2,3}$", "aaaa"));
}

test "regex: alternation and groups" {
    try testing.expect(m("^(cat|dog)$", "cat"));
    try testing.expect(m("^(cat|dog)$", "dog"));
    try testing.expect(!m("^(cat|dog)$", "cow"));
    try testing.expect(m("^(?:ab)+$", "abab"));
    const re = compileRegex("^/api/([0-9]+)/$");
    var caps: [max_groups + 1]CaptureRange = undefined;
    try testing.expect(match(&re, "/api/42/", &caps, 0, false));
    try testing.expectEqual(@as(u16, 5), caps[1].start);
    try testing.expectEqual(@as(u16, 7), caps[1].end);
}

test "regex: captures slice the subject (M-D captures)" {
    const re = compileRegex("^/api/([0-9]+)/");
    var caps: [max_groups + 1]CaptureRange = undefined;
    const subject = "/api/123/x";
    try testing.expect(match(&re, subject, &caps, 0, false));
    try testing.expectEqualStrings("123", subject[caps[1].start..caps[1].end]);
}

test "regex: case-insensitive matching (~*)" {
    const re = compileRegex("^hello$");
    var caps: [max_groups + 1]CaptureRange = undefined;
    try testing.expect(!match(&re, "HELLO", &caps, 0, false));
    try testing.expect(match(&re, "hello", &caps, 0, false));
    // ~* semantics: ci folds the subject.
    const re_ci = compileRegex("^hello$");
    try testing.expect(match(&re_ci, "HeLLo", &caps, 0, true));
}

test "regex: pathological pattern terminates" {
    const re = compileRegex("(a|a)*a");
    var caps: [max_groups + 1]CaptureRange = undefined;
    const subject = "aaaaaaaaaaaaaaaaaaaa";
    try testing.expect(match(&re, subject, &caps, 0, false));
}

test "regex: braced quantifiers compile and match" {
    try testing.expect(m("^a{2}$", "aa"));
    try testing.expect(!m("^a{2}$", "aaa"));
    try testing.expect(m("^a{2,}$", "aaaa"));
    try testing.expect(m("^a{2,3}$", "aaa"));
    try testing.expect(!m("^a{2,3}$", "aaaa"));
}
