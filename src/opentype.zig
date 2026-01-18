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

/// Ligature set - all ligatures starting with a particular glyph
pub const LigatureSet = struct {
    ligatures: []const Ligature,
};

/// Ligature substitution lookup (GSUB Lookup Type 4)
pub const LigatureSubst = struct {
    coverage: CoverageTable,
    ligature_sets: []const LigatureSet,

    /// Find a ligature match starting at the given position in the glyph sequence
    /// Returns the replacement glyph ID and number of glyphs consumed, or null if no match
    pub fn findLigature(self: LigatureSubst, glyphs: []const u16, pos: usize) ?struct { lig_glyph: u16, consumed: usize } {
        if (pos >= glyphs.len) return null;

        const first_glyph = glyphs[pos];
        const coverage_index = self.coverage.getCoverageIndex(first_glyph) orelse return null;

        if (coverage_index >= self.ligature_sets.len) return null;
        const lig_set = self.ligature_sets[coverage_index];

        // Try each ligature in the set (longer ones first typically)
        for (lig_set.ligatures) |lig| {
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

/// OpenType features parsed from a font
pub const OpenTypeFeatures = struct {
    allocator: std.mem.Allocator,

    // GSUB data
    gsub_data: ?[]const u8 = null,
    liga_lookups: std.ArrayListUnmanaged(LigatureSubst) = .{},

    // GPOS data
    gpos_data: ?[]const u8 = null,
    kern_lookups: std.ArrayListUnmanaged(PairPosLookup) = .{},

    // Allocated memory for ligature data
    ligature_memory: std.ArrayListUnmanaged([]const u16) = .{},
    ligature_set_memory: std.ArrayListUnmanaged([]const Ligature) = .{},
    ligature_structs: std.ArrayListUnmanaged(Ligature) = .{},
    ligature_sets: std.ArrayListUnmanaged(LigatureSet) = .{},

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
        self.kern_lookups.deinit(self.allocator);
    }

    /// Parse GSUB table from font data
    pub fn parseGSUB(self: *OpenTypeFeatures, gsub_data: []const u8) !void {
        self.gsub_data = gsub_data;
        try self.parseGSUBFeature(gsub_data, Feature.liga);
    }

    /// Parse GPOS table from font data
    pub fn parseGPOS(self: *OpenTypeFeatures, gpos_data: []const u8) !void {
        self.gpos_data = gpos_data;
        try self.parseGPOSFeature(gpos_data, Feature.kern);
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
                try self.parseLigatureLookup(data, lookup_list_offset, lookup_index);
            }
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
                try self.parseKernLookup(data, lookup_list_offset, lookup_index);
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

    fn parseLigatureLookup(self: *OpenTypeFeatures, data: []const u8, lookup_list_offset: u16, lookup_index: u16) !void {
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

        // Only process Lookup Type 4 (Ligature Substitution)
        if (lookup_type != 4) return;

        var i: u16 = 0;
        while (i < subtable_count) : (i += 1) {
            const st_offset_pos = lookup_table_offset + 6 + @as(usize, i) * 2;
            if (st_offset_pos + 2 > data.len) break;

            const subtable_offset = readU16(data, st_offset_pos);
            const subtable_addr = lookup_table_offset + subtable_offset;

            try self.parseLigatureSubtable(data, subtable_addr);
        }
    }

    fn parseLigatureSubtable(self: *OpenTypeFeatures, data: []const u8, offset: usize) !void {
        if (offset + 6 > data.len) return;

        const format = readU16(data, offset);
        if (format != 1) return; // Only format 1 supported

        const coverage_offset = readU16(data, offset + 2);
        const lig_set_count = readU16(data, offset + 4);

        // Parse coverage table
        const coverage_addr = offset + coverage_offset;
        if (coverage_addr + 4 > data.len) return;

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
                .ligatures = self.ligature_structs.items[ligs_start..],
            });
        }

        try self.liga_lookups.append(self.allocator, .{
            .coverage = coverage,
            .ligature_sets = self.ligature_sets.items[lig_sets_start..],
        });
    }

    fn parseKernLookup(self: *OpenTypeFeatures, data: []const u8, lookup_list_offset: u16, lookup_index: u16) !void {
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

        // Only process Lookup Type 2 (Pair Adjustment)
        if (lookup_type != 2) return;

        var i: u16 = 0;
        while (i < subtable_count) : (i += 1) {
            const st_offset_pos = lookup_table_offset + 6 + @as(usize, i) * 2;
            if (st_offset_pos + 2 > data.len) break;

            const subtable_offset = readU16(data, st_offset_pos);
            const subtable_addr = lookup_table_offset + subtable_offset;

            try self.parseKernSubtable(data, subtable_addr);
        }
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
                if (lookup.findLigature(glyphs, pos)) |match| {
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

    /// Get kerning adjustment between two glyphs
    pub fn getKerning(self: *OpenTypeFeatures, glyph1: u16, glyph2: u16) i16 {
        for (self.kern_lookups.items) |lookup| {
            const kern = lookup.getKerning(glyph1, glyph2);
            if (kern != 0) return kern;
        }
        return 0;
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
    const ligatures = [_]Ligature{.{
        .lig_glyph = 100,
        .components = &components,
    }};
    const lig_sets = [_]LigatureSet{.{
        .ligatures = &ligatures,
    }};

    // Coverage: only glyph 10 covered
    const coverage_data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x0A, // glyph[0] = 10
    };

    const lookup = LigatureSubst{
        .coverage = .{ .format = 1, .data = &coverage_data },
        .ligature_sets = &lig_sets,
    };

    const glyphs = [_]u16{ 10, 11, 12 };

    const result = lookup.findLigature(&glyphs, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 100), result.?.lig_glyph);
    try std.testing.expectEqual(@as(usize, 2), result.?.consumed);

    // No match at position 1
    try std.testing.expect(lookup.findLigature(&glyphs, 1) == null);
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
        .ligatures = features.ligature_structs.items[0..1],
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
        .ligature_sets = features.ligature_sets.items[0..1],
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
