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
//! fonts without GPOS get its fallback mark positioning; Devanagari goes
//! through HarfBuzz's Indic shaper (indic.zig); all checked against
//! HarfBuzz. The text's first character of a script picks the script, as
//! HarfBuzz's guess_segment_properties: split mixed-script text into runs.
//! Not yet: other Indic scripts, Arabic joining, bidi (text is shaped left
//! to right), and AAT 'morx' tables (GSUB is used).

const std = @import("std");
const embedded = @import("embedded.zig");
const decode = @import("decode.zig");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const unicode_props = @import("unicode_props.zig");
const gpos = @import("gpos.zig");
const ttf = @import("ttf.zig");
const mark_fallback = @import("mark_fallback.zig");
const indic = @import("indic.zig");

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
    /// The bytes of the text this glyph itself was formed from
    /// [text_start, text_end): a ligature or conjunct its characters', a
    /// mark its own, a reordered matra its own; empty (start == end) for a
    /// glyph that stands for no text (the second glyph of a decomposition,
    /// an inserted dotted circle). Each character belongs to one glyph at
    /// most: copy text built from these neither repeats nor drops any
    /// (but a ligature formed across a mark also spans the mark's bytes).
    text_start: u32 = 0,
    text_end: u32 = 0,
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
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    return shapeCached(allocator, &cache, allocator, emb, flags, text);
}

/// Reusable shaping state for one font: buffers kept between calls, and
/// the lookups per feature flags and script, so shaping text after text
/// (measuring every word of a paragraph) hardly allocates. Belongs to one
/// font and one thread (a document's EmbeddedFont); `shapeFont` uses a
/// fresh one per call.
pub const Cache = struct {
    decoded: decode.Decoded = .{},
    shaper: gsub.Shaper = .{},
    pos: std.ArrayListUnmanaged(gpos.Position) = .empty,
    /// Per-call temporaries, reset at each call
    arena: std.heap.ArenaAllocator.State = .{},
    /// GPOS lookups for `flags`, per script (default, devanagari)
    gpos_lookups: [2]std.ArrayListUnmanaged(u16) = .{ .empty, .empty },
    gpos_valid: [2]bool = .{ false, false },
    indic_plan: ?indic.Plan = null,
    /// GPOS pair adjustments found so far (independent of flags)
    pairs: std.AutoHashMapUnmanaged(u64, gpos.PairRecord) = .empty,
    /// Advance and glyph count of short texts measured (advanceCached) with
    /// `flags`: wrapping measures the same words over and over. Keys owned.
    widths: std.StringHashMapUnmanaged(Advance) = .empty,
    /// The flags the cached lookups and plan are for
    flags: ?opentype.FeatureFlags = null,

    pub fn deinit(self: *Cache, allocator: Allocator) void {
        self.decoded.deinit(allocator);
        self.shaper.deinit(allocator);
        self.pos.deinit(allocator);
        self.arena.promote(allocator).deinit();
        for (&self.gpos_lookups) |*l| l.deinit(allocator);
        if (self.indic_plan) |p| p.deinit(allocator);
        self.pairs.deinit(allocator);
        self.clearWidths(allocator);
        self.widths.deinit(allocator);
        self.* = .{};
    }

    /// Texts longer than this are not remembered (lines rarely repeat)
    const max_width_text = 64;
    /// Widths remembered before the cache starts over
    const max_widths = 4096;

    fn clearWidths(self: *Cache, allocator: Allocator) void {
        var it = self.widths.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.widths.clearRetainingCapacity();
    }

    fn useFlags(self: *Cache, allocator: Allocator, flags: opentype.FeatureFlags) void {
        if (self.flags) |f| {
            if (std.mem.eql(bool, &f.flags, &flags.flags)) return;
        }
        self.gpos_valid = .{ false, false };
        if (self.indic_plan) |p| p.deinit(allocator);
        self.indic_plan = null;
        self.clearWidths(allocator);
        self.flags = flags;
    }
};

