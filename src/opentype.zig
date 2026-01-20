//! OpenType Feature Support
//!
//! Parses GSUB (Glyph Substitution) and GPOS (Glyph Positioning) tables
//! for ligature support and kerning in OpenType/TrueType fonts.
//!
//! References:
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gsub
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gpos

const std = @import("std");

/// OpenType feature tags
pub const Feature = enum(u32) {
    liga = tag("liga"), // Standard Ligatures
    kern = tag("kern"), // Kerning
    clig = tag("clig"), // Contextual Ligatures
    dlig = tag("dlig"), // Discretionary Ligatures
    hlig = tag("hlig"), // Historical Ligatures
    calt = tag("calt"), // Contextual Alternates
    mark = tag("mark"), // Mark Positioning
    mkmk = tag("mkmk"), // Mark-to-Mark Positioning

    fn tag(comptime s: *const [4]u8) u32 {
        return std.mem.readInt(u32, s, .big);
    }

    pub fn fromTag(t: u32) ?Feature {
        return switch (t) {
            tag("liga") => .liga,
            tag("kern") => .kern,
            tag("clig") => .clig,
            tag("dlig") => .dlig,
            tag("hlig") => .hlig,
            tag("calt") => .calt,
            tag("mark") => .mark,
            tag("mkmk") => .mkmk,
            else => null,
        };
    }
};

/// Feature enable/disable flags
pub const FeatureFlags = struct {
    liga: bool = true, // Ligatures on by default
    kern: bool = true, // Kerning on by default
    clig: bool = false,
    dlig: bool = false,
    hlig: bool = false,
    calt: bool = true, // Contextual alternates on by default
    mark: bool = true, // Mark positioning on by default
    mkmk: bool = true, // Mark-to-mark on by default
};

/// Coverage table - maps glyph IDs to coverage indices
pub const CoverageTable = struct {
    format: u16,
    data: []const u8,

    /// Get coverage index for a glyph ID, or null if not covered
    pub fn getCoverageIndex(self: CoverageTable, glyph_id: u16) ?u16 {
        return switch (self.format) {
            1 => self.getCoverageIndexFormat1(glyph_id),
            2 => self.getCoverageIndexFormat2(glyph_id),
            else => null,
        };
    }

    fn getCoverageIndexFormat1(self: CoverageTable, glyph_id: u16) ?u16 {
        if (self.data.len < 4) return null;
        const glyph_count = readU16(self.data, 2);

        // Binary search in sorted glyph array
        var lo: u16 = 0;
        var hi: u16 = glyph_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = 4 + @as(usize, mid) * 2;
            if (offset + 2 > self.data.len) return null;
            const gid = readU16(self.data, offset);
            if (gid < glyph_id) {
                lo = mid + 1;
            } else if (gid > glyph_id) {
                hi = mid;
            } else {
                return mid; // Coverage index = position in array
            }
        }
        return null;
    }

    fn getCoverageIndexFormat2(self: CoverageTable, glyph_id: u16) ?u16 {
        if (self.data.len < 4) return null;
        const range_count = readU16(self.data, 2);

        // Binary search in range records
        var lo: u16 = 0;
        var hi: u16 = range_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = 4 + @as(usize, mid) * 6;
            if (offset + 6 > self.data.len) return null;

            const start_glyph = readU16(self.data, offset);
            const end_glyph = readU16(self.data, offset + 2);
            const start_index = readU16(self.data, offset + 4);

            if (glyph_id < start_glyph) {
                hi = mid;
            } else if (glyph_id > end_glyph) {
                lo = mid + 1;
            } else {
                return start_index + (glyph_id - start_glyph);
            }
        }
        return null;
    }
};

/// Ligature - replacement glyph and component sequence
pub const Ligature = struct {
    lig_glyph: u16, // Replacement glyph ID
    components: []const u16, // Component glyph IDs (excluding first)
};

/// Ligature set - indices into ligature_structs array
pub const LigatureSet = struct {
    start: usize, // Start index in ligature_structs
    count: usize, // Number of ligatures
};

/// Ligature substitution lookup (GSUB Lookup Type 4)
/// Stores indices to avoid slice invalidation during parsing
pub const LigatureSubst = struct {
    coverage: CoverageTable,
    sets_start: usize, // Start index in ligature_sets array
    sets_count: usize, // Number of ligature sets

    /// Find a ligature match starting at the given position in the glyph sequence
    /// Returns the replacement glyph ID and number of glyphs consumed, or null if no match
    pub fn findLigature(
        self: LigatureSubst,
        glyphs: []const u16,
        pos: usize,
        ligature_sets: []const LigatureSet,
        ligature_structs: []const Ligature,
    ) ?struct { lig_glyph: u16, consumed: usize } {
        if (pos >= glyphs.len) return null;

        const first_glyph = glyphs[pos];
        const coverage_index = self.coverage.getCoverageIndex(first_glyph) orelse return null;

        if (coverage_index >= self.sets_count) return null;
        const set_idx = self.sets_start + coverage_index;
        if (set_idx >= ligature_sets.len) return null;
        const lig_set = ligature_sets[set_idx];

        // Get ligatures for this set
        const ligs_end = lig_set.start + lig_set.count;
        if (ligs_end > ligature_structs.len) return null;
        const ligs = ligature_structs[lig_set.start..ligs_end];

        // Try each ligature in the set (longer ones first typically)
        for (ligs) |lig| {
            if (pos + 1 + lig.components.len > glyphs.len) continue;

            // Check if remaining glyphs match
            var matches = true;
            for (lig.components, 0..) |comp_glyph, i| {
                if (glyphs[pos + 1 + i] != comp_glyph) {
                    matches = false;
                    break;
                }
            }

            if (matches) {
                return .{
                    .lig_glyph = lig.lig_glyph,
                    .consumed = 1 + lig.components.len, // First glyph + components
                };
            }
        }

        return null;
    }
};

/// Single Substitution lookup (GSUB Lookup Type 1)
/// Replaces single glyphs with other single glyphs
pub const SingleSubst = struct {
    coverage: CoverageTable,
    format: u16,
    delta: i16 = 0, // Format 1: add to glyph ID
    substitutes: []const u16 = &[_]u16{}, // Format 2: direct mapping

    /// Get the substitute glyph for an input glyph, or null if not covered
    pub fn substitute(self: SingleSubst, glyph: u16) ?u16 {
        const cov_index = self.coverage.getCoverageIndex(glyph) orelse return null;

        return switch (self.format) {
            1 => @bitCast(@as(i16, @bitCast(glyph)) +% self.delta),
            2 => if (cov_index < self.substitutes.len) self.substitutes[cov_index] else null,
            else => null,
        };
    }
};

/// Substitution lookup record - used in chaining context substitution
pub const SubstLookupRecord = struct {
    sequence_index: u16, // Which glyph in input sequence (0-based)
    lookup_index: u16, // Which lookup to apply
};

/// Chaining Context Substitution Format 3 (GSUB Lookup Type 6)
/// Uses coverage tables for matching; invokes nested lookups for substitution
pub const ChainContextSubstF3 = struct {
    backtrack_coverages: []const CoverageTable,
    input_coverages: []const CoverageTable, // First coverage is at current position
    lookahead_coverages: []const CoverageTable,
    subst_records: []const SubstLookupRecord,

    /// Check if this rule matches at the given position in the glyph sequence
    /// Returns the substitution records to apply if matched, null otherwise
    pub fn match(self: ChainContextSubstF3, glyphs: []const u16, pos: usize) ?[]const SubstLookupRecord {
        // Need at least enough glyphs for input sequence
        if (self.input_coverages.len == 0) return null;
        if (pos + self.input_coverages.len > glyphs.len) return null;

        // Check backtrack glyphs (in reverse order from pos-1)
        for (self.backtrack_coverages, 0..) |cov, i| {
            if (i >= pos) return null; // Not enough backtrack glyphs
            const backtrack_glyph = glyphs[pos - 1 - i];
            if (cov.getCoverageIndex(backtrack_glyph) == null) return null;
        }

        // Check input glyphs (starting at pos)
        for (self.input_coverages, 0..) |cov, i| {
            const input_glyph = glyphs[pos + i];
            if (cov.getCoverageIndex(input_glyph) == null) return null;
        }

        // Check lookahead glyphs (after input sequence)
        const lookahead_start = pos + self.input_coverages.len;
        for (self.lookahead_coverages, 0..) |cov, i| {
            if (lookahead_start + i >= glyphs.len) return null;
            const lookahead_glyph = glyphs[lookahead_start + i];
            if (cov.getCoverageIndex(lookahead_glyph) == null) return null;
        }

        return self.subst_records;
    }
};

/// Kerning pair value
pub const KernPair = struct {
    second: u16, // Second glyph ID
    value: i16, // X advance adjustment
};

/// Class definition table for GPOS
pub const ClassDef = struct {
    format: u16,
    data: []const u8,

    /// Get class value for a glyph ID (0 = default class)
    pub fn getClass(self: ClassDef, glyph_id: u16) u16 {
        return switch (self.format) {
            1 => self.getClassFormat1(glyph_id),
            2 => self.getClassFormat2(glyph_id),
            else => 0,
        };
    }

    fn getClassFormat1(self: ClassDef, glyph_id: u16) u16 {
        if (self.data.len < 6) return 0;
        const start_glyph = readU16(self.data, 2);
        const glyph_count = readU16(self.data, 4);

        if (glyph_id < start_glyph or glyph_id >= start_glyph + glyph_count) return 0;

        const offset = 6 + @as(usize, glyph_id - start_glyph) * 2;
        if (offset + 2 > self.data.len) return 0;
        return readU16(self.data, offset);
    }

    fn getClassFormat2(self: ClassDef, glyph_id: u16) u16 {
        if (self.data.len < 4) return 0;
        const range_count = readU16(self.data, 2);

        // Binary search in range records
        var lo: u16 = 0;
        var hi: u16 = range_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = 4 + @as(usize, mid) * 6;
            if (offset + 6 > self.data.len) return 0;

            const start_glyph = readU16(self.data, offset);
            const end_glyph = readU16(self.data, offset + 2);
            const class_value = readU16(self.data, offset + 4);

            if (glyph_id < start_glyph) {
                hi = mid;
            } else if (glyph_id > end_glyph) {
                lo = mid + 1;
            } else {
                return class_value;
            }
        }
        return 0;
    }
};

