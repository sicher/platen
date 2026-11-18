//! GPOS pair kerning of two glyphs, for callers that place glyphs without
//! shaping (one glyph per character) but kern as a shaper would.
//!
//! The pair goes through platen's GPOS engine as shapeText runs it: the
//! PairPos lookups of the 'kern' feature of a script's language system
//! (formats 1 and 2, extension lookups resolved), in lookup order, with
//! their lookup flags and GDEF classes. Two glyphs alone: a lookup whose
//! flags skip one of them (a mark under IgnoreMarks) gives nothing, where
//! shaping would kern across the mark; contextual kerning (chained
//! positioning in 'kern') and other features are not applied.
//!
//! Pure: reads the face only. A `GposKerning` belongs to one thread (it
//! remembers pairs it looked up); make one per thread from a shared face.

const std = @import("std");
const embedded = @import("embedded.zig");
const gsub = @import("gsub.zig");
const gpos = @import("gpos.zig");
const opentype = @import("opentype.zig");

const Allocator = std.mem.Allocator;
const FontFace = embedded.FontFace;

/// Which language system, as shapeText picks it from the text's first
/// character of a script: `.latin` (latn, else DFLT, dflt), `.devanagari`
/// (dev2/deva), `.hangul` (hang), else `.default` (DFLT, dflt, latn: text
/// with no script character, or a script without its own here).
pub const Script = gsub.Script;

/// The adjustments a pair gets, font units (x right, y up).
pub const Adjustment = struct {
    /// The first glyph's advance change: the kerning, for most fonts
    x_advance: i32 = 0,
    /// The first glyph's offset (rare)
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// The second glyph's advance and offset (a pair with a second
    /// value record; rare)
    second_x_advance: i32 = 0,
    second_x_offset: i32 = 0,
    second_y_offset: i32 = 0,
    /// The pair had a second value record: in shaping, the second glyph
    /// then does not start a pair with the glyph after it (HarfBuzz
    /// continues after the pair), so skip that next pair
    consumes_second: bool = false,
};

fn gposOf(face: *const FontFace) ?*const gsub.Table {
    const ot = face.prototype.ot_features orelse return null;
    return if (ot.gpos) |*t| t else null;
}

/// Whether the face's GPOS has a 'kern' feature with lookups for
/// `script`'s language system.
pub fn hasGposKerning(face: *const FontFace, script: Script) bool {
    const table = gposOf(face) orelse return false;
    return table.langSys(script).feature_lookups[opentype.FeatureFlags.featureIndex(.kern)].len > 0;
}

