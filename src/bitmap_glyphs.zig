//! CBDT/CBLC, EBDT/EBLC and sbix bitmap-glyph support.
//!
//! Extracts the embedded bitmap strike for individual glyphs so higher
//! layers can embed them as PDF image XObjects referenced from Type3
//! CharProcs. Two payload kinds are supported: PNG color bitmaps (CBDT
//! image formats 17/18/19, sbix 'png ' records) and 1-bit monochrome pixel
//! glyphs (EBDT image formats 1/2/5/6/7 — classic OTB pixel fonts, emitted
//! as PDF ImageMasks so they take the text color). EBLC shares CBLC's
//! layout, so one parser handles both. The largest strike is used and
//! scaled to the em. All slices reference the font data — nothing is
//! allocated.

const std = @import("std");
const binary = @import("binary.zig");

const readU8 = binary.readU8;
const readU16 = binary.readU16;
const readI16 = binary.readI16;
const readU32 = binary.readU32;

fn readI8(data: []const u8, off: usize) i8 {
    return @bitCast(readU8(data, off));
}

/// A glyph's bitmap: pixel payload plus placement in strike pixels.
pub const BitmapGlyph = struct {
    pixels: Pixels,
    /// Left edge of the bitmap relative to the glyph origin, pixels.
    bearing_x: f64,
    /// Bottom edge of the bitmap relative to the baseline, pixels.
    bottom_y: f64,
    width_px: u32,
    height_px: u32,

    pub const Pixels = union(enum) {
        /// A PNG file (color strikes).
        png: []const u8,
        /// 1-bit pixels, MSB first, bit 1 = ink. `bit_aligned` rows run
        /// continuously with no padding; otherwise each row starts on a
        /// byte boundary.
        mono: Mono,
    };

    pub const Mono = struct { data: []const u8, bit_aligned: bool };
};

/// Repack a 1-bit mono bitmap into byte-aligned rows (each row padded to a
/// byte boundary, MSB first) as PDF image data expects. Returns a newly
/// allocated buffer of (width+7)/8 × height bytes.
pub fn packMonoRows(allocator: std.mem.Allocator, mono: BitmapGlyph.Mono, width: u32, height: u32) ![]u8 {
    const row_bytes = (width + 7) / 8;
    const out = try allocator.alloc(u8, @as(usize, row_bytes) * height);
    if (!mono.bit_aligned) {
        @memcpy(out, mono.data[0..out.len]);
        return out;
    }
    @memset(out, 0);
    var bit_index: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const bit = (mono.data[bit_index / 8] >> @intCast(7 - bit_index % 8)) & 1;
            bit_index += 1;
            if (bit != 0) out[y * row_bytes + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
        }
    }
    return out;
}

