//! Embedded Font Support
//!
//! Handles TrueType font embedding in PDF documents.
//! Supports two encoding modes:
//! - WinAnsiEncoding (Windows-1252): Simple single-byte text, 256 character limit
//! - Identity-H (CID): Full Unicode support via 2-byte glyph IDs

const std = @import("std");
const ttf = @import("ttf.zig");
const unicode_compose = @import("unicode_compose.zig");
const gsub = @import("gsub.zig");

/// Whether `text` may contain a combining mark or a default ignorable,
/// i.e. needs decodeText before measuring: UTF-8 lead bytes below 0xCC
/// encode code points below U+0300 (unicode_compose.first_mark); 0xC2
/// leads the soft hyphen U+00AD, the one ignorable below that.
fn mayNeedDecoding(text: []const u8) bool {
    for (text) |b| {
        if (b >= 0xCC or b == 0xC2) return true;
    }
    return false;
}
const ttf_subset = @import("ttf_subset.zig");
const cff_subset = @import("cff_subset.zig");
const colr = @import("colr.zig");
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const svg_table = @import("svg_table.zig");
pub const opentype = @import("opentype.zig");
const KernTable = @import("kern_table.zig").KernTable;
const format = @import("format.zig");
const binary = @import("binary.zig");

// Re-export commonly used functions from subsetting modules
const readU16 = ttf_subset.readU16;
const readI16 = ttf_subset.readI16;
const readU32 = ttf_subset.readU32;
const padTo4 = ttf_subset.padTo4;
const writeTableEntry = ttf_subset.writeTableEntry;
const getLocaOffset = ttf_subset.getLocaOffset;
const buildHmtxForGlyphs = ttf_subset.buildHmtxForGlyphs;
const buildMinimalCmap = ttf_subset.buildMinimalCmap;
const buildMinimalNameTable = ttf_subset.buildMinimalNameTable;
const assembleTTF = ttf_subset.assembleTTF;
const TTFTables = ttf_subset.TTFTables;
const getCompositeComponents = ttf_subset.getCompositeComponents;
const expandCompositeGlyphs = ttf_subset.expandCompositeGlyphs;
const rewriteCompositeGlyphIDs = ttf_subset.rewriteCompositeGlyphIDs;

const CFFIndex = cff_subset.CFFIndex;
const parseCFFIndex = cff_subset.parseCFFIndex;
const skipCFFIndex = cff_subset.skipCFFIndex;
const readCFFOffset = cff_subset.readCFFOffset;
const parseCFFTopDictForCharStrings = cff_subset.parseCFFTopDictForCharStrings;
const parseCFFTopDictForPrivate = cff_subset.parseCFFTopDictForPrivate;
const parseCFFDictForOperator = cff_subset.parseCFFDictForOperator;
const getCharsetSID = cff_subset.getCharsetSID;
const buildUpdatedTopDict = cff_subset.buildUpdatedTopDict;
const buildPrivateDictWithoutSubrs = cff_subset.buildPrivateDictWithoutSubrs;
const encodeCFFInt = cff_subset.encodeCFFInt;
const getSubrBias = cff_subset.getSubrBias;
const desubroutinizeCharString = cff_subset.desubroutinizeCharString;
const PrivateInfo = cff_subset.PrivateInfo;
const TopDictOffsets = cff_subset.TopDictOffsets;
const collectTopDictSIDs = cff_subset.collectTopDictSIDs;
const buildSubsetStringIndex = cff_subset.buildSubsetStringIndex;
const buildUpdatedTopDictWithSIDRemap = cff_subset.buildUpdatedTopDictWithSIDRemap;
const remapSID = cff_subset.remapSID;
const STANDARD_STRING_COUNT = cff_subset.STANDARD_STRING_COUNT;

/// Font encoding mode for PDF embedding
pub const FontEncoding = enum {
    /// WinAnsiEncoding - single byte, 256 chars max (legacy mode)
    win_ansi,
    /// Identity-H - 2-byte glyph IDs, full Unicode (CID font)
    identity,
};

/// Common font table references for TTF subsetting operations.
/// Consolidates repeated table extraction code.
const SubsetTables = struct {
    head: ttf.HeadTable,
    hhea: ttf.HheaTable,
    maxp: ttf.MaxpTable,
    glyf: []const u8,
    loca: []const u8,
    hmtx: []const u8,
    loca_format: i16,

    fn init(emb: *const EmbeddedFont) !SubsetTables {
        const font = &emb.font;
        const head = font.head orelse return error.MissingTable;
        // Bitmap-only fonts get a synthesized all-empty loca and an empty
        // glyf (see EmbeddedFont.synthetic_loca).
        const glyf = font.getTable("glyf".*) orelse
            (if (emb.synthetic_loca != null) &[_]u8{} else return error.MissingTable);
        const loca = font.getTable("loca".*) orelse
            (emb.synthetic_loca orelse return error.MissingTable);
        return .{
            .head = head,
            .hhea = font.hhea orelse return error.MissingTable,
            .maxp = font.maxp orelse return error.MissingTable,
            .glyf = glyf,
            .loca = loca,
            .hmtx = font.getTable("hmtx".*) orelse return error.MissingTable,
            .loca_format = head.index_to_loc_format,
        };
    }
};

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
/// Scale a font-unit metric to 1000 units. A value that does not fit i16
/// (only reachable with hostile metrics) makes the font invalid.
fn scaledI16(v: i16, scale: f64) error{InvalidFont}!i16 {
    const r = @round(@as(f64, @floatFromInt(v)) * scale);
    if (r < std.math.minInt(i16) or r > std.math.maxInt(i16)) return error.InvalidFont;
    return @intFromFloat(r);
}

