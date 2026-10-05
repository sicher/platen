//! Hostile-metrics regression tests for EmbeddedFont (2026-10-05 audit).
//! Scaled font metrics are narrowed to u16/i16 and summed in fixed-width
//! accumulators; a font with tiny unitsPerEm or extreme values made those
//! conversions panic.

const std = @import("std");
const embedded = @import("embedded.zig");

const EmbeddedFont = embedded.EmbeddedFont;

const Spec = struct {
    upem: u16 = 1000,
    ascent: i16 = 800,
    descent: i16 = -200,
    advance: u16 = 500,
};

/// Minimal TrueType font: head, hhea, maxp, hmtx (2 glyphs) and a
/// format-12 cmap mapping U+0020..U+007E to glyph 1.
fn buildFont(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    const tags = [_]*const [4]u8{ "head", "hhea", "maxp", "hmtx", "cmap" };
    const lens = [_]usize{ 54, 36, 6, 8, 40 };
    var total: usize = 12 + tags.len * 16;
    for (lens) |l| total += l;
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], tags.len, .big);
    var off: usize = 12 + tags.len * 16;
    var starts: [tags.len]usize = undefined;
    for (tags, lens, 0..) |tag, len, k| {
        const rec = buf[12 + k * 16 ..][0..16];
        @memcpy(rec[0..4], tag);
        std.mem.writeInt(u32, rec[8..12], @intCast(off), .big);
        std.mem.writeInt(u32, rec[12..16], @intCast(len), .big);
        starts[k] = off;
        off += len;
    }

    const head = buf[starts[0]..][0..54];
    std.mem.writeInt(u16, head[18..20], spec.upem, .big);
    const hhea = buf[starts[1]..][0..36];
    std.mem.writeInt(i16, hhea[4..6], spec.ascent, .big);
    std.mem.writeInt(i16, hhea[6..8], spec.descent, .big);
    std.mem.writeInt(u16, hhea[34..36], 2, .big); // numOfLongHorMetrics
    const maxp = buf[starts[2]..][0..6];
    std.mem.writeInt(u32, maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, maxp[4..6], 2, .big); // numGlyphs
    const hmtx = buf[starts[3]..][0..8];
    std.mem.writeInt(u16, hmtx[4..6], spec.advance, .big); // glyph 1 advance
    const cmap = buf[starts[4]..][0..40];
    std.mem.writeInt(u16, cmap[2..4], 1, .big); // numTables
    std.mem.writeInt(u16, cmap[4..6], 3, .big); // platform Windows
    std.mem.writeInt(u16, cmap[6..8], 10, .big); // encoding UCS-4
    std.mem.writeInt(u32, cmap[8..12], 12, .big); // subtable offset
    const sub = cmap[12..40];
    std.mem.writeInt(u16, sub[0..2], 12, .big); // format 12
    std.mem.writeInt(u32, sub[4..8], 28, .big); // length
    std.mem.writeInt(u32, sub[12..16], 1, .big); // numGroups
    std.mem.writeInt(u32, sub[16..20], 0x20, .big);
    std.mem.writeInt(u32, sub[20..24], 0x7E, .big);
    std.mem.writeInt(u32, sub[24..28], 1, .big);
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