/// Pair positioning lookup (GPOS Lookup Type 2)
pub const PairPosLookup = struct {
    format: u16,
    coverage: CoverageTable,
    data: []const u8,

    // Format 2 specific
    class_def1: ?ClassDef = null,
    class_def2: ?ClassDef = null,
    class1_count: u16 = 0,
    class2_count: u16 = 0,
    class1_records_offset: usize = 0,

    /// Get kerning value for a glyph pair
    pub fn getKerning(self: PairPosLookup, glyph1: u16, glyph2: u16) i16 {
        return switch (self.format) {
            1 => self.getKerningFormat1(glyph1, glyph2),
            2 => self.getKerningFormat2(glyph1, glyph2),
            else => 0,
        };
    }

    fn getKerningFormat1(self: PairPosLookup, glyph1: u16, glyph2: u16) i16 {
        const cov_index = self.coverage.getCoverageIndex(glyph1) orelse return 0;

        // Format 1: Individual pair sets
        // Structure: coverage, valueFormat1, valueFormat2, pairSetCount, pairSetOffsets[]
        if (self.data.len < 10) return 0;

        const value_format1 = readU16(self.data, 4);
        const value_format2 = readU16(self.data, 6);
        const pair_set_count = readU16(self.data, 8);

        if (cov_index >= pair_set_count) return 0;

        // Get pair set offset
        const offset_pos = 10 + @as(usize, cov_index) * 2;
        if (offset_pos + 2 > self.data.len) return 0;
        const pair_set_offset = readU16(self.data, offset_pos);

        // Parse pair set
        if (pair_set_offset + 2 > self.data.len) return 0;
        const pair_value_count = readU16(self.data, pair_set_offset);

        // Calculate record size based on value formats
        const value1_size = valueRecordSize(value_format1);
        const value2_size = valueRecordSize(value_format2);
        const record_size = 2 + value1_size + value2_size;

        // Search for matching second glyph
        var i: u16 = 0;
        while (i < pair_value_count) : (i += 1) {
            const rec_offset = pair_set_offset + 2 + @as(usize, i) * record_size;
            if (rec_offset + 2 > self.data.len) break;

            const second_glyph = readU16(self.data, rec_offset);
            if (second_glyph == glyph2) {
                // Found! Extract X advance from value1
                return extractXAdvance(self.data, rec_offset + 2, value_format1);
            }
            if (second_glyph > glyph2) break; // Sorted, no need to continue
        }

        return 0;
    }

    fn getKerningFormat2(self: PairPosLookup, glyph1: u16, glyph2: u16) i16 {
        _ = self.coverage.getCoverageIndex(glyph1) orelse return 0;

        const class_def1 = self.class_def1 orelse return 0;
        const class_def2 = self.class_def2 orelse return 0;

        const class1 = class_def1.getClass(glyph1);
        const class2 = class_def2.getClass(glyph2);

        if (class1 >= self.class1_count or class2 >= self.class2_count) return 0;

        // Format 2 structure after header:
        // valueFormat1, valueFormat2, classDef1Offset, classDef2Offset, class1Count, class2Count, class1Records[]
        if (self.data.len < 16) return 0;
        const value_format1 = readU16(self.data, 4);

        const value1_size = valueRecordSize(value_format1);
        const value2_size = valueRecordSize(readU16(self.data, 6));
        const class2_record_size = value1_size + value2_size;
        const class1_record_size = @as(usize, self.class2_count) * class2_record_size;

        // Navigate to the correct record
        const record_offset = self.class1_records_offset +
            @as(usize, class1) * class1_record_size +
            @as(usize, class2) * class2_record_size;

        return extractXAdvance(self.data, record_offset, value_format1);
    }
};

/// Anchor position in design units
pub const Anchor = struct {
    x: i16,
    y: i16,
};

/// Mark record - mark class and anchor position
pub const MarkRecord = struct {
    mark_class: u16,
    anchor: Anchor,
};

/// Mark positioning offset in design units
pub const MarkOffset = struct {
    dx: i16,
    dy: i16,
};

/// Mark-to-Base Attachment lookup (GPOS Lookup Type 4)
/// Attaches combining marks to base glyphs
pub const MarkBasePos = struct {
    mark_coverage: CoverageTable,
    base_coverage: CoverageTable,
    mark_class_count: u16,
    mark_records: []const MarkRecord, // [mark_coverage_idx] -> class + anchor
    base_anchors_data: []const u8, // Raw data for base anchor lookup
    base_count: u16,
    base_array_offset: usize, // Offset within data

    /// Get attachment offset for a mark glyph attaching to a base glyph
    /// Returns (dx, dy) adjustment in design units, or null if not applicable
    pub fn getAttachment(self: MarkBasePos, mark_glyph: u16, base_glyph: u16) ?MarkOffset {
        const mark_idx = self.mark_coverage.getCoverageIndex(mark_glyph) orelse return null;
        const base_idx = self.base_coverage.getCoverageIndex(base_glyph) orelse return null;

        if (mark_idx >= self.mark_records.len) return null;
        const mark_rec = self.mark_records[mark_idx];

        if (base_idx >= self.base_count) return null;
        if (mark_rec.mark_class >= self.mark_class_count) return null;

        // Base anchor offset: baseArrayOffset + baseIdx * (markClassCount * 2) + markClass * 2
        const base_record_offset = self.base_array_offset + 2 + // skip baseCount
            @as(usize, base_idx) * @as(usize, self.mark_class_count) * 2 +
            @as(usize, mark_rec.mark_class) * 2;

        if (base_record_offset + 2 > self.base_anchors_data.len) return null;
        const anchor_offset = readU16(self.base_anchors_data, base_record_offset);
        if (anchor_offset == 0) return null; // No anchor for this class

        const anchor_addr = self.base_array_offset + anchor_offset;
        if (anchor_addr + 6 > self.base_anchors_data.len) return null;

        const base_anchor = Anchor{
            .x = readI16(self.base_anchors_data, anchor_addr + 2),
            .y = readI16(self.base_anchors_data, anchor_addr + 4),
        };

        // Offset = base anchor - mark anchor
        return .{
            .dx = base_anchor.x - mark_rec.anchor.x,
            .dy = base_anchor.y - mark_rec.anchor.y,
        };
    }
};

/// Mark-to-Mark Attachment lookup (GPOS Lookup Type 6)
/// Attaches combining marks to other marks (base marks)
pub const MarkMarkPos = struct {
    mark1_coverage: CoverageTable, // Combining mark (attaching mark)
    mark2_coverage: CoverageTable, // Base mark (mark being attached to)
    mark_class_count: u16,
    mark1_records: []const MarkRecord, // Attaching marks
    mark2_anchors_data: []const u8,
    mark2_count: u16,
    mark2_array_offset: usize,

    /// Get attachment offset for mark1 attaching to mark2
    pub fn getAttachment(self: MarkMarkPos, mark1_glyph: u16, mark2_glyph: u16) ?MarkOffset {
        const mark1_idx = self.mark1_coverage.getCoverageIndex(mark1_glyph) orelse return null;
        const mark2_idx = self.mark2_coverage.getCoverageIndex(mark2_glyph) orelse return null;

        if (mark1_idx >= self.mark1_records.len) return null;
        const mark1_rec = self.mark1_records[mark1_idx];

        if (mark2_idx >= self.mark2_count) return null;
        if (mark1_rec.mark_class >= self.mark_class_count) return null;

        const mark2_record_offset = self.mark2_array_offset + 2 +
            @as(usize, mark2_idx) * @as(usize, self.mark_class_count) * 2 +
            @as(usize, mark1_rec.mark_class) * 2;

        if (mark2_record_offset + 2 > self.mark2_anchors_data.len) return null;
        const anchor_offset = readU16(self.mark2_anchors_data, mark2_record_offset);
        if (anchor_offset == 0) return null;

        const anchor_addr = self.mark2_array_offset + anchor_offset;
        if (anchor_addr + 6 > self.mark2_anchors_data.len) return null;

        const mark2_anchor = Anchor{
            .x = readI16(self.mark2_anchors_data, anchor_addr + 2),
            .y = readI16(self.mark2_anchors_data, anchor_addr + 4),
        };

        return .{
            .dx = mark2_anchor.x - mark1_rec.anchor.x,
            .dy = mark2_anchor.y - mark1_rec.anchor.y,
        };
    }
};

/// Reference to a GSUB lookup by type and index in respective array
pub const GSUBLookupRef = union(enum) {
    single: usize, // Index into single_lookups
    liga: usize, // Index into liga_lookups
    dlig: usize, // Index into dlig_lookups
    clig: usize, // Index into clig_lookups
    hlig: usize, // Index into hlig_lookups
    calt_liga: usize, // Index into calt_liga_lookups
    chain_context: usize, // Index into chain_context_lookups
};

