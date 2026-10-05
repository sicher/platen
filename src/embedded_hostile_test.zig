//! Hostile-metrics regression tests for EmbeddedFont (2026-10-05 audit).
//! Scaled font metrics are narrowed to u16/i16 and summed in fixed-width
//! accumulators; a font with tiny unitsPerEm or extreme values made those
//! conversions panic. Subsetting tests: glyph sets, loca and CFF layouts
//! from hostile tables.

const std = @import("std");
const embedded = @import("embedded.zig");

const EmbeddedFont = embedded.EmbeddedFont;

const Spec = struct {
    upem: u16 = 1000,
    ascent: i16 = 800,
    descent: i16 = -200,
    advance: u16 = 500,
    num_glyphs: u16 = 2,
    /// One format-12 cmap group: [cmap_start, cmap_end] -> cmap_glyph...
    cmap_start: u32 = 0x20,
    cmap_end: u32 = 0x7E,
    cmap_glyph: u32 = 1,
    /// glyf/loca: every glyph spans glyf[0..glyph_len] (overlapping, as a
    /// hostile font may declare); short (offset/2) or long loca.
    glyf_len: u32 = 0,
    loca_short: bool = false,
    /// If set, an OpenType/CFF font: this is the "CFF " table (no glyf/loca).
    cff: ?[]const u8 = null,
};

/// Minimal sfnt: head, hhea, maxp, hmtx (num_glyphs long metrics, glyph 1+
/// at `advance`), a one-group format-12 cmap, and glyf/loca or CFF.
fn buildFont(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    const loca_entry: usize = if (spec.loca_short) 2 else 4;
    const n: usize = spec.num_glyphs;
    var tags: [7]*const [4]u8 = undefined;
    var lens: [7]usize = undefined;
    var count: usize = 0;
    for ([_]*const [4]u8{ "head", "hhea", "maxp", "hmtx", "cmap" }, [_]usize{ 54, 36, 6, n * 4, 40 }) |t, l| {
        tags[count] = t;
        lens[count] = l;
        count += 1;
    }
    if (spec.cff) |cff| {
        tags[count] = "CFF ";
        lens[count] = cff.len;
        count += 1;
    } else {
        tags[count] = "loca";
        lens[count] = (n + 1) * loca_entry;
        tags[count + 1] = "glyf";
        lens[count + 1] = spec.glyf_len;
        count += 2;
    }

    var total: usize = 12 + count * 16;
    for (lens[0..count]) |l| total += (l + 3) & ~@as(usize, 3);
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], if (spec.cff != null) 0x4F54544F else 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], @intCast(count), .big);
    var off: usize = 12 + count * 16;
    var start: [7]usize = undefined;
    for (tags[0..count], lens[0..count], 0..) |tag, len, k| {
        const rec = buf[12 + k * 16 ..][0..16];
        @memcpy(rec[0..4], tag);
        std.mem.writeInt(u32, rec[8..12], @intCast(off), .big);
        std.mem.writeInt(u32, rec[12..16], @intCast(len), .big);
        start[k] = off;
        off += (len + 3) & ~@as(usize, 3);
    }

    const head = buf[start[0]..][0..54];
    std.mem.writeInt(u16, head[18..20], spec.upem, .big);
    std.mem.writeInt(i16, head[50..52], if (spec.loca_short) 0 else 1, .big);
    const hhea = buf[start[1]..][0..36];
    std.mem.writeInt(i16, hhea[4..6], spec.ascent, .big);
    std.mem.writeInt(i16, hhea[6..8], spec.descent, .big);
    std.mem.writeInt(u16, hhea[34..36], spec.num_glyphs, .big); // numOfLongHorMetrics
    const maxp = buf[start[2]..][0..6];
    std.mem.writeInt(u32, maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, maxp[4..6], spec.num_glyphs, .big);
    const hmtx = buf[start[3]..][0 .. n * 4];
    for (1..n) |g| std.mem.writeInt(u16, hmtx[g * 4 ..][0..2], spec.advance, .big);
    const cmap = buf[start[4]..][0..40];
    std.mem.writeInt(u16, cmap[2..4], 1, .big); // numTables
    std.mem.writeInt(u16, cmap[4..6], 3, .big); // platform Windows
    std.mem.writeInt(u16, cmap[6..8], 10, .big); // encoding UCS-4
    std.mem.writeInt(u32, cmap[8..12], 12, .big); // subtable offset
    const sub = cmap[12..40];
    std.mem.writeInt(u16, sub[0..2], 12, .big); // format 12
    std.mem.writeInt(u32, sub[4..8], 28, .big); // length
    std.mem.writeInt(u32, sub[12..16], 1, .big); // numGroups
    std.mem.writeInt(u32, sub[16..20], spec.cmap_start, .big);
    std.mem.writeInt(u32, sub[20..24], spec.cmap_end, .big);
    std.mem.writeInt(u32, sub[24..28], spec.cmap_glyph, .big);

    if (spec.cff) |cff| {
        @memcpy(buf[start[5]..][0..cff.len], cff);
    } else {
        // Hostile, non-monotonic loca: entries alternate 0, glyf_len, 0, ...
        // so every even glyph spans glyf[0..glyf_len] (overlapping) and every
        // odd glyph is empty.
        const loca = buf[start[5]..][0 .. (n + 1) * loca_entry];
        for (0..n + 1) |k| {
            const v: u32 = if (k % 2 == 1) spec.glyf_len else 0;
            if (spec.loca_short) {
                std.mem.writeInt(u16, loca[k * 2 ..][0..2], @intCast(v / 2), .big);
            } else {
                std.mem.writeInt(u32, loca[k * 4 ..][0..4], v, .big);
            }
        }
    }
    return buf;
}

