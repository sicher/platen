//! COLR v0/v1 / CPAL color font support.
//!
//! Parses the CPAL palette table and the COLR color-glyph data (both the v1
//! paint graph and the v0 layer records), and extracts `glyf` outlines as PDF
//! path operators. Higher layers turn a base color glyph into a PDF Type3
//! CharProc (see the paint interpreter and Type3 emitter).
//!
//! Scope: COLR v0 (flat solid-color layer records) and COLR v1 with glyf
//! (TrueType) outlines. The supported v1 paint formats are ColrLayers, Solid,
//! Linear/Radial/Sweep gradients (sweep approximated as a wedge fan — PDF has
//! no conic shading), Glyph (clip), ColrGlyph, the affine transform family,
//! and Composite. CFF-flavored color fonts are not supported.

const std = @import("std");
const format = @import("format.zig");
const color = @import("color.zig");

pub const Color = color.Color;

// ============================================================================
// Big-endian readers (bounds-checked; shared via binary.zig)
// ============================================================================

const binary = @import("binary.zig");
pub const readU8 = binary.readU8;
pub const readU16 = binary.readU16;
pub const readI16 = binary.readI16;
pub const readU24 = binary.readU24;
pub const readU32 = binary.readU32;
pub const readF2Dot14 = binary.readF2Dot14;
pub const readFixed = binary.readFixed;

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
        const end = getLocaOffset(self.loca, @as(usize, gid) + 1, self.loca_format);
        if (end <= start or end > self.glyf.len) return null;
        return self.glyf[start..end];
    }
};

