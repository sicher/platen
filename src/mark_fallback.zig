//! Fallback mark positioning, for fonts without GPOS: HarfBuzz's
//! _hb_ot_shape_fallback_mark_position (hb-ot-shape-fallback.cc), left to
//! right. Marks are stacked on their base by glyph extents and their
//! (recategorized) combining class: centered, left- or right-aligned,
//! above or below with a gap of 1/16 em, per ligature component.

const std = @import("std");
const gsub = @import("gsub.zig");
const gpos = @import("gpos.zig");
const ttf = @import("ttf.zig");
const unicode_props = @import("unicode_props.zig");
const unicode_compose = @import("unicode_compose.zig");

const Glyph = gsub.Glyph;
const Position = gpos.Position;
const Extents = ttf.GlyphExtents;

// Unicode combining classes HarfBuzz positions by
const attached_below_left = 200;
const attached_below = 202;
const attached_above = 214;
const attached_above_right = 216;
const below_left = 218;
const below = 220;
const below_right = 222;
const above_left = 228;
const above = 230;
const above_right = 232;
const double_below = 233;
const double_above = 234;

/// HarfBuzz's recategorize_combining_class: Hebrew, Arabic, Syriac, Thai,
/// Lao and Tibetan fixed-position classes as positions. `class` is the
/// modified combining class (unicode_compose.modifiedCombiningClass).
fn recategorize(cp: u21, class: u8) u8 {
    if (class >= 200) return class;
    var k = class;
    if (cp & ~@as(u21, 0xFF) == 0x0E00) {
        if (k == 0) {
            switch (cp) {
                0x0E31, 0x0E34, 0x0E35, 0x0E36, 0x0E37, 0x0E47, 0x0E4C, 0x0E4D, 0x0E4E => k = above_right,
                0x0EB1, 0x0EB4, 0x0EB5, 0x0EB6, 0x0EB7, 0x0EBB, 0x0ECC, 0x0ECD => k = above,
                0x0EBC => k = below,
                else => {},
            }
        } else if (cp == 0x0E3A) k = below_right; // Thai virama
    }
    // Case labels are modified classes (HB_MODIFIED_COMBINING_CLASS_CCCn)
    return switch (k) {
        22, 15, 16, 17, 23, 18, 19, 20, 21, 24, 25 => below, // Hebrew points, meteg
        13 => attached_above, // rafe
        10 => above_right, // shin dot
        11, 14 => above_left, // sin dot, holam
        26 => above, // point varika
        28, 29, 31, 32, 27, 34, 35, 36 => above, // Arabic fathatan .. superscript alef, Syriac
        30, 33 => below, // kasratan, kasra
        3 => below_right, // Thai sara u / uu
        107 => above_right, // Thai mai
        118 => below, // Lao sign u / uu
        122 => above, // Lao mai
        129 => below, // Tibetan sign aa
        132 => above, // Tibetan sign i
        131 => below, // Tibetan sign u
        else => k,
    };
}

/// The combining class a glyph is positioned by: its character's modified
/// class (0 for non-marks), recategorized for nonspacing marks.
fn classOf(cps: []const u21, g: Glyph) u8 {
    const cp = cps[g.cp];
    if (!unicode_props.isMark(cp)) return 0;
    const m = unicode_compose.modifiedCombiningClass(cp);
    return if (unicode_props.isNonspacingMark(cp)) recategorize(cp, m) else m;
}

fn isMarkChar(cps: []const u21, g: Glyph) bool {
    return unicode_props.isMark(cps[g.cp]);
}

/// Positions the marks of `glyphs` (their characters in `cps`, by
/// `Glyph.cp`) around their bases. `table` supplies glyph classes (for
/// ligature components). `adjust_offsets` as for zeroMarkWidths.
pub fn position(table: *const gsub.Table, font: *const ttf.Font, cps: []const u21, glyphs: []Glyph, pos: []Position, adjust_offsets: bool) void {
    var list: std.ArrayListUnmanaged(Glyph) = .fromOwnedSlice(glyphs);
    var m: gsub.Context = .{ .table = table, .buf = &list, .max_len = glyphs.len };
    const upem: i32 = font.head.?.units_per_em;
    var start: usize = 0;
    for (1..glyphs.len) |i| {
        if (isMarkChar(cps, glyphs[i])) continue;
        positionCluster(&m, font, upem, cps, pos, start, i, adjust_offsets);
        start = i;
    }
    positionCluster(&m, font, upem, cps, pos, start, glyphs.len, adjust_offsets);
}

fn positionCluster(m: *gsub.Context, font: *const ttf.Font, upem: i32, cps: []const u21, pos: []Position, start: usize, end: usize, adjust_offsets: bool) void {
    if (end - start < 2) return;
    const glyphs = m.buf.items;
    var i = start;
    while (i < end) : (i += 1) {
        if (isMarkChar(cps, glyphs[i])) continue;
        var j = i + 1;
        while (j < end and isMarkChar(cps, glyphs[j])) j += 1;
        positionAroundBase(m, font, upem, cps, pos, i, j, adjust_offsets);
        i = j - 1;
    }
}

