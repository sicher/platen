//! OpenType Feature Support
//!
//! Parses GSUB (Glyph Substitution) and GPOS (Glyph Positioning) tables
//! for ligature support and kerning in OpenType/TrueType fonts.
//!
//! References:
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gsub
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gpos

const std = @import("std");
const KernTable = @import("kern_table.zig").KernTable;
const gsub_mod = @import("gsub.zig");

/// GSUB of a font without one: shaping maps code points 1:1.
const empty_gsub: gsub_mod.Table = .{
    .data = &.{},
    .gdef = .{},
    .lookups = &.{},
    .subtable_storage = &.{},
    .digest_storage = &.{},
    .second_digest_storage = &.{},
    .feature_lookups = @splat(&.{}),
    .required_lookups = &.{},
    .lookup_index_storage = &.{},
};

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
    tnum = tag("tnum"), // Tabular Figures
    pnum = tag("pnum"), // Proportional Figures
    frac = tag("frac"), // Fractions
    zero = tag("zero"), // Slashed Zero
    case_ = tag("case"), // Case-Sensitive Forms (case_ to avoid keyword)
    ccmp = tag("ccmp"), // Glyph Composition / Decomposition
    locl = tag("locl"), // Localized Forms
    rlig = tag("rlig"), // Required Ligatures
    // Stylistic Sets 1-20
    ss01 = tag("ss01"),
    ss02 = tag("ss02"),
    ss03 = tag("ss03"),
    ss04 = tag("ss04"),
    ss05 = tag("ss05"),
    ss06 = tag("ss06"),
    ss07 = tag("ss07"),
    ss08 = tag("ss08"),
    ss09 = tag("ss09"),
    ss10 = tag("ss10"),
    ss11 = tag("ss11"),
    ss12 = tag("ss12"),
    ss13 = tag("ss13"),
    ss14 = tag("ss14"),
    ss15 = tag("ss15"),
    ss16 = tag("ss16"),
    ss17 = tag("ss17"),
    ss18 = tag("ss18"),
    ss19 = tag("ss19"),
    ss20 = tag("ss20"),
    // Character Variants 1-99
    cv01 = tag("cv01"),
    cv02 = tag("cv02"),
    cv03 = tag("cv03"),
    cv04 = tag("cv04"),
    cv05 = tag("cv05"),
    cv06 = tag("cv06"),
    cv07 = tag("cv07"),
    cv08 = tag("cv08"),
    cv09 = tag("cv09"),
    cv10 = tag("cv10"),
    cv11 = tag("cv11"),
    cv12 = tag("cv12"),
    cv13 = tag("cv13"),
    cv14 = tag("cv14"),
    cv15 = tag("cv15"),
    cv16 = tag("cv16"),
    cv17 = tag("cv17"),
    cv18 = tag("cv18"),
    cv19 = tag("cv19"),
    cv20 = tag("cv20"),
    cv21 = tag("cv21"),
    cv22 = tag("cv22"),
    cv23 = tag("cv23"),
    cv24 = tag("cv24"),
    cv25 = tag("cv25"),
    cv26 = tag("cv26"),
    cv27 = tag("cv27"),
    cv28 = tag("cv28"),
    cv29 = tag("cv29"),
    cv30 = tag("cv30"),
    cv31 = tag("cv31"),
    cv32 = tag("cv32"),
    cv33 = tag("cv33"),
    cv34 = tag("cv34"),
    cv35 = tag("cv35"),
    cv36 = tag("cv36"),
    cv37 = tag("cv37"),
    cv38 = tag("cv38"),
    cv39 = tag("cv39"),
    cv40 = tag("cv40"),
    cv41 = tag("cv41"),
    cv42 = tag("cv42"),
    cv43 = tag("cv43"),
    cv44 = tag("cv44"),
    cv45 = tag("cv45"),
    cv46 = tag("cv46"),
    cv47 = tag("cv47"),
    cv48 = tag("cv48"),
    cv49 = tag("cv49"),
    cv50 = tag("cv50"),
    cv51 = tag("cv51"),
    cv52 = tag("cv52"),
    cv53 = tag("cv53"),
    cv54 = tag("cv54"),
    cv55 = tag("cv55"),
    cv56 = tag("cv56"),
    cv57 = tag("cv57"),
    cv58 = tag("cv58"),
    cv59 = tag("cv59"),
    cv60 = tag("cv60"),
    cv61 = tag("cv61"),
    cv62 = tag("cv62"),
    cv63 = tag("cv63"),
    cv64 = tag("cv64"),
    cv65 = tag("cv65"),
    cv66 = tag("cv66"),
    cv67 = tag("cv67"),
    cv68 = tag("cv68"),
    cv69 = tag("cv69"),
    cv70 = tag("cv70"),
    cv71 = tag("cv71"),
    cv72 = tag("cv72"),
    cv73 = tag("cv73"),
    cv74 = tag("cv74"),
    cv75 = tag("cv75"),
    cv76 = tag("cv76"),
    cv77 = tag("cv77"),
    cv78 = tag("cv78"),
    cv79 = tag("cv79"),
    cv80 = tag("cv80"),
    cv81 = tag("cv81"),
    cv82 = tag("cv82"),
    cv83 = tag("cv83"),
    cv84 = tag("cv84"),
    cv85 = tag("cv85"),
    cv86 = tag("cv86"),
    cv87 = tag("cv87"),
    cv88 = tag("cv88"),
    cv89 = tag("cv89"),
    cv90 = tag("cv90"),
    cv91 = tag("cv91"),
    cv92 = tag("cv92"),
    cv93 = tag("cv93"),
    cv94 = tag("cv94"),
    cv95 = tag("cv95"),
    cv96 = tag("cv96"),
    cv97 = tag("cv97"),
    cv98 = tag("cv98"),
    cv99 = tag("cv99"),

    fn tag(comptime s: *const [4]u8) u32 {
        return std.mem.readInt(u32, s, .big);
    }

    pub fn fromTag(t: u32) ?Feature {
        return std.enums.fromInt(Feature, t);
    }

    /// Returns true if this feature is enabled by default
    pub fn defaultEnabled(self: Feature) bool {
        // Stylistic sets and character variants are never enabled by default
        if (self.ssIndex() != null or self.cvIndex() != null) return false;
        return switch (self) {
            // HarfBuzz's defaults for horizontal text
            .ccmp, .locl, .rlig, .liga, .clig, .kern, .calt, .mark, .mkmk => true,
            else => false,
        };
    }

    /// Returns the stylistic set index (0-19) if this is a stylistic set feature, null otherwise
    pub fn ssIndex(self: Feature) ?usize {
        return switch (self) {
            .ss01 => 0,
            .ss02 => 1,
            .ss03 => 2,
            .ss04 => 3,
            .ss05 => 4,
            .ss06 => 5,
            .ss07 => 6,
            .ss08 => 7,
            .ss09 => 8,
            .ss10 => 9,
            .ss11 => 10,
            .ss12 => 11,
            .ss13 => 12,
            .ss14 => 13,
            .ss15 => 14,
            .ss16 => 15,
            .ss17 => 16,
            .ss18 => 17,
            .ss19 => 18,
            .ss20 => 19,
            else => null,
        };
    }

    /// All stylistic set features
    pub const stylistic_sets = [_]Feature{
        .ss01, .ss02, .ss03, .ss04, .ss05, .ss06, .ss07, .ss08, .ss09, .ss10,
        .ss11, .ss12, .ss13, .ss14, .ss15, .ss16, .ss17, .ss18, .ss19, .ss20,
    };

    /// Returns the character variant index (0-98) if this is a cv feature, null otherwise
    pub fn cvIndex(self: Feature) ?usize {
        return switch (self) {
            .cv01 => 0,
            .cv02 => 1,
            .cv03 => 2,
            .cv04 => 3,
            .cv05 => 4,
            .cv06 => 5,
            .cv07 => 6,
            .cv08 => 7,
            .cv09 => 8,
            .cv10 => 9,
            .cv11 => 10,
            .cv12 => 11,
            .cv13 => 12,
            .cv14 => 13,
            .cv15 => 14,
            .cv16 => 15,
            .cv17 => 16,
            .cv18 => 17,
            .cv19 => 18,
            .cv20 => 19,
            .cv21 => 20,
            .cv22 => 21,
            .cv23 => 22,
            .cv24 => 23,
            .cv25 => 24,
            .cv26 => 25,
            .cv27 => 26,
            .cv28 => 27,
            .cv29 => 28,
            .cv30 => 29,
            .cv31 => 30,
            .cv32 => 31,
            .cv33 => 32,
            .cv34 => 33,
            .cv35 => 34,
            .cv36 => 35,
            .cv37 => 36,
            .cv38 => 37,
            .cv39 => 38,
            .cv40 => 39,
            .cv41 => 40,
            .cv42 => 41,
            .cv43 => 42,
            .cv44 => 43,
            .cv45 => 44,
            .cv46 => 45,
            .cv47 => 46,
            .cv48 => 47,
            .cv49 => 48,
            .cv50 => 49,
            .cv51 => 50,
            .cv52 => 51,
            .cv53 => 52,
            .cv54 => 53,
            .cv55 => 54,
            .cv56 => 55,
            .cv57 => 56,
            .cv58 => 57,
            .cv59 => 58,
            .cv60 => 59,
            .cv61 => 60,
            .cv62 => 61,
            .cv63 => 62,
            .cv64 => 63,
            .cv65 => 64,
            .cv66 => 65,
            .cv67 => 66,
            .cv68 => 67,
            .cv69 => 68,
            .cv70 => 69,
            .cv71 => 70,
            .cv72 => 71,
            .cv73 => 72,
            .cv74 => 73,
            .cv75 => 74,
            .cv76 => 75,
            .cv77 => 76,
            .cv78 => 77,
            .cv79 => 78,
            .cv80 => 79,
            .cv81 => 80,
            .cv82 => 81,
            .cv83 => 82,
            .cv84 => 83,
            .cv85 => 84,
            .cv86 => 85,
            .cv87 => 86,
            .cv88 => 87,
            .cv89 => 88,
            .cv90 => 89,
            .cv91 => 90,
            .cv92 => 91,
            .cv93 => 92,
            .cv94 => 93,
            .cv95 => 94,
            .cv96 => 95,
            .cv97 => 96,
            .cv98 => 97,
            .cv99 => 98,
            else => null,
        };
    }

    /// All character variant features
    pub const character_variants = [_]Feature{
        .cv01, .cv02, .cv03, .cv04, .cv05, .cv06, .cv07, .cv08, .cv09, .cv10,
        .cv11, .cv12, .cv13, .cv14, .cv15, .cv16, .cv17, .cv18, .cv19, .cv20,
        .cv21, .cv22, .cv23, .cv24, .cv25, .cv26, .cv27, .cv28, .cv29, .cv30,
        .cv31, .cv32, .cv33, .cv34, .cv35, .cv36, .cv37, .cv38, .cv39, .cv40,
        .cv41, .cv42, .cv43, .cv44, .cv45, .cv46, .cv47, .cv48, .cv49, .cv50,
        .cv51, .cv52, .cv53, .cv54, .cv55, .cv56, .cv57, .cv58, .cv59, .cv60,
        .cv61, .cv62, .cv63, .cv64, .cv65, .cv66, .cv67, .cv68, .cv69, .cv70,
        .cv71, .cv72, .cv73, .cv74, .cv75, .cv76, .cv77, .cv78, .cv79, .cv80,
        .cv81, .cv82, .cv83, .cv84, .cv85, .cv86, .cv87, .cv88, .cv89, .cv90,
        .cv91, .cv92, .cv93, .cv94, .cv95, .cv96, .cv97, .cv98, .cv99,
    };
};