fn getLocaOffset(loca: []const u8, gid: usize, fmt: i16) usize {
    if (fmt == 0) {
        const off = gid * 2;
        if (off + 2 > loca.len) return 0;
        return @as(usize, readU16(loca, off)) * 2;
    } else {
        const off = gid * 4;
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
    const instr_len: usize = readU16(g, pos);
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

/// Shared TrueType-contour segment emitter: feed points in order; an
/// on-curve point emits a line (or resolves a pending control point into a
/// quadratic), consecutive off-curve points get an implied on-curve
/// midpoint. Closing a contour is just feeding its (on-curve) start point.
const SegEmitter = struct {
    w: *std.Io.Writer,
    cur: Pt,
    pending_off: ?Pt = null,

    fn feed(self: *SegEmitter, p: Pt) !void {
        if (p.on) {
            if (self.pending_off) |q| {
                try quadTo(self.w, self.cur, q, p);
                self.pending_off = null;
            } else {
                try lineTo(self.w, p);
            }
            self.cur = p;
        } else {
            if (self.pending_off) |q| {
                const mid = Pt{ .x = (q.x + p.x) / 2, .y = (q.y + p.y) / 2, .on = true };
                try quadTo(self.w, self.cur, q, mid);
                self.cur = mid;
            }
            self.pending_off = p;
        }
    }
};

/// Walk a contour that has at least one on-curve point, starting at `si`.
fn walkFrom(w: *std.Io.Writer, pts: []const Pt, si: usize, start: Pt) !void {
    var e = SegEmitter{ .w = w, .cur = start };
    var step: usize = 1;
    while (step < pts.len) : (step += 1) {
        try e.feed(pts[(si + step) % pts.len]);
    }
    try e.feed(start); // close: resolves a pending control into the final quad
}

/// Walk a contour that is entirely off-curve, with a synthesized start point.
fn walkAllOff(w: *std.Io.Writer, pts: []const Pt, start: Pt) !void {
    var e = SegEmitter{ .w = w, .cur = start };
    for (pts) |p| {
        try e.feed(p);
    }
    try e.feed(start); // close: resolves a pending control into the final quad
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

/// A gradient's color stops, sorted by offset, with each stop's alpha
/// (stop alpha × palette entry alpha) alongside.
const ColorLine = struct {
    stops: []gradient.ColorStop,
    alphas: []f64,

    /// The alpha shared by every stop, or null if it varies along the line.
    fn constantAlpha(self: ColorLine) ?f64 {
        for (self.alphas[1..]) |a| {
            if (@abs(a - self.alphas[0]) > 0.001) return null;
        }
        return self.alphas[0];
    }
};

/// Extend mode for a COLR color line.
pub const Extend = enum(u8) { pad = 0, repeat = 1, reflect = 2, _ };

/// Lazy accessor over a COLR version-1 table. Offsets are absolute within
/// `data` (the whole COLR table).
/// A COLR v0 base glyph: a contiguous run of layer records.
pub const BaseGlyphV0 = struct { first: u32, num: u32 };

/// One COLR v0 layer: an outline glyph filled with a palette color.
pub const LayerV0 = struct { gid: u16, palette: u16 };

pub const Colr = struct {
    data: []const u8,
    version: u16,
    // v0 layer records (present in both v0 and, optionally, v1 fonts).
    base_glyph_records: usize, // absolute offset, 0 if absent
    num_base_glyph_records: u16,
    layer_records: usize, // absolute offset, 0 if absent
    num_layer_records: u16,
    // v1 paint graph (0 for v0-only fonts).
    base_glyph_list: usize, // absolute offset, 0 if absent
    layer_list: usize, // absolute offset, 0 if absent
    num_base_records: u32,
    num_layers: u32,

    pub fn parse(data: []const u8) !Colr {
        if (data.len < 14) return error.InvalidColr;
        const version = readU16(data, 0);

        // v0 header (bytes 2..14): common to all versions. Record counts are
        // clamped to what fits in the table so malformed counts cannot drive
        // lookups (and their offset arithmetic) past the data.
        const base_glyph_records_off = readU32(data, 4);
        const layer_records_off = readU32(data, 8);
        const base_glyph_records: usize = if (base_glyph_records_off != 0 and base_glyph_records_off < data.len) base_glyph_records_off else 0;
        const layer_records: usize = if (layer_records_off != 0 and layer_records_off < data.len) layer_records_off else 0;
        const num_base_glyph_records: u16 = @intCast(@min(readU16(data, 2), (data.len - base_glyph_records) / 6));
        const num_layer_records: u16 = @intCast(@min(readU16(data, 12), (data.len - layer_records) / 4));

        // v1 fields begin after the v0 header (14 bytes).
        var base_glyph_list: usize = 0;
        var num_base_records: u32 = 0;
        var layer_list: usize = 0;
        var num_layers: u32 = 0;
        if (version >= 1) {
            if (data.len < 22) return error.InvalidColr;
            const base_glyph_list_off = readU32(data, 14);
            const layer_list_off = readU32(data, 18);
            if (base_glyph_list_off != 0 and base_glyph_list_off < data.len) {
                base_glyph_list = base_glyph_list_off;
                num_base_records = @intCast(@min(readU32(data, base_glyph_list), ((data.len - base_glyph_list) -| 4) / 6));
            }
            if (layer_list_off != 0 and layer_list_off < data.len) {
                layer_list = layer_list_off;
                num_layers = @intCast(@min(readU32(data, layer_list), ((data.len - layer_list) -| 4) / 4));
            }
        }
        return .{
            .data = data,
            .version = version,
            .base_glyph_records = base_glyph_records,
            .num_base_glyph_records = num_base_glyph_records,
            .layer_records = layer_records,
            .num_layer_records = num_layer_records,
            .base_glyph_list = base_glyph_list,
            .layer_list = layer_list,
            .num_base_records = num_base_records,
            .num_layers = num_layers,
        };
    }

    /// True if `gid` has color layers in either the v1 paint graph or the v0
    /// layer records.
    pub fn isColorGlyph(self: Colr, gid: u16) bool {
        return self.baseGlyphPaint(gid) != null or self.v0BaseGlyph(gid) != null;
    }

    /// The COLR v0 layer run for `gid`, or null. Records are 6 bytes
    /// (glyphID, firstLayerIndex, numLayers) sorted by glyphID (binary search).
    pub fn v0BaseGlyph(self: Colr, gid: u16) ?BaseGlyphV0 {
        if (self.base_glyph_records == 0 or self.num_base_glyph_records == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.num_base_glyph_records;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = self.base_glyph_records + mid * 6;
            const rec_gid = readU16(self.data, rec);
            if (rec_gid == gid) {
                return .{ .first = readU16(self.data, rec + 2), .num = readU16(self.data, rec + 4) };
            } else if (rec_gid < gid) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    /// A COLR v0 layer record (4 bytes: glyphID, paletteIndex).
    pub fn v0Layer(self: Colr, index: u32) ?LayerV0 {
        if (self.layer_records == 0 or index >= self.num_layer_records) return null;
        const rec = self.layer_records + index * 4;
        return .{ .gid = readU16(self.data, rec), .palette = readU16(self.data, rec + 2) };
    }

    /// Absolute offset of the root Paint for a base glyph, or null if the glyph
    /// has no v1 color record. Records are sorted by glyph id (binary search).
    pub fn baseGlyphPaint(self: Colr, gid: u16) ?usize {
        if (self.base_glyph_list == 0 or self.num_base_records == 0) return null;
        const records = self.base_glyph_list + 4; // after numBaseGlyphPaintRecords
        var lo: usize = 0;
        var hi: usize = self.num_base_records;
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
    pub fn layerPaint(self: Colr, index: usize) ?usize {
        if (self.layer_list == 0 or index >= self.num_layers) return null;
        const paint_off = readU32(self.data, self.layer_list + 4 + index * 4);
        return self.layer_list + paint_off;
    }

    /// Format byte of the Paint at an absolute offset.
    pub fn paintFormat(self: Colr, abs: usize) PaintFormat {
        return @fromBackingInt(@intCast(readU8(self.data, abs)));
    }
};

// ============================================================================
// Paint interpreter → PDF content operators
// ============================================================================

const gradient = @import("gradient.zig");

/// Accumulates the Shading and ExtGState resources referenced by the color
/// glyphs' CharProcs. These become the Type3 font's /Resources. Dict strings
/// are owned by this struct's allocator.
pub const ColorResources = struct {
    allocator: std.mem.Allocator,
    shadings: std.ArrayListUnmanaged([]u8) = .empty,
    ext_gstates: std.ArrayListUnmanaged([]u8) = .empty,
    /// Gray shading dicts of luminosity soft masks (gradient stop alpha).
    /// Each becomes a transparency-group form XObject, set by an ExtGState
    /// named "Gm{index+1}" (color_fonts.zig writes both).
    soft_masks: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ColorResources {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ColorResources) void {
        for (self.shadings.items) |s| self.allocator.free(s);
        for (self.ext_gstates.items) |s| self.allocator.free(s);
        for (self.soft_masks.items) |s| self.allocator.free(s);
        self.shadings.deinit(self.allocator);
        self.ext_gstates.deinit(self.allocator);
        self.soft_masks.deinit(self.allocator);
    }

    /// Register a shading dict body (owned copy taken). Returns 0-based index;
    /// resource name is "Sh{index+1}".
    fn addShading(self: *ColorResources, dict: []const u8) !usize {
        const owned = try self.allocator.dupe(u8, dict);
        try self.shadings.append(self.allocator, owned);
        return self.shadings.items.len - 1;
    }

    /// Register an ExtGState dict body (owned copy taken). Returns 0-based
    /// index; resource name is "Ga{index+1}". An identical dict already
    /// registered is reused (alphas repeat across glyphs and sweep wedges).
    fn addExtGState(self: *ColorResources, dict: []const u8) !usize {
        for (self.ext_gstates.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, dict)) return i;
        }
        const owned = try self.allocator.dupe(u8, dict);
        try self.ext_gstates.append(self.allocator, owned);
        return self.ext_gstates.items.len - 1;
    }

    /// Register a soft mask's gray shading dict body (owned copy taken).
    /// Returns 0-based index; the ExtGState setting it is "Gm{index+1}".
    fn addSoftMask(self: *ColorResources, dict: []const u8) !usize {
        const owned = try self.allocator.dupe(u8, dict);
        try self.soft_masks.append(self.allocator, owned);
        return self.soft_masks.items.len - 1;
    }
};

/// Interprets a COLR v1 base glyph and emits PDF drawing operators into `w`,
/// in glyph space (font units, y-up). The caller wraps the output with the
/// Type3 CharProc prologue (`wx 0 d0`) and FontMatrix.
pub const PaintInterp = struct {
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    colr: Colr,
    cpal: Cpal,
    glyf: GlyfContext,
    res: *ColorResources,
    /// Foreground color substituted for palette index 0xFFFF.
    fg: Color = Color.black,
    /// Constant alpha inherited from an enclosing composite approximation
    /// (see renderMasked); multiplied into every solid fill's alpha.
    alpha_scale: f64 = 1.0,
    /// Number of enclosing PaintGlyph clips. Unbounded fills (solids,
    /// gradients) are skipped at depth 0 — with no clip they would cover the
    /// entire page (COLR ClipBox bounds are not implemented).
    clip_depth: u8 = 0,
    /// Remaining paint visits for the current render() call. The depth limit
    /// alone does not bound work: a malformed graph whose layers point back
    /// at ColrLayers/ColrGlyph nodes expands combinatorially within it.
    ops_budget: usize = max_paint_ops,

    /// Far beyond any real glyph's paint count (typically dozens).
    const max_paint_ops = 65536;

    /// Large cover rectangle (font units) used to fill the current clip for
    /// solid paints reached outside the fast PaintGlyph→Solid path.
    const cover_rect = "-32768 -32768 65536 65536 re\n";

    /// Explicit error set for the mutually-recursive paint methods (breaks the
    /// inferred-error-set dependency loop).
    const Error = std.Io.Writer.Error || std.mem.Allocator.Error || error{InvalidGradient};

    pub fn render(self: *PaintInterp, base_gid: u16) !void {
        self.ops_budget = max_paint_ops;
        // Prefer the v1 paint graph; fall back to v0 layer records.
        if (self.colr.baseGlyphPaint(base_gid)) |root| {
            try self.renderPaint(root, 0);
        } else if (self.colr.v0BaseGlyph(base_gid)) |rec| {
            try self.renderV0(rec);
        } else {
            return error.NotAColorGlyph;
        }
    }

    fn renderPaint(self: *PaintInterp, abs: usize, depth: u8) Error!void {
        if (depth > 64) return;
        if (self.ops_budget == 0) return;
        self.ops_budget -= 1;
        switch (self.colr.paintFormat(abs)) {
            .colr_layers => {
                const n = readU8(self.colr.data, abs + 1);
                const first: usize = readU32(self.colr.data, abs + 2);
                for (0..n) |i| {
                    const lp = self.colr.layerPaint(first + i) orelse continue;
                    try self.renderPaint(lp, depth + 1);
                }
            },
            .solid, .var_solid => {
                // Fill the current clip region with the solid color.
                if (self.clip_depth == 0) return; // unbounded fill: skip
                try self.beginSolid(abs);
                try self.w.writeAll(cover_rect);
                try self.w.writeAll("f\n");
                try self.endSolid(abs);
            },
            .glyph => {
                try self.renderGlyphPaint(abs, depth);
            },
            .colr_glyph => {
                const gid = readU16(self.colr.data, abs + 1);
                const target = self.colr.baseGlyphPaint(gid) orelse return;
                try self.renderPaint(target, depth + 1);
            },
            .linear_gradient => try self.renderGradient(abs, false),
            .radial_gradient => try self.renderGradient(abs, true),
            .sweep_gradient, .var_sweep_gradient => try self.renderSweep(abs),
            .transform, .var_transform => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const xf_off = abs + readU24(self.colr.data, abs + 4);
                const m = self.readAffine(xf_off);
                try self.withTransform(m, abs + paint_off, depth);
            },
            .translate, .var_translate => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const dx: f64 = @floatFromInt(readI16(self.colr.data, abs + 4));
                const dy: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
                try self.withTransform(Transform.translate(dx, dy), abs + paint_off, depth);
            },
            .scale, .var_scale => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const sx = readF2Dot14(self.colr.data, abs + 4);
                const sy = readF2Dot14(self.colr.data, abs + 6);
                try self.withTransform(Transform.scale(sx, sy), abs + paint_off, depth);
            },
            .scale_around_center, .var_scale_around_center => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const sx = readF2Dot14(self.colr.data, abs + 4);
                const sy = readF2Dot14(self.colr.data, abs + 6);
                const cx: f64 = @floatFromInt(readI16(self.colr.data, abs + 8));
                const cy: f64 = @floatFromInt(readI16(self.colr.data, abs + 10));
                try self.withTransform(aroundCenter(Transform.scale(sx, sy), cx, cy), abs + paint_off, depth);
            },
            .scale_uniform, .var_scale_uniform => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const s = readF2Dot14(self.colr.data, abs + 4);
                try self.withTransform(Transform.scale(s, s), abs + paint_off, depth);
            },
            .scale_uniform_around_center, .var_scale_uniform_around_center => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const s = readF2Dot14(self.colr.data, abs + 4);
                const cx: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
                const cy: f64 = @floatFromInt(readI16(self.colr.data, abs + 8));
                try self.withTransform(aroundCenter(Transform.scale(s, s), cx, cy), abs + paint_off, depth);
            },
            .rotate, .var_rotate => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const ang = readF2Dot14(self.colr.data, abs + 4) * std.math.pi; // *180deg → rad
                try self.withTransform(rotation(ang), abs + paint_off, depth);
            },
            .rotate_around_center, .var_rotate_around_center => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const ang = readF2Dot14(self.colr.data, abs + 4) * std.math.pi;
                const cx: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
                const cy: f64 = @floatFromInt(readI16(self.colr.data, abs + 8));
                try self.withTransform(aroundCenter(rotation(ang), cx, cy), abs + paint_off, depth);
            },
            .skew, .var_skew => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const xs = readF2Dot14(self.colr.data, abs + 4) * std.math.pi;
                const ys = readF2Dot14(self.colr.data, abs + 6) * std.math.pi;
                try self.withTransform(skew(xs, ys), abs + paint_off, depth);
            },
            .skew_around_center, .var_skew_around_center => {
                const paint_off = readU24(self.colr.data, abs + 1);
                const xs = readF2Dot14(self.colr.data, abs + 4) * std.math.pi;
                const ys = readF2Dot14(self.colr.data, abs + 6) * std.math.pi;
                const cx: f64 = @floatFromInt(readI16(self.colr.data, abs + 8));
                const cy: f64 = @floatFromInt(readI16(self.colr.data, abs + 10));
                try self.withTransform(aroundCenter(skew(xs, ys), cx, cy), abs + paint_off, depth);
            },
            .composite => {
                // format(u8), sourcePaintOffset(Offset24), compositeMode(u8),
                // backdropPaintOffset(Offset24).
                const src_off = abs + readU24(self.colr.data, abs + 1);
                const mode = readU8(self.colr.data, abs + 4);
                const back_off = abs + readU24(self.colr.data, abs + 5);
                switch (mode) {
                    0 => {}, // CLEAR: nothing visible
                    1 => try self.renderPaint(src_off, depth + 1), // SRC
                    2 => try self.renderPaint(back_off, depth + 1), // DEST
                    4 => { // DEST_OVER: backdrop composites on top of source
                        try self.renderPaint(src_off, depth + 1);
                        try self.renderPaint(back_off, depth + 1);
                    },
                    // SRC_IN(5)/SRC_OUT(7): source masked by the backdrop's
                    // coverage; DEST_IN(6)/DEST_OUT(8) mirror the branches.
                    5 => try self.renderMasked(src_off, back_off, false, depth),
                    7 => try self.renderMasked(src_off, back_off, true, depth),
                    6 => try self.renderMasked(back_off, src_off, false, depth),
                    8 => try self.renderMasked(back_off, src_off, true, depth),
                    else => {
                        // Blend modes (13..27) get a PDF /BM ExtGState; the
                        // remaining Porter-Duff modes (ATOP/XOR/PLUS)
                        // approximate as plain source-over.
                        try self.renderPaint(back_off, depth + 1);
                        if (blendModeName(mode)) |bm| {
                            const dict = try std.fmt.allocPrint(self.arena, "<< /Type /ExtGState /BM /{s} >>", .{bm});
                            const idx = try self.res.addExtGState(dict);
                            try self.w.writeAll("q\n");
                            try self.w.print("/Ga{d} gs\n", .{idx + 1});
                            try self.renderPaint(src_off, depth + 1);
                            try self.w.writeAll("Q\n");
                        } else {
                            try self.renderPaint(src_off, depth + 1);
                        }
                    },
                }
            },
            else => {}, // unknown paint format: skip
        }
    }

    /// PaintGlyph: clip to the referenced glyph outline, then paint the child.
    /// Fast-paths the very common PaintGlyph→Solid as a direct filled outline.
    fn renderGlyphPaint(self: *PaintInterp, abs: usize, depth: u8) Error!void {
        const child = abs + readU24(self.colr.data, abs + 1);
        const gid = readU16(self.colr.data, abs + 4);
        const child_fmt = self.colr.paintFormat(child);

        if (child_fmt == .solid or child_fmt == .var_solid) {
            // Fill the outline directly with the solid color.
            try self.beginSolid(child);
            try writeGlyphOutline(self.w, self.arena, self.glyf, gid, Transform.identity);
            try self.w.writeAll("f\n");
            try self.endSolid(child);
            return;
        }

        // General case: set clip to the outline, then paint child into it.
        try self.w.writeAll("q\n");
        try writeGlyphOutline(self.w, self.arena, self.glyf, gid, Transform.identity);
        try self.w.writeAll("W n\n");
        self.clip_depth +|= 1;
        try self.renderPaint(child, depth + 1);
        self.clip_depth -= 1;
        try self.w.writeAll("Q\n");
    }

    /// Approximate a Porter-Duff IN/OUT composite: render `content` masked by
    /// `mask`'s coverage. A full-coverage solid mask reduces exactly to the
    /// content at the mask's alpha (1 - alpha for the OUT modes); any other
    /// mask shape drops the mask and renders the content as-is.
    fn renderMasked(self: *PaintInterp, content_off: usize, mask_off: usize, invert: bool, depth: u8) Error!void {
        var alpha: f64 = 1.0;
        if (self.solidPaintAlpha(mask_off)) |a| alpha = if (invert) 1.0 - a else a;
        if (alpha < 0.001) return;
        if (alpha >= 0.999) return self.renderPaint(content_off, depth + 1);

        // ExtGState /ca covers shading fills; alpha_scale folds the factor
        // into solid fills (whose own /ca would otherwise replace this one).
        const dict = try std.fmt.allocPrint(self.arena, "<< /Type /ExtGState /ca {d:.3} >>", .{alpha});
        const idx = try self.res.addExtGState(dict);
        try self.w.writeAll("q\n");
        try self.w.print("/Ga{d} gs\n", .{idx + 1});
        const saved = self.alpha_scale;
        self.alpha_scale = saved * alpha;
        defer self.alpha_scale = saved; // restore even on error
        try self.renderPaint(content_off, depth + 1);
        try self.w.writeAll("Q\n");
    }

    /// Total constant alpha of a solid paint (palette entry alpha × paint
    /// alpha), or null if the paint is not a PaintSolid.
    fn solidPaintAlpha(self: *PaintInterp, off: usize) ?f64 {
        switch (self.colr.paintFormat(off)) {
            .solid, .var_solid => {},
            else => return null,
        }
        const palette = readU16(self.colr.data, off + 1);
        const paint_alpha = readF2Dot14(self.colr.data, off + 3);
        const entry_alpha: f64 = if (self.cpal.color(palette)) |r| @as(f64, @floatFromInt(r.alpha)) / 255.0 else 1.0;
        return paint_alpha * entry_alpha;
    }

    /// Emit fill-color setup for a PaintSolid, wrapping in an alpha ExtGState if
    /// the paint's alpha is below 1. Must be paired with endSolid.
    fn beginSolid(self: *PaintInterp, solid_abs: usize) !void {
        try self.beginSolidColor(readU16(self.colr.data, solid_abs + 1), readF2Dot14(self.colr.data, solid_abs + 3));
    }

    fn endSolid(self: *PaintInterp, solid_abs: usize) !void {
        try self.endSolidColor(readU16(self.colr.data, solid_abs + 1), readF2Dot14(self.colr.data, solid_abs + 3));
    }

    /// Set the fill color for `palette_index` scaled by `paint_alpha` (1.0 for
    /// COLR v0 layers, which have no per-layer alpha), wrapping in an alpha
    /// ExtGState when the combined alpha is below 1. Pair with endSolidColor.
    fn beginSolidColor(self: *PaintInterp, palette_index: u16, paint_alpha: f64) !void {
        const resolved = self.cpal.color(palette_index);
        const c = if (resolved) |r| r.c else self.fg;
        const entry_alpha: f64 = if (resolved) |r| @as(f64, @floatFromInt(r.alpha)) / 255.0 else 1.0;
        const total_alpha = paint_alpha * entry_alpha * self.alpha_scale;

        if (total_alpha < 0.999) {
            var buf: [96]u8 = undefined;
            const dict = std.fmt.bufPrint(&buf, "<< /Type /ExtGState /ca {d:.3} >>", .{total_alpha}) catch unreachable;
            const idx = self.res.addExtGState(dict) catch 0;
            try self.w.writeAll("q\n");
            try self.w.print("/Ga{d} gs\n", .{idx + 1});
        }
        try c.writeFill(self.w);
    }

    fn endSolidColor(self: *PaintInterp, palette_index: u16, paint_alpha: f64) !void {
        const resolved = self.cpal.color(palette_index);
        const entry_alpha: f64 = if (resolved) |r| @as(f64, @floatFromInt(r.alpha)) / 255.0 else 1.0;
        if (paint_alpha * entry_alpha * self.alpha_scale < 0.999) try self.w.writeAll("Q\n");
    }

    /// Render a COLR v0 base glyph: a flat list of layers, each a glyph outline
    /// filled with a solid palette color (painted back-to-front).
    fn renderV0(self: *PaintInterp, rec: BaseGlyphV0) Error!void {
        var i: u32 = rec.first;
        const end = rec.first + rec.num;
        while (i < end) : (i += 1) {
            if (self.ops_budget == 0) return;
            self.ops_budget -= 1;
            const layer = self.colr.v0Layer(i) orelse continue;
            try self.beginSolidColor(layer.palette, 1.0);
            try writeGlyphOutline(self.w, self.arena, self.glyf, layer.gid, Transform.identity);
            try self.w.writeAll("f\n");
            try self.endSolidColor(layer.palette, 1.0);
        }
    }

    fn withTransform(self: *PaintInterp, m: Transform, child_abs: usize, depth: u8) Error!void {
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "q\n{d:.5} {d:.5} {d:.5} {d:.5} {d:.4} {d:.4} cm\n", .{ m.a, m.b, m.c, m.d, m.e, m.f }) catch unreachable;
        try self.w.writeAll(s);
        try self.renderPaint(child_abs, depth + 1);
        try self.w.writeAll("Q\n");
    }

    fn readAffine(self: *PaintInterp, off: usize) Transform {
        return .{
            .a = readFixed(self.colr.data, off),
            .b = readFixed(self.colr.data, off + 4),
            .c = readFixed(self.colr.data, off + 8),
            .d = readFixed(self.colr.data, off + 12),
            .e = readFixed(self.colr.data, off + 16),
            .f = readFixed(self.colr.data, off + 20),
        };
    }

    /// Render a linear or radial gradient, filling the current clip via `sh`.
    fn renderGradient(self: *PaintInterp, abs: usize, is_radial: bool) !void {
        if (self.clip_depth == 0) return; // unbounded fill: skip
        const color_line_abs = abs + readU24(self.colr.data, abs + 1);
        const line = try self.readColorLine(color_line_abs);
        if (line.stops.len < 2) return;

        // Geometry shared by the color shading and its soft mask
        var geometry: std.Io.Writer.Allocating = .init(self.arena);
        if (is_radial) {
            const x0: f64 = @floatFromInt(readI16(self.colr.data, abs + 4));
            const y0: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
            const r0: f64 = @floatFromInt(readU16(self.colr.data, abs + 8));
            const x1: f64 = @floatFromInt(readI16(self.colr.data, abs + 10));
            const y1: f64 = @floatFromInt(readI16(self.colr.data, abs + 12));
            const r1: f64 = @floatFromInt(readU16(self.colr.data, abs + 14));
            try geometry.writer.print("/ShadingType 3 /Coords [{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}] /Extend [true true]", .{ x0, y0, r0, x1, y1, r1 });
        } else {
            // Three-point form → two-point axial gradient. The iso-color lines
            // are parallel to (p2-p0); the axis runs from p0 to the projection
            // of p1 onto the perpendicular direction.
            const p0x: f64 = @floatFromInt(readI16(self.colr.data, abs + 4));
            const p0y: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
            const p1x: f64 = @floatFromInt(readI16(self.colr.data, abs + 8));
            const p1y: f64 = @floatFromInt(readI16(self.colr.data, abs + 10));
            const p2x: f64 = @floatFromInt(readI16(self.colr.data, abs + 12));
            const p2y: f64 = @floatFromInt(readI16(self.colr.data, abs + 14));
            const end = axialEndpoint(p0x, p0y, p1x, p1y, p2x, p2y);
            try geometry.writer.print("/ShadingType 2 /Coords [{d:.2} {d:.2} {d:.2} {d:.2}] /Extend [true true]", .{ p0x, p0y, end.x, end.y });
        }
        const geom = geometry.writer.buffered();

        // Stop alpha: a constant one is /ca (replacing, so it carries the
        // enclosing composite's alpha_scale); a varying one is a luminosity
        // soft mask drawing the same gradient in gray, which leaves the
        // enclosing /ca in place
        var mask: ?usize = null;
        var ca: ?usize = null;
        if (line.constantAlpha()) |a| {
            const total = a * self.alpha_scale;
            if (total < 0.001) return;
            if (total < 0.999) {
                const gs = try std.fmt.allocPrint(self.arena, "<< /Type /ExtGState /ca {d:.3} >>", .{total});
                ca = try self.res.addExtGState(gs);
            }
        } else {
            var m: std.Io.Writer.Allocating = .init(self.arena);
            try m.writer.print("<< {s} /ColorSpace /DeviceGray /Function ", .{geom});
            try gradient.writeChannelFunctionDict(line.stops, .{ .gray = line.alphas }, &m.writer);
            try m.writer.writeAll(" >>");
            mask = try self.res.addSoftMask(m.writer.buffered());
        }

        var dict: std.Io.Writer.Allocating = .init(self.arena);
        try dict.writer.print("<< {s} /ColorSpace /DeviceRGB /Function ", .{geom});
        try gradient.writeFunctionDict(line.stops, &dict.writer);
        try dict.writer.writeAll(" >>");
        const idx = try self.res.addShading(dict.writer.buffered());

        if (mask) |i| try self.w.print("q\n/Gm{d} gs\n", .{i + 1});
        if (ca) |i| try self.w.print("q\n/Ga{d} gs\n", .{i + 1});
        try self.w.print("/Sh{d} sh\n", .{idx + 1});
        if (mask != null or ca != null) try self.w.writeAll("Q\n");
    }

    /// Render a sweep (conic) gradient. PDF has no conic shading type, so
    /// approximate it with a fan of flat-colored wedges around the center;
    /// the current clip (from the enclosing PaintGlyph) bounds the visible
    /// part, exactly as for the `sh`-painted gradients.
    fn renderSweep(self: *PaintInterp, abs: usize) !void {
        if (self.clip_depth == 0) return; // unbounded fill: skip
        // PaintSweepGradient: format(u8), colorLineOffset(Offset24),
        // centerX/centerY(FWORD), startAngle/endAngle(F2Dot14, biased).
        const color_line_abs = abs + readU24(self.colr.data, abs + 1);
        const extend: Extend = @fromBackingInt(@intCast(readU8(self.colr.data, color_line_abs)));
        const line = try self.readColorLine(color_line_abs);
        if (line.stops.len < 2) return;

        const cx: f64 = @floatFromInt(readI16(self.colr.data, abs + 4));
        const cy: f64 = @floatFromInt(readI16(self.colr.data, abs + 6));
        // Angles are biased F2Dot14: degrees = (value + 1) × 180,
        // counter-clockwise from the positive x-axis.
        const start = (readF2Dot14(self.colr.data, abs + 8) + 1.0) * 180.0;
        const end = (readF2Dot14(self.colr.data, abs + 10) + 1.0) * 180.0;
        // Signed span: start > end inverts the color line (per spec). The
        // extend mode handles positions outside [0, 1].
        const span = end - start;
        if (@abs(span) < 1e-9) return;

        // The spec samples rays over the absolute angular domain [0°, 360°):
        // 120 wedges (3° each), each filled with the color line sampled at
        // its midpoint angle. Each wedge starts slightly inside its
        // predecessor so anti-aliasing of abutting fills leaves no seams.
        const wedges = 120;
        const overlap = 0.3; // degrees
        const radius = 65536.0; // covers any glyph bbox (matches cover_rect)
        const back = 4.0; // apex pushed past the center: no pinhole where the fan converges
        for (0..wedges) |i| {
            const a0 = 360.0 * @as(f64, @floatFromInt(i)) / wedges;
            const a1 = 360.0 * @as(f64, @floatFromInt(i + 1)) / wedges;
            const mid = (a0 + a1) / 2.0;
            const t = sweepExtendT((mid - start) / span, extend);
            const c = sampleColorLine(line.stops, t);
            // Each wedge is flat, so its alpha is a plain /ca
            const alpha = sampleValues(line.stops, line.alphas, t) * self.alpha_scale;
            if (alpha < 0.001) continue;
            const translucent = alpha < 0.999;
            if (translucent) {
                const gs = try std.fmt.allocPrint(self.arena, "<< /Type /ExtGState /ca {d:.3} >>", .{alpha});
                try self.w.print("q\n/Ga{d} gs\n", .{try self.res.addExtGState(gs) + 1});
            }
            try self.w.print("{d:.3} {d:.3} {d:.3} rg\n", .{ c.r, c.g, c.b });
            try self.w.print("{d:.2} {d:.2} m {d:.2} {d:.2} l {d:.2} {d:.2} l h f\n", .{
                cx - back * @cos(std.math.degreesToRadians(mid)),
                cy - back * @sin(std.math.degreesToRadians(mid)),
                cx + radius * @cos(std.math.degreesToRadians(a0 - overlap)),
                cy + radius * @sin(std.math.degreesToRadians(a0 - overlap)),
                cx + radius * @cos(std.math.degreesToRadians(a1)),
                cy + radius * @sin(std.math.degreesToRadians(a1)),
            });
            if (translucent) try self.w.writeAll("Q\n");
        }
    }

    fn readColorLine(self: *PaintInterp, abs: usize) !ColorLine {
        // ColorLine: uint8 extend; uint16 numStops; ColorStop[numStops].
        // ColorStop: F2Dot14 stopOffset; uint16 paletteIndex; F2Dot14 alpha.
        const Stop = struct { stop: gradient.ColorStop, alpha: f64 };
        const num = readU16(self.colr.data, abs + 1);
        if (num == 0) return .{ .stops = &.{}, .alphas = &.{} };
        const read = try self.arena.alloc(Stop, num);
        for (read, 0..) |*stop, i| {
            const s = abs + 3 + i * 6;
            const off = readF2Dot14(self.colr.data, s);
            const pal = readU16(self.colr.data, s + 2);
            const resolved = self.cpal.color(pal);
            const c = if (resolved) |r| r.c else self.fg;
            const entry_alpha: f64 = if (resolved) |r| @as(f64, @floatFromInt(r.alpha)) / 255.0 else 1.0;
            stop.* = .{
                .stop = .{ .offset = std.math.clamp(off, 0.0, 1.0), .color = c },
                .alpha = std.math.clamp(readF2Dot14(self.colr.data, s + 4) * entry_alpha, 0.0, 1.0),
            };
        }
        // PDF stitching functions need non-decreasing, in-range offsets.
        std.sort.pdq(Stop, read, {}, struct {
            fn lt(_: void, a: Stop, b: Stop) bool {
                return a.stop.offset < b.stop.offset;
            }
        }.lt);
        const line: ColorLine = .{
            .stops = try self.arena.alloc(gradient.ColorStop, num),
            .alphas = try self.arena.alloc(f64, num),
        };
        for (read, line.stops, line.alphas) |r, *stop, *alpha| {
            stop.* = r.stop;
            alpha.* = r.alpha;
        }
        return line;
    }
};

