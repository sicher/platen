//! Embedded Font Support
//!
//! Handles TrueType font embedding in PDF documents.
//! Uses WinAnsiEncoding (Windows-1252) for simple single-byte text.

const std = @import("std");
const ttf = @import("ttf.zig");

/// WinAnsiEncoding (Windows-1252) to Unicode mapping.
/// Maps byte values 0-255 to Unicode codepoints.
/// Values 0x00-0x7F are identical to ASCII.
/// Values 0x80-0x9F contain special characters (not defined in Latin-1).
/// Values 0xA0-0xFF are Latin-1 Supplement.
pub const win_ansi_to_unicode: [256]u21 = blk: {
    var map: [256]u21 = undefined;

    // 0x00-0x7F: ASCII (identical)
    for (0..128) |i| {
        map[i] = @intCast(i);
    }

    // 0x80-0x9F: Windows-1252 specific characters
    map[0x80] = 0x20AC; // Euro sign
    map[0x81] = 0xFFFD; // Undefined (use replacement char)
    map[0x82] = 0x201A; // Single low-9 quotation mark
    map[0x83] = 0x0192; // Latin small letter f with hook
    map[0x84] = 0x201E; // Double low-9 quotation mark
    map[0x85] = 0x2026; // Horizontal ellipsis
    map[0x86] = 0x2020; // Dagger
    map[0x87] = 0x2021; // Double dagger
    map[0x88] = 0x02C6; // Modifier letter circumflex accent
    map[0x89] = 0x2030; // Per mille sign
    map[0x8A] = 0x0160; // Latin capital letter S with caron
    map[0x8B] = 0x2039; // Single left-pointing angle quotation mark
    map[0x8C] = 0x0152; // Latin capital ligature OE
    map[0x8D] = 0xFFFD; // Undefined
    map[0x8E] = 0x017D; // Latin capital letter Z with caron
    map[0x8F] = 0xFFFD; // Undefined
    map[0x90] = 0xFFFD; // Undefined
    map[0x91] = 0x2018; // Left single quotation mark
    map[0x92] = 0x2019; // Right single quotation mark
    map[0x93] = 0x201C; // Left double quotation mark
    map[0x94] = 0x201D; // Right double quotation mark
    map[0x95] = 0x2022; // Bullet
    map[0x96] = 0x2013; // En dash
    map[0x97] = 0x2014; // Em dash
    map[0x98] = 0x02DC; // Small tilde
    map[0x99] = 0x2122; // Trade mark sign
    map[0x9A] = 0x0161; // Latin small letter s with caron
    map[0x9B] = 0x203A; // Single right-pointing angle quotation mark
    map[0x9C] = 0x0153; // Latin small ligature oe
    map[0x9D] = 0xFFFD; // Undefined
    map[0x9E] = 0x017E; // Latin small letter z with caron
    map[0x9F] = 0x0178; // Latin capital letter Y with diaeresis

    // 0xA0-0xFF: Latin-1 Supplement (identical to Unicode)
    for (0xA0..256) |i| {
        map[i] = @intCast(i);
    }

    break :blk map;
};

/// Font flags for FontDescriptor
pub const FontFlags = packed struct(u32) {
    fixed_pitch: bool = false, // Bit 0: All glyphs have same width
    serif: bool = false, // Bit 1: Serifs present
    symbolic: bool = false, // Bit 2: Non-standard character set
    script: bool = false, // Bit 3: Script/cursive font
    _reserved4: bool = false,
    nonsymbolic: bool = true, // Bit 5: Uses standard Latin encoding
    italic: bool = false, // Bit 6: Italic or oblique
    _reserved7_15: u9 = 0,
    all_cap: bool = false, // Bit 16: No lowercase
    small_cap: bool = false, // Bit 17: Lowercase are small caps
    _reserved18_31: u14 = 0,

    pub fn toInt(self: FontFlags) u32 {
        return @bitCast(self);
    }
};

