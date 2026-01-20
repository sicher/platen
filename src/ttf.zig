//! TrueType Font Parser
//!
//! Parses TTF files to extract metrics for PDF embedding.
//! Reference: https://developer.apple.com/fonts/TrueType-Reference-Manual/

const std = @import("std");

/// TTF parsing errors
pub const Error = error{
    InvalidSignature,
    TableNotFound,
    InvalidTableData,
    UnsupportedFormat,
    OutOfBounds,
};

/// TrueType font
pub const Font = struct {
    data: []const u8,
    tables: TableDirectory,

    // Parsed table data
    head: ?HeadTable = null,
    hhea: ?HheaTable = null,
    maxp: ?MaxpTable = null,

    // Cached cmap lookup (avoids subtable search on every glyph lookup)
    cmap_subtable_offset: u32 = 0,
    cmap_format: u16 = 0,

    // ASCII glyph cache for O(1) lookup of common characters
    ascii_glyphs: [128]u16 = [_]u16{0} ** 128,
    has_ascii_cache: bool = false,

    /// Load a font from file
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !struct { font: Font, data: []const u8 } {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            allocator.free(data);
            return Error.InvalidTableData;
        }

        return .{ .font = try parse(data), .data = data };
    }

    /// Parse font from memory
    pub fn parse(data: []const u8) Error!Font {
        if (data.len < 12) return Error.InvalidSignature;

        const signature = readU32(data, 0);
        // Accept: 0x00010000 (TTF), 'true', 'typ1', 'OTTO' (OTF/CFF)
        if (signature != 0x00010000 and
            signature != 0x74727565 and // 'true'
            signature != 0x74797031 and // 'typ1'
            signature != 0x4F54544F) // 'OTTO'
        {
            return Error.InvalidSignature;
        }

        const num_tables = readU16(data, 4);
        const tables = try TableDirectory.parse(data, num_tables);

        var font = Font{
            .data = data,
            .tables = tables,
        };

        // Parse essential tables
        font.head = font.parseHead();
        font.hhea = font.parseHhea();
        font.maxp = font.parseMaxp();

        // Initialize cmap cache for fast glyph lookups
        font.initCmapCache();

        return font;
    }

    /// Initialize cmap cache - find best subtable once, cache ASCII glyphs
    fn initCmapCache(self: *Font) void {
        const cmap_data = self.getTable("cmap".*) orelse return;
        if (cmap_data.len < 4) return;

        const num_tables = readU16(cmap_data, 2);

        // Find best subtable (prefer format 12 for full Unicode, then format 4)
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const record_offset = 4 + i * 8;
            if (record_offset + 8 > cmap_data.len) break;

            const platform_id = readU16(cmap_data, record_offset);
            const encoding_id = readU16(cmap_data, record_offset + 2);
            const subtable_offset = readU32(cmap_data, record_offset + 4);

            // Accept Unicode platforms
            const is_unicode = (platform_id == 0) or
                (platform_id == 3 and (encoding_id == 1 or encoding_id == 10));

            if (is_unicode and subtable_offset < cmap_data.len) {
                const format = readU16(cmap_data, subtable_offset);
                // Prefer format 12 (full Unicode) over format 4 (BMP only)
                if (format == 12) {
                    self.cmap_subtable_offset = subtable_offset;
                    self.cmap_format = 12;
                    break; // Best possible
                } else if (format == 4 and self.cmap_format == 0) {
                    self.cmap_subtable_offset = subtable_offset;
                    self.cmap_format = 4;
                }
            }
        }

        // Populate ASCII cache if we found a valid subtable
        if (self.cmap_format != 0) {
            const subtable_data = cmap_data[self.cmap_subtable_offset..];
            for (0..128) |cp| {
                const gid = switch (self.cmap_format) {
                    4 => parseCmapFormat4(subtable_data, @intCast(cp)),
                    12 => parseCmapFormat12(subtable_data, @intCast(cp)),
                    else => null,
                };
                self.ascii_glyphs[cp] = gid orelse 0;
            }
            self.has_ascii_cache = true;
        }
    }

    /// Check if this is a CFF-based font (OTF with PostScript outlines)
    pub fn isCFF(self: *const Font) bool {
        // CFF fonts have "CFF " or "CFF2" table, no "glyf" table
        return self.getTable("CFF ".*) != null or self.getTable("CFF2".*) != null;
    }

    /// Check if this is a TrueType font (has glyf outlines)
    pub fn isTrueType(self: *const Font) bool {
        return self.getTable("glyf".*) != null;
    }

    /// Get table data by tag
    pub fn getTable(self: *const Font, tag: [4]u8) ?[]const u8 {
        const entry = self.tables.find(tag) orelse return null;
        if (entry.offset + entry.length > self.data.len) return null;
        return self.data[entry.offset..][0..entry.length];
    }

    /// Parse 'head' table
    fn parseHead(self: *const Font) ?HeadTable {
        const data = self.getTable("head".*) orelse return null;
        if (data.len < 54) return null;

        return HeadTable{
            .units_per_em = readU16(data, 18),
            .x_min = readI16(data, 36),
            .y_min = readI16(data, 38),
            .x_max = readI16(data, 40),
            .y_max = readI16(data, 42),
            .index_to_loc_format = readI16(data, 50),
        };
    }

    /// Parse 'hhea' table
    fn parseHhea(self: *const Font) ?HheaTable {
        const data = self.getTable("hhea".*) orelse return null;
        if (data.len < 36) return null;

        return HheaTable{
            .ascent = readI16(data, 4),
            .descent = readI16(data, 6),
            .line_gap = readI16(data, 8),
            .advance_width_max = readU16(data, 10),
            .num_of_long_hor_metrics = readU16(data, 34),
        };
    }

    /// Parse 'maxp' table
    fn parseMaxp(self: *const Font) ?MaxpTable {
        const data = self.getTable("maxp".*) orelse return null;
        if (data.len < 6) return null;

        return MaxpTable{
            .num_glyphs = readU16(data, 4),
        };
    }

    /// Get glyph width (in font units)
    pub fn getGlyphWidth(self: *const Font, glyph_id: u16) ?u16 {
        const hhea = self.hhea orelse return null;
        const hmtx_data = self.getTable("hmtx".*) orelse return null;

        // hmtx has two parts:
        // 1. longHorMetric[numOfLongHorMetrics] - 4 bytes each (advanceWidth + lsb)
        // 2. leftSideBearing[numGlyphs - numOfLongHorMetrics] - 2 bytes each

        if (glyph_id < hhea.num_of_long_hor_metrics) {
            const offset = @as(usize, glyph_id) * 4;
            if (offset + 2 > hmtx_data.len) return null;
            return readU16(hmtx_data, offset);
        } else {
            // Use last advanceWidth for remaining glyphs
            if (hhea.num_of_long_hor_metrics == 0) return null;
            const offset = (@as(usize, hhea.num_of_long_hor_metrics) - 1) * 4;
            if (offset + 2 > hmtx_data.len) return null;
            return readU16(hmtx_data, offset);
        }
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn getGlyphId(self: *const Font, codepoint: u21) ?u16 {
        // Fast path: ASCII cache (O(1) lookup for most text)
        if (self.has_ascii_cache and codepoint < 128) {
            const gid = self.ascii_glyphs[codepoint];
            return if (gid != 0) gid else null;
        }

        // Use cached subtable if available (skips subtable search)
        if (self.cmap_format != 0) {
            const cmap_data = self.getTable("cmap".*) orelse return null;
            const subtable_data = cmap_data[self.cmap_subtable_offset..];
            return switch (self.cmap_format) {
                4 => parseCmapFormat4(subtable_data, codepoint),
                12 => parseCmapFormat12(subtable_data, codepoint),
                else => null,
            };
        }

        // Fallback: full cmap lookup (only if cache wasn't initialized)
        const cmap_data = self.getTable("cmap".*) orelse return null;
        return parseCmapLookup(cmap_data, codepoint);
    }

    /// Get character width in font units
    pub fn getCharWidth(self: *const Font, codepoint: u21) ?u16 {
        const glyph_id = self.getGlyphId(codepoint) orelse return null;
        return self.getGlyphWidth(glyph_id);
    }

    /// Get font family name
    pub fn getFamilyName(self: *const Font) ?[]const u8 {
        return self.getNameEntry(1); // Family name
    }

    /// Get font subfamily/style name
    pub fn getStyleName(self: *const Font) ?[]const u8 {
        return self.getNameEntry(2); // Subfamily name
    }

    /// Get full font name (e.g., "Courier Prime Bold")
    pub fn getFullName(self: *const Font) ?[]const u8 {
        return self.getNameEntry(4); // Full name
    }

    /// Get PostScript name (e.g., "CourierPrime-Bold")
    pub fn getPostScriptName(self: *const Font) ?[]const u8 {
        return self.getNameEntry(6); // PostScript name
    }

    /// Get name table entry
    fn getNameEntry(self: *const Font, name_id: u16) ?[]const u8 {
        const name_data = self.getTable("name".*) orelse return null;
        if (name_data.len < 6) return null;

        const count = readU16(name_data, 2);
        const string_offset = readU16(name_data, 4);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const record_offset = 6 + i * 12;
            if (record_offset + 12 > name_data.len) break;

            const platform_id = readU16(name_data, record_offset);
            const encoding_id = readU16(name_data, record_offset + 2);
            const record_name_id = readU16(name_data, record_offset + 6);
            const length = readU16(name_data, record_offset + 8);
            const offset = readU16(name_data, record_offset + 10);

            if (record_name_id == name_id) {
                // Prefer platform 3 (Windows), encoding 1 (Unicode BMP)
                // or platform 1 (Macintosh), encoding 0 (Roman)
                if ((platform_id == 3 and encoding_id == 1) or
                    (platform_id == 1 and encoding_id == 0))
                {
                    const str_start = string_offset + offset;
                    if (str_start + length <= name_data.len) {
                        return name_data[str_start..][0..length];
                    }
                }
            }
        }

        return null;
    }
};

