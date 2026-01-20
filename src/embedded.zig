//! Embedded Font Support
//!
//! Handles TrueType font embedding in PDF documents.
//! Supports two encoding modes:
//! - WinAnsiEncoding (Windows-1252): Simple single-byte text, 256 character limit
//! - Identity-H (CID): Full Unicode support via 2-byte glyph IDs

const std = @import("std");
const ttf = @import("ttf.zig");
const ttf_subset = @import("ttf_subset.zig");
const cff_subset = @import("cff_subset.zig");
pub const opentype = @import("opentype.zig");

// Re-export commonly used functions from subsetting modules
const readU16 = ttf_subset.readU16;
const readI16 = ttf_subset.readI16;
const readU32 = ttf_subset.readU32;
const padTo4 = ttf_subset.padTo4;
const writeTableEntry = ttf_subset.writeTableEntry;
const getLocaOffset = ttf_subset.getLocaOffset;
const buildHmtxForGlyphs = ttf_subset.buildHmtxForGlyphs;
const buildMinimalCmap = ttf_subset.buildMinimalCmap;
const assembleTTF = ttf_subset.assembleTTF;
const TTFTables = ttf_subset.TTFTables;
const getCompositeComponents = ttf_subset.getCompositeComponents;
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

    // Encoding mode
    encoding: FontEncoding = .win_ansi,

    // Subsetting support (WinAnsi mode)
    used_chars: [256]bool = [_]bool{false} ** 256, // Track which WinAnsi chars are used
    subset_data: ?[]const u8 = null, // Generated subset TTF (lazily created)

    // CID mode: track Unicode codepoint → glyph ID mappings
    // Key: Unicode codepoint, Value: original glyph ID from font
    cid_used_glyphs: std.AutoArrayHashMapUnmanaged(u21, u16) = .{},
    cid_glyph_widths: std.AutoArrayHashMapUnmanaged(u16, u16) = .{}, // GID → width in 1/1000 em

    // Glyph → codepoint mapping for ToUnicode (handles calt contextual variants)
    // Key: glyph ID, Value: Unicode codepoint that produced this glyph
    // Needed because calt can produce different glyphs for the same codepoint in different contexts
    glyph_to_codepoint: std.AutoArrayHashMapUnmanaged(u16, u21) = .{},

    // Glyph ID remapping for compact CFF subsets (original GID → new compact GID)
    // Only populated for CFF fonts with subsetting enabled
    gid_remap: std.AutoArrayHashMapUnmanaged(u16, u16) = .{},

    // OpenType feature support
    ot_features: ?*opentype.OpenTypeFeatures = null,
    feature_flags: opentype.FeatureFlags = .{}, // liga=on, kern=on by default

    // Ligature glyph → original codepoints mapping for ToUnicode CMap
    // Key: ligature glyph ID (original), Value: array of codepoints that form it
    ligature_codepoints: std.AutoArrayHashMapUnmanaged(u16, []const u21) = .{},

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
        self.allocator.destroy(self);
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
            try ot.parseGSUB(gsub_data);
        }

        // Parse GPOS table if present (for kerning)
        if (self.font.getTable("GPOS".*)) |gpos_data| {
            try ot.parseGPOS(gpos_data);
        }

        self.ot_features = ot;
    }

    /// Set OpenType feature flag
    pub fn setFeature(self: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void {
        switch (feature) {
            .liga => self.feature_flags.liga = enabled,
            .kern => self.feature_flags.kern = enabled,
            .clig => self.feature_flags.clig = enabled,
            .dlig => self.feature_flags.dlig = enabled,
            .hlig => self.feature_flags.hlig = enabled,
            .calt => self.feature_flags.calt = enabled,
            .mark => self.feature_flags.mark = enabled,
            .mkmk => self.feature_flags.mkmk = enabled,
        }
    }

    /// Mark Unicode codepoints as used (CID mode)
    /// Parses UTF-8 text and records Unicode→GlyphID mappings
    /// Applies ligature substitution if enabled
    pub fn markUnicodeCharsUsed(self: *EmbeddedFont, text: []const u8) !void {
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(self.font.head.?.units_per_em));

        // First pass: decode text into codepoints and map to glyph IDs
        var codepoints = std.ArrayListUnmanaged(u21){};
        defer codepoints.deinit(self.allocator);
        var base_glyphs = std.ArrayListUnmanaged(u16){};
        defer base_glyphs.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch {
                i += 1;
                continue;
            };

            try codepoints.append(self.allocator, codepoint);
            const gid = self.font.getGlyphId(codepoint) orelse 0;
            try base_glyphs.append(self.allocator, gid);

            i += len;
        }

        // Initialize OpenType features if any GSUB/GPOS feature is enabled
        const needs_ot = self.feature_flags.liga or self.feature_flags.dlig or
            self.feature_flags.clig or self.feature_flags.hlig or
            self.feature_flags.calt or self.feature_flags.kern;
        if (needs_ot) {
            try self.initOpenTypeFeatures();
        }

        // Apply GSUB substitutions if enabled (calt and/or ligatures)
        if (base_glyphs.items.len > 0) {
            if (self.ot_features) |ot| {
                const has_calt = self.feature_flags.calt and ot.chain_context_lookups.items.len > 0;
                const has_liga = self.feature_flags.liga and ot.liga_lookups.items.len > 0;
                const has_dlig = self.feature_flags.dlig and ot.dlig_lookups.items.len > 0;
                const has_clig = self.feature_flags.clig and ot.clig_lookups.items.len > 0;
                const has_hlig = self.feature_flags.hlig and ot.hlig_lookups.items.len > 0;

                if (has_calt or has_liga or has_dlig or has_clig or has_hlig) {
                    // Apply GSUB substitutions and track results
                    try self.applyGSUBAndTrack(codepoints.items, base_glyphs.items, scale);
                    return;
                }
            }
        }

        // No ligatures - just track the base glyphs
        for (codepoints.items, base_glyphs.items) |cp, gid| {
            if (!self.cid_used_glyphs.contains(cp)) {
                try self.cid_used_glyphs.put(self.allocator, cp, gid);
            }
            // Track glyph→codepoint for ToUnicode
            if (!self.glyph_to_codepoint.contains(gid)) {
                try self.glyph_to_codepoint.put(self.allocator, gid, cp);
            }
            if (!self.cid_glyph_widths.contains(gid)) {
                if (self.font.getGlyphWidth(gid)) |w| {
                    const width: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
                    try self.cid_glyph_widths.put(self.allocator, gid, width);
                }
            }
        }
    }

    /// Apply GSUB substitutions (calt and/or ligatures) and track all resulting glyphs
    fn applyGSUBAndTrack(self: *EmbeddedFont, codepoints: []const u21, base_glyphs: []const u16, scale: f64) !void {
        const ot = self.ot_features orelse return;

        // Apply GSUB substitutions to get final glyph sequence
        const final_glyphs = try ot.applyGSUBWithFlags(base_glyphs, self.feature_flags);
        defer self.allocator.free(final_glyphs);

        // Track all glyphs in the final sequence
        // We need to handle cases where substitutions occurred (ligatures/calt changes)
        var src_pos: usize = 0;
        var dst_pos: usize = 0;

        while (dst_pos < final_glyphs.len and src_pos < codepoints.len) {
            const gid = final_glyphs[dst_pos];

            // Check if this might be a ligature (glyph consumes multiple codepoints)
            // We detect this by checking if the glyph at dst_pos differs from base_glyphs[src_pos]
            // and trying to find how many source glyphs were consumed
            if (src_pos < base_glyphs.len and gid != base_glyphs[src_pos]) {
                // A substitution occurred - could be a ligature or single substitution
                // Try to find how many source glyphs map to this output glyph
                var consumed: usize = 1;

                // Check all enabled ligature features for a match
                const lookup_arrays = [_][]const opentype.LigatureSubst{
                    if (self.feature_flags.liga) ot.liga_lookups.items else &[_]opentype.LigatureSubst{},
                    if (self.feature_flags.dlig) ot.dlig_lookups.items else &[_]opentype.LigatureSubst{},
                    if (self.feature_flags.clig) ot.clig_lookups.items else &[_]opentype.LigatureSubst{},
                    if (self.feature_flags.hlig) ot.hlig_lookups.items else &[_]opentype.LigatureSubst{},
                    if (self.feature_flags.calt) ot.calt_liga_lookups.items else &[_]opentype.LigatureSubst{},
                };

                outer: for (lookup_arrays) |lookups| {
                    for (lookups) |lookup| {
                        if (lookup.findLigature(base_glyphs, src_pos, ot.ligature_sets.items, ot.ligature_structs.items)) |match| {
                            // Check if output glyph matches the ligature directly
                            // OR if the ligature was further substituted by chain context
                            if (match.lig_glyph == gid) {
                                consumed = match.consumed;
                                break :outer;
                            }
                            // Check if chain context substituted the ligature glyph to the output glyph
                            if (self.feature_flags.calt) {
                                for (ot.single_lookups.items) |single| {
                                    if (single.substitute(match.lig_glyph)) |subst_glyph| {
                                        if (subst_glyph == gid) {
                                            consumed = match.consumed;
                                            break :outer;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (consumed > 1) {
                    // Ligature: track codepoints for ToUnicode mapping
                    // But skip if this glyph is already mapped to a single codepoint
                    // (e.g., Inter has ⇔ as both a direct glyph AND a <=> ligature)
                    const already_single = blk: {
                        var iter = self.cid_used_glyphs.iterator();
                        while (iter.next()) |entry| {
                            if (entry.value_ptr.* == gid) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!already_single and !self.ligature_codepoints.contains(gid)) {
                        const lig_cps = try self.allocator.alloc(u21, consumed);
                        for (0..consumed) |j| {
                            if (src_pos + j < codepoints.len) {
                                lig_cps[j] = codepoints[src_pos + j];
                            }
                        }
                        try self.ligature_codepoints.put(self.allocator, gid, lig_cps);
                    }
                } else {
                    // Single substitution (calt): track codepoint->substituted glyph mapping
                    const cp = codepoints[src_pos];
                    if (!self.cid_used_glyphs.contains(cp)) {
                        try self.cid_used_glyphs.put(self.allocator, cp, gid);
                    }
                    // Track glyph→codepoint for ToUnicode (handles calt variants)
                    if (!self.glyph_to_codepoint.contains(gid)) {
                        try self.glyph_to_codepoint.put(self.allocator, gid, cp);
                    }
                }

                // Track width for this glyph
                if (!self.cid_glyph_widths.contains(gid)) {
                    if (self.font.getGlyphWidth(gid)) |w| {
                        const width: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
                        try self.cid_glyph_widths.put(self.allocator, gid, width);
                    }
                }

                src_pos += consumed;
            } else {
                // No substitution or single calt substitution (1:1 mapping)
                const cp = codepoints[src_pos];
                if (!self.cid_used_glyphs.contains(cp)) {
                    try self.cid_used_glyphs.put(self.allocator, cp, gid);
                }
                // Track glyph→codepoint for ToUnicode
                if (!self.glyph_to_codepoint.contains(gid)) {
                    try self.glyph_to_codepoint.put(self.allocator, gid, cp);
                }
                if (!self.cid_glyph_widths.contains(gid)) {
                    if (self.font.getGlyphWidth(gid)) |w| {
                        const width: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
                        try self.cid_glyph_widths.put(self.allocator, gid, width);
                    }
                }
                src_pos += 1;
            }

            dst_pos += 1;
        }
    }

    /// Get glyph sequence for text with ligature substitution applied
    /// Returns allocated slice that caller must free
    pub fn getGlyphsForText(self: *EmbeddedFont, text: []const u8) ![]u16 {
        var base_glyphs = std.ArrayListUnmanaged(u16){};
        defer base_glyphs.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch {
                i += 1;
                continue;
            };

            const gid = self.font.getGlyphId(codepoint) orelse 0;
            try base_glyphs.append(self.allocator, gid);
            i += len;
        }

        // Apply GSUB substitutions if enabled and available
        if (self.ot_features) |ot| {
            const has_gsub = (self.feature_flags.calt and (ot.calt_liga_lookups.items.len > 0 or ot.chain_context_lookups.items.len > 0)) or
                (self.feature_flags.liga and ot.liga_lookups.items.len > 0) or
                (self.feature_flags.dlig and ot.dlig_lookups.items.len > 0) or
                (self.feature_flags.clig and ot.clig_lookups.items.len > 0) or
                (self.feature_flags.hlig and ot.hlig_lookups.items.len > 0);

            if (has_gsub) {
                return ot.applyGSUBWithFlags(base_glyphs.items, self.feature_flags);
            }
        }

        return base_glyphs.toOwnedSlice(self.allocator);
    }

    /// Get kerning value between two glyphs (in font units)
    pub fn getKerning(self: *EmbeddedFont, glyph1: u16, glyph2: u16) i16 {
        if (!self.feature_flags.kern) return 0;

        if (self.ot_features) |ot| {
            return ot.getKerning(glyph1, glyph2);
        }
        return 0;
    }

    /// Get mark positioning offset for a mark glyph following a base glyph
    /// Returns (dx, dy) in font units (design units), or null if no positioning applies
    pub fn getMarkOffset(self: *EmbeddedFont, base_glyph: u16, mark_glyph: u16) ?opentype.MarkOffset {
        if (!self.feature_flags.mark and !self.feature_flags.mkmk) return null;

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

    /// Generate ToUnicode CMap for CID mode (2-byte glyph IDs → Unicode)
    /// Includes ligature glyph → component codepoints mappings for proper text extraction
    pub fn generateCIDToUnicodeCMap(self: *const EmbeddedFont) ![]const u8 {
        var cmap = std.ArrayListUnmanaged(u8){};
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
                    const entry_s = std.fmt.bufPrint(&entry_buf, "<{X:0>4}> <{X:0>4}{X:0>4}>\n", .{ gid, high, low }) catch unreachable;
                    try cmap.appendSlice(self.allocator, entry_s);
                } else {
                    const entry_s = std.fmt.bufPrint(&entry_buf, "<{X:0>4}> <{X:0>4}>\n", .{ gid, codepoint }) catch unreachable;
                    try cmap.appendSlice(self.allocator, entry_s);
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
                var fbs = std.io.fixedBufferStream(&entry_buf);
                const writer = fbs.writer();

                try writer.print("<{X:0>4}> <", .{lig_gid});
                for (lig_codepoints) |cp| {
                    if (cp > 0xFFFF) {
                        const adjusted = cp - 0x10000;
                        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
                        const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                        try writer.print("{X:0>4}{X:0>4}", .{ high, low });
                    } else {
                        try writer.print("{X:0>4}", .{cp});
                    }
                }
                try writer.writeAll(">\n");

                try cmap.appendSlice(self.allocator, fbs.getWritten());
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
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "[");

        const has_remap = self.gid_remap.count() > 0;

        // Get sorted glyph IDs for consistent output
        // If remapping, we need to collect the NEW glyph IDs
        const GidWidthPair = struct { gid: u16, width: u16 };
        var gid_width_pairs = std.ArrayListUnmanaged(GidWidthPair){};
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
            const entry = std.fmt.bufPrint(&entry_buf, "{d} [{d}] ", .{ pair.gid, pair.width }) catch unreachable;
            try buf.appendSlice(self.allocator, entry);
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

/// Create a subset TTF containing only the used glyphs
fn createSubsetTTF(allocator: std.mem.Allocator, emb: *const EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const head = font.head orelse return error.MissingTable;
    const hhea = font.hhea orelse return error.MissingTable;
    _ = font.maxp orelse return error.MissingTable; // verify table exists

    // Collect unique glyph IDs we need from both WinAnsi and CID modes
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    // Always include glyph 0 (.notdef)
    try glyph_set.put(allocator, 0, {});

    // Collect from WinAnsi mode (used_chars)
    for (0..256) |i| {
        if (emb.used_chars[i]) {
            const unicode = win_ansi_to_unicode[i];
            if (font.getGlyphId(unicode)) |gid| {
                try glyph_set.put(allocator, gid, {});
            }
        }
    }

    // Collect from CID mode (cid_used_glyphs)
    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        try glyph_set.put(allocator, entry.value_ptr.*, {});
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

/// Create a subset TTF for CID mode (preserves glyph IDs, no remapping)
/// This creates a sparse font with entries for all glyphs 0..max_gid
fn createSubsetTTF_CID(allocator: std.mem.Allocator, emb: *const EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const head = font.head orelse return error.MissingTable;
    const hhea = font.hhea orelse return error.MissingTable;
    const orig_maxp = font.maxp orelse return error.MissingTable;

    const orig_glyf = font.getTable("glyf".*) orelse return error.MissingTable;
    const orig_loca = font.getTable("loca".*) orelse return error.MissingTable;
    const orig_hmtx = font.getTable("hmtx".*) orelse return error.MissingTable;
    const loca_format = head.index_to_loc_format;

    // Collect used glyph IDs from CID mode
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    // Always include glyph 0 (.notdef)
    try glyph_set.put(allocator, 0, {});

    // Collect from CID mode (cid_used_glyphs)
    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        try glyph_set.put(allocator, entry.value_ptr.*, {});
    }

    // Recursively add component glyphs referenced by composite glyphs
    // Keep expanding until no new glyphs are added
    var changed = true;
    while (changed) {
        changed = false;
        // Collect current glyphs to check (can't modify while iterating)
        var glyphs_to_check = std.ArrayListUnmanaged(u16){};
        defer glyphs_to_check.deinit(allocator);

        var check_iter = glyph_set.keyIterator();
        while (check_iter.next()) |gid| {
            try glyphs_to_check.append(allocator, gid.*);
        }

        for (glyphs_to_check.items) |gid| {
            const components = getCompositeComponents(orig_glyf, orig_loca, loca_format, gid);
            for (components) |comp_gid| {
                if (comp_gid < orig_maxp.num_glyphs and !glyph_set.contains(comp_gid)) {
                    try glyph_set.put(allocator, comp_gid, {});
                    changed = true;
                }
            }
        }
    }

    // Find max glyph ID
    var max_gid: u16 = 0;
    var key_iter = glyph_set.keyIterator();
    while (key_iter.next()) |gid| {
        if (gid.* > max_gid) max_gid = gid.*;
    }

    // Limit to original font's glyph count
    if (max_gid >= orig_maxp.num_glyphs) {
        max_gid = orig_maxp.num_glyphs - 1;
    }

    const num_glyphs: u16 = max_gid + 1;

    // Build new glyf data (sparse - only used glyphs have data)
    var new_glyf = std.ArrayListUnmanaged(u8){};
    defer new_glyf.deinit(allocator);

    // Build new loca (offsets into glyf) - entries for all 0..max_gid
    var new_loca = std.ArrayListUnmanaged(u8){};
    defer new_loca.deinit(allocator);

    // Process each glyph from 0 to max_gid
    var gid: u16 = 0;
    while (gid <= max_gid) : (gid += 1) {
        // Record offset in new loca
        const offset: u32 = @intCast(new_glyf.items.len);
        if (loca_format == 0) {
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(offset / 2))));
        } else {
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, offset)));
        }

        // Only include glyph data if this glyph is used
        if (glyph_set.contains(gid)) {
            const glyph_start = getLocaOffset(orig_loca, gid, loca_format);
            const glyph_end = getLocaOffset(orig_loca, gid + 1, loca_format);

            if (glyph_end > glyph_start and glyph_end <= orig_glyf.len) {
                const glyph_data = orig_glyf[glyph_start..glyph_end];
                try new_glyf.appendSlice(allocator, glyph_data);
            }
        }
        // Unused glyphs: no data added, so next loca entry will have same offset (zero-length glyph)
    }

    // Final loca entry (end of last glyph)
    const final_offset: u32 = @intCast(new_glyf.items.len);
    if (loca_format == 0) {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(final_offset / 2))));
    } else {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, final_offset)));
    }

    // Build new hmtx (horizontal metrics) for all glyphs 0..max_gid
    var new_hmtx = std.ArrayListUnmanaged(u8){};
    defer new_hmtx.deinit(allocator);

    gid = 0;
    while (gid <= max_gid) : (gid += 1) {
        var advance: u16 = 0;
        var lsb: i16 = 0;

        if (gid < hhea.num_of_long_hor_metrics) {
            const off = @as(usize, gid) * 4;
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
            const lsb_idx = gid - hhea.num_of_long_hor_metrics;
            const lsb_off = @as(usize, hhea.num_of_long_hor_metrics) * 4 + @as(usize, lsb_idx) * 2;
            if (lsb_off + 2 <= orig_hmtx.len) {
                lsb = readI16(orig_hmtx, lsb_off);
            }
        }

        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, advance)));
        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, lsb)));
    }

    // Build minimal cmap (Format 4 with just .notdef mapping)
    // CID mode uses glyph IDs directly, but some PDF readers still want a cmap
    var new_cmap = std.ArrayListUnmanaged(u8){};
    defer new_cmap.deinit(allocator);

    // cmap header
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // version
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // numTables

    // Encoding record for Windows Unicode BMP
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 3))); // platformID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // encodingID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, 12))); // offset

    // Minimal Format 4 subtable (just final segment 0xFFFF)
    const seg_count: u16 = 1;
    const seg_count_x2: u16 = seg_count * 2;
    const search_range: u16 = 2;
    const entry_selector: u16 = 0;
    const range_shift: u16 = 0;

    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 4))); // format
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 32))); // length
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // language
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, seg_count_x2)));
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, search_range)));
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, entry_selector)));
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, range_shift)));
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // endCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // reservedPad
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // startCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, 1))); // idDelta
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // idRangeOffset

    // Assemble the final TTF
    const table_count: u16 = 9;
    const header_size: usize = 12 + @as(usize, table_count) * 16;

    const orig_head = font.getTable("head".*) orelse return error.MissingTable;
    const orig_hhea = font.getTable("hhea".*) orelse return error.MissingTable;
    const orig_name = font.getTable("name".*);
    const orig_post = font.getTable("post".*);

    // Copy and modify head
    const new_head = try allocator.alloc(u8, orig_head.len);
    defer allocator.free(new_head);
    @memcpy(new_head, orig_head);

    // Copy and modify hhea: update numOfLongHorMetrics
    const new_hhea = try allocator.alloc(u8, orig_hhea.len);
    defer allocator.free(new_hhea);
    @memcpy(new_hhea, orig_hhea);
    std.mem.writeInt(u16, new_hhea[34..36], num_glyphs, .big);

    // Build maxp
    var new_maxp: [6]u8 = undefined;
    std.mem.writeInt(u32, new_maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, new_maxp[4..6], num_glyphs, .big);

    // Calculate padded sizes and offsets
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

    // Allocate and build output
    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    // Write TTF header
    std.mem.writeInt(u32, output[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, output[4..6], table_count, .big);
    const ttf_search_range: u16 = 128;
    const ttf_entry_selector: u16 = 3;
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
        std.mem.writeInt(u32, output[post_offset..][0..4], 0x00030000, .big);
    }

    return output;
}