/// Feature enable/disable flags using a custom bitset (EnumArray exceeds comptime branch limit)
pub const FeatureFlags = struct {
    pub const num_features = @typeInfo(Feature).@"enum".field_values.len;
    flags: [num_features]bool,

    /// (tag value, field index) pairs sorted by tag value, built at comptime
    /// for O(log n) runtime lookup (a linear scan over ~150 features showed up
    /// as 30% of invoice-benchmark runtime).
    const Entry = struct { value: u32, index: u16 };
    const sorted_entries = blk: {
        @setEvalBranchQuota(100_000);
        const values = @typeInfo(Feature).@"enum".field_values;
        var entries: [values.len]Entry = undefined;
        for (values, 0..) |v, i| {
            entries[i] = .{ .value = v, .index = i };
        }
        // Insertion sort by tag value
        for (1..entries.len) |i| {
            const key = entries[i];
            var j = i;
            while (j > 0 and entries[j - 1].value > key.value) : (j -= 1) {
                entries[j] = entries[j - 1];
            }
            entries[j] = key;
        }
        break :blk entries;
    };

    /// Map a runtime Feature to its flags-array index via binary search.
    pub fn featureIndex(feature: Feature) usize {
        const value = @backingInt(feature);
        var lo: usize = 0;
        var hi: usize = sorted_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (sorted_entries[mid].value < value) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return sorted_entries[lo].index;
    }

    /// Comptime index of a feature (for building contiguous range scans).
    pub fn comptimeIndex(comptime feature: Feature) usize {
        @setEvalBranchQuota(100_000);
        const values = @typeInfo(Feature).@"enum".field_values;
        inline for (values, 0..) |v, i| {
            if (@backingInt(feature) == v) return i;
        }
        unreachable;
    }

    /// True if any flag in the contiguous field range [first, last] is set.
    /// Fields between first and last must be declared consecutively.
    pub fn anyEnabledInRange(self: FeatureFlags, comptime first: Feature, comptime last: Feature) bool {
        const lo = comptime comptimeIndex(first);
        const hi = comptime comptimeIndex(last);
        comptime std.debug.assert(lo <= hi);
        for (self.flags[lo .. hi + 1]) |f| {
            if (f) return true;
        }
        return false;
    }

    /// Initialize with default values (ccmp, locl, rlig, liga, clig, kern, calt,
    /// mark, mkmk enabled)
    pub fn init() FeatureFlags {
        var f: FeatureFlags = .{ .flags = @splat(false) };
        const values = @typeInfo(Feature).@"enum".field_values;
        inline for (values, 0..) |v, i| {
            const feat: Feature = @fromBackingInt(@intCast(v));
            f.flags[i] = feat.defaultEnabled();
        }
        return f;
    }

    /// Initialize with all features disabled
    pub fn initAllDisabled() FeatureFlags {
        return .{ .flags = @splat(false) };
    }

    /// Initialize with all features enabled
    pub fn initAllEnabled() FeatureFlags {
        return .{ .flags = @splat(true) };
    }

    pub fn isEnabled(self: FeatureFlags, feature: Feature) bool {
        return self.flags[featureIndex(feature)];
    }

    pub fn set(self: *FeatureFlags, feature: Feature, enabled: bool) void {
        self.flags[featureIndex(feature)] = enabled;
    }
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
        // Bound the array by the data once; the search then reads freely
        const count = @min(readU16(self.data, 2), (self.data.len - 4) / 2);
        const glyphs = self.data[4..][0 .. count * 2];

        // Binary search in sorted glyph array
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const gid = std.mem.readInt(u16, glyphs[mid * 2 ..][0..2], .big);
            if (gid < glyph_id) {
                lo = mid + 1;
            } else if (gid > glyph_id) {
                hi = mid;
            } else {
                return @intCast(mid); // Coverage index = position in array
            }
        }
        return null;
    }

    fn getCoverageIndexFormat2(self: CoverageTable, glyph_id: u16) ?u16 {
        if (self.data.len < 4) return null;
        const count = @min(readU16(self.data, 2), (self.data.len - 4) / 6);
        const ranges = self.data[4..][0 .. count * 6];

        // Binary search in range records
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = ranges[mid * 6 ..][0..6];
            const start_glyph = std.mem.readInt(u16, rec[0..2], .big);
            const end_glyph = std.mem.readInt(u16, rec[2..4], .big);

            if (glyph_id < start_glyph) {
                hi = mid;
            } else if (glyph_id > end_glyph) {
                lo = mid + 1;
            } else {
                const start_index = std.mem.readInt(u16, rec[4..6], .big);
                return std.math.cast(u16, @as(u32, start_index) + (glyph_id - start_glyph));
            }
        }
        return null;
    }

    /// Get the number of glyphs in this coverage
    /// usize: a coverage may list all 65,536 glyph IDs.
    pub fn getGlyphCount(self: CoverageTable) usize {
        if (self.data.len < 4) return 0;
        return switch (self.format) {
            1 => readU16(self.data, 2), // Format 1: glyph count at offset 2
            2 => blk: {
                // Format 2: sum of all range sizes
                const range_count = readU16(self.data, 2);
                var total: usize = 0;
                var i: u16 = 0;
                while (i < range_count) : (i += 1) {
                    const offset = 4 + @as(usize, i) * 6;
                    if (offset + 6 > self.data.len) break;
                    const start_glyph = readU16(self.data, offset);
                    const end_glyph = readU16(self.data, offset + 2);
                    if (end_glyph < start_glyph) continue; // malformed: empty
                    total += @as(usize, end_glyph - start_glyph) + 1;
                }
                break :blk total;
            },
            else => 0,
        };
    }

    /// Get glyph ID at a given coverage index
    pub fn getGlyphAt(self: CoverageTable, index: usize) ?u16 {
        if (self.data.len < 4) return null;
        return switch (self.format) {
            1 => blk: {
                // Format 1: direct array lookup
                const glyph_count = readU16(self.data, 2);
                if (index >= glyph_count) break :blk null;
                const offset = 4 + @as(usize, index) * 2;
                if (offset + 2 > self.data.len) break :blk null;
                break :blk readU16(self.data, offset);
            },
            2 => blk: {
                // Format 2: iterate through ranges
                const range_count = readU16(self.data, 2);
                var current_index: usize = 0;
                var i: u16 = 0;
                while (i < range_count) : (i += 1) {
                    const offset = 4 + @as(usize, i) * 6;
                    if (offset + 6 > self.data.len) break :blk null;
                    const start_glyph = readU16(self.data, offset);
                    const end_glyph = readU16(self.data, offset + 2);
                    if (end_glyph < start_glyph) continue; // malformed: empty
                    const range_size = @as(usize, end_glyph - start_glyph) + 1;
                    if (index < current_index + range_size) {
                        // <= end_glyph, so it fits u16
                        break :blk @intCast(start_glyph + (index - current_index));
                    }
                    current_index += range_size;
                }
                break :blk null;
            },
            else => null,
        };
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

        if (glyph_id < start_glyph or glyph_id >= @as(u32, start_glyph) + glyph_count) return 0;

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
        const pair_set_offset: usize = readU16(self.data, offset_pos);

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
    // i32: the difference of two i16 anchors can exceed i16.
    dx: i32,
    dy: i32,
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
            .dx = @as(i32, base_anchor.x) - mark_rec.anchor.x,
            .dy = @as(i32, base_anchor.y) - mark_rec.anchor.y,
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
            .dx = @as(i32, mark2_anchor.x) - mark1_rec.anchor.x,
            .dy = @as(i32, mark2_anchor.y) - mark1_rec.anchor.y,
        };
    }
};