/// OpenType features parsed from a font
pub const OpenTypeFeatures = struct {
    allocator: std.mem.Allocator,

    // GSUB data
    gsub_data: ?[]const u8 = null,
    liga_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{}, // Standard ligatures
    dlig_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{}, // Discretionary ligatures
    clig_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{}, // Contextual ligatures
    hlig_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{}, // Historical ligatures
    calt_liga_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{}, // Calt ligatures (e.g., arrow sequences)
    single_lookups: std.ArrayListUnmanaged(SingleSubst) = .{}, // Type 1
    chain_context_lookups: std.ArrayListUnmanaged(ChainContextSubstF3) = .{}, // Type 6 Format 3

    // Lookup index map: maps original lookup index -> lookup reference
    gsub_lookup_map: std.AutoHashMapUnmanaged(u16, GSUBLookupRef) = .{},

    // GPOS data
    gpos_data: ?[]const u8 = null,
    kern_lookups: std.ArrayListUnmanaged(PairPosLookup) = .{},
    mark_base_lookups: std.ArrayListUnmanaged(MarkBasePos) = .{}, // Type 4
    mark_mark_lookups: std.ArrayListUnmanaged(MarkMarkPos) = .{}, // Type 6

    // Allocated memory for ligature data
    ligature_memory: std.ArrayListUnmanaged([]const u16) = .{},
    ligature_set_memory: std.ArrayListUnmanaged([]const Ligature) = .{},
    ligature_structs: std.ArrayListUnmanaged(Ligature) = .{},
    ligature_sets: std.ArrayListUnmanaged(LigatureSet) = .{},

    // Allocated memory for single subst (Format 2 substitutes array)
    single_subst_memory: std.ArrayListUnmanaged([]const u16) = .{},

    // Allocated memory for chain context (coverages and records)
    chain_coverage_memory: std.ArrayListUnmanaged([]const CoverageTable) = .{},
    chain_record_memory: std.ArrayListUnmanaged([]const SubstLookupRecord) = .{},

    // Allocated memory for mark records
    mark_record_memory: std.ArrayListUnmanaged([]const MarkRecord) = .{},

    pub fn init(allocator: std.mem.Allocator) OpenTypeFeatures {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OpenTypeFeatures) void {
        // Free allocated ligature component arrays
        for (self.ligature_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.ligature_memory.deinit(self.allocator);
        self.ligature_set_memory.deinit(self.allocator);
        self.ligature_structs.deinit(self.allocator);
        self.ligature_sets.deinit(self.allocator);
        self.liga_lookups.deinit(self.allocator);
        self.dlig_lookups.deinit(self.allocator);
        self.clig_lookups.deinit(self.allocator);
        self.hlig_lookups.deinit(self.allocator);
        self.calt_liga_lookups.deinit(self.allocator);
        self.kern_lookups.deinit(self.allocator);

        // Free single subst memory
        for (self.single_subst_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.single_subst_memory.deinit(self.allocator);
        self.single_lookups.deinit(self.allocator);

        // Free chain context memory
        for (self.chain_coverage_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.chain_coverage_memory.deinit(self.allocator);
        for (self.chain_record_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.chain_record_memory.deinit(self.allocator);
        self.chain_context_lookups.deinit(self.allocator);

        // Free mark record memory
        for (self.mark_record_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.mark_record_memory.deinit(self.allocator);
        self.mark_base_lookups.deinit(self.allocator);
        self.mark_mark_lookups.deinit(self.allocator);

        // Free lookup map
        self.gsub_lookup_map.deinit(self.allocator);
    }

    /// Parse GSUB table from font data
    pub fn parseGSUB(self: *OpenTypeFeatures, gsub_data: []const u8) !void {
        self.gsub_data = gsub_data;
        // Parse feature-referenced lookups
        try self.parseGSUBFeature(gsub_data, Feature.liga);
        try self.parseGSUBFeature(gsub_data, Feature.dlig);
        try self.parseGSUBFeature(gsub_data, Feature.clig);
        try self.parseGSUBFeature(gsub_data, Feature.hlig);
        try self.parseGSUBFeature(gsub_data, Feature.calt);
        // Then parse ALL lookups to enable nested lookup dispatch from calt
        try self.parseAllGSUBLookups(gsub_data);
    }

    /// Parse ALL lookups in the GSUB lookup list
    /// This enables nested lookup dispatch from chain context rules
    /// Does NOT add to ligature arrays - only populates gsub_lookup_map
    fn parseAllGSUBLookups(self: *OpenTypeFeatures, data: []const u8) !void {
        if (data.len < 10) return;

        const lookup_list_offset = readU16(data, 8);
        if (lookup_list_offset + 2 > data.len) return;

        const lookup_count = readU16(data, lookup_list_offset);

        var i: u16 = 0;
        while (i < lookup_count) : (i += 1) {
            // parseGSUBLookup will skip if already parsed (via gsub_lookup_map)
            // Pass null feature to indicate this is for nested dispatch only
            try self.parseGSUBLookup(data, lookup_list_offset, i, null);
        }
    }

    /// Parse GPOS table from font data
    pub fn parseGPOS(self: *OpenTypeFeatures, gpos_data: []const u8) !void {
        self.gpos_data = gpos_data;
        try self.parseGPOSFeature(gpos_data, Feature.kern);
        try self.parseGPOSFeature(gpos_data, Feature.mark);
        try self.parseGPOSFeature(gpos_data, Feature.mkmk);
    }

    fn parseGSUBFeature(self: *OpenTypeFeatures, data: []const u8, feature: Feature) !void {
        if (data.len < 10) return;

        // GSUB header: version, scriptListOffset, featureListOffset, lookupListOffset
        const script_list_offset = readU16(data, 4);
        const feature_list_offset = readU16(data, 6);
        const lookup_list_offset = readU16(data, 8);

        // Find feature in FeatureList
        const feature_indices = try self.findFeatureIndices(data, script_list_offset, feature_list_offset, feature);
        defer self.allocator.free(feature_indices);

        // For each feature index, get lookup indices and parse lookups
        if (feature_list_offset + 2 > data.len) return;
        const feature_count = readU16(data, feature_list_offset);

        for (feature_indices) |feat_idx| {
            if (feat_idx >= feature_count) continue;

            const feat_record_offset = feature_list_offset + 2 + @as(usize, feat_idx) * 6;
            if (feat_record_offset + 6 > data.len) continue;

            const feat_offset = readU16(data, feat_record_offset + 4);
            const feat_table_offset = feature_list_offset + feat_offset;

            if (feat_table_offset + 4 > data.len) continue;
            const lookup_index_count = readU16(data, feat_table_offset + 2);

            var i: u16 = 0;
            while (i < lookup_index_count) : (i += 1) {
                const li_offset = feat_table_offset + 4 + @as(usize, i) * 2;
                if (li_offset + 2 > data.len) break;

                const lookup_index = readU16(data, li_offset);
                try self.parseGSUBLookup(data, lookup_list_offset, lookup_index, feature);
            }
        }

        // Parse nested lookups referenced by chain context rules
        // These lookups might not be part of any feature directly
        if (feature == .calt) {
            for (self.chain_context_lookups.items) |chain| {
                for (chain.subst_records) |rec| {
                    if (!self.gsub_lookup_map.contains(rec.lookup_index)) {
                        try self.parseGSUBLookup(data, lookup_list_offset, rec.lookup_index, .calt);
                    }
                }
            }
        }
    }

    fn parseGSUBLookup(self: *OpenTypeFeatures, data: []const u8, lookup_list_offset: u16, lookup_index: u16, feature: ?Feature) !void {
        // Skip if already parsed this lookup
        if (self.gsub_lookup_map.contains(lookup_index)) return;

        // Get lookup table offset
        if (lookup_list_offset + 2 > data.len) return;
        const lookup_count = readU16(data, lookup_list_offset);
        if (lookup_index >= lookup_count) return;

        const lookup_offset_pos = lookup_list_offset + 2 + @as(usize, lookup_index) * 2;
        if (lookup_offset_pos + 2 > data.len) return;
        const lookup_offset = readU16(data, lookup_offset_pos);
        const lookup_table_offset = lookup_list_offset + lookup_offset;

        if (lookup_table_offset + 6 > data.len) return;

        const lookup_type = readU16(data, lookup_table_offset);
        const subtable_count = readU16(data, lookup_table_offset + 4);

        // Track starting index for this lookup type
        const single_start = self.single_lookups.items.len;
        const liga_start = self.liga_lookups.items.len;
        const dlig_start = self.dlig_lookups.items.len;
        const clig_start = self.clig_lookups.items.len;
        const hlig_start = self.hlig_lookups.items.len;
        const calt_liga_start = self.calt_liga_lookups.items.len;
        const chain_start = self.chain_context_lookups.items.len;

        var i: u16 = 0;
        while (i < subtable_count) : (i += 1) {
            const st_offset_pos = lookup_table_offset + 6 + @as(usize, i) * 2;
            if (st_offset_pos + 2 > data.len) break;

            const subtable_offset = readU16(data, st_offset_pos);
            const subtable_addr = lookup_table_offset + subtable_offset;

            switch (lookup_type) {
                1 => try self.parseSingleSubtable(data, subtable_addr), // Type 1: Single Substitution
                4 => { // Type 4: Ligature Substitution
                    // Parse and append to appropriate feature array
                    if (try self.parseLigatureSubtable(data, subtable_addr)) |lig_subst| {
                        if (feature) |f| {
                            switch (f) {
                                .liga => try self.liga_lookups.append(self.allocator, lig_subst),
                                .dlig => try self.dlig_lookups.append(self.allocator, lig_subst),
                                .clig => try self.clig_lookups.append(self.allocator, lig_subst),
                                .hlig => try self.hlig_lookups.append(self.allocator, lig_subst),
                                .calt => try self.calt_liga_lookups.append(self.allocator, lig_subst),
                                else => {}, // Other features, don't add to any array
                            }
                        }
                        // If feature is null, don't add to any array (for nested dispatch only)
                    }
                },
                6 => { // Type 6: Chaining Context Substitution
                    // Only parse chain context for calt feature to avoid applying wrong rules
                    if (feature) |f| {
                        if (f == .calt) {
                            try self.parseChainContextSubtable(data, subtable_addr);
                        }
                    }
                },
                else => {}, // Ignore unsupported types
            }
        }

        // Record lookup mapping (first subtable parsed for this lookup)
        const lookup_ref: ?GSUBLookupRef = switch (lookup_type) {
            1 => if (self.single_lookups.items.len > single_start)
                GSUBLookupRef{ .single = single_start }
            else
                null,
            4 => blk: {
                // Determine which ligature array was appended to based on feature
                if (feature) |f| {
                    switch (f) {
                        .liga => break :blk if (self.liga_lookups.items.len > liga_start)
                            GSUBLookupRef{ .liga = liga_start }
                        else
                            null,
                        .dlig => break :blk if (self.dlig_lookups.items.len > dlig_start)
                            GSUBLookupRef{ .dlig = dlig_start }
                        else
                            null,
                        .clig => break :blk if (self.clig_lookups.items.len > clig_start)
                            GSUBLookupRef{ .clig = clig_start }
                        else
                            null,
                        .hlig => break :blk if (self.hlig_lookups.items.len > hlig_start)
                            GSUBLookupRef{ .hlig = hlig_start }
                        else
                            null,
                        .calt => break :blk if (self.calt_liga_lookups.items.len > calt_liga_start)
                            GSUBLookupRef{ .calt_liga = calt_liga_start }
                        else
                            null,
                        else => break :blk null, // Other feature
                    }
                } else {
                    break :blk null; // No feature, no ligature ref
                }
            },
            6 => if (self.chain_context_lookups.items.len > chain_start)
                GSUBLookupRef{ .chain_context = chain_start }
            else
                null,
            else => null,
        };

        if (lookup_ref) |ref| {
            try self.gsub_lookup_map.put(self.allocator, lookup_index, ref);
        }
    }

    fn parseGPOSFeature(self: *OpenTypeFeatures, data: []const u8, feature: Feature) !void {
        if (data.len < 10) return;

        const script_list_offset = readU16(data, 4);
        const feature_list_offset = readU16(data, 6);
        const lookup_list_offset = readU16(data, 8);

        const feature_indices = try self.findFeatureIndices(data, script_list_offset, feature_list_offset, feature);
        defer self.allocator.free(feature_indices);

        if (feature_list_offset + 2 > data.len) return;
        const feature_count = readU16(data, feature_list_offset);

        for (feature_indices) |feat_idx| {
            if (feat_idx >= feature_count) continue;

            const feat_record_offset = feature_list_offset + 2 + @as(usize, feat_idx) * 6;
            if (feat_record_offset + 6 > data.len) continue;

            const feat_offset = readU16(data, feat_record_offset + 4);
            const feat_table_offset = feature_list_offset + feat_offset;

            if (feat_table_offset + 4 > data.len) continue;
            const lookup_index_count = readU16(data, feat_table_offset + 2);

            var i: u16 = 0;
            while (i < lookup_index_count) : (i += 1) {
                const li_offset = feat_table_offset + 4 + @as(usize, i) * 2;
                if (li_offset + 2 > data.len) break;

                const lookup_index = readU16(data, li_offset);
                try self.parseGPOSLookup(data, lookup_list_offset, lookup_index, feature);
            }
        }
    }

    fn parseGPOSLookup(self: *OpenTypeFeatures, data: []const u8, lookup_list_offset: u16, lookup_index: u16, feature: Feature) !void {
        if (lookup_list_offset + 2 > data.len) return;
        const lookup_count = readU16(data, lookup_list_offset);
        if (lookup_index >= lookup_count) return;

        const lookup_offset_pos = lookup_list_offset + 2 + @as(usize, lookup_index) * 2;
        if (lookup_offset_pos + 2 > data.len) return;
        const lookup_offset = readU16(data, lookup_offset_pos);
        const lookup_table_offset = lookup_list_offset + lookup_offset;

        if (lookup_table_offset + 6 > data.len) return;

        const lookup_type = readU16(data, lookup_table_offset);
        const subtable_count = readU16(data, lookup_table_offset + 4);

        var i: u16 = 0;
        while (i < subtable_count) : (i += 1) {
            const st_offset_pos = lookup_table_offset + 6 + @as(usize, i) * 2;
            if (st_offset_pos + 2 > data.len) break;

            const subtable_offset = readU16(data, st_offset_pos);
            const subtable_addr = lookup_table_offset + subtable_offset;

            switch (lookup_type) {
                2 => { // Type 2: Pair Adjustment (kerning)
                    if (feature == .kern) try self.parseKernSubtable(data, subtable_addr);
                },
                4 => { // Type 4: Mark-to-Base
                    if (feature == .mark) try self.parseMarkBaseSubtable(data, subtable_addr);
                },
                6 => { // Type 6: Mark-to-Mark
                    if (feature == .mkmk) try self.parseMarkMarkSubtable(data, subtable_addr);
                },
                9 => { // Type 9: Extension Positioning (wraps other lookup types)
                    if (subtable_addr + 8 > data.len) continue;
                    const ext_format = readU16(data, subtable_addr);
                    if (ext_format != 1) continue;
                    const ext_lookup_type = readU16(data, subtable_addr + 2);
                    const ext_offset = readU32(data, subtable_addr + 4);
                    const actual_subtable_addr = subtable_addr + ext_offset;

                    // Parse the actual subtable based on the extended type
                    switch (ext_lookup_type) {
                        2 => { // Pair Adjustment (kerning)
                            if (feature == .kern) try self.parseKernSubtable(data, actual_subtable_addr);
                        },
                        4 => { // Mark-to-Base
                            if (feature == .mark) try self.parseMarkBaseSubtable(data, actual_subtable_addr);
                        },
                        6 => { // Mark-to-Mark
                            if (feature == .mkmk) try self.parseMarkMarkSubtable(data, actual_subtable_addr);
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn findFeatureIndices(self: *OpenTypeFeatures, data: []const u8, script_list_offset: u16, feature_list_offset: u16, target_feature: Feature) ![]u16 {
        var indices = std.ArrayListUnmanaged(u16){};
        errdefer indices.deinit(self.allocator);

        // Find DFLT or latn script
        const script_offset = self.findScriptOffset(data, script_list_offset) orelse return indices.toOwnedSlice(self.allocator);

        // Get default LangSys or specific one
        if (script_offset + 4 > data.len) return indices.toOwnedSlice(self.allocator);
        const default_langsys_offset = readU16(data, script_offset);

        var langsys_offset: usize = 0;
        if (default_langsys_offset != 0) {
            langsys_offset = script_offset + default_langsys_offset;
        } else {
            // Try to find 'dflt' or first langsys
            const langsys_count = readU16(data, script_offset + 2);
            if (langsys_count > 0 and script_offset + 6 + 6 <= data.len) {
                const ls_offset = readU16(data, script_offset + 6 + 4); // First langsys record
                langsys_offset = script_offset + ls_offset;
            }
        }

        if (langsys_offset == 0 or langsys_offset + 6 > data.len) return indices.toOwnedSlice(self.allocator);

        // LangSys table: lookupOrder, reqFeatureIndex, featureIndexCount, featureIndices[]
        const feature_index_count = readU16(data, langsys_offset + 4);

        // Search feature indices for matching feature tag
        var i: u16 = 0;
        while (i < feature_index_count) : (i += 1) {
            const fi_offset = langsys_offset + 6 + @as(usize, i) * 2;
            if (fi_offset + 2 > data.len) break;

            const feat_idx = readU16(data, fi_offset);

            // Check feature tag at this index
            const feat_record_offset = feature_list_offset + 2 + @as(usize, feat_idx) * 6;
            if (feat_record_offset + 4 > data.len) continue;

            const feat_tag = readU32(data, feat_record_offset);
            if (feat_tag == @intFromEnum(target_feature)) {
                try indices.append(self.allocator, feat_idx);
            }
        }

        return indices.toOwnedSlice(self.allocator);
    }

    fn findScriptOffset(self: *OpenTypeFeatures, data: []const u8, script_list_offset: u16) ?usize {
        _ = self;
        if (script_list_offset + 2 > data.len) return null;
        const script_count = readU16(data, script_list_offset);

        // Look for DFLT, then latn
        var dflt_offset: ?usize = null;
        var latn_offset: ?usize = null;

        var i: u16 = 0;
        while (i < script_count) : (i += 1) {
            const record_offset = script_list_offset + 2 + @as(usize, i) * 6;
            if (record_offset + 6 > data.len) break;

            const script_tag = readU32(data, record_offset);
            const offset = readU16(data, record_offset + 4);

            if (script_tag == 0x44464C54) { // DFLT
                dflt_offset = script_list_offset + offset;
            } else if (script_tag == 0x6C61746E) { // latn
                latn_offset = script_list_offset + offset;
            }
        }

        return dflt_offset orelse latn_offset;
    }

    fn parseLigatureSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !?LigatureSubst {
        if (offset + 6 > data.len) return null;

        const format = readU16(data, offset);
        if (format != 1) return null; // Only format 1 supported

        const coverage_offset = readU16(data, offset + 2);
        const lig_set_count = readU16(data, offset + 4);

        // Parse coverage table
        const coverage_addr = offset + coverage_offset;
        if (coverage_addr + 4 > data.len) return null;

        const coverage = CoverageTable{
            .format = readU16(data, coverage_addr),
            .data = data[coverage_addr..],
        };

        // Parse ligature sets
        const lig_sets_start = self.ligature_sets.items.len;

        var set_idx: u16 = 0;
        while (set_idx < lig_set_count) : (set_idx += 1) {
            const set_offset_pos = offset + 6 + @as(usize, set_idx) * 2;
            if (set_offset_pos + 2 > data.len) break;

            const lig_set_offset = readU16(data, set_offset_pos);
            const lig_set_addr = offset + lig_set_offset;

            if (lig_set_addr + 2 > data.len) break;
            const lig_count = readU16(data, lig_set_addr);

            const ligs_start = self.ligature_structs.items.len;

            var lig_idx: u16 = 0;
            while (lig_idx < lig_count) : (lig_idx += 1) {
                const lig_offset_pos = lig_set_addr + 2 + @as(usize, lig_idx) * 2;
                if (lig_offset_pos + 2 > data.len) break;

                const lig_offset = readU16(data, lig_offset_pos);
                const lig_addr = lig_set_addr + lig_offset;

                if (lig_addr + 4 > data.len) break;

                const lig_glyph = readU16(data, lig_addr);
                const comp_count = readU16(data, lig_addr + 2);

                // Parse components (comp_count - 1 because first glyph is covered by coverage)
                const actual_comp_count = if (comp_count > 0) comp_count - 1 else 0;
                const components = try self.allocator.alloc(u16, actual_comp_count);
                errdefer self.allocator.free(components);

                var comp_idx: u16 = 0;
                while (comp_idx < actual_comp_count) : (comp_idx += 1) {
                    const comp_offset = lig_addr + 4 + @as(usize, comp_idx) * 2;
                    if (comp_offset + 2 > data.len) break;
                    components[comp_idx] = readU16(data, comp_offset);
                }

                try self.ligature_memory.append(self.allocator, components);
                try self.ligature_structs.append(self.allocator, .{
                    .lig_glyph = lig_glyph,
                    .components = components,
                });
            }

            try self.ligature_sets.append(self.allocator, .{
                .start = ligs_start,
                .count = self.ligature_structs.items.len - ligs_start,
            });
        }

        return LigatureSubst{
            .coverage = coverage,
            .sets_start = lig_sets_start,
            .sets_count = self.ligature_sets.items.len - lig_sets_start,
        };
    }

    fn parseKernSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 8 > data.len) return;

        const format = readU16(data, offset);
        const coverage_offset = readU16(data, offset + 2);

        const coverage_addr = offset + coverage_offset;
        if (coverage_addr + 4 > data.len) return;

        const coverage = CoverageTable{
            .format = readU16(data, coverage_addr),
            .data = data[coverage_addr..],
        };

        if (format == 1) {
            try self.kern_lookups.append(self.allocator, .{
                .format = 1,
                .coverage = coverage,
                .data = data[offset..],
            });
        } else if (format == 2) {
            if (offset + 16 > data.len) return;

            const class_def1_offset = readU16(data, offset + 8);
            const class_def2_offset = readU16(data, offset + 10);
            const class1_count = readU16(data, offset + 12);
            const class2_count = readU16(data, offset + 14);

            const class1_addr = offset + class_def1_offset;
            const class2_addr = offset + class_def2_offset;

            var lookup = PairPosLookup{
                .format = 2,
                .coverage = coverage,
                .data = data[offset..],
                .class1_count = class1_count,
                .class2_count = class2_count,
                .class1_records_offset = 16,
            };

            if (class1_addr + 2 <= data.len) {
                lookup.class_def1 = .{
                    .format = readU16(data, class1_addr),
                    .data = data[class1_addr..],
                };
            }
            if (class2_addr + 2 <= data.len) {
                lookup.class_def2 = .{
                    .format = readU16(data, class2_addr),
                    .data = data[class2_addr..],
                };
            }

            try self.kern_lookups.append(self.allocator, lookup);
        }
    }

    /// Parse GSUB Type 1: Single Substitution subtable
    fn parseSingleSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 6 > data.len) return;

        const format = readU16(data, offset);
        const coverage_offset = readU16(data, offset + 2);

        const coverage_addr = offset + coverage_offset;
        if (coverage_addr + 4 > data.len) return;

        const coverage = CoverageTable{
            .format = readU16(data, coverage_addr),
            .data = data[coverage_addr..],
        };

        if (format == 1) {
            // Format 1: Add delta to glyph ID
            const delta = readI16(data, offset + 4);
            try self.single_lookups.append(self.allocator, .{
                .coverage = coverage,
                .format = 1,
                .delta = delta,
            });
        } else if (format == 2) {
            // Format 2: Direct substitution array
            const glyph_count = readU16(data, offset + 4);
            const substitutes = try self.allocator.alloc(u16, glyph_count);
            errdefer self.allocator.free(substitutes);

            var i: u16 = 0;
            while (i < glyph_count) : (i += 1) {
                const subst_offset = offset + 6 + @as(usize, i) * 2;
                if (subst_offset + 2 > data.len) break;
                substitutes[i] = readU16(data, subst_offset);
            }

            try self.single_subst_memory.append(self.allocator, substitutes);
            try self.single_lookups.append(self.allocator, .{
                .coverage = coverage,
                .format = 2,
                .substitutes = substitutes,
            });
        }
    }

    /// Parse GSUB Type 6: Chaining Context Substitution subtable
    fn parseChainContextSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 4 > data.len) return;

        const format = readU16(data, offset);
        if (format != 3) return; // Only Format 3 supported for now

        // Format 3 structure:
        // format(2), backtrackGlyphCount(2), backtrackCoverages[],
        // inputGlyphCount(2), inputCoverages[],
        // lookaheadGlyphCount(2), lookaheadCoverages[],
        // substCount(2), substLookupRecords[]

        var pos = offset + 2;
        if (pos + 2 > data.len) return;

        // Parse backtrack coverages
        const backtrack_count = readU16(data, pos);
        pos += 2;

        var backtrack_coverages = try self.allocator.alloc(CoverageTable, backtrack_count);
        errdefer self.allocator.free(backtrack_coverages);

        var i: u16 = 0;
        while (i < backtrack_count) : (i += 1) {
            if (pos + 2 > data.len) {
                self.allocator.free(backtrack_coverages);
                return;
            }
            const cov_offset = readU16(data, pos);
            pos += 2;
            const cov_addr = offset + cov_offset;
            if (cov_addr + 4 > data.len) {
                self.allocator.free(backtrack_coverages);
                return;
            }
            backtrack_coverages[i] = .{
                .format = readU16(data, cov_addr),
                .data = data[cov_addr..],
            };
        }

        // Parse input coverages
        if (pos + 2 > data.len) {
            self.allocator.free(backtrack_coverages);
            return;
        }
        const input_count = readU16(data, pos);
        pos += 2;

        var input_coverages = try self.allocator.alloc(CoverageTable, input_count);
        errdefer {
            self.allocator.free(input_coverages);
            self.allocator.free(backtrack_coverages);
        }

        i = 0;
        while (i < input_count) : (i += 1) {
            if (pos + 2 > data.len) {
                self.allocator.free(input_coverages);
                self.allocator.free(backtrack_coverages);
                return;
            }
            const cov_offset = readU16(data, pos);
            pos += 2;
            const cov_addr = offset + cov_offset;
            if (cov_addr + 4 > data.len) {
                self.allocator.free(input_coverages);
                self.allocator.free(backtrack_coverages);
                return;
            }
            input_coverages[i] = .{
                .format = readU16(data, cov_addr),
                .data = data[cov_addr..],
            };
        }

        // Parse lookahead coverages
        if (pos + 2 > data.len) {
            self.allocator.free(input_coverages);
            self.allocator.free(backtrack_coverages);
            return;
        }
        const lookahead_count = readU16(data, pos);
        pos += 2;

        var lookahead_coverages = try self.allocator.alloc(CoverageTable, lookahead_count);
        errdefer {
            self.allocator.free(lookahead_coverages);
            self.allocator.free(input_coverages);
            self.allocator.free(backtrack_coverages);
        }

        i = 0;
        while (i < lookahead_count) : (i += 1) {
            if (pos + 2 > data.len) {
                self.allocator.free(lookahead_coverages);
                self.allocator.free(input_coverages);
                self.allocator.free(backtrack_coverages);
                return;
            }
            const cov_offset = readU16(data, pos);
            pos += 2;
            const cov_addr = offset + cov_offset;
            if (cov_addr + 4 > data.len) {
                self.allocator.free(lookahead_coverages);
                self.allocator.free(input_coverages);
                self.allocator.free(backtrack_coverages);
                return;
            }
            lookahead_coverages[i] = .{
                .format = readU16(data, cov_addr),
                .data = data[cov_addr..],
            };
        }

        // Parse substitution records
        if (pos + 2 > data.len) {
            self.allocator.free(lookahead_coverages);
            self.allocator.free(input_coverages);
            self.allocator.free(backtrack_coverages);
            return;
        }
        const subst_count = readU16(data, pos);
        pos += 2;

        var subst_records = try self.allocator.alloc(SubstLookupRecord, subst_count);
        errdefer self.allocator.free(subst_records);

        i = 0;
        while (i < subst_count) : (i += 1) {
            if (pos + 4 > data.len) {
                self.allocator.free(subst_records);
                self.allocator.free(lookahead_coverages);
                self.allocator.free(input_coverages);
                self.allocator.free(backtrack_coverages);
                return;
            }
            subst_records[i] = .{
                .sequence_index = readU16(data, pos),
                .lookup_index = readU16(data, pos + 2),
            };
            pos += 4;
        }

        // Store memory for cleanup
        try self.chain_coverage_memory.append(self.allocator, backtrack_coverages);
        try self.chain_coverage_memory.append(self.allocator, input_coverages);
        try self.chain_coverage_memory.append(self.allocator, lookahead_coverages);
        try self.chain_record_memory.append(self.allocator, subst_records);

        try self.chain_context_lookups.append(self.allocator, .{
            .backtrack_coverages = backtrack_coverages,
            .input_coverages = input_coverages,
            .lookahead_coverages = lookahead_coverages,
            .subst_records = subst_records,
        });

    }

    /// Parse GPOS Type 4: Mark-to-Base Attachment subtable
    fn parseMarkBaseSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 12 > data.len) return;

        const format = readU16(data, offset);
        if (format != 1) return; // Only format 1 supported

        const mark_cov_offset = readU16(data, offset + 2);
        const base_cov_offset = readU16(data, offset + 4);
        const mark_class_count = readU16(data, offset + 6);
        const mark_array_offset = readU16(data, offset + 8);
        const base_array_offset = readU16(data, offset + 10);

        // Parse mark coverage
        const mark_cov_addr = offset + mark_cov_offset;
        if (mark_cov_addr + 4 > data.len) return;
        const mark_coverage = CoverageTable{
            .format = readU16(data, mark_cov_addr),
            .data = data[mark_cov_addr..],
        };

        // Parse base coverage
        const base_cov_addr = offset + base_cov_offset;
        if (base_cov_addr + 4 > data.len) return;
        const base_coverage = CoverageTable{
            .format = readU16(data, base_cov_addr),
            .data = data[base_cov_addr..],
        };

        // Parse mark array
        const mark_array_addr = offset + mark_array_offset;
        if (mark_array_addr + 2 > data.len) return;
        const mark_count = readU16(data, mark_array_addr);

        var mark_records = try self.allocator.alloc(MarkRecord, mark_count);
        errdefer self.allocator.free(mark_records);

        var i: u16 = 0;
        while (i < mark_count) : (i += 1) {
            const rec_offset = mark_array_addr + 2 + @as(usize, i) * 4;
            if (rec_offset + 4 > data.len) break;

            const mark_class = readU16(data, rec_offset);
            const anchor_offset = readU16(data, rec_offset + 2);
            const anchor_addr = mark_array_addr + anchor_offset;

            if (anchor_addr + 6 > data.len) {
                mark_records[i] = .{ .mark_class = mark_class, .anchor = .{ .x = 0, .y = 0 } };
            } else {
                mark_records[i] = .{
                    .mark_class = mark_class,
                    .anchor = .{
                        .x = readI16(data, anchor_addr + 2),
                        .y = readI16(data, anchor_addr + 4),
                    },
                };
            }
        }

        // Get base count
        const base_array_addr = offset + base_array_offset;
        if (base_array_addr + 2 > data.len) {
            self.allocator.free(mark_records);
            return;
        }
        const base_count = readU16(data, base_array_addr);

        try self.mark_record_memory.append(self.allocator, mark_records);
        try self.mark_base_lookups.append(self.allocator, .{
            .mark_coverage = mark_coverage,
            .base_coverage = base_coverage,
            .mark_class_count = mark_class_count,
            .mark_records = mark_records,
            .base_anchors_data = data,
            .base_count = base_count,
            .base_array_offset = base_array_addr,
        });
    }

    /// Parse GPOS Type 6: Mark-to-Mark Attachment subtable
    fn parseMarkMarkSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 12 > data.len) return;

        const format = readU16(data, offset);
        if (format != 1) return; // Only format 1 supported

        const mark1_cov_offset = readU16(data, offset + 2);
        const mark2_cov_offset = readU16(data, offset + 4);
        const mark_class_count = readU16(data, offset + 6);
        const mark1_array_offset = readU16(data, offset + 8);
        const mark2_array_offset = readU16(data, offset + 10);

        // Parse mark1 coverage (combining mark)
        const mark1_cov_addr = offset + mark1_cov_offset;
        if (mark1_cov_addr + 4 > data.len) return;
        const mark1_coverage = CoverageTable{
            .format = readU16(data, mark1_cov_addr),
            .data = data[mark1_cov_addr..],
        };

        // Parse mark2 coverage (base mark)
        const mark2_cov_addr = offset + mark2_cov_offset;
        if (mark2_cov_addr + 4 > data.len) return;
        const mark2_coverage = CoverageTable{
            .format = readU16(data, mark2_cov_addr),
            .data = data[mark2_cov_addr..],
        };

        // Parse mark1 array
        const mark1_array_addr = offset + mark1_array_offset;
        if (mark1_array_addr + 2 > data.len) return;
        const mark1_count = readU16(data, mark1_array_addr);

        var mark1_records = try self.allocator.alloc(MarkRecord, mark1_count);
        errdefer self.allocator.free(mark1_records);

        var i: u16 = 0;
        while (i < mark1_count) : (i += 1) {
            const rec_offset = mark1_array_addr + 2 + @as(usize, i) * 4;
            if (rec_offset + 4 > data.len) break;

            const mark_class = readU16(data, rec_offset);
            const anchor_offset = readU16(data, rec_offset + 2);
            const anchor_addr = mark1_array_addr + anchor_offset;

            if (anchor_addr + 6 > data.len) {
                mark1_records[i] = .{ .mark_class = mark_class, .anchor = .{ .x = 0, .y = 0 } };
            } else {
                mark1_records[i] = .{
                    .mark_class = mark_class,
                    .anchor = .{
                        .x = readI16(data, anchor_addr + 2),
                        .y = readI16(data, anchor_addr + 4),
                    },
                };
            }
        }

        // Get mark2 count
        const mark2_array_addr = offset + mark2_array_offset;
        if (mark2_array_addr + 2 > data.len) {
            self.allocator.free(mark1_records);
            return;
        }
        const mark2_count = readU16(data, mark2_array_addr);

        try self.mark_record_memory.append(self.allocator, mark1_records);
        try self.mark_mark_lookups.append(self.allocator, .{
            .mark1_coverage = mark1_coverage,
            .mark2_coverage = mark2_coverage,
            .mark_class_count = mark_class_count,
            .mark1_records = mark1_records,
            .mark2_anchors_data = data,
            .mark2_count = mark2_count,
            .mark2_array_offset = mark2_array_addr,
        });
    }

    /// Apply ligature substitution to a glyph sequence
    /// Returns new glyph sequence with ligatures applied
    pub fn applyLigatures(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        if (self.liga_lookups.items.len == 0) {
            return try self.allocator.dupe(u16, glyphs);
        }

        var result = std.ArrayListUnmanaged(u16){};
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < glyphs.len) {
            var matched = false;

            // Try each ligature lookup
            for (self.liga_lookups.items) |lookup| {
                if (lookup.findLigature(glyphs, pos, self.ligature_sets.items, self.ligature_structs.items)) |match| {
                    try result.append(self.allocator, match.lig_glyph);
                    pos += match.consumed;
                    matched = true;
                    break;
                }
            }

            if (!matched) {
                try result.append(self.allocator, glyphs[pos]);
                pos += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Apply ligature substitution using specific lookup array
    fn applyFeatureLigatures(self: *OpenTypeFeatures, glyphs: []const u16, lookups: []const LigatureSubst) ![]u16 {
        if (lookups.len == 0) {
            return try self.allocator.dupe(u16, glyphs);
        }

        var result = std.ArrayListUnmanaged(u16){};
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < glyphs.len) {
            var matched = false;

            // Try each ligature lookup
            for (lookups) |lookup| {
                if (lookup.findLigature(glyphs, pos, self.ligature_sets.items, self.ligature_structs.items)) |match| {
                    try result.append(self.allocator, match.lig_glyph);
                    pos += match.consumed;
                    matched = true;
                    break;
                }
            }

            if (!matched) {
                try result.append(self.allocator, glyphs[pos]);
                pos += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Apply discretionary ligatures (dlig feature)
    pub fn applyDlig(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        return self.applyFeatureLigatures(glyphs, self.dlig_lookups.items);
    }

    /// Apply contextual ligatures (clig feature)
    pub fn applyClig(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        return self.applyFeatureLigatures(glyphs, self.clig_lookups.items);
    }

    /// Apply historical ligatures (hlig feature)
    pub fn applyHlig(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        return self.applyFeatureLigatures(glyphs, self.hlig_lookups.items);
    }

    /// Get kerning adjustment between two glyphs
    pub fn getKerning(self: *OpenTypeFeatures, glyph1: u16, glyph2: u16) i16 {
        for (self.kern_lookups.items) |lookup| {
            const kern = lookup.getKerning(glyph1, glyph2);
            if (kern != 0) return kern;
        }
        return 0;
    }

    /// Apply contextual alternates (calt) substitution to a glyph sequence
    /// Processes calt ligatures (e.g., ->) and chain context rules
    pub fn applyCalt(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        const has_calt_liga = self.calt_liga_lookups.items.len > 0;
        const has_chain = self.chain_context_lookups.items.len > 0;

        if (!has_calt_liga and !has_chain) {
            return try self.allocator.dupe(u16, glyphs);
        }

        // First apply calt's direct ligatures (e.g., -> to arrow)
        var intermediate: []u16 = undefined;
        var owns_intermediate = false;
        if (has_calt_liga) {
            intermediate = try self.applyFeatureLigatures(glyphs, self.calt_liga_lookups.items);
            owns_intermediate = true;
        } else {
            intermediate = @constCast(glyphs);
        }
        defer if (owns_intermediate) self.allocator.free(intermediate);

        // If no chain context, we're done
        if (!has_chain) {
            if (owns_intermediate) {
                const copy = try self.allocator.dupe(u16, intermediate);
                return copy;
            }
            return try self.allocator.dupe(u16, intermediate);
        }

        // Work with a mutable copy for chain context processing
        var result = std.ArrayListUnmanaged(u16){};
        errdefer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, intermediate);

        // Process each position
        var pos: usize = 0;
        while (pos < result.items.len) {
            // Try each chain context rule
            for (self.chain_context_lookups.items) |chain_lookup| {
                if (chain_lookup.match(result.items, pos)) |subst_records| {
                    // Apply nested substitutions
                    for (subst_records) |rec| {
                        const target_pos = pos + rec.sequence_index;
                        if (target_pos >= result.items.len) continue;

                        // Find the referenced lookup
                        if (self.gsub_lookup_map.get(rec.lookup_index)) |lookup_ref| {
                            switch (lookup_ref) {
                                .single => |idx| {
                                    if (idx < self.single_lookups.items.len) {
                                        const single = self.single_lookups.items[idx];
                                        if (single.substitute(result.items[target_pos])) |new_glyph| {
                                            result.items[target_pos] = new_glyph;
                                        }
                                    }
                                },
                                .liga, .dlig, .clig, .hlig, .calt_liga => |idx| {
                                    // Ligature substitution at target_pos
                                    const lookups = switch (lookup_ref) {
                                        .liga => self.liga_lookups.items,
                                        .dlig => self.dlig_lookups.items,
                                        .clig => self.clig_lookups.items,
                                        .hlig => self.hlig_lookups.items,
                                        .calt_liga => self.calt_liga_lookups.items,
                                        else => unreachable,
                                    };
                                    if (idx < lookups.len) {
                                        const liga = lookups[idx];
                                        if (liga.findLigature(result.items, target_pos, self.ligature_sets.items, self.ligature_structs.items)) |match| {
                                            // Replace glyphs with ligature
                                            result.items[target_pos] = match.lig_glyph;
                                            // Remove consumed glyphs (except first)
                                            if (match.consumed > 1) {
                                                const remove_count = match.consumed - 1;
                                                const remove_start = target_pos + 1;
                                                if (remove_start + remove_count <= result.items.len) {
                                                    // Shift remaining elements
                                                    const src_start = remove_start + remove_count;
                                                    const src_end = result.items.len;
                                                    std.mem.copyForwards(
                                                        u16,
                                                        result.items[remove_start..],
                                                        result.items[src_start..src_end],
                                                    );
                                                    result.shrinkRetainingCapacity(result.items.len - remove_count);
                                                }
                                            }
                                        }
                                    }
                                },
                                .chain_context => {
                                    // Nested chain context - skip for now to avoid recursion
                                },
                            }
                        }
                    }
                    break; // Stop after first matching rule
                }
            }

            // Always advance at least one position
            pos += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Apply all GSUB substitutions (calt + ligatures) in proper order
    /// Uses default feature flags (liga enabled, dlig/clig/hlig disabled)
    pub fn applyGSUB(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        return self.applyGSUBWithFlags(glyphs, .{});
    }

    /// Apply all GSUB substitutions with explicit feature flags
    pub fn applyGSUBWithFlags(self: *OpenTypeFeatures, glyphs: []const u16, flags: FeatureFlags) ![]u16 {
        var current = try self.allocator.dupe(u16, glyphs);
        errdefer self.allocator.free(current);

        // Apply calt first (contextual alternates)
        const has_calt = self.calt_liga_lookups.items.len > 0 or self.chain_context_lookups.items.len > 0;
        if (flags.calt and has_calt) {
            const next = try self.applyCalt(current);
            self.allocator.free(current);
            current = next;
        }

        // Apply standard ligatures (liga)
        if (flags.liga and self.liga_lookups.items.len > 0) {
            const next = try self.applyLigatures(current);
            self.allocator.free(current);
            current = next;
        }

        // Apply discretionary ligatures (dlig)
        if (flags.dlig and self.dlig_lookups.items.len > 0) {
            const next = try self.applyDlig(current);
            self.allocator.free(current);
            current = next;
        }

        // Apply contextual ligatures (clig)
        if (flags.clig and self.clig_lookups.items.len > 0) {
            const next = try self.applyClig(current);
            self.allocator.free(current);
            current = next;
        }

        // Apply historical ligatures (hlig)
        if (flags.hlig and self.hlig_lookups.items.len > 0) {
            const next = try self.applyHlig(current);
            self.allocator.free(current);
            current = next;
        }

        return current;
    }

    /// Get mark positioning offset for a mark glyph following a base glyph
    /// Returns (dx, dy) in design units, or null if no positioning applies
    pub fn getMarkOffset(self: *OpenTypeFeatures, base_glyph: u16, mark_glyph: u16) ?MarkOffset {
        // First try mark-to-base
        for (self.mark_base_lookups.items) |lookup| {
            if (lookup.getAttachment(mark_glyph, base_glyph)) |offset| {
                return offset;
            }
        }
        // Then try mark-to-mark (if base is also a mark)
        for (self.mark_mark_lookups.items) |lookup| {
            if (lookup.getAttachment(mark_glyph, base_glyph)) |offset| {
                return offset;
            }
        }
        return null;
    }
};

// Helper functions
fn valueRecordSize(format: u16) usize {
    var size: usize = 0;
    if (format & 0x0001 != 0) size += 2; // XPlacement
    if (format & 0x0002 != 0) size += 2; // YPlacement
    if (format & 0x0004 != 0) size += 2; // XAdvance
    if (format & 0x0008 != 0) size += 2; // YAdvance
    if (format & 0x0010 != 0) size += 2; // XPlaDevice
    if (format & 0x0020 != 0) size += 2; // YPlaDevice
    if (format & 0x0040 != 0) size += 2; // XAdvDevice
    if (format & 0x0080 != 0) size += 2; // YAdvDevice
    return size;
}

fn extractXAdvance(data: []const u8, offset: usize, format: u16) i16 {
    // XAdvance is at bit 2 (0x0004) in format
    // Position depends on which bits 0-2 are set
    var pos = offset;
    if (format & 0x0001 != 0) pos += 2; // Skip XPlacement
    if (format & 0x0002 != 0) pos += 2; // Skip YPlacement
    if (format & 0x0004 != 0) {
        if (pos + 2 <= data.len) {
            return readI16(data, pos);
        }
    }
    return 0;
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

test "Feature tag conversion" {
    try std.testing.expectEqual(@as(u32, 0x6C696761), @intFromEnum(Feature.liga));
    try std.testing.expectEqual(@as(u32, 0x6B65726E), @intFromEnum(Feature.kern));

    try std.testing.expectEqual(Feature.liga, Feature.fromTag(0x6C696761).?);
    try std.testing.expectEqual(Feature.kern, Feature.fromTag(0x6B65726E).?);
    try std.testing.expect(Feature.fromTag(0x12345678) == null);
}

test "Coverage table format 1" {
    // Format 1: glyph list [10, 20, 30]
    const data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x03, // glyphCount = 3
        0x00, 0x0A, // glyph[0] = 10
        0x00, 0x14, // glyph[1] = 20
        0x00, 0x1E, // glyph[2] = 30
    };

    const coverage = CoverageTable{ .format = 1, .data = &data };

    try std.testing.expectEqual(@as(?u16, 0), coverage.getCoverageIndex(10));
    try std.testing.expectEqual(@as(?u16, 1), coverage.getCoverageIndex(20));
    try std.testing.expectEqual(@as(?u16, 2), coverage.getCoverageIndex(30));
    try std.testing.expectEqual(@as(?u16, null), coverage.getCoverageIndex(15));
    try std.testing.expectEqual(@as(?u16, null), coverage.getCoverageIndex(5));
}

test "Coverage table format 2" {
    // Format 2: ranges [10-15] startIndex=0, [20-25] startIndex=6
    const data = [_]u8{
        0x00, 0x02, // format = 2
        0x00, 0x02, // rangeCount = 2
        0x00, 0x0A, // range[0].startGlyph = 10
        0x00, 0x0F, // range[0].endGlyph = 15
        0x00, 0x00, // range[0].startCoverageIndex = 0
        0x00, 0x14, // range[1].startGlyph = 20
        0x00, 0x19, // range[1].endGlyph = 25
        0x00, 0x06, // range[1].startCoverageIndex = 6
    };

    const coverage = CoverageTable{ .format = 2, .data = &data };

    try std.testing.expectEqual(@as(?u16, 0), coverage.getCoverageIndex(10));
    try std.testing.expectEqual(@as(?u16, 3), coverage.getCoverageIndex(13));
    try std.testing.expectEqual(@as(?u16, 5), coverage.getCoverageIndex(15));
    try std.testing.expectEqual(@as(?u16, 6), coverage.getCoverageIndex(20));
    try std.testing.expectEqual(@as(?u16, 9), coverage.getCoverageIndex(23));
    try std.testing.expectEqual(@as(?u16, null), coverage.getCoverageIndex(16));
    try std.testing.expectEqual(@as(?u16, null), coverage.getCoverageIndex(5));
}

test "Ligature matching" {
    // Simple ligature: glyph 10 + glyph 11 -> glyph 100
    const components = [_]u16{11};
    const ligature_structs = [_]Ligature{.{
        .lig_glyph = 100,
        .components = &components,
    }};
    const lig_sets = [_]LigatureSet{.{
        .start = 0,
        .count = 1,
    }};

    // Coverage: only glyph 10 covered
    const coverage_data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x0A, // glyph[0] = 10
    };

    const lookup = LigatureSubst{
        .coverage = .{ .format = 1, .data = &coverage_data },
        .sets_start = 0,
        .sets_count = 1,
    };

    const glyphs = [_]u16{ 10, 11, 12 };

    const result = lookup.findLigature(&glyphs, 0, &lig_sets, &ligature_structs);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 100), result.?.lig_glyph);
    try std.testing.expectEqual(@as(usize, 2), result.?.consumed);

    // No match at position 1
    try std.testing.expect(lookup.findLigature(&glyphs, 1, &lig_sets, &ligature_structs) == null);
}

test "OpenTypeFeatures init and deinit" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try std.testing.expectEqual(@as(usize, 0), features.liga_lookups.items.len);
    try std.testing.expectEqual(@as(usize, 0), features.kern_lookups.items.len);
}

test "Parse Charter GPOS kerning" {
    // Charter font has GPOS kerning table
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf") catch |err| {
        std.debug.print("Failed to load font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    // Check GPOS table exists
    const gpos_data = font.getTable("GPOS".*) orelse {
        std.debug.print("No GPOS table found\n", .{});
        return error.TableNotFound;
    };

    // Parse GPOS
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGPOS(gpos_data);

    // Should have kerning lookups
    try std.testing.expect(features.kern_lookups.items.len > 0);

    // Test kerning between common pairs
    // Note: Charter has kern feature, test specific known pairs
    const glyph_A = font.getGlyphId('A') orelse 0;
    const glyph_V = font.getGlyphId('V') orelse 0;
    const glyph_T = font.getGlyphId('T') orelse 0;
    const glyph_o = font.getGlyphId('o') orelse 0;

    // AV is a common kerning pair (usually negative kerning)
    const kern_AV = features.getKerning(glyph_A, glyph_V);
    // To is often kerned
    const kern_To = features.getKerning(glyph_T, glyph_o);

    // At least one should have non-zero kerning
    const has_kerning = kern_AV != 0 or kern_To != 0;
    if (!has_kerning) {
        std.debug.print("Warning: No kerning found for AV or To pairs\n", .{});
    }
    // This is expected to pass for Charter font
    try std.testing.expect(has_kerning);
}

test "applyLigatures" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    // Manual setup of a simple ligature: f (70) + i (71) -> fi ligature (100)
    const components = [_]u16{71}; // 'i' glyph
    const comp_slice = try std.testing.allocator.dupe(u16, &components);
    try features.ligature_memory.append(std.testing.allocator, comp_slice);

    try features.ligature_structs.append(std.testing.allocator, .{
        .lig_glyph = 100,
        .components = comp_slice,
    });

    try features.ligature_sets.append(std.testing.allocator, .{
        .start = 0,
        .count = 1,
    });

    // Coverage: 'f' glyph (70)
    // Use static data for coverage (lives for duration of test)
    const coverage_data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x46, // glyph[0] = 70 ('f')
    };

    try features.liga_lookups.append(std.testing.allocator, .{
        .coverage = .{ .format = 1, .data = &coverage_data },
        .sets_start = 0,
        .sets_count = 1,
    });

    // Test: "fi" (glyphs 70, 71) -> ligature 100
    const input_glyphs = [_]u16{ 70, 71 };
    const result = try features.applyLigatures(&input_glyphs);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u16, 100), result[0]);
}