/// Width/height from a PNG's IHDR header, or null if not a PNG.
pub fn pngDimensions(png: []const u8) ?struct { w: u32, h: u32 } {
    if (png.len < 24) return null;
    if (!std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return null;
    const w = readU32(png, 16);
    const h = readU32(png, 20);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

// ============================================================================
// sbix
// ============================================================================

/// Parsed sbix table, positioned on its largest-ppem strike.
pub const Sbix = struct {
    data: []const u8,
    num_glyphs: u16, // from maxp; the strike offset array has num_glyphs+1 entries
    strike_off: usize,
    strike_ppem: u16,

    pub fn parse(data: []const u8, num_glyphs: u16) !Sbix {
        // Header: u16 version, u16 flags, u32 numStrikes, u32 strikeOffset[].
        if (data.len < 12) return error.InvalidSbix;
        const num_strikes = readU32(data, 4);
        var best_off: usize = 0;
        var best_ppem: u16 = 0;
        for (0..num_strikes) |i| {
            const off = readU32(data, 8 + i * 4);
            if (off + 4 > data.len) continue;
            // Strike: u16 ppem, u16 ppi, u32 glyphDataOffsets[numGlyphs+1].
            const ppem = readU16(data, off);
            if (ppem > best_ppem) {
                best_ppem = ppem;
                best_off = off;
            }
        }
        if (best_ppem == 0) return error.InvalidSbix;
        return .{ .data = data, .num_glyphs = num_glyphs, .strike_off = best_off, .strike_ppem = best_ppem };
    }

    pub fn glyphBitmap(self: Sbix, gid: u16) ?BitmapGlyph {
        var g = gid;
        // Follow at most a few 'dupe' references.
        for (0..4) |_| {
            if (g >= self.num_glyphs) return null;
            const off_pos = self.strike_off + 4 + @as(usize, g) * 4;
            const o0 = self.strike_off + readU32(self.data, off_pos);
            const o1 = self.strike_off + readU32(self.data, off_pos + 4);
            // Glyph data: i16 originOffsetX, i16 originOffsetY, tag graphicType, data.
            if (o1 <= o0 + 8 or o1 > self.data.len) return null;
            const gtype = self.data[o0 + 4 .. o0 + 8];
            if (std.mem.eql(u8, gtype, "dupe")) {
                g = readU16(self.data, o0 + 8);
                continue;
            }
            if (!std.mem.eql(u8, gtype, "png ")) return null;
            const png = self.data[o0 + 8 .. o1];
            const dims = pngDimensions(png) orelse return null;
            return .{
                .pixels = .{ .png = png },
                .bearing_x = @floatFromInt(readI16(self.data, o0)),
                .bottom_y = @floatFromInt(readI16(self.data, o0 + 2)),
                .width_px = dims.w,
                .height_px = dims.h,
            };
        }
        return null;
    }
};

// ============================================================================
// CBDT / CBLC (and EBDT / EBLC, which share the same layout)
// ============================================================================

/// Parsed CBDT+CBLC (or EBDT+EBLC) pair, positioned on the largest-ppem
/// strike.
pub const Cbdt = struct {
    cblc: []const u8,
    cbdt: []const u8,
    index_array_off: usize,
    num_subtables: u32,
    strike_ppem: u16,
    /// Bits per pixel of the strike: 32 for color (PNG payloads), 1 for
    /// monochrome pixel fonts. Grayscale depths (2/4/8) are unsupported.
    bit_depth: u8,

    const BigMetrics = struct { height: u8, width: u8, bearing_x: i8, bearing_y: i8 };

    pub fn parse(cblc: []const u8, cbdt: []const u8) !Cbdt {
        // CBLC header: u16 major, u16 minor, u32 numSizes; BitmapSize[48] each.
        if (cblc.len < 8) return error.InvalidCblc;
        const num_sizes = readU32(cblc, 4);
        var best: ?usize = 0;
        var best_ppem: u16 = 0;
        best = null;
        for (0..num_sizes) |i| {
            const rec = 8 + i * 48;
            if (rec + 48 > cblc.len) break;
            const ppem: u16 = readU8(cblc, rec + 44); // ppemX
            if (ppem > best_ppem) {
                best_ppem = ppem;
                best = rec;
            }
        }
        const rec = best orelse return error.InvalidCblc;
        return .{
            .cblc = cblc,
            .cbdt = cbdt,
            .index_array_off = readU32(cblc, rec),
            .num_subtables = readU32(cblc, rec + 8),
            .strike_ppem = best_ppem,
            .bit_depth = readU8(cblc, rec + 46),
        };
    }

    pub fn glyphBitmap(self: Cbdt, gid: u16) ?BitmapGlyph {
        // IndexSubTableArray: u16 firstGlyphIndex, u16 lastGlyphIndex,
        // u32 additionalOffsetToIndexSubtable (from the array start).
        for (0..self.num_subtables) |i| {
            const entry = self.index_array_off + i * 8;
            const first = readU16(self.cblc, entry);
            const last = readU16(self.cblc, entry + 2);
            if (gid < first or gid > last) continue;
            const sub = self.index_array_off + readU32(self.cblc, entry + 4);
            return self.lookupInSubtable(sub, first, gid);
        }
        return null;
    }

    fn lookupInSubtable(self: Cbdt, sub: usize, first: u16, gid: u16) ?BitmapGlyph {
        // IndexSubHeader: u16 indexFormat, u16 imageFormat, u32 imageDataOffset
        // (from the start of CBDT).
        const index_format = readU16(self.cblc, sub);
        const image_format = readU16(self.cblc, sub + 2);
        const image_data_off = readU32(self.cblc, sub + 4);
        const rel: usize = gid - first;

        var glyph_off: usize = 0;
        var glyph_end: usize = 0; // 0 = unknown (constant-size formats)
        var index_metrics: ?BigMetrics = null;
        switch (index_format) {
            1 => { // u32 offsets, one per glyph in [first, last] plus a sentinel
                const o0 = readU32(self.cblc, sub + 8 + rel * 4);
                const o1 = readU32(self.cblc, sub + 8 + (rel + 1) * 4);
                if (o1 <= o0) return null; // no bitmap for this glyph
                glyph_off = image_data_off + o0;
                glyph_end = image_data_off + o1;
            },
            2 => { // constant imageSize + shared BigGlyphMetrics
                const image_size = readU32(self.cblc, sub + 8);
                index_metrics = readBigMetrics(self.cblc, sub + 12);
                glyph_off = image_data_off + rel * image_size;
                glyph_end = glyph_off + image_size;
            },
            3 => { // u16 offsets
                const o0: usize = readU16(self.cblc, sub + 8 + rel * 2);
                const o1: usize = readU16(self.cblc, sub + 8 + (rel + 1) * 2);
                if (o1 <= o0) return null;
                glyph_off = image_data_off + o0;
                glyph_end = image_data_off + o1;
            },
            4 => { // sparse (glyphID, offset) pairs + sentinel pair
                const num = readU32(self.cblc, sub + 8);
                var i: usize = 0;
                while (i < num) : (i += 1) {
                    const pair = sub + 12 + i * 4;
                    if (readU16(self.cblc, pair) != gid) continue;
                    glyph_off = image_data_off + readU16(self.cblc, pair + 2);
                    glyph_end = image_data_off + readU16(self.cblc, pair + 6);
                    break;
                }
                if (i == num or glyph_end <= glyph_off) return null;
            },
            5 => { // constant imageSize + shared metrics + sorted glyph id array
                const image_size = readU32(self.cblc, sub + 8);
                index_metrics = readBigMetrics(self.cblc, sub + 12);
                const num = readU32(self.cblc, sub + 20);
                var i: usize = 0;
                while (i < num) : (i += 1) {
                    if (readU16(self.cblc, sub + 24 + i * 2) == gid) break;
                }
                if (i == num) return null;
                glyph_off = image_data_off + i * image_size;
                glyph_end = glyph_off + image_size;
            },
            else => return null,
        }
        if (glyph_end > self.cbdt.len or glyph_end <= glyph_off) return null;

        // Glyph record. PNG data length is explicit in the color formats;
        // the monochrome formats (1-bit only) derive it from the metrics.
        switch (image_format) {
            1, 2 => { // SmallGlyphMetrics (5 bytes) + rows (1: byte-, 2: bit-aligned)
                if (self.bit_depth != 1) return null;
                const m_height = readU8(self.cbdt, glyph_off);
                const m_width = readU8(self.cbdt, glyph_off + 1);
                const bearing_x = readI8(self.cbdt, glyph_off + 2);
                const bearing_y = readI8(self.cbdt, glyph_off + 3);
                return self.monoAt(glyph_off + 5, glyph_end, bearing_x, bearing_y, m_width, m_height, image_format == 2);
            },
            5 => { // bit-aligned rows only; metrics come from the index subtable
                if (self.bit_depth != 1) return null;
                const m = index_metrics orelse return null;
                return self.monoAt(glyph_off, glyph_end, m.bearing_x, m.bearing_y, m.width, m.height, true);
            },
            6, 7 => { // BigGlyphMetrics (8 bytes) + rows (6: byte-, 7: bit-aligned)
                if (self.bit_depth != 1) return null;
                const m = readBigMetrics(self.cbdt, glyph_off);
                return self.monoAt(glyph_off + 8, glyph_end, m.bearing_x, m.bearing_y, m.width, m.height, image_format == 7);
            },
            17 => { // SmallGlyphMetrics (5 bytes) + u32 dataLen + PNG
                const m_height = readU8(self.cbdt, glyph_off);
                const m_width = readU8(self.cbdt, glyph_off + 1);
                const bearing_x = readI8(self.cbdt, glyph_off + 2);
                const bearing_y = readI8(self.cbdt, glyph_off + 3);
                return self.pngAt(glyph_off + 5, bearing_x, bearing_y, m_width, m_height);
            },
            18 => { // BigGlyphMetrics (8 bytes) + u32 dataLen + PNG
                const m = readBigMetrics(self.cbdt, glyph_off);
                return self.pngAt(glyph_off + 8, m.bearing_x, m.bearing_y, m.width, m.height);
            },
            19 => { // u32 dataLen + PNG; metrics come from the index subtable
                const m = index_metrics orelse return null;
                return self.pngAt(glyph_off, m.bearing_x, m.bearing_y, m.width, m.height);
            },
            else => return null, // incl. 8/9 (composite glyphs): unsupported
        }
    }

    fn monoAt(self: Cbdt, off: usize, end: usize, bearing_x: i8, bearing_y: i8, width: u8, height: u8, bit_aligned: bool) ?BitmapGlyph {
        if (width == 0 or height == 0) return null;
        const w: usize = width;
        const h: usize = height;
        const len = if (bit_aligned) (w * h + 7) / 8 else h * ((w + 7) / 8);
        if (off + len > end or off + len > self.cbdt.len) return null;
        return .{
            .pixels = .{ .mono = .{ .data = self.cbdt[off .. off + len], .bit_aligned = bit_aligned } },
            .bearing_x = @floatFromInt(bearing_x),
            .bottom_y = @as(f64, @floatFromInt(bearing_y)) - @as(f64, @floatFromInt(height)),
            .width_px = width,
            .height_px = height,
        };
    }

    fn readBigMetrics(data: []const u8, off: usize) BigMetrics {
        // BigGlyphMetrics: height, width (u8), horiBearingX/Y (i8), ...
        return .{
            .height = readU8(data, off),
            .width = readU8(data, off + 1),
            .bearing_x = readI8(data, off + 2),
            .bearing_y = readI8(data, off + 3),
        };
    }

    fn pngAt(self: Cbdt, off: usize, bearing_x: i8, bearing_y: i8, width: u8, height: u8) ?BitmapGlyph {
        const len = readU32(self.cbdt, off);
        if (len == 0 or off + 4 + len > self.cbdt.len) return null;
        const png = self.cbdt[off + 4 .. off + 4 + len];
        if (pngDimensions(png) == null) return null;
        return .{
            .pixels = .{ .png = png },
            .bearing_x = @floatFromInt(bearing_x),
            // bearingY is the top edge above the baseline; convert to bottom.
            .bottom_y = @as(f64, @floatFromInt(bearing_y)) - @as(f64, @floatFromInt(height)),
            .width_px = width,
            .height_px = height,
        };
    }
};

// ============================================================================
// Common front end
// ============================================================================

/// Bitmap color-glyph source for one font: sbix or CBDT/CBLC.
pub const BitmapInfo = union(enum) {
    sbix: Sbix,
    cbdt: Cbdt,

    /// Pixels per em of the chosen strike.
    pub fn ppem(self: BitmapInfo) u16 {
        return switch (self) {
            .sbix => |s| s.strike_ppem,
            .cbdt => |c| c.strike_ppem,
        };
    }

    /// The glyph's PNG bitmap and placement, or null if it has none.
    pub fn glyphBitmap(self: BitmapInfo, gid: u16) ?BitmapGlyph {
        return switch (self) {
            .sbix => |s| s.glyphBitmap(gid),
            .cbdt => |c| c.glyphBitmap(gid),
        };
    }

    pub fn isBitmapGlyph(self: BitmapInfo, gid: u16) bool {
        return self.glyphBitmap(gid) != null;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "sbix parse and glyph extraction (SbixTest fixture)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/bitmap/SbixTest.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;

    const sbix = try Sbix.parse(font.getTable("sbix".*).?, font.maxp.?.num_glyphs);
    try testing.expectEqual(@as(u16, 64), sbix.strike_ppem);

    // 'A' (gid 1): 64x64 PNG at the origin.
    const a = sbix.glyphBitmap(1).?;
    try testing.expectEqual(@as(u32, 64), a.width_px);
    try testing.expectEqual(@as(u32, 64), a.height_px);
    try testing.expectApproxEqAbs(@as(f64, 0), a.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), a.bottom_y, 1e-9);
    try testing.expect(std.mem.startsWith(u8, a.pixels.png, "\x89PNG"));

    // 'B' (gid 2): origin offset (8, -8).
    const b = sbix.glyphBitmap(2).?;
    try testing.expectApproxEqAbs(@as(f64, 8), b.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -8), b.bottom_y, 1e-9);

    // .notdef (gid 0) has no bitmap.
    try testing.expect(sbix.glyphBitmap(0) == null);

    // 'C' (gid 3): a 'dupe' record that resolves to A's bitmap.
    const c = sbix.glyphBitmap(3).?;
    try testing.expectEqualSlices(u8, a.pixels.png, c.pixels.png);
}

test "CBDT/CBLC parse and glyph extraction (CbdtTest fixture)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/bitmap/CbdtTest.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;

    const cbdt = try Cbdt.parse(font.getTable("CBLC".*).?, font.getTable("CBDT".*).?);
    try testing.expectEqual(@as(u16, 64), cbdt.strike_ppem);

    // 'A' (gid 1): 64x64, bearingX 0, bearingY 64 → bottom at the baseline.
    const a = cbdt.glyphBitmap(1).?;
    try testing.expectEqual(@as(u32, 64), a.width_px);
    try testing.expectEqual(@as(u32, 64), a.height_px);
    try testing.expectApproxEqAbs(@as(f64, 0), a.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), a.bottom_y, 1e-9);
    try testing.expect(std.mem.startsWith(u8, a.pixels.png, "\x89PNG"));

    // 'B' (gid 2): bearingX 4, bearingY 60 → bottom edge at -4 px.
    const b = cbdt.glyphBitmap(2).?;
    try testing.expectApproxEqAbs(@as(f64, 4), b.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -4), b.bottom_y, 1e-9);

    try testing.expect(cbdt.glyphBitmap(0) == null);
    try testing.expect(cbdt.glyphBitmap(99) == null);
}

