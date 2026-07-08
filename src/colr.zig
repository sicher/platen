//! COLR v1 / CPAL color font support.
//!
//! Parses the CPAL palette table and the COLR (version 1) color-glyph paint
//! graph, and extracts `glyf` outlines as PDF path operators. Higher layers
//! turn a base color glyph into a PDF Type3 CharProc (see the paint interpreter
//! and Type3 emitter).
//!
//! Scope: COLR version 1 with glyf (TrueType) outlines. The supported paint
//! formats are ColrLayers, Solid, Linear/Radial gradients, Glyph (clip),
//! ColrGlyph, the affine transform family, and Composite. CFF-flavored color
//! fonts and COLR sweep gradients are not supported.

const std = @import("std");
const format = @import("format.zig");
const color = @import("color.zig");

pub const Color = color.Color;

// ============================================================================
// Big-endian readers (bounds-checked, returning 0 on overflow)
// ============================================================================

pub fn readU8(data: []const u8, off: usize) u8 {
    if (off >= data.len) return 0;
    return data[off];
}

pub fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

pub fn readI16(data: []const u8, off: usize) i16 {
    if (off + 2 > data.len) return 0;
    return std.mem.readInt(i16, data[off..][0..2], .big);
}

pub fn readU24(data: []const u8, off: usize) u32 {
    if (off + 3 > data.len) return 0;
    return (@as(u32, data[off]) << 16) | (@as(u32, data[off + 1]) << 8) | data[off + 2];
}

pub fn readU32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

/// Read an F2Dot14 fixed-point value (used by COLR transforms and composite
/// glyph component scales) as an f64.
pub fn readF2Dot14(data: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(readI16(data, off))) / 16384.0;
}

/// Read a Fixed (16.16) value as an f64. Used by COLR variable/transform fields.
pub fn readFixed(data: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(@as(i32, @bitCast(readU32(data, off))))) / 65536.0;
}

// ============================================================================
// CPAL — color palette table
// ============================================================================

/// A parsed CPAL table exposing palette-entry colors for palette 0.
pub const Cpal = struct {
    data: []const u8,
    /// Byte offset of the color-records array within `data`.
    color_records_offset: usize,
    /// Index into the color-records array of palette 0's first entry.
    first_color_index: usize,
    num_palette_entries: u16,
    num_color_records: u16,

    /// Palette index sentinel meaning "use the current foreground color".
    pub const foreground_index: u16 = 0xFFFF;

    pub fn parse(data: []const u8) !Cpal {
        if (data.len < 12) return error.InvalidCpal;
        // version (u16) at 0
        const num_palette_entries = readU16(data, 2);
        const num_palettes = readU16(data, 4);
        const num_color_records = readU16(data, 6);
        const color_records_offset = readU32(data, 8);
        if (num_palettes == 0) return error.InvalidCpal;
        // colorRecordIndices[numPalettes] starts at offset 12; palette 0 first.
        const first_color_index = readU16(data, 12);
        if (color_records_offset == 0 or color_records_offset > data.len) return error.InvalidCpal;
        return .{
            .data = data,
            .color_records_offset = color_records_offset,
            .first_color_index = first_color_index,
            .num_palette_entries = num_palette_entries,
            .num_color_records = num_color_records,
        };
    }

    /// Return the color for a COLR palette entry index in palette 0. Returns
    /// null for the foreground sentinel (0xFFFF) so the caller can substitute
    /// the text color. Alpha (0..255) is returned separately.
    pub fn color(self: Cpal, palette_index: u16) ?struct { c: Color, alpha: u8 } {
        if (palette_index == foreground_index) return null;
        const rec = self.first_color_index + palette_index;
        if (rec >= self.num_color_records) return .{ .c = Color.black, .alpha = 255 };
        const off = self.color_records_offset + rec * 4;
        // Color records are stored BGRA.
        const b = readU8(self.data, off);
        const g = readU8(self.data, off + 1);
        const r = readU8(self.data, off + 2);
        const a = readU8(self.data, off + 3);
        return .{ .c = Color.rgb(r, g, b), .alpha = a };
    }
};