pub const EmbeddedFont = struct {
    name: []const u8, // PostScript name for PDF
    data: []const u8, // Raw TTF data (for FontFile2)
    font: ttf.Font, // Parsed font
    widths: [256]u16, // Widths in 1/1000 em for WinAnsi chars
    allocator: std.mem.Allocator,
    owns_data: bool, // Whether we own the TTF data
    /// True on per-document clones of a FontFace: parse-time allocations
    /// (synthetic_loca, color tables) belong to the prototype.
    borrowed: bool = false,

    // Metrics scaled to 1000 units (PDF standard)
    ascent: i16,
    descent: i16,
    cap_height: i16,
    bbox: [4]i16, // [x_min, y_min, x_max, y_max]
    italic_angle: i16,
    stem_v: u16,
    flags: FontFlags,

    // Text decoration metrics (scaled to 1000 units)
    underline_position: i16, // Distance below baseline (usually negative)
    underline_thickness: i16,
    strikeout_position: i16, // Distance above baseline
    strikeout_size: i16,

    // Encoding mode (identity preserves composite glyphs and supports full Unicode)
    encoding: FontEncoding = .identity,

    // Subsetting support (WinAnsi mode)
    used_chars: [256]bool = @splat(false), // Track which WinAnsi chars are used
    subset_data: ?[]const u8 = null, // Generated subset TTF (lazily created)

    // CID mode: track Unicode codepoint → glyph ID mappings
    // Key: Unicode codepoint, Value: original glyph ID from font
    cid_used_glyphs: std.AutoArrayHashMapUnmanaged(u21, u16) = .empty,
    cid_glyph_widths: std.AutoArrayHashMapUnmanaged(u16, u16) = .empty, // GID → width in 1/1000 em

    // Glyph → codepoint mapping for ToUnicode (handles calt contextual variants)
    // Key: glyph ID, Value: Unicode codepoint that produced this glyph
    // Needed because calt can produce different glyphs for the same codepoint in different contexts
    glyph_to_codepoint: std.AutoArrayHashMapUnmanaged(u16, u21) = .empty,

    // Glyph ID remapping for compact CFF subsets (original GID → new compact GID)
    // Only populated for CFF fonts with subsetting enabled
    gid_remap: std.AutoArrayHashMapUnmanaged(u16, u16) = .empty,

    // OpenType feature support
    ot_features: ?*opentype.OpenTypeFeatures = null,
    feature_flags: opentype.FeatureFlags = opentype.FeatureFlags.init(), // liga=on, kern=on by default

    // Cached flags for fast render-time checks (set by initOpenTypeFeatures)
    has_kern_data: bool = false, // True if font has ANY kerning pairs
    has_mark_data: bool = false, // True if font has ANY mark positioning

    // Ligature glyph → original codepoints mapping for ToUnicode CMap
    // Key: ligature glyph ID (original), Value: array of codepoints that form it
    ligature_codepoints: std.AutoArrayHashMapUnmanaged(u16, []const u21) = .empty,

    // Scratch buffers for shaping (reused across calls to avoid allocations)
    scratch_codepoints: std.ArrayListUnmanaged(u21) = .empty,
    // Per scratch code point: composed from a decomposed sequence (decodeText)
    scratch_composed: std.ArrayListUnmanaged(bool) = .empty,
    /// decodeText found a default ignorable (U+FE0F, ZWJ, soft hyphen...):
    /// the text must go through the shaper, which removes them
    scratch_ignorables: bool = false,
    scratch_glyphs: std.ArrayListUnmanaged(u16) = .empty,

    // COLR/CPAL color-font support (lazily probed). All slices in ColorInfo
    // point into `data`, so there is nothing to free.
    color_info: ?ColorInfo = null,
    color_checked: bool = false,

    // CBDT/sbix bitmap color-glyph support (lazily probed; null when the
    // font also has COLR, which takes priority). Slices point into `data`.
    bitmap_info: ?bitmap_glyphs.BitmapInfo = null,
    bitmap_checked: bool = false,

    // OT-SVG color-glyph support (lazily probed; null when the font also
    // has COLR, which takes priority). The table slice points into `data`.
    svg_info: ?svg_table.SvgTable = null,
    svg_checked: bool = false,

    /// All-zero loca synthesized for bitmap-only fonts (e.g. Noto Color
    /// Emoji CBDT), which carry no glyf/loca at all: the CID companion font
    /// is then subset with every outline empty (glyphs render via the Type3
    /// bitmap path instead).
    synthetic_loca: ?[]u8 = null,

    /// Load and parse a TTF font from file
    pub fn fromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*EmbeddedFont {
        const result = try ttf.Font.fromFile(io, allocator, path);
        return try fromParsed(allocator, result.font, result.data, true);
    }

    /// Load and parse a TTF font from memory
    /// If owns_data is true, this font takes ownership of the data slice
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8, owns_data: bool) !*EmbeddedFont {
        const font = try ttf.Font.parse(data);
        return try fromParsed(allocator, font, data, owns_data);
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

        // Glyphs platen can embed: TrueType outlines, CFF/CFF2, or bitmaps
        // (embedded through a Type3 companion). A face with none of them -
        // Apple's private 'hvgl' outlines, e.g. PingFang UI - would load and
        // then fail when subset at output: refuse it here, where a caller
        // choosing among system fonts can still take another.
        const has_outlines = (font.getTable("glyf".*) != null and font.getTable("loca".*) != null) or font.isCFF();
        const has_bitmaps = font.getTable("CBLC".*) != null or font.getTable("sbix".*) != null or
            font.getTable("EBLC".*) != null;
        if (!has_outlines and !has_bitmaps) return error.UnsupportedOutlines;

        // OpenType allows unitsPerEm 16..16384. Outside it the 1000-unit
        // scale (up to 62.5x) overflows the u16/i16 metrics below.
        const units_per_em = head.units_per_em;
        if (units_per_em < 16 or units_per_em > 16384) return error.InvalidFont;

        // Scale factor: convert from font units to 1000 units
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(units_per_em));

        // Every advance getGlyphWidth can return must fit u16 once scaled.
        // Checked once here, so the per-glyph conversions (WinAnsi widths,
        // CID widths, getGlyphWidth) cannot overflow later.
        if (@round(@as(f64, @floatFromInt(font.maxAdvanceWidth())) * scale) > std.math.maxInt(u16)) {
            return error.InvalidFont;
        }

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
        const ascent = try scaledI16(hhea.ascent, scale);
        const descent = try scaledI16(hhea.descent, scale);

        // Get CapHeight from OS/2 table if available, otherwise estimate as 70% of ascent
        const cap_height: i16 = if (font.os2) |os2| blk: {
            if (os2.cap_height > 0) {
                break :blk try scaledI16(os2.cap_height, scale);
            } else {
                break :blk @intFromFloat(@round(@as(f64, @floatFromInt(ascent)) * 0.7));
            }
        } else @intFromFloat(@round(@as(f64, @floatFromInt(ascent)) * 0.7));

        // Scale bounding box
        const bbox: [4]i16 = .{
            try scaledI16(head.x_min, scale),
            try scaledI16(head.y_min, scale),
            try scaledI16(head.x_max, scale),
            try scaledI16(head.y_max, scale),
        };

        // Estimate StemV (vertical stem width) - typically 80 for normal, higher for bold
        // Would need proper stem detection for accuracy
        const stem_v: u16 = 80;

        // Get underline metrics from POST table (defaults based on fpdf2)
        const underline_position: i16 = if (font.post) |post|
            try scaledI16(post.underline_position, scale)
        else
            -100; // Default from fpdf2 core fonts

        const underline_thickness: i16 = if (font.post) |post|
            try scaledI16(post.underline_thickness, scale)
        else
            50; // Default from fpdf2 core fonts

        // Get strikeout metrics from OS/2 table (defaults based on fpdf2)
        const strikeout_position: i16 = if (font.os2) |os2|
            try scaledI16(os2.strikeout_position, scale)
        else
            250; // Default: roughly middle of x-height

        const strikeout_size: i16 = if (font.os2) |os2|
            try scaledI16(os2.strikeout_size, scale)
        else
            50; // Default from fpdf2 core fonts

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

        // Bitmap-only fonts have no outlines; synthesize an all-empty loca
        // (paired with a zero-length glyf in SubsetTables) so the CID
        // companion font can still be subset and embedded.
        var synthetic_loca: ?[]u8 = null;
        if (font.getTable("glyf".*) == null and
            (font.getTable("CBLC".*) != null or font.getTable("sbix".*) != null or
                font.getTable("EBLC".*) != null))
        {
            if (font.maxp) |maxp| {
                const entry_size: usize = if (head.index_to_loc_format == 0) 2 else 4;
                synthetic_loca = try allocator.alloc(u8, (@as(usize, maxp.num_glyphs) + 1) * entry_size);
                @memset(synthetic_loca.?, 0);
            }
        }
        errdefer if (synthetic_loca) |sl| allocator.free(sl);

        const embedded = try allocator.create(EmbeddedFont);
        embedded.* = .{
            .name = name,
            .data = data,
            .font = font,
            .synthetic_loca = synthetic_loca,
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
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikeout_position = strikeout_position,
            .strikeout_size = strikeout_size,
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
        // Free CID mode hash maps
        self.cid_used_glyphs.deinit(self.allocator);
        self.cid_glyph_widths.deinit(self.allocator);
        self.glyph_to_codepoint.deinit(self.allocator);
        self.gid_remap.deinit(self.allocator);
        // Free OpenType features
        if (self.ot_features) |ot| {
            ot.deinit();
            self.allocator.destroy(ot);
        }
        // Free ligature codepoint arrays
        for (self.ligature_codepoints.values()) |codepoints| {
            self.allocator.free(codepoints);
        }
        self.ligature_codepoints.deinit(self.allocator);
        // Free scratch buffers
        self.scratch_codepoints.deinit(self.allocator);
        self.scratch_composed.deinit(self.allocator);
        self.scratch_glyphs.deinit(self.allocator);
        if (!self.borrowed) {
            if (self.synthetic_loca) |sl| self.allocator.free(sl);
        }
        self.allocator.destroy(self);
    }

    /// Create a per-document font from a FontFace prototype: the parsed
    /// ttf tables, metrics, and OpenType lookups are borrowed (immutable
    /// after parse); all per-document state (glyph tracking, subsetting,
    /// scratch buffers, kerning cache) is fresh and owned. The prototype
    /// must outlive the returned font.
    fn fromShared(allocator: std.mem.Allocator, proto: *const EmbeddedFont) !*EmbeddedFont {
        const emb = try allocator.create(EmbeddedFont);
        errdefer allocator.destroy(emb);
        emb.* = proto.*;
        emb.allocator = allocator;
        emb.name = try allocator.dupe(u8, proto.name);
        errdefer allocator.free(emb.name);
        emb.owns_data = false;
        emb.borrowed = true;
        emb.subset_data = null;
        emb.used_chars = @splat(false);
        emb.cid_used_glyphs = .empty;
        emb.cid_glyph_widths = .empty;
        emb.glyph_to_codepoint = .empty;
        emb.gid_remap = .empty;
        emb.ligature_codepoints = .empty;
        emb.scratch_codepoints = .empty;
        emb.scratch_composed = .empty;
        emb.scratch_glyphs = .empty;
        if (proto.ot_features) |proto_ot| {
            const ot = try allocator.create(opentype.OpenTypeFeatures);
            errdefer allocator.destroy(ot);
            // Struct copy shares the parsed lookup tables (read-only after
            // parse) and inherits the prototype's kern cache values; shaping
            // buffers are fresh so shaping never touches shared memory.
            ot.* = proto_ot.*;
            ot.allocator = allocator;
            ot.shaper = .{};
            ot.borrowed_tables = true;
            emb.ot_features = ot;
        }
        return emb;
    }

    /// Mark characters as used (call this when text is written)
    pub fn markCharsUsed(self: *EmbeddedFont, text: []const u8) void {
        for (text) |c| {
            self.used_chars[c] = true;
        }
    }

    /// Get the number of used characters (WinAnsi mode)
    pub fn countUsedChars(self: *const EmbeddedFont) usize {
        var count: usize = 0;
        for (self.used_chars) |used| {
            if (used) count += 1;
        }
        return count;
    }

    /// Initialize OpenType features (GSUB/GPOS) if not already done
    pub fn initOpenTypeFeatures(self: *EmbeddedFont) !void {
        if (self.ot_features != null) return;

        const ot = try self.allocator.create(opentype.OpenTypeFeatures);
        ot.* = opentype.OpenTypeFeatures.init(self.allocator);
        errdefer {
            ot.deinit();
            self.allocator.destroy(ot);
        }

        // Parse GSUB table if present (for ligatures)
        if (self.font.getTable("GSUB".*)) |gsub_data| {
            try ot.parseGSUB(gsub_data, self.font.getTable("GDEF".*));
        }

        // Parse GPOS table if present (for kerning)
        if (self.font.getTable("GPOS".*)) |gpos_data| {
            try ot.parseGPOS(gpos_data);
        }

        // Legacy 'kern' table only when GPOS has no kerning (as HarfBuzz)
        if (ot.kern_lookups.items.len == 0) {
            if (self.font.getTable("kern".*)) |kern_data| {
                const t = KernTable.parse(kern_data);
                if (t.count > 0) ot.legacy_kern = t;
            }
        }

        self.ot_features = ot;

        // Cache flags for fast render-time checks
        self.has_kern_data = ot.kern_lookups.items.len > 0 or ot.legacy_kern != null;
        self.has_mark_data = ot.mark_base_lookups.items.len > 0 or ot.mark_mark_lookups.items.len > 0;
    }

    /// Set OpenType feature flag
    pub fn setFeature(self: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void {
        self.feature_flags.set(feature, enabled);
    }

    /// Mark Unicode codepoints as used (CID mode)
    /// Parses UTF-8 text and records Unicode→GlyphID mappings
    /// Applies ligature substitution if enabled
    /// Mark Unicode characters as used for subsetting and return the computed glyph sequence.
    /// Returns the final glyph sequence (caller owns the memory) for caching.
    /// Mark unicode chars as used for subsetting and return glyph IDs.
    /// output_allocator: allocator for the returned glyph slice (if null, uses self.allocator)
    /// True if any feature that affects shaping or positioning is enabled -
    /// the condition for lazily parsing GSUB/GPOS.
    fn anyShapingFeatureEnabled(self: *const EmbeddedFont) bool {
        return std.mem.indexOfScalar(bool, &self.feature_flags.flags, true) != null;
    }

    /// True if any enabled GSUB feature has lookups in this font, i.e. the
    /// rendered glyph sequence may differ from the codepoint sequence.
    fn hasActiveGsub(self: *const EmbeddedFont, ot: *opentype.OpenTypeFeatures) !bool {
        return ot.hasActiveGsub(self.feature_flags);
    }

    /// Decode UTF-8 `text` into `scratch_codepoints` and their nominal
    /// glyphs in `scratch_glyphs`, composing a base + combining marks into
    /// the precomposed character when this font has a glyph for it (the
    /// normalization HarfBuzz does before shaping). Every identity shaping
    /// path - rendering and measurement - decodes here, so they agree.
    /// Invalid sequences are skipped; a truncated one ends the text.
    fn decodeText(self: *EmbeddedFont, text: []const u8) !void {
        self.scratch_codepoints.clearRetainingCapacity();
        self.scratch_composed.clearRetainingCapacity();
        self.scratch_glyphs.clearRetainingCapacity();
        // Worst case: all ASCII = text.len code points
        try self.scratch_codepoints.ensureTotalCapacity(self.allocator, text.len);
        try self.scratch_composed.ensureTotalCapacity(self.allocator, text.len);
        try self.scratch_glyphs.ensureTotalCapacity(self.allocator, text.len);

        var may_compose = false;
        self.scratch_ignorables = false;
        var i: usize = 0;
        while (i < text.len) {
            const byte = text[i];
            if (byte < 128) {
                self.scratch_codepoints.appendAssumeCapacity(byte);
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (i + len > text.len) break;
            const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch {
                i += 1;
                continue;
            };
            if (codepoint >= unicode_compose.first_mark) may_compose = true;
            if (gsub.Ignorable.of(codepoint) != .none) self.scratch_ignorables = true;
            self.scratch_codepoints.appendAssumeCapacity(codepoint);
            i += len;
        }

        if (may_compose) {
            const ctx = struct {
                font: *const ttf.Font,
                pub fn hasGlyph(c: @This(), cp: u21) bool {
                    return (c.font.getGlyphId(cp) orelse 0) != 0;
                }
            }{ .font = &self.font };
            self.scratch_composed.items.len = self.scratch_codepoints.items.len;
            self.scratch_codepoints.items.len = unicode_compose.composeInPlace(self.scratch_codepoints.items, self.scratch_composed.items, ctx);
            self.scratch_composed.items.len = self.scratch_codepoints.items.len;
        } else {
            self.scratch_composed.appendNTimesAssumeCapacity(false, self.scratch_codepoints.items.len);
        }

        for (self.scratch_codepoints.items) |cp| {
            // ASCII: cached glyph (looked up at font load)
            const gid = if (cp < 128 and self.font.has_ascii_cache) self.font.ascii_glyphs[cp] else self.font.getGlyphId(cp) orelse 0;
            self.scratch_glyphs.appendAssumeCapacity(gid);
        }

        if (self.scratch_ignorables and self.font.cmap_uvs_offset != 0) self.applyVariationSequences();
    }

    /// A variation selector after a character picks the glyph the font's
    /// cmap format 14 lists for the pair, before GSUB, and is consumed - as
    /// in HarfBuzz's normalization. An unlisted pair is left alone: the
    /// selector is a default ignorable, which shaping skips and removes.
    fn applyVariationSequences(self: *EmbeddedFont) void {
        const cps = self.scratch_codepoints.items;
        const composed = self.scratch_composed.items;
        const glyphs = self.scratch_glyphs.items;
        var out: usize = 0;
        var consumed = false;
        var i: usize = 0;
        while (i < cps.len) : (i += 1) {
            cps[out] = cps[i];
            composed[out] = composed[i];
            glyphs[out] = glyphs[i];
            if (i + 1 < cps.len and isVariationSelector(cps[i + 1])) {
                if (self.font.getVariationGlyph(cps[i], cps[i + 1])) |gid| {
                    glyphs[out] = gid;
                    i += 1;
                    consumed = true;
                }
            }
            out += 1;
        }
        if (!consumed) return;
        self.scratch_codepoints.items.len = out;
        self.scratch_composed.items.len = out;
        self.scratch_glyphs.items.len = out;
        self.scratch_ignorables = for (self.scratch_codepoints.items) |cp| {
            if (gsub.Ignorable.of(cp) != .none) break true;
        } else false;
    }

    fn isVariationSelector(cp: u21) bool {
        return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
    }

    /// Record the ToUnicode text of `gid` (first use wins). A glyph that
    /// decodeText composed from base + marks maps to its canonical
    /// decomposition - the text as typed - so copying it back yields the
    /// input, not a normalized form of it.
    fn trackGlyphText(self: *EmbeddedFont, gid: u16, cp: u21, composed: bool) !void {
        if (self.glyph_to_codepoint.contains(gid) or self.ligature_codepoints.contains(gid)) return;
        if (!composed) {
            try self.glyph_to_codepoint.put(self.allocator, gid, cp);
            return;
        }
        var buf: [4]u21 = undefined;
        const seq = try self.allocator.dupe(u21, unicode_compose.decompose(cp, &buf));
        errdefer self.allocator.free(seq);
        try self.ligature_codepoints.put(self.allocator, gid, seq);
    }

    pub fn markUnicodeCharsUsed(self: *EmbeddedFont, text: []const u8, output_allocator: ?std.mem.Allocator) ![]u16 {
        const out_alloc = output_allocator orelse self.allocator;
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(self.font.head.?.units_per_em));

        // First pass: decode text into (composed) codepoints and glyph IDs
        try self.decodeText(text);

        // Use local references for cleaner code
        const codepoints = &self.scratch_codepoints;
        const base_glyphs = &self.scratch_glyphs;

        // Initialize OpenType features if any GSUB/GPOS feature is enabled,
        // or the shaper has ignorables to remove
        if (self.anyShapingFeatureEnabled() or self.scratch_ignorables) {
            try self.initOpenTypeFeatures();
        }

        // Apply GSUB substitutions if enabled (any substitution feature)
        if (base_glyphs.items.len > 0) {
            if (self.ot_features) |ot| {
                if (self.scratch_ignorables or try self.hasActiveGsub(ot)) {
                    // Apply GSUB substitutions, track results, and return glyphs
                    return try self.applyGSUBAndTrack(codepoints.items, self.scratch_composed.items, base_glyphs.items, scale, out_alloc);
                }
            }
        }

        // No GSUB - just track the base glyphs
        for (codepoints.items, self.scratch_composed.items, base_glyphs.items) |cp, composed, gid| {
            if (!self.cid_used_glyphs.contains(cp)) {
                try self.cid_used_glyphs.put(self.allocator, cp, gid);
            }
            try self.trackGlyphText(gid, cp, composed);
            if (!self.cid_glyph_widths.contains(gid)) {
                if (self.font.getGlyphWidth(gid)) |w| {
                    const width: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
                    try self.cid_glyph_widths.put(self.allocator, gid, width);
                }
            }
        }

        // Return copy of base glyphs
        return try out_alloc.dupe(u16, base_glyphs.items);
    }

    /// Shape the decoded text with GSUB and record every output glyph's
    /// width and ToUnicode text (trackClusterText). Glyphs sharing a
    /// cluster came from the code points [cluster, next cluster). Returns
    /// the glyphs (caller owns, out_alloc).
    fn applyGSUBAndTrack(self: *EmbeddedFont, codepoints: []const u21, composed: []const bool, base_glyphs: []const u16, scale: f64, out_alloc: std.mem.Allocator) ![]u16 {
        const ot = self.ot_features orelse return try out_alloc.dupe(u16, base_glyphs);
        const shaped = try ot.shape(base_glyphs, codepoints, self.feature_flags);

        const result = try out_alloc.alloc(u16, shaped.len);
        errdefer out_alloc.free(result);
        for (result, shaped) |*r, g| {
            r.* = g.id;
            try self.trackGlyphWidth(g.id, scale);
        }
        var k: usize = 0;
        while (k < shaped.len) {
            const cluster = shaped[k].cluster;
            var end = k + 1;
            while (end < shaped.len and shaped[end].cluster == cluster) end += 1;
            // Clusters are non-decreasing (left-to-right shaping)
            const next = if (end < shaped.len) shaped[end].cluster else codepoints.len;
            const first: usize = @min(cluster, codepoints.len);
            const last: usize = @max(first, @min(next, codepoints.len));
            if (last > first) try self.trackClusterTextKept(result[k..end], codepoints[first..last], composed[first..last], ot.shaper.dropped.items[first..last]);
            k = end;
        }
        return result;
    }

    /// trackClusterText without the default ignorables shaping removed:
    /// they have no glyph and are no part of a glyph's text (a soft hyphen
    /// must not make "o" extract as "o\u{AD}"). Ignorables a ligature took
    /// up (ZWJ in an emoji sequence) stay.
    fn trackClusterTextKept(self: *EmbeddedFont, glyphs: []const u16, cps: []const u21, composed: []const bool, dropped: []const bool) !void {
        if (std.mem.indexOfScalar(bool, dropped, true) == null) return self.trackClusterText(glyphs, cps, composed);
        var kept_cps: std.ArrayListUnmanaged(u21) = .empty;
        defer kept_cps.deinit(self.allocator);
        var kept_composed: std.ArrayListUnmanaged(bool) = .empty;
        defer kept_composed.deinit(self.allocator);
        for (cps, composed, dropped) |cp, c, d| {
            if (d) continue;
            try kept_cps.append(self.allocator, cp);
            try kept_composed.append(self.allocator, c);
        }
        if (kept_cps.items.len > 0) try self.trackClusterText(glyphs, kept_cps.items, kept_composed.items);
    }

    fn trackGlyphWidth(self: *EmbeddedFont, gid: u16, scale: f64) !void {
        if (self.cid_glyph_widths.contains(gid)) return;
        if (self.font.getGlyphWidth(gid)) |w| {
            const width: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
            try self.cid_glyph_widths.put(self.allocator, gid, width);
        }
    }

    /// ToUnicode text of a cluster's glyphs (first use of a glyph wins).
    /// The text is the cluster's code points as typed (composed ones
    /// decomposed back). One glyph per code point maps glyph by glyph;
    /// so does a cluster a multiple substitution split into one glyph per
    /// code point of the canonical decomposition (ccmp turning U+012F into
    /// dotless i + ogonek), which keeps each glyph's text the same wherever
    /// it occurs. Otherwise (a ligature) the first glyph carries the whole
    /// text and the others none, so extracted text holds it once.
    fn trackClusterText(self: *EmbeddedFont, glyphs: []const u16, cps: []const u21, composed: []const bool) !void {
        if (cps.len == 1 and !self.cid_used_glyphs.contains(cps[0])) {
            try self.cid_used_glyphs.put(self.allocator, cps[0], glyphs[0]);
        }
        if (glyphs.len == 1 and cps.len == 1) return self.trackGlyphText(glyphs[0], cps[0], composed[0]);
        // Text is fixed at a glyph's first use: nothing to do once all are
        // mapped (the common case for a repeated ligature)
        for (glyphs) |gid| {
            if (!self.glyph_to_codepoint.contains(gid) and !self.ligature_codepoints.contains(gid)) break;
        } else return;

        var typed: std.ArrayListUnmanaged(u21) = .empty;
        defer typed.deinit(self.allocator);
        var decomposed: std.ArrayListUnmanaged(u21) = .empty;
        defer decomposed.deinit(self.allocator);
        for (cps, composed) |cp, c| {
            var buf: [8]u21 = undefined;
            const full = unicode_compose.decompose(cp, &buf);
            try typed.appendSlice(self.allocator, if (c) full else &.{cp});
            try decomposed.appendSlice(self.allocator, full);
        }
        for ([_][]const u21{ typed.items, decomposed.items }) |text| {
            if (text.len != glyphs.len) continue;
            for (glyphs, text) |gid, cp| try self.trackGlyphText(gid, cp, false);
            return;
        }
        // Ligature. A glyph already mapped to a single code point keeps it
        // (Inter has a direct glyph for U+21D4 and a <=> ligature to it).
        const gid = glyphs[0];
        if (self.glyph_to_codepoint.contains(gid) or self.ligature_codepoints.contains(gid)) return;
        if (typed.items.len == 1) return self.trackGlyphText(gid, typed.items[0], false);
        const owned = try typed.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        try self.ligature_codepoints.put(self.allocator, gid, owned);
    }

    /// Get glyph sequence for text with ligature substitution applied
    /// Returns allocated slice that caller must free
    pub fn getGlyphsForText(self: *EmbeddedFont, text: []const u8) ![]u16 {
        try self.decodeText(text);
        if (self.scratch_ignorables) try self.initOpenTypeFeatures();
        if (self.ot_features) |ot| {
            if (self.scratch_ignorables or try self.hasActiveGsub(ot)) {
                return ot.glyphIds(self.scratch_glyphs.items, self.scratch_codepoints.items, self.feature_flags);
            }
        }
        return self.allocator.dupe(u16, self.scratch_glyphs.items);
    }

    /// Get kerning value between two glyphs (in font units)
    pub fn getKerning(self: *EmbeddedFont, glyph1: u16, glyph2: u16) i16 {
        if (!self.feature_flags.isEnabled(.kern)) return 0;

        if (self.ot_features) |ot| {
            return ot.getKerning(glyph1, glyph2);
        }
        return 0;
    }

    /// Get mark positioning offset for a mark glyph following a base glyph
    /// Returns (dx, dy) in font units (design units), or null if no positioning applies
    pub fn getMarkOffset(self: *EmbeddedFont, base_glyph: u16, mark_glyph: u16) ?opentype.MarkOffset {
        if (!self.feature_flags.isEnabled(.mark) and !self.feature_flags.isEnabled(.mkmk)) return null;

        if (self.ot_features) |ot| {
            return ot.getMarkOffset(base_glyph, mark_glyph);
        }
        return null;
    }

    /// Get glyph ID for a Unicode codepoint (CID mode)
    /// Returns remapped GID if subsetting with remapping is enabled, otherwise original GID
    /// Returns 0 (notdef) if codepoint not found
    pub fn getGlyphIdForCodepoint(self: *const EmbeddedFont, codepoint: u21) u16 {
        const orig_gid = self.cid_used_glyphs.get(codepoint) orelse return 0;
        // If remapping is active, return the new compact GID
        if (self.gid_remap.count() > 0) {
            return self.gid_remap.get(orig_gid) orelse 0;
        }
        return orig_gid;
    }

    /// Parsed COLR/CPAL tables plus the glyf context needed to render color
    /// glyph outlines. Slices reference the font `data`.
    pub const ColorInfo = struct {
        colr: colr.Colr,
        cpal: colr.Cpal,
        glyf: colr.GlyfContext,
    };

    /// Lazily probe and return the font's COLR v1 / CPAL color tables, or null
    /// if the font is not a (supported) color font.
    pub fn colorInfo(self: *EmbeddedFont) ?ColorInfo {
        if (!self.color_checked) {
            self.color_checked = true;
            self.color_info = parseColorInfo(self);
        }
        return self.color_info;
    }

    fn parseColorInfo(self: *EmbeddedFont) ?ColorInfo {
        const colr_data = self.font.getTable("COLR".*) orelse return null;
        const cpal_data = self.font.getTable("CPAL".*) orelse return null;
        const glyf_data = self.font.getTable("glyf".*) orelse return null;
        const loca_data = self.font.getTable("loca".*) orelse return null;
        const head = self.font.head orelse return null;
        const c = colr.Colr.parse(colr_data) catch return null;
        const p = colr.Cpal.parse(cpal_data) catch return null;
        return .{
            .colr = c,
            .cpal = p,
            .glyf = .{ .glyf = glyf_data, .loca = loca_data, .loca_format = head.index_to_loc_format },
        };
    }

    /// True if `gid` is a COLR base glyph (v1 paint graph or v0 layer records).
    pub fn isColorGlyph(self: *EmbeddedFont, gid: u16) bool {
        const info = self.colorInfo() orelse return false;
        return info.colr.isColorGlyph(gid);
    }

    /// Lazily probe and return the font's CBDT/CBLC or sbix bitmap strike, or
    /// null if the font has none (or has COLR, which takes priority as it is
    /// vector data).
    pub fn bitmapInfo(self: *EmbeddedFont) ?bitmap_glyphs.BitmapInfo {
        if (!self.bitmap_checked) {
            self.bitmap_checked = true;
            self.bitmap_info = parseBitmapInfo(self);
        }
        return self.bitmap_info;
    }

    /// Lazily probe and return the font's OT 'SVG ' table, or null if the
    /// font has none (or has COLR, which takes priority).
    pub fn svgInfo(self: *EmbeddedFont) ?svg_table.SvgTable {
        if (!self.svg_checked) {
            self.svg_checked = true;
            self.svg_info = parseSvgInfo(self);
        }
        return self.svg_info;
    }

    fn parseSvgInfo(self: *EmbeddedFont) ?svg_table.SvgTable {
        if (self.colorInfo() != null) return null;
        const data = self.font.getTable("SVG ".*) orelse return null;
        return svg_table.SvgTable.parse(data) catch null;
    }

    /// True if `gid` has a (supported) SVG document in the 'SVG ' table.
    pub fn isSvgGlyph(self: *EmbeddedFont, gid: u16) bool {
        const info = self.svgInfo() orelse return false;
        return info.docForGlyph(gid) != null;
    }

    fn parseBitmapInfo(self: *EmbeddedFont) ?bitmap_glyphs.BitmapInfo {
        if (self.colorInfo() != null) return null;
        if (self.svgInfo() != null) return null;
        if (self.font.getTable("CBLC".*)) |cblc| {
            if (self.font.getTable("CBDT".*)) |cbdt_data| {
                const parsed = bitmap_glyphs.Cbdt.parse(cblc, cbdt_data) catch return null;
                return .{ .cbdt = parsed };
            }
        }
        if (self.font.getTable("sbix".*)) |sbix_data| {
            const num_glyphs = if (self.font.maxp) |m| m.num_glyphs else return null;
            const parsed = bitmap_glyphs.Sbix.parse(sbix_data, num_glyphs) catch return null;
            return .{ .sbix = parsed };
        }
        // EBDT/EBLC monochrome strikes (OTB pixel fonts) — but only when the
        // font has no real outlines; classic outline+strike CJK fonts keep
        // rendering their (scalable) outlines instead.
        const glyf = self.font.getTable("glyf".*);
        if (glyf == null or glyf.?.len == 0) {
            if (self.font.getTable("EBLC".*)) |eblc| {
                if (self.font.getTable("EBDT".*)) |ebdt_data| {
                    const parsed = bitmap_glyphs.Cbdt.parse(eblc, ebdt_data) catch return null;
                    if (parsed.bit_depth != 1) return null; // grayscale unsupported
                    return .{ .cbdt = parsed };
                }
            }
        }
        return null;
    }

    /// True if `gid` has a PNG bitmap in the font's chosen strike.
    pub fn isBitmapGlyph(self: *EmbeddedFont, gid: u16) bool {
        const info = self.bitmapInfo() orelse return false;
        return info.isBitmapGlyph(gid);
    }

    /// Glyph advance width in original font units (glyph space), used for
    /// Type3 color-glyph Widths.
    pub fn glyphAdvanceFontUnits(self: *const EmbeddedFont, gid: u16) u16 {
        return self.font.getGlyphWidth(gid) orelse 0;
    }

    /// Get width for a glyph ID (CID mode), in 1/1000 em
    pub fn getGlyphWidth(self: *const EmbeddedFont, gid: u16) u16 {
        // First check cached widths (already scaled to 1/1000 em)
        if (self.cid_glyph_widths.get(gid)) |w| return w;

        // Fall back to getting width directly from font and scaling
        if (self.font.getGlyphWidth(gid)) |w| {
            const units_per_em = self.font.head.?.units_per_em;
            const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(units_per_em));
            return @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
        }
        return 0;
    }

    /// Get width for a Unicode codepoint (CID mode), in 1/1000 em
    /// Returns 0 if codepoint not found in font
    pub fn getCodepointWidth(self: *const EmbeddedFont, codepoint: u21) u16 {
        const gid = self.getGlyphIdForCodepoint(codepoint);
        if (gid == 0) return 0;
        return self.getGlyphWidth(gid);
    }

    /// Count used glyphs in CID mode
    pub fn countUsedGlyphs(self: *const EmbeddedFont) usize {
        return self.cid_used_glyphs.count();
    }

    /// Get font data for PDF embedding (subset if available, else full)
    /// For CFF fonts, returns just the CFF table data (not the full OTF wrapper)
    pub fn getFontData(self: *EmbeddedFont) []const u8 {
        if (self.subset_data) |subset| {
            return subset;
        }

        // For CFF fonts, extract just the CFF table
        if (self.font.isCFF()) {
            if (self.font.getTable("CFF ".*)) |cff_data| {
                return cff_data;
            }
            if (self.font.getTable("CFF2".*)) |cff2_data| {
                return cff2_data;
            }
        }

        return self.data;
    }

    /// Generate subset font data containing only used glyphs
    pub fn generateSubset(self: *EmbeddedFont) !void {
        // If already generated, skip
        if (self.subset_data != null) return;

        // Check if any chars are used
        const has_winansi_chars = self.countUsedChars() > 0;
        const has_cid_chars = self.countUsedGlyphs() > 0;
        if (!has_winansi_chars and !has_cid_chars) return;

        // CFF fonts: use compact CFF subsetting with glyph ID remapping
        // Content is now rendered after subsetting (lazy generation) so remapping works
        if (self.font.isCFF()) {
            if (self.encoding == .identity) {
                self.subset_data = try createSubsetCFF_Compact(self.allocator, self);
            }
            return;
        }

        // CID mode (Identity-H encoding): use compact TTF subsetting with glyph ID remapping
        // Lazy content generation ensures content is rendered after subsetting populates gid_remap
        if (self.encoding == .identity) {
            self.subset_data = try createSubsetTTF_Compact(self.allocator, self);
            return;
        }

        // TrueType fonts in WinAnsi mode: generate subset with glyph remapping
        self.subset_data = try createSubsetTTF(self.allocator, self);
    }

    /// Get character width for a byte value (WinAnsi encoded)
    pub fn getCharWidth(self: *const EmbeddedFont, char: u8) u16 {
        return self.widths[char];
    }

    /// Get text width in points.
    /// For identity encoding, decodes UTF-8 and uses actual glyph widths.
    /// For WinAnsi encoding, uses byte-indexed width table.
    pub fn measureTextWidth(self: *EmbeddedFont, text: []const u8, size: f64) f64 {
        return self.measureTextWidthSpaced(text, size, 0);
    }

    /// Measure text width in points, including char_spacing (added between
    /// rendered glyphs, matching the Tc operator emitted at render time).
    /// Applies the same GSUB substitutions as rendering, so ligature-bearing
    /// strings measure exactly as wide as they draw.
    pub fn measureTextWidthSpaced(self: *EmbeddedFont, text: []const u8, size: f64, char_spacing: f64) f64 {
        // GSUB/GPOS are parsed lazily on first render. Initialize here too,
        // so a measurement taken before the first render agrees with one
        // taken after - justification and alignment depend on the width of
        // a string being stable over time.
        if (self.ot_features == null and self.anyShapingFeatureEnabled()) {
            self.initOpenTypeFeatures() catch {};
        }

        if (self.encoding != .identity) {
            // WinAnsi encoding: use byte-indexed width table
            var total: u64 = 0; // u32 overflows past ~65K maximal glyphs
            for (text) |c| {
                total += self.widths[c];
            }
            var result = @as(f64, @floatFromInt(total)) * size / 1000.0;
            if (text.len > 1) {
                result += char_spacing * @as(f64, @floatFromInt(text.len - 1));
            }
            return result;
        }

        // When GSUB substitutions are active the rendered glyph sequence
        // differs from the codepoint sequence (ligatures, alternates) -
        // measure the shaped sequence so measure == render.
        if (self.ot_features) |ot| {
            if (self.hasActiveGsub(ot) catch true) {
                if (self.measureShaped(text, size, char_spacing, ot)) |width| {
                    return width;
                } else |_| {} // OOM etc: fall through to unshaped estimate
            }
        }
        // Combining marks may compose into precomposed glyphs, and default
        // ignorables are removed by the shaper (decodeText finds both)
        if (mayNeedDecoding(text)) {
            if (self.decodeText(text)) {
                if (self.scratch_ignorables) {
                    self.initOpenTypeFeatures() catch {};
                    if (self.ot_features) |ot| {
                        if (self.measureShaped(text, size, char_spacing, ot)) |width| {
                            return width;
                        } else |_| {}
                    }
                }
                return self.glyphSequenceWidth(self.scratch_glyphs.items, size, char_spacing);
            } else |_| {} // OOM: fall through to unshaped estimate
        }
        return self.measureUnshaped(text, size, char_spacing);
    }

    /// Identity-encoding measurement without GSUB: per-codepoint advances
    /// plus kerning. Exact when the font has no active substitutions.
    fn measureUnshaped(self: *EmbeddedFont, text: []const u8, size: f64, char_spacing: f64) f64 {
        const units_per_em = self.font.head.?.units_per_em;
        const em: i64 = units_per_em;
        const has_ascii_widths = self.font.has_ascii_widths;
        const do_kerning = self.feature_flags.isEnabled(.kern) and self.has_kern_data and self.ot_features != null;

        var total: i64 = 0; // i32 overflows past ~32K maximal glyphs
        var glyph_count: usize = 0;
        var prev_gid: u16 = 0;
        var has_prev: bool = false;

        var i: usize = 0;
        while (i < text.len) {
            const byte = text[i];
            var gid: u16 = 0;
            var width: u16 = 0;

            if (byte < 128) {
                // ASCII fast path: use cached width directly
                if (has_ascii_widths) {
                    width = self.font.ascii_widths[byte];
                    gid = self.font.ascii_glyphs[byte];
                } else if (self.font.has_ascii_cache) {
                    gid = self.font.ascii_glyphs[byte];
                    width = self.font.getGlyphWidth(gid) orelse 0;
                } else {
                    gid = self.font.getGlyphId(byte) orelse 0;
                    width = self.font.getGlyphWidth(gid) orelse 0;
                }
                i += 1;
            } else {
                // Multi-byte UTF-8
                const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                if (i + len > text.len) break;
                const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch {
                    i += 1;
                    continue;
                };
                gid = self.font.getGlyphId(codepoint) orelse 0;
                width = self.font.getGlyphWidth(gid) orelse 0;
                i += len;
            }

            // Add glyph width (scaled to 1/1000 em)
            total += thousandths(width, em);
            glyph_count += 1;

            // Add kerning from previous glyph
            if (do_kerning and has_prev) {
                const kern = self.ot_features.?.getKerning(prev_gid, gid);
                total += @divTrunc(@as(i64, kern) * 1000, em);
            }

            prev_gid = gid;
            has_prev = true;
        }

        var result = @as(f64, @floatFromInt(total)) * size / 1000.0;
        if (glyph_count > 1) {
            result += char_spacing * @as(f64, @floatFromInt(glyph_count - 1));
        }
        return result;
    }

    /// Identity-encoding measurement through the same GSUB pipeline the
    /// renderer uses: decode to base glyphs, substitute, then sum the final
    /// glyph advances plus kerning and char_spacing.
    fn measureShaped(self: *EmbeddedFont, text: []const u8, size: f64, char_spacing: f64, ot: *opentype.OpenTypeFeatures) !f64 {
        // Same decoding (and composition) as markUnicodeCharsUsed, so
        // shaping input matches rendering
        try self.decodeText(text);

        const final_glyphs = try ot.glyphIds(self.scratch_glyphs.items, self.scratch_codepoints.items, self.feature_flags);
        defer self.allocator.free(final_glyphs);

        return self.glyphSequenceWidth(final_glyphs, size, char_spacing);
    }

    /// Width in points of an already-shaped glyph sequence (advances +
    /// kerning + char_spacing). Used by measureShaped and by writeAt, which
    /// already has the shaped run and must not shape a second time.
    /// A glyph advance in 1/1000 em, rounded exactly as the PDF width
    /// arrays (/W, /Widths) store it: measurement sums the widths viewers
    /// advance by.
    fn thousandths(width: u16, em: i64) i64 {
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(em));
        return @intFromFloat(@round(@as(f64, @floatFromInt(width)) * scale));
    }

    pub fn glyphSequenceWidth(self: *EmbeddedFont, glyphs: []const u16, size: f64, char_spacing: f64) f64 {
        const em: i64 = self.font.head.?.units_per_em;
        const do_kerning = self.feature_flags.isEnabled(.kern) and self.has_kern_data and self.ot_features != null;

        var total: i64 = 0; // i32 overflows past ~32K maximal glyphs
        var prev_gid: u16 = 0;
        var has_prev: bool = false;
        for (glyphs) |gid| {
            const width = self.font.getGlyphWidth(gid) orelse 0;
            total += thousandths(width, em);
            if (do_kerning and has_prev) {
                total += @divTrunc(@as(i64, self.ot_features.?.getKerning(prev_gid, gid)) * 1000, em);
            }
            prev_gid = gid;
            has_prev = true;
        }

        var result = @as(f64, @floatFromInt(total)) * size / 1000.0;
        if (glyphs.len > 1) {
            result += char_spacing * @as(f64, @floatFromInt(glyphs.len - 1));
        }
        return result;
    }

    /// Generate ToUnicode CMap for PDF text extraction/copy-paste
    /// Maps WinAnsi byte values to Unicode codepoints
    pub fn generateToUnicodeCMap(self: *const EmbeddedFont) ![]const u8 {
        var cmap = std.ArrayListUnmanaged(u8).empty;
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

    /// Generate ToUnicode CMap for CID mode (2-byte glyph IDs → Unicode)
    /// Includes ligature glyph → component codepoints mappings for proper text extraction
    pub fn generateCIDToUnicodeCMap(self: *const EmbeddedFont) ![]const u8 {
        var cmap = std.ArrayListUnmanaged(u8).empty;
        errdefer cmap.deinit(self.allocator);

        // CMap header - note 2-byte codespace for CID
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
            \\<0000> <FFFF>
            \\endcodespacerange
            \\
        );

        // Count entries: regular glyphs + ligature glyphs
        // Use glyph_to_codepoint for regular glyphs (handles calt variants where same codepoint → different glyphs)
        const regular_count = self.glyph_to_codepoint.count();
        const ligature_count = self.ligature_codepoints.count();
        const total_count = regular_count + ligature_count;

        if (total_count > 0) {
            // Write bfchar entries (glyph ID → Unicode codepoint(s))
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d} beginbfchar\n", .{total_count}) catch unreachable;
            try cmap.appendSlice(self.allocator, count_str);

            const has_remap = self.gid_remap.count() > 0;

            // Regular glyphs: glyph → single Unicode codepoint
            var iter = self.glyph_to_codepoint.iterator();
            while (iter.next()) |entry| {
                const orig_gid = entry.key_ptr.*;
                const codepoint = entry.value_ptr.*;
                const gid = if (has_remap) self.gid_remap.get(orig_gid) orelse 0 else orig_gid;
                var entry_buf: [48]u8 = undefined;

                if (codepoint > 0xFFFF) {
                    const adjusted = codepoint - 0x10000;
                    const high: u16 = @intCast(0xD800 + (adjusted >> 10));
                    const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                    const len = format.writeCMapEntrySurrogate(&entry_buf, gid, high, low);
                    try cmap.appendSlice(self.allocator, entry_buf[0..len]);
                } else {
                    const len = format.writeCMapEntry(&entry_buf, gid, codepoint);
                    try cmap.appendSlice(self.allocator, entry_buf[0..len]);
                }
            }

            // Ligature glyphs: ligature glyph → sequence of Unicode codepoints
            var lig_iter = self.ligature_codepoints.iterator();
            while (lig_iter.next()) |entry| {
                const orig_lig_gid = entry.key_ptr.*;
                const lig_codepoints = entry.value_ptr.*;
                const lig_gid = if (has_remap) self.gid_remap.get(orig_lig_gid) orelse 0 else orig_lig_gid;

                // Format: <GID> <UTF16_CODEPOINT_SEQUENCE>
                var entry_buf: [128]u8 = undefined;
                var len: usize = 0;

                entry_buf[len] = '<';
                len += 1;
                format.writeHex4(entry_buf[len..][0..4], lig_gid);
                len += 4;
                @memcpy(entry_buf[len..][0..3], "> <");
                len += 3;

                for (lig_codepoints) |cp| {
                    if (cp > 0xFFFF) {
                        const adjusted = cp - 0x10000;
                        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
                        const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                        format.writeHex4(entry_buf[len..][0..4], high);
                        len += 4;
                        format.writeHex4(entry_buf[len..][0..4], low);
                        len += 4;
                    } else {
                        format.writeHex4(entry_buf[len..][0..4], @intCast(cp));
                        len += 4;
                    }
                }
                @memcpy(entry_buf[len..][0..2], ">\n");
                len += 2;

                try cmap.appendSlice(self.allocator, entry_buf[0..len]);
            }

            try cmap.appendSlice(self.allocator, "endbfchar\n");
        }

        // CMap footer
        try cmap.appendSlice(self.allocator,
            \\endcmap
            \\CMapName currentdict /CMap defineresource pop
            \\end
            \\end
        );

        return cmap.toOwnedSlice(self.allocator);
    }

    /// Generate /W array for CID font (per-glyph widths)
    /// Format: [gid [w1 w2 ...] gid [w1 w2 ...] ...]
    pub fn generateWidthArray(self: *const EmbeddedFont) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "[");

        const has_remap = self.gid_remap.count() > 0;

        // Get sorted glyph IDs for consistent output
        // If remapping, we need to collect the NEW glyph IDs
        const GidWidthPair = struct { gid: u16, width: u16 };
        var gid_width_pairs = std.ArrayListUnmanaged(GidWidthPair).empty;
        defer gid_width_pairs.deinit(self.allocator);

        var iter = self.cid_glyph_widths.iterator();
        while (iter.next()) |entry| {
            const orig_gid = entry.key_ptr.*;
            const width = entry.value_ptr.*;
            const gid = if (has_remap) self.gid_remap.get(orig_gid) orelse 0 else orig_gid;
            try gid_width_pairs.append(self.allocator, .{ .gid = gid, .width = width });
        }

        // Sort by glyph ID
        std.mem.sort(GidWidthPair, gid_width_pairs.items, {}, struct {
            fn lessThan(_: void, a: GidWidthPair, b: GidWidthPair) bool {
                return a.gid < b.gid;
            }
        }.lessThan);

        // Output as individual entries: gid [width]
        // Note: space after each entry ensures proper parsing by all PDF readers
        for (gid_width_pairs.items) |pair| {
            var entry_buf: [32]u8 = undefined;
            var len: usize = 0;
            const gid_str = format.writeInt(entry_buf[len..], pair.gid);
            len += gid_str.len;
            @memcpy(entry_buf[len..][0..2], " [");
            len += 2;
            const width_str = format.writeInt(entry_buf[len..], pair.width);
            len += width_str.len;
            @memcpy(entry_buf[len..][0..2], "] ");
            len += 2;
            try buf.appendSlice(self.allocator, entry_buf[0..len]);
        }

        try buf.appendSlice(self.allocator, "]");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Get default width for CID font (most common width, or 0)
    pub fn getDefaultWidth(self: *const EmbeddedFont) u16 {
        // For simplicity, return 0 (all widths specified in /W array)
        // A more sophisticated version could find the most common width
        _ = self;
        return 0;
    }
};