/// `shapeFont` with `cache` (owned by `cache_alloc`, one font's) kept
/// between calls. The result is owned by `out_alloc`.
pub fn shapeCached(cache_alloc: Allocator, cache: *Cache, out_alloc: Allocator, emb: *const EmbeddedFont, flags: opentype.FeatureFlags, text: []const u8) ![]ShapedGlyph {
    const r = try run(cache_alloc, cache, emb, flags, text);
    const d = &cache.decoded;
    const out = try out_alloc.alloc(ShapedGlyph, r.glyphs.len);
    errdefer out_alloc.free(out);
    for (out, r.glyphs, r.pos) |*o, g, p| {
        const cluster = d.offsets.items[g.cluster];
        var start: u32 = std.math.maxInt(u32);
        var end: u32 = 0;
        for (d.spans.items[g.src_lo..g.src_hi]) |span| {
            if (span[0] == span[1]) continue;
            start = @min(start, span[0]);
            end = @max(end, span[1]);
        }
        if (start >= end) {
            start = cluster;
            end = cluster;
        }
        o.* = .{
            .id = g.id,
            .x_advance = p.x_advance,
            .x_offset = p.x_offset,
            .y_offset = p.y_offset,
            .cluster = cluster,
            .text_start = start,
            .text_end = end,
        };
    }
    return out;
}

/// Total advance (font units) and glyph count of `text` as shapeCached
/// shapes it, without building its glyph list.
pub fn advanceCached(cache_alloc: Allocator, cache: *Cache, emb: *const EmbeddedFont, flags: opentype.FeatureFlags, text: []const u8) !Advance {
    cache.useFlags(cache_alloc, flags);
    const remember = text.len <= Cache.max_width_text;
    if (remember) {
        if (cache.widths.get(text)) |a| return a;
    }
    const r = try run(cache_alloc, cache, emb, flags, text);
    var sum: i64 = 0;
    for (r.pos) |p| sum += p.x_advance;
    const result: Advance = .{ .advance = sum, .count = r.glyphs.len };
    if (remember) {
        if (cache.widths.count() >= Cache.max_widths) cache.clearWidths(cache_alloc);
        // A cache: out of memory only skips remembering
        if (cache_alloc.dupe(u8, text)) |key| {
            cache.widths.put(cache_alloc, key, result) catch cache_alloc.free(key);
        } else |_| {}
    }
    return result;
}

/// Total advance (font units) and glyph count of a shaped text.
pub const Advance = struct { advance: i64, count: usize };

/// One shaping pass; its glyphs and positions live in `cache` until the
/// next call.
fn run(allocator: Allocator, cache: *Cache, emb: *const EmbeddedFont, flags: opentype.FeatureFlags, text: []const u8) !struct { glyphs: []gsub.Glyph, pos: []gpos.Position } {
    cache.useFlags(allocator, flags);
    var arena = cache.arena.promote(allocator);
    defer cache.arena = arena.state;
    _ = arena.reset(.retain_capacity);
    const tmp = arena.allocator();

    // GSUB always runs: GPOS needs its glyph classes and ligature
    // components (a font without GSUB gets an empty table with its GDEF)
    const ot = emb.ot_features;
    var no_gsub = opentype.empty_gsub;
    if (ot) |o| no_gsub.gdef = o.gdef;
    const gsub_table: *const gsub.Table = if (ot) |o| (if (o.gsub) |*g| g else &no_gsub) else &no_gsub;

    // The script picks the language system, and Devanagari in a font with
    // dev2/deva GSUB the Indic shaper (HarfBuzz's shaper selection)
    const script = textScript(text);
    var indic_plan: ?*const indic.Plan = null;
    if (script == .devanagari and (gsub_table.devanagari.script == gsub.tag("dev2") or gsub_table.devanagari.script == gsub.tag("deva"))) {
        if (cache.indic_plan == null) cache.indic_plan = try indic.Plan.init(allocator, gsub_table, flags, emb.font.getGlyphId(0x094D) orelse 0);
        indic_plan = &cache.indic_plan.?;
    }

    const d = &cache.decoded;
    try decode.decodeAs(allocator, &emb.font, text, d, true, if (indic_plan != null) .indic else .default);

    // Clusters start per grapheme, as HarfBuzz forms them before shaping;
    // shaping merges them further (ligatures, reordering)
    const clusters = try graphemeClusters(tmp, d.codepoints.items, d.offsets.items);

    const shaper = &cache.shaper;
    if (indic_plan) |plan| {
        try shaper.beginClustered(allocator, gsub_table, d.glyphs.items, d.codepoints.items, clusters);
        _ = try indic.substitute(allocator, shaper, plan, &emb.font, d.codepoints.items);
    } else {
        _ = try shaper.shapeClustered(allocator, gsub_table, d.glyphs.items, d.codepoints.items, clusters, flags);
    }
    const glyphs = shaper.buf.items;

    try cache.pos.resize(allocator, glyphs.len);
    const pos = cache.pos.items;
    for (pos, glyphs) |*p, g| p.* = .{ .x_advance = emb.font.getGlyphWidth(g.id) orelse 0 };
    if (d.space_fallbacks.items.len > 0) spaceWidths(&emb.font, d.space_fallbacks.items, glyphs, pos);
    if (ot) |o| {
        var lookups: []const u16 = &.{};
        if (o.gpos) |*table| {
            const k: usize = @intFromBool(script == .devanagari);
            if (!cache.gpos_valid[k]) {
                try table.collectLookupsFor(allocator, table.langSys(script), flags, &cache.gpos_lookups[k]);
                cache.gpos_valid[k] = true;
            }
            lookups = cache.gpos_lookups[k].items;
        }
        var pairs: gpos.PairCache = .{ .map = cache.pairs, .allocator = allocator };
        defer cache.pairs = pairs.map;
        positionGlyphs(o, gsub_table, &emb.font, d.codepoints.items, flags, indic_plan != null, glyphs, pos, lookups, &pairs);
    }
    return .{ .glyphs = glyphs, .pos = pos };
}

