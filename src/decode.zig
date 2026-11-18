//! Text decoding for shaping: UTF-8 to code points and their nominal
//! glyphs, the step before GSUB. Every identity shaping path - rendering,
//! measurement and the pure `shape` call - decodes here, so they agree.

const std = @import("std");
const ttf = @import("ttf.zig");
const unicode_compose = @import("unicode_compose.zig");
const gsub = @import("gsub.zig");
const unicode_props = @import("unicode_props.zig");
const hangul = @import("hangul.zig");

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
    /// Byte range of the text each code point stands for (filled with
    /// `offsets`): a composite covers its parts, a decomposition's first
    /// part has the character and the others nothing, an inserted dotted
    /// circle nothing. Never merged, unlike `offsets`.
    spans: std.ArrayListUnmanaged([2]u32) = .empty,
    /// The text has a default ignorable (U+FE0F, ZWJ, soft hyphen...): it
    /// must go through the shaper, which removes them.
    ignorables: bool = false,
    /// Per code point, when a space the font lacks took its space glyph:
    /// how wide it is (HarfBuzz's space fallback). Empty if none did.
    space_fallbacks: std.ArrayListUnmanaged(unicode_props.SpaceFallback) = .empty,
    /// Per code point in Hangul mode: its hangul.Jamo feature. Empty in
    /// the other modes.
    jamo: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Decoded, allocator: Allocator) void {
        self.codepoints.deinit(allocator);
        self.composed.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.offsets.deinit(allocator);
        self.spans.deinit(allocator);
        self.space_fallbacks.deinit(allocator);
        self.jamo.deinit(allocator);
    }
};

/// How to normalize: as HarfBuzz's default shaper, its Indic shaper
/// (vowel constraints; decompose whatever the font has the parts of, not
/// U+0931; never compose onto a mark) or its Hangul shaper (hangul.zig's
/// preprocessing first, with clusters in the offsets; then decompose what
/// the font lacks, compose nothing; needs `track_offsets`).
pub const Mode = enum { default, indic, hangul };

pub fn decode(allocator: Allocator, font: *const ttf.Font, text: []const u8, out: *Decoded, track_offsets: bool) !void {
    return decodeAs(allocator, font, text, out, track_offsets, .default);
}