/// Decode font name (handles UTF-16BE from Windows platform)
/// Uses a static buffer, so the result is only valid until the next call.
fn decodeFontName(raw: []const u8) []const u8 {
    // Use static buffer so result persists after function returns
    const S = struct {
        var result: [256]u8 = undefined;
    };

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
            var len: usize = 0;
            var i: usize = 0;
            while (i + 1 < raw.len and len < 255) : (i += 2) {
                if (raw[i] == 0 and raw[i + 1] >= 0x20 and raw[i + 1] < 0x7F) {
                    S.result[len] = raw[i + 1];
                    len += 1;
                }
            }
            if (len > 0) {
                return S.result[0..len];
            }
        }
    }
    return raw;
}

/// Append a loca table entry in the correct format (short or long).
/// Append a loca entry for a subset glyf offset. error.InvalidFont when it
/// is not representable: short loca stores offset / 2 in u16 (glyf up to
/// 0x1FFFE bytes), long loca a u32. A subset can only outgrow its source
/// font through hostile, overlapping glyph ranges.
fn appendLocaEntry(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, offset: usize, loca_format: i16) !void {
    if (loca_format == 0) {
        const half = std.math.cast(u16, offset / 2) orelse return error.InvalidFont;
        try binary.appendBE16(list, allocator, half);
    } else {
        const off = std.math.cast(u32, offset) orelse return error.InvalidFont;
        try binary.appendBE32(list, allocator, off);
    }
}