fn aroundCenter(m: Transform, cx: f64, cy: f64) Transform {
    return Transform.translate(cx, cy).concat(m).concat(Transform.translate(-cx, -cy));
}

fn rotation(rad: f64) Transform {
    return .{ .a = @cos(rad), .b = @sin(rad), .c = -@sin(rad), .d = @cos(rad) };
}

fn skew(x_rad: f64, y_rad: f64) Transform {
    return .{ .a = 1, .b = @tan(y_rad), .c = -@tan(x_rad), .d = 1 };
}

/// Reduce a COLR 3-point linear gradient to a PDF axial gradient endpoint.
fn axialEndpoint(p0x: f64, p0y: f64, p1x: f64, p1y: f64, p2x: f64, p2y: f64) struct { x: f64, y: f64 } {
    // Iso-color direction v = p2 - p0; gradient axis is perpendicular to v.
    const vx = p2x - p0x;
    const vy = p2y - p0y;
    const len = @sqrt(vx * vx + vy * vy);
    if (len < 1e-6) return .{ .x = p1x, .y = p1y };
    // Perpendicular unit vector n = perp(v)/|v|.
    const nx = -vy / len;
    const ny = vx / len;
    // Project (p1 - p0) onto n; endpoint = p0 + t*n.
    const t = (p1x - p0x) * nx + (p1y - p0y) * ny;
    return .{ .x = p0x + t * nx, .y = p0y + t * ny };
}