test "EBDT/EBLC 1-bit pixel glyph extraction (Cozette OTB)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/Cozette/cozette.otb") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;

    const ebdt = try Cbdt.parse(font.getTable("EBLC".*).?, font.getTable("EBDT".*).?);
    try testing.expectEqual(@as(u16, 13), ebdt.strike_ppem);
    try testing.expectEqual(@as(u8, 1), ebdt.bit_depth);

    // 'A' (gid 66): 7x13 bitmap via index format 2 / image format 5
    // (bit-aligned, shared metrics). Ground truth from fontTools:
    // bearing (0, 10) → bottom edge 3 px below the baseline.
    const a = ebdt.glyphBitmap(66).?;
    try testing.expectEqual(@as(u32, 7), a.width_px);
    try testing.expectEqual(@as(u32, 13), a.height_px);
    try testing.expectApproxEqAbs(@as(f64, 0), a.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -3), a.bottom_y, 1e-9);
    const mono = a.pixels.mono;
    try testing.expect(mono.bit_aligned);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xE2, 0x24, 0x48, 0x9F, 0x22, 0x44, 0x88, 0x00, 0x00, 0x00 }, mono.data);

    // Repacked byte-aligned rows draw the expected 'A' shape.
    const rows = try packMonoRows(testing.allocator, mono, a.width_px, a.height_px);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x38, 0x44, 0x44, 0x44, 0x7C, 0x44, 0x44, 0x44, 0x00, 0x00, 0x00,
    }, rows);
}

