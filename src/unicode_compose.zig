//! Canonical composition of combining sequences, as HarfBuzz normalizes
//! before shaping: a base followed by combining marks becomes the
//! precomposed character when the font has a glyph for it ("i" + U+0308
//! -> U+00EF), otherwise the sequence stays decomposed for GPOS mark
//! positioning. Data: unicode_compose_data.zig (generated).

const std = @import("std");
const data = @import("unicode_compose_data.zig");

/// First code point that can be a combining mark in a composition pair
/// (U+0300 COMBINING GRAVE ACCENT); text below it never composes.
pub const first_mark: u21 = 0x0300;

/// Canonical combining class (0 for starters and unlisted code points).
/// HarfBuzz's modified combining class (_hb_modified_combining_class), by
/// which marks are put in order before shaping: Hebrew points in SBL
/// order, Arabic shadda first, Telugu length marks and Thai sara u/uu
/// before the virama, Tibetan sign u before sign i; and three special
/// cases (Tai Tham sakot, Tibetan tsa-phru).
pub fn modifiedCombiningClass(cp: u21) u8 {
    switch (cp) {
        0x1A60, 0x0FC6 => return 254,
        0x0F39 => return 127,
        else => {},
    }
    const ccc = combiningClass(cp);
    return switch (ccc) {
        // Hebrew
        10 => 22,
        11 => 15,
        12 => 16,
        13 => 17,
        14 => 23,
        15 => 18,
        16 => 19,
        17 => 20,
        18 => 21,
        19 => 14,
        20 => 24,
        21 => 12,
        22 => 25,
        23 => 13,
        24 => 10,
        25 => 11,
        // Arabic: shadda (33) before the others
        27 => 28,
        28 => 29,
        29 => 30,
        30 => 31,
        31 => 32,
        32 => 33,
        33 => 27,
        // Telugu length marks, Thai sara u/uu, Tibetan sign i/u
        84 => 4,
        91 => 5,
        103 => 3,
        130 => 132,
        132 => 131,
        else => ccc,
    };
}

/// HarfBuzz's mark reordering (normalization round 2): each run of code
/// points with a nonzero modified combining class, up to 32 long, is
/// sorted stably by that class. `offsets` (optional, same length) moves
/// along.
pub fn reorderMarks(cps: []u21, offsets: ?[]u32) void {
    const max_run = 32;
    var i: usize = 0;
    while (i < cps.len) {
        if (modifiedCombiningClass(cps[i]) == 0) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < cps.len and modifiedCombiningClass(cps[end]) != 0) end += 1;
        if (end - i <= max_run) {
            // Insertion sort: stable, and runs are short
            var k = i + 1;
            while (k < end) : (k += 1) {
                const cp = cps[k];
                const off = if (offsets) |o| o[k] else 0;
                const cc = modifiedCombiningClass(cp);
                var j = k;
                while (j > i and modifiedCombiningClass(cps[j - 1]) > cc) : (j -= 1) {
                    cps[j] = cps[j - 1];
                    if (offsets) |o| o[j] = o[j - 1];
                }
                cps[j] = cp;
                if (offsets) |o| o[j] = off;
            }
        }
        i = end;
    }
}

pub fn combiningClass(cp: u21) u8 {
    if (cp < first_mark) return 0;
    const ranges = &data.ccc_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].first) {
            hi = mid;
        } else if (cp > ranges[mid].last) {
            lo = mid + 1;
        } else {
            return ranges[mid].ccc;
        }
    }
    return 0;
}

/// Primary composite of `a` + combining mark `b`, if any.
pub fn compose(a: u21, b: u21) ?u21 {
    const pairs = &data.pairs;
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const p = pairs[mid];
        if (a < p.a or (a == p.a and b < p.b)) {
            hi = mid;
        } else if (a > p.a or b > p.b) {
            lo = mid + 1;
        } else {
            return p.c;
        }
    }
    return null;
}

/// Full canonical decomposition of a composite from `pairs` into `buf`
/// (e.g. U+1EC7 -> e, U+0323, U+0302); a code point that is not a
/// composite is returned as itself. `buf` must hold the result (4 is
/// enough for every pair-built composite).
pub fn decompose(c: u21, buf: []u21) []u21 {
    // The first primary composite is U+00C0
    if (c < 0xC0) {
        buf[0] = c;
        return buf[0..1];
    }
    for (data.pairs) |p| {
        if (p.c == c) {
            const head = decompose(p.a, buf);
            buf[head.len] = p.b;
            return buf[0 .. head.len + 1];
        }
    }
    buf[0] = c;
    return buf[0..1];
}

/// Compose combining sequences in `cps` in place and return the new
/// length. A mark composes with the last starter unless blocked (an
/// intervening uncomposed mark of equal or higher combining class), and
/// only when `ctx.hasGlyph(composite)`. Input is expected in canonical
/// order (as typed text is); nothing is reordered. If given, `composed`
/// (same length as `cps`) gets, per output position, whether that code
/// point was composed from a decomposed sequence. `offsets` (same length,
/// optional) moves with the code points: a composite keeps its base's.
pub fn composeInPlace(cps: []u21, composed: ?[]bool, offsets: ?[]u32, ctx: anytype) usize {
    var out: usize = 0;
    var starter: ?usize = null;
    var last_ccc: u8 = 0; // class of the last uncomposed mark after the starter
    for (cps, 0..) |cp, in| {
        const ccc = combiningClass(cp);
        if (ccc != 0) {
            if (starter) |s| {
                const unblocked = out == s + 1 or last_ccc < ccc;
                if (unblocked) {
                    if (compose(cps[s], cp)) |c| {
                        if (ctx.hasGlyph(c)) {
                            cps[s] = c;
                            if (composed) |flags| flags[s] = true;
                            continue;
                        }
                    }
                }
            }
            last_ccc = ccc;
        } else {
            starter = out;
            last_ccc = 0;
        }
        cps[out] = cp;
        if (composed) |flags| flags[out] = false;
        if (offsets) |o| o[out] = o[in];
        out += 1;
    }
    return out;
}