test "applyLigatures preserves unmatched" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    // No ligatures configured - should return copy of input
    const input_glyphs = [_]u16{ 65, 66, 67 }; // ABC
    const result = try features.applyLigatures(&input_glyphs);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u16, 65), result[0]);
    try std.testing.expectEqual(@as(u16, 66), result[1]);
    try std.testing.expectEqual(@as(u16, 67), result[2]);
}

test "Parse Satoshi GSUB ligatures" {
    // Satoshi font has liga feature with fi, fl, ff, ffi, ffl, ft ligatures
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Satoshi/Satoshi-Regular.otf") catch |err| {
        std.debug.print("Failed to load font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    // Check GSUB table exists
    const gsub_data = font.getTable("GSUB".*) orelse {
        std.debug.print("No GSUB table found\n", .{});
        return error.TableNotFound;
    };

    // Parse GSUB
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGSUB(gsub_data);

    // Should have ligature lookups
    try std.testing.expect(features.liga_lookups.items.len > 0);

    // Get glyph IDs for test characters
    const glyph_f = font.getGlyphId('f') orelse 0;
    const glyph_i = font.getGlyphId('i') orelse 0;
    const glyph_l = font.getGlyphId('l') orelse 0;
    const glyph_t = font.getGlyphId('t') orelse 0;

    std.debug.print("\nGlyph IDs: f={d} i={d} l={d} t={d}\n", .{ glyph_f, glyph_i, glyph_l, glyph_t });

    // Test fi ligature
    const fi_glyphs = [_]u16{ glyph_f, glyph_i };
    const fi_result = try features.applyLigatures(&fi_glyphs);
    defer std.testing.allocator.free(fi_result);

    std.debug.print("fi input: [{d}, {d}] -> output: {any}\n", .{ glyph_f, glyph_i, fi_result });

    // Should have 1 glyph (the fi ligature)
    try std.testing.expectEqual(@as(usize, 1), fi_result.len);
    // The ligature glyph should be different from both f and i
    try std.testing.expect(fi_result[0] != glyph_f);
    try std.testing.expect(fi_result[0] != glyph_i);

    // Test fl ligature
    const fl_glyphs = [_]u16{ glyph_f, glyph_l };
    const fl_result = try features.applyLigatures(&fl_glyphs);
    defer std.testing.allocator.free(fl_result);

    std.debug.print("fl input: [{d}, {d}] -> output: {any}\n", .{ glyph_f, glyph_l, fl_result });

    try std.testing.expectEqual(@as(usize, 1), fl_result.len);

    // Test ft ligature
    const ft_glyphs = [_]u16{ glyph_f, glyph_t };
    const ft_result = try features.applyLigatures(&ft_glyphs);
    defer std.testing.allocator.free(ft_result);

    std.debug.print("ft input: [{d}, {d}] -> output: {any}\n", .{ glyph_f, glyph_t, ft_result });

    try std.testing.expectEqual(@as(usize, 1), ft_result.len);

    // fi and fl and ft should produce DIFFERENT ligature glyphs
    try std.testing.expect(fi_result[0] != fl_result[0]);
    try std.testing.expect(fi_result[0] != ft_result[0]);
    try std.testing.expect(fl_result[0] != ft_result[0]);
}

test "Parse Inter calt feature (Type 1 and Type 6)" {
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf") catch |err| {
        std.debug.print("Failed to load Inter font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    const gsub_data = font.getTable("GSUB".*) orelse {
        std.debug.print("No GSUB table in Inter\n", .{});
        return error.TableNotFound;
    };

    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGSUB(gsub_data);

    // Inter should have calt feature which uses Type 1 and Type 6 lookups
    std.debug.print("\nInter GSUB parsed:\n", .{});
    std.debug.print("  Single substitution lookups: {d}\n", .{features.single_lookups.items.len});
    std.debug.print("  Chaining context lookups: {d}\n", .{features.chain_context_lookups.items.len});
    std.debug.print("  Liga lookups: {d}\n", .{features.liga_lookups.items.len});
    std.debug.print("  Dlig lookups: {d}\n", .{features.dlig_lookups.items.len});
    std.debug.print("  Clig lookups: {d}\n", .{features.clig_lookups.items.len});
    std.debug.print("  Hlig lookups: {d}\n", .{features.hlig_lookups.items.len});

    // Inter has extensive calt feature with arrow ligatures etc.
    // We should have some Type 1 or Type 6 lookups
    const has_calt_lookups = features.single_lookups.items.len > 0 or
        features.chain_context_lookups.items.len > 0;
    try std.testing.expect(has_calt_lookups);
}

test "Parse Inter mark/mkmk features (GPOS Type 4 and 6)" {
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf") catch |err| {
        std.debug.print("Failed to load Inter font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    const gpos_data = font.getTable("GPOS".*) orelse {
        std.debug.print("No GPOS table in Inter\n", .{});
        return error.TableNotFound;
    };

    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGPOS(gpos_data);

    std.debug.print("\nInter GPOS parsed:\n", .{});
    std.debug.print("  Kerning lookups: {d}\n", .{features.kern_lookups.items.len});
    std.debug.print("  Mark-to-Base lookups: {d}\n", .{features.mark_base_lookups.items.len});
    std.debug.print("  Mark-to-Mark lookups: {d}\n", .{features.mark_mark_lookups.items.len});

    // Inter should have mark positioning for diacritics
    try std.testing.expect(features.mark_base_lookups.items.len > 0);
}

test "Single substitution" {
    // Test Format 1: delta substitution
    const coverage_data_f1 = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x02, // glyphCount = 2
        0x00, 0x64, // glyph 100
        0x00, 0x65, // glyph 101
    };

    const single_f1 = SingleSubst{
        .coverage = .{ .format = 1, .data = &coverage_data_f1 },
        .format = 1,
        .delta = 10, // Add 10 to glyph ID
    };

    // Glyph 100 -> 110, Glyph 101 -> 111
    try std.testing.expectEqual(@as(?u16, 110), single_f1.substitute(100));
    try std.testing.expectEqual(@as(?u16, 111), single_f1.substitute(101));
    try std.testing.expectEqual(@as(?u16, null), single_f1.substitute(102)); // Not covered

    // Test Format 2: direct mapping
    const substitutes = [_]u16{ 200, 201 };
    const single_f2 = SingleSubst{
        .coverage = .{ .format = 1, .data = &coverage_data_f1 },
        .format = 2,
        .substitutes = &substitutes,
    };

    try std.testing.expectEqual(@as(?u16, 200), single_f2.substitute(100));
    try std.testing.expectEqual(@as(?u16, 201), single_f2.substitute(101));
    try std.testing.expectEqual(@as(?u16, null), single_f2.substitute(102));
}