/// Test helper: builds CBLC/CBDT byte blobs for parser tests without
/// needing fixture fonts.
const TableBuilder = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn u8v(self: *TableBuilder, v: u8) *TableBuilder {
        self.bytes.append(testing.allocator, v) catch unreachable;
        return self;
    }
    fn u16v(self: *TableBuilder, v: u16) *TableBuilder {
        self.bytes.appendSlice(testing.allocator, &@as([2]u8, @bitCast(std.mem.nativeToBig(u16, v)))) catch unreachable;
        return self;
    }
    fn u32v(self: *TableBuilder, v: u32) *TableBuilder {
        self.bytes.appendSlice(testing.allocator, &@as([4]u8, @bitCast(std.mem.nativeToBig(u32, v)))) catch unreachable;
        return self;
    }
    fn raw(self: *TableBuilder, data: []const u8) *TableBuilder {
        self.bytes.appendSlice(testing.allocator, data) catch unreachable;
        return self;
    }
    fn deinit(self: *TableBuilder) void {
        self.bytes.deinit(testing.allocator);
    }

    /// CBLC/EBLC with one strike whose IndexSubTableArray (one entry:
    /// [first, last] → subtable at array+8) is followed by `subtable`.
    fn cblc(self: *TableBuilder, first: u16, last: u16, ppem: u8, bit_depth: u8, subtable: []const u8) []const u8 {
        _ = self.u16v(3).u16v(0).u32v(1); // header: version 3.0, numSizes 1
        _ = self.u32v(56).u32v(0).u32v(1).u32v(0); // record: arrayOff 56, size, numSubtables 1, colorRef
        for (0..28) |_| _ = self.u8v(0); // sbit line metrics (2 × 12) + start/end glyph (ignored by parser)
        _ = self.u8v(ppem).u8v(ppem).u8v(bit_depth).u8v(0); // ppemX/Y, bitDepth, flags
        _ = self.u16v(first).u16v(last).u32v(8); // array entry → subtable at array+8
        _ = self.raw(subtable);
        return self.bytes.items;
    }
};