// ============================================================================
// glyf outline extraction → PDF path operators (font units / glyph space)
// ============================================================================

/// 2x3 affine transform: maps (x, y) → (a*x + c*y + e, b*x + d*y + f).
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Transform = .{};

    pub fn apply(t: Transform, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{ .x = t.a * x + t.c * y + t.e, .y = t.b * x + t.d * y + t.f };
    }

    /// Returns `self ∘ other` (apply `other` first, then `self`).
    pub fn concat(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }

    pub fn translate(tx: f64, ty: f64) Transform {
        return .{ .e = tx, .f = ty };
    }

    pub fn scale(sx: f64, sy: f64) Transform {
        return .{ .a = sx, .d = sy };
    }
};

const Pt = struct { x: f64, y: f64, on: bool };

/// Tables needed for glyf outline extraction.
pub const GlyfContext = struct {
    glyf: []const u8,
    loca: []const u8,
    loca_format: i16,

    fn glyphSlice(self: GlyfContext, gid: u16) ?[]const u8 {
        const start = getLocaOffset(self.loca, gid, self.loca_format);
        const end = getLocaOffset(self.loca, gid + 1, self.loca_format);
        if (end <= start or end > self.glyf.len) return null;
        return self.glyf[start..end];
    }
};

fn getLocaOffset(loca: []const u8, gid: u16, fmt: i16) usize {
    if (fmt == 0) {
        const off = @as(usize, gid) * 2;
        if (off + 2 > loca.len) return 0;
        return @as(usize, readU16(loca, off)) * 2;
    } else {
        const off = @as(usize, gid) * 4;
        if (off + 4 > loca.len) return 0;
        return readU32(loca, off);
    }
}

/// Append a glyph's contours (transformed) to `out`. Recurses for composite
/// glyphs. Contours are stored as slices of Pt owned by `arena`.
fn collectContours(
    arena: std.mem.Allocator,
    ctx: GlyfContext,
    gid: u16,
    xf: Transform,
    depth: u8,
    out: *std.ArrayListUnmanaged([]Pt),
) std.mem.Allocator.Error!void {
    if (depth > 8) return; // guard against cyclic composites
    const g = ctx.glyphSlice(gid) orelse return; // empty glyph (e.g. space)
    if (g.len < 10) return;
    const num_contours = readI16(g, 0);
    if (num_contours < 0) {
        try collectComposite(arena, ctx, g, xf, depth, out);
        return;
    }
    const nc: usize = @intCast(num_contours);
    if (nc == 0) return;

    // endPtsOfContours
    var pos: usize = 10;
    const end_pts = try arena.alloc(u16, nc);
    for (0..nc) |i| {
        end_pts[i] = readU16(g, pos);
        pos += 2;
    }
    const num_points: usize = @as(usize, end_pts[nc - 1]) + 1;

    // Skip instructions
    const instr_len = readU16(g, pos);
    pos += 2 + instr_len;

    // Read flags (with repeat)
    const flags = try arena.alloc(u8, num_points);
    var i: usize = 0;
    while (i < num_points) {
        const fl = readU8(g, pos);
        pos += 1;
        flags[i] = fl;
        i += 1;
        if (fl & 0x08 != 0) { // REPEAT_FLAG
            var rep = readU8(g, pos);
            pos += 1;
            while (rep > 0 and i < num_points) : (rep -= 1) {
                flags[i] = fl;
                i += 1;
            }
        }
    }

    // Read X coordinates (delta encoded)
    const xs = try arena.alloc(f64, num_points);
    var x: i32 = 0;
    for (0..num_points) |k| {
        const fl = flags[k];
        if (fl & 0x02 != 0) { // X_SHORT_VECTOR
            const dx = readU8(g, pos);
            pos += 1;
            x += if (fl & 0x10 != 0) @as(i32, dx) else -@as(i32, dx);
        } else if (fl & 0x10 == 0) { // not X_IS_SAME
            x += readI16(g, pos);
            pos += 2;
        }
        xs[k] = @floatFromInt(x);
    }

    // Read Y coordinates (delta encoded)
    const ys = try arena.alloc(f64, num_points);
    var y: i32 = 0;
    for (0..num_points) |k| {
        const fl = flags[k];
        if (fl & 0x04 != 0) { // Y_SHORT_VECTOR
            const dy = readU8(g, pos);
            pos += 1;
            y += if (fl & 0x20 != 0) @as(i32, dy) else -@as(i32, dy);
        } else if (fl & 0x20 == 0) { // not Y_IS_SAME
            y += readI16(g, pos);
            pos += 2;
        }
        ys[k] = @floatFromInt(y);
    }

    // Split into contours, applying the transform.
    var start: usize = 0;
    for (0..nc) |ci| {
        const end: usize = @as(usize, end_pts[ci]) + 1;
        if (end <= start or end > num_points) {
            start = end;
            continue;
        }
        const pts = try arena.alloc(Pt, end - start);
        for (start..end) |k| {
            const p = xf.apply(xs[k], ys[k]);
            pts[k - start] = .{ .x = p.x, .y = p.y, .on = (flags[k] & 0x01) != 0 };
        }
        try out.append(arena, pts);
        start = end;
    }
}