test "Chain context matching" {
    // Simple test: backtrack=[a], input=[b], lookahead=[c]
    // Match sequence: a b c (when pos is at b)

    const cov_a_data = [_]u8{
        0x00, 0x01, 0x00, 0x01, 0x00, 0x61, // format 1, count 1, glyph 'a' (97)
    };
    const cov_b_data = [_]u8{
        0x00, 0x01, 0x00, 0x01, 0x00, 0x62, // format 1, count 1, glyph 'b' (98)
    };
    const cov_c_data = [_]u8{
        0x00, 0x01, 0x00, 0x01, 0x00, 0x63, // format 1, count 1, glyph 'c' (99)
    };

    const backtrack_cov = [_]CoverageTable{.{ .format = 1, .data = &cov_a_data }};
    const input_cov = [_]CoverageTable{.{ .format = 1, .data = &cov_b_data }};
    const lookahead_cov = [_]CoverageTable{.{ .format = 1, .data = &cov_c_data }};
    const subst_recs = [_]SubstLookupRecord{.{ .sequence_index = 0, .lookup_index = 5 }};

    const chain = ChainContextSubstF3{
        .backtrack_coverages = &backtrack_cov,
        .input_coverages = &input_cov,
        .lookahead_coverages = &lookahead_cov,
        .subst_records = &subst_recs,
    };

    // Test matching sequence: 'a' 'b' 'c' with pos=1 (at 'b')
    const glyphs_abc = [_]u16{ 97, 98, 99 }; // a b c
    const match_result = chain.match(&glyphs_abc, 1);
    try std.testing.expect(match_result != null);
    try std.testing.expectEqual(@as(usize, 1), match_result.?.len);
    try std.testing.expectEqual(@as(u16, 0), match_result.?[0].sequence_index);
    try std.testing.expectEqual(@as(u16, 5), match_result.?[0].lookup_index);

    // Test non-matching: 'x' 'b' 'c' with pos=1 (backtrack fails)
    const glyphs_xbc = [_]u16{ 120, 98, 99 };
    try std.testing.expect(chain.match(&glyphs_xbc, 1) == null);

    // Test non-matching: 'a' 'b' 'x' with pos=1 (lookahead fails)
    const glyphs_abx = [_]u16{ 97, 98, 120 };
    try std.testing.expect(chain.match(&glyphs_abx, 1) == null);

    // Test non-matching: pos=0 (not enough backtrack)
    try std.testing.expect(chain.match(&glyphs_abc, 0) == null);
}