/// Create a subset TTF containing only the used glyphs
fn createSubsetTTF(allocator: std.mem.Allocator, emb: *const EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const head = font.head orelse return error.MissingTable;
    const hhea = font.hhea orelse return error.MissingTable;
    _ = font.maxp orelse return error.MissingTable; // verify table exists

    // Collect unique glyph IDs we need from both WinAnsi and CID modes
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    // Always include glyph 0 (.notdef). Glyph IDs at or past numGlyphs
    // (reachable via a hostile cmap) do not exist: they stay out of the
    // subset and render as .notdef (remap lookups fall back to 0), which
    // also keeps the subset's glyph count within u16.
    const font_glyphs = font.maxp.?.num_glyphs;
    try glyph_set.put(allocator, 0, {});

    // Collect from WinAnsi mode (used_chars)
    for (0..256) |i| {
        if (emb.used_chars[i]) {
            const unicode = win_ansi_to_unicode[i];
            if (font.getGlyphId(unicode)) |gid| {
                if (gid < font_glyphs) try glyph_set.put(allocator, gid, {});
            }
        }
    }

    // Collect from CID mode (cid_used_glyphs)
    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        if (entry.value_ptr.* < font_glyphs) try glyph_set.put(allocator, entry.value_ptr.*, {});
    }

    // Get original table data
    const orig_glyf = font.getTable("glyf".*) orelse return error.MissingTable;
    const orig_loca = font.getTable("loca".*) orelse return error.MissingTable;
    const orig_hmtx = font.getTable("hmtx".*) orelse return error.MissingTable;

    const loca_format = head.index_to_loc_format; // 0=short, 1=long

    // Composites (e.g. i = dotlessi + dot) need their components too.
    try expandCompositeGlyphs(allocator, &glyph_set, orig_glyf, orig_loca, loca_format, font_glyphs);

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
    var gid_map: std.AutoArrayHashMapUnmanaged(u16, u16) = .empty;
    defer gid_map.deinit(allocator);
    for (glyph_ids, 0..) |old_gid, new_gid| {
        try gid_map.put(allocator, old_gid, @intCast(new_gid));
    }

    const num_glyphs: u16 = @intCast(glyph_ids.len);

    // Build new glyf data
    var new_glyf = std.ArrayListUnmanaged(u8).empty;
    defer new_glyf.deinit(allocator);

    // Build new loca (offsets into glyf)
    var new_loca = std.ArrayListUnmanaged(u8).empty;
    defer new_loca.deinit(allocator);

    for (glyph_ids) |old_gid| {
        // Record offset in new loca
        try appendLocaEntry(&new_loca, allocator, new_glyf.items.len, loca_format);

        // Get glyph bounds from original loca
        const glyph_start = getLocaOffset(orig_loca, old_gid, loca_format);
        const glyph_end = getLocaOffset(orig_loca, @as(usize, old_gid) + 1, loca_format);

        if (glyph_end > glyph_start and glyph_end <= orig_glyf.len) {
            const start = new_glyf.items.len;
            try new_glyf.appendSlice(allocator, orig_glyf[glyph_start..glyph_end]);
            const glyph_data = new_glyf.items[start..];
            if (glyph_data.len >= 2 and std.mem.readInt(i16, glyph_data[0..2], .big) < 0) {
                try rewriteCompositeGlyphIDs(glyph_data, &gid_map);
            }
        }
    }

    // Final loca entry (end of last glyph)
    try appendLocaEntry(&new_loca, allocator, new_glyf.items.len, loca_format);

    // Build new hmtx (horizontal metrics)
    const new_hmtx = try buildHmtxForGlyphs(allocator, orig_hmtx, hhea.num_of_long_hor_metrics, glyph_ids);
    defer allocator.free(new_hmtx);

    // Build cmap with both Format 0 (MacRoman) and Format 4 (Windows Unicode BMP)
    // PDF viewers with WinAnsiEncoding use Platform 3, Encoding 1 (Format 4)
    var new_cmap = std.ArrayListUnmanaged(u8).empty;
    defer new_cmap.deinit(allocator);

    // First, build the Format 4 subtable for Windows Unicode BMP
    // This maps Unicode codepoints to glyph IDs
    var format4 = std.ArrayListUnmanaged(u8).empty;
    defer format4.deinit(allocator);

    // Collect Unicode -> new glyph ID mappings for used characters
    const UnicodeMapping = struct { unicode: u16, glyph_id: u16 };
    var unicode_mappings = std.ArrayListUnmanaged(UnicodeMapping).empty;
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
    // searchRange = 2 * (largest power of 2 <= segCount)
    var search_range: u16 = 1;
    var entry_selector: u16 = 0;
    while (search_range * 2 <= seg_count) {
        search_range *= 2;
        entry_selector += 1;
    }
    search_range *= 2;
    const range_shift = seg_count_x2 - search_range;

    // Format 4 header
    try binary.appendBE16(&format4, allocator, 4); // format
    // Length will be filled in later
    const format4_length_pos = format4.items.len;
    try format4.appendSlice(allocator, &[_]u8{ 0, 0 }); // length placeholder
    try binary.appendBE16(&format4, allocator, 0); // language
    try binary.appendBE16(&format4, allocator, seg_count_x2);
    try binary.appendBE16(&format4, allocator, search_range);
    try binary.appendBE16(&format4, allocator, entry_selector);
    try binary.appendBE16(&format4, allocator, range_shift);

    // endCode array
    for (unicode_mappings.items) |m| {
        try binary.appendBE16(&format4, allocator, m.unicode);
    }
    try binary.appendBE16(&format4, allocator, 0xFFFF); // final segment

    // reservedPad
    try binary.appendBE16(&format4, allocator, 0);

    // startCode array (same as endCode for single-char segments)
    for (unicode_mappings.items) |m| {
        try binary.appendBE16(&format4, allocator, m.unicode);
    }
    try binary.appendBE16(&format4, allocator, 0xFFFF); // final segment

    // idDelta array - we'll use idRangeOffset instead, so delta is 0
    // Actually, for single-char segments, we can use: delta = glyphId - charCode
    for (unicode_mappings.items) |m| {
        const delta: i16 = @as(i16, @intCast(m.glyph_id)) - @as(i16, @intCast(m.unicode));
        try binary.appendBEi16(&format4, allocator, delta);
    }
    try binary.appendBEi16(&format4, allocator, 1); // final segment delta

    // idRangeOffset array (all zeros since we use idDelta)
    for (0..seg_count) |_| {
        try binary.appendBE16(&format4, allocator, 0);
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
    try binary.appendBE32(&new_cmap, allocator, format0_offset);

    // Encoding record 2: Platform 3 (Windows), Encoding 1 (Unicode BMP)
    // Offset = 20 + 262 (format0 size) = 282
    const format4_offset: u32 = 20 + 262;
    try new_cmap.appendSlice(allocator, &[_]u8{ 0, 3, 0, 1 }); // platform 3, encoding 1
    try binary.appendBE32(&new_cmap, allocator, format4_offset);

    // Format 0 subtable (for MacRoman compatibility)
    try binary.appendBE16(&new_cmap, allocator, 0); // format
    try binary.appendBE16(&new_cmap, allocator, 262); // length
    try binary.appendBE16(&new_cmap, allocator, 0); // language

    // Format 0 glyph index array (256 bytes) - maps byte value to glyph
    for (0..256) |i| {
        const unicode = win_ansi_to_unicode[i];
        const orig_gid = font.getGlyphId(unicode) orelse 0;
        const new_gid = gid_map.get(orig_gid) orelse 0;
        // Format 0 holds one-byte glyph IDs; a subset past 256 glyphs (only
        // when CID glyphs join the WinAnsi ones - WinAnsi alone has 252
        // distinct codepoints) maps the rest to .notdef here. The format 4
        // subtable below carries the full mapping.
        try new_cmap.append(allocator, std.math.cast(u8, new_gid) orelse 0);
    }

    // Append Format 4 subtable
    try new_cmap.appendSlice(allocator, format4.items);

    // Assemble the final TTF
    return finishTTFSubset(allocator, font, new_hmtx, new_cmap.items, new_loca.items, new_glyf.items, num_glyphs);
}

