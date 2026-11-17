//! Per-character font fallback (`TextStyle.fallback`).
//!
//! Text is cut into runs, each drawn in one font: a character goes to the
//! first of `font`, `fallback[0]`, `fallback[1]`, ... that has a glyph for
//! it, and to `font` when none does (its .notdef marks the gap). The unit
//! is an extended grapheme cluster (UAX #29: a base with its marks, a
//! conjunct, an emoji sequence), drawn in the first font that has all of
//! it or the precomposed letter it makes ("e" + U+0301 in a font with
//! "é"), so a cluster is always shaped in one font.
//!
//! Slot 0 is the primary font, slot i+1 is `fallback[i]`. A primary run is
//! written with the style as given (minus the fallback list); a fallback
//! run with the fallback's variant for the requested bold/italic. What a
//! fallback lacks is synthesized, with FreeType's strengths so a PDF
//! matches an on-screen render of the same face: bold strokes the outline
//! (FT_GlyphSlot_Embolden grows it by em/48 a side), italic slants the text
//! matrix (FT_GlyphSlot_Oblique's shear).
//!
//! With `.monospace` advance every fallback cluster is a run of its own,
//! shaped and centered in its cells: as many as `clusterCells` says (2 for
//! East Asian wide characters), each the width of the primary's space.

const std = @import("std");
const layout = @import("layout.zig");
const embedded = @import("embedded.zig");
const unicode_compose = @import("unicode_compose.zig");
const unicode_props = @import("unicode_props.zig");

const Font = layout.Font;
const TextStyle = layout.TextStyle;
const EmbeddedFont = embedded.EmbeddedFont;

/// Most fallback fonts one style may list.
pub const max_fallbacks = 32;

/// Stroke width of synthesized bold, as a fraction of the font size: a
/// stroke paints half its width outside the outline, em/48 a side.
pub const embolden_per_em: f64 = 1.0 / 24.0;

/// Horizontal shear of synthesized italic (FreeType's 0x0366A / 0x10000).
pub const oblique_shear: f64 = 0x0366A.0 / 65536.0;

pub const Error = error{ InvalidFallbackFont, TooManyFallbackFonts, FontVariantNotLoaded };

/// One fallback font in the requested style.
pub const Face = struct {
    /// A single face: `.embedded` or `.face`.
    font: Font,
    synth_bold: bool = false,
    synth_italic: bool = false,
};

/// The parsed font behind a single face (a `.face`'s shared prototype:
/// same tables and metrics as any document's clone of it).
fn embOf(font: Font) ?*EmbeddedFont {
    return switch (font) {
        .embedded => |e| if (e.encoding == .identity) e else null,
        .face => |f| f.prototype,
        else => null,
    };
}

/// The primary font's variant for bold/italic, for coverage and metrics.
pub fn primaryEmb(font: Font, bold: bool, italic: bool) Error!*EmbeddedFont {
    const emb: *EmbeddedFont = switch (font) {
        .embedded => |e| blk: {
            if (bold or italic) return error.FontVariantNotLoaded;
            break :blk e;
        },
        .face => |f| blk: {
            if (bold or italic) return error.FontVariantNotLoaded;
            break :blk f.prototype;
        },
        .embedded_family => |fam| try fam.resolve(bold, italic),
        .family => |fam| (try fam.resolve(bold, italic)).prototype,
        .standard, .symbol, .zapf_dingbats => return error.InvalidFallbackFont,
    };
    if (emb.encoding != .identity) return error.InvalidFallbackFont;
    return emb;
}

/// `font` as a fallback for bold/italic: its own variant where it has one,
/// the nearest variant plus synthesis where it does not.
pub fn face(font: Font, bold: bool, italic: bool) Error!Face {
    switch (font) {
        .embedded, .face => {
            const emb = embOf(font) orelse return error.InvalidFallbackFont;
            const own = emb.font.style;
            return .{ .font = font, .synth_bold = bold and !own.bold, .synth_italic = italic and !own.italic };
        },
        .embedded_family => |fam| {
            const v = nearest(*EmbeddedFont, fam, bold, italic);
            if (v.font.encoding != .identity) return error.InvalidFallbackFont;
            return .{ .font = .{ .embedded = v.font }, .synth_bold = v.synth_bold, .synth_italic = v.synth_italic };
        },
        .family => |fam| {
            const v = nearest(*const embedded.FontFace, fam, bold, italic);
            return .{ .font = .{ .face = v.font }, .synth_bold = v.synth_bold, .synth_italic = v.synth_italic };
        },
        .standard, .symbol, .zapf_dingbats => return error.InvalidFallbackFont,
    }
}

fn Nearest(comptime T: type) type {
    return struct { font: T, synth_bold: bool, synth_italic: bool };
}

/// A family's variant closest to bold/italic: exact, else keep italic and
/// synthesize bold, else keep bold and synthesize italic, else regular.
fn nearest(comptime T: type, fam: anytype, bold: bool, italic: bool) Nearest(T) {
    if (fam.resolve(bold, italic)) |f| return .{ .font = f, .synth_bold = false, .synth_italic = false } else |_| {}
    if (bold and italic) {
        if (fam.italic) |f| return .{ .font = f, .synth_bold = true, .synth_italic = false };
        if (fam.bold) |f| return .{ .font = f, .synth_bold = false, .synth_italic = true };
    }
    return .{ .font = fam.regular, .synth_bold = bold, .synth_italic = italic };
}

