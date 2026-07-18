//! OpenType 'SVG ' table: per-glyph SVG documents (OT-SVG color fonts).
//!
//! Provides the raw SVG document covering a glyph so higher layers can
//! render it through the svg.zig parser into a Type3 CharProc. OT-SVG
//! glyph space is y-down with the origin at the glyph origin, which matches
//! svg.zig's output flip (`1 0 0 -1 0 0`) when the document declares no
//! width/height/viewBox — as OT-SVG documents do.
//!
//! Limits: gzip-compressed documents and documents spanning multiple glyph
//! ids are not supported (the affected glyphs fall back to their mono
//! outlines).

const std = @import("std");
const colr = @import("colr.zig");

const readU16 = colr.readU16;
const readU32 = colr.readU32;

pub const SvgTable = struct {
    data: []const u8,
    doc_list_off: usize,
    num_entries: u16,

    pub fn parse(data: []const u8) !SvgTable {
        // Header: u16 version, Offset32 svgDocumentListOffset, u32 reserved.
        if (data.len < 10) return error.InvalidSvgTable;
        const doc_list_off = readU32(data, 2);
        if (doc_list_off + 2 > data.len) return error.InvalidSvgTable;
        // SVGDocumentList: u16 numEntries, then SVGDocumentRecord[numEntries].
        const num_entries = readU16(data, doc_list_off);
        return .{ .data = data, .doc_list_off = doc_list_off, .num_entries = num_entries };
    }

    /// The uncompressed SVG document covering exactly `gid`, or null (no
    /// record, gzipped, or a multi-glyph document).
    pub fn docForGlyph(self: SvgTable, gid: u16) ?[]const u8 {
        for (0..self.num_entries) |i| {
            // SVGDocumentRecord: u16 startGlyphID, u16 endGlyphID,
            // Offset32 svgDocOffset, u32 svgDocLength (offsets relative to
            // the SVGDocumentList).
            const rec = self.doc_list_off + 2 + i * 12;
            const start = readU16(self.data, rec);
            const end = readU16(self.data, rec + 2);
            if (gid < start or gid > end) continue;
            if (start != end) return null; // multi-glyph documents unsupported
            const off = self.doc_list_off + readU32(self.data, rec + 4);
            const len = readU32(self.data, rec + 8);
            if (len < 2 or off + len > self.data.len) return null;
            const doc = self.data[off .. off + len];
            if (doc[0] == 0x1F and doc[1] == 0x8B) return null; // gzip unsupported
            return doc;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SVG table doc lookup (Bungee Color SVG)" {
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/Bungee Color/BungeeColor-Regular-SVG.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;

    const table = try SvgTable.parse(font.getTable("SVG ".*).?);
    try testing.expectEqual(@as(u16, 288), table.num_entries);

    // 'A' (gid 43): a single-glyph document with two solid-fill paths
    // (Bungee's dark-red fill + salmon inline).
    const doc = table.docForGlyph(43) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, doc, "id=\"glyph43\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "fill=\"#c90900\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "fill=\"#ff9580\"") != null);

    // Gid outside every record has no document.
    try testing.expect(table.docForGlyph(0xFFFF) == null);
}

test "SVG table fallback cases (SvgTest fixture)" {
    // Fixture built by scripts/gen_svg_font.py: gid 1 = supported doc,
    // gid 2 = doc with fill-opacity, gid 3 = gzipped doc, gids 4-5 = one
    // multi-glyph document.
    const ttf = @import("ttf.zig");
    const loaded = ttf.Font.fromFile(testing.io, testing.allocator, "test/fonts/svg/SvgTest.ttf") catch return error.SkipZigTest;
    defer testing.allocator.free(loaded.data);
    var font = loaded.font;

    const table = try SvgTable.parse(font.getTable("SVG ".*).?);
    // Supported and opacity docs are returned (opacity is judged later by
    // the SVG renderer, not here).
    try testing.expect(table.docForGlyph(1) != null);
    try testing.expect(table.docForGlyph(2) != null);
    // Gzip-compressed documents are unsupported.
    try testing.expect(table.docForGlyph(3) == null);
    // Multi-glyph-range documents are unsupported (both covered gids).
    try testing.expect(table.docForGlyph(4) == null);
    try testing.expect(table.docForGlyph(5) == null);
}