/// Create a compact TTF subset with glyph ID remapping
/// Unlike createSubsetTTF_CID, this creates minimal tables with only used glyphs
/// and remaps glyph IDs for maximum size reduction
fn createSubsetTTF_Compact(allocator: std.mem.Allocator, emb: *EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const tables = try SubsetTables.init(emb);

    // Collect used glyph IDs
    // Use cid_glyph_widths instead of cid_used_glyphs because calt substitutions
    // can produce different glyphs for the same codepoint depending on context.
    // cid_glyph_widths tracks ALL glyphs that have been used, regardless of codepoint.
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    try glyph_set.put(allocator, 0, {}); // .notdef

    // Add all glyphs that have width entries (includes contextual variants)
    for (emb.cid_glyph_widths.keys()) |gid| {
        try glyph_set.put(allocator, gid, {});
    }

    // Add ligature glyph IDs (they might not have width entries if not used directly)
    var lig_iter = emb.ligature_codepoints.iterator();
    while (lig_iter.next()) |entry| {
        try glyph_set.put(allocator, entry.key_ptr.*, {});
    }

    // Recursively add composite glyph components
    try expandCompositeGlyphs(allocator, &glyph_set, tables.glyf, tables.loca, tables.loca_format, tables.maxp.num_glyphs);

    // Build sorted glyph list (0 first, then ascending order)
    var glyph_list = std.ArrayListUnmanaged(u16).empty;
    defer glyph_list.deinit(allocator);

    try glyph_list.append(allocator, 0); // .notdef always first

    // Glyph IDs at or past numGlyphs do not exist (see createSubsetTTF).
    var key_iter = glyph_set.keyIterator();
    while (key_iter.next()) |gid| {
        if (gid.* != 0 and gid.* < tables.maxp.num_glyphs) {
            try glyph_list.append(allocator, gid.*);
        }
    }

    // Sort (keeping 0 at front)
    std.mem.sort(u16, glyph_list.items[1..], {}, std.sort.asc(u16));

    // Build glyph ID remap: original GID → new compact GID
    emb.gid_remap.clearRetainingCapacity();
    for (glyph_list.items, 0..) |orig_gid, new_gid| {
        try emb.gid_remap.put(emb.allocator, orig_gid, @intCast(new_gid));
    }

    const num_glyphs: u16 = @intCast(glyph_list.items.len);

    // Build compact glyf and loca tables
    var new_glyf = std.ArrayListUnmanaged(u8).empty;
    defer new_glyf.deinit(allocator);

    var new_loca = std.ArrayListUnmanaged(u8).empty;
    defer new_loca.deinit(allocator);

    // Process glyphs in new order
    for (glyph_list.items) |orig_gid| {
        // Record offset
        try appendLocaEntry(&new_loca, allocator, new_glyf.items.len, tables.loca_format);

        // Get original glyph data
        if (orig_gid < tables.maxp.num_glyphs) {
            const glyph_start = getLocaOffset(tables.loca, orig_gid, tables.loca_format);
            const glyph_end = getLocaOffset(tables.loca, @as(usize, orig_gid) + 1, tables.loca_format);

            if (glyph_end > glyph_start and glyph_end <= tables.glyf.len) {
                var glyph_data = try allocator.alloc(u8, glyph_end - glyph_start);
                defer allocator.free(glyph_data);
                @memcpy(glyph_data, tables.glyf[glyph_start..glyph_end]);

                // Check if composite and rewrite component references
                if (glyph_data.len >= 2) {
                    const num_contours = @as(i16, @bitCast(std.mem.readInt(u16, glyph_data[0..2], .big)));
                    if (num_contours < 0) {
                        // Composite glyph - rewrite component glyph IDs
                        try rewriteCompositeGlyphIDs(glyph_data, &emb.gid_remap);
                    }
                }

                try new_glyf.appendSlice(allocator, glyph_data);
            }
        }
    }

    // Final loca entry
    try appendLocaEntry(&new_loca, allocator, new_glyf.items.len, tables.loca_format);

    // Build compact hmtx
    const new_hmtx = try buildHmtxForGlyphs(allocator, tables.hmtx, tables.hhea.num_of_long_hor_metrics, glyph_list.items);
    defer allocator.free(new_hmtx);

    // Build minimal cmap (same as CID version)
    const new_cmap = try buildMinimalCmap(allocator);
    defer allocator.free(new_cmap);

    // Assemble the final TTF
    return finishTTFSubset(allocator, font, new_hmtx, new_cmap, new_loca.items, new_glyf.items, num_glyphs);
}

/// Helper to finish TTF subset assembly - gets required tables from font and calls assembleTTF.
fn finishTTFSubset(
    allocator: std.mem.Allocator,
    font: *const ttf.Font,
    hmtx: []const u8,
    cmap: []const u8,
    loca: []const u8,
    glyf: []const u8,
    num_glyphs: u16,
) ![]const u8 {
    const orig_head = font.getTable("head".*) orelse return error.MissingTable;
    const orig_hhea = font.getTable("hhea".*) orelse return error.MissingTable;
    const orig_maxp = font.getTable("maxp".*) orelse return error.MissingTable;
    const orig_name = font.getTable("name".*);
    const orig_post = font.getTable("post".*);
    const orig_os2 = font.getTable("OS/2".*); // OS/2 table - required by PDF validators

    // assembleTTF needs mutable hhea to update numOfLongHorMetrics
    const new_hhea = try allocator.dupe(u8, orig_hhea);
    defer allocator.free(new_hhea);

    // Build minimal name table (reduces ~17KB to ~300 bytes for Gentium fonts)
    const min_name = try buildMinimalNameTable(allocator, orig_name);
    defer allocator.free(min_name);

    return assembleTTF(allocator, .{
        .head = orig_head,
        .hhea = new_hhea,
        .maxp = orig_maxp, // Original maxp - assembleTTF updates numGlyphs
        .hmtx = hmtx,
        .cmap = cmap,
        .loca = loca,
        .glyf = glyf,
        .name = min_name,
        .post = orig_post,
        .os2 = orig_os2,
        .num_glyphs = num_glyphs,
    });
}

/// Parsed CFF file layout with offsets to each section.
const CFFLayout = struct {
    hdr_size: usize,
    name_end: usize,
    topdict_start: usize,
    topdict_end: usize,
    string_start: usize,
    string_end: usize,
    gsubr_start: usize,
    gsubr_end: usize,

    fn parse(cff_data: []const u8) error{InvalidCFF}!CFFLayout {
        if (cff_data.len < 4) return error.InvalidCFF; // header: major, minor, hdrSize, offSize
        const hdr_size: usize = cff_data[2];
        const name_end = skipCFFIndex(cff_data, hdr_size);
        const topdict_end = skipCFFIndex(cff_data, name_end);
        const string_end = skipCFFIndex(cff_data, topdict_end);
        const gsubr_end = skipCFFIndex(cff_data, string_end);
        return .{
            .hdr_size = hdr_size,
            .name_end = name_end,
            .topdict_start = name_end,
            .topdict_end = topdict_end,
            .string_start = topdict_end,
            .string_end = string_end,
            .gsubr_start = string_end,
            .gsubr_end = gsubr_end,
        };
    }
};

/// Smallest CFF offSize (1-4 bytes) that holds `max_offset` - for an
/// INDEX, the last offset, data.len + 1 (comparing data.len < 256 was off
/// by one: 255 bytes need offset 256).
fn cffOffSize(max_offset: usize) error{InvalidCFF}!u8 {
    if (max_offset <= 0xFF) return 1;
    if (max_offset <= 0xFFFF) return 2;
    if (max_offset <= 0xFF_FFFF) return 3;
    if (max_offset <= 0xFFFF_FFFF) return 4;
    return error.InvalidCFF;
}

/// Append a CFF offset value with the specified size (1-4 bytes); `off`
/// must fit (see cffOffSize).
fn appendCffOffset(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, off: u32, off_size: u8) !void {
    switch (off_size) {
        1 => try list.append(allocator, @intCast(off)),
        2 => try binary.appendBE16(list, allocator, @intCast(off)),
        3 => {
            std.debug.assert(off <= 0xFF_FFFF);
            const off_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, off));
            try list.appendSlice(allocator, off_bytes[1..4]);
        },
        4 => try binary.appendBE32(list, allocator, off),
        else => unreachable,
    }
}

/// Build a CFF INDEX structure containing a single item.
/// CFF INDEX format: count(2) + offSize(1) + offsets(offSize * (count+1)) + data
fn appendCffSingleItemIndex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    // Count = 1 (big-endian u16)
    try binary.appendBE16(list, allocator, 1);

    // Offsets: first offset is always 1, second is data.len + 1
    const off_size = try cffOffSize(data.len + 1);
    try list.append(allocator, off_size);
    try appendCffOffset(list, allocator, 1, off_size);
    try appendCffOffset(list, allocator, @intCast(data.len + 1), off_size);

    // Data
    try list.appendSlice(allocator, data);
}