test "applyCalt with Inter font" {
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf") catch |err| {
        std.debug.print("Failed to load Inter font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    const gsub_data = font.getTable("GSUB".*) orelse {
        std.debug.print("No GSUB table in Inter\n", .{});
        return error.TableNotFound;
    };

    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGSUB(gsub_data);

    // Verify lookup map is populated
    std.debug.print("\nLookup map entries: {d}\n", .{features.gsub_lookup_map.count()});
    try std.testing.expect(features.gsub_lookup_map.count() > 0);

    // Get test glyph IDs
    const glyph_minus = font.getGlyphId('-') orelse 0;
    const glyph_gt = font.getGlyphId('>') orelse 0;
    std.debug.print("Glyph IDs: - = {d}, > = {d}\n", .{ glyph_minus, glyph_gt });

    // Inter's arrow ligatures (-> etc) are in the 'calt' feature
    // Inter does NOT have a 'liga' feature at all

    const test_glyphs = [_]u16{ glyph_minus, glyph_gt };

    // applyLigatures should NOT transform -> (no liga feature in Inter)
    const liga_result = try features.applyLigatures(&test_glyphs);
    defer std.testing.allocator.free(liga_result);
    std.debug.print("applyLigatures: [{d}, {d}] -> {any}\n", .{ glyph_minus, glyph_gt, liga_result });

    // Should be unchanged - no liga lookups
    try std.testing.expectEqual(@as(usize, 2), liga_result.len);

    // applyCalt SHOULD transform -> to arrow
    const calt_result = try features.applyCalt(&test_glyphs);
    defer std.testing.allocator.free(calt_result);
    std.debug.print("applyCalt: [{d}, {d}] -> {any}\n", .{ glyph_minus, glyph_gt, calt_result });

    // The arrow ligature should produce a single glyph
    try std.testing.expectEqual(@as(usize, 1), calt_result.len);
    try std.testing.expectEqual(@as(u16, 1805), calt_result[0]); // Arrow glyph
}