/// The text's script, as HarfBuzz's guess_segment_properties finds it: the
/// first character of a script (not common or inherited) decides.
/// Devanagari picks its own language system; anything else the default.
fn textScript(text: []const u8) gsub.Script {
    var view = std.unicode.Utf8View.init(text) catch return .default;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (unicode_props.runScript(cp)) {
            .none => {},
            .devanagari => return .devanagari,
            .other => return .default,
        }
    }
    return .default;
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
/// GPOS), and attached glyphs take their parents' offsets. Without GPOS,
/// marks are then placed by glyph extents (mark_fallback.zig).
/// `gpos_lookups`: the GPOS lookups for the text's script and flags.
fn positionGlyphs(ot: *const opentype.OpenTypeFeatures, gsub_table: *const gsub.Table, font: *const ttf.Font, cps: []const u21, flags: opentype.FeatureFlags, indic_shaper: bool, glyphs: []gsub.Glyph, pos: []gpos.Position, gpos_lookups: []const u16, pairs: *gpos.PairCache) void {
    if (ot.gpos) |*table| gpos.applyCached(table, glyphs, pos, gpos_lookups, pairs);
    if (ot.shaping_kern) |*kern| {
        if (flags.isEnabled(.kern)) gpos.applyKernTable(gsub_table, kern, glyphs, pos);
    }
    // The Indic shaper zeroes no marks and has no fallback positioning
    if (!indic_shaper) gpos.zeroMarkWidths(gsub_table, glyphs, pos, ot.gpos == null);
    gpos.propagateAttachments(pos);
    if (ot.gpos == null and !indic_shaper) mark_fallback.position(gsub_table, font, cps, glyphs, pos, true);
}