/// Create a compact subset CFF with glyph ID remapping
/// This achieves better compression than createSubsetCFF by only including used glyphs
/// and remapping glyph IDs to 0, 1, 2, ...
fn createSubsetCFF_Compact(allocator: std.mem.Allocator, emb: *EmbeddedFont) ![]const u8 {
    const cff_data = emb.font.getCFFTable() orelse return error.MissingTable;

    // Parse the CFF structure first: the CharStrings count bounds which glyph
    // IDs exist. All INDEX reads go through the bounds-checked CFFIndex.
    const cff = try CFFLayout.parse(cff_data);
    const global_subrs = parseCFFIndex(cff_data, cff.gsubr_start);
    const charstrings_offset = parseCFFTopDictForCharStrings(cff_data, cff.topdict_start) orelse
        return error.InvalidCFF;
    const charstrings = parseCFFIndex(cff_data, charstrings_offset) orelse return error.InvalidCFF;
    const cs_count = charstrings.count;
    if (cs_count == 0) return error.InvalidCFF;

    // Collect used glyph IDs into sorted list
    var glyph_list = std.ArrayListUnmanaged(u16).empty;
    defer glyph_list.deinit(allocator);

    try glyph_list.append(allocator, 0); // .notdef always first

    // Use a set to avoid duplicates
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    // Glyph IDs at or past the CharStrings count do not exist: they stay out
    // of the subset (rendering as .notdef) and keep its count within u16.
    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        const gid = entry.value_ptr.*;
        if (gid != 0 and gid < cs_count) {
            try glyph_set.put(allocator, gid, {});
        }
    }
    // Every drawn glyph has a width entry - contextual variants and the
    // extra glyphs of multiple substitutions included, which no code point
    // maps to (as createSubsetTTF_Compact)
    for (emb.cid_glyph_widths.keys()) |gid| {
        if (gid != 0 and gid < cs_count) try glyph_set.put(allocator, gid, {});
    }

    // Add ligature glyph IDs
    var lig_iter = emb.ligature_codepoints.iterator();
    while (lig_iter.next()) |entry| {
        const lig_gid = entry.key_ptr.*;
        if (lig_gid != 0 and lig_gid < cs_count) {
            try glyph_set.put(allocator, lig_gid, {});
        }
    }

    // Convert set to list
    var set_iter = glyph_set.keyIterator();
    while (set_iter.next()) |gid| {
        try glyph_list.append(allocator, gid.*);
    }

    // Sort glyph IDs (keeps .notdef at 0, others in ascending order)
    std.mem.sort(u16, glyph_list.items[1..], {}, std.sort.asc(u16));

    // Build glyph ID remap: original GID → new compact GID
    emb.gid_remap.clearRetainingCapacity();
    for (glyph_list.items, 0..) |orig_gid, new_gid| {
        try emb.gid_remap.put(emb.allocator, orig_gid, @intCast(new_gid));
    }

    const num_glyphs: u16 = @intCast(glyph_list.items.len); // <= cs_count

    // Get Private DICT info to find Local Subrs
    const private_info = parseCFFTopDictForPrivate(cff_data, cff.topdict_start);
    var local_subrs: ?CFFIndex = null;
    if (private_info.size > 0 and private_info.offset + private_info.size <= cff_data.len) {
        const private_dict_data = cff_data[private_info.offset..][0..private_info.size];
        if (parseCFFDictForOperator(private_dict_data, 19)) |rel_off| {
            const local_subrs_offset = private_info.offset + rel_off;
            local_subrs = parseCFFIndex(cff_data, local_subrs_offset);
        }
    }

    // Build compact CharStrings INDEX with desubroutinized glyphs
    var cs_data_buf = std.ArrayListUnmanaged(u8).empty;
    defer cs_data_buf.deinit(allocator);

    var cs_offsets = std.ArrayListUnmanaged(u32).empty;
    defer cs_offsets.deinit(allocator);

    // Track desubroutinized charstrings for later cleanup
    var desubr_charstrings = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (desubr_charstrings.items) |cs| allocator.free(cs);
        desubr_charstrings.deinit(allocator);
    }

    try cs_offsets.append(allocator, 1); // First offset is always 1

    const use_desubroutinization = true; // Set to true to enable desubroutinization
    for (glyph_list.items) |orig_gid| {
        // getEntry is null for empty, inverted or out-of-bounds entries.
        if (charstrings.getEntry(orig_gid)) |orig_charstring| {
            if (use_desubroutinization) {
                // Desubroutinize the charstring
                const desubr_cs = try desubroutinizeCharString(allocator, orig_charstring, global_subrs, local_subrs, 0);
                try desubr_charstrings.append(allocator, desubr_cs);
                try cs_data_buf.appendSlice(allocator, desubr_cs);
            } else {
                // Keep original charstring (requires keeping Subrs)
                try cs_data_buf.appendSlice(allocator, orig_charstring);
            }
        }
        try cs_offsets.append(allocator, std.math.cast(u32, cs_data_buf.items.len + 1) orelse return error.InvalidCFF);
    }

    // Offset size for compact CharStrings: must hold the last offset
    const new_cs_off_size = try cffOffSize(cs_data_buf.items.len + 1);

    // Build CharStrings INDEX
    var new_charstrings = std.ArrayListUnmanaged(u8).empty;
    defer new_charstrings.deinit(allocator);

    try binary.appendBE16(&new_charstrings, allocator, num_glyphs);
    try new_charstrings.append(allocator, new_cs_off_size);

    for (cs_offsets.items) |off| {
        try appendCffOffset(&new_charstrings, allocator, off, new_cs_off_size);
    }
    try new_charstrings.appendSlice(allocator, cs_data_buf.items);

    // Build format 0 charset preserving original SIDs for each glyph
    // This is required for macOS/CoreGraphics which uses SIDs for glyph lookup
    var new_charset = std.ArrayListUnmanaged(u8).empty;
    defer new_charset.deinit(allocator);

    // Get original charset offset (Top DICT via the bounds-checked INDEX)
    const top_dict = (parseCFFIndex(cff_data, cff.topdict_start) orelse return error.InvalidCFF).getEntry(0) orelse
        return error.InvalidCFF;
    const orig_charset_offset = parseCFFDictForOperator(top_dict, 15) orelse return error.InvalidCFF;

    // Collect all SIDs used in the new charset
    var charset_sids = std.ArrayListUnmanaged(u16).empty;
    defer charset_sids.deinit(allocator);
    try charset_sids.append(allocator, 0); // .notdef always has SID 0
    for (glyph_list.items[1..]) |orig_gid| {
        const sid = getCharsetSID(cff_data, orig_charset_offset, orig_gid) orelse 1;
        try charset_sids.append(allocator, sid);
    }

    // Collect SIDs used in Top DICT
    var topdict_sids = try collectTopDictSIDs(allocator, cff_data, cff.topdict_start);
    defer topdict_sids.deinit(allocator);

    // Combine all used SIDs
    var all_used_sids = std.ArrayListUnmanaged(u16).empty;
    defer all_used_sids.deinit(allocator);
    try all_used_sids.appendSlice(allocator, charset_sids.items);
    try all_used_sids.appendSlice(allocator, topdict_sids.items);

    // Build subset String INDEX with SID remapping
    const string_subset = try buildSubsetStringIndex(allocator, cff_data, cff.string_start, all_used_sids.items);
    defer allocator.free(string_subset.data);
    var sid_remap = string_subset.remap;
    defer sid_remap.deinit(allocator);

    // String INDEX subsetting removes unused strings and remaps SIDs in Top DICT.
    // Charset SIDs are preserved (standard SIDs < 391 don't need remapping).
    const use_string_subsetting = true;
    const string_index_data = if (use_string_subsetting) string_subset.data else cff_data[cff.string_start..cff.string_end];

    // Build format 0 charset with remapped SIDs
    // Standard SIDs (< 391) don't need remapping, but custom strings do
    try new_charset.append(allocator, 0); // Format 0
    for (charset_sids.items[1..]) |orig_sid| {
        const final_sid = if (use_string_subsetting and orig_sid >= 391)
            sid_remap.get(orig_sid) orelse orig_sid
        else
            orig_sid;
        try binary.appendBE16(&new_charset, allocator, final_sid);
    }

    // Private DICT handling
    const orig_private_size = private_info.size;
    const orig_private_offset = private_info.offset;

    var new_private = std.ArrayListUnmanaged(u8).empty;
    defer new_private.deinit(allocator);

    // Get Local Subrs size if present
    var local_subrs_size: usize = 0;
    if (orig_private_size > 0 and orig_private_offset + orig_private_size <= cff_data.len) {
        const private_dict_data = cff_data[orig_private_offset..][0..orig_private_size];
        if (use_desubroutinization) {
            // Strip Subrs operator when desubroutinizing
            try buildPrivateDictWithoutSubrs(allocator, private_dict_data, &new_private);
        } else {
            // Keep original Private DICT with Subrs reference
            try new_private.appendSlice(allocator, private_dict_data);
            // Also get Local Subrs size
            if (parseCFFDictForOperator(private_dict_data, 19)) |rel_off| {
                const local_subrs_offset = orig_private_offset + rel_off;
                const local_subrs_end = skipCFFIndex(cff_data, local_subrs_offset);
                local_subrs_size = local_subrs_end - local_subrs_offset;
            }
        }
    }

    // Get original Name INDEX (keep as-is)
    const name_index_data = cff_data[cff.hdr_size..cff.name_end];

    // Global Subrs INDEX - empty if desubroutinizing, keep original otherwise
    const orig_gsubr_index_data = cff_data[cff.gsubr_start..cff.gsubr_end];
    const empty_gsubr_index = [_]u8{ 0, 0 };

    // Calculate final offsets (we need to do this twice due to Top DICT size changes)
    var final_offset: usize = cff.hdr_size + name_index_data.len;

    // Estimate Top DICT INDEX size for first pass
    var new_topdict = std.ArrayListUnmanaged(u8).empty;
    defer new_topdict.deinit(allocator);

    // First pass: build Top DICT with estimated offsets
    const est_topdict_index_size: usize = 10 + 32; // header + dict estimate
    final_offset += est_topdict_index_size;
    final_offset += string_index_data.len;
    final_offset += if (use_desubroutinization) empty_gsubr_index.len else orig_gsubr_index_data.len;

    const est_charset_offset = final_offset;
    final_offset += new_charset.items.len;

    const est_charstrings_offset = final_offset;
    final_offset += new_charstrings.items.len;

    const est_private_offset = final_offset;

    // Private size includes Local Subrs when not desubroutinizing
    const total_private_size = new_private.items.len + local_subrs_size;

    if (use_string_subsetting) {
        try buildUpdatedTopDictWithSIDRemap(allocator, cff_data, cff.topdict_start, &new_topdict, .{
            .charset = @intCast(est_charset_offset),
            .charstrings = @intCast(est_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(est_private_offset),
        }, &sid_remap);
    } else {
        try buildUpdatedTopDict(allocator, cff_data, cff.topdict_start, &new_topdict, .{
            .charset = @intCast(est_charset_offset),
            .charstrings = @intCast(est_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(est_private_offset),
        });
    }

    // Build Top DICT INDEX
    var new_topdict_index = std.ArrayListUnmanaged(u8).empty;
    defer new_topdict_index.deinit(allocator);
    try appendCffSingleItemIndex(&new_topdict_index, allocator, new_topdict.items);

    // Recalculate with actual Top DICT INDEX size
    final_offset = cff.hdr_size + name_index_data.len + new_topdict_index.items.len;
    final_offset += string_index_data.len;
    final_offset += if (use_desubroutinization) empty_gsubr_index.len else orig_gsubr_index_data.len;

    const final_charset_offset = final_offset;
    final_offset += new_charset.items.len;

    const final_charstrings_offset = final_offset;
    final_offset += new_charstrings.items.len;

    const final_private_offset = final_offset;

    // Rebuild Top DICT with correct offsets
    new_topdict.clearRetainingCapacity();
    if (use_string_subsetting) {
        try buildUpdatedTopDictWithSIDRemap(allocator, cff_data, cff.topdict_start, &new_topdict, .{
            .charset = @intCast(final_charset_offset),
            .charstrings = @intCast(final_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(final_private_offset),
        }, &sid_remap);
    } else {
        try buildUpdatedTopDict(allocator, cff_data, cff.topdict_start, &new_topdict, .{
            .charset = @intCast(final_charset_offset),
            .charstrings = @intCast(final_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(final_private_offset),
        });
    }

    // Rebuild Top DICT INDEX
    new_topdict_index.clearRetainingCapacity();
    try appendCffSingleItemIndex(&new_topdict_index, allocator, new_topdict.items);

    // Assemble final CFF
    const gsubr_len = if (use_desubroutinization) empty_gsubr_index.len else orig_gsubr_index_data.len;
    const total_size = cff.hdr_size + name_index_data.len + new_topdict_index.items.len +
        string_index_data.len + gsubr_len +
        new_charset.items.len + new_charstrings.items.len + total_private_size;

    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    var pos: usize = 0;

    // Header
    @memcpy(output[0..cff.hdr_size], cff_data[0..cff.hdr_size]);
    pos = cff.hdr_size;

    // Name INDEX
    @memcpy(output[pos..][0..name_index_data.len], name_index_data);
    pos += name_index_data.len;

    // Top DICT INDEX
    @memcpy(output[pos..][0..new_topdict_index.items.len], new_topdict_index.items);
    pos += new_topdict_index.items.len;

    // String INDEX (full, for now)
    @memcpy(output[pos..][0..string_index_data.len], string_index_data);
    pos += string_index_data.len;

    // Global Subr INDEX
    if (use_desubroutinization) {
        @memcpy(output[pos..][0..empty_gsubr_index.len], &empty_gsubr_index);
        pos += empty_gsubr_index.len;
    } else {
        @memcpy(output[pos..][0..orig_gsubr_index_data.len], orig_gsubr_index_data);
        pos += orig_gsubr_index_data.len;
    }

    // Charset
    @memcpy(output[pos..][0..new_charset.items.len], new_charset.items);
    pos += new_charset.items.len;

    // CharStrings INDEX
    @memcpy(output[pos..][0..new_charstrings.items.len], new_charstrings.items);
    pos += new_charstrings.items.len;

    // Private DICT + Local Subrs (if not desubroutinizing)
    if (new_private.items.len > 0) {
        @memcpy(output[pos..][0..new_private.items.len], new_private.items);
        pos += new_private.items.len;
    }
    if (!use_desubroutinization and local_subrs_size > 0) {
        // Copy Local Subrs from original location
        const local_subrs_data = cff_data[orig_private_offset + orig_private_size ..][0..local_subrs_size];
        @memcpy(output[pos..][0..local_subrs_size], local_subrs_data);
    }

    return output;
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
    const emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
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

test "WinAnsi subset keeps composite glyph components" {
    // Inter's i, j, colon and semicolon are composites (e.g. i = dotlessi +
    // dot). The WinAnsi subsetter copied the composites without their
    // components, so they rendered blank.
    const allocator = std.testing.allocator;
    const emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();
    emb.encoding = .win_ansi;
    emb.markCharsUsed("ij:;");
    try emb.generateSubset();

    const sub = try ttf.Font.parse(emb.getFontData());
    const glyf = sub.getTable("glyf".*).?;
    const loca = sub.getTable("loca".*).?;
    const loca_format = sub.head.?.index_to_loc_format;
    const num_glyphs = sub.maxp.?.num_glyphs;
    var composites: usize = 0;
    for ("ij:;") |c| {
        const gid = sub.getGlyphId(c).?;
        const comps = ttf_subset.getCompositeComponents(glyf, loca, loca_format, gid);
        if (comps[0] == 0) continue; // simple glyph
        composites += 1;
        for (comps) |comp| {
            if (comp == 0) break;
            try std.testing.expect(comp < num_glyphs);
            const start = getLocaOffset(loca, comp, loca_format);
            const end = getLocaOffset(loca, @as(usize, comp) + 1, loca_format);
            try std.testing.expect(end > start); // has an outline
        }
    }
    try std.testing.expectEqual(@as(usize, 4), composites);
}

test "subset is valid TTF" {
    const allocator = std.testing.allocator;

    const emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
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

    const emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Courier Prime/Courier Prime.ttf");
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

// =============================================================================
// CFF Desubroutinization Tests
// =============================================================================

test "getSubrBias calculation" {
    // CFF spec: bias depends on subroutine count
    // count < 1240: bias = 107
    // count < 33900: bias = 1131
    // else: bias = 32768

    try std.testing.expectEqual(@as(i32, 107), getSubrBias(0));
    try std.testing.expectEqual(@as(i32, 107), getSubrBias(1));
    try std.testing.expectEqual(@as(i32, 107), getSubrBias(100));
    try std.testing.expectEqual(@as(i32, 107), getSubrBias(1239));

    try std.testing.expectEqual(@as(i32, 1131), getSubrBias(1240));
    try std.testing.expectEqual(@as(i32, 1131), getSubrBias(5000));
    try std.testing.expectEqual(@as(i32, 1131), getSubrBias(33899));

    try std.testing.expectEqual(@as(i32, 32768), getSubrBias(33900));
    try std.testing.expectEqual(@as(i32, 32768), getSubrBias(50000));
}

test "parseCFFIndex empty index" {
    // Empty CFF INDEX: count = 0 (2 bytes)
    const empty_index = [_]u8{ 0, 0 };
    const idx = parseCFFIndex(&empty_index, 0);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 0), idx.?.count);
}

test "parseCFFIndex single entry" {
    // CFF INDEX with 1 entry: count(2) + offSize(1) + offsets(2) + data
    // count = 1, offSize = 1, offsets = [1, 5], data = "test"
    const single_index = [_]u8{
        0, 1, // count = 1
        1, // offSize = 1
        1, 5, // offsets: 1, 5 (data is 4 bytes)
        't', 'e', 's', 't', // data
    };
    const idx = parseCFFIndex(&single_index, 0);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 1), idx.?.count);

    // Get entry 0
    const entry = idx.?.getEntry(0);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualSlices(u8, "test", entry.?);

    // Entry 1 should be null (out of bounds)
    try std.testing.expect(idx.?.getEntry(1) == null);
}

test "parseCFFIndex multiple entries" {
    // CFF INDEX with 3 entries
    const multi_index = [_]u8{
        0, 3, // count = 3
        1, // offSize = 1
        1, 3, 6, 7, // offsets: entries are [1,3), [3,6), [6,7)
        'A', 'B', // entry 0: "AB"
        'C', 'D', 'E', // entry 1: "CDE"
        'F', // entry 2: "F"
    };
    const idx = parseCFFIndex(&multi_index, 0);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 3), idx.?.count);

    try std.testing.expectEqualSlices(u8, "AB", idx.?.getEntry(0).?);
    try std.testing.expectEqualSlices(u8, "CDE", idx.?.getEntry(1).?);
    try std.testing.expectEqualSlices(u8, "F", idx.?.getEntry(2).?);
}