fn collectComposite(
    arena: std.mem.Allocator,
    ctx: GlyfContext,
    g: []const u8,
    xf: Transform,
    depth: u8,
    out: *std.ArrayListUnmanaged([]Pt),
) std.mem.Allocator.Error!void {
    var pos: usize = 10;
    while (true) {
        const flags = readU16(g, pos);
        const comp_gid = readU16(g, pos + 2);
        pos += 4;

        var dx: f64 = 0;
        var dy: f64 = 0;
        if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
            if (flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                dx = @floatFromInt(readI16(g, pos));
                dy = @floatFromInt(readI16(g, pos + 2));
            }
            pos += 4;
        } else {
            if (flags & 0x0002 != 0) {
                dx = @floatFromInt(@as(i8, @bitCast(readU8(g, pos))));
                dy = @floatFromInt(@as(i8, @bitCast(readU8(g, pos + 1))));
            }
            pos += 2;
        }

        var comp = Transform.translate(dx, dy);
        if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
            const s = readF2Dot14(g, pos);
            pos += 2;
            comp.a = s;
            comp.d = s;
        } else if (flags & 0x0040 != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
            comp.a = readF2Dot14(g, pos);
            comp.d = readF2Dot14(g, pos + 2);
            pos += 4;
        } else if (flags & 0x0080 != 0) { // WE_HAVE_A_TWO_BY_TWO
            comp.a = readF2Dot14(g, pos);
            comp.b = readF2Dot14(g, pos + 2);
            comp.c = readF2Dot14(g, pos + 4);
            comp.d = readF2Dot14(g, pos + 6);
            pos += 8;
        }

        try collectContours(arena, ctx, comp_gid, xf.concat(comp), depth + 1, out);

        if (flags & 0x0020 == 0) break; // no MORE_COMPONENTS
    }
}

/// Emit PDF path operators (m/l/c/h) for a glyph outline in glyph space
/// (font units), transformed by `xf`. Does not emit a paint operator; the
/// caller adds `f`, `W n`, etc. Uses `arena` for scratch allocations.
pub fn writeGlyphOutline(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    ctx: GlyfContext,
    gid: u16,
    xf: Transform,
) !void {
    var contours: std.ArrayListUnmanaged([]Pt) = .empty;
    try collectContours(arena, ctx, gid, xf, 0, &contours);
    for (contours.items) |pts| {
        try writeContour(w, pts);
    }
}