/// Map a sweep-gradient interpolation position through a color-line extend
/// mode into [0, 1].
fn sweepExtendT(t: f64, extend: Extend) f64 {
    return switch (extend) {
        .repeat => t - @floor(t),
        .reflect => blk: {
            const m = @mod(t, 2.0);
            break :blk if (m <= 1.0) m else 2.0 - m;
        },
        else => std.math.clamp(t, 0.0, 1.0), // pad (and unknown)
    };
}

/// Piecewise-linear evaluation of a sorted color line at t ∈ [0, 1].
fn sampleColorLine(stops: []const gradient.ColorStop, t: f64) Color.Rgbf {
    if (t <= stops[0].offset) return stops[0].color.toRgbf();
    const last = stops[stops.len - 1];
    if (t >= last.offset) return last.color.toRgbf();
    for (0..stops.len - 1) |i| {
        const b = stops[i + 1];
        if (t <= b.offset) {
            const a = stops[i];
            const seg = b.offset - a.offset;
            const u = if (seg < 1e-9) 1.0 else (t - a.offset) / seg;
            const ca = a.color.toRgbf();
            const cb = b.color.toRgbf();
            return .{
                .r = ca.r + (cb.r - ca.r) * u,
                .g = ca.g + (cb.g - ca.g) * u,
                .b = ca.b + (cb.b - ca.b) * u,
            };
        }
    }
    return last.color.toRgbf();
}