fn positionAroundBase(m: *gsub.Context, font: *const ttf.Font, upem: i32, cps: []const u21, pos: []Position, base: usize, end: usize, adjust_offsets: bool) void {
    const glyphs = m.buf.items;
    var base_extents = font.glyphExtents(glyphs[base].id) orelse {
        // No extents: zero the marks' advances and leave them
        for (glyphs[base + 1 .. end], pos[base + 1 .. end]) |g, *p| {
            if (!unicode_props.isNonspacingMark(cps[g.cp])) continue;
            if (adjust_offsets) {
                p.x_offset -= p.x_advance;
                p.y_offset -= p.y_advance;
            }
            p.x_advance = 0;
            p.y_advance = 0;
        }
        return;
    };
    base_extents.y_bearing += pos[base].y_offset;
    // The advance, not the ink, for horizontal placement (HarfBuzz #1532)
    base_extents.x_bearing = 0;
    base_extents.width = font.getGlyphWidth(glyphs[base].id) orelse 0;

    const lig_id = glyphs[base].lig_id;
    const num_comps: i32 = m.numComps(base);

    var x_offset: i32 = -pos[base].x_advance;
    var y_offset: i32 = -pos[base].y_advance;
    var component_extents = base_extents;
    var last_component: i32 = -1;
    var last_class: u16 = 255;
    var cluster_extents = base_extents;
    for (base + 1..end) |i| {
        const class = classOf(cps, glyphs[i]);
        if (class == 0) {
            x_offset -= pos[i].x_advance;
            y_offset -= pos[i].y_advance;
            continue;
        }
        if (num_comps > 1) {
            var component: i32 = @as(i32, glyphs[i].lig_comp) - 1;
            if (lig_id == 0 or lig_id != glyphs[i].lig_id or component >= num_comps) component = num_comps - 1;
            if (last_component != component) {
                last_component = component;
                last_class = 255;
                component_extents = base_extents;
                component_extents.x_bearing += @divTrunc(component * component_extents.width, num_comps);
                component_extents.width = @divTrunc(component_extents.width, num_comps);
            }
        }
        if (last_class != class) {
            last_class = class;
            cluster_extents = component_extents;
        }
        positionMark(font, upem, &cluster_extents, glyphs[i].id, &pos[i], class);
        pos[i].x_advance = 0;
        pos[i].y_advance = 0;
        pos[i].x_offset += x_offset;
        pos[i].y_offset += y_offset;
    }
}

/// HarfBuzz's position_mark: places one mark against `base` (the extents
/// so far of its class's stack, which it grows).
fn positionMark(font: *const ttf.Font, upem: i32, base: *Extents, glyph: u16, p: *Position, class: u8) void {
    const mark = font.glyphExtents(glyph) orelse return;
    const y_gap = @divTrunc(upem, 16);
    p.x_offset = 0;
    p.y_offset = 0;

    // X: double marks sit on the base's right edge (left to right); left
    // and right marks are not moved
    switch (class) {
        double_below, double_above => p.x_offset += base.x_bearing + base.width - @divTrunc(mark.width, 2) - mark.x_bearing,
        attached_below_left, below_left, above_left => p.x_offset += base.x_bearing - mark.x_bearing,
        attached_above_right, below_right, above_right => p.x_offset += base.x_bearing + base.width - mark.width - mark.x_bearing,
        else => p.x_offset += base.x_bearing + @divTrunc(base.width - mark.width, 2) - mark.x_bearing,
    }

    // Y
    switch (class) {
        double_below, below_left, below, below_right, attached_below_left, attached_below => {
            if (class != attached_below_left and class != attached_below) base.height -= y_gap;
            p.y_offset = base.y_bearing + base.height - mark.y_bearing;
            // Never shift "below" marks up
            if ((y_gap > 0) == (p.y_offset > 0)) {
                base.height -= p.y_offset;
                p.y_offset = 0;
            }
            base.height += mark.height;
        },
        double_above, above_left, above, above_right, attached_above, attached_above_right => {
            if (class != attached_above and class != attached_above_right) {
                base.y_bearing += y_gap;
                base.height -= y_gap;
            }
            p.y_offset = base.y_bearing - (mark.y_bearing + mark.height);
            // Don't shift "above" marks down too much
            if ((y_gap > 0) != (p.y_offset > 0)) {
                const correction = @divTrunc(-p.y_offset, 2);
                base.y_bearing += correction;
                base.height -= correction;
                p.y_offset += correction;
            }
            base.y_bearing -= mark.height;
            base.height += mark.height;
        },
        else => {},
    }
}
