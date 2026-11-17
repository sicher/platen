//! CID text rendering with kerning and mark positioning.
//!
//! This module handles OpenType text layout features including:
//! - Ligature substitution
//! - Kerning adjustments
//! - Mark-to-base and mark-to-mark positioning

const std = @import("std");
const pagemod = @import("page.zig");
const embedded = @import("embedded.zig");
const opentype = @import("opentype.zig");
const format = @import("format.zig");

const ContentWriter = pagemod.ContentWriter;
const EmbeddedFont = embedded.EmbeddedFont;

// Re-export fast hex conversion from format module
const writeHex4 = format.writeHex4;

/// Render CID text with ligatures, kerning, and mark positioning
/// Returns true if advanced positioning was used (kerning or marks)
/// start_x, start_y are absolute page coordinates for Tm-based mark positioning
/// If cached_glyphs is provided, uses those instead of computing from str
/// word_spacing (points) is added after each space glyph: PDF applies Tw
/// only to the single-byte code 32, never to 2-byte Identity-H codes.
/// char_spacing is applied by Tc, except in the per-glyph Tm path, which
/// adds it itself
/// shear slants the glyphs (synthesized italic); 0 for upright text
pub fn renderCIDTextWithKerning(
    cw: *ContentWriter,
    emb: *EmbeddedFont,
    str: []const u8,
    cached_glyphs: ?[]const u16,
    font_size: f64,
    start_x: f64,
    start_y: f64,
    word_spacing: f64,
    char_spacing: f64,
    shear: f64,
) !bool {
    // Use cached glyphs if available, otherwise compute
    const glyphs_to_free: ?[]u16 = if (cached_glyphs == null) try emb.getGlyphsForText(str) else null;
    defer if (glyphs_to_free) |g| emb.allocator.free(g);
    const glyphs = cached_glyphs orelse glyphs_to_free.?;

    if (glyphs.len == 0) return false;

    const has_remap = emb.gid_remap.count() > 0;
    const units_per_em = emb.font.head.?.units_per_em;

    // Check if we have any kerning or mark positioning
    // Fast path: skip check loop if font has no kerning/mark data at all
    var has_kerning = false;
    var has_marks = false;
    const check_kern = emb.feature_flags.isEnabled(.kern) and emb.has_kern_data;
    const check_marks = (emb.feature_flags.isEnabled(.mark) or emb.feature_flags.isEnabled(.mkmk)) and emb.has_mark_data;
    if (check_kern or check_marks) {
        // Early exit once both are found (or we know we won't find the other)
        for (0..glyphs.len -| 1) |i| {
            if (!has_kerning and check_kern and emb.getKerning(glyphs[i], glyphs[i + 1]) != 0) {
                has_kerning = true;
                if (!check_marks or has_marks) break;
            }
            if (!has_marks and check_marks and emb.getMarkOffset(glyphs[i], glyphs[i + 1]) != null) {
                has_marks = true;
                if (!check_kern or has_kerning) break;
            }
        }
    }

    const space_gid = spaceGlyph(emb, glyphs, word_spacing);

    // If we have marks with y-offsets, use Tm-based absolute positioning (like LibreOffice)
    if (has_marks) {
        return try renderWithMarkPositioning(cw, emb, glyphs, font_size, units_per_em, has_remap, start_x, start_y, space_gid, word_spacing, char_spacing, shear);
    }

    // No marks - use Td for initial position (Tm when slanted)
    if (shear != 0) try cw.writeTmShear(start_x, start_y, shear) else try cw.writeTd(start_x, start_y);

    if (!has_kerning and space_gid == null) {
        // No kerning - use simple hex string
        try cw.append("<");
        var hex_buf: [4]u8 = undefined;
        for (glyphs) |gid| {
            const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
            writeHex4(&hex_buf, final_gid);
            try cw.append(&hex_buf);
        }
        try cw.append("> Tj\n");
        return false;
    }

    // Use TJ operator with kerning (and word spacing) adjustments
    // Format: [<HexGlyphs> kern <HexGlyphs> kern ...] TJ
    const ws_1000 = wordSpacing1000(word_spacing, font_size);
    try cw.append("[<");
    var hex_buf: [4]u8 = undefined;

    for (glyphs, 0..) |gid, i| {
        const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
        writeHex4(&hex_buf, final_gid);
        try cw.append(&hex_buf);

        // Add kerning adjustment before next glyph
        if (i + 1 < glyphs.len) {
            const kern = emb.getKerning(gid, glyphs[i + 1]);
            // Convert from font units to 1/1000 em, negate for TJ
            // TJ uses positive values to move left (reduce spacing)
            const kern_1000: i32 = @divTrunc(@as(i32, kern) * 1000, @as(i32, units_per_em));
            const ws: i32 = if (space_gid != null and gid == space_gid.?) ws_1000 else 0;
            if (kern_1000 != 0 or ws != 0) {
                try cw.writeKernAdjust(-kern_1000 - ws);
            }
        }
    }

    try cw.append(">] TJ\n");
    return true;
}