fn writeContour(w: *std.Io.Writer, pts: []const Pt) !void {
    if (pts.len == 0) return;

    // Find the first on-curve point to start from.
    var start_idx: ?usize = null;
    for (pts, 0..) |p, i| {
        if (p.on) {
            start_idx = i;
            break;
        }
    }

    var cur: Pt = undefined;
    if (start_idx) |si| {
        cur = pts[si];
        try moveTo(w, cur);
        try walkFrom(w, pts, si, cur);
    } else {
        // All off-curve: synthesize an on-curve start at the midpoint of the
        // last and first control points.
        const mid = Pt{ .x = (pts[pts.len - 1].x + pts[0].x) / 2, .y = (pts[pts.len - 1].y + pts[0].y) / 2, .on = true };
        cur = mid;
        try moveTo(w, cur);
        // Walk starting "before" index 0 with the synthetic point as current.
        try walkAllOff(w, pts, mid);
    }
    try w.writeAll("h\n");
}

/// Walk a contour that has at least one on-curve point, starting at `si`.
fn walkFrom(w: *std.Io.Writer, pts: []const Pt, si: usize, start: Pt) !void {
    var cur = start;
    var pending_off: ?Pt = null;
    var step: usize = 1;
    while (step <= pts.len) : (step += 1) {
        const idx = (si + step) % pts.len;
        const p = if (step == pts.len) start else pts[idx];
        if (p.on) {
            if (pending_off) |q| {
                try quadTo(w, cur, q, p);
                pending_off = null;
            } else {
                try lineTo(w, p);
            }
            cur = p;
        } else {
            if (pending_off) |q| {
                const mid = Pt{ .x = (q.x + p.x) / 2, .y = (q.y + p.y) / 2, .on = true };
                try quadTo(w, cur, q, mid);
                cur = mid;
            }
            pending_off = p;
        }
    }
    // If a control point is still pending at the end, close with a quad to start.
    if (pending_off) |q| {
        try quadTo(w, cur, q, start);
    }
}

/// Walk a contour that is entirely off-curve, with a synthesized start point.
fn walkAllOff(w: *std.Io.Writer, pts: []const Pt, start: Pt) !void {
    var cur = start;
    var pending_off: ?Pt = null;
    var step: usize = 0;
    while (step <= pts.len) : (step += 1) {
        const p = if (step == pts.len) start else pts[step % pts.len];
        if (p.on) {
            if (pending_off) |q| {
                try quadTo(w, cur, q, p);
                pending_off = null;
            } else {
                try lineTo(w, p);
            }
            cur = p;
        } else {
            if (pending_off) |q| {
                const mid = Pt{ .x = (q.x + p.x) / 2, .y = (q.y + p.y) / 2, .on = true };
                try quadTo(w, cur, q, mid);
                cur = mid;
            }
            pending_off = p;
        }
    }
    if (pending_off) |q| {
        try quadTo(w, cur, q, start);
    }
}

fn moveTo(w: *std.Io.Writer, p: Pt) !void {
    var buf: [64]u8 = undefined;
    const n = format.writeCoord2Suffix(&buf, p.x, p.y, " m\n");
    try w.writeAll(buf[0..n]);
}

fn lineTo(w: *std.Io.Writer, p: Pt) !void {
    var buf: [64]u8 = undefined;
    const n = format.writeCoord2Suffix(&buf, p.x, p.y, " l\n");
    try w.writeAll(buf[0..n]);
}

/// Convert a quadratic segment (P0=cur, control Q, end P) to a cubic and emit.
fn quadTo(w: *std.Io.Writer, p0: Pt, q: Pt, p: Pt) !void {
    const c1x = p0.x + 2.0 / 3.0 * (q.x - p0.x);
    const c1y = p0.y + 2.0 / 3.0 * (q.y - p0.y);
    const c2x = p.x + 2.0 / 3.0 * (q.x - p.x);
    const c2y = p.y + 2.0 / 3.0 * (q.y - p.y);
    var buf: [160]u8 = undefined;
    const n = format.writeCubic(&buf, c1x, c1y, c2x, c2y, p.x, p.y);
    try w.writeAll(buf[0..n]);
}