/// Table directory - index of all tables in the font
pub const TableDirectory = struct {
    entries: []const TableEntry,
    data: []const u8, // Reference to underlying data for entry access

    pub fn parse(data: []const u8, num_tables: u16) Error!TableDirectory {
        const dir_start: usize = 12;
        const dir_size = @as(usize, num_tables) * 16;

        if (dir_start + dir_size > data.len) {
            return Error.OutOfBounds;
        }

        return TableDirectory{
            .entries = @as([*]const TableEntry, @ptrCast(@alignCast(data.ptr + dir_start)))[0..num_tables],
            .data = data,
        };
    }

    pub fn find(self: *const TableDirectory, tag: [4]u8) ?TableEntry {
        // Linear search (typically < 20 tables)
        const num = @divExact(self.entries.len * 16, 16); // entry count
        var i: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            const offset = 12 + i * 16;
            if (offset + 16 > self.data.len) break;

            const entry_tag = self.data[offset..][0..4];
            if (std.mem.eql(u8, entry_tag, &tag)) {
                return TableEntry{
                    .tag = tag,
                    .checksum = readU32(self.data, offset + 4),
                    .offset = readU32(self.data, offset + 8),
                    .length = readU32(self.data, offset + 12),
                };
            }
        }
        _ = num;
        return null;
    }
};