/// A shaped run (EmbeddedFont.shapeRun) at (x, y): each glyph advances by
/// its shaped advance. Without offsets it is one TJ: a viewer advances a
/// glyph by its /W width, so each gap carries the difference to the shaped
/// advance in 1/1000 em, the remainder carried on so the pen never drifts
/// (word spacing after spaces too; Tc, set by the caller, after each
/// glyph). A run with offsets (GPOS marks) places every glyph by its own
/// text matrix instead, adding the character spacing itself: a gap per
/// glyph as measured, but a zero-advance glyph (a mark) stays on its base,
/// its gap added before the next glyph that advances.
pub fn renderShapedRun(
    cw: *ContentWriter,
    emb: *EmbeddedFont,
    glyphs: []const u16,
    pos: []const EmbeddedFont.GlyphPos,
    font_size: f64,
    x: f64,
    y: f64,
    word_spacing: f64,
    char_spacing: f64,
    shear: f64,
) !void {
    if (glyphs.len == 0) return;
    const has_remap = emb.gid_remap.count() > 0;
    const em: f64 = @floatFromInt(emb.font.head.?.units_per_em);
    const space_gid = spaceGlyph(emb, glyphs, word_spacing);
    var hex_buf: [4]u8 = undefined;

    var offsets = false;
    for (pos) |p| {
        if (p.dx != 0 or p.dy != 0) offsets = true;
    }
    if (offsets) {
        const scale = font_size / em;
        var pen = x;
        var deferred: f64 = 0;
        for (glyphs, pos) |gid, p| {
            if (p.advance != 0) {
                pen += deferred;
                deferred = 0;
            }
            const gx = pen + @as(f64, @floatFromInt(p.dx)) * scale;
            const gy = y + @as(f64, @floatFromInt(p.dy)) * scale;
            if (shear != 0) try cw.writeTmShear(gx, gy, shear) else try cw.writeTm3(gx, gy);
            writeHex4(&hex_buf, if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid);
            try cw.append("<");
            try cw.append(&hex_buf);
            try cw.append("> Tj\n");
            pen += @as(f64, @floatFromInt(p.advance)) * scale;
            deferred += char_spacing;
            if (space_gid != null and gid == space_gid.?) pen += word_spacing;
        }
        return;
    }

    // The adjustment after each glyph (1/1000 em, positive = further
    // right): its whole part, the fraction carried on, so the pen is never
    // off by 1/1000 em or more and a run of /W-rounded glyphs needs no
    // adjustment at every glyph
    const ws_1000: f64 = if (space_gid != null) word_spacing * 1000.0 / font_size else 0;
    const adjust = try emb.allocator.alloc(i32, glyphs.len);
    defer emb.allocator.free(adjust);
    var carry: f64 = 0;
    var any = false;
    for (glyphs, pos, adjust, 0..) |gid, p, *adj, i| {
        if (i + 1 == glyphs.len) {
            adj.* = 0;
            break;
        }
        var want = carry + @as(f64, @floatFromInt(p.advance)) * 1000.0 / em - @as(f64, @floatFromInt(emb.getGlyphWidth(gid)));
        if (space_gid != null and gid == space_gid.?) want += ws_1000;
        adj.* = @intFromFloat(@trunc(want));
        carry = want - @as(f64, @floatFromInt(adj.*));
        if (adj.* != 0) any = true;
    }

    if (shear != 0) try cw.writeTmShear(x, y, shear) else try cw.writeTd(x, y);
    if (!any) {
        try cw.append("<");
        for (glyphs) |gid| {
            writeHex4(&hex_buf, if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid);
            try cw.append(&hex_buf);
        }
        try cw.append("> Tj\n");
        return;
    }
    try cw.append("[<");
    for (glyphs, adjust, 0..) |gid, adj, i| {
        writeHex4(&hex_buf, if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid);
        try cw.append(&hex_buf);
        if (adj != 0 and i + 1 < glyphs.len) try cw.writeKernAdjust(-adj);
    }
    try cw.append(">] TJ\n");
}