// ============================================================================
// COLR (version 1) — color-glyph paint graph
// ============================================================================

/// Paint table format identifiers (COLR v1). Odd-numbered "Var" variants share
/// the geometric layout of the preceding format plus a trailing VarIndexBase we
/// ignore (no variation instancing).
pub const PaintFormat = enum(u8) {
    colr_layers = 1,
    solid = 2,
    var_solid = 3,
    linear_gradient = 4,
    var_linear_gradient = 5,
    radial_gradient = 6,
    var_radial_gradient = 7,
    sweep_gradient = 8,
    var_sweep_gradient = 9,
    glyph = 10,
    colr_glyph = 11,
    transform = 12,
    var_transform = 13,
    translate = 14,
    var_translate = 15,
    scale = 16,
    var_scale = 17,
    scale_around_center = 18,
    var_scale_around_center = 19,
    scale_uniform = 20,
    var_scale_uniform = 21,
    scale_uniform_around_center = 22,
    var_scale_uniform_around_center = 23,
    rotate = 24,
    var_rotate = 25,
    rotate_around_center = 26,
    var_rotate_around_center = 27,
    skew = 28,
    var_skew = 29,
    skew_around_center = 30,
    var_skew_around_center = 31,
    composite = 32,
    _,
};

/// A single gradient color stop resolved to an RGB color + alpha.
pub const GradientStop = struct {
    offset: f64,
    color: Color,
    alpha: f64,
};

/// Extend mode for a COLR color line.
pub const Extend = enum(u8) { pad = 0, repeat = 1, reflect = 2, _ };

/// Lazy accessor over a COLR version-1 table. Offsets are absolute within
/// `data` (the whole COLR table).
pub const Colr = struct {
    data: []const u8,
    base_glyph_list: usize, // absolute offset, 0 if absent
    layer_list: usize, // absolute offset, 0 if absent
    num_base_records: u32,
    num_layers: u32,

    pub fn parse(data: []const u8) !Colr {
        if (data.len < 14) return error.InvalidColr;
        const version = readU16(data, 0);
        if (version < 1) return error.UnsupportedColrVersion;
        // v1 fields begin after the v0 header (14 bytes).
        const base_glyph_list_off = readU32(data, 14);
        const layer_list_off = readU32(data, 18);

        var base_glyph_list: usize = 0;
        var num_base_records: u32 = 0;
        if (base_glyph_list_off != 0 and base_glyph_list_off < data.len) {
            base_glyph_list = base_glyph_list_off;
            num_base_records = readU32(data, base_glyph_list);
        }
        var layer_list: usize = 0;
        var num_layers: u32 = 0;
        if (layer_list_off != 0 and layer_list_off < data.len) {
            layer_list = layer_list_off;
            num_layers = readU32(data, layer_list);
        }
        return .{
            .data = data,
            .base_glyph_list = base_glyph_list,
            .layer_list = layer_list,
            .num_base_records = num_base_records,
            .num_layers = num_layers,
        };
    }

    /// Absolute offset of the root Paint for a base glyph, or null if the glyph
    /// has no v1 color record. Records are sorted by glyph id (binary search).
    pub fn baseGlyphPaint(self: Colr, gid: u16) ?usize {
        if (self.base_glyph_list == 0 or self.num_base_records == 0) return null;
        const records = self.base_glyph_list + 4; // after numBaseGlyphPaintRecords
        var lo: u32 = 0;
        var hi: u32 = self.num_base_records;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = records + mid * 6;
            const rec_gid = readU16(self.data, rec);
            if (rec_gid == gid) {
                const paint_off = readU32(self.data, rec + 2);
                return self.base_glyph_list + paint_off;
            } else if (rec_gid < gid) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    /// Absolute offset of the Paint for a LayerList entry.
    pub fn layerPaint(self: Colr, index: u32) ?usize {
        if (self.layer_list == 0 or index >= self.num_layers) return null;
        const paint_off = readU32(self.data, self.layer_list + 4 + index * 4);
        return self.layer_list + paint_off;
    }

    /// Format byte of the Paint at an absolute offset.
    pub fn paintFormat(self: Colr, abs: usize) PaintFormat {
        return @enumFromInt(readU8(self.data, abs));
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "CPAL parse and palette lookup (Noto Color Emoji)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;
    const cpal_data = font.getTable("CPAL".*) orelse return error.SkipZigTest;

    const cpal = try Cpal.parse(cpal_data);
    // Ground truth from fontTools: palette[4406] = (228, 234, 238, 255).
    const entry = cpal.color(4406).?;
    try testing.expectEqual(@as(u8, 255), entry.alpha);
    const rgbf = entry.c.toRgbf();
    try testing.expectApproxEqAbs(@as(f64, 228.0 / 255.0), rgbf.r, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 234.0 / 255.0), rgbf.g, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 238.0 / 255.0), rgbf.b, 0.01);

    // Foreground sentinel returns null.
    try testing.expect(cpal.color(Cpal.foreground_index) == null);
}