/// OpenType features parsed from a font
pub const OpenTypeFeatures = struct {
    allocator: std.mem.Allocator,

    // GSUB: parsed table (shared by FontFace clones) and this instance's
    // shaping state
    gsub: ?gsub_mod.Table = null,
    shaper: gsub_mod.Shaper = .{},

    // GPOS data
    gpos_data: ?[]const u8 = null,
    kern_lookups: std.ArrayListUnmanaged(PairPosLookup) = .empty,
    /// Legacy 'kern' table, set only when GPOS has no kern lookups.
    legacy_kern: ?KernTable = null,
    mark_base_lookups: std.ArrayListUnmanaged(MarkBasePos) = .empty, // Type 4
    mark_mark_lookups: std.ArrayListUnmanaged(MarkMarkPos) = .empty, // Type 6

    // Kerning cache: (glyph1 << 16 | glyph2) -> kern value for O(1) lookup
    /// Direct-mapped kerning cache: keys are (glyph1 << 16 | glyph2), the
    /// sentinel 0xFFFFFFFF marks an empty slot (that pair just recomputes).
    /// A plain array beats a hash map here - getKerning runs per glyph pair
    /// in both measurement and rendering.
    kern_cache_keys: [kern_cache_size]u32 = @splat(0xFFFF_FFFF),
    kern_cache_values: [kern_cache_size]i16 = @splat(0),

    // Allocated memory for mark records
    mark_record_memory: std.ArrayListUnmanaged([]const MarkRecord) = .empty,

    /// True on per-document clones of a FontFace: the parsed lookup
    /// tables are borrowed from the prototype and must not be freed here.
    borrowed_tables: bool = false,

    pub fn init(allocator: std.mem.Allocator) OpenTypeFeatures {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OpenTypeFeatures) void {
        // Shaping state is always owned by this instance
        self.shaper.deinit(self.allocator);
        // Per-document clones of a FontFace borrow the parsed tables;
        // only the prototype frees them
        if (self.borrowed_tables) return;
        if (self.gsub) |*g| g.deinit(self.allocator);
        self.kern_lookups.deinit(self.allocator);

        // Free mark record memory
        for (self.mark_record_memory.items) |slice| {
            self.allocator.free(slice);
        }
        self.mark_record_memory.deinit(self.allocator);
        self.mark_base_lookups.deinit(self.allocator);
        self.mark_mark_lookups.deinit(self.allocator);
    }

    /// Parse the GSUB table (and GDEF glyph classes, which lookup flags
    /// need) from font data
    pub fn parseGSUB(self: *OpenTypeFeatures, gsub_data: []const u8, gdef_data: ?[]const u8) !void {
        if (self.gsub) |*g| g.deinit(self.allocator);
        self.gsub = null;
        self.gsub = try gsub_mod.Table.parse(self.allocator, gsub_data, gdef_data);
    }

    /// Parse GPOS table from font data
    pub fn parseGPOS(self: *OpenTypeFeatures, gpos_data: []const u8) !void {
        self.gpos_data = gpos_data;
        try self.parseGPOSFeature(gpos_data, Feature.kern);
        try self.parseGPOSFeature(gpos_data, Feature.mark);
        try self.parseGPOSFeature(gpos_data, Feature.mkmk);
    }

    fn parseGPOSFeature(self: *OpenTypeFeatures, data: []const u8, feature: Feature) !void {
        if (data.len < 10) return;

        const script_list_offset: usize = readU16(data, 4);
        const feature_list_offset: usize = readU16(data, 6);
        const lookup_list_offset: usize = readU16(data, 8);

        const feature_indices = try self.findFeatureIndices(data, script_list_offset, feature_list_offset, feature);
        defer self.allocator.free(feature_indices);

        if (feature_list_offset + 2 > data.len) return;
        const feature_count = readU16(data, feature_list_offset);

        for (feature_indices) |feat_idx| {
            if (feat_idx >= feature_count) continue;

            const feat_record_offset = feature_list_offset + 2 + @as(usize, feat_idx) * 6;
            if (feat_record_offset + 6 > data.len) continue;

            const feat_offset: usize = readU16(data, feat_record_offset + 4);
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

    fn parseGPOSLookup(self: *OpenTypeFeatures, data: []const u8, lookup_list_offset: usize, lookup_index: u16, feature: Feature) !void {
        if (lookup_list_offset + 2 > data.len) return;
        const lookup_count = readU16(data, lookup_list_offset);
        if (lookup_index >= lookup_count) return;

        const lookup_offset_pos = lookup_list_offset + 2 + @as(usize, lookup_index) * 2;
        if (lookup_offset_pos + 2 > data.len) return;
        const lookup_offset: usize = readU16(data, lookup_offset_pos);
        const lookup_table_offset = lookup_list_offset + lookup_offset;

        if (lookup_table_offset + 6 > data.len) return;

        const lookup_type = readU16(data, lookup_table_offset);
        const subtable_count = readU16(data, lookup_table_offset + 4);

        var i: u16 = 0;
        while (i < subtable_count) : (i += 1) {
            const st_offset_pos = lookup_table_offset + 6 + @as(usize, i) * 2;
            if (st_offset_pos + 2 > data.len) break;

            const subtable_offset: usize = readU16(data, st_offset_pos);
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
                    const ext_offset: usize = readU32(data, subtable_addr + 4);
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

    fn findFeatureIndices(self: *OpenTypeFeatures, data: []const u8, script_list_offset: usize, feature_list_offset: usize, target_feature: Feature) ![]u16 {
        var indices = std.ArrayListUnmanaged(u16).empty;
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
            if (feat_tag == @backingInt(target_feature)) {
                try indices.append(self.allocator, feat_idx);
            }
        }

        return indices.toOwnedSlice(self.allocator);
    }

    fn findScriptOffset(self: *OpenTypeFeatures, data: []const u8, script_list_offset: usize) ?usize {
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
            const offset: usize = readU16(data, record_offset + 4);

            if (script_tag == 0x44464C54) { // DFLT
                dflt_offset = script_list_offset + offset;
            } else if (script_tag == 0x6C61746E) { // latn
                latn_offset = script_list_offset + offset;
            }
        }

        return dflt_offset orelse latn_offset;
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

    /// Get kerning adjustment between two glyphs (O(1) with lazy caching)
    const kern_cache_size = 4096; // power of two

    fn kernCacheSlot(key: u32) usize {
        return (key *% 2654435761) >> (32 - 12); // Knuth multiplicative hash
    }

    pub fn getKerning(self: *OpenTypeFeatures, glyph1: u16, glyph2: u16) i16 {
        // O(1) cache lookup
        const key = (@as(u32, glyph1) << 16) | @as(u32, glyph2);
        const slot = kernCacheSlot(key);
        if (self.kern_cache_keys[slot] == key) {
            return self.kern_cache_values[slot];
        }

        // Cache miss - do the full lookup
        var kern: i16 = 0;
        for (self.kern_lookups.items) |lookup| {
            kern = lookup.getKerning(glyph1, glyph2);
            if (kern != 0) break;
        }
        if (self.legacy_kern) |*t| kern = t.get(glyph1, glyph2);

        // Cache the result (even if 0, to avoid repeated lookups);
        // colliding pairs simply overwrite each other
        self.kern_cache_keys[slot] = key;
        self.kern_cache_values[slot] = kern;
        return kern;
    }

    /// Apply all GSUB substitutions with the default feature flags
    pub fn applyGSUB(self: *OpenTypeFeatures, glyphs: []const u16) ![]u16 {
        return self.applyGSUBWithFlags(glyphs, FeatureFlags.init());
    }

    /// Glyph IDs after GSUB with explicit feature flags (caller owns them).
    pub fn applyGSUBWithFlags(self: *OpenTypeFeatures, glyphs: []const u16, flags: FeatureFlags) ![]u16 {
        return self.glyphIds(glyphs, null, flags);
    }

    /// Glyph IDs after GSUB (caller owns them); `codepoints` as in shape.
    pub fn glyphIds(self: *OpenTypeFeatures, glyphs: []const u16, codepoints: ?[]const u21, flags: FeatureFlags) ![]u16 {
        const shaped = try self.shape(glyphs, codepoints, flags);
        const out = try self.allocator.alloc(u16, shaped.len);
        for (out, shaped) |*o, g| o.* = g.id;
        return out;
    }

    /// GSUB with clusters: each glyph carries the index of the code point
    /// it came from. `codepoints` (optional, same length as `glyphs`) lets
    /// fonts without GDEF classes treat combining marks as marks. The
    /// result is valid until the next shaping call on this instance.
    pub fn shape(self: *OpenTypeFeatures, glyphs: []const u16, codepoints: ?[]const u21, flags: FeatureFlags) ![]const gsub_mod.Glyph {
        const table = if (self.gsub) |*g| g else &empty_gsub;
        return self.shaper.shape(self.allocator, table, glyphs, codepoints, flags);
    }

    /// True if any enabled feature has GSUB lookups in this font, i.e.
    /// shaping may change the glyph sequence.
    pub fn hasActiveGsub(self: *OpenTypeFeatures, flags: FeatureFlags) !bool {
        const table = if (self.gsub) |*g| g else return false;
        return (try self.shaper.activeLookups(self.allocator, table, flags)).len > 0;
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
    try std.testing.expectEqual(@as(u32, 0x6C696761), @backingInt(Feature.liga));
    try std.testing.expectEqual(@as(u32, 0x6B65726E), @backingInt(Feature.kern));

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

test "OpenTypeFeatures init and deinit" {
    var features = OpenTypeFeatures.init(std.testing.allocator);
    defer features.deinit();

    try std.testing.expect(features.gsub == null);
    try std.testing.expectEqual(@as(usize, 0), features.kern_lookups.items.len);
}

test "Parse Charter GPOS kerning" {
    // Charter font has GPOS kerning table
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Charter/Charter Regular.ttf") catch |err| {
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

test "Parse Inter mark/mkmk features (GPOS Type 4 and 6)" {
    const ttf = @import("ttf.zig");

    const result = ttf.Font.fromFile(std.testing.io, std.testing.allocator, "test/fonts/Inter/Inter-Regular.ttf") catch |err| {
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

    // Inter should have mark positioning for diacritics
    try std.testing.expect(features.mark_base_lookups.items.len > 0);
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
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(data);

    const font = try ttf.Font.parse(data);

    // Initialize OpenType features
    var ot = OpenTypeFeatures.init(allocator);
    defer ot.deinit();

    // Parse GPOS for mark positioning
    try ot.parseGPOS(font.getTable("GPOS".*) orelse return error.TestExpectedGpos);

    // Get glyph IDs for test characters
    const base_a = font.getGlyphId('A') orelse return error.TestExpectedGlyph;
    const base_e = font.getGlyphId('e') orelse return error.TestExpectedGlyph;
    const combining_grave = font.getGlyphId(0x0300) orelse return error.TestExpectedGlyph; // COMBINING GRAVE ACCENT
    const combining_acute = font.getGlyphId(0x0301) orelse return error.TestExpectedGlyph; // COMBINING ACUTE ACCENT
    try std.testing.expect(ot.mark_base_lookups.items.len > 0);

    // Inter's GPOS anchors (design units). Required, not optional: a missing
    // offset used to print "No mark offset" and pass.
    const a_grave = ot.getMarkOffset(base_a, combining_grave) orelse return error.TestExpectedMarkOffset;
    try std.testing.expectEqual(MarkOffset{ .dx = 292, .dy = 372 }, a_grave);
    const e_acute = ot.getMarkOffset(base_e, combining_acute) orelse return error.TestExpectedMarkOffset;
    try std.testing.expectEqual(MarkOffset{ .dx = 356, .dy = 0 }, e_acute);
}

// ----------------------------------------------------------------------------
// Overflow regression tests (2026-10-05 audit): offsets read as u16/u32 were
// added in their on-disk width. Each case panicked before the fix.
// ----------------------------------------------------------------------------

fn putU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .big);
}

fn putU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .big);
}

fn parseBoth(data: []const u8) !void {
    var gsub = OpenTypeFeatures.init(std.testing.allocator);
    defer gsub.deinit();
    try gsub.parseGSUB(data, data);
    // Shaping over a hostile table must stay in bounds too
    const glyphs = try gsub.applyGSUBWithFlags(&.{ 0, 1, 2, 3, 0xFFFF }, FeatureFlags.initAllEnabled());
    std.testing.allocator.free(glyphs);
    var gpos = OpenTypeFeatures.init(std.testing.allocator);
    defer gpos.deinit();
    try gpos.parseGPOS(data);
}

test "GSUB/GPOS header offsets near u16 max do not overflow" {
    for ([_]usize{ 4, 6, 8 }) |field| {
        for ([_]u16{ 0xFFFC, 0xFFFE, 0xFFFF }) |v| {
            var small: [10]u8 = @splat(0);
            putU16(&small, field, v);
            try parseBoth(&small);
        }
    }
}

test "GSUB/GPOS list offset + inner offset overflowing u16 does not panic" {
    const big = try std.testing.allocator.alloc(u8, 0x8100);
    defer std.testing.allocator.free(big);

    // ScriptList at 0x8000 whose DFLT script offset is 0x8000.
    @memset(big, 0);
    putU16(big, 4, 0x8000);
    putU16(big, 0x8000, 1); // scriptCount
    @memcpy(big[0x8002..0x8006], "DFLT");
    putU16(big, 0x8006, 0x8000);
    try parseBoth(big);

    // FeatureList at 0x8000 whose first feature table offset is 0x8000;
    // ScriptList at 0x10 points its default LangSys at feature index 0.
    @memset(big, 0);
    putU16(big, 4, 0x10);
    putU16(big, 6, 0x8000);
    putU16(big, 0x10, 1);
    @memcpy(big[0x12..0x16], "DFLT");
    putU16(big, 0x16, 0x08); // script table at 0x18
    putU16(big, 0x18, 4); // default LangSys at 0x1C
    putU16(big, 0x1C + 4, 1); // featureIndexCount
    putU16(big, 0x1C + 6, 0); // feature index 0
    putU16(big, 0x8000, 1); // featureCount
    @memcpy(big[0x8002..0x8006], "kern");
    putU16(big, 0x8006, 0x8000);
    try parseBoth(big);
    @memcpy(big[0x8002..0x8006], "liga");
    try parseBoth(big);

    // LookupList at 0x8000 whose lookup offset is 0x8000.
    @memset(big, 0);
    putU16(big, 8, 0x8000);
    putU16(big, 0x8000, 1); // lookupCount
    putU16(big, 0x8002, 0x8000);
    try parseBoth(big);

    // Lookup at 0x8000+0x10 whose subtable offset is 0x8000.
    putU16(big, 0x8002, 0x10);
    putU16(big, 0x8010, 9); // extension lookup type (GPOS)
    putU16(big, 0x8014, 1); // subTableCount
    putU16(big, 0x8016, 0x8000);
    try parseBoth(big);
}

test "GPOS extension offset near u32 max does not overflow" {
    var data: [64]u8 = @splat(0);
    putU16(&data, 4, 0x0A); // empty ScriptList
    putU16(&data, 6, 0x0C); // FeatureList with one kern feature
    putU16(&data, 8, 0x20); // LookupList
    putU16(&data, 0x0A, 1);
    putU16(&data, 0x0C, 1);
    @memcpy(data[0x0E..0x12], "kern");
    putU16(&data, 0x12, 0x08); // feature table at 0x14
    putU16(&data, 0x16, 1); // lookupIndexCount
    putU16(&data, 0x18, 0); // lookup 0
    putU16(&data, 0x20, 1); // lookupCount
    putU16(&data, 0x22, 0x04); // lookup at 0x24
    putU16(&data, 0x24, 9); // Extension positioning
    putU16(&data, 0x28, 1); // subTableCount
    putU16(&data, 0x2A, 0x08); // subtable at 0x2C
    putU16(&data, 0x2C, 1); // extension format
    putU16(&data, 0x2E, 2); // extension lookup type
    putU32(&data, 0x30, 0xFFFF_FFFF);

    var ot = OpenTypeFeatures.init(std.testing.allocator);
    defer ot.deinit();
    try ot.parseGPOSLookup(&data, 0x20, 0, .kern);
}

test "coverage format 2 arithmetic on hostile ranges" {
    var data: [10]u8 = @splat(0);
    putU16(&data, 0, 2);
    putU16(&data, 2, 1); // rangeCount
    putU16(&data, 4, 0x10); // start
    putU16(&data, 6, 0x20); // end
    putU16(&data, 8, 0xFFFF); // startCoverageIndex
    const cov = CoverageTable{ .format = 2, .data = &data };
    try std.testing.expectEqual(@as(?u16, 0xFFFF), cov.getCoverageIndex(0x10));
    try std.testing.expectEqual(@as(?u16, null), cov.getCoverageIndex(0x11)); // index > u16

    // end < start: an empty (malformed) range, not an underflow.
    putU16(&data, 4, 0x20);
    putU16(&data, 6, 0x10);
    try std.testing.expectEqual(@as(usize, 0), cov.getGlyphCount());
    try std.testing.expectEqual(@as(?u16, null), cov.getGlyphAt(0));

    // 0..0xFFFF covers all 65,536 glyphs.
    putU16(&data, 4, 0);
    putU16(&data, 6, 0xFFFF);
    try std.testing.expectEqual(@as(usize, 0x10000), cov.getGlyphCount());
    try std.testing.expectEqual(@as(?u16, 0xFFFF), cov.getGlyphAt(0xFFFF));
    try std.testing.expectEqual(@as(?u16, null), cov.getGlyphAt(0x10000));
}

test "class def format 1 range ending past u16" {
    var data: [8]u8 = @splat(0);
    putU16(&data, 0, 1);
    putU16(&data, 2, 0x8000); // startGlyph
    putU16(&data, 4, 0x8000); // glyphCount (ends at 0x10000)
    putU16(&data, 6, 7); // class of 0x8000
    const cd = ClassDef{ .format = 1, .data = &data };
    try std.testing.expectEqual(@as(u16, 7), cd.getClass(0x8000));
    try std.testing.expectEqual(@as(u16, 0), cd.getClass(0x9000)); // past data
}

test "pair set offset near u16 max" {
    var cov_data: [6]u8 = @splat(0);
    putU16(&cov_data, 0, 1);
    putU16(&cov_data, 2, 1);
    putU16(&cov_data, 4, 5); // covers glyph 5
    var data: [12]u8 = @splat(0);
    putU16(&data, 8, 1); // pairSetCount
    putU16(&data, 10, 0xFFFF); // pairSetOffset
    const pp = PairPosLookup{ .format = 1, .coverage = .{ .format = 1, .data = &cov_data }, .data = &data };
    try std.testing.expectEqual(@as(i16, 0), pp.getKerning(5, 6));
}

test "mark attachment with extreme anchors does not overflow" {
    var mark_cov: [6]u8 = @splat(0);
    putU16(&mark_cov, 0, 1);
    putU16(&mark_cov, 2, 1);
    putU16(&mark_cov, 4, 1);
    var base_cov: [6]u8 = @splat(0);
    putU16(&base_cov, 0, 1);
    putU16(&base_cov, 2, 1);
    putU16(&base_cov, 4, 2);
    var anchors: [10]u8 = @splat(0);
    putU16(&anchors, 0, 1); // baseCount
    putU16(&anchors, 2, 4); // anchor offset for class 0
    putU16(&anchors, 4, 1); // anchor format
    putU16(&anchors, 6, 0x7FFF); // x = 32767
    putU16(&anchors, 8, 0x7FFF); // y = 32767
    const records = [_]MarkRecord{.{ .mark_class = 0, .anchor = .{ .x = -32768, .y = -32768 } }};

    const mb = MarkBasePos{
        .mark_coverage = .{ .format = 1, .data = &mark_cov },
        .base_coverage = .{ .format = 1, .data = &base_cov },
        .mark_class_count = 1,
        .mark_records = &records,
        .base_anchors_data = &anchors,
        .base_count = 1,
        .base_array_offset = 0,
    };
    const off = mb.getAttachment(1, 2).?;
    try std.testing.expectEqual(@as(i32, 65535), off.dx);
    try std.testing.expectEqual(@as(i32, 65535), off.dy);

    const mm = MarkMarkPos{
        .mark1_coverage = .{ .format = 1, .data = &mark_cov },
        .mark2_coverage = .{ .format = 1, .data = &base_cov },
        .mark_class_count = 1,
        .mark1_records = &records,
        .mark2_anchors_data = &anchors,
        .mark2_count = 1,
        .mark2_array_offset = 0,
    };
    try std.testing.expectEqual(@as(i32, 65535), mm.getAttachment(1, 2).?.dx);
}