/// Decode UTF-8 `text` into code points and their nominal glyphs in
/// `font`, composing a base + combining marks into the precomposed
/// character when the font has a glyph for it (the normalization HarfBuzz
/// does before shaping), then applying variation sequences. A character
/// the font lacks is decomposed into ones it has, a missing space takes
/// the space glyph (`space_fallbacks`), U+2011 the glyph of U+2010, all as
/// HarfBuzz's normalization does. Invalid
/// sequences are skipped; a truncated one ends the text. With
/// `track_offsets`, `out.offsets` gets each code point's byte offset.
pub fn decodeAs(allocator: Allocator, font: *const ttf.Font, text: []const u8, out: *Decoded, track_offsets: bool, mode: Mode) !void {
    out.codepoints.clearRetainingCapacity();
    out.composed.clearRetainingCapacity();
    out.glyphs.clearRetainingCapacity();
    out.offsets.clearRetainingCapacity();
    out.spans.clearRetainingCapacity();
    out.space_fallbacks.clearRetainingCapacity();
    out.jamo.clearRetainingCapacity();
    // Worst case: all ASCII = text.len code points
    try out.codepoints.ensureTotalCapacity(allocator, text.len);
    try out.composed.ensureTotalCapacity(allocator, text.len);
    try out.glyphs.ensureTotalCapacity(allocator, text.len);
    if (track_offsets) try out.offsets.ensureTotalCapacity(allocator, text.len);
    if (track_offsets) try out.spans.ensureTotalCapacity(allocator, text.len);
    const offsets: ?*std.ArrayListUnmanaged(u32) = if (track_offsets) &out.offsets else null;

    var may_compose = false;
    var may_decompose = false;
    var may_fall_back = false;
    out.ignorables = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 128) {
            out.codepoints.appendAssumeCapacity(byte);
            if (offsets) |o| o.appendAssumeCapacity(@intCast(i));
            if (track_offsets) out.spans.appendAssumeCapacity(.{ @intCast(i), @intCast(i + 1) });
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
        if (codepoint >= 0xC0) may_decompose = true;
        if (codepoint >= 0xA0) may_fall_back = true;
        if (gsub.Ignorable.of(codepoint) != .none) out.ignorables = true;
        out.codepoints.appendAssumeCapacity(codepoint);
        if (offsets) |o| o.appendAssumeCapacity(@intCast(i));
        if (track_offsets) out.spans.appendAssumeCapacity(.{ @intCast(i), @intCast(i + len) });
        i += len;
    }

    if (mode == .hangul) {
        std.debug.assert(track_offsets);
        try hangul.preprocess(allocator, font, out);
    }
    if (mode == .indic and may_decompose) try vowelConstraints(allocator, out, track_offsets);
    if (may_decompose and try decomposeMissing(allocator, font, out, track_offsets, mode)) may_compose = true;

    if (may_compose and mode == .hangul) {
        // Marks in canonical order; nothing recomposed (HarfBuzz's
        // normalization mode NONE)
        unicode_compose.reorderMarksTagged(out.codepoints.items, out.offsets.items, out.spans.items, out.jamo.items);
        out.composed.appendNTimesAssumeCapacity(false, out.codepoints.items.len);
    } else if (may_compose) {
        const ctx = struct {
            font: *const ttf.Font,
            indic: bool,
            pub fn hasGlyph(c: @This(), cp: u21) bool {
                return (c.font.getGlyphId(cp) orelse 0) != 0;
            }
            /// HarfBuzz's compose_indic: split matras are not recomposed
            pub fn allowStarter(c: @This(), cp: u21) bool {
                return !c.indic or !unicode_props.isMark(cp);
            }
        }{ .font = font, .indic = mode == .indic };
        // Marks in canonical order first, as HarfBuzz's normalization
        const spans: ?[][2]u32 = if (track_offsets) out.spans.items else null;
        unicode_compose.reorderMarks(out.codepoints.items, if (offsets) |o| o.items else null, spans);
        out.composed.items.len = out.codepoints.items.len;
        const n = unicode_compose.composeInPlace(out.codepoints.items, out.composed.items, if (offsets) |o| o.items else null, spans, ctx);
        out.codepoints.items.len = n;
        out.composed.items.len = n;
        if (offsets) |o| o.items.len = n;
        if (track_offsets) out.spans.items.len = n;
    } else {
        out.composed.appendNTimesAssumeCapacity(false, out.codepoints.items.len);
    }

    for (out.codepoints.items) |cp| {
        // ASCII: cached glyph (looked up at font load)
        const gid = if (cp < 128 and font.has_ascii_cache) font.ascii_glyphs[cp] else font.getGlyphId(cp) orelse 0;
        out.glyphs.appendAssumeCapacity(gid);
    }

    if (out.ignorables and font.cmap_uvs_offset != 0) applyVariationSequences(font, out, track_offsets);
    if (may_fall_back) try fallbackGlyphs(allocator, font, out);
}

fn hasGlyph(font: *const ttf.Font, cp: u21) bool {
    return (font.getGlyphId(cp) orelse 0) != 0;
}

/// HarfBuzz's decompose (normalization round 1, shortest form): a
/// character without a glyph becomes its canonical decomposition when the
/// font has the second part, recursing into the first. False if the font
/// can't draw it that way either.
fn decomposeInto(font: *const ttf.Font, cp: u21, buf: []u21, n: *usize) bool {
    const parts = unicode_props.decomposeOnce(cp) orelse return false;
    const a = parts[0];
    const b = parts[1];
    if (b != 0 and !hasGlyph(font, b)) return false;
    if (n.* + 2 > buf.len) return false;
    const start = n.*;
    if (hasGlyph(font, a)) {
        buf[n.*] = a;
        n.* += 1;
    } else if (!decomposeInto(font, a, buf, n)) {
        n.* = start;
        return false;
    }
    if (b != 0) {
        if (n.* >= buf.len) {
            n.* = start;
            return false;
        }
        buf[n.*] = b;
        n.* += 1;
    }
    return true;
}

/// HarfBuzz's decompose without short-circuit (the Indic shaper): the
/// deepest decomposition whose parts the font has, even when it has the
/// character itself; U+0931 is never decomposed (decompose_indic).
fn decomposeAll(font: *const ttf.Font, cp: u21, buf: []u21, n: *usize) bool {
    if (cp == 0x0931) return false;
    const parts = unicode_props.decomposeOnce(cp) orelse return false;
    const a = parts[0];
    const b = parts[1];
    if (b != 0 and !hasGlyph(font, b)) return false;
    if (n.* + 2 > buf.len) return false;
    const start = n.*;
    if (!decomposeAll(font, a, buf, n)) {
        n.* = start;
        if (!hasGlyph(font, a)) return false;
        buf[n.*] = a;
        n.* += 1;
    }
    if (b != 0) {
        if (n.* >= buf.len) {
            n.* = start;
            return false;
        }
        buf[n.*] = b;
        n.* += 1;
    }
    return true;
}