/// Embedded TrueType font for PDF
pub const EmbeddedFont = struct {
    name: []const u8, // PostScript name for PDF
    data: []const u8, // Raw TTF data (for FontFile2)
    font: ttf.Font, // Parsed font
    widths: [256]u16, // Widths in 1/1000 em for WinAnsi chars
    allocator: std.mem.Allocator,
    owns_data: bool, // Whether we own the TTF data

    // Metrics scaled to 1000 units (PDF standard)
    ascent: i16,
    descent: i16,
    cap_height: i16,
    bbox: [4]i16, // [x_min, y_min, x_max, y_max]
    italic_angle: i16,
    stem_v: u16,
    flags: FontFlags,

    // Subsetting support
    used_chars: [256]bool = [_]bool{false} ** 256, // Track which WinAnsi chars are used
    subset_data: ?[]const u8 = null, // Generated subset TTF (lazily created)

    /// Load and parse a TTF font from file
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !*EmbeddedFont {
        const result = try ttf.Font.fromFile(allocator, path);
        return try fromParsed(allocator, result.font, result.data, true);
    }

    /// Create from already-parsed font
    pub fn fromParsed(
        allocator: std.mem.Allocator,
        font: ttf.Font,
        data: []const u8,
        owns_data: bool,
    ) !*EmbeddedFont {
        const head = font.head orelse return error.MissingTable;
        const hhea = font.hhea orelse return error.MissingTable;

        const units_per_em = head.units_per_em;
        if (units_per_em == 0) return error.InvalidFont;

        // Scale factor: convert from font units to 1000 units
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(units_per_em));

        // Build widths array for WinAnsiEncoding
        var widths: [256]u16 = undefined;
        for (0..256) |i| {
            const unicode = win_ansi_to_unicode[i];
            if (font.getCharWidth(unicode)) |w| {
                // Round to nearest integer (matches fpdf2 behavior)
                widths[i] = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
            } else {
                // Use zero width for missing glyphs
                widths[i] = 0;
            }
        }

        // Scale metrics (round to nearest integer)
        const ascent: i16 = @intFromFloat(@round(@as(f64, @floatFromInt(hhea.ascent)) * scale));
        const descent: i16 = @intFromFloat(@round(@as(f64, @floatFromInt(hhea.descent)) * scale));

        // Estimate CapHeight as 70% of ascent if not available
        // (Would need OS/2 table for accurate value)
        const cap_height: i16 = @intFromFloat(@round(@as(f64, @floatFromInt(ascent)) * 0.7));

        // Scale bounding box
        const bbox: [4]i16 = .{
            @intFromFloat(@round(@as(f64, @floatFromInt(head.x_min)) * scale)),
            @intFromFloat(@round(@as(f64, @floatFromInt(head.y_min)) * scale)),
            @intFromFloat(@round(@as(f64, @floatFromInt(head.x_max)) * scale)),
            @intFromFloat(@round(@as(f64, @floatFromInt(head.y_max)) * scale)),
        };

        // Estimate StemV (vertical stem width) - typically 80 for normal, higher for bold
        // Would need proper stem detection for accuracy
        const stem_v: u16 = 80;

        // Determine flags from font properties
        var flags = FontFlags{};

        // Check if monospace (compare widths of 'i' and 'm')
        const width_i = font.getCharWidth('i');
        const width_m = font.getCharWidth('m');
        if (width_i != null and width_m != null and width_i.? == width_m.?) {
            flags.fixed_pitch = true;
        }

        // Get PostScript name for PDF BaseFont (preferred)
        // Fall back to family name + style if PostScript name not available
        const ps_name = font.getPostScriptName() orelse font.getFamilyName() orelse "Unknown";

        // Allocate and copy name (may be UTF-16, need to decode)
        const name = try allocator.dupe(u8, decodeFontName(ps_name));

        const embedded = try allocator.create(EmbeddedFont);
        embedded.* = .{
            .name = name,
            .data = data,
            .font = font,
            .widths = widths,
            .allocator = allocator,
            .owns_data = owns_data,
            .ascent = ascent,
            .descent = descent,
            .cap_height = cap_height,
            .bbox = bbox,
            .italic_angle = 0,
            .stem_v = stem_v,
            .flags = flags,
        };

        return embedded;
    }

    pub fn deinit(self: *EmbeddedFont) void {
        self.allocator.free(self.name);
        if (self.subset_data) |subset| {
            self.allocator.free(subset);
        }
        if (self.owns_data) {
            self.allocator.free(self.data);
        }
        self.allocator.destroy(self);
    }

    /// Mark characters as used (call this when text is written)
    pub fn markCharsUsed(self: *EmbeddedFont, text: []const u8) void {
        for (text) |c| {
            self.used_chars[c] = true;
        }
    }

    /// Get the number of used characters
    pub fn countUsedChars(self: *const EmbeddedFont) usize {
        var count: usize = 0;
        for (self.used_chars) |used| {
            if (used) count += 1;
        }
        return count;
    }

    /// Get font data for PDF embedding (subset if available, else full)
    pub fn getFontData(self: *EmbeddedFont) []const u8 {
        return self.subset_data orelse self.data;
    }

    /// Generate subset font data containing only used glyphs
    pub fn generateSubset(self: *EmbeddedFont) !void {
        // If already generated or no chars used, skip
        if (self.subset_data != null) return;
        if (self.countUsedChars() == 0) return;

        self.subset_data = try createSubsetTTF(self.allocator, self);
    }

    /// Get character width for a byte value (WinAnsi encoded)
    pub fn getCharWidth(self: *const EmbeddedFont, char: u8) u16 {
        return self.widths[char];
    }

    /// Get text width in points
    pub fn measureTextWidth(self: *const EmbeddedFont, text: []const u8, size: f64) f64 {
        var total: u32 = 0;
        for (text) |c| {
            total += self.widths[c];
        }
        return @as(f64, @floatFromInt(total)) * size / 1000.0;
    }

    /// Generate ToUnicode CMap for PDF text extraction/copy-paste
    /// Maps WinAnsi byte values to Unicode codepoints
    pub fn generateToUnicodeCMap(self: *const EmbeddedFont) ![]const u8 {
        var cmap = std.ArrayListUnmanaged(u8){};
        errdefer cmap.deinit(self.allocator);

        // CMap header
        try cmap.appendSlice(self.allocator,
            \\/CIDInit /ProcSet findresource begin
            \\12 dict begin
            \\begincmap
            \\/CIDSystemInfo
            \\<</Registry (Adobe)
            \\/Ordering (UCS)
            \\/Supplement 0
            \\>> def
            \\/CMapName /Adobe-Identity-UCS def
            \\/CMapType 2 def
            \\1 begincodespacerange
            \\<00> <FF>
            \\endcodespacerange
            \\
        );

        // Count used characters (excluding undefined ones mapping to U+FFFD)
        var count: usize = 0;
        for (0..256) |i| {
            if (self.used_chars[i] and win_ansi_to_unicode[i] != 0xFFFD) {
                count += 1;
            }
        }

        // Write bfchar entries
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} beginbfchar\n", .{count}) catch unreachable;
        try cmap.appendSlice(self.allocator, count_str);

        for (0..256) |i| {
            if (self.used_chars[i] and win_ansi_to_unicode[i] != 0xFFFD) {
                const unicode = win_ansi_to_unicode[i];
                var entry_buf: [32]u8 = undefined;
                const entry = std.fmt.bufPrint(&entry_buf, "<{X:0>2}> <{X:0>4}>\n", .{ i, unicode }) catch unreachable;
                try cmap.appendSlice(self.allocator, entry);
            }
        }

        // CMap footer
        try cmap.appendSlice(self.allocator,
            \\endbfchar
            \\endcmap
            \\CMapName currentdict /CMap defineresource pop
            \\end
            \\end
        );

        return cmap.toOwnedSlice(self.allocator);
    }
};