test "desubroutinize simple charstring no subrs" {
    const allocator = std.testing.allocator;

    // Simple charstring: just moveto and endchar
    // 100 100 rmoveto endchar
    // Encoded: 100 = 239 (100+139), rmoveto = 21, endchar = 14
    const simple_cs = [_]u8{
        239, 239, 21, // 100 100 rmoveto
        14, // endchar
    };

    const result = try desubroutinizeCharString(allocator, &simple_cs, null, null, 0);
    defer allocator.free(result);

    // Should be unchanged (no subrs to inline)
    try std.testing.expectEqualSlices(u8, &simple_cs, result);
}

test "desubroutinize preserves operators" {
    const allocator = std.testing.allocator;

    // Charstring with various operators
    const cs = [_]u8{
        139, 139, 1, // 0 0 hstem
        139, 139, 3, // 0 0 vstem
        139, 139, 21, // 0 0 rmoveto
        139, 139, 5, // 0 0 rlineto
        14, // endchar
    };

    const result = try desubroutinizeCharString(allocator, &cs, null, null, 0);
    defer allocator.free(result);

    // Should preserve all operators
    try std.testing.expectEqualSlices(u8, &cs, result);
}

test "desubroutinize handles two-byte operators" {
    const allocator = std.testing.allocator;

    // Charstring with two-byte operator (12 XX)
    const cs = [_]u8{
        139, 139, 12, 35, // 0 0 flex (12 35)
        14, // endchar
    };

    const result = try desubroutinizeCharString(allocator, &cs, null, null, 0);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, &cs, result);
}

test "desubroutinize handles shortint encoding" {
    const allocator = std.testing.allocator;

    // Charstring with shortint (28 followed by 2 bytes)
    const cs = [_]u8{
        28, 0x01, 0x00, // shortint 256
        139, 21, // 0 rmoveto
        14, // endchar
    };

    const result = try desubroutinizeCharString(allocator, &cs, null, null, 0);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, &cs, result);
}

test "desubroutinize strips return opcode" {
    const allocator = std.testing.allocator;

    // Build a simple local subrs index with one subroutine containing:
    // 139 139 5 = "0 0 rlineto" followed by 11 = "return"
    const local_subrs_data = [_]u8{
        0, 1, // count = 1
        1, // offSize = 1
        1, 5, // offsets
        139, 139, 5, 11, // the subr data with return
    };
    const local_subrs = parseCFFIndex(&local_subrs_data, 0);

    // Charstring that calls local subr 0 (with bias 107, so stack value = -107)
    // -107 encoded as: 251 + (107-108)/256 = 251, (107-108)%256 + 108 = ... actually -107 = 139-107 = 32
    // Actually for -107: use formula for negative: -(b0-251)*256 - b1 - 108 = -107
    // So: (b0-251)*256 + b1 + 108 = 107 -> if b0=251, b1=-1 doesn't work
    // Let's use single byte: -107 to 107 -> 32 to 246
    // -107 -> 32 (since value + 139 = byte, so -107 + 139 = 32)
    const cs = [_]u8{
        32, // -107 (subr index 0 with bias 107)
        10, // callsubr
        14, // endchar
    };

    const result = try desubroutinizeCharString(allocator, &cs, null, local_subrs, 0);
    defer allocator.free(result);

    // Result should have the subr content inlined (without return) plus endchar
    // Expected: 139 139 5 14 (rlineto args + endchar)
    const expected = [_]u8{ 139, 139, 5, 14 };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

// =============================================================================
// Compact TTF Subsetting Tests
// =============================================================================

test "compact TTF subsetting creates valid font" {
    const allocator = std.testing.allocator;

    // Load a TTF font with identity encoding
    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    // Switch to identity encoding for CID mode
    emb.encoding = .identity;

    // Mark some Unicode characters
    const glyphs = try emb.markUnicodeCharsUsed("Hello", null);
    emb.allocator.free(glyphs);

    // Generate subset (should use compact TTF)
    try emb.generateSubset();

    // Verify subset was created
    try std.testing.expect(emb.subset_data != null);
    const subset = emb.getFontData();

    // Verify it's a valid TTF
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, subset[0..4], .big));

    // Parse and verify
    const parsed = try ttf.Font.parse(subset);
    try std.testing.expect(parsed.head != null);
    try std.testing.expect(parsed.maxp != null);

    // Should have fewer glyphs than original (only used glyphs)
    const subset_glyphs = parsed.maxp.?.num_glyphs;
    try std.testing.expect(subset_glyphs < 100); // "Hello" should need < 10 glyphs
}

test "compact TTF glyph ID remapping" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;
    const glyphs_ab = try emb.markUnicodeCharsUsed("AB", null);
    emb.allocator.free(glyphs_ab);

    try emb.generateSubset();

    // After subsetting, gid_remap should have entries
    try std.testing.expect(emb.gid_remap.count() > 0);

    // .notdef (GID 0) should always map to 0
    try std.testing.expectEqual(@as(u16, 0), emb.gid_remap.get(0).?);

    // getGlyphIdForCodepoint should return remapped IDs
    const a_gid = emb.getGlyphIdForCodepoint('A');
    const b_gid = emb.getGlyphIdForCodepoint('B');

    // Remapped GIDs should be small sequential numbers
    try std.testing.expect(a_gid < 10);
    try std.testing.expect(b_gid < 10);
    try std.testing.expect(a_gid != b_gid);
}

test "compact TTF smaller than sparse TTF" {
    const allocator = std.testing.allocator;

    // Test that compact subsetting produces smaller output than the original
    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;
    const glyphs_test = try emb.markUnicodeCharsUsed("Test", null);
    emb.allocator.free(glyphs_test);

    try emb.generateSubset();

    const subset = emb.getFontData();
    const original = emb.data;

    // Subset should be much smaller (< 10% of original for small char sets)
    try std.testing.expect(subset.len < original.len / 10);
}

test "rewriteCompositeGlyphIDs remaps component references" {
    // Build a mock composite glyph:
    // Header (10 bytes): numberOfContours=-1 (composite), xMin, yMin, xMax, yMax
    // Component 1: flags (no MORE_COMPONENTS), glyphIndex=100, args (2 bytes)
    var glyph_data = [_]u8{
        0xFF, 0xFF, // numberOfContours = -1 (composite)
        0x00, 0x00, // xMin
        0x00, 0x00, // yMin
        0x00, 0x64, // xMax = 100
        0x00, 0x64, // yMax = 100
        // Component 1:
        0x00, 0x00, // flags (no special flags, no MORE_COMPONENTS)
        0x00, 0x64, // glyphIndex = 100
        0x00, 0x00, // args (2 bytes, offsets)
    };

    // Create a remap: 100 -> 5
    var remap = std.AutoArrayHashMapUnmanaged(u16, u16){};
    defer remap.deinit(std.testing.allocator);
    try remap.put(std.testing.allocator, 100, 5);

    try rewriteCompositeGlyphIDs(&glyph_data, &remap);

    // Check that glyph ID was remapped
    const new_gid = std.mem.readInt(u16, glyph_data[12..14], .big);
    try std.testing.expectEqual(@as(u16, 5), new_gid);
}

test "rewriteCompositeGlyphIDs handles multiple components" {
    // Composite with 2 components
    var glyph_data = [_]u8{
        0xFF, 0xFF, // numberOfContours = -1 (composite)
        0x00, 0x00, // xMin
        0x00, 0x00, // yMin
        0x00, 0x64, // xMax
        0x00, 0x64, // yMax
        // Component 1 (with MORE_COMPONENTS flag = 0x0020):
        0x00, 0x20, // flags = MORE_COMPONENTS
        0x00, 0x0A, // glyphIndex = 10
        0x00, 0x00, // args (2 bytes)
        // Component 2 (no MORE_COMPONENTS):
        0x00, 0x00, // flags = no more
        0x00, 0x14, // glyphIndex = 20
        0x00, 0x10, // args (2 bytes)
    };

    var remap = std.AutoArrayHashMapUnmanaged(u16, u16){};
    defer remap.deinit(std.testing.allocator);
    try remap.put(std.testing.allocator, 10, 1);
    try remap.put(std.testing.allocator, 20, 2);

    try rewriteCompositeGlyphIDs(&glyph_data, &remap);

    // Check both glyph IDs were remapped
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, glyph_data[12..14], .big));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, glyph_data[18..20], .big));
}

test "rewriteCompositeGlyphIDs handles ARG_1_AND_2_ARE_WORDS" {
    // Component with ARG_1_AND_2_ARE_WORDS flag (4-byte args)
    var glyph_data = [_]u8{
        0xFF, 0xFF, // numberOfContours = -1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x64, // bounds
        // Component with 4-byte args:
        0x00, 0x01, // flags = ARG_1_AND_2_ARE_WORDS
        0x00, 0x32, // glyphIndex = 50
        0x00, 0x00, 0x00, 0x00, // 4-byte args
    };

    var remap = std.AutoArrayHashMapUnmanaged(u16, u16){};
    defer remap.deinit(std.testing.allocator);
    try remap.put(std.testing.allocator, 50, 3);

    try rewriteCompositeGlyphIDs(&glyph_data, &remap);

    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, glyph_data[12..14], .big));
}

// =============================================================================
// CFF Subsetting Tests
// =============================================================================

test "CFF subsetting creates valid font" {
    const allocator = std.testing.allocator;

    // Load an OTF (CFF) font
    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    const glyphs = try emb.markUnicodeCharsUsed("Hello", null);
    emb.allocator.free(glyphs);

    try emb.generateSubset();

    // Verify subset was created
    try std.testing.expect(emb.subset_data != null);
    const subset = emb.getFontData();

    // CFF should start with version 1.0
    try std.testing.expectEqual(@as(u8, 1), subset[0]); // major version
    try std.testing.expectEqual(@as(u8, 0), subset[1]); // minor version
}

test "CFF desubroutinization reduces size" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    // Get original CFF size
    const orig_cff = emb.font.getTable("CFF ".*);
    try std.testing.expect(orig_cff != null);
    const orig_size = orig_cff.?.len;

    emb.encoding = .identity;
    const glyphs_abc = try emb.markUnicodeCharsUsed("ABC", null);
    emb.allocator.free(glyphs_abc);

    try emb.generateSubset();

    const subset = emb.getFontData();

    // Subset should be much smaller than original CFF
    try std.testing.expect(subset.len < orig_size / 5);
}

test "CFF glyph ID remapping works" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    const glyphs_xy = try emb.markUnicodeCharsUsed("XY", null);
    emb.allocator.free(glyphs_xy);

    try emb.generateSubset();

    // After subsetting, gid_remap should have entries
    try std.testing.expect(emb.gid_remap.count() > 0);

    // Verify remapped GIDs are sequential
    const x_gid = emb.getGlyphIdForCodepoint('X');
    const y_gid = emb.getGlyphIdForCodepoint('Y');

    try std.testing.expect(x_gid < 10);
    try std.testing.expect(y_gid < 10);
}

// =============================================================================
// Integration Tests
// =============================================================================