/// Table directory entry
pub const TableEntry = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

/// 'head' table - font header
pub const HeadTable = struct {
    units_per_em: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    index_to_loc_format: i16, // 0 = short offsets, 1 = long offsets
};

/// 'hhea' table - horizontal header
pub const HheaTable = struct {
    ascent: i16,
    descent: i16,
    line_gap: i16,
    advance_width_max: u16,
    num_of_long_hor_metrics: u16,
};

/// 'maxp' table - maximum profile
pub const MaxpTable = struct {
    num_glyphs: u16,
};

/// Parse cmap table to look up a glyph ID
fn parseCmapLookup(data: []const u8, codepoint: u21) ?u16 {
    if (data.len < 4) return null;

    const num_tables = readU16(data, 2);
    var best_subtable: ?struct { offset: u32, format: u16 } = null;

    // Find best subtable (prefer format 4 or 12 for Unicode)
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const record_offset = 4 + i * 8;
        if (record_offset + 8 > data.len) break;

        const platform_id = readU16(data, record_offset);
        const encoding_id = readU16(data, record_offset + 2);
        const subtable_offset = readU32(data, record_offset + 4);

        // Accept Unicode platforms
        const is_unicode = (platform_id == 0) or // Unicode
            (platform_id == 3 and (encoding_id == 1 or encoding_id == 10)); // Windows Unicode

        if (is_unicode and subtable_offset < data.len) {
            const format = readU16(data, subtable_offset);
            // Prefer format 12 (full Unicode) over format 4 (BMP only)
            if (format == 12 or (format == 4 and best_subtable == null)) {
                best_subtable = .{ .offset = subtable_offset, .format = format };
                if (format == 12) break; // Best possible, stop searching
            }
        }
    }

    const subtable = best_subtable orelse return null;

    return switch (subtable.format) {
        4 => parseCmapFormat4(data[subtable.offset..], codepoint),
        12 => parseCmapFormat12(data[subtable.offset..], codepoint),
        else => null,
    };
}