const AllGlyphs = struct {
    fn hasGlyph(_: AllGlyphs, _: u21) bool {
        return true;
    }
};

fn expectComposed(input: []const u21, expected: []const u21, ctx: anytype) !void {
    var buf: [16]u21 = undefined;
    @memcpy(buf[0..input.len], input);
    const n = composeInPlace(buf[0..input.len], null, null, ctx);
    try std.testing.expectEqualSlices(u21, expected, buf[0..n]);
}

test "compose looks up primary composites" {
    try std.testing.expectEqual(@as(?u21, 0x00EF), compose('i', 0x0308)); // ï
    try std.testing.expectEqual(@as(?u21, 0x00E9), compose('e', 0x0301)); // é
    try std.testing.expectEqual(@as(?u21, null), compose('q', 0x0301)); // no q́
    // Composition exclusion: U+0958 (DEVANAGARI QA) is never recomposed
    try std.testing.expectEqual(@as(?u21, null), compose(0x0915, 0x093C));
}

test "combiningClass" {
    try std.testing.expectEqual(@as(u8, 0), combiningClass('a'));
    try std.testing.expectEqual(@as(u8, 230), combiningClass(0x0301));
    try std.testing.expectEqual(@as(u8, 220), combiningClass(0x0323));
    try std.testing.expectEqual(@as(u8, 202), combiningClass(0x0327)); // cedilla
}

test "composeInPlace composes, chains, and respects blocking" {
    const all = AllGlyphs{};
    // naïve
    try expectComposed(&.{ 'n', 'a', 'i', 0x0308, 'v', 'e' }, &.{ 'n', 'a', 0x00EF, 'v', 'e' }, all);
    // ệ: e + dot below (220) + circumflex (230) -> ẹ -> ệ
    try expectComposed(&.{ 'e', 0x0323, 0x0302 }, &.{0x1EC7}, all);
    // No composite: q + acute stays decomposed
    try expectComposed(&.{ 'q', 0x0301, 'x' }, &.{ 'q', 0x0301, 'x' }, all);
    // Blocked: q + acute (uncomposed, 230) blocks a following 230 mark,
    // but a starter resets: a + grave still composes
    try expectComposed(&.{ 'q', 0x0301, 0x0300, 'a', 0x0300 }, &.{ 'q', 0x0301, 0x0300, 0x00E0 }, all);
}

test "composeInPlace reports composed positions and moves offsets" {
    var cps = [_]u21{ 0x00E9, 'e', 0x0301, 'x' }; // é typed precomposed, then e + acute
    var flags: [4]bool = undefined;
    // UTF-8 byte offsets of "\u{E9}e\u{301}x"
    var offsets = [_]u32{ 0, 2, 3, 5 };
    const n = composeInPlace(&cps, &flags, &offsets, AllGlyphs{});
    try std.testing.expectEqualSlices(u21, &.{ 0x00E9, 0x00E9, 'x' }, cps[0..n]);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, flags[0..n]);
    // The composite keeps its base's offset; the acute's is gone
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 5 }, offsets[0..n]);
}

test "decompose inverts chained compositions" {
    var buf: [4]u21 = undefined;
    try std.testing.expectEqualSlices(u21, &.{ 'e', 0x0323, 0x0302 }, decompose(0x1EC7, &buf)); // ệ
    try std.testing.expectEqualSlices(u21, &.{ 'i', 0x0308 }, decompose(0x00EF, &buf));
    try std.testing.expectEqualSlices(u21, &.{'x'}, decompose('x', &buf));
}

test "composeInPlace keeps sequences the font cannot show precomposed" {
    const NoIdieresis = struct {
        fn hasGlyph(_: @This(), cp: u21) bool {
            return cp != 0x00EF;
        }
    };
    try expectComposed(&.{ 'i', 0x0308, 'e', 0x0301 }, &.{ 'i', 0x0308, 0x00E9 }, NoIdieresis{});
}

test "reorderMarks sorts mark runs by modified combining class, stably" {
    // m, acute (230), dot below (220), n: the dot below goes first
    var cps = [_]u21{ 'm', 0x0301, 0x0323, 'n', 0x0300, 0x0301 };
    var offsets = [_]u32{ 0, 1, 3, 5, 6, 8 };
    reorderMarks(&cps, &offsets);
    try std.testing.expectEqualSlices(u21, &.{ 'm', 0x0323, 0x0301, 'n', 0x0300, 0x0301 }, &cps);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 1, 5, 6, 8 }, &offsets);
    // Arabic: fatha (30) then shadda (33) - shadda moves first
    var ar = [_]u21{ 0x0644, 0x064E, 0x0651 };
    reorderMarks(&ar, null);
    try std.testing.expectEqualSlices(u21, &.{ 0x0644, 0x0651, 0x064E }, &ar);
}