/// The (unremapped) space glyph when `word_spacing` applies to this run,
/// else null.
pub fn spaceGlyph(emb: *const EmbeddedFont, glyphs: []const u16, word_spacing: f64) ?u16 {
    if (word_spacing == 0) return null;
    const gid = emb.font.getGlyphId(' ') orelse return null;
    if (gid == 0 or std.mem.indexOfScalar(u16, glyphs, gid) == null) return null;
    return gid;
}

/// Word spacing in TJ units (1/1000 em of the current font size).
pub fn wordSpacing1000(word_spacing: f64, font_size: f64) i32 {
    return @intFromFloat(@round(word_spacing * 1000.0 / font_size));
}

/// Render glyphs with mark positioning using absolute Tm positioning (like LibreOffice).
/// Each glyph gets positioned with "1 0 0 1 x y Tm" followed by glyph Tj.
/// This avoids relying on PDF auto-advance behavior.
fn renderWithMarkPositioning(
    cw: *ContentWriter,
    emb: *EmbeddedFont,
    glyphs: []const u16,
    font_size: f64,
    units_per_em: u16,
    has_remap: bool,
    start_x: f64,
    start_y: f64,
    space_gid: ?u16,
    word_spacing: f64,
    char_spacing: f64,
    shear: f64,
) !bool {
    // Track absolute position for each glyph
    var abs_x = start_x;
    const abs_y = start_y; // Baseline doesn't change for horizontal text

    var i: usize = 0;
    while (i < glyphs.len) {
        const gid = glyphs[i];
        const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
        const glyph_width = emb.getGlyphWidth(gid); // in 1/1000 em
        const glyph_width_pts = @as(f64, @floatFromInt(glyph_width)) * font_size / 1000.0;

        // Check if next glyphs are marks that attach to this base (or to other marks)
        // A mark can attach to:
        // 1. The previous glyph (mark-to-mark for stacked diacritics)
        // 2. The base glyph directly (multiple marks on same base, e.g., cedilla below + acute above)
        var mark_count: usize = 0;
        var j = i + 1;
        while (j < glyphs.len) {
            const potential_mark = glyphs[j];
            // Check mark-to-mark (attaches to previous glyph)
            if (emb.getMarkOffset(glyphs[j - 1], potential_mark) != null) {
                mark_count += 1;
                j += 1;
            }
            // Check mark-to-base (attaches directly to base, e.g., acute on 's' when cedilla is also present)
            else if (emb.getMarkOffset(gid, potential_mark) != null) {
                mark_count += 1;
                j += 1;
            } else {
                break;
            }
        }

        // Save base glyph origin for mark positioning
        const base_x = abs_x;
        const base_y = abs_y;

        // Position and output base glyph using Tm (absolute positioning)
        try cw.writeTmShear(abs_x, abs_y, shear);
        var hex_buf: [4]u8 = undefined;
        writeHex4(&hex_buf, final_gid);
        try cw.append("<");
        try cw.append(&hex_buf);
        try cw.append("> Tj\n");

        // Advance position for next base glyph
        abs_x += glyph_width_pts;
        if (space_gid != null and gid == space_gid.?) abs_x += word_spacing;

        if (mark_count > 0) {
            // Render marks with absolute positioning
            // Track previous glyph for mark-to-mark positioning
            var prev_gid = gid;
            var prev_x = base_x;
            var prev_y = base_y;

            for (0..mark_count) |m| {
                const mark_gid = glyphs[i + 1 + m];
                const mark_final_gid = if (has_remap) emb.gid_remap.get(mark_gid) orelse 0 else mark_gid;

                // Try mark-to-mark first (attaches to previous mark)
                // Then try mark-to-base (attaches directly to base)
                var ref_x = base_x;
                var ref_y = base_y;
                var offset: ?opentype.MarkOffset = emb.getMarkOffset(prev_gid, mark_gid);
                if (offset != null) {
                    // Mark-to-mark: position relative to previous mark
                    ref_x = prev_x;
                    ref_y = prev_y;
                } else {
                    // Try mark-to-base: position relative to base glyph
                    offset = emb.getMarkOffset(gid, mark_gid);
                }

                if (offset) |off| {
                    // Convert mark offset from design units to points
                    const dx_pts = @as(f64, @floatFromInt(off.dx)) * font_size / @as(f64, @floatFromInt(units_per_em));
                    const dy_pts = @as(f64, @floatFromInt(off.dy)) * font_size / @as(f64, @floatFromInt(units_per_em));

                    // Mark position is relative to reference glyph (base or previous mark)
                    const mark_x = ref_x + dx_pts;
                    const mark_y = ref_y + dy_pts;

                    // Position and output mark using Tm (absolute positioning)
                    try cw.writeTmShear(mark_x, mark_y, shear);
                    var mark_hex_buf: [4]u8 = undefined;
                    writeHex4(&mark_hex_buf, mark_final_gid);
                    try cw.append("<");
                    try cw.append(&mark_hex_buf);
                    try cw.append("> Tj\n");

                    // Update prev position for potential mark-to-mark stacking
                    prev_gid = mark_gid;
                    prev_x = mark_x;
                    prev_y = mark_y;
                }
            }

            i += 1 + mark_count;
        } else {
            i += 1;
        }

        // Tc never applies here (every glyph is placed by Tm): add the
        // character spacing of the base and each of its marks, as
        // measurement counts one gap per glyph
        abs_x += char_spacing * @as(f64, @floatFromInt(1 + mark_count));

        // Add kerning if next glyph exists
        const next_idx = i;
        if (next_idx < glyphs.len) {
            const kern = emb.getKerning(gid, glyphs[next_idx]);
            if (kern != 0) {
                const kern_pts = @as(f64, @floatFromInt(kern)) * font_size / @as(f64, @floatFromInt(units_per_em));
                abs_x += kern_pts;
            }
        }
    }

    return true;
}