/// Parse cmap format 4 (segment mapping to delta values) - BMP only
fn parseCmapFormat4(data: []const u8, codepoint: u21) ?u16 {
    if (codepoint > 0xFFFF) return null; // Format 4 is BMP only
    if (data.len < 14) return null;

    const seg_count = readU16(data, 6) / 2;
    const end_codes_offset: usize = 14;
    const start_codes_offset = end_codes_offset + @as(usize, seg_count) * 2 + 2; // +2 for reservedPad
    const deltas_offset = start_codes_offset + @as(usize, seg_count) * 2;
    const offsets_offset = deltas_offset + @as(usize, seg_count) * 2;

    const cp: u16 = @intCast(codepoint);

    // Binary search for segment
    var lo: usize = 0;
    var hi: usize = seg_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const end_code = readU16(data, end_codes_offset + mid * 2);
        if (end_code < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo >= seg_count) return null;

    const seg = lo;
    const end_code = readU16(data, end_codes_offset + seg * 2);
    const start_code = readU16(data, start_codes_offset + seg * 2);

    if (cp < start_code or cp > end_code) return null;

    const delta = readI16(data, deltas_offset + seg * 2);
    const range_offset = readU16(data, offsets_offset + seg * 2);

    if (range_offset == 0) {
        // Simple delta
        return @bitCast(@as(i16, @bitCast(cp)) +% delta);
    } else {
        // Indexed lookup
        const idx_offset = offsets_offset + seg * 2 + range_offset + (cp - start_code) * 2;
        if (idx_offset + 2 > data.len) return null;
        const glyph_id = readU16(data, idx_offset);
        if (glyph_id == 0) return 0;
        return @bitCast(@as(i16, @bitCast(glyph_id)) +% delta);
    }
}

/// Parse cmap format 12 (segmented coverage) - full Unicode
fn parseCmapFormat12(data: []const u8, codepoint: u21) ?u16 {
    if (data.len < 16) return null;

    const num_groups = readU32(data, 12);
    const groups_offset: usize = 16;

    // Binary search
    var lo: usize = 0;
    var hi: usize = num_groups;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const group_offset = groups_offset + mid * 12;
        if (group_offset + 12 > data.len) return null;

        const start_code = readU32(data, group_offset);
        const end_code = readU32(data, group_offset + 4);

        if (codepoint < start_code) {
            hi = mid;
        } else if (codepoint > end_code) {
            lo = mid + 1;
        } else {
            // Found
            const start_glyph = readU32(data, group_offset + 8);
            return @intCast(start_glyph + (codepoint - start_code));
        }
    }

    return null;
}

// Big-endian read helpers
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

// ============================================================================
// Tests
// ============================================================================

test "parse Courier Prime" {
    const result = Font.fromFile(std.testing.allocator, "test/fonts/Courier Prime/Courier Prime.ttf") catch |err| {
        std.debug.print("Failed to load font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    // Check header
    try std.testing.expect(font.head != null);
    try std.testing.expect(font.hhea != null);
    try std.testing.expect(font.maxp != null);

    const head = font.head.?;
    try std.testing.expect(head.units_per_em > 0);

    // Check glyph mapping
    const glyph_a = font.getGlyphId('A');
    try std.testing.expect(glyph_a != null);

    // Check width
    const width_a = font.getCharWidth('A');
    try std.testing.expect(width_a != null);
    try std.testing.expect(width_a.? > 0);
}

test "read big-endian" {
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(u16, 0x0001), readU16(&data, 0));
    try std.testing.expectEqual(@as(u16, 0x0102), readU16(&data, 1));
    try std.testing.expectEqual(@as(u32, 0x00010203), readU32(&data, 0));
}
