//! Pure text shaping: UTF-8 text + a font face -> positioned glyph IDs.
//!
//! No Document, no I/O, no state: the face's parsed tables are only read
//! (never its caches or subset state), so any number of threads may shape
//! with one face at once. A layout engine measures and breaks lines with
//! the result and draws the same records with `Document.drawGlyphs`.
//!
//! Positions are in font units (scale by size / `unitsPerEm`), as
//! HarfBuzz reports them: a glyph is drawn at the pen position plus its
//! offset, then the pen moves by its advance. Substitution is platen's
//! GSUB engine, positioning its GPOS engine (gpos.zig) as HarfBuzz's
//! default shaper runs it, after HarfBuzz's normalization (decode.zig);
//! all checked against HarfBuzz. Not yet: fallback mark positioning for
//! fonts without GPOS, and script-specific shaping (Indic reordering,
//! Arabic joining, bidi): text is shaped left to right with the font's
//! DFLT (else latn) script.

const std = @import("std");
const embedded = @import("embedded.zig");
const decode = @import("decode.zig");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const unicode_props = @import("unicode_props.zig");
const gpos = @import("gpos.zig");
const ttf = @import("ttf.zig");

const Allocator = std.mem.Allocator;
const EmbeddedFont = embedded.EmbeddedFont;
const FontFace = embedded.FontFace;

/// One shaped glyph. Lengths are font units.
pub const ShapedGlyph = struct {
    /// Glyph ID in the face (as in its cmap/GSUB, not a subset's).
    id: u16,
    /// Pen advance after this glyph (0 for an attached mark).
    x_advance: i32,
    /// Where the glyph is drawn relative to the pen (y up).
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// Byte offset in the text of the first character of this glyph's
    /// cluster. Glyphs of one cluster (a ligature's, a base and its
    /// marks after composition) share it; clusters never decrease.
    cluster: u32,
};

pub const FeatureSetting = struct {
    feature: opentype.Feature,
    enabled: bool,
};

pub const Options = struct {
    /// Changes to the face's feature defaults (see `FontFace.setFeature`).
    features: []const FeatureSetting = &.{},
};

/// Shapes `text` with `face`. Caller owns the result (free with
/// `allocator`). Characters the face lacks become glyph 0 (.notdef);
/// default ignorables (ZWJ, soft hyphen, variation selectors...) produce
/// no glyph unless the font uses them.
pub fn shape(allocator: Allocator, face: *const FontFace, text: []const u8, opts: Options) ![]ShapedGlyph {
    var flags = face.prototype.feature_flags;
    for (opts.features) |f| flags.set(f.feature, f.enabled);
    return shapeFont(allocator, face.prototype, flags, text);
}

/// Units per em of `face`, for scaling: points = units * size / unitsPerEm.
pub fn unitsPerEm(face: *const FontFace) u16 {
    return face.prototype.font.head.?.units_per_em;
}

/// Total advance of `glyphs` in font units.
pub fn totalAdvance(glyphs: []const ShapedGlyph) i64 {
    var sum: i64 = 0;
    for (glyphs) |g| sum += g.x_advance;
    return sum;
}

/// `shape` on a parsed font with explicit feature flags. Reads `emb` only.
pub fn shapeFont(allocator: Allocator, emb: *const EmbeddedFont, flags: opentype.FeatureFlags, text: []const u8) ![]ShapedGlyph {
    var d: decode.Decoded = .{};
    defer d.deinit(allocator);
    try decode.decode(allocator, &emb.font, text, &d, true);

    var shaper: gsub.Shaper = .{};
    defer shaper.deinit(allocator);

    // GSUB always runs: GPOS needs its glyph classes and ligature
    // components (a font without GSUB gets an empty table with its GDEF)
    const ot = emb.ot_features;
    var no_gsub = opentype.empty_gsub;
    if (ot) |o| no_gsub.gdef = o.gdef;
    const gsub_table: *const gsub.Table = if (ot) |o| (if (o.gsub) |*g| g else &no_gsub) else &no_gsub;
    _ = try shaper.shape(allocator, gsub_table, d.glyphs.items, d.codepoints.items, flags);
    const glyphs = shaper.buf.items;

    const pos = try allocator.alloc(gpos.Position, glyphs.len);
    defer allocator.free(pos);
    for (pos, glyphs) |*p, g| p.* = .{ .x_advance = emb.font.getGlyphWidth(g.id) orelse 0 };
    if (d.space_fallbacks.items.len > 0) spaceWidths(&emb.font, d.space_fallbacks.items, glyphs, pos);
    if (ot) |o| try positionGlyphs(allocator, o, gsub_table, flags, glyphs, pos);

    const out = try allocator.alloc(ShapedGlyph, glyphs.len);
    errdefer allocator.free(out);
    for (out, glyphs, pos) |*o, g, p| o.* = .{
        .id = g.id,
        .x_advance = p.x_advance,
        .x_offset = p.x_offset,
        .y_offset = p.y_offset,
        .cluster = g.cluster,
    };
    try formClusters(allocator, d.codepoints.items, d.offsets.items, out);
    return out;
}