/// Glyphs by ID, each placed with its own text matrix (Document.drawGlyphs).
/// `font_index` names the font resource (/E<index+1>).
pub fn renderPlacedGlyphs(cw: *ContentWriter, g: pagemod.GlyphsCommand, font_index: usize) !void {
    if (g.ids.len == 0) return;
    const emb = g.font;
    const has_remap = emb.gid_remap.count() > 0;
    try cw.append("BT\n");
    try g.text_color.writeFill(cw);
    try cw.print("/E{d} {d:.3} Tf\n", .{ font_index + 1, g.font_size });
    var hex_buf: [4]u8 = undefined;
    for (g.ids, g.xs, g.ys) |gid, x, y| {
        try cw.writeTm3(x, y);
        writeHex4(&hex_buf, if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid);
        try cw.append("<");
        try cw.append(&hex_buf);
        try cw.append("> Tj\n");
    }
    try cw.append("ET\n");
}

/// A TextCommand's `placed` glyphs: one text matrix each (slanted by
/// `shear` for synthesized italic), at (x, y) plus the glyph's offset.
pub fn renderPlacedOffsets(cw: *ContentWriter, emb: *EmbeddedFont, placed: []const pagemod.PlacedOffset, x: f64, y: f64, shear: f64) !void {
    const has_remap = emb.gid_remap.count() > 0;
    var hex_buf: [4]u8 = undefined;
    for (placed) |p| {
        if (shear != 0) try cw.writeTmShear(x + p.dx, y + p.dy, shear) else try cw.writeTm3(x + p.dx, y + p.dy);
        writeHex4(&hex_buf, if (has_remap) emb.gid_remap.get(p.id) orelse 0 else p.id);
        try cw.append("<");
        try cw.append(&hex_buf);
        try cw.append("> Tj\n");
    }
}