/// Decode font name (handles UTF-16BE from Windows platform)
fn decodeFontName(raw: []const u8) []const u8 {
    // Simple heuristic: if it looks like UTF-16BE (null bytes), decode it
    if (raw.len >= 2 and raw.len % 2 == 0) {
        var has_nulls = false;
        for (raw, 0..) |b, i| {
            if (b == 0 and i % 2 == 0) {
                has_nulls = true;
                break;
            }
        }
        if (has_nulls) {
            // This is likely UTF-16BE, extract ASCII portion
            // For now, just skip null bytes (works for ASCII names)
            var result: [256]u8 = undefined;
            var len: usize = 0;
            var i: usize = 0;
            while (i + 1 < raw.len and len < 255) : (i += 2) {
                if (raw[i] == 0 and raw[i + 1] >= 0x20 and raw[i + 1] < 0x7F) {
                    result[len] = raw[i + 1];
                    len += 1;
                }
            }
            if (len > 0) {
                return result[0..len];
            }
        }
    }
    return raw;
}

/// Create a subset TTF containing only the used glyphs
fn createSubsetTTF(allocator: std.mem.Allocator, emb: *const EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const head = font.head orelse return error.MissingTable;
    const hhea = font.hhea orelse return error.MissingTable;
    _ = font.maxp orelse return error.MissingTable; // verify table exists

    // Build mapping: WinAnsi char → original glyph ID
    // And collect unique glyph IDs we need
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    // Always include glyph 0 (.notdef)
    try glyph_set.put(allocator, 0, {});

    for (0..256) |i| {
        if (emb.used_chars[i]) {
            const unicode = win_ansi_to_unicode[i];
            if (font.getGlyphId(unicode)) |gid| {
                try glyph_set.put(allocator, gid, {});
            }
        }
    }

    // Sort glyph IDs and create old→new mapping
    var glyph_ids = try allocator.alloc(u16, glyph_set.count());
    defer allocator.free(glyph_ids);

    var idx: usize = 0;
    var it = glyph_set.keyIterator();
    while (it.next()) |gid| {
        glyph_ids[idx] = gid.*;
        idx += 1;
    }
    std.mem.sort(u16, glyph_ids, {}, std.sort.asc(u16));

    // Create old_gid → new_gid mapping
    var gid_map = std.AutoHashMapUnmanaged(u16, u16){};
    defer gid_map.deinit(allocator);
    for (glyph_ids, 0..) |old_gid, new_gid| {
        try gid_map.put(allocator, old_gid, @intCast(new_gid));
    }

    const num_glyphs: u16 = @intCast(glyph_ids.len);

    // Get original table data
    const orig_glyf = font.getTable("glyf".*) orelse return error.MissingTable;
    const orig_loca = font.getTable("loca".*) orelse return error.MissingTable;
    const orig_hmtx = font.getTable("hmtx".*) orelse return error.MissingTable;

    const loca_format = head.index_to_loc_format; // 0=short, 1=long

    // Build new glyf data
    var new_glyf = std.ArrayListUnmanaged(u8){};
    defer new_glyf.deinit(allocator);

    // Build new loca (offsets into glyf)
    var new_loca = std.ArrayListUnmanaged(u8){};
    defer new_loca.deinit(allocator);

    for (glyph_ids) |old_gid| {
        // Record offset in new loca
        const offset: u32 = @intCast(new_glyf.items.len);
        if (loca_format == 0) {
            // Short format: offset / 2
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(offset / 2))));
        } else {
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, offset)));
        }

        // Get glyph bounds from original loca
        const glyph_start = getLocaOffset(orig_loca, old_gid, loca_format);
        const glyph_end = getLocaOffset(orig_loca, old_gid + 1, loca_format);

        if (glyph_end > glyph_start and glyph_end <= orig_glyf.len) {
            const glyph_data = orig_glyf[glyph_start..glyph_end];
            try new_glyf.appendSlice(allocator, glyph_data);
        }
    }

    // Final loca entry (end of last glyph)
    const final_offset: u32 = @intCast(new_glyf.items.len);
    if (loca_format == 0) {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(final_offset / 2))));
    } else {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, final_offset)));
    }

    // Build new hmtx (horizontal metrics)
    var new_hmtx = std.ArrayListUnmanaged(u8){};
    defer new_hmtx.deinit(allocator);

    for (glyph_ids) |old_gid| {
        // Get advance width and lsb
        var advance: u16 = 0;
        var lsb: i16 = 0;

        if (old_gid < hhea.num_of_long_hor_metrics) {
            const off = @as(usize, old_gid) * 4;
            if (off + 4 <= orig_hmtx.len) {
                advance = readU16(orig_hmtx, off);
                lsb = readI16(orig_hmtx, off + 2);
            }
        } else {
            // Use last advance width
            if (hhea.num_of_long_hor_metrics > 0) {
                const off = (@as(usize, hhea.num_of_long_hor_metrics) - 1) * 4;
                if (off + 2 <= orig_hmtx.len) {
                    advance = readU16(orig_hmtx, off);
                }
            }
            // lsb from separate array
            const lsb_idx = old_gid - hhea.num_of_long_hor_metrics;
            const lsb_off = @as(usize, hhea.num_of_long_hor_metrics) * 4 + @as(usize, lsb_idx) * 2;
            if (lsb_off + 2 <= orig_hmtx.len) {
                lsb = readI16(orig_hmtx, lsb_off);
            }
        }

        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, advance)));
        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, lsb)));
    }

    // Build cmap with both Format 0 (MacRoman) and Format 4 (Windows Unicode BMP)
    // PDF viewers with WinAnsiEncoding use Platform 3, Encoding 1 (Format 4)
    var new_cmap = std.ArrayListUnmanaged(u8){};
    defer new_cmap.deinit(allocator);

    // First, build the Format 4 subtable for Windows Unicode BMP
    // This maps Unicode codepoints to glyph IDs
    var format4 = std.ArrayListUnmanaged(u8){};
    defer format4.deinit(allocator);

    // Collect Unicode -> new glyph ID mappings for used characters
    const UnicodeMapping = struct { unicode: u16, glyph_id: u16 };
    var unicode_mappings = std.ArrayListUnmanaged(UnicodeMapping){};
    defer unicode_mappings.deinit(allocator);

    for (0..256) |i| {
        if (emb.used_chars[i]) {
            const unicode = win_ansi_to_unicode[i];
            if (unicode != 0xFFFD and unicode <= 0xFFFF) { // Valid BMP codepoint
                const orig_gid = font.getGlyphId(unicode) orelse 0;
                const new_gid = gid_map.get(orig_gid) orelse 0;
                try unicode_mappings.append(allocator, .{
                    .unicode = @intCast(unicode),
                    .glyph_id = new_gid,
                });
            }
        }
    }

    // Sort by Unicode codepoint
    std.mem.sort(UnicodeMapping, unicode_mappings.items, {}, struct {
        fn lessThan(_: void, a: UnicodeMapping, b: UnicodeMapping) bool {
            return a.unicode < b.unicode;
        }
    }.lessThan);

    // Build segments - for simplicity, one segment per character
    // Plus the required final segment (0xFFFF -> 0xFFFF)
    const seg_count: u16 = @intCast(unicode_mappings.items.len + 1);
    const seg_count_x2: u16 = seg_count * 2;

    // Calculate searchRange, entrySelector, rangeShift
    var search_range: u16 = 2;
    var entry_selector: u16 = 0;
    while (search_range * 2 <= seg_count) {
        search_range *= 2;
        entry_selector += 1;
    }
    search_range *= 2; // searchRange = 2 * (2^floor(log2(segCount)))
    const range_shift = seg_count_x2 - search_range;

    // Format 4 header
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 4))); // format
    // Length will be filled in later
    const format4_length_pos = format4.items.len;
    try format4.appendSlice(allocator, &[_]u8{ 0, 0 }); // length placeholder
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // language
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, seg_count_x2)));
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, search_range)));
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, entry_selector)));
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, range_shift)));

    // endCode array
    for (unicode_mappings.items) |m| {
        try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, m.unicode)));
    }
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // final segment

    // reservedPad
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0)));

    // startCode array (same as endCode for single-char segments)
    for (unicode_mappings.items) |m| {
        try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, m.unicode)));
    }
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // final segment

    // idDelta array - we'll use idRangeOffset instead, so delta is 0
    // Actually, for single-char segments, we can use: delta = glyphId - charCode
    for (unicode_mappings.items) |m| {
        const delta: i16 = @as(i16, @intCast(m.glyph_id)) - @as(i16, @intCast(m.unicode));
        try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, delta)));
    }
    try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, 1))); // final segment delta

    // idRangeOffset array (all zeros since we use idDelta)
    for (0..seg_count) |_| {
        try format4.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0)));
    }

    // No glyphIdArray needed since we use idDelta

    // Update format4 length
    std.mem.writeInt(u16, format4.items[format4_length_pos..][0..2], @intCast(format4.items.len), .big);

    // Now build the complete cmap table with 2 encoding records
    // cmap header: version 0, 2 encoding tables
    try new_cmap.appendSlice(allocator, &[_]u8{ 0, 0, 0, 2 });

    // Encoding record 1: Platform 1 (Mac), Encoding 0 (Roman)
    // Offset = 4 (header) + 16 (2 records) = 20
    const format0_offset: u32 = 20;
    try new_cmap.appendSlice(allocator, &[_]u8{ 0, 1, 0, 0 }); // platform 1, encoding 0
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, format0_offset)));

    // Encoding record 2: Platform 3 (Windows), Encoding 1 (Unicode BMP)
    // Offset = 20 + 262 (format0 size) = 282
    const format4_offset: u32 = 20 + 262;
    try new_cmap.appendSlice(allocator, &[_]u8{ 0, 3, 0, 1 }); // platform 3, encoding 1
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, format4_offset)));

    // Format 0 subtable (for MacRoman compatibility)
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // format
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 262))); // length
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // language

    // Format 0 glyph index array (256 bytes) - maps byte value to glyph
    for (0..256) |i| {
        const unicode = win_ansi_to_unicode[i];
        const orig_gid = font.getGlyphId(unicode) orelse 0;
        const new_gid = gid_map.get(orig_gid) orelse 0;
        try new_cmap.append(allocator, @intCast(new_gid));
    }

    // Append Format 4 subtable
    try new_cmap.appendSlice(allocator, format4.items);

    // Now assemble the final TTF
    // Tables needed: head, hhea, maxp, hmtx, cmap, loca, glyf, name, post
    const table_count: u16 = 9;

    // Calculate table sizes and offsets
    const header_size: usize = 12 + @as(usize, table_count) * 16;

    // Copy and modify required tables
    const orig_head = font.getTable("head".*) orelse return error.MissingTable;
    const orig_hhea = font.getTable("hhea".*) orelse return error.MissingTable;
    const orig_name = font.getTable("name".*);
    const orig_post = font.getTable("post".*);

    // Modify head: update checksum adjustment later
    const new_head = try allocator.alloc(u8, orig_head.len);
    defer allocator.free(new_head);
    @memcpy(new_head, orig_head);

    // Modify hhea: update numOfLongHorMetrics
    const new_hhea = try allocator.alloc(u8, orig_hhea.len);
    defer allocator.free(new_hhea);
    @memcpy(new_hhea, orig_hhea);
    std.mem.writeInt(u16, new_hhea[34..36], num_glyphs, .big);

    // Build maxp
    var new_maxp: [6]u8 = undefined;
    std.mem.writeInt(u32, new_maxp[0..4], 0x00005000, .big); // version 0.5
    std.mem.writeInt(u16, new_maxp[4..6], num_glyphs, .big);

    // Pad tables to 4-byte boundaries
    const head_padded = padTo4(new_head.len);
    const hhea_padded = padTo4(new_hhea.len);
    const maxp_padded = padTo4(new_maxp.len);
    const hmtx_padded = padTo4(new_hmtx.items.len);
    const cmap_padded = padTo4(new_cmap.items.len);
    const loca_padded = padTo4(new_loca.items.len);
    const glyf_padded = padTo4(new_glyf.items.len);
    const name_len = if (orig_name) |n| n.len else 0;
    const name_padded = padTo4(name_len);
    const post_len = if (orig_post) |p| @min(p.len, 32) else 32;
    const post_padded = padTo4(post_len);

    var offset: u32 = @intCast(header_size);
    const head_offset = offset;
    offset += @intCast(head_padded);
    const hhea_offset = offset;
    offset += @intCast(hhea_padded);
    const maxp_offset = offset;
    offset += @intCast(maxp_padded);
    const hmtx_offset = offset;
    offset += @intCast(hmtx_padded);
    const cmap_offset = offset;
    offset += @intCast(cmap_padded);
    const loca_offset = offset;
    offset += @intCast(loca_padded);
    const glyf_offset = offset;
    offset += @intCast(glyf_padded);
    const name_offset = offset;
    offset += @intCast(name_padded);
    const post_offset = offset;
    offset += @intCast(post_padded);

    const total_size = offset;

    // Allocate output buffer
    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    // Write TTF header
    std.mem.writeInt(u32, output[0..4], 0x00010000, .big); // sfnt version
    std.mem.writeInt(u16, output[4..6], table_count, .big);
    // searchRange, entrySelector, rangeShift for table directory
    const ttf_search_range: u16 = 128; // 8 * 16
    const ttf_entry_selector: u16 = 3; // log2(8)
    const ttf_range_shift: u16 = table_count * 16 - ttf_search_range;
    std.mem.writeInt(u16, output[6..8], ttf_search_range, .big);
    std.mem.writeInt(u16, output[8..10], ttf_entry_selector, .big);
    std.mem.writeInt(u16, output[10..12], ttf_range_shift, .big);

    // Write table directory
    var dir_offset: usize = 12;
    writeTableEntry(output, &dir_offset, "cmap", cmap_offset, @intCast(new_cmap.items.len));
    writeTableEntry(output, &dir_offset, "glyf", glyf_offset, @intCast(new_glyf.items.len));
    writeTableEntry(output, &dir_offset, "head", head_offset, @intCast(new_head.len));
    writeTableEntry(output, &dir_offset, "hhea", hhea_offset, @intCast(new_hhea.len));
    writeTableEntry(output, &dir_offset, "hmtx", hmtx_offset, @intCast(new_hmtx.items.len));
    writeTableEntry(output, &dir_offset, "loca", loca_offset, @intCast(new_loca.items.len));
    writeTableEntry(output, &dir_offset, "maxp", maxp_offset, @intCast(new_maxp.len));
    writeTableEntry(output, &dir_offset, "name", name_offset, @intCast(name_len));
    writeTableEntry(output, &dir_offset, "post", post_offset, @intCast(post_len));

    // Copy table data
    @memcpy(output[head_offset..][0..new_head.len], new_head);
    @memcpy(output[hhea_offset..][0..new_hhea.len], new_hhea);
    @memcpy(output[maxp_offset..][0..new_maxp.len], &new_maxp);
    @memcpy(output[hmtx_offset..][0..new_hmtx.items.len], new_hmtx.items);
    @memcpy(output[cmap_offset..][0..new_cmap.items.len], new_cmap.items);
    @memcpy(output[loca_offset..][0..new_loca.items.len], new_loca.items);
    @memcpy(output[glyf_offset..][0..new_glyf.items.len], new_glyf.items);
    if (orig_name) |name_data| {
        @memcpy(output[name_offset..][0..name_data.len], name_data);
    }
    if (orig_post) |post_data| {
        @memcpy(output[post_offset..][0..post_len], post_data[0..post_len]);
    } else {
        // Minimal post table (version 3.0 - no glyph names)
        std.mem.writeInt(u32, output[post_offset..][0..4], 0x00030000, .big);
    }

    return output;
}