/// A minimal but valid-headered PNG blob (only the 24-byte prefix is read).
fn fakePng(comptime w: u32, comptime h: u32) [24]u8 {
    var png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R' } ++ [_]u8{0} ** 8;
    std.mem.writeInt(u32, png[16..20], w, .big);
    std.mem.writeInt(u32, png[20..24], h, .big);
    return png;
}

test "CBDT index format 3 (u16 offsets) with image format 17" {
    const png = fakePng(2, 3);
    // CBDT: two format-17 records (small metrics + u32 len + PNG).
    var cbdt_b = TableBuilder{};
    defer cbdt_b.deinit();
    _ = cbdt_b.u8v(3).u8v(2).u8v(1).u8v(3).u8v(2).u32v(png.len).raw(&png); // gid 1: h3 w2 bx1 by3 adv2
    const rec_len: u16 = @intCast(cbdt_b.bytes.items.len);
    _ = cbdt_b.u8v(3).u8v(2).u8v(0).u8v(1).u8v(2).u32v(png.len).raw(&png); // gid 2: by 1
    const cbdt_data = cbdt_b.bytes.items;

    // Index subtable: format 3, image format 17, offsets [0, rec, 2*rec].
    var sub = TableBuilder{};
    defer sub.deinit();
    _ = sub.u16v(3).u16v(17).u32v(0).u16v(0).u16v(rec_len).u16v(rec_len * 2);

    var cblc_b = TableBuilder{};
    defer cblc_b.deinit();
    const parsed = try Cbdt.parse(cblc_b.cblc(1, 2, 64, 32, sub.bytes.items), cbdt_data);

    const g1 = parsed.glyphBitmap(1).?;
    try testing.expectEqual(@as(u32, 2), g1.width_px);
    try testing.expectEqual(@as(u32, 3), g1.height_px);
    try testing.expectApproxEqAbs(@as(f64, 1), g1.bearing_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), g1.bottom_y, 1e-9); // by 3 - h 3
    const g2 = parsed.glyphBitmap(2).?;
    try testing.expectApproxEqAbs(@as(f64, -2), g2.bottom_y, 1e-9); // by 1 - h 3
    try testing.expect(parsed.glyphBitmap(3) == null);
}