/// HarfBuzz's _hb_ot_shape_fallback_spaces: a space the font lacks, drawn
/// with the space glyph, gets the width its kind calls for.
fn spaceWidths(font: *const ttf.Font, kinds: []const unicode_props.SpaceFallback, glyphs: []const gsub.Glyph, pos: []gpos.Position) void {
    const upem: i32 = font.head.?.units_per_em;
    for (glyphs, pos) |g, *p| {
        const kind = kinds[g.cp];
        switch (kind) {
            .none, .space => {},
            .em, .em_2, .em_3, .em_4, .em_5, .em_6, .em_16 => {
                const n: i32 = @backingInt(kind);
                p.x_advance = @divTrunc(upem + @divTrunc(n, 2), n);
            },
            .four_em_18 => p.x_advance = @divTrunc(upem * 4, 18),
            .figure => for ("0123456789") |c| {
                const gid = font.getGlyphId(c) orelse 0;
                if (gid != 0) {
                    p.x_advance = font.getGlyphWidth(gid) orelse 0;
                    break;
                }
            },
            .punctuation => {
                const gid = font.getGlyphId('.') orelse font.getGlyphId(',') orelse 0;
                if (gid != 0) p.x_advance = font.getGlyphWidth(gid) orelse 0;
            },
            .narrow => p.x_advance = @divTrunc(p.x_advance, 2),
        }
    }
}

/// HarfBuzz's positioning for the default shaper (hb_ot_position): GPOS,
/// or the 'kern' table where GPOS has no kern feature; then GDEF marks
/// lose their advance (shifted back over the glyph before when there is no
/// GPOS), and attached glyphs take their parents' offsets.
fn positionGlyphs(allocator: Allocator, ot: *const opentype.OpenTypeFeatures, gsub_table: *const gsub.Table, flags: opentype.FeatureFlags, glyphs: []gsub.Glyph, pos: []gpos.Position) !void {
    if (ot.gpos) |*table| {
        var lookups: std.ArrayListUnmanaged(u16) = .empty;
        defer lookups.deinit(allocator);
        try table.collectLookups(allocator, flags, &lookups);
        gpos.apply(table, glyphs, pos, lookups.items);
    }
    if (ot.shaping_kern) |*kern| {
        if (flags.isEnabled(.kern)) gpos.applyKernTable(gsub_table, kern, glyphs, pos);
    }
    gpos.zeroMarkWidths(gsub_table, glyphs, pos, ot.gpos == null);
    gpos.propagateAttachments(pos);
}

/// Turns the glyphs' clusters from code point indices (as GSUB left them:
/// non-decreasing, a ligature's merged to its first component) into byte
/// offsets of merged clusters, as HarfBuzz's default cluster level
/// (monotone graphemes) gives them. A glyph's cluster owns the code points
/// up to the next glyph's (one GSUB deleted, or a removed ignorable, joins
/// the cluster before it; at the start, the one after). A grapheme
/// (unicode_props.markContinuations) never spans two clusters: those it
/// touches merge, and a merged cluster takes the offset of its first code
/// point.
fn formClusters(allocator: Allocator, cps: []const u21, offsets: []const u32, glyphs: []ShapedGlyph) !void {
    if (glyphs.len == 0) return;
    const n = cps.len;
    const buf = try allocator.alloc(u32, n);
    defer allocator.free(buf);
    const cont = try allocator.alloc(bool, n);
    defer allocator.free(cont);
    unicode_props.markContinuations(cps, cont);

    // owner[i]: the glyph cluster whose span holds code point i
    const owner = buf;
    var g: usize = 0;
    for (owner, 0..) |*o, i| {
        while (g + 1 < glyphs.len and glyphs[g + 1].cluster <= i) g += 1;
        o.* = glyphs[g].cluster;
    }
    // In place: start[i], the first code point of i's merged cluster
    const start = buf;
    var prev_owner: u32 = undefined;
    for (0..n) |i| {
        const own = owner[i];
        start[i] = if (i > 0 and (cont[i] or own == prev_owner)) start[i - 1] else @intCast(i);
        prev_owner = own;
    }
    for (glyphs) |*gl| gl.cluster = offsets[start[gl.cluster]];
}