fn load(spec: Spec) !*EmbeddedFont {
    const data = try buildFont(std.testing.allocator, spec);
    return EmbeddedFont.fromMemory(std.testing.allocator, data, true) catch |err| {
        std.testing.allocator.free(data);
        return err;
    };
}

test "builder font loads and measures (sanity)" {
    const font = try load(.{});
    defer font.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), font.measureTextWidth("A", 10), 1e-9);
}

test "unitsPerEm outside 16..16384 is rejected" {
    for ([_]u16{ 1, 15, 16385, 0xFFFF }) |upem| {
        try std.testing.expectError(error.InvalidFont, load(.{ .upem = upem, .advance = 1 }));
    }
    const lo = try load(.{ .upem = 16, .ascent = 12, .descent = -4, .advance = 8 });
    lo.deinit();
    const hi = try load(.{ .upem = 16384 });
    hi.deinit();
}

test "advance widths that do not fit u16 once scaled are rejected" {
    // upem 16 scales by 62.5: 0x8000 -> 2,048,000 (panicked in @intFromFloat).
    try std.testing.expectError(error.InvalidFont, load(.{ .upem = 16, .ascent = 12, .descent = -4, .advance = 0x8000 }));
    // The largest representable advance still loads.
    const ok = try load(.{ .upem = 1000, .advance = 0xFFFF });
    ok.deinit();
}

test "vertical metrics that do not fit i16 once scaled are rejected" {
    try std.testing.expectError(error.InvalidFont, load(.{ .upem = 16, .ascent = 0x7FFF, .advance = 8 }));
    try std.testing.expectError(error.InvalidFont, load(.{ .upem = 16, .descent = -0x8000, .advance = 8 }));
}

test "long text with maximal widths does not overflow width accumulators" {
    // 65,535 units per glyph: 70,000 glyphs pass both u32 (WinAnsi sum)
    // and i32 (identity sum) accumulators.
    const text = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'A');
    const expected: f64 = 70_000.0 * 65_535.0 / 1000.0;

    const font = try load(.{ .advance = 0xFFFF });
    defer font.deinit();
    try std.testing.expectApproxEqRel(expected, font.measureTextWidth(text, 1), 1e-12);

    const glyphs = try std.testing.allocator.alloc(u16, 70_000);
    defer std.testing.allocator.free(glyphs);
    @memset(glyphs, 1);
    try std.testing.expectApproxEqRel(expected, font.glyphSequenceWidth(glyphs, 1, 0), 1e-12);

    font.encoding = .win_ansi;
    try std.testing.expectApproxEqRel(expected, font.measureTextWidth(text, 1), 1e-12);
}