/// Piecewise-linear evaluation of per-stop `values` (in the order of the
/// sorted `stops`) at t ∈ [0, 1].
fn sampleValues(stops: []const gradient.ColorStop, values: []const f64, t: f64) f64 {
    if (t <= stops[0].offset) return values[0];
    if (t >= stops[stops.len - 1].offset) return values[values.len - 1];
    for (0..stops.len - 1) |i| {
        const b = stops[i + 1];
        if (t <= b.offset) {
            const seg = b.offset - stops[i].offset;
            const u = if (seg < 1e-9) 1.0 else (t - stops[i].offset) / seg;
            return values[i] + (values[i + 1] - values[i]) * u;
        }
    }
    return values[values.len - 1];
}

/// Map a COLR CompositeMode to a PDF /BM blend-mode name, or null for modes
/// with no direct PDF equivalent (fall back to Normal over).
fn blendModeName(mode: u8) ?[]const u8 {
    return switch (mode) {
        // Separable + non-separable blend modes shared with PDF.
        13 => "Screen",
        14 => "Overlay",
        15 => "Darken",
        16 => "Lighten",
        17 => "ColorDodge",
        18 => "ColorBurn",
        19 => "HardLight",
        20 => "SoftLight",
        21 => "Difference",
        22 => "Exclusion",
        23 => "Multiply",
        24 => "Hue",
        25 => "Saturation",
        26 => "Color",
        27 => "Luminosity",
        else => null, // Porter-Duff modes (0..12): approximate as source-over
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Interpreter-test fixture: loads a color font, parses its COLR/CPAL/glyf
/// tables, and owns the arena, resources, and output buffer a PaintInterp
/// needs. Returns error.SkipZigTest when the font (or a table) is missing.
const InterpFixture = struct {
    data: []const u8,
    colr: Colr,
    cpal: Cpal,
    glyf: GlyfContext,
    arena_state: std.heap.ArenaAllocator,
    res: ColorResources,
    aw: std.Io.Writer.Allocating,

    fn init(path: []const u8) !InterpFixture {
        const ttf = @import("ttf.zig");
        const loaded = ttf.Font.fromFile(testing.io, testing.allocator, path) catch return error.SkipZigTest;
        errdefer testing.allocator.free(loaded.data);
        const font = loaded.font;
        const head = font.head orelse return error.SkipZigTest;
        return .{
            .data = loaded.data,
            .colr = try Colr.parse(font.getTable("COLR".*) orelse return error.SkipZigTest),
            .cpal = try Cpal.parse(font.getTable("CPAL".*) orelse return error.SkipZigTest),
            .glyf = .{
                .glyf = font.getTable("glyf".*) orelse return error.SkipZigTest,
                .loca = font.getTable("loca".*) orelse return error.SkipZigTest,
                .loca_format = head.index_to_loc_format,
            },
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .res = ColorResources.init(testing.allocator),
            .aw = .init(testing.allocator),
        };
    }

    fn deinit(self: *InterpFixture) void {
        self.aw.deinit();
        self.res.deinit();
        self.arena_state.deinit();
        testing.allocator.free(self.data);
    }

    /// A PaintInterp wired to this fixture's tables and output buffer. Build
    /// it only once the fixture sits in its final location (`var fx = ...`),
    /// since it points into the fixture.
    fn interp(self: *InterpFixture) PaintInterp {
        return .{
            .w = &self.aw.writer,
            .arena = self.arena_state.allocator(),
            .colr = self.colr,
            .cpal = self.cpal,
            .glyf = self.glyf,
            .res = &self.res,
        };
    }

    /// Everything rendered into the fixture's output buffer so far.
    fn output(self: *InterpFixture) []const u8 {
        return self.aw.writer.buffered();
    }
};

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

test "paint interpreter renders cloud glyph as two filled solid layers" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();

    var interp = fx.interp();
    try interp.render(3950);
    const out = fx.output();

    // Two solid layers with the ground-truth palette colors.
    try testing.expect(std.mem.indexOf(u8, out, "0.894 0.918 0.933 rg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0.729 0.804 0.824 rg") != null);
    // Layer 0's outline (fast PaintGlyph→Solid path fills the outline directly).
    try testing.expect(std.mem.indexOf(u8, out, "257.00 366.00 m") != null);
    // Exactly two fills, no gradients/clips for this flat glyph.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "f\n"));
    try testing.expectEqual(@as(usize, 0), fx.res.shadings.items.len);
}

test "paint interpreter emits a shading for a gradient glyph" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();

    var interp = fx.interp();
    // gid 3994 = keycap digit '0': PaintGlyph(clip) → PaintLinearGradient.
    try interp.render(3994);
    const out = fx.output();

    // One axial shading registered, referenced by `sh` inside a clip.
    try testing.expectEqual(@as(usize, 1), fx.res.shadings.items.len);
    try testing.expect(std.mem.indexOf(u8, fx.res.shadings.items[0], "/ShadingType 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "W n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/Sh1 sh") != null);
}

test "gradient stop alpha becomes a luminosity soft mask" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();

    var interp = fx.interp();
    // gid 2236 = U+1F4E3 megaphone: one linear gradient of a single palette
    // color fading from alpha 1 (offset 0) to alpha 0 (offset 1), per fontTools
    try interp.render(2236);
    const out = fx.output();

    try testing.expectEqual(@as(usize, 1), fx.res.shadings.items.len);
    try testing.expectEqual(@as(usize, 1), fx.res.soft_masks.items.len);
    // The mask is the same axial geometry in gray, carrying the alpha ramp
    const fill = fx.res.shadings.items[0];
    const mask = fx.res.soft_masks.items[0];
    try testing.expect(std.mem.indexOf(u8, mask, "/ShadingType 2") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "/ColorSpace /DeviceGray") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "/C0 [1.000] /C1 [0.000]") != null or
        std.mem.indexOf(u8, mask, "/C0 [1.000]\n/C1 [0.000]") != null);
    const coords = std.mem.indexOf(u8, fill, "/Coords").?;
    const coords_end = std.mem.indexOfScalarPos(u8, fill, coords, ']').?;
    try testing.expect(std.mem.indexOf(u8, mask, fill[coords .. coords_end + 1]) != null);
    // The shading is painted under the mask, inside its own q/Q
    try testing.expect(std.mem.indexOf(u8, out, "q\n/Gm1 gs\n/Sh1 sh\nQ\n") != null);
}