test "COLR v1 paint graph walk (Noto cloud glyph 3950)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;
    const colr_data = font.getTable("COLR".*) orelse return error.SkipZigTest;

    const colr = try Colr.parse(colr_data);
    try testing.expect(colr.base_glyph_list != 0);
    try testing.expect(colr.layer_list != 0);

    // Base glyph 3950 (uni2601 cloud) → PaintColrLayers.
    const root = colr.baseGlyphPaint(3950) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PaintFormat.colr_layers, colr.paintFormat(root));

    // PaintColrLayers: format(u8), numLayers(u8), firstLayerIndex(u32).
    const num_layers = readU8(colr.data, root + 1);
    const first_layer = readU32(colr.data, root + 2);
    try testing.expectEqual(@as(u8, 2), num_layers);
    try testing.expectEqual(@as(u32, 75206), first_layer);

    // Layer 0: PaintGlyph → PaintSolid(palette 4406).
    const l0 = colr.layerPaint(first_layer).?;
    try testing.expectEqual(PaintFormat.glyph, colr.paintFormat(l0));
    // PaintGlyph: format(u8), paintOffset(Offset24), glyphID(u16).
    const l0_child = l0 + readU24(colr.data, l0 + 1);
    const l0_gid = readU16(colr.data, l0 + 4);
    try testing.expectEqual(@as(u16, 23929), l0_gid);
    try testing.expectEqual(PaintFormat.solid, colr.paintFormat(l0_child));
    try testing.expectEqual(@as(u16, 4406), readU16(colr.data, l0_child + 1));

    // Layer 1: PaintGlyph(23930) → PaintSolid(palette 3420).
    const l1 = colr.layerPaint(first_layer + 1).?;
    try testing.expectEqual(@as(u16, 23930), readU16(colr.data, l1 + 4));
    const l1_child = l1 + readU24(colr.data, l1 + 1);
    try testing.expectEqual(@as(u16, 3420), readU16(colr.data, l1_child + 1));
}

test "glyf outline extraction (Noto cloud layer glyph 23929)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;
    const head = font.head.?;
    const ctx = GlyfContext{
        .glyf = font.getTable("glyf".*).?,
        .loca = font.getTable("loca".*).?,
        .loca_format = head.index_to_loc_format,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeGlyphOutline(&aw.writer, arena, ctx, 23929, Transform.identity);
    const out = aw.writer.buffered();

    // Ground truth: single contour starting on-curve at (257, 366).
    try testing.expect(std.mem.indexOf(u8, out, "257.00 366.00 m") != null);
    // Exactly one subpath (one moveTo) and it closes.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, " m\n"));
    try testing.expect(std.mem.endsWith(u8, out, "h\n"));
    // Contains cubic segments (quads converted to cubics).
    try testing.expect(std.mem.indexOf(u8, out, " c\n") != null);
}
