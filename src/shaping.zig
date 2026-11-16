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
//! GSUB engine (checked against HarfBuzz); positioning is, for now, what
//! `write` draws: pair kerning between neighbors and mark-to-base /
//! mark-to-mark attachment of the marks after a base. Not yet: the other
//! GPOS lookup types, lookup order and flags, and script-specific shaping
//! (Indic reordering, Arabic joining, bidi): text is shaped left to right
//! with the font's DFLT script.

const std = @import("std");
const embedded = @import("embedded.zig");
const decode = @import("decode.zig");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const unicode_props = @import("unicode_props.zig");

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

    const run_gsub = if (emb.ot_features) |ot| d.ignorables or try hasActiveGsub(allocator, &shaper, ot, flags) else false;
    const shaped: []const gsub.Glyph = if (run_gsub) blk: {
        const ot = emb.ot_features.?;
        const table: *const gsub.Table = if (ot.gsub) |*g| g else &opentype.empty_gsub;
        break :blk try shaper.shape(allocator, table, d.glyphs.items, d.codepoints.items, flags);
    } else &.{};

    const n = if (run_gsub) shaped.len else d.glyphs.items.len;
    const out = try allocator.alloc(ShapedGlyph, n);
    errdefer allocator.free(out);
    if (run_gsub) {
        for (out, shaped) |*o, g| o.* = .{ .id = g.id, .x_advance = 0, .cluster = g.cluster };
    } else {
        for (out, d.glyphs.items, 0..) |*o, gid, i| o.* = .{ .id = gid, .x_advance = 0, .cluster = @intCast(i) };
    }
    try formClusters(allocator, d.codepoints.items, d.offsets.items, out);
    position(emb, flags, out);
    return out;
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

fn hasActiveGsub(allocator: Allocator, shaper: *gsub.Shaper, ot: *const opentype.OpenTypeFeatures, flags: opentype.FeatureFlags) !bool {
    const table = if (ot.gsub) |*g| g else return false;
    return (try shaper.activeLookups(allocator, table, flags)).len > 0;
}

/// Advances and offsets as `text_render` draws them: each glyph advances
/// by its hmtx width plus the kerning with the next base. When the run has
/// a mark that attaches to the glyph before it, a base's following marks
/// attach to it (or to the mark before them) with zero advance, and the
/// base kerns with the glyph after its marks.
fn position(emb: *const EmbeddedFont, flags: opentype.FeatureFlags, glyphs: []ShapedGlyph) void {
    for (glyphs) |*g| g.x_advance = emb.font.getGlyphWidth(g.id) orelse 0;
    const ot = emb.ot_features orelse return;
    const kern_on = flags.isEnabled(.kern) and emb.has_kern_data;
    const marks_on = (flags.isEnabled(.mark) or flags.isEnabled(.mkmk)) and emb.has_mark_data;
    const Ctx = struct {
        ot: *const opentype.OpenTypeFeatures,
        kern_on: bool,
        marks_on: bool,
        fn kern(c: @This(), a: u16, b: u16) i32 {
            return if (c.kern_on) c.ot.kerningUncached(a, b) else 0;
        }
        fn mark(c: @This(), base: u16, m: u16) ?opentype.MarkOffset {
            return if (c.marks_on) c.ot.getMarkOffset(base, m) else null;
        }
    };
    const c: Ctx = .{ .ot = ot, .kern_on = kern_on, .marks_on = marks_on };

    const has_marks = marks_on and for (0..glyphs.len -| 1) |i| {
        if (c.mark(glyphs[i].id, glyphs[i + 1].id) != null) break true;
    } else false;

    if (!has_marks) {
        if (!kern_on) return;
        for (0..glyphs.len -| 1) |i| glyphs[i].x_advance += c.kern(glyphs[i].id, glyphs[i + 1].id);
        return;
    }

    var i: usize = 0;
    while (i < glyphs.len) {
        const base = glyphs[i].id;
        // The marks after this base: each attaches to the glyph before it
        // (mark-to-mark) or to the base itself
        var j = i + 1;
        while (j < glyphs.len) : (j += 1) {
            if (c.mark(glyphs[j - 1].id, glyphs[j].id) == null and c.mark(base, glyphs[j].id) == null) break;
        }
        const kern = if (j < glyphs.len) c.kern(base, glyphs[j].id) else 0;
        const base_advance = glyphs[i].x_advance + kern;
        glyphs[i].x_advance = base_advance;

        // Mark positions relative to the base origin; the pen after the
        // base is at base_advance
        var prev = base;
        var prev_x: i32 = 0;
        var prev_y: i32 = 0;
        for (glyphs[i + 1 .. j]) |*m| {
            var ref_x: i32 = 0;
            var ref_y: i32 = 0;
            var off = c.mark(prev, m.id);
            if (off != null) {
                ref_x = prev_x;
                ref_y = prev_y;
            } else off = c.mark(base, m.id);
            const o = off.?; // the scan above found one
            m.x_advance = 0;
            m.x_offset = ref_x + o.dx - base_advance;
            m.y_offset = ref_y + o.dy;
            prev = m.id;
            prev_x = ref_x + o.dx;
            prev_y = ref_y + o.dy;
        }
        i = j;
    }
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