test "constant gradient stop alpha becomes /ca, scaled by an enclosing composite" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();
    var interp = fx.interp();
    interp.alpha_scale = 0.5;
    interp.clip_depth = 1;
    // PaintLinearGradient (format 4) with an inline ColorLine of two stops,
    // both at alpha 0.5 (F2Dot14 0x2000)
    const paint = [_]u8{
        4, 0, 0, 16, // format, colorLineOffset 16
        0, 0, 0, 0, 0, 100, 0, 0, 0, 0, 100, 0, // p0 (0,0) p1 (0,100) p2 (100,0)
        0, 0, 2, // extend pad, 2 stops
        0x00, 0x00, 0, 0, 0x20, 0x00, // offset 0, palette 0, alpha 0.5
        0x40, 0x00, 0, 0, 0x20, 0x00, // offset 1, palette 0, alpha 0.5
    };
    interp.colr = std.mem.zeroes(Colr);
    interp.colr.data = &paint;
    try interp.renderPaint(0, 0);
    try testing.expectEqual(@as(usize, 0), fx.res.soft_masks.items.len);
    try testing.expectEqual(@as(usize, 1), fx.res.ext_gstates.items.len);
    try testing.expectEqualStrings("<< /Type /ExtGState /ca 0.250 >>", fx.res.ext_gstates.items[0]);
    try testing.expectEqualStrings("q\n/Ga1 gs\n/Sh1 sh\nQ\n", fx.output());
}