// ============================================================================
// Tests (HarfBuzz differential: shaping_test.zig)
// ============================================================================

const testing = std.testing;

fn testFace(path: []const u8) !FontFace {
    return FontFace.fromFile(testing.io, testing.allocator, path);
}

test "shape: a ligature's cluster is its first character's byte offset" {
    var face = try testFace("test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    // "o" + "ffi" ligature + "c" + "e"
    const glyphs = try shape(testing.allocator, &face, "office", .{});
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(@as(usize, 4), glyphs.len);
    const clusters = [_]u32{ 0, 1, 4, 5 };
    for (glyphs, clusters) |g, c| try testing.expectEqual(c, g.cluster);
    try testing.expectEqual(@as(u16, 793), glyphs[1].id);
    try testing.expectEqual(@as(i32, 1829), glyphs[1].x_advance);

    // Turned off, the ligature splits back into one glyph per character
    const plain = try shape(testing.allocator, &face, "office", .{ .features = &.{.{ .feature = .liga, .enabled = false }} });
    defer testing.allocator.free(plain);
    try testing.expectEqual(@as(usize, 6), plain.len);
    for (plain, 0..) |g, i| try testing.expectEqual(@as(u32, @intCast(i)), g.cluster);
}

test "shape: marks join their base's cluster, composed or attached" {
    var face = try testFace("test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    // e + U+0301 composes to é; q + U+0303 has no precomposed form, so
    // the tilde attaches as a mark with zero advance
    const text = "e\u{301}q\u{303}x";
    const glyphs = try shape(testing.allocator, &face, text, .{});
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(@as(usize, 4), glyphs.len);
    const clusters = [_]u32{ 0, 3, 3, 6 };
    for (glyphs, clusters) |g, c| try testing.expectEqual(c, g.cluster);
    try testing.expectEqual(@as(i32, 0), glyphs[2].x_advance);
    try testing.expect(glyphs[2].y_offset != 0 or glyphs[2].x_offset != 0);
    try testing.expectEqual(totalAdvance(glyphs), @as(i64, glyphs[0].x_advance + glyphs[1].x_advance + glyphs[3].x_advance));
}

test "shape is pure: the face keeps no trace of it" {
    var face = try testFace("test/fonts/Inter/Inter-Regular.otf");
    defer face.deinit();
    const glyphs = try shape(testing.allocator, &face, "AVATAR office \u{1F600}", .{});
    defer testing.allocator.free(glyphs);
    // No frozen face, no used glyphs or kerning cache entries on it
    try testing.expect(!face.frozen);
    try testing.expectEqual(@as(usize, 0), face.prototype.cid_used_glyphs.count());
    try testing.expectEqual(@as(usize, 0), face.prototype.glyph_to_codepoint.count());
    try testing.expectEqual(@as(usize, 0), face.prototype.cid_glyph_widths.count());
    for (face.prototype.ot_features.?.kern_cache_keys) |k| try testing.expectEqual(@as(u32, 0xFFFF_FFFF), k);
    // The emoji is not in Inter: .notdef, still one glyph with an advance
    try testing.expectEqual(@as(u16, 0), glyphs[glyphs.len - 1].id);
    try testing.expectEqual(@as(u32, 14), glyphs[glyphs.len - 1].cluster);
    try testing.expectEqual(@as(u16, 2048), unitsPerEm(&face));
}

test "shape: empty text and ignorables only" {
    var face = try testFace("test/fonts/Inter/Inter-Regular.otf");
    defer face.deinit();
    const none = try shape(testing.allocator, &face, "", .{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    // A soft hyphen and ZWJ are removed; "a" keeps byte offset 3
    const soft = try shape(testing.allocator, &face, "\u{AD}\u{200D}a", .{});
    defer testing.allocator.free(soft);
    try testing.expectEqual(@as(usize, 1), soft.len);
    // HarfBuzz merges a removed leading ignorable forward: cluster 0
    try testing.expectEqual(@as(u32, 0), soft[0].cluster);
}
