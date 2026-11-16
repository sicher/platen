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
    post: ?PostTable = null,
    os2: ?Os2Table = null,
    /// The face's own style: OS/2 fsSelection, else head.macStyle (as
    /// font_collection.describeFace reads it).
    style: FaceStyle = .{},
    /// OS/2 fsType: the embedding permissions the face's licence grants
    /// (0 = installable, also without an OS/2 table). See `mayEmbed`.
    fs_type: u16 = 0,

    // Cached cmap lookup (avoids subtable search on every glyph lookup)
    cmap_subtable_offset: u32 = 0,
    cmap_format: u16 = 0,
    /// Offset of the format 14 subtable (variation sequences) in cmap,
    /// 0 if the font has none.
    cmap_uvs_offset: u32 = 0,

    // ASCII glyph cache for O(1) lookup of common characters
    ascii_glyphs: [128]u16 = @splat(0),
    has_ascii_cache: bool = false,

    // Cached hmtx table data for fast width lookups
    hmtx_data: ?[]const u8 = null,

    // ASCII width cache for O(1) width lookup of common characters (in font units)
    ascii_widths: [128]u16 = @splat(0),
    has_ascii_widths: bool = false,

    /// Load a font from file
    pub fn fromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !struct { font: Font, data: []const u8 } {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024));
        errdefer allocator.free(data);

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
        font.post = font.parsePost();
        font.os2 = font.parseOs2();
        font.style = font.parseStyle();
        if (font.getTable("OS/2".*)) |os2| {
            if (os2.len >= 10) font.fs_type = readU16(os2, 8);
        }

        // Initialize cmap cache for fast glyph lookups
        font.initCmapCache();

        // Initialize hmtx cache for fast width lookups
        font.initHmtxCache();

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

        // Variation sequences: platform 0 (Unicode), encoding 5
        i = 0;
        while (i < num_tables) : (i += 1) {
            const record_offset = 4 + i * 8;
            if (record_offset + 8 > cmap_data.len) break;
            const subtable_offset = readU32(cmap_data, record_offset + 4);
            if (readU16(cmap_data, record_offset) == 0 and readU16(cmap_data, record_offset + 2) == 5 and
                subtable_offset > 0 and readU16(cmap_data, subtable_offset) == 14)
            {
                self.cmap_uvs_offset = subtable_offset;
                break;
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

    /// Initialize hmtx cache - cache table pointer and ASCII widths
    fn initHmtxCache(self: *Font) void {
        self.hmtx_data = self.getTable("hmtx".*);
        const hmtx = self.hmtx_data orelse return;
        const hhea = self.hhea orelse return;

        // Only cache if we have ASCII glyph cache
        if (!self.has_ascii_cache) return;

        // Populate ASCII width cache
        for (0..128) |i| {
            const gid = self.ascii_glyphs[i];
            if (gid < hhea.num_of_long_hor_metrics) {
                const offset = @as(usize, gid) * 4;
                if (offset + 2 <= hmtx.len) {
                    self.ascii_widths[i] = readU16(hmtx, offset);
                }
            } else if (hhea.num_of_long_hor_metrics > 0) {
                // Use last advanceWidth for glyphs beyond longHorMetrics
                const offset = (@as(usize, hhea.num_of_long_hor_metrics) - 1) * 4;
                if (offset + 2 <= hmtx.len) {
                    self.ascii_widths[i] = readU16(hmtx, offset);
                }
            }
        }
        self.has_ascii_widths = true;
    }

    /// Check if this is a CFF-based font (OTF with PostScript outlines)
    pub fn isCFF(self: *const Font) bool {
        return self.getCFFTable() != null;
    }

    /// Check if this is a TrueType font (has glyf outlines)
    pub fn isTrueType(self: *const Font) bool {
        return self.getTable("glyf".*) != null;
    }

    /// Get CFF or CFF2 table data (for CFF-based fonts)
    pub fn getCFFTable(self: *const Font) ?[]const u8 {
        return self.getTable("CFF ".*) orelse self.getTable("CFF2".*);
    }

    /// Get table data by tag
    pub fn getTable(self: *const Font, tag: [4]u8) ?[]const u8 {
        const entry = self.tables.find(tag) orelse return null;
        // Subtraction form: offset + length is attacker-controlled u32
        // arithmetic and can wrap.
        if (entry.offset > self.data.len or entry.length > self.data.len - entry.offset) return null;
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

    /// Parse 'post' table (underline metrics)
    fn parsePost(self: *const Font) ?PostTable {
        const data = self.getTable("post".*) orelse return null;
        if (data.len < 12) return null;

        // post table layout:
        // 0-4: version (Fixed)
        // 4-8: italicAngle (Fixed)
        // 8-10: underlinePosition (FWord/i16)
        // 10-12: underlineThickness (FWord/i16)
        return PostTable{
            .underline_position = readI16(data, 8),
            .underline_thickness = readI16(data, 10),
        };
    }

    /// Parse 'OS/2' table (strikethrough metrics)
    /// Whether the licence lets a document embed the face's outlines: not
    /// Restricted License (bits 0-3 exactly 0x2; with several bits set the
    /// least restrictive applies) and not Bitmap Embedding Only (bit 9).
    /// platen embeds whatever it is given; callers choosing fonts on their
    /// own (system fallback) ask this first.
    pub fn mayEmbed(self: *const Font) bool {
        if (self.fs_type & 0x000F == 0x0002) return false;
        return self.fs_type & 0x0200 == 0;
    }

    fn parseStyle(self: *const Font) FaceStyle {
        if (self.getTable("OS/2".*)) |os2| {
            if (os2.len < 64) return .{};
            const sel = readU16(os2, 62);
            return .{ .bold = sel & (1 << 5) != 0, .italic = sel & 1 != 0 };
        }
        const head = self.getTable("head".*) orelse return .{};
        if (head.len < 46) return .{};
        const mac = readU16(head, 44);
        return .{ .bold = mac & 1 != 0, .italic = mac & 2 != 0 };
    }

    fn parseOs2(self: *const Font) ?Os2Table {
        const data = self.getTable("OS/2".*) orelse return null;
        if (data.len < 30) return null;

        // OS/2 table layout (relevant fields):
        // 0-2: version (u16)
        // 26-28: yStrikeoutSize (i16)
        // 28-30: yStrikeoutPosition (i16)
        // 88-90: sCapHeight (i16) - only in version 2+

        // sCapHeight is at offset 88, requires version >= 2 and enough data
        const version = readU16(data, 0);
        const cap_height: i16 = if (version >= 2 and data.len >= 90)
            readI16(data, 88)
        else
            0; // Will be estimated from ascent if 0

        return Os2Table{
            .strikeout_size = readI16(data, 26),
            .strikeout_position = readI16(data, 28),
            .cap_height = cap_height,
        };
    }

    /// Get glyph width (in font units)
    pub fn getGlyphWidth(self: *const Font, glyph_id: u16) ?u16 {
        const hhea = self.hhea orelse return null;
        const hmtx_data = self.hmtx_data orelse return null;

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

    /// Get glyph width with ASCII fast path (in font units)
    /// Largest advance width getGlyphWidth can return (the longHorMetric
    /// entries; trailing glyphs reuse the last one).
    pub fn maxAdvanceWidth(self: *const Font) u16 {
        const hhea = self.hhea orelse return 0;
        const hmtx_data = self.hmtx_data orelse return 0;
        var max: u16 = 0;
        for (0..hhea.num_of_long_hor_metrics) |i| {
            const offset = i * 4;
            if (offset + 2 > hmtx_data.len) break;
            max = @max(max, readU16(hmtx_data, offset));
        }
        return max;
    }

    pub fn getGlyphWidthFast(self: *const Font, glyph_id: u16, codepoint: u21) ?u16 {
        // ASCII fast path: use cached width
        if (self.has_ascii_widths and codepoint < 128) {
            const w = self.ascii_widths[codepoint];
            return if (w != 0) w else self.getGlyphWidth(glyph_id);
        }
        return self.getGlyphWidth(glyph_id);
    }

    /// Glyph of the variation sequence `codepoint` + `selector` (cmap
    /// format 14): its own glyph, or the base's glyph when the font lists
    /// the sequence as using it (default UVS). Null when the sequence is
    /// not listed, or the font has no format 14 subtable.
    pub fn getVariationGlyph(self: *const Font, codepoint: u21, selector: u21) ?u16 {
        if (self.cmap_uvs_offset == 0) return null;
        const cmap_data = self.getTable("cmap".*) orelse return null;
        const uvs = cmap_data[self.cmap_uvs_offset..];
        return switch (lookupVariation(uvs, codepoint, selector)) {
            .none => null,
            .default => self.getGlyphId(codepoint),
            .glyph => |g| g,
        };
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
        // Offsets/lengths widen to usize at the read: summing u16 file
        // values in u16 overflows on hostile input.
        const string_offset: usize = readU16(name_data, 4);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const record_offset = 6 + i * 12;
            if (record_offset + 12 > name_data.len) break;

            const platform_id = readU16(name_data, record_offset);
            const encoding_id = readU16(name_data, record_offset + 2);
            const record_name_id = readU16(name_data, record_offset + 6);
            const length: usize = readU16(name_data, record_offset + 8);
            const offset: usize = readU16(name_data, record_offset + 10);

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
    /// Number of table entries; each is 16 bytes at `data[12 + i*16]`.
    count: u16,
    data: []const u8, // Reference to underlying data for entry access

    pub fn parse(data: []const u8, num_tables: u16) Error!TableDirectory {
        const dir_start: usize = 12;
        const dir_size = @as(usize, num_tables) * 16;

        if (dir_start + dir_size > data.len) {
            return Error.OutOfBounds;
        }

        // The directory is NOT cast to []const TableEntry: font data comes
        // from the caller and may be arbitrarily aligned (@embedFile yields
        // alignment 1, which crashed with "incorrect alignment"), and the
        // on-disk fields are big-endian, so a native-endian struct view would
        // read garbage anyway. Entries are decoded field-by-field in `find`.
        return TableDirectory{
            .count = num_tables,
            .data = data,
        };
    }

    pub fn find(self: *const TableDirectory, tag: [4]u8) ?TableEntry {
        // Linear search (typically < 20 tables)
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
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

/// Bold and italic as a face declares them about itself.
pub const FaceStyle = struct {
    bold: bool = false,
    italic: bool = false,
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

/// 'post' table - PostScript hints (underline metrics)
pub const PostTable = struct {
    underline_position: i16,
    underline_thickness: i16,
};

/// 'OS/2' table - OS/2 and Windows metrics
pub const Os2Table = struct {
    strikeout_size: i16,
    strikeout_position: i16,
    cap_height: i16, // sCapHeight - height of capital letters (0 if not available)
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
        const idx_offset = offsets_offset + seg * 2 + @as(usize, range_offset) + @as(usize, cp - start_code) * 2;
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
            // A glyph ID beyond u16 cannot exist; treat it as unmapped.
            const start_glyph: u64 = readU32(data, group_offset + 8);
            return std.math.cast(u16, start_glyph + (codepoint - start_code));
        }
    }

    return null;
}

const Variation = union(enum) { none, default, glyph: u16 };

/// Look up `codepoint` + `selector` in a cmap format 14 subtable. As in
/// HarfBuzz, the default UVS ranges are checked before the non-default
/// mappings.
fn lookupVariation(data: []const u8, codepoint: u21, selector: u21) Variation {
    // uint16 format, uint32 length, uint32 numVarSelectorRecords;
    // records: uint24 varSelector, Offset32 defaultUVS, Offset32 nonDefaultUVS
    const num_records = readU32(data, 6);
    const record = bsearch(data, 10, 11, num_records, selector) orelse return .none;
    const default_uvs = readU32(data, record + 3);
    if (default_uvs != 0 and default_uvs < data.len) {
        // uint32 numUnicodeValueRanges; ranges: uint24 start, uint8 additionalCount
        const ranges = data[default_uvs..];
        const n = readU32(ranges, 0);
        // Last range starting at or before codepoint
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = 4 + mid * 4;
            if (at + 4 > ranges.len) return .none;
            if (readU24(ranges, at) <= codepoint) lo = mid + 1 else hi = mid;
        }
        if (lo > 0) {
            const at = 4 + (lo - 1) * 4;
            if (codepoint <= readU24(ranges, at) + @as(u32, ranges[at + 3])) return .default;
        }
    }
    const non_default = readU32(data, record + 7);
    if (non_default != 0 and non_default < data.len) {
        // uint32 numUVSMappings; mappings: uint24 unicodeValue, uint16 glyphID
        const mappings = data[non_default..];
        const mapping = bsearch(mappings, 4, 5, readU32(mappings, 0), codepoint) orelse return .none;
        return .{ .glyph = readU16(mappings, mapping + 3) };
    }
    return .none;
}

/// Binary search `count` records of `size` bytes starting at `start`, keyed
/// by a leading uint24, for `key`. Returns the record's offset.
fn bsearch(data: []const u8, start: usize, size: usize, count: u32, key: u21) ?usize {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = start + mid * size;
        if (at + size > data.len) return null;
        const k = readU24(data, at);
        if (key < k) {
            hi = mid;
        } else if (key > k) {
            lo = mid + 1;
        } else {
            return at;
        }
    }
    return null;
}

// Big-endian read helpers
fn readU24(data: []const u8, offset: usize) u32 {
    if (offset + 3 > data.len) return 0;
    return std.mem.readInt(u24, data[offset..][0..3], .big);
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

// ============================================================================
// Tests
// ============================================================================

test "cmap format 14 variation glyphs (GsubTest)" {
    const loaded = Font.fromFile(std.testing.io, std.testing.allocator, "test/fonts/gsub/GsubTest.ttf") catch return error.SkipZigTest;
    defer std.testing.allocator.free(loaded.data);
    const font = loaded.font;
    // scripts/gen_gsub_test_font.py: a+FE00 -> a.alt (gid 32), b+FE00 ->
    // b's own glyph (default UVS), d+E0100 -> d.alt (gid 47); anything
    // else is not listed
    try std.testing.expectEqual(@as(?u16, 32), font.getVariationGlyph('a', 0xFE00));
    try std.testing.expectEqual(font.getGlyphId('b'), font.getVariationGlyph('b', 0xFE00));
    try std.testing.expectEqual(@as(?u16, 47), font.getVariationGlyph('d', 0xE0100));
    try std.testing.expectEqual(@as(?u16, null), font.getVariationGlyph('a', 0xFE01));
    try std.testing.expectEqual(@as(?u16, null), font.getVariationGlyph('e', 0xFE00));
    try std.testing.expectEqual(@as(?u16, null), font.getVariationGlyph('d', 0xFE00));
}

test "parse Courier Prime" {
    const result = Font.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Courier Prime/Courier Prime.ttf") catch |err| {
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

test "a face reports its own bold and italic" {
    const cases = [_]struct { path: []const u8, style: FaceStyle }{
        .{ .path = "test/fonts/Courier Prime/Courier Prime.ttf", .style = .{} },
        .{ .path = "test/fonts/Courier Prime/Courier Prime Bold.ttf", .style = .{ .bold = true } },
        .{ .path = "test/fonts/Courier Prime/Courier Prime Italic.ttf", .style = .{ .italic = true } },
        .{ .path = "test/fonts/Courier Prime/Courier Prime Bold Italic.ttf", .style = .{ .bold = true, .italic = true } },
    };
    for (cases) |c| {
        const result = try Font.fromFile(std.testing.io, std.testing.allocator, c.path);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqual(c.style, result.font.style);
    }
}

test "embedding permissions follow fsType" {
    var f: Font = .{ .data = &.{}, .tables = undefined };
    for ([_]struct { u16, bool }{
        .{ 0x0000, true }, // installable
        .{ 0x0002, false }, // restricted
        .{ 0x0004, true }, // preview & print
        .{ 0x0008, true }, // editable
        .{ 0x0006, true }, // restricted + preview: the less restrictive wins
        .{ 0x0208, false }, // bitmap embedding only
    }) |c| {
        f.fs_type = c[0];
        try std.testing.expectEqual(c[1], f.mayEmbed());
    }
    const courier = try Font.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
    defer std.testing.allocator.free(courier.data);
    try std.testing.expect(courier.font.mayEmbed());
}

test "read big-endian" {
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(u16, 0x0001), readU16(&data, 0));
    try std.testing.expectEqual(@as(u16, 0x0102), readU16(&data, 1));
    try std.testing.expectEqual(@as(u32, 0x00010203), readU32(&data, 0));
}

test "table record whose offset + length overflows u32 is rejected" {
    // Found by `zig build test --fuzz`: getTable computed entry.offset +
    // entry.length in u32, which overflowed (panic) for hostile records.
    var data: [28]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], 0x00010000, .big); // sfnt version
    std.mem.writeInt(u16, data[4..6], 1, .big); // numTables
    @memcpy(data[12..16], "head");
    std.mem.writeInt(u32, data[20..24], 0xFFFF_FF00, .big); // offset
    std.mem.writeInt(u32, data[24..28], 0x0000_0200, .big); // length (sum wraps)

    const font = try Font.parse(&data);
    try std.testing.expect(font.head == null);
    try std.testing.expect(font.getTable("head".*) == null);
}

test "cmap format 12 group mapping beyond u16 glyph IDs is unmapped" {
    // Found by audit: start_glyph + delta was u32 arithmetic, then
    // @intCast to u16 - reached from Font.parse via the ASCII cache.
    var data: [28]u8 = @splat(0);
    std.mem.writeInt(u32, data[12..16], 1, .big); // numGroups
    std.mem.writeInt(u32, data[16..20], 0, .big); // startCharCode
    std.mem.writeInt(u32, data[20..24], 0x7F, .big); // endCharCode
    std.mem.writeInt(u32, data[24..28], 0x10000, .big); // startGlyphID
    try std.testing.expectEqual(@as(?u16, null), parseCmapFormat12(&data, 'A'));

    std.mem.writeInt(u32, data[24..28], 0xFFFF_FFFF, .big); // sum wraps u32
    try std.testing.expectEqual(@as(?u16, null), parseCmapFormat12(&data, 'A'));

    std.mem.writeInt(u32, data[24..28], 0xFFBE, .big); // 'A' (0x41) -> 0xFFFF fits
    try std.testing.expectEqual(@as(?u16, 0xFFFF), parseCmapFormat12(&data, 'A'));
}

test "cmap format 4 indexed lookup with a wide segment does not overflow" {
    // Found by audit: (cp - start_code) * 2 was computed in u16.
    var data: [24]u8 = @splat(0);
    std.mem.writeInt(u16, data[6..8], 2, .big); // segCountX2 = 2 (one segment)
    std.mem.writeInt(u16, data[14..16], 0xFFFF, .big); // endCode
    std.mem.writeInt(u16, data[18..20], 0, .big); // startCode
    std.mem.writeInt(u16, data[22..24], 2, .big); // idRangeOffset (indexed)
    try std.testing.expectEqual(@as(?u16, null), parseCmapFormat4(&data, 0x8000));
}

test "name record whose string offset + length overflows u16 is ignored" {
    // Found by audit: string_offset + offset and str_start + length were
    // u16 arithmetic on file values.
    var data: [52]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, data[4..6], 1, .big); // numTables
    @memcpy(data[12..16], "name");
    std.mem.writeInt(u32, data[20..24], 28, .big); // table offset
    std.mem.writeInt(u32, data[24..28], 24, .big); // table length
    const name = data[28..];
    std.mem.writeInt(u16, name[2..4], 1, .big); // count
    std.mem.writeInt(u16, name[4..6], 0xFFFF, .big); // stringOffset
    std.mem.writeInt(u16, name[6..8], 3, .big); // platformID (Windows)
    std.mem.writeInt(u16, name[8..10], 1, .big); // encodingID (Unicode BMP)
    std.mem.writeInt(u16, name[12..14], 6, .big); // nameID (PostScript)
    std.mem.writeInt(u16, name[14..16], 0x20, .big); // length
    std.mem.writeInt(u16, name[16..18], 1, .big); // offset

    const font = try Font.parse(&data);
    try std.testing.expectEqual(@as(?[]const u8, null), font.getNameEntry(6));
}