fn tryDecompose(font: *const ttf.Font, cp: u21, mode: Mode, buf: []u21, n: *usize) bool {
    if (cp < 0xC0) return false;
    return switch (mode) {
        .default, .hangul => !hasGlyph(font, cp) and decomposeInto(font, cp, buf, n),
        .indic => decomposeAll(font, cp, buf, n),
    };
}

/// Decomposes the characters the font lacks (in Indic mode, all it has
/// the parts of); true if any was.
fn decomposeMissing(allocator: Allocator, font: *const ttf.Font, out: *Decoded, track_offsets: bool, mode: Mode) !bool {
    const cps = out.codepoints.items;
    var first: ?usize = null;
    var buf: [8]u21 = undefined;
    for (cps, 0..) |cp, i| {
        var n: usize = 0;
        if (tryDecompose(font, cp, mode, &buf, &n)) {
            first = i;
            break;
        }
    }
    const from = first orelse return false;

    var new_cps: std.ArrayListUnmanaged(u21) = .empty;
    errdefer new_cps.deinit(allocator);
    var new_offsets: std.ArrayListUnmanaged(u32) = .empty;
    errdefer new_offsets.deinit(allocator);
    var new_spans: std.ArrayListUnmanaged([2]u32) = .empty;
    errdefer new_spans.deinit(allocator);
    var new_jamo: std.ArrayListUnmanaged(u8) = .empty;
    errdefer new_jamo.deinit(allocator);
    const jamo = out.jamo.items.len > 0;
    if (jamo) try new_jamo.appendSlice(allocator, out.jamo.items[0..from]);
    try new_cps.ensureTotalCapacity(allocator, cps.len + 8);
    new_cps.appendSliceAssumeCapacity(cps[0..from]);
    if (track_offsets) {
        try new_offsets.appendSlice(allocator, out.offsets.items[0..from]);
        try new_spans.appendSlice(allocator, out.spans.items[0..from]);
    }
    for (cps[from..], from..) |cp, i| {
        var n: usize = 0;
        const parts: []const u21 = if (tryDecompose(font, cp, mode, &buf, &n)) buf[0..n] else &.{cp};
        try new_cps.appendSlice(allocator, parts);
        if (jamo) try new_jamo.appendNTimes(allocator, out.jamo.items[i], parts.len);
        if (track_offsets) {
            try new_offsets.appendNTimes(allocator, out.offsets.items[i], parts.len);
            // The first part stands for the character, the others for none
            const span = out.spans.items[i];
            try new_spans.append(allocator, span);
            try new_spans.appendNTimes(allocator, .{ span[1], span[1] }, parts.len - 1);
        }
    }
    out.codepoints.deinit(allocator);
    out.codepoints = new_cps;
    if (track_offsets) {
        out.offsets.deinit(allocator);
        out.offsets = new_offsets;
        out.spans.deinit(allocator);
        out.spans = new_spans;
    } else new_spans.deinit(allocator);
    out.jamo.deinit(allocator);
    out.jamo = new_jamo;
    // The other per-code-point lists are filled after this, at this length
    try out.composed.ensureTotalCapacity(allocator, out.codepoints.items.len);
    try out.glyphs.ensureTotalCapacity(allocator, out.codepoints.items.len);
    return true;
}