/// Create a compact TTF subset with glyph ID remapping
/// Unlike createSubsetTTF_CID, this creates minimal tables with only used glyphs
/// and remaps glyph IDs for maximum size reduction
fn createSubsetTTF_Compact(allocator: std.mem.Allocator, emb: *EmbeddedFont) ![]const u8 {
    const font = &emb.font;
    const head = font.head orelse return error.MissingTable;
    const hhea = font.hhea orelse return error.MissingTable;
    const orig_maxp = font.maxp orelse return error.MissingTable;

    const orig_glyf = font.getTable("glyf".*) orelse return error.MissingTable;
    const orig_loca = font.getTable("loca".*) orelse return error.MissingTable;
    const orig_hmtx = font.getTable("hmtx".*) orelse return error.MissingTable;
    const loca_format = head.index_to_loc_format;

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
    var changed = true;
    while (changed) {
        changed = false;
        var glyphs_to_check = std.ArrayListUnmanaged(u16){};
        defer glyphs_to_check.deinit(allocator);

        var check_iter = glyph_set.keyIterator();
        while (check_iter.next()) |gid| {
            try glyphs_to_check.append(allocator, gid.*);
        }

        for (glyphs_to_check.items) |gid| {
            const components = getCompositeComponents(orig_glyf, orig_loca, loca_format, gid);
            for (components) |comp_gid| {
                if (comp_gid < orig_maxp.num_glyphs and !glyph_set.contains(comp_gid)) {
                    try glyph_set.put(allocator, comp_gid, {});
                    changed = true;
                }
            }
        }
    }

    // Build sorted glyph list (0 first, then ascending order)
    var glyph_list = std.ArrayListUnmanaged(u16){};
    defer glyph_list.deinit(allocator);

    try glyph_list.append(allocator, 0); // .notdef always first

    var key_iter = glyph_set.keyIterator();
    while (key_iter.next()) |gid| {
        if (gid.* != 0) {
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
    var new_glyf = std.ArrayListUnmanaged(u8){};
    defer new_glyf.deinit(allocator);

    var new_loca = std.ArrayListUnmanaged(u8){};
    defer new_loca.deinit(allocator);

    // Process glyphs in new order
    for (glyph_list.items) |orig_gid| {
        // Record offset
        const offset: u32 = @intCast(new_glyf.items.len);
        if (loca_format == 0) {
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(offset / 2))));
        } else {
            try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, offset)));
        }

        // Get original glyph data
        if (orig_gid < orig_maxp.num_glyphs) {
            const glyph_start = getLocaOffset(orig_loca, orig_gid, loca_format);
            const glyph_end = getLocaOffset(orig_loca, orig_gid + 1, loca_format);

            if (glyph_end > glyph_start and glyph_end <= orig_glyf.len) {
                var glyph_data = try allocator.alloc(u8, glyph_end - glyph_start);
                defer allocator.free(glyph_data);
                @memcpy(glyph_data, orig_glyf[glyph_start..glyph_end]);

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
    const final_offset: u32 = @intCast(new_glyf.items.len);
    if (loca_format == 0) {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(final_offset / 2))));
    } else {
        try new_loca.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, final_offset)));
    }

    // Build compact hmtx
    var new_hmtx = std.ArrayListUnmanaged(u8){};
    defer new_hmtx.deinit(allocator);

    for (glyph_list.items) |orig_gid| {
        var advance: u16 = 0;
        var lsb: i16 = 0;

        if (orig_gid < hhea.num_of_long_hor_metrics) {
            const off = @as(usize, orig_gid) * 4;
            if (off + 4 <= orig_hmtx.len) {
                advance = readU16(orig_hmtx, off);
                lsb = readI16(orig_hmtx, off + 2);
            }
        } else {
            if (hhea.num_of_long_hor_metrics > 0) {
                const off = (@as(usize, hhea.num_of_long_hor_metrics) - 1) * 4;
                if (off + 2 <= orig_hmtx.len) {
                    advance = readU16(orig_hmtx, off);
                }
            }
            const lsb_idx = orig_gid - hhea.num_of_long_hor_metrics;
            const lsb_off = @as(usize, hhea.num_of_long_hor_metrics) * 4 + @as(usize, lsb_idx) * 2;
            if (lsb_off + 2 <= orig_hmtx.len) {
                lsb = readI16(orig_hmtx, lsb_off);
            }
        }

        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, advance)));
        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, lsb)));
    }

    // Build minimal cmap (same as CID version)
    var new_cmap = std.ArrayListUnmanaged(u8){};
    defer new_cmap.deinit(allocator);

    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // version
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // numTables
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 3))); // platformID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // encodingID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, 12))); // offset

    // Minimal Format 4
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 4))); // format
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 32))); // length
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // language
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 2))); // segCountX2
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 2))); // searchRange
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // entrySelector
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // rangeShift
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // endCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // reservedPad
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // startCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, 1))); // idDelta
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // idRangeOffset

    // Assemble TTF
    const table_count: u16 = 9;
    const header_size: usize = 12 + @as(usize, table_count) * 16;

    const orig_head = font.getTable("head".*) orelse return error.MissingTable;
    const orig_hhea = font.getTable("hhea".*) orelse return error.MissingTable;
    const orig_name = font.getTable("name".*);
    const orig_post = font.getTable("post".*);

    const new_head = try allocator.alloc(u8, orig_head.len);
    defer allocator.free(new_head);
    @memcpy(new_head, orig_head);

    const new_hhea = try allocator.alloc(u8, orig_hhea.len);
    defer allocator.free(new_hhea);
    @memcpy(new_hhea, orig_hhea);
    std.mem.writeInt(u16, new_hhea[34..36], num_glyphs, .big);

    var new_maxp: [6]u8 = undefined;
    std.mem.writeInt(u32, new_maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, new_maxp[4..6], num_glyphs, .big);

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

    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    std.mem.writeInt(u32, output[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, output[4..6], table_count, .big);
    std.mem.writeInt(u16, output[6..8], 128, .big); // searchRange
    std.mem.writeInt(u16, output[8..10], 3, .big); // entrySelector
    std.mem.writeInt(u16, output[10..12], table_count * 16 - 128, .big); // rangeShift

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
        std.mem.writeInt(u32, output[post_offset..][0..4], 0x00030000, .big);
    }

    return output;
}

