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
/// only to the single-byte code 32, never to 2-byte Identity-H codes
pub fn renderCIDTextWithKerning(
    cw: *ContentWriter,
    emb: *EmbeddedFont,
    str: []const u8,
    cached_glyphs: ?[]const u16,
    font_size: f64,
    start_x: f64,
    start_y: f64,
    word_spacing: f64,
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
        return try renderWithMarkPositioning(cw, emb, glyphs, font_size, units_per_em, has_remap, start_x, start_y, space_gid, word_spacing);
    }

    // No marks - use Td for initial position
    try cw.writeTd(start_x, start_y);

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
        try cw.writeTm(abs_x, abs_y);
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
                    try cw.writeTm(mark_x, mark_y);
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