test "all-off-curve contour walks as four smooth quadratic segments" {
    // A TrueType "circle": four off-curve points and no on-curve ones. The
    // start point is synthesized midway between the last and first points.
    const pts = [_]Pt{
        .{ .x = 100, .y = 0, .on = false },
        .{ .x = 0, .y = 100, .on = false },
        .{ .x = -100, .y = 0, .on = false },
        .{ .x = 0, .y = -100, .on = false },
    };
    const start = Pt{ .x = 50, .y = -50, .on = true }; // mid(last, first)

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try walkAllOff(&aw.writer, &pts, start);
    const out = aw.writer.buffered();

    // Four quadratic segments (as cubics), no straight lines.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, " c\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, " l\n"));
    // Segment midpoints land halfway between adjacent control points.
    try testing.expect(std.mem.indexOf(u8, out, "50.00 50.00 c") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-50.00 50.00 c") != null);
}

test "glyf outline extraction (Noto cloud layer glyph 23929)" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();

    try writeGlyphOutline(&fx.aw.writer, fx.arena_state.allocator(), fx.glyf, 23929, Transform.identity);
    const out = fx.output();

    // Ground truth: single contour starting on-curve at (257, 366).
    try testing.expect(std.mem.indexOf(u8, out, "257.00 366.00 m") != null);
    // Exactly one subpath (one moveTo) and it closes.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, " m\n"));
    try testing.expect(std.mem.endsWith(u8, out, "h\n"));
    // Contains cubic segments (quads converted to cubics).
    try testing.expect(std.mem.indexOf(u8, out, " c\n") != null);
}

const bungee_v0_path = "test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf";

test "COLR v1 sweep gradient renders as a wedge fan (SweepTest fixture)" {
    // Fixture built by scripts/gen_sweep_font.py: 'A' (gid 1) is a square
    // with a full-circle sweep 0°..360°, red → blue, pad extend; 'B' (gid 2)
    // sweeps only 0°..90° (angles outside the range pad to the end colors);
    // 'C' (gid 3) sweeps 110°..230° (the spec's example arc).
    var fx = try InterpFixture.init("test/fonts/sweep/SweepTest.ttf");
    defer fx.deinit();

    // PaintGlyph → PaintSweepGradient.
    const root = fx.colr.baseGlyphPaint(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PaintFormat.glyph, fx.colr.paintFormat(root));
    try testing.expectEqual(PaintFormat.sweep_gradient, fx.colr.paintFormat(root + readU24(fx.colr.data, root + 1)));

    var interp = fx.interp();
    try interp.render(1); // 'A': full-circle sweep
    const out = fx.output();

    // A fan of 120 flat-colored wedges inside the glyph clip; no shadings.
    try testing.expectEqual(@as(usize, 0), fx.res.shadings.items.len);
    try testing.expect(std.mem.indexOf(u8, out, "W n") != null);
    try testing.expectEqual(@as(usize, 120), std.mem.count(u8, out, " rg\n"));
    // First wedge midpoint t = 1.5/360: nearly pure red; last: nearly pure blue.
    try testing.expect(std.mem.indexOf(u8, out, "0.996 0.000 0.004 rg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0.004 0.000 0.996 rg") != null);
    // 120 closed, filled wedge triangles.
    try testing.expectEqual(@as(usize, 120), std.mem.count(u8, out, "h f\n"));

    // 'B': 0°..90° span with pad extend — wedges beyond 90° clamp to pure
    // blue, so blue is by far the most common wedge color (90 of 120).
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    interp.w = &aw2.writer;
    try interp.render(2);
    const out2 = aw2.writer.buffered();
    try testing.expectEqual(@as(usize, 90), std.mem.count(u8, out2, "0.000 0.000 1.000 rg"));
    // Near the sweep midpoint (wedge 42°..45°, midpoint t = 43.5/90): the
    // color is about half red, half blue.
    try testing.expect(std.mem.indexOf(u8, out2, "0.517 0.000 0.483 rg") != null);

    // 'C': 110°..230° span, pad — per spec the sampling domain is the
    // absolute [0°, 360°): angles below 110° pad to the offset-0 color
    // (red, 37 wedge midpoints) and angles above 230° to the offset-1
    // color (blue, 43 wedge midpoints).
    var aw3: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw3.deinit();
    interp.w = &aw3.writer;
    try interp.render(3);
    const out3 = aw3.writer.buffered();
    try testing.expectEqual(@as(usize, 37), std.mem.count(u8, out3, "1.000 0.000 0.000 rg"));
    try testing.expectEqual(@as(usize, 43), std.mem.count(u8, out3, "0.000 0.000 1.000 rg"));
}

test "SRC_IN composite with solid backdrop renders source at backdrop alpha" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();

    var interp = fx.interp();
    // gid 2092 (control knobs 🎛): root layers contain unclipped
    // PaintComposite(SRC_IN, source = artwork layers, backdrop = solid black
    // alpha 0.7). Must render as the artwork at 0.7 alpha — NOT paint the
    // backdrop as an unbounded black rectangle over the whole page.
    try interp.render(2092);
    const out = fx.output();

    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "-32768 -32768 65536 65536 re"));
    var found_ca = false;
    for (fx.res.ext_gstates.items) |gs| {
        if (std.mem.indexOf(u8, gs, "/ca 0.700") != null) found_ca = true;
    }
    try testing.expect(found_ca);
}