// ----------------------------------------------------------------------------
// Subsetting (2026-10-05 audit)
// ----------------------------------------------------------------------------

fn markUsed(font: *EmbeddedFont, text: []const u8) !void {
    const gids = try font.markUnicodeCharsUsed(text, std.testing.allocator);
    std.testing.allocator.free(gids);
}

test "compact subset ignores glyph IDs past numGlyphs (65,536 IDs used)" {
    // cmap U+10000..U+1FFFF -> glyphs 0..0xFFFF: every u16 glyph ID, one
    // more than a font can have. The subset glyph count (u16) overflowed.
    const font = try load(.{ .num_glyphs = 0xFFFF, .cmap_start = 0x10000, .cmap_end = 0x1FFFF, .cmap_glyph = 0 });
    defer font.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var cp: u21 = 0x10000;
    while (cp <= 0x1FFFF) : (cp += 1) {
        var b: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &b);
        try text.appendSlice(std.testing.allocator, b[0..n]);
    }
    try markUsed(font, text.items);
    try font.generateSubset();
    try std.testing.expect(font.gid_remap.get(0xFFFE) != null);
    try std.testing.expect(font.gid_remap.get(0xFFFF) == null); // does not exist
}

test "short-loca subset larger than 128 KB is an invalid font" {
    // Even glyphs all span the same 64 KB (hostile overlapping loca), so
    // .notdef + glyph 2 make a 128 KB subset glyf: past what short loca
    // (offset / 2 in u16) can address.
    for ([_]embedded.FontEncoding{ .identity, .win_ansi }) |enc| {
        const font = try load(.{ .num_glyphs = 4, .cmap_start = 'A', .cmap_end = 'A', .cmap_glyph = 2, .glyf_len = 0x10000, .loca_short = true });
        defer font.deinit();
        font.encoding = enc;
        if (enc == .identity) try markUsed(font, "A") else font.markCharsUsed("A");
        try std.testing.expectError(error.InvalidFont, font.generateSubset());
    }
}

/// CFF table: header, empty Name INDEX, Top DICT INDEX holding
/// `CharStrings <cs_offset>`, empty String and Global Subr INDEXes, then
/// `charstrings` at cs_offset (19).
fn testCff(buf: []u8, charstrings: []const u8) []const u8 {
    const prefix = [_]u8{
        1, 0, 4, 1, // header
        0, 0, // Name INDEX (empty)
        0, 1, 1, 1, 5, 28, 0, 19, 17, // Top DICT INDEX: "19 CharStrings"
        0, 0, // String INDEX
        0, 0, // Global Subr INDEX
    };
    @memcpy(buf[0..prefix.len], &prefix);
    @memcpy(buf[prefix.len..][0..charstrings.len], charstrings);
    return buf[0 .. prefix.len + charstrings.len];
}

fn expectCffSubsetError(cff: []const u8, expected: anyerror) !void {
    const font = try load(.{ .cmap_start = 'A', .cmap_end = 'A', .cmap_glyph = 1, .cff = cff });
    defer font.deinit();
    try markUsed(font, "A");
    try std.testing.expectError(expected, font.generateSubset());
}

test "truncated CFF table is invalid, not an out-of-bounds read" {
    try expectCffSubsetError(&.{ 1, 0 }, error.InvalidCFF);
}

test "CharStrings INDEX cut off before offSize is invalid" {
    var buf: [64]u8 = undefined;
    try expectCffSubsetError(testCff(&buf, &.{ 0, 1 }), error.InvalidCFF);
}

test "CharString ending past the CFF data is not sliced" {
    // count 1, offSize 1, offsets [1, 200], no data. (The font then fails
    // for lacking a charset - after the CharStrings are read safely.)
    var buf: [64]u8 = undefined;
    try expectCffSubsetError(testCff(&buf, &.{ 0, 1, 1, 1, 200 }), error.InvalidCFF);
}
