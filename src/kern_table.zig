//! Legacy TrueType 'kern' table: horizontal format 0 pair kerning, used
//! when the font has no GPOS kern lookups (HarfBuzz applies the same
//! rule). Reads both the Microsoft (version 0) and Apple (version 1.0)
//! layouts. Format 2 (class-based, rare outside old Apple fonts) and
//! cross-stream, minimum and variation subtables are skipped.
//!
//! No allocation: subtables are slices into the font data, so a value
//! copy (per-document FontFace clones) stays valid as long as the data.

const std = @import("std");

pub const max_subtables = 8;

pub const KernTable = struct {
    subtables: [max_subtables]Subtable = undefined,
    count: u8 = 0,

    const Subtable = struct {
        /// nPairs records of (left u16, right u16, value i16), sorted by
        /// (left << 16 | right).
        pairs: []const u8,
        /// Coverage "override": replaces the sum so far instead of adding.
        override: bool,
    };

    /// Parse the table; malformed or unsupported subtables are skipped.
    pub fn parse(data: []const u8) KernTable {
        var t: KernTable = .{};
        if (data.len < 4) return t;
        const apple = readU16(data, 0) == 1 and readU16(data, 2) == 0;
        var pos: usize = if (apple) 8 else 4;
        if (pos > data.len) return t;
        const n_tables: u32 = if (apple) readU32(data, 4) else readU16(data, 2);

        var i: u32 = 0;
        while (i < n_tables and t.count < max_subtables) : (i += 1) {
            const header_len: usize = if (apple) 8 else 6;
            if (pos + header_len > data.len) break;
            const length: usize = if (apple) readU32(data, pos) else readU16(data, pos + 2);
            const coverage = readU16(data, pos + 4);
            const format: u8, const usable = if (apple)
                .{ @truncate(coverage), coverage & 0xE000 == 0 } // not vertical/cross-stream/variation
            else
                .{ @truncate(coverage >> 8), coverage & 0x07 == 0x01 }; // horizontal, not minimum/cross-stream
            const body = pos + header_len;

            if (usable and format == 0 and body + 8 <= data.len) {
                // The pair count, not the 16-bit length, bounds the pairs:
                // large tables overflow the Microsoft length field.
                const n_pairs: usize = readU16(data, body);
                const start = body + 8;
                const end = @min(start + n_pairs * 6, data.len);
                const whole = end - start - (end - start) % 6;
                t.subtables[t.count] = .{
                    .pairs = data[start..][0..whole],
                    .override = !apple and coverage & 0x08 != 0,
                };
                t.count += 1;
            }
            if (length < header_len) break; // cannot advance
            pos += length;
        }
        return t;
    }

    /// Total pairs over all usable subtables.
    pub fn pairCount(self: *const KernTable) usize {
        var n: usize = 0;
        for (self.subtables[0..self.count]) |s| n += s.pairs.len / 6;
        return n;
    }

    /// Kerning for the glyph pair in font units (0 when none).
    pub fn get(self: *const KernTable, left: u16, right: u16) i16 {
        const key = (@as(u32, left) << 16) | right;
        var sum: i32 = 0;
        for (self.subtables[0..self.count]) |s| {
            const v = lookup(s.pairs, key) orelse continue;
            sum = if (s.override) v else sum + v;
        }
        return @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    fn lookup(pairs: []const u8, key: u32) ?i16 {
        var lo: usize = 0;
        var hi: usize = pairs.len / 6;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = readU32(pairs, mid * 6);
            if (k == key) return @bitCast(readU16(pairs, mid * 6 + 4));
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Microsoft-layout table from (coverage, pairs) subtables.
fn msTable(buf: []u8, subs: []const struct { coverage: u16, pairs: []const [3]i32 }) []const u8 {
    var w: usize = 4;
    std.mem.writeInt(u16, buf[0..2], 0, .big);
    std.mem.writeInt(u16, buf[2..4], @intCast(subs.len), .big);
    for (subs) |s| {
        const len = 14 + s.pairs.len * 6;
        std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
        std.mem.writeInt(u16, buf[w + 2 ..][0..2], @intCast(len), .big);
        std.mem.writeInt(u16, buf[w + 4 ..][0..2], s.coverage, .big);
        std.mem.writeInt(u16, buf[w + 6 ..][0..2], @intCast(s.pairs.len), .big);
        @memset(buf[w + 8 ..][0..6], 0); // searchRange etc. (unused)
        for (s.pairs, 0..) |p, j| {
            const o = w + 14 + j * 6;
            std.mem.writeInt(u16, buf[o..][0..2], @intCast(p[0]), .big);
            std.mem.writeInt(u16, buf[o + 2 ..][0..2], @intCast(p[1]), .big);
            std.mem.writeInt(i16, buf[o + 4 ..][0..2], @intCast(p[2]), .big);
        }
        w += len;
    }
    return buf[0..w];
}

test "kern format 0: lookup, sum across subtables, override, skipped kinds" {
    var buf: [256]u8 = undefined;
    const data = msTable(&buf, &.{
        .{ .coverage = 0x0001, .pairs = &.{ .{ 1, 2, -50 }, .{ 1, 3, 20 }, .{ 4, 1, -7 } } },
        .{ .coverage = 0x0001, .pairs = &.{.{ 1, 2, -5 }} }, // adds
        .{ .coverage = 0x0003, .pairs = &.{.{ 1, 3, 999 }} }, // minimum: skipped
        .{ .coverage = 0x0005, .pairs = &.{.{ 1, 3, 999 }} }, // cross-stream: skipped
        .{ .coverage = 0x0000, .pairs = &.{.{ 1, 3, 999 }} }, // vertical: skipped
        .{ .coverage = 0x0201, .pairs = &.{.{ 1, 3, 999 }} }, // format 2: skipped
        .{ .coverage = 0x0009, .pairs = &.{.{ 4, 1, 11 }} }, // override
    });
    const t = KernTable.parse(data);
    try testing.expectEqual(@as(u8, 3), t.count);
    try testing.expectEqual(@as(i16, -55), t.get(1, 2));
    try testing.expectEqual(@as(i16, 20), t.get(1, 3));
    try testing.expectEqual(@as(i16, 11), t.get(4, 1));
    try testing.expectEqual(@as(i16, 0), t.get(2, 1));
    try testing.expectEqual(@as(i16, 0), t.get(0, 0));
}

test "kern format 0: Apple version 1.0 layout" {
    var buf: [64]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    // Subtable 1: horizontal format 0, two pairs
    std.mem.writeInt(u32, buf[8..12], 8 + 8 + 12, .big);
    std.mem.writeInt(u16, buf[12..14], 0x0000, .big);
    std.mem.writeInt(u16, buf[16..18], 2, .big);
    const p = buf[24..];
    std.mem.writeInt(u16, p[0..2], 5, .big);
    std.mem.writeInt(u16, p[2..4], 6, .big);
    std.mem.writeInt(i16, p[4..6], -40, .big);
    std.mem.writeInt(u16, p[6..8], 5, .big);
    std.mem.writeInt(u16, p[8..10], 7, .big);
    std.mem.writeInt(i16, p[10..12], 15, .big);
    // Subtable 2: vertical (0x8000) - skipped
    std.mem.writeInt(u32, buf[36..40], 8 + 8, .big);
    std.mem.writeInt(u16, buf[40..42], 0x8000, .big);
    const t = KernTable.parse(buf[0..52]);
    try testing.expectEqual(@as(u8, 1), t.count);
    try testing.expectEqual(@as(i16, -40), t.get(5, 6));
    try testing.expectEqual(@as(i16, 15), t.get(5, 7));
    try testing.expectEqual(@as(i16, 0), t.get(6, 5));
}

test "kern: truncated and hostile tables never read out of bounds" {
    var buf: [256]u8 = undefined;
    const good = msTable(&buf, &.{.{ .coverage = 0x0001, .pairs = &.{ .{ 1, 2, -50 }, .{ 3, 4, 9 } } }});
    // Every truncation parses without reading past the end
    for (0..good.len + 1) |n| {
        const t = KernTable.parse(good[0..n]);
        _ = t.get(1, 2);
        _ = t.get(3, 4);
    }
    // Last pair cut in half: the whole first pair still kerns
    try testing.expectEqual(@as(i16, -50), KernTable.parse(good[0 .. good.len - 3]).get(1, 2));

    // nPairs far beyond the data, zero-length subtables, huge table count
    var bad = buf;
    std.mem.writeInt(u16, bad[10..12], 0xFFFF, .big); // nPairs
    _ = KernTable.parse(bad[0..good.len]).get(3, 4);
    std.mem.writeInt(u16, bad[2..4], 0xFFFF, .big); // nTables
    std.mem.writeInt(u16, bad[6..8], 0, .big); // length 0
    _ = KernTable.parse(bad[0..good.len]).get(1, 2);
}

test "kern: 16-bit length overflow is ignored (pair count bounds the pairs)" {
    var buf: [256]u8 = undefined;
    const data = msTable(&buf, &.{.{ .coverage = 0x0001, .pairs = &.{ .{ 1, 2, -50 }, .{ 3, 4, 9 } } }});
    std.mem.writeInt(u16, buf[6..8], 7, .big); // wrapped length
    try testing.expectEqual(@as(i16, 9), KernTable.parse(data).get(3, 4));
}

/// Every pair in `tsv_path` (left, right, value; from fontTools via
/// scripts/gen_kern_fonts.py) reads back from the font's table, and the
/// table holds exactly `expected` pairs, so none are missing or extra.
fn expectPairs(font_path: []const u8, tsv_path: []const u8, expected: usize) !void {
    const font = try std.Io.Dir.cwd().readFileAlloc(testing.io, font_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(font);
    const tsv = try std.Io.Dir.cwd().readFileAlloc(testing.io, tsv_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(tsv);

    const parsed = try @import("ttf.zig").Font.parse(font);
    const t = KernTable.parse(parsed.getTable("kern".*) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(expected, t.pairCount());

    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
    while (lines.next()) |line| : (n += 1) {
        var f = std.mem.tokenizeScalar(u8, line, '\t');
        const l = try std.fmt.parseInt(u16, f.next().?, 10);
        const r = try std.fmt.parseInt(u16, f.next().?, 10);
        const v = try std.fmt.parseInt(i16, f.next().?, 10);
        try testing.expectEqual(v, t.get(l, r));
    }
    try testing.expectEqual(expected, n);
}

test "kern: Charter-derived table matches every HarfBuzz pair" {
    // Charter's GPOS kerning moved to a format 0 table
    try expectPairs("test/fonts/kern/CharterKern.ttf", "test/reference/charter_kern_pairs.tsv", 160);
}

test "kern: unmodified Bitstream Vera Sans 1.10 reads every pair" {
    // A real legacy font: one format 0 'kern' subtable, no GPOS
    try expectPairs("test/fonts/Bitstream Vera/Vera.ttf", "test/reference/vera_kern_pairs.tsv", 1940);
}

fn measureWith(path: []const u8, text: []const u8, kern: bool) !f64 {
    const Document = @import("document.zig").Document;
    var doc = Document.init(testing.allocator, testing.io);
    defer doc.deinit();
    const font = try doc.loadFont(path, .identity);
    if (!kern) try doc.setFeature(.kern, false);
    return (try doc.measureStyled(text, .{ .font = font, .size = 100 })).width;
}

const kern_sample = "AVATAR Toyota WAVE \"LT\" P.";

test "kern table: a kern-only font measures like the GPOS original" {
    // CharterKern.ttf = Charter Regular with its GPOS pairs moved to 'kern'
    const gpos = try measureWith("test/fonts/Charter/Charter Regular.ttf", kern_sample, true);
    const legacy = try measureWith("test/fonts/kern/CharterKern.ttf", kern_sample, true);
    const plain = try measureWith("test/fonts/kern/CharterKern.ttf", kern_sample, false);
    try testing.expect(plain - gpos > 50); // the sample really kerns (100pt)
    try testing.expectEqual(gpos, legacy);
}

test "kern table: ignored when GPOS has kerning" {
    // CharterKernGpos.ttf: GPOS kept, 'kern' values all -300 (wrong)
    const gpos = try measureWith("test/fonts/Charter/Charter Regular.ttf", kern_sample, true);
    const both = try measureWith("test/fonts/kern/CharterKernGpos.ttf", kern_sample, true);
    try testing.expectEqual(gpos, both);
}
