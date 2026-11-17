//! Text decoding for shaping: UTF-8 to code points and their nominal
//! glyphs, the step before GSUB. Every identity shaping path - rendering,
//! measurement and the pure `shape` call - decodes here, so they agree.

const std = @import("std");
const ttf = @import("ttf.zig");
const unicode_compose = @import("unicode_compose.zig");
const gsub = @import("gsub.zig");

const Allocator = std.mem.Allocator;

/// Decoded text, one entry per code point after composition. Reusable
/// across calls (`decode` clears it); free with `deinit`.
pub const Decoded = struct {
    codepoints: std.ArrayListUnmanaged(u21) = .empty,
    /// Per code point: composed from a decomposed sequence.
    composed: std.ArrayListUnmanaged(bool) = .empty,
    /// Nominal glyph per code point (0 when the font has none).
    glyphs: std.ArrayListUnmanaged(u16) = .empty,
    /// Byte offset in the text of each code point (of the base, for a
    /// composed one). Filled only when `decode` is asked for it.
    offsets: std.ArrayListUnmanaged(u32) = .empty,
    /// The text has a default ignorable (U+FE0F, ZWJ, soft hyphen...): it
    /// must go through the shaper, which removes them.
    ignorables: bool = false,

    pub fn deinit(self: *Decoded, allocator: Allocator) void {
        self.codepoints.deinit(allocator);
        self.composed.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.offsets.deinit(allocator);
    }
};

/// Decode UTF-8 `text` into code points and their nominal glyphs in
/// `font`, composing a base + combining marks into the precomposed
/// character when the font has a glyph for it (the normalization HarfBuzz
/// does before shaping), then applying variation sequences. Invalid
/// sequences are skipped; a truncated one ends the text. With
/// `track_offsets`, `out.offsets` gets each code point's byte offset.
pub fn decode(allocator: Allocator, font: *const ttf.Font, text: []const u8, out: *Decoded, track_offsets: bool) !void {
    out.codepoints.clearRetainingCapacity();
    out.composed.clearRetainingCapacity();
    out.glyphs.clearRetainingCapacity();
    out.offsets.clearRetainingCapacity();
    // Worst case: all ASCII = text.len code points
    try out.codepoints.ensureTotalCapacity(allocator, text.len);
    try out.composed.ensureTotalCapacity(allocator, text.len);
    try out.glyphs.ensureTotalCapacity(allocator, text.len);
    if (track_offsets) try out.offsets.ensureTotalCapacity(allocator, text.len);
    const offsets: ?*std.ArrayListUnmanaged(u32) = if (track_offsets) &out.offsets else null;

    var may_compose = false;
    out.ignorables = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 128) {
            out.codepoints.appendAssumeCapacity(byte);
            if (offsets) |o| o.appendAssumeCapacity(@intCast(i));
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };
        if (codepoint >= unicode_compose.first_mark) may_compose = true;
        if (gsub.Ignorable.of(codepoint) != .none) out.ignorables = true;
        out.codepoints.appendAssumeCapacity(codepoint);
        if (offsets) |o| o.appendAssumeCapacity(@intCast(i));
        i += len;
    }

    if (may_compose) {
        const ctx = struct {
            font: *const ttf.Font,
            pub fn hasGlyph(c: @This(), cp: u21) bool {
                return (c.font.getGlyphId(cp) orelse 0) != 0;
            }
        }{ .font = font };
        // Marks in canonical order first, as HarfBuzz's normalization
        unicode_compose.reorderMarks(out.codepoints.items, if (offsets) |o| o.items else null);
        out.composed.items.len = out.codepoints.items.len;
        const n = unicode_compose.composeInPlace(out.codepoints.items, out.composed.items, if (offsets) |o| o.items else null, ctx);
        out.codepoints.items.len = n;
        out.composed.items.len = n;
        if (offsets) |o| o.items.len = n;
    } else {
        out.composed.appendNTimesAssumeCapacity(false, out.codepoints.items.len);
    }

    for (out.codepoints.items) |cp| {
        // ASCII: cached glyph (looked up at font load)
        const gid = if (cp < 128 and font.has_ascii_cache) font.ascii_glyphs[cp] else font.getGlyphId(cp) orelse 0;
        out.glyphs.appendAssumeCapacity(gid);
    }

    if (out.ignorables and font.cmap_uvs_offset != 0) applyVariationSequences(font, out, track_offsets);
}

/// A variation selector after a character picks the glyph the font's cmap
/// format 14 lists for the pair, before GSUB, and is consumed - as in
/// HarfBuzz's normalization. An unlisted pair is left alone: the selector
/// is a default ignorable, which shaping skips and removes.
fn applyVariationSequences(font: *const ttf.Font, d: *Decoded, track_offsets: bool) void {
    const cps = d.codepoints.items;
    const composed = d.composed.items;
    const glyphs = d.glyphs.items;
    var out: usize = 0;
    var consumed = false;
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        cps[out] = cps[i];
        composed[out] = composed[i];
        glyphs[out] = glyphs[i];
        if (track_offsets) d.offsets.items[out] = d.offsets.items[i];
        if (i + 1 < cps.len and isVariationSelector(cps[i + 1])) {
            if (font.getVariationGlyph(cps[i], cps[i + 1])) |gid| {
                glyphs[out] = gid;
                i += 1;
                consumed = true;
            }
        }
        out += 1;
    }
    if (!consumed) return;
    d.codepoints.items.len = out;
    d.composed.items.len = out;
    d.glyphs.items.len = out;
    if (track_offsets) d.offsets.items.len = out;
    d.ignorables = for (d.codepoints.items) |cp| {
        if (gsub.Ignorable.of(cp) != .none) break true;
    } else false;
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}