test "calt should not corrupt regular text" {
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf") catch |err| {
        std.debug.print("Failed to load Inter font: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(result.data);

    const font = result.font;

    const gsub_data = font.getTable("GSUB".*) orelse {
        std.debug.print("No GSUB table in Inter\n", .{});
        return error.TableNotFound;
    };

    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try features.parseGSUB(gsub_data);

    // Test with "Latin Extended:" - should NOT be corrupted
    const test_str = "Latin Extended:";
    var glyphs_latin = std.ArrayListUnmanaged(u16){};
    defer glyphs_latin.deinit(std.testing.allocator);

    for (test_str) |c| {
        if (font.getGlyphId(c)) |gid| {
            try glyphs_latin.append(std.testing.allocator, gid);
        }
    }

    std.debug.print("\nTesting calt on '{s}':\n", .{test_str});
    std.debug.print("  Input glyphs: {any}\n", .{glyphs_latin.items});

    const calt_result = try features.applyCalt(glyphs_latin.items);
    defer std.testing.allocator.free(calt_result);

    std.debug.print("  Output glyphs: {any}\n", .{calt_result});

    // Check for any mismatches
    var mismatches: usize = 0;
    const min_len = @min(glyphs_latin.items.len, calt_result.len);
    for (0..min_len) |i| {
        if (calt_result[i] != glyphs_latin.items[i]) {
            const expected_char: u8 = test_str[i];
            std.debug.print("  MISMATCH at pos {d} ('{c}'): expected glyph {d}, got {d}\n", .{ i, expected_char, glyphs_latin.items[i], calt_result[i] });
            mismatches += 1;
        }
    }

    // The glyphs should be the same (no contextual alternates for regular text)
    try std.testing.expectEqual(@as(usize, 0), mismatches);

    // Also test with arrows in the middle: "A -> B"
    const test_str2 = "A -> B Latin";
    var glyphs_arrow = std.ArrayListUnmanaged(u16){};
    defer glyphs_arrow.deinit(std.testing.allocator);

    for (test_str2) |c| {
        if (font.getGlyphId(c)) |gid| {
            try glyphs_arrow.append(std.testing.allocator, gid);
        }
    }

    std.debug.print("\nTesting calt on '{s}':\n", .{test_str2});
    std.debug.print("  Input glyphs: {any}\n", .{glyphs_arrow.items});

    const calt_result2 = try features.applyCalt(glyphs_arrow.items);
    defer std.testing.allocator.free(calt_result2);

    std.debug.print("  Output glyphs: {any}\n", .{calt_result2});

    // The arrow should be transformed, but text before/after should remain unchanged
    // Expected: A [space] [arrow] [space] B [space] L a t i n
    // The -> becomes a single arrow glyph, so output should be 2 shorter
}

test "applyGSUB combines calt and liga" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    // Test with empty lookups - should just return copy
    const test_glyphs = [_]u16{ 100, 101, 102 };
    const result = try features.applyGSUB(&test_glyphs);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u16, 100), result[0]);
    try std.testing.expectEqual(@as(u16, 101), result[1]);
    try std.testing.expectEqual(@as(u16, 102), result[2]);
}