/// Create a subset CFF for CID mode (preserves glyph IDs)
fn createSubsetCFF(allocator: std.mem.Allocator, emb: *const EmbeddedFont) ![]const u8 {
    const cff_data = emb.font.getTable("CFF ".*) orelse
        emb.font.getTable("CFF2".*) orelse
        return error.MissingTable;

    // Collect used glyph IDs
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    try glyph_set.put(allocator, 0, {}); // .notdef

    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        try glyph_set.put(allocator, entry.value_ptr.*, {});
    }

    // Add ligature glyph IDs
    var lig_iter = emb.ligature_codepoints.iterator();
    while (lig_iter.next()) |entry| {
        try glyph_set.put(allocator, entry.key_ptr.*, {});
    }

    // Find max glyph ID
    var max_gid: u16 = 0;
    var key_iter = glyph_set.keyIterator();
    while (key_iter.next()) |gid| {
        if (gid.* > max_gid) max_gid = gid.*;
    }

    // Parse CFF structure
    const hdr_size = cff_data[2];

    // Skip Name INDEX
    const name_end = skipCFFIndex(cff_data, hdr_size);

    // Skip Top DICT INDEX (but remember its location for later)
    const topdict_start = name_end;
    const topdict_end = skipCFFIndex(cff_data, topdict_start);

    // Skip String INDEX
    const string_start = topdict_end;
    const string_end = skipCFFIndex(cff_data, string_start);

    // Skip Global Subr INDEX
    const gsubr_start = string_end;
    const gsubr_end = skipCFFIndex(cff_data, gsubr_start);

    // Parse Top DICT to find CharStrings offset
    const charstrings_offset = parseCFFTopDictForCharStrings(cff_data, topdict_start) orelse
        return error.InvalidCFF;

    // Parse CharStrings INDEX
    const cs_count = readU16(cff_data, charstrings_offset);
    if (cs_count == 0) return error.InvalidCFF;

    const cs_off_size = cff_data[charstrings_offset + 2];
    const cs_offsets_start = charstrings_offset + 3;
    const cs_data_start = cs_offsets_start + (@as(usize, cs_count) + 1) * cs_off_size;

    // Limit max_gid to actual glyph count
    if (max_gid >= cs_count) {
        max_gid = cs_count - 1;
    }
    const num_glyphs: u16 = max_gid + 1;

    // Build new CharStrings INDEX - copy ALL charstrings up to num_glyphs (no sparse data)
    // This preserves glyph ID mapping and avoids issues with empty placeholder charstrings
    var new_charstrings = std.ArrayListUnmanaged(u8){};
    defer new_charstrings.deinit(allocator);

    // Calculate size of original CharStrings data we need (glyphs 0 to num_glyphs-1)
    const orig_first_offset = readCFFOffset(cff_data, cs_offsets_start, 0, cs_off_size);
    const orig_last_offset = readCFFOffset(cff_data, cs_offsets_start, num_glyphs, cs_off_size);
    const charstrings_data_size = orig_last_offset - orig_first_offset;

    // Determine offset size needed for new CharStrings
    const new_cs_off_size: u8 = if (charstrings_data_size < 256) 1 else if (charstrings_data_size < 65536) 2 else 3;

    // Build CharStrings INDEX header
    try new_charstrings.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, num_glyphs)));
    try new_charstrings.append(allocator, new_cs_off_size);

    // Copy and convert offsets (may need to change offset size)
    var gid: u16 = 0;
    while (gid <= num_glyphs) : (gid += 1) {
        const orig_off = readCFFOffset(cff_data, cs_offsets_start, gid, cs_off_size);
        // Rebase offset relative to first glyph
        const new_off: u32 = @intCast(orig_off - orig_first_offset + 1);
        if (new_cs_off_size == 1) {
            try new_charstrings.append(allocator, @intCast(new_off));
        } else if (new_cs_off_size == 2) {
            try new_charstrings.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(new_off))));
        } else {
            const off_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, new_off));
            try new_charstrings.appendSlice(allocator, off_bytes[1..4]);
        }
    }

    // Copy CharStrings data for glyphs 0 to num_glyphs-1
    const cs_data = cff_data[cs_data_start + orig_first_offset - 1 ..][0..charstrings_data_size];
    try new_charstrings.appendSlice(allocator, cs_data);

    // Build new CFF: header + name + topdict + strings + gsubrs + charset + charstrings + private
    // For simplicity, keep everything before CharStrings, replace CharStrings, keep Private

    // Calculate new CharStrings offset
    const new_charstrings_offset = gsubr_end;

    // Get original charset info and copy it (preserves correct SIDs for glyph names)
    const orig_charset_offset = parseCFFDictForOperator(
        cff_data[topdict_start + 3 + 2 * cff_data[topdict_start + 2] ..][0 .. readCFFOffset(cff_data, topdict_start + 3, 1, cff_data[topdict_start + 2]) - 1],
        15,
    ) orelse return error.InvalidCFF;

    // Calculate charset size for our subset (use num_glyphs, not original cs_count)
    var subset_charset_size: usize = 1; // format byte
    const charset_format = cff_data[orig_charset_offset];
    if (charset_format == 0) {
        // Format 0: 2 bytes per glyph (except .notdef)
        subset_charset_size = 1 + (@as(usize, num_glyphs) - 1) * 2;
    } else if (charset_format == 1) {
        // Format 1: ranges with 1-byte nLeft - parse until we cover num_glyphs-1 glyphs
        var pos = orig_charset_offset + 1;
        var covered: usize = 1; // .notdef is glyph 0
        while (covered < num_glyphs and pos + 3 <= cff_data.len) {
            const nleft = cff_data[pos + 2];
            const range_covers = @as(usize, nleft) + 1;
            if (covered + range_covers > num_glyphs) {
                // This range extends past our subset - truncate it
                // We need to include a partial range
                pos += 3;
                break;
            }
            covered += range_covers;
            pos += 3;
        }
        subset_charset_size = pos - orig_charset_offset;
    } else if (charset_format == 2) {
        // Format 2: ranges with 2-byte nLeft
        var pos = orig_charset_offset + 1;
        var covered: usize = 1;
        while (covered < num_glyphs and pos + 4 <= cff_data.len) {
            const nleft = readU16(cff_data, pos + 2);
            const range_covers = @as(usize, nleft) + 1;
            if (covered + range_covers > num_glyphs) {
                pos += 4;
                break;
            }
            covered += range_covers;
            pos += 4;
        }
        subset_charset_size = pos - orig_charset_offset;
    }

    // Charset goes right after Global Subrs, CharStrings after that
    const new_charstrings_actual_offset = new_charstrings_offset + subset_charset_size;

    // Get original Private DICT info
    const private_info = parseCFFTopDictForPrivate(cff_data, topdict_start);
    const orig_private_size = private_info.size;
    const orig_private_offset = private_info.offset;

    // Check for Local Subrs in Private DICT
    const private_dict_data = cff_data[orig_private_offset..][0..orig_private_size];
    const local_subrs_relative_offset = parseCFFDictForOperator(private_dict_data, 19); // op 19 = Subrs
    var local_subrs_size: usize = 0;
    if (local_subrs_relative_offset) |rel_off| {
        const local_subrs_offset = orig_private_offset + rel_off;
        const local_subrs_end = skipCFFIndex(cff_data, local_subrs_offset);
        local_subrs_size = local_subrs_end - local_subrs_offset;
    }

    // Total Private section size = Private DICT + Local Subrs INDEX
    const total_private_size = orig_private_size + local_subrs_size;

    const new_private_offset = new_charstrings_actual_offset + new_charstrings.items.len;

    // Build new Top DICT with updated offsets
    var new_topdict = std.ArrayListUnmanaged(u8){};
    defer new_topdict.deinit(allocator);

    // Copy original Top DICT entries except charset, CharStrings, Private
    try buildUpdatedTopDict(allocator, cff_data, topdict_start, &new_topdict, .{
        .charset = @intCast(new_charstrings_offset), // charset at gsubr_end
        .charstrings = @intCast(new_charstrings_actual_offset),
        .private_size = orig_private_size,
        .private_offset = @intCast(new_private_offset),
    });

    // Build new Top DICT INDEX
    var new_topdict_index = std.ArrayListUnmanaged(u8){};
    defer new_topdict_index.deinit(allocator);

    try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // count
    const td_off_size: u8 = if (new_topdict.items.len < 256) 1 else 2;
    try new_topdict_index.append(allocator, td_off_size);
    if (td_off_size == 1) {
        try new_topdict_index.append(allocator, 1);
        try new_topdict_index.append(allocator, @intCast(new_topdict.items.len + 1));
    } else {
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(new_topdict.items.len + 1))));
    }
    try new_topdict_index.appendSlice(allocator, new_topdict.items);

    // Now we need to recalculate because Top DICT size changed
    // This changes all subsequent offsets... let's iterate
    const name_index_data = cff_data[hdr_size..name_end];
    const string_index_data = cff_data[string_start..string_end];
    const gsubr_index_data = cff_data[gsubr_start..gsubr_end];

    // Calculate actual offsets
    var final_offset: usize = hdr_size;
    final_offset += name_index_data.len;
    final_offset += new_topdict_index.items.len;
    final_offset += string_index_data.len;
    final_offset += gsubr_index_data.len;

    const final_charset_offset = final_offset;
    final_offset += subset_charset_size;

    const final_charstrings_offset = final_offset;
    final_offset += new_charstrings.items.len;

    const final_private_offset = final_offset;

    // Rebuild Top DICT with correct offsets
    new_topdict.clearRetainingCapacity();
    try buildUpdatedTopDict(allocator, cff_data, topdict_start, &new_topdict, .{
        .charset = @intCast(final_charset_offset),
        .charstrings = @intCast(final_charstrings_offset),
        .private_size = orig_private_size,
        .private_offset = @intCast(final_private_offset),
    });

    // Rebuild Top DICT INDEX with new data
    new_topdict_index.clearRetainingCapacity();
    try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
    const td_off_size2: u8 = if (new_topdict.items.len < 256) 1 else 2;
    try new_topdict_index.append(allocator, td_off_size2);
    if (td_off_size2 == 1) {
        try new_topdict_index.append(allocator, 1);
        try new_topdict_index.append(allocator, @intCast(new_topdict.items.len + 1));
    } else {
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(new_topdict.items.len + 1))));
    }
    try new_topdict_index.appendSlice(allocator, new_topdict.items);

    // Assemble final CFF
    const total_size = hdr_size + name_index_data.len + new_topdict_index.items.len +
        string_index_data.len + gsubr_index_data.len +
        subset_charset_size + new_charstrings.items.len + total_private_size;

    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    var pos: usize = 0;

    // Header
    @memcpy(output[0..hdr_size], cff_data[0..hdr_size]);
    pos = hdr_size;

    // Name INDEX
    @memcpy(output[pos..][0..name_index_data.len], name_index_data);
    pos += name_index_data.len;

    // Top DICT INDEX
    @memcpy(output[pos..][0..new_topdict_index.items.len], new_topdict_index.items);
    pos += new_topdict_index.items.len;

    // String INDEX
    @memcpy(output[pos..][0..string_index_data.len], string_index_data);
    pos += string_index_data.len;

    // Global Subr INDEX
    @memcpy(output[pos..][0..gsubr_index_data.len], gsubr_index_data);
    pos += gsubr_index_data.len;

    // Charset (copy from original)
    @memcpy(output[pos..][0..subset_charset_size], cff_data[orig_charset_offset..][0..subset_charset_size]);
    pos += subset_charset_size;

    // CharStrings INDEX
    @memcpy(output[pos..][0..new_charstrings.items.len], new_charstrings.items);
    pos += new_charstrings.items.len;

    // Private DICT + Local Subrs
    if (orig_private_offset + total_private_size <= cff_data.len) {
        @memcpy(output[pos..][0..total_private_size], cff_data[orig_private_offset..][0..total_private_size]);
    }

    return output;
}