/// HarfBuzz's Devanagari vowel constraints (hb-ot-shaper-vowel-
/// constraints.cc): a dotted circle goes before a vowel sign that would
/// turn an independent vowel into another one (A + AA reads as AA), so the
/// sequence shows as written. It takes the vowel sign's offset.
fn vowelConstraints(allocator: Allocator, out: *Decoded, track_offsets: bool) !void {
    const cps = out.codepoints.items;
    const n = cps.len;
    const matches = struct {
        fn f(c: []const u21, idx: usize) bool {
            const next = c[idx + 1];
            return switch (c[idx]) {
                0x0905 => switch (next) {
                    0x093A, 0x093B, 0x093E, 0x0945, 0x0946, 0x0949, 0x094A, 0x094B, 0x094C, 0x094F, 0x0956, 0x0957 => true,
                    else => false,
                },
                0x0906 => switch (next) {
                    0x093A, 0x0945, 0x0946, 0x0947, 0x0948 => true,
                    else => false,
                },
                0x0909 => next == 0x0941,
                0x090F => next == 0x0945 or next == 0x0946 or next == 0x0947,
                else => false,
            };
        }
    }.f;
    var any = false;
    for (0..n -| 1) |i| {
        if (matches(cps, i) or (cps[i] == 0x0930 and cps[i + 1] == 0x094D and i + 2 < n and cps[i + 2] == 0x0907)) {
            any = true;
            break;
        }
    }
    if (!any) return;

    var new_cps: std.ArrayListUnmanaged(u21) = .empty;
    errdefer new_cps.deinit(allocator);
    var new_offsets: std.ArrayListUnmanaged(u32) = .empty;
    errdefer new_offsets.deinit(allocator);
    var new_spans: std.ArrayListUnmanaged([2]u32) = .empty;
    errdefer new_spans.deinit(allocator);
    const offs = out.offsets.items;
    const spans = out.spans.items;
    const Lists = struct {
        a: Allocator,
        c: *std.ArrayListUnmanaged(u21),
        o: *std.ArrayListUnmanaged(u32),
        s: *std.ArrayListUnmanaged([2]u32),
        track: bool,
        fn push(l: @This(), cp: u21, off: u32, span: [2]u32) !void {
            try l.c.append(l.a, cp);
            if (l.track) {
                try l.o.append(l.a, off);
                try l.s.append(l.a, span);
            }
        }
    };
    const l: Lists = .{ .a = allocator, .c = &new_cps, .o = &new_offsets, .s = &new_spans, .track = track_offsets };
    const at = struct {
        fn off(t: bool, o: []const u32, k: usize) u32 {
            return if (t) o[k] else 0;
        }
        fn span(t: bool, sp: []const [2]u32, k: usize) [2]u32 {
            return if (t) sp[k] else .{ 0, 0 };
        }
    };
    var idx: usize = 0;
    while (idx + 1 < n) {
        var matched = matches(cps, idx);
        if (cps[idx] == 0x0930 and cps[idx + 1] == 0x094D and idx + 2 < n and cps[idx + 2] == 0x0907) {
            try l.push(cps[idx], at.off(track_offsets, offs, idx), at.span(track_offsets, spans, idx));
            idx += 1;
            matched = true;
        }
        try l.push(cps[idx], at.off(track_offsets, offs, idx), at.span(track_offsets, spans, idx));
        idx += 1;
        if (matched) {
            // The inserted circle stands for no text
            const next = at.off(track_offsets, offs, idx);
            try l.push(0x25CC, next, .{ next, next });
            try l.push(cps[idx], next, at.span(track_offsets, spans, idx));
            idx += 1;
        }
    }
    while (idx < n) : (idx += 1) try l.push(cps[idx], at.off(track_offsets, offs, idx), at.span(track_offsets, spans, idx));
    out.codepoints.deinit(allocator);
    out.codepoints = new_cps;
    if (track_offsets) {
        out.offsets.deinit(allocator);
        out.offsets = new_offsets;
        out.spans.deinit(allocator);
        out.spans = new_spans;
    } else {
        new_offsets.deinit(allocator);
        new_spans.deinit(allocator);
    }
    try out.composed.ensureTotalCapacity(allocator, out.codepoints.items.len);
    try out.glyphs.ensureTotalCapacity(allocator, out.codepoints.items.len);
}

/// Glyphs for characters the font still lacks: a space takes the space
/// glyph (with its fallback width recorded), U+2011 the glyph of U+2010.
fn fallbackGlyphs(allocator: Allocator, font: *const ttf.Font, out: *Decoded) !void {
    for (out.codepoints.items, out.glyphs.items, 0..) |cp, *gid, i| {
        if (gid.* != 0 or cp < 0xA0) continue;
        if (cp == 0x2011) {
            gid.* = font.getGlyphId(0x2010) orelse 0;
            continue;
        }
        const kind = unicode_props.SpaceFallback.of(cp);
        if (kind == .none) continue;
        const space = font.getGlyphId(' ') orelse 0;
        if (space == 0) continue;
        gid.* = space;
        if (out.space_fallbacks.items.len == 0) {
            try out.space_fallbacks.appendNTimes(allocator, .none, out.codepoints.items.len);
        }
        out.space_fallbacks.items[i] = kind;
    }
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
        if (d.jamo.items.len > 0) d.jamo.items[out] = d.jamo.items[i];
        if (track_offsets) {
            d.offsets.items[out] = d.offsets.items[i];
            d.spans.items[out] = d.spans.items[i];
        }
        if (i + 1 < cps.len and isVariationSelector(cps[i + 1])) {
            if (font.getVariationGlyph(cps[i], cps[i + 1])) |gid| {
                glyphs[out] = gid;
                // The selector is part of the character's text
                if (track_offsets) d.spans.items[out][1] = d.spans.items[i + 1][1];
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
    if (d.jamo.items.len > 0) d.jamo.items.len = out;
    if (track_offsets) {
        d.offsets.items.len = out;
        d.spans.items.len = out;
    }
    d.ignorables = for (d.codepoints.items) |cp| {
        if (gsub.Ignorable.of(cp) != .none) break true;
    } else false;
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}