test "blend mode mapping follows the COLR CompositeMode enum" {
    // Porter-Duff modes (0..12) have no PDF blend-mode equivalent.
    try testing.expect(blendModeName(3) == null); // SRC_OVER
    try testing.expect(blendModeName(5) == null); // SRC_IN
    try testing.expect(blendModeName(9) == null); // SRC_ATOP
    try testing.expect(blendModeName(12) == null); // PLUS
    // Blend modes start at SCREEN = 13; MULTIPLY is 23 (after EXCLUSION).
    try testing.expectEqualStrings("Screen", blendModeName(13).?);
    try testing.expectEqualStrings("SoftLight", blendModeName(20).?);
    try testing.expectEqualStrings("Multiply", blendModeName(23).?);
    try testing.expectEqualStrings("Luminosity", blendModeName(27).?);
    try testing.expect(blendModeName(28) == null);
}

test "sweep color-line helpers (extend modes and sampling)" {
    // Extend modes.
    try testing.expectApproxEqAbs(@as(f64, 1.0), sweepExtendT(2.3, .pad), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), sweepExtendT(-0.5, .pad), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.3), sweepExtendT(2.3, .repeat), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), sweepExtendT(-0.5, .repeat), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.7), sweepExtendT(1.3, .reflect), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), sweepExtendT(-0.5, .reflect), 1e-12);

    // Sampling clamps outside the stop range and lerps within segments.
    const stops = [_]gradient.ColorStop{
        .{ .offset = 0.25, .color = Color.rgb(255, 0, 0) },
        .{ .offset = 0.75, .color = Color.rgb(0, 0, 255) },
    };
    try testing.expectApproxEqAbs(@as(f64, 1.0), sampleColorLine(&stops, 0.0).r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), sampleColorLine(&stops, 1.0).b, 1e-12);
    const mid = sampleColorLine(&stops, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 0.5), mid.r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), mid.b, 1e-12);
}

test "COLR v0 parse and layer records (Bungee Color)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, bungee_v0_path) catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;
    const colr_data = font.getTable("COLR".*) orelse return error.SkipZigTest;

    const colr = try Colr.parse(colr_data);
    try testing.expectEqual(@as(u16, 0), colr.version);
    try testing.expect(colr.base_glyph_list == 0); // no v1 paint graph
    try testing.expect(colr.num_base_glyph_records > 0);

    // 'A' (gid 2) has two layers: the fill outline (palette 0) and the inline
    // detail glyph 'A.inline' (gid 1062, palette 1).
    const rec = colr.v0BaseGlyph(2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), rec.num);
    const l0 = colr.v0Layer(rec.first).?;
    const l1 = colr.v0Layer(rec.first + 1).?;
    try testing.expectEqual(@as(u16, 2), l0.gid);
    try testing.expectEqual(@as(u16, 0), l0.palette);
    try testing.expectEqual(@as(u16, 1062), l1.gid);
    try testing.expectEqual(@as(u16, 1), l1.palette);

    try testing.expect(colr.isColorGlyph(2));
}

test "COLR v1 linear gradients on a non-emoji font (Bungee Spice)" {
    var fx = try InterpFixture.init("test/fonts/Bungee Color/BungeeSpice-Regular-COLRv1.ttf");
    defer fx.deinit();

    try testing.expectEqual(@as(u16, 1), fx.colr.version);
    try testing.expect(fx.colr.base_glyph_list != 0);
    try testing.expect(fx.colr.isColorGlyph(2));

    var interp = fx.interp();
    // 'A' (gid 2): PaintColrLayers → 2× PaintGlyph(clip) → PaintLinearGradient.
    try interp.render(2);
    const out = fx.output();

    // Ground truth from fontTools: both layers share the gradient geometry
    // p0=(0,0), p1=(0,900), p2=(100,0); the 3-point form reduces to the axial
    // endpoint (0,900). Layer 0 runs gold→dark red, layer 1 (A.inline) the
    // reverse. Palette: 0 = (201,9,0), 1 = (255,215,0).
    try testing.expectEqual(@as(usize, 2), fx.res.shadings.items.len);
    const sh0 = fx.res.shadings.items[0];
    const sh1 = fx.res.shadings.items[1];
    try testing.expect(std.mem.indexOf(u8, sh0, "/ShadingType 2") != null);
    try testing.expect(std.mem.indexOf(u8, sh0, "/Coords [0.00 0.00 0.00 900.00]") != null);
    try testing.expect(std.mem.indexOf(u8, sh0, "/C0 [1.000 0.843 0.000]") != null);
    try testing.expect(std.mem.indexOf(u8, sh0, "/C1 [0.788 0.035 0.000]") != null);
    try testing.expect(std.mem.indexOf(u8, sh1, "/C0 [0.788 0.035 0.000]") != null);
    try testing.expect(std.mem.indexOf(u8, sh1, "/C1 [1.000 0.843 0.000]") != null);

    // Each layer clips to its glyph outline and paints via `sh`; no solid fills.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "W n"));
    try testing.expect(std.mem.indexOf(u8, out, "/Sh1 sh") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/Sh2 sh") != null);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "f\n"));
}

test "COLR v0 paint interpreter fills layers with palette colors (Bungee)" {
    var fx = try InterpFixture.init(bungee_v0_path);
    defer fx.deinit();

    var interp = fx.interp();
    try interp.render(2); // 'A'
    const out = fx.output();

    // Two solid layers: palette 0 = (201,9,0) dark red, palette 1 = (255,149,128) salmon.
    try testing.expect(std.mem.indexOf(u8, out, "0.788 0.035 0.000 rg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.000 0.584 0.502 rg") != null);
    // Exactly two fills, no gradients (v0 is flat solid layers only).
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "f\n"));
    try testing.expectEqual(@as(usize, 0), fx.res.shadings.items.len);
}

// Overflow regression tests (2026-10-05 audit): each panicked before the fix.

test "glyf slice for gid 0xFFFF does not overflow" {
    const loca: [8]u8 = @splat(0);
    const ctx = GlyfContext{ .glyf = &.{}, .loca = &loca, .loca_format = 1 };
    try testing.expectEqual(@as(?[]const u8, null), ctx.glyphSlice(0xFFFF));
}

test "glyf instruction length near u16 max does not overflow" {
    // One simple glyph: 1 contour ending at point 0, instructionLength 0xFFFF.
    var glyf: [14]u8 = @splat(0);
    std.mem.writeInt(i16, glyf[0..2], 1, .big);
    std.mem.writeInt(u16, glyf[12..14], 0xFFFF, .big);
    var loca: [8]u8 = @splat(0);
    std.mem.writeInt(u32, loca[4..8], glyf.len, .big);
    const ctx = GlyfContext{ .glyf = &glyf, .loca = &loca, .loca_format = 1 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayListUnmanaged([]Pt) = .empty;
    try collectContours(arena.allocator(), ctx, 0, Transform.identity, 0, &out);
}

test "PaintColrLayers with firstLayerIndex near u32 max does not overflow" {
    var fx = try InterpFixture.init("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf");
    defer fx.deinit();
    // PaintColrLayers: format 1, numLayers 2, firstLayerIndex 0xFFFFFFFF.
    const paint = [_]u8{ 1, 2, 0xFF, 0xFF, 0xFF, 0xFF };
    var interp = fx.interp();
    interp.colr = std.mem.zeroes(Colr);
    interp.colr.data = &paint;
    interp.colr.layer_list = 1;
    interp.colr.num_layers = 0xFFFF_FFFF;
    try interp.renderPaint(0, 0);
}