/// Create a compact subset CFF with glyph ID remapping
/// This achieves better compression than createSubsetCFF by only including used glyphs
/// and remapping glyph IDs to 0, 1, 2, ...
fn createSubsetCFF_Compact(allocator: std.mem.Allocator, emb: *EmbeddedFont) ![]const u8 {
    const cff_data = emb.font.getTable("CFF ".*) orelse
        emb.font.getTable("CFF2".*) orelse
        return error.MissingTable;

    // Collect used glyph IDs into sorted list
    var glyph_list = std.ArrayListUnmanaged(u16){};
    defer glyph_list.deinit(allocator);

    try glyph_list.append(allocator, 0); // .notdef always first

    // Use a set to avoid duplicates
    var glyph_set = std.AutoHashMapUnmanaged(u16, void){};
    defer glyph_set.deinit(allocator);

    var cid_iter = emb.cid_used_glyphs.iterator();
    while (cid_iter.next()) |entry| {
        const gid = entry.value_ptr.*;
        if (gid != 0) {
            try glyph_set.put(allocator, gid, {});
        }
    }

    // Add ligature glyph IDs
    var lig_iter = emb.ligature_codepoints.iterator();
    while (lig_iter.next()) |entry| {
        const lig_gid = entry.key_ptr.*;
        if (lig_gid != 0) {
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

    const num_glyphs: u16 = @intCast(glyph_list.items.len);

    // Parse CFF structure
    const hdr_size = cff_data[2];
    const name_end = skipCFFIndex(cff_data, hdr_size);
    const topdict_start = name_end;
    const topdict_end = skipCFFIndex(cff_data, topdict_start);
    const string_start = topdict_end;
    const string_end = skipCFFIndex(cff_data, string_start);
    const gsubr_start = string_end;

    // Parse Global Subrs INDEX
    const global_subrs = parseCFFIndex(cff_data, gsubr_start);

    // Parse CharStrings INDEX location
    const charstrings_offset = parseCFFTopDictForCharStrings(cff_data, topdict_start) orelse
        return error.InvalidCFF;

    const cs_count = readU16(cff_data, charstrings_offset);
    if (cs_count == 0) return error.InvalidCFF;

    const cs_off_size = cff_data[charstrings_offset + 2];
    const cs_offsets_start = charstrings_offset + 3;
    const cs_data_start = cs_offsets_start + (@as(usize, cs_count) + 1) * cs_off_size;

    // Get Private DICT info to find Local Subrs
    const private_info = parseCFFTopDictForPrivate(cff_data, topdict_start);
    var local_subrs: ?CFFIndex = null;
    if (private_info.size > 0 and private_info.offset + private_info.size <= cff_data.len) {
        const private_dict_data = cff_data[private_info.offset..][0..private_info.size];
        if (parseCFFDictForOperator(private_dict_data, 19)) |rel_off| {
            const local_subrs_offset = private_info.offset + rel_off;
            local_subrs = parseCFFIndex(cff_data, local_subrs_offset);
        }
    }

    // Build compact CharStrings INDEX with desubroutinized glyphs
    var cs_data_buf = std.ArrayListUnmanaged(u8){};
    defer cs_data_buf.deinit(allocator);

    var cs_offsets = std.ArrayListUnmanaged(u32){};
    defer cs_offsets.deinit(allocator);

    // Track desubroutinized charstrings for later cleanup
    var desubr_charstrings = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (desubr_charstrings.items) |cs| allocator.free(cs);
        desubr_charstrings.deinit(allocator);
    }

    try cs_offsets.append(allocator, 1); // First offset is always 1

    const use_desubroutinization = true; // Set to true to enable desubroutinization
    for (glyph_list.items) |orig_gid| {
        if (orig_gid < cs_count) {
            const orig_start = readCFFOffset(cff_data, cs_offsets_start, orig_gid, cs_off_size);
            const orig_end = readCFFOffset(cff_data, cs_offsets_start, orig_gid + 1, cs_off_size);
            if (orig_end > orig_start) {
                const orig_charstring = cff_data[cs_data_start + orig_start - 1 .. cs_data_start + orig_end - 1];
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
        }
        try cs_offsets.append(allocator, @intCast(cs_data_buf.items.len + 1));
    }

    // Determine offset size for compact CharStrings
    const new_cs_off_size: u8 = if (cs_data_buf.items.len < 256) 1 else if (cs_data_buf.items.len < 65536) 2 else 3;

    // Build CharStrings INDEX
    var new_charstrings = std.ArrayListUnmanaged(u8){};
    defer new_charstrings.deinit(allocator);

    try new_charstrings.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, num_glyphs)));
    try new_charstrings.append(allocator, new_cs_off_size);

    for (cs_offsets.items) |off| {
        if (new_cs_off_size == 1) {
            try new_charstrings.append(allocator, @intCast(off));
        } else if (new_cs_off_size == 2) {
            try new_charstrings.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(off))));
        } else {
            const off_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, off));
            try new_charstrings.appendSlice(allocator, off_bytes[1..4]);
        }
    }
    try new_charstrings.appendSlice(allocator, cs_data_buf.items);

    // Build format 0 charset preserving original SIDs for each glyph
    // This is required for macOS/CoreGraphics which uses SIDs for glyph lookup
    var new_charset = std.ArrayListUnmanaged(u8){};
    defer new_charset.deinit(allocator);

    // Get original charset offset
    const orig_charset_offset = parseCFFDictForOperator(
        cff_data[topdict_start + 3 + 2 * cff_data[topdict_start + 2] ..][0 .. readCFFOffset(cff_data, topdict_start + 3, 1, cff_data[topdict_start + 2]) - 1],
        15,
    ) orelse return error.InvalidCFF;

    // Collect all SIDs used in the new charset
    var charset_sids = std.ArrayListUnmanaged(u16){};
    defer charset_sids.deinit(allocator);
    try charset_sids.append(allocator, 0); // .notdef always has SID 0
    for (glyph_list.items[1..]) |orig_gid| {
        const sid = getCharsetSID(cff_data, orig_charset_offset, orig_gid) orelse 1;
        try charset_sids.append(allocator, sid);
    }

    // Collect SIDs used in Top DICT
    var topdict_sids = try collectTopDictSIDs(allocator, cff_data, topdict_start);
    defer topdict_sids.deinit(allocator);

    // Combine all used SIDs
    var all_used_sids = std.ArrayListUnmanaged(u16){};
    defer all_used_sids.deinit(allocator);
    try all_used_sids.appendSlice(allocator, charset_sids.items);
    try all_used_sids.appendSlice(allocator, topdict_sids.items);

    // Build subset String INDEX with SID remapping
    const string_subset = try buildSubsetStringIndex(allocator, cff_data, string_start, all_used_sids.items);
    defer allocator.free(string_subset.data);
    var sid_remap = string_subset.remap;
    defer sid_remap.deinit(allocator);

    // String INDEX subsetting removes unused strings and remaps SIDs in Top DICT.
    // Charset SIDs are preserved (standard SIDs < 391 don't need remapping).
    const use_string_subsetting = true;
    const string_index_data = if (use_string_subsetting) string_subset.data else cff_data[string_start..string_end];

    // Build format 0 charset with remapped SIDs
    // Standard SIDs (< 391) don't need remapping, but custom strings do
    try new_charset.append(allocator, 0); // Format 0
    for (charset_sids.items[1..]) |orig_sid| {
        const final_sid = if (use_string_subsetting and orig_sid >= 391)
            sid_remap.get(orig_sid) orelse orig_sid
        else
            orig_sid;
        try new_charset.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, final_sid)));
    }

    // Private DICT handling
    const orig_private_size = private_info.size;
    const orig_private_offset = private_info.offset;

    var new_private = std.ArrayListUnmanaged(u8){};
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
    const name_index_data = cff_data[hdr_size..name_end];

    // Global Subrs INDEX - empty if desubroutinizing, keep original otherwise
    const gsubr_end = skipCFFIndex(cff_data, gsubr_start);
    const orig_gsubr_index_data = cff_data[gsubr_start..gsubr_end];
    const empty_gsubr_index = [_]u8{ 0, 0 };

    // Calculate final offsets (we need to do this twice due to Top DICT size changes)
    var final_offset: usize = hdr_size + name_index_data.len;

    // Estimate Top DICT INDEX size for first pass
    var new_topdict = std.ArrayListUnmanaged(u8){};
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
        try buildUpdatedTopDictWithSIDRemap(allocator, cff_data, topdict_start, &new_topdict, .{
            .charset = @intCast(est_charset_offset),
            .charstrings = @intCast(est_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(est_private_offset),
        }, &sid_remap);
    } else {
        try buildUpdatedTopDict(allocator, cff_data, topdict_start, &new_topdict, .{
            .charset = @intCast(est_charset_offset),
            .charstrings = @intCast(est_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(est_private_offset),
        });
    }

    // Build Top DICT INDEX
    var new_topdict_index = std.ArrayListUnmanaged(u8){};
    defer new_topdict_index.deinit(allocator);

    try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
    const td_off_size: u8 = if (new_topdict.items.len < 256) 1 else 2;
    try new_topdict_index.append(allocator, td_off_size);
    if (td_off_size == 1) {
        try new_topdict_index.append(allocator, 1);
        try new_topdict_index.append(allocator, @intCast(new_topdict.items.len + 1));
    } else {
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(new_topdict.items.len + 1))));
    }
    try new_topdict_index.appendSlice(allocator, new_topdict.items);

    // Recalculate with actual Top DICT INDEX size
    final_offset = hdr_size + name_index_data.len + new_topdict_index.items.len;
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
        try buildUpdatedTopDictWithSIDRemap(allocator, cff_data, topdict_start, &new_topdict, .{
            .charset = @intCast(final_charset_offset),
            .charstrings = @intCast(final_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(final_private_offset),
        }, &sid_remap);
    } else {
        try buildUpdatedTopDict(allocator, cff_data, topdict_start, &new_topdict, .{
            .charset = @intCast(final_charset_offset),
            .charstrings = @intCast(final_charstrings_offset),
            .private_size = total_private_size,
            .private_offset = @intCast(final_private_offset),
        });
    }

    // Rebuild Top DICT INDEX
    new_topdict_index.clearRetainingCapacity();
    try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
    const td_off_size2: u8 = if (new_topdict.items.len < 256) 1 else 2;
    try new_topdict_index.append(allocator, td_off_size2);
    if (td_off_size2 == 1) {
        try new_topdict_index.append(allocator, 1);
        try new_topdict_index.append(allocator, @intCast(new_topdict.items.len + 1));
    } else {
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1)));
        try new_topdict_index.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(new_topdict.items.len + 1))));
    }
    try new_topdict_index.appendSlice(allocator, new_topdict.items);

    // Assemble final CFF
    const gsubr_len = if (use_desubroutinization) empty_gsubr_index.len else orig_gsubr_index_data.len;
    const total_size = hdr_size + name_index_data.len + new_topdict_index.items.len +
        string_index_data.len + gsubr_len +
        new_charset.items.len + new_charstrings.items.len + total_private_size;

    var output = try allocator.alloc(u8, total_size);
    @memset(output, 0);

    var pos: usize = 0;

    // Header
    @memcpy(output[0..hdr_size], cff_data[0..hdr_size]);
    pos = hdr_size;

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
    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    // Switch to identity encoding for CID mode
    emb.encoding = .identity;

    // Mark some Unicode characters
    try emb.markUnicodeCharsUsed("Hello");

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

    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("AB");

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
    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("Test");

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
    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("Hello");

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

    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    // Get original CFF size
    const orig_cff = emb.font.getTable("CFF ".*);
    try std.testing.expect(orig_cff != null);
    const orig_size = orig_cff.?.len;

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("ABC");

    try emb.generateSubset();

    const subset = emb.getFontData();

    // Subset should be much smaller than original CFF
    try std.testing.expect(subset.len < orig_size / 5);
}