test "CBDT index format 4 (sparse pairs) with image format 17" {
    const png = fakePng(4, 4);
    var cbdt_b = TableBuilder{};
    defer cbdt_b.deinit();
    _ = cbdt_b.u8v(4).u8v(4).u8v(0).u8v(4).u8v(4).u32v(png.len).raw(&png);
    const rec_len: u16 = @intCast(cbdt_b.bytes.items.len);
    _ = cbdt_b.u8v(4).u8v(4).u8v(0).u8v(4).u8v(4).u32v(png.len).raw(&png);
    const cbdt_data = cbdt_b.bytes.items;

    // Format 4: numGlyphs, (gid, offset) pairs + sentinel pair.
    var sub = TableBuilder{};
    defer sub.deinit();
    _ = sub.u16v(4).u16v(17).u32v(0).u32v(2);
    _ = sub.u16v(5).u16v(0).u16v(9).u16v(rec_len).u16v(0).u16v(rec_len * 2);

    var cblc_b = TableBuilder{};
    defer cblc_b.deinit();
    const parsed = try Cbdt.parse(cblc_b.cblc(5, 9, 64, 32, sub.bytes.items), cbdt_data);

    try testing.expect(parsed.glyphBitmap(5) != null);
    try testing.expect(parsed.glyphBitmap(9) != null);
    try testing.expect(parsed.glyphBitmap(7) == null); // in range but not in the pair list
}