/// A style's fonts, resolved once per string.
pub const Plan = struct {
    primary: *EmbeddedFont,
    faces: [max_fallbacks]Face = undefined,
    n: usize = 0,
    monospace: bool,

    pub fn init(style: TextStyle) Error!Plan {
        if (style.fallback.len > max_fallbacks) return error.TooManyFallbackFonts;
        var p: Plan = .{
            .primary = try primaryEmb(style.font, style.bold, style.italic),
            .monospace = style.fallback_advance == .monospace,
        };
        for (style.fallback) |f| {
            p.faces[p.n] = try face(f, style.bold, style.italic);
            p.n += 1;
        }
        return p;
    }

    fn has(self: *const Plan, slot: usize, cp: u21) bool {
        const emb = if (slot == 0) self.primary else embOf(self.faces[slot - 1].font).?;
        return (emb.font.getGlyphId(cp) orelse 0) != 0;
    }

    /// Whether `slot` can draw a cluster: every codepoint as it is, or
    /// the base composed with marks into a precomposed letter it has (as
    /// platen's shaping composes, e.g. "e" + U+0301 -> "é").
    fn drawsCluster(self: *const Plan, slot: usize, cluster: []const u21) bool {
        var acc = cluster[0];
        for (cluster[1..]) |mark| {
            if (unicode_compose.compose(acc, mark)) |c| if (self.has(slot, c)) {
                acc = c;
                continue;
            };
            if (!self.has(slot, mark)) return false;
        }
        return self.has(slot, acc);
    }

    /// The first slot that draws the whole cluster; else the first that has
    /// its base (its marks then show as that font's .notdef or not at all).
    fn pick(self: *const Plan, cluster: []const u21) usize {
        for (0..self.n + 1) |slot| {
            if (self.drawsCluster(slot, cluster)) return slot;
        }
        for (0..self.n + 1) |slot| {
            if (self.has(slot, cluster[0])) return slot;
        }
        return 0;
    }

    /// The run starting at `start`: whole clusters (a character and the
    /// marks and ignorables after it), each in the font `pick` chooses.
    pub fn nextRun(self: *const Plan, text: []const u8, start: usize) Run {
        var buf: [max_cluster]u21 = undefined;
        var i = start;
        const slot = self.pick(nextCluster(text, &i, &buf));
        const one_cell = self.monospace and slot != 0;
        while (i < text.len and !one_cell) {
            var j = i;
            if (self.pick(nextCluster(text, &j, &buf)) != slot) break;
            i = j;
        }
        return .{ .end = i, .slot = slot };
    }

    /// The style a run in `slot` is written with (no fallback list).
    pub fn runStyle(self: *const Plan, style: TextStyle, slot: usize) TextStyle {
        var s = style;
        s.fallback = &.{};
        if (slot == 0) return s;
        s.font = self.faces[slot - 1].font;
        s.bold = false;
        s.italic = false;
        return s;
    }

    /// Advance of a `.monospace` fallback character, before char spacing:
    /// the primary's space.
    pub fn cell(self: *const Plan, size: f64) f64 {
        const gid = self.primary.font.getGlyphId(' ') orelse 0;
        return @as(f64, @floatFromInt(self.primary.getGlyphWidth(gid))) * size / 1000.0;
    }

    /// Width of `text` in `style`; `ctx.width(run, run_style)` measures one
    /// run (so a Document measures with its own font clones).
    pub fn measure(self: *const Plan, text: []const u8, style: TextStyle, ctx: anytype) f64 {
        var total: f64 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const run = self.nextRun(text, i);
            total += if (run.slot != 0 and self.monospace)
                @as(f64, @floatFromInt(clusterCells(style, text[i..run.end]))) * self.cell(style.size) + style.char_spacing
            else
                ctx.width(text[i..run.end], self.runStyle(style, run.slot));
            i = run.end;
        }
        return total;
    }
};

pub const Run = struct {
    /// End byte (exclusive).
    end: usize,
    /// 0 = primary, i+1 = fallback[i].
    slot: usize,
};

/// Longest cluster (as unicode_props.graphemeEndBytes cuts it).
const max_cluster = 32;

/// The extended grapheme cluster at `i.*`, advancing past it; its code
/// points.
fn nextCluster(text: []const u8, i: *usize, buf: *[max_cluster]u21) []const u21 {
    const end = unicode_props.graphemeEndBytes(text, i.*);
    var n: usize = 0;
    while (i.* < end and n < buf.len) : (n += 1) buf[n] = decode(text, i);
    i.* = end;
    return buf[0..n];
}

/// How a `.monospace` fallback cluster `own` points wide (at the style's
/// size) sits in `room` points of cells: scaled to fit when wider, capped
/// by `fallback_max_em`, and centered.
pub const Fit = struct { scale: f64, dx: f64 };

pub fn fitCluster(style: TextStyle, own: f64, room: f64) Fit {
    var scale: f64 = if (own > room and own > 0) room / own else 1;
    if (style.fallback_max_em) |cap| scale = @min(scale, @as(f64, cap));
    return .{ .scale = scale, .dx = (room - own * scale) / 2 };
}

/// Cells of the cluster `text` (one extended grapheme cluster) with
/// `.monospace`: the style's `fallback_cells` override, else
/// unicode_props.cells.
pub fn clusterCells(style: TextStyle, text: []const u8) u8 {
    if (style.fallback_cells) |f| return @max(1, f(text));
    var buf: [max_cluster]u21 = undefined;
    var i: usize = 0;
    return unicode_props.cells(nextCluster(text, &i, &buf));
}

/// Next codepoint at `i.*`, advancing past it. A byte that is not valid
/// UTF-8 decodes as U+FFFD and is consumed alone.
fn decode(text: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > text.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(text[i.*..][0..len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}