/// Each code point's initial cluster: the index of the first code point
/// of its grapheme (unicode_props.markContinuations, as HarfBuzz's
/// hb_form_clusters at its default cluster level). A dotted circle the
/// Indic vowel constraints inserted (it shares the next character's
/// offset) is not there for this: HarfBuzz forms clusters first and then
/// inserts it with the cluster of the character after it.
fn graphemeClusters(allocator: Allocator, cps: []const u21, offsets: []const u32) ![]u32 {
    const n = cps.len;
    const out = try allocator.alloc(u32, n);
    errdefer allocator.free(out);
    const inserted = try allocator.alloc(bool, n);
    defer allocator.free(inserted);
    for (inserted, 0..) |*f, i| f.* = cps[i] == 0x25CC and i + 1 < n and offsets[i] == offsets[i + 1];
    // Graphemes over the text as typed
    const typed = try allocator.alloc(u21, n);
    defer allocator.free(typed);
    const index = try allocator.alloc(u32, n);
    defer allocator.free(index);
    var m: usize = 0;
    for (cps, inserted, 0..) |cp, f, i| {
        if (f) continue;
        typed[m] = cp;
        index[m] = @intCast(i);
        m += 1;
    }
    const cont = try allocator.alloc(bool, m);
    defer allocator.free(cont);
    unicode_props.markContinuations(typed[0..m], cont);
    for (0..m) |k| out[index[k]] = if (k > 0 and cont[k]) out[index[k - 1]] else index[k];
    // An inserted dotted circle takes the next character's cluster
    var i = n;
    while (i > 0) {
        i -= 1;
        if (inserted[i]) out[i] = out[i + 1];
    }
    return out;
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

test "shape: Devanagari as Final Draft 13 prints it (Kohinoor Devanagari Light)" {
    // courier's reference glyphs (FD_RULES 3.1): macOS only
    const a = testing.allocator;
    const ttc = std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/Kohinoor.ttc", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(ttc);
    const data = try @import("font_collection.zig").extractFace(a, ttc, 4);
    defer a.free(data);
    var face = try FontFace.fromMemory(a, data);
    defer face.deinit();
    try testing.expectEqual(@as(u16, 1000), unitsPerEm(&face));

    // namaste: na, ma, the sa-ta conjunct (11.484 pt at 12 pt), then the e
    // matra with no advance, drawn at the conjunct's pen position
    const namaste = try shape(a, &face, "नमस्ते", .{});
    defer a.free(namaste);
    try testing.expectEqual(@as(usize, 4), namaste.len);
    try testing.expectEqual(@as(i32, 957), namaste[2].x_advance);
    try testing.expectEqual(@as(u32, 6), namaste[2].cluster);
    try testing.expectEqual(@as(i32, 0), namaste[3].x_advance);
    try testing.expectEqual(@as(u32, 6), namaste[3].cluster);
    // ki: the i matra before ka, one cluster
    const ki = try shape(a, &face, "कि", .{});
    defer a.free(ki);
    try testing.expectEqual(@as(usize, 2), ki.len);
    try testing.expectEqual(face.prototype.font.getGlyphId(0x0915).?, ki[1].id);
    // ksha: one glyph
    const ksha = try shape(a, &face, "क्ष", .{});
    defer a.free(ksha);
    try testing.expectEqual(@as(usize, 1), ksha.len);
    // hain: ha, then ai + anusvara as one mark glyph
    const hain = try shape(a, &face, "हैं", .{});
    defer a.free(hain);
    try testing.expectEqual(@as(usize, 2), hain.len);
    try testing.expectEqual(face.prototype.font.getGlyphId(0x0939).?, hain[0].id);
    try testing.expectEqual(@as(i32, 0), hain[1].x_advance);
}

test "shape: each glyph's source text, ligatures and reordering included" {
    var face = try testFace("test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    // o | ffi ligature | c | e ; then q + tilde (attached mark, own text)
    const text = "office q\u{303}";
    const glyphs = try shape(testing.allocator, &face, text, .{});
    defer testing.allocator.free(glyphs);
    const expected = [_][2]u32{ .{ 0, 1 }, .{ 1, 4 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 10 } };
    try testing.expectEqual(expected.len, glyphs.len);
    for (glyphs, expected) |g, e| {
        try testing.expectEqual(e[0], g.text_start);
        try testing.expectEqual(e[1], g.text_end);
    }
    // The mark shares its base's cluster but has its own text
    try testing.expectEqual(glyphs[5].cluster, glyphs[6].cluster);
}

test "shape: Devanagari glyphs carry their own characters (Kohinoor)" {
    const a = testing.allocator;
    const ttc = std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/Kohinoor.ttc", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(ttc);
    const data = try @import("font_collection.zig").extractFace(a, ttc, 4);
    defer a.free(data);
    var face = try FontFace.fromMemory(a, data);
    defer face.deinit();
    // ki: the i matra (bytes 3..6) drawn first, then ka (0..3)
    const ki = try shape(a, &face, "कि", .{});
    defer a.free(ki);
    try testing.expectEqual(@as(u32, 3), ki[0].text_start);
    try testing.expectEqual(@as(u32, 6), ki[0].text_end);
    try testing.expectEqual(@as(u32, 0), ki[1].text_start);
    try testing.expectEqual(@as(u32, 3), ki[1].text_end);
    // ste: the sa-virama-ta conjunct (0..9), then the e matra (9..12)
    const ste = try shape(a, &face, "स्ते", .{});
    defer a.free(ste);
    try testing.expectEqual(@as(usize, 2), ste.len);
    try testing.expectEqual([2]u32{ 0, 9 }, [2]u32{ ste[0].text_start, ste[0].text_end });
    try testing.expectEqual([2]u32{ 9, 12 }, [2]u32{ ste[1].text_start, ste[1].text_end });
}