test "CFF glyph ID remapping works" {
    const allocator = std.testing.allocator;

    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("XY");

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

    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer emb.deinit();

    emb.encoding = .identity;

    // Mark various characters
    try emb.markUnicodeCharsUsed("Hello World! 123");

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

    var emb = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.otf");
    defer emb.deinit();

    emb.encoding = .identity;
    try emb.markUnicodeCharsUsed("Test 456");

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
    var ttf_font = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Regular.ttf");
    defer ttf_font.deinit();

    var otf_font = try EmbeddedFont.fromFile(allocator, "test/fonts/Inter/Inter-Bold.otf");
    defer otf_font.deinit();

    ttf_font.encoding = .identity;
    otf_font.encoding = .identity;

    try ttf_font.markUnicodeCharsUsed("Regular");
    try otf_font.markUnicodeCharsUsed("Bold");

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
    const font = try EmbeddedFont.fromFile(std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
    defer font.deinit();

    // Features should not be initialized yet (lazy)
    try std.testing.expect(font.ot_features == null);

    // Default flags
    try std.testing.expect(font.feature_flags.liga);
    try std.testing.expect(font.feature_flags.kern);

    // Initialize features
    try font.initOpenTypeFeatures();
    try std.testing.expect(font.ot_features != null);

    // Charter has GPOS but no GSUB
    try std.testing.expectEqual(@as(usize, 0), font.ot_features.?.liga_lookups.items.len);
    try std.testing.expect(font.ot_features.?.kern_lookups.items.len > 0);
}

test "OpenType kerning applied in text rendering" {
    const font = try EmbeddedFont.fromFile(std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
    defer font.deinit();
    font.encoding = .identity;

    // Text with common kerning pairs
    try font.markUnicodeCharsUsed("AVATAR");

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
    const font = try EmbeddedFont.fromFile(std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf");
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
    const font = try EmbeddedFont.fromFile(std.testing.allocator, "test/fonts/Satoshi/Satoshi-Regular.otf");
    defer font.deinit();
    font.encoding = .identity;

    // Mark text with ligatures
    try font.markUnicodeCharsUsed("fi fl ft");

    // Check ligature codepoints were tracked
    std.debug.print("\nLigature codepoints tracked: {d}\n", .{font.ligature_codepoints.count()});

    var iter = font.ligature_codepoints.iterator();
    while (iter.next()) |entry| {
        const lig_gid = entry.key_ptr.*;
        const codepoints = entry.value_ptr.*;
        std.debug.print("  Ligature glyph {d} -> codepoints: ", .{lig_gid});
        for (codepoints) |cp| {
            std.debug.print("{c}({d}) ", .{ @as(u8, @intCast(cp)), cp });
        }
        std.debug.print("\n", .{});
    }

    // Should have tracked fi, fl, ft ligatures (3 different glyph IDs)
    try std.testing.expect(font.ligature_codepoints.count() >= 3);

    // Check that each ligature has 2 codepoints
    iter = font.ligature_codepoints.iterator();
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.value_ptr.*.len);
    }
}