test "CID font with TTF renders correctly" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;

    // Mark various characters
    const glyphs_hw = try emb.markUnicodeCharsUsed("Hello World! 123", null);
    emb.allocator.free(glyphs_hw);

    try emb.generateSubset();

    // Verify ToUnicode CMap can be generated
    const cmap = try emb.generateCIDToUnicodeCMap();
    defer allocator.free(cmap);

    try std.testing.expect(std.mem.indexOf(u8, cmap, "CIDInit") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "beginbfchar") != null);

    // Verify width array can be generated
    const widths = try emb.generateWidthArray();
    defer allocator.free(widths);

    try std.testing.expect(widths.len > 2); // Should have content
    try std.testing.expect(widths[0] == '['); // Should start with array
}

test "CID font with OTF renders correctly" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    const glyphs_t456 = try emb.markUnicodeCharsUsed("Test 456", null);
    emb.allocator.free(glyphs_t456);

    try emb.generateSubset();

    const cmap = try emb.generateCIDToUnicodeCMap();
    defer allocator.free(cmap);

    try std.testing.expect(std.mem.indexOf(u8, cmap, "CIDInit") != null);

    const widths = try emb.generateWidthArray();
    defer allocator.free(widths);

    try std.testing.expect(widths.len > 2);
}

test "mixed font types in same document" {
    const allocator = std.testing.allocator;

    // Load both TTF and OTF
    var ttf_font = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer ttf_font.deinit();

    var otf_font = try EmbeddedFont.fromFile(std.testing.io, allocator, "test/fonts/Inter/Inter-Bold.otf");
    defer otf_font.deinit();

    ttf_font.encoding = .identity;
    otf_font.encoding = .identity;

    const glyphs_reg = try ttf_font.markUnicodeCharsUsed("Regular", null);
    ttf_font.allocator.free(glyphs_reg);
    const glyphs_bold = try otf_font.markUnicodeCharsUsed("Bold", null);
    otf_font.allocator.free(glyphs_bold);

    try ttf_font.generateSubset();
    try otf_font.generateSubset();

    // Both should have valid subsets
    try std.testing.expect(ttf_font.subset_data != null);
    try std.testing.expect(otf_font.subset_data != null);

    // TTF should have TTF signature
    const ttf_data = ttf_font.getFontData();
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, ttf_data[0..4], .big));

    // OTF/CFF should have CFF version
    const otf_data = otf_font.getFontData();
    try std.testing.expectEqual(@as(u8, 1), otf_data[0]);
}

test "OpenType features initialization" {
    const font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
    defer font.deinit();

    // Features should not be initialized yet (lazy)
    try std.testing.expect(font.ot_features == null);

    // Default flags
    try std.testing.expect(font.feature_flags.isEnabled(.liga));
    try std.testing.expect(font.feature_flags.isEnabled(.kern));

    // Initialize features
    try font.initOpenTypeFeatures();
    try std.testing.expect(font.ot_features != null);

    // Charter has GPOS but no GSUB
    try std.testing.expect(font.ot_features.?.gsub == null);
    try std.testing.expect(font.ot_features.?.kern_lookups.items.len > 0);
}

test "OpenType kerning applied in text rendering" {
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
    defer font.deinit();
    font.encoding = .identity;

    // Text with common kerning pairs
    const glyphs_avatar = try font.markUnicodeCharsUsed("AVATAR", null);
    font.allocator.free(glyphs_avatar);

    // OpenType features should now be initialized
    try std.testing.expect(font.ot_features != null);

    // Get glyphs for text (will have ligatures/kerning applied during rendering)
    const glyphs = try font.getGlyphsForText("AV");
    defer font.allocator.free(glyphs);

    // Should have 2 glyphs (no ligatures in Charter)
    try std.testing.expectEqual(@as(usize, 2), glyphs.len);

    // Get kerning between A and V
    const kern = font.getKerning(glyphs[0], glyphs[1]);
    // AV should have negative kerning (letters move closer)
    try std.testing.expect(kern < 0);
}

test "setFeature disables kerning" {
    const font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
    defer font.deinit();
    font.encoding = .identity;

    // Initialize features
    try font.initOpenTypeFeatures();

    // Get kerning for AV with kern enabled
    const glyph_A = font.font.getGlyphId('A') orelse 0;
    const glyph_V = font.font.getGlyphId('V') orelse 0;
    const kern_enabled = font.getKerning(glyph_A, glyph_V);

    // Disable kerning
    font.setFeature(.kern, false);
    const kern_disabled = font.getKerning(glyph_A, glyph_V);

    // With kern disabled, should return 0
    try std.testing.expectEqual(@as(i16, 0), kern_disabled);
    // With kern enabled, should have been non-zero
    try std.testing.expect(kern_enabled != 0);
}

test "Satoshi ligature codepoint tracking" {
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Satoshi/Satoshi-Regular.otf");
    defer font.deinit();
    font.encoding = .identity;

    // Mark text with ligatures
    const glyphs_ligas = try font.markUnicodeCharsUsed("fi fl ft", null);
    font.allocator.free(glyphs_ligas);

    // Should have tracked fi, fl, ft ligatures (3 different glyph IDs)
    try std.testing.expect(font.ligature_codepoints.count() >= 3);

    // Check that each ligature has 2 codepoints
    var iter = font.ligature_codepoints.iterator();
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.value_ptr.*.len);
    }
}

/// The text the ToUnicode maps give a glyph sequence, concatenated.
fn textOfGlyphs(font: *const EmbeddedFont, glyphs: []const u16, out: *std.ArrayListUnmanaged(u21)) !void {
    for (glyphs) |gid| {
        if (font.glyph_to_codepoint.get(gid)) |cp| {
            try out.append(std.testing.allocator, cp);
        } else if (font.ligature_codepoints.get(gid)) |seq| {
            try out.appendSlice(std.testing.allocator, seq);
        }
    }
}

test "ccmp output maps back to the text as typed" {
    // Gentium's ccmp swaps i/j for dotless forms before above-marks, and
    // decomposes U+1ECB (i with dot below, which "i" + U+0323 composes to)
    // into dotless i + U+0323 when an above-mark follows. The same
    // i.Dotless glyph thus comes from "i" and from the composed
    // character; ToUnicode must still yield every input code point once.
    // Text typed precomposed and split by ccmp (U+012F -> dotless i +
    // ogonek) comes back decomposed: canonically equivalent, so compare
    // canonical decompositions.
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer font.deinit();
    const text = "i\u{0307}\u{0301} i\u{0323}\u{0301} j\u{0301} \u{012F}\u{0301}";
    const glyphs = try font.markUnicodeCharsUsed(text, null);
    defer font.allocator.free(glyphs);
    // ccmp did apply: dotless j, not j
    try std.testing.expect(std.mem.indexOfScalar(u16, glyphs, font.font.getGlyphId('j').?) == null);

    var extracted: std.ArrayListUnmanaged(u21) = .empty;
    defer extracted.deinit(std.testing.allocator);
    try textOfGlyphs(font, glyphs, &extracted);
    var expected: std.ArrayListUnmanaged(u21) = .empty;
    defer expected.deinit(std.testing.allocator);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        var buf: [8]u21 = undefined;
        try expected.appendSlice(std.testing.allocator, unicode_compose.decompose(cp, &buf));
    }
    try std.testing.expectEqualSlices(u21, expected.items, extracted.items);
}

test "default ignorables are removed and stay out of the text" {
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer font.deinit();
    // Soft hyphen and ZWSP vanish; ZWJ between f and i does not block the
    // ligature (Inter has none for "fi" by default, so check text only)
    const text = "co\u{00AD}op a\u{200B}b f\u{200D}i";
    const glyphs = try font.markUnicodeCharsUsed(text, null);
    defer font.allocator.free(glyphs);
    const plain = try font.markUnicodeCharsUsed("coop ab fi", null);
    defer font.allocator.free(plain);
    try std.testing.expectEqualSlices(u16, plain, glyphs);

    // No glyph's text picked up an ignorable ("o" must not become "o" + SHY)
    var extracted: std.ArrayListUnmanaged(u21) = .empty;
    defer extracted.deinit(std.testing.allocator);
    try textOfGlyphs(font, glyphs, &extracted);
    var expected: std.ArrayListUnmanaged(u21) = .empty;
    defer expected.deinit(std.testing.allocator);
    var it = (try std.unicode.Utf8View.init("coop ab fi")).iterator();
    while (it.nextCodepoint()) |cp| try expected.append(std.testing.allocator, cp);
    try std.testing.expectEqualSlices(u21, expected.items, extracted.items);
}

test "a ZWJ taken up by an emoji ligature stays in its text" {
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Noto Emoji/NotoEmoji-Regular.ttf");
    defer font.deinit();
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const glyphs = try font.markUnicodeCharsUsed(family, null);
    defer font.allocator.free(glyphs);
    try std.testing.expectEqual(@as(usize, 1), glyphs.len);
    try std.testing.expectEqualSlices(u21, &.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 }, font.ligature_codepoints.get(glyphs[0]).?);

    // U+FE0F after a heart: removed, so the heart maps to itself alone
    const heart = try font.markUnicodeCharsUsed("\u{2764}\u{FE0F}", null);
    defer font.allocator.free(heart);
    try std.testing.expectEqual(@as(usize, 1), heart.len);
    try std.testing.expectEqual(@as(?u21, 0x2764), font.glyph_to_codepoint.get(heart[0]));
}

test "default ignorables measure as nothing, with and without GSUB" {
    for ([_][]const u8{ "test/fonts/Charter/Charter Regular.ttf", "test/fonts/Inter/Inter-Regular.ttf" }) |path| {
        var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, path);
        defer font.deinit();
        const with = font.measureTextWidthSpaced("co\u{00AD}op a\u{200B}b\u{FEFF}", 12, 0);
        const without = font.measureTextWidthSpaced("coop ab", 12, 0);
        try std.testing.expectEqual(without, with);
    }
}

test "a variation sequence measures and draws as the glyph cmap 14 gives it" {
    // GsubTest: a+FE00 -> a.alt, 700 units wide (a is 500, upem 1000);
    // a+FE01 is not listed, so a keeps its glyph and the selector goes.
    // Once with GSUB (clig is on by default) and once without
    var font = try EmbeddedFont.fromFile(std.testing.io, std.testing.allocator, "test/fonts/gsub/GsubTest.ttf");
    defer font.deinit();
    for ([_]bool{ true, false }) |clig| {
        font.setFeature(.clig, clig);
        try std.testing.expectEqual(@as(f64, 700), font.measureTextWidthSpaced("a\u{FE00}", 1000, 0));
        try std.testing.expectEqual(@as(f64, 500), font.measureTextWidthSpaced("a\u{FE01}", 1000, 0));
        try std.testing.expectEqual(@as(f64, 1200), font.measureTextWidthSpaced("a\u{FE00}a", 1000, 0));
        const glyphs = try font.markUnicodeCharsUsed("a\u{FE00}a", std.testing.allocator);
        defer std.testing.allocator.free(glyphs);
        try std.testing.expectEqualSlices(u16, &.{ 32, 2 }, glyphs);
    }
    // The variant copies as the base character, without the selector
    var text: std.ArrayListUnmanaged(u21) = .empty;
    defer text.deinit(std.testing.allocator);
    try textOfGlyphs(font, &.{32}, &text);
    try std.testing.expectEqualSlices(u21, &.{'a'}, text.items);
}

/// A parsed font file: one weight/style of one typeface. Caller-owned and
/// shareable - like Image and Svg, create it once and use it in any number
/// of documents, on any threads (each document works on a private clone).
///
/// Life cycle: after fromMemory/fromFile the face is in its configuration
/// phase - setFeature and warmup may be called from the creating thread.
/// The first use by any document freezes it; from then on it is immutable
/// and thread-safe, and configuration calls return error.FaceFrozen.
/// Keep the face (and, for fromMemory, the font bytes) alive until every
/// document that used it has been deinitialized.
pub const FontFace = struct {
    /// Internal: the fully-parsed prototype that per-document clones copy
    /// from. Do not use it in styles or mutate it directly - Zig cannot
    /// hide fields, but this one is not API.
    prototype: *EmbeddedFont,
    /// Set by the first per-document instantiation; configuration is
    /// rejected afterwards (changes would not propagate to existing
    /// clones, and warmup would race with concurrent cloning).
    frozen: bool = false,

    /// Parse font data (borrowed - must outlive the FontFace) and eagerly
    /// initialize all OpenType tables, so per-document use never parses
    /// anything. Faces always use identity (Unicode/CID) encoding; the
    /// legacy .win_ansi mode is only available via doc.loadFont.
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !FontFace {
        const emb = try EmbeddedFont.fromMemory(allocator, data, false);
        errdefer emb.deinit();
        try emb.initOpenTypeFeatures();
        return .{ .prototype = emb };
    }

    /// Parse a font file. The face owns the loaded bytes.
    pub fn fromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !FontFace {
        const emb = try EmbeddedFont.fromFile(io, allocator, path);
        errdefer emb.deinit();
        try emb.initOpenTypeFeatures();
        return .{ .prototype = emb };
    }

    /// Set a default OpenType feature flag for this face; every document
    /// clone inherits these defaults (documents can still override with
    /// doc.setFeature). Configuration phase only.
    pub fn setFeature(self: *FontFace, feature: opentype.Feature, enabled: bool) error{FaceFrozen}!void {
        if (@atomicLoad(bool, &self.frozen, .acquire)) return error.FaceFrozen;
        self.prototype.setFeature(feature, enabled);
    }

    /// Optionally pre-fill the kerning cache by measuring representative
    /// text; every document clone starts with those pair lookups cached.
    /// Configuration phase only.
    pub fn warmup(self: *FontFace, text: []const u8) error{FaceFrozen}!void {
        if (@atomicLoad(bool, &self.frozen, .acquire)) return error.FaceFrozen;
        _ = self.prototype.measureTextWidth(text, 12);
    }

    /// Create the per-document clone and freeze the face. Called by
    /// Document when a .face style is first used.
    pub fn instantiate(self: *const FontFace, allocator: std.mem.Allocator) !*EmbeddedFont {
        @atomicStore(bool, @constCast(&self.frozen), true, .release);
        return EmbeddedFont.fromShared(allocator, self.prototype);
    }

    pub fn deinit(self: *FontFace) void {
        self.prototype.deinit();
    }
};

test "CFF single-item INDEX picks an offset size that holds data.len + 1" {
    // Off-by-one (any font): 255 bytes need offset 256, which does not fit
    // offSize 1; >= 65,535 bytes overflowed offSize 2 (e.g. a hostile Top
    // DICT with a very long real operand).
    for ([_]usize{ 254, 255, 256, 65_534, 65_535, 70_000 }) |len| {
        const data = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(data);
        @memset(data, 0xAB);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try appendCffSingleItemIndex(&out, std.testing.allocator, data);
        const index = cff_subset.parseCFFIndex(out.items, 0).?;
        try std.testing.expectEqualSlices(u8, data, index.getEntry(0).?);
    }
}