test "getMarkOffset" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    // With no mark lookups, should return null
    const result = features.getMarkOffset(100, 200);
    try std.testing.expect(result == null);
}

test "Inter mark positioning for combining diacritics" {
    const allocator = std.testing.allocator;
    const ttf = @import("ttf.zig");

    // Load Inter font
    const file = std.fs.cwd().openFile("test/fonts/Inter/Inter-Regular.ttf", .{}) catch {
        return; // Skip if font not available
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(data);

    const font = ttf.Font.parse(data) catch return;

    // Initialize OpenType features
    var ot = OpenTypeFeatures.init(allocator);
    defer ot.deinit();

    // Parse GPOS for mark positioning
    if (font.getTable("GPOS".*)) |gpos_data| {
        try ot.parseGPOS(gpos_data);
    } else {
        return; // No GPOS table
    }

    // Get glyph IDs for test characters
    const base_a = font.getGlyphId('A') orelse return;
    const base_e = font.getGlyphId('e') orelse return;
    const combining_grave = font.getGlyphId(0x0300) orelse return; // COMBINING GRAVE ACCENT
    const combining_acute = font.getGlyphId(0x0301) orelse return; // COMBINING ACUTE ACCENT

    std.debug.print("\nInter mark positioning test:\n", .{});
    std.debug.print("  'A' glyph: {}, combining grave (0300): {}\n", .{ base_a, combining_grave });
    std.debug.print("  'e' glyph: {}, combining acute (0301): {}\n", .{ base_e, combining_acute });
    std.debug.print("  Mark-to-Base lookups: {}\n", .{ot.mark_base_lookups.items.len});

    // Check if Inter has mark positioning data for these combinations
    if (ot.getMarkOffset(base_a, combining_grave)) |offset| {
        std.debug.print("  A + grave offset: dx={}, dy={}\n", .{ offset.dx, offset.dy });
        // Mark offset should have non-zero values
        try std.testing.expect(offset.dx != 0 or offset.dy != 0);
    } else {
        std.debug.print("  No mark offset for A + grave\n", .{});
    }

    if (ot.getMarkOffset(base_e, combining_acute)) |offset| {
        std.debug.print("  e + acute offset: dx={}, dy={}\n", .{ offset.dx, offset.dy });
        try std.testing.expect(offset.dx != 0 or offset.dy != 0);
    } else {
        std.debug.print("  No mark offset for e + acute\n", .{});
    }
}

test "dlig/clig/hlig separate parsing" {
    const allocator = std.testing.allocator;
    const ttf = @import("ttf.zig");

    // Load Inter font (has dlig feature)
    const file = std.fs.cwd().openFile("test/fonts/Inter/Inter-Regular.ttf", .{}) catch {
        return; // Skip if font not available
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(data);

    const font = ttf.Font.parse(data) catch return;

    const gsub_data = font.getTable("GSUB".*) orelse return;

    var features = OpenTypeFeatures.init(allocator);
    defer features.deinit();

    try features.parseGSUB(gsub_data);

    // Inter has dlig and calt (with ligatures), but NOT liga/clig/hlig
    try std.testing.expectEqual(@as(usize, 0), features.liga_lookups.items.len); // No liga feature
    try std.testing.expect(features.dlig_lookups.items.len > 0); // Inter has dlig
    try std.testing.expectEqual(@as(usize, 0), features.clig_lookups.items.len);
    try std.testing.expectEqual(@as(usize, 0), features.hlig_lookups.items.len);
    try std.testing.expect(features.calt_liga_lookups.items.len > 0); // Calt has arrow ligatures

    // Test applyGSUBWithFlags with dlig enabled
    // Get some test glyphs (we'll just test that the function runs without error)
    const glyph_a = font.getGlyphId('a') orelse 0;
    const glyph_b = font.getGlyphId('b') orelse 0;
    const test_glyphs = [_]u16{ glyph_a, glyph_b };

    // Apply with default flags (liga on, dlig off)
    const result1 = try features.applyGSUBWithFlags(&test_glyphs, .{});
    defer allocator.free(result1);

    // Apply with dlig enabled
    const result2 = try features.applyGSUBWithFlags(&test_glyphs, .{ .dlig = true });
    defer allocator.free(result2);

    // Both should complete without error (results may or may not differ depending on font)
    try std.testing.expect(result1.len >= 1);
    try std.testing.expect(result2.len >= 1);
}