pub const GposKerning = struct {
    face: *const FontFace,
    /// The kern feature's PairPos lookups, sorted (applied in this order)
    lookups: []u16,
    pairs: gpos.PairCache,

    /// The kerning of `face` for `script`. Free with `deinit`; the face
    /// must outlive it.
    pub fn init(allocator: Allocator, face: *const FontFace, script: Script) !GposKerning {
        var list: std.ArrayListUnmanaged(u16) = .empty;
        errdefer list.deinit(allocator);
        if (gposOf(face)) |table| {
            for (table.langSys(script).feature_lookups[opentype.FeatureFlags.featureIndex(.kern)]) |li| {
                if (li >= table.lookups.len or table.lookups[li].type != 2) continue;
                if (std.mem.indexOfScalar(u16, list.items, li) != null) continue;
                try list.append(allocator, li);
            }
            std.mem.sort(u16, list.items, {}, std.sort.asc(u16));
        }
        return .{ .face = face, .lookups = try list.toOwnedSlice(allocator), .pairs = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *GposKerning) void {
        self.pairs.allocator.free(self.lookups);
        self.pairs.deinit();
    }

    /// Whether any pair can be kerned (the face has GPOS kern PairPos
    /// lookups for the script).
    pub fn any(self: *const GposKerning) bool {
        return self.lookups.len > 0;
    }

    /// What GPOS kerning does to `left` followed by `right` (glyph IDs).
    pub fn pair(self: *GposKerning, left: u16, right: u16) Adjustment {
        if (self.lookups.len == 0) return .{};
        const table = gposOf(self.face).?;
        // Classes from GDEF, else both are bases (no code points to tell)
        const props: gsub.Props = if (table.gdef.glyph_class != null) gsub.props_unknown else @backingInt(gsub.GlyphClass.base);
        var glyphs = [2]gsub.Glyph{
            .{ .id = left, .cluster = 0, .props = props, .cp = 0, .src_lo = 0, .src_hi = 1 },
            .{ .id = right, .cluster = 1, .props = props, .cp = 1, .src_lo = 1, .src_hi = 2 },
        };
        var pos = [2]gpos.Position{ .{}, .{} };
        const consumed = gpos.applyPairs(table, &glyphs, &pos, self.lookups, &self.pairs);
        return .{
            .x_advance = pos[0].x_advance,
            .x_offset = pos[0].x_offset,
            .y_offset = pos[0].y_offset,
            .second_x_advance = pos[1].x_advance,
            .second_x_offset = pos[1].x_offset,
            .second_y_offset = pos[1].y_offset,
            .consumes_second = consumed,
        };
    }

    /// The first glyph's advance change for the pair: its kerning.
    pub fn advance(self: *GposKerning, left: u16, right: u16) i32 {
        return self.pair(left, right).x_advance;
    }
};

// ============================================================================
// Tests (checked against HarfBuzz: every pair of 100 characters in Apple SD
// Gothic Neo Thin, Arial, Inter, Gentium, Charter and Satoshi agree)
// ============================================================================

const testing = std.testing;
const shaping = @import("shaping.zig");

fn glyphOf(face: *const FontFace, cp: u21) u16 {
    return face.prototype.font.getGlyphId(cp).?;
}

test "GposKerning: courier's Final Draft pairs (Apple SD Gothic Neo Thin, GPOS only)" {
    const a = testing.allocator;
    const ttc = std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/AppleSDGothicNeo.ttc", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(ttc);
    const data = try @import("font_collection.zig").extractFace(a, ttc, 10);
    defer a.free(data);
    var face = try FontFace.fromMemory(a, data);
    defer face.deinit();
    try testing.expect(hasGposKerning(&face, .latin));
    try testing.expect(hasGposKerning(&face, .hangul));
    var k = try GposKerning.init(a, &face, .latin);
    defer k.deinit();
    try testing.expectEqual(@as(i32, -21), k.advance(glyphOf(&face, 'r'), glyphOf(&face, 'a')));
    try testing.expectEqual(@as(i32, -5), k.advance(glyphOf(&face, 'J'), glyphOf(&face, 'a')));
    try testing.expectEqual(@as(i32, 0), k.advance(glyphOf(&face, 'W'), glyphOf(&face, 'r')));
    // Asked again: from the pair cache, the same
    try testing.expectEqual(@as(i32, -21), k.advance(glyphOf(&face, 'r'), glyphOf(&face, 'a')));
}

test "GposKerning: the kerning shapeText gives each pair (Inter)" {
    // A V: -140, as HarfBuzz
    const a = testing.allocator;
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Inter/Inter-Regular.otf");
    defer face.deinit();
    try testing.expect(hasGposKerning(&face, .latin));
    var k = try GposKerning.init(a, &face, .latin);
    defer k.deinit();
    try testing.expectEqual(@as(i32, -140), k.advance(glyphOf(&face, 'A'), glyphOf(&face, 'V')));
    var kerned: usize = 0;
    var text: [2]u8 = undefined;
    for ('A'..'Z' + 1) |l| for ('A'..'Z' + 1) |r| {
        text = .{ @intCast(l), @intCast(r) };
        const glyphs = try shaping.shape(a, &face, &text, .{});
        defer a.free(glyphs);
        try testing.expectEqual(@as(usize, 2), glyphs.len);
        const own = face.prototype.font.getGlyphWidth(glyphs[0].id).?;
        const adj = k.pair(glyphs[0].id, glyphs[1].id);
        try testing.expectEqual(glyphs[0].x_advance - own, adj.x_advance);
        try testing.expectEqual(@as(i32, 0), adj.second_x_advance);
        if (adj.x_advance != 0) kerned += 1;
    };
    try testing.expect(kerned > 50);
}

test "GposKerning: fonts without GPOS kerning give nothing" {
    const a = testing.allocator;
    // Courier Prime kerns with a 'kern' table only
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Courier Prime/Courier Prime.ttf");
    defer face.deinit();
    try testing.expect(!hasGposKerning(&face, .default));
    var k = try GposKerning.init(a, &face, .default);
    defer k.deinit();
    try testing.expect(!k.any());
    try testing.expectEqual(KernAdjustmentZero, k.pair(glyphOf(&face, 'A'), glyphOf(&face, 'V')));
}

const KernAdjustmentZero: Adjustment = .{};
