//! CID text rendering: shaped runs (EmbeddedFont.shapeRun: glyphs with
//! their advances and offsets, as GSUB and GPOS made them), glyphs placed
//! by ID (Document.drawGlyphs) and placed clusters (.monospace fallback).

const std = @import("std");
const pagemod = @import("page.zig");
const embedded = @import("embedded.zig");
const format = @import("format.zig");

const ContentWriter = pagemod.ContentWriter;
const EmbeddedFont = embedded.EmbeddedFont;

// Re-export fast hex conversion from format module
const writeHex4 = format.writeHex4;

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