test "CBDT index format 5 (constant size) with image format 19" {
    const png = fakePng(8, 8);
    // Image format 19: u32 dataLen + PNG only; metrics come from the index.
    var cbdt_b = TableBuilder{};
    defer cbdt_b.deinit();
    _ = cbdt_b.u32v(png.len).raw(&png);
    const image_size: u32 = @intCast(cbdt_b.bytes.items.len);
    _ = cbdt_b.u32v(png.len).raw(&png);
    const cbdt_data = cbdt_b.bytes.items;

    // Format 5: imageSize, BigGlyphMetrics (h8 w8 bx0 by8 ...), numGlyphs, gids.
    var sub = TableBuilder{};
    defer sub.deinit();
    _ = sub.u16v(5).u16v(19).u32v(0).u32v(image_size);
    _ = sub.u8v(8).u8v(8).u8v(0).u8v(8).u8v(8).u8v(0).u8v(0).u8v(8); // big metrics
    _ = sub.u32v(2).u16v(3).u16v(7); // two glyphs: gids 3 and 7

    var cblc_b = TableBuilder{};
    defer cblc_b.deinit();
    const parsed = try Cbdt.parse(cblc_b.cblc(3, 7, 32, 32, sub.bytes.items), cbdt_data);

    const g7 = parsed.glyphBitmap(7).?;
    try testing.expectEqual(@as(u32, 8), g7.width_px);
    try testing.expectApproxEqAbs(@as(f64, 0), g7.bottom_y, 1e-9); // by 8 - h 8
    try testing.expect(parsed.glyphBitmap(5) == null); // in range, not in gid list
}

test "EBDT image formats 6 and 7 (big metrics, byte/bit-aligned mono)" {
    // Glyph 1: format 6, 3x2 byte-aligned rows; glyph 2: format 7, 3x2
    // bit-aligned (6 bits → 1 byte).
    var ebdt_b = TableBuilder{};
    defer ebdt_b.deinit();
    _ = ebdt_b.u8v(2).u8v(3).u8v(0).u8v(2).u8v(3).u8v(0).u8v(0).u8v(2); // big metrics h2 w3
    _ = ebdt_b.u8v(0b1010_0000).u8v(0b0100_0000); // rows: 101 / 010
    const rec1_len: u32 = @intCast(ebdt_b.bytes.items.len);
    _ = ebdt_b.u8v(2).u8v(3).u8v(0).u8v(2).u8v(3).u8v(0).u8v(0).u8v(2);
    _ = ebdt_b.u8v(0b1010_1000); // 101 010 packed continuously
    const ebdt_data = ebdt_b.bytes.items;

    // Two subtables would need two array entries; use one glyph per test
    // via two parses instead.
    inline for (.{ .{ 6, 0, rec1_len }, .{ 7, rec1_len, @as(u32, @intCast(ebdt_data.len)) } }, 0..) |case, i| {
        var sub = TableBuilder{};
        defer sub.deinit();
        _ = sub.u16v(1).u16v(case[0]).u32v(0).u32v(case[1]).u32v(case[2]);
        var cblc_b = TableBuilder{};
        defer cblc_b.deinit();
        const parsed = try Cbdt.parse(cblc_b.cblc(1, 1, 16, 1, sub.bytes.items), ebdt_data);
        const g = parsed.glyphBitmap(1).?;
        try testing.expectEqual(@as(u32, 3), g.width_px);
        try testing.expectEqual(@as(u32, 2), g.height_px);
        const mono = g.pixels.mono;
        try testing.expectEqual(i == 1, mono.bit_aligned);
        // Both decode to the same byte-aligned rows.
        const rows = try packMonoRows(testing.allocator, mono, 3, 2);
        defer testing.allocator.free(rows);
        try testing.expectEqualSlices(u8, &.{ 0b1010_0000, 0b0100_0000 }, rows);
    }
}

test "pngDimensions rejects non-PNG data" {
    try testing.expect(pngDimensions("not a png at all, sorry") == null);
    try testing.expect(pngDimensions("") == null);
}