fn getLocaOffset(loca: []const u8, glyph_id: u16, format: i16) usize {
    if (format == 0) {
        // Short format: offset / 2
        const off = @as(usize, glyph_id) * 2;
        if (off + 2 > loca.len) return 0;
        return @as(usize, readU16(loca, off)) * 2;
    } else {
        // Long format
        const off = @as(usize, glyph_id) * 4;
        if (off + 4 > loca.len) return 0;
        return readU32(loca, off);
    }
}

fn padTo4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

fn writeTableEntry(output: []u8, dir_offset: *usize, tag: *const [4]u8, offset: u32, length: u32) void {
    @memcpy(output[dir_offset.*..][0..4], tag);
    std.mem.writeInt(u32, output[dir_offset.* + 4 ..][0..4], 0, .big); // checksum placeholder
    std.mem.writeInt(u32, output[dir_offset.* + 8 ..][0..4], offset, .big);
    std.mem.writeInt(u32, output[dir_offset.* + 12 ..][0..4], length, .big);
    dir_offset.* += 16;
}

fn readU16(data: []const u8, offset: usize) u16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readI16(data: []const u8, offset: usize) i16 {
    return @bitCast(readU16(data, offset));
}

fn readU32(data: []const u8, offset: usize) u32 {
    if (offset + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

test "win ansi encoding" {
    // ASCII range
    try std.testing.expectEqual(@as(u21, 'A'), win_ansi_to_unicode['A']);
    try std.testing.expectEqual(@as(u21, ' '), win_ansi_to_unicode[' ']);

    // Special characters
    try std.testing.expectEqual(@as(u21, 0x20AC), win_ansi_to_unicode[0x80]); // Euro
    try std.testing.expectEqual(@as(u21, 0x2014), win_ansi_to_unicode[0x97]); // Em dash

    // Latin-1 supplement
    try std.testing.expectEqual(@as(u21, 0xA0), win_ansi_to_unicode[0xA0]); // NBSP
    try std.testing.expectEqual(@as(u21, 0xFF), win_ansi_to_unicode[0xFF]); // ÿ
}

test "font flags" {
    var flags = FontFlags{};
    try std.testing.expectEqual(@as(u32, 32), flags.toInt()); // Bit 5 (nonsymbolic) set

    flags.fixed_pitch = true;
    try std.testing.expectEqual(@as(u32, 33), flags.toInt()); // Bits 0 and 5

    flags.italic = true;
    try std.testing.expectEqual(@as(u32, 97), flags.toInt()); // Bits 0, 5, 6
}

test "font subsetting" {
    const allocator = std.testing.allocator;

    // Load a font
    const emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
    defer emb.deinit();

    // Mark only a few characters as used
    emb.markCharsUsed("Hello");

    // Verify tracking
    try std.testing.expect(emb.used_chars['H']);
    try std.testing.expect(emb.used_chars['e']);
    try std.testing.expect(emb.used_chars['l']);
    try std.testing.expect(emb.used_chars['o']);
    try std.testing.expect(!emb.used_chars['X']); // Not used

    // Count unique chars
    try std.testing.expectEqual(@as(usize, 4), emb.countUsedChars()); // H, e, l, o

    // Generate subset
    try emb.generateSubset();

    // Verify subset was created and is smaller than original
    try std.testing.expect(emb.subset_data != null);
    const subset = emb.getFontData();
    try std.testing.expect(subset.len < emb.data.len);

    // Subset should be significantly smaller (< 50% of original for small char sets)
    try std.testing.expect(subset.len < emb.data.len / 2);
}

test "subset is valid TTF" {
    const allocator = std.testing.allocator;

    const emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
    defer emb.deinit();

    emb.markCharsUsed("ABC123");
    try emb.generateSubset();

    const subset = emb.getFontData();

    // Verify TTF signature
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, subset[0..4], .big));

    // Parse the subset to verify it's valid
    const parsed = try ttf.Font.parse(subset);
    try std.testing.expect(parsed.head != null);
    try std.testing.expect(parsed.hhea != null);
    try std.testing.expect(parsed.maxp != null);

    // Should have fewer glyphs than original
    const orig_glyphs = emb.font.maxp.?.num_glyphs;
    const subset_glyphs = parsed.maxp.?.num_glyphs;
    try std.testing.expect(subset_glyphs < orig_glyphs);
}

test "ToUnicode CMap generation" {
    const allocator = std.testing.allocator;

    const emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
    defer emb.deinit();

    // Mark a few characters including ASCII and special WinAnsi chars
    emb.markCharsUsed("Hi!");

    const cmap = try emb.generateToUnicodeCMap();
    defer allocator.free(cmap);

    // Check CMap structure
    try std.testing.expect(std.mem.indexOf(u8, cmap, "begincodespacerange") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<00> <FF>") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "beginbfchar") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "endbfchar") != null);

    // Check specific mappings: H=0x48→U+0048, i=0x69→U+0069, !=0x21→U+0021
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<48> <0048>") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<69> <0069>") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<21> <0021>") != null);
}
