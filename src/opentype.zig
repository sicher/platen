//! OpenType features: the feature tags and flags shaping is configured
//! with, coverage and class tables, and a font's parsed GSUB, GPOS, GDEF
//! and 'kern' tables for the shaping engine (gsub.zig, gpos.zig).
//!
//! References:
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gsub
//! - OpenType spec: https://learn.microsoft.com/en-us/typography/opentype/spec/gpos

const std = @import("std");
const KernTable = @import("kern_table.zig").KernTable;
const gsub_mod = @import("gsub.zig");

/// GSUB of a font without one: shaping maps code points 1:1.
pub const empty_gsub: gsub_mod.Table = .{
    .data = &.{},
    .gdef = .{},
    .lookups = &.{},
    .subtable_storage = &.{},
    .digest_storage = &.{},
    .second_digest_storage = &.{},
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
    curs = tag("curs"), // Cursive Positioning
    dist = tag("dist"), // Distances
    abvm = tag("abvm"), // Above-base Mark Positioning
    blwm = tag("blwm"), // Below-base Mark Positioning
    rclt = tag("rclt"), // Required Contextual Alternates
    // Indic basic and presentation features: applied by the Indic shaper
    // (indic.zig) in its own stages, never by the default shaper
    nukt = tag("nukt"),
    akhn = tag("akhn"),
    rphf = tag("rphf"),
    rkrf = tag("rkrf"),
    pref = tag("pref"),
    blwf = tag("blwf"),
    abvf = tag("abvf"),
    half = tag("half"),
    pstf = tag("pstf"),
    vatu = tag("vatu"),
    cjct = tag("cjct"),
    init = tag("init"),
    pres = tag("pres"),
    abvs = tag("abvs"),
    blws = tag("blws"),
    psts = tag("psts"),
    haln = tag("haln"),
    // Hangul jamo features: the Hangul shaper (hangul.zig) applies them to
    // the jamo of the syllables it does not compose
    ljmo = tag("ljmo"),
    vjmo = tag("vjmo"),
    tjmo = tag("tjmo"),
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
            .ccmp, .locl, .rlig, .liga, .clig, .kern, .calt, .mark, .mkmk, .curs, .dist, .abvm, .blwm, .rclt => true,
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
        const count: usize = @min(readU16(self.data, 2), (self.data.len - 4) / 2);
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
        const count: usize = @min(readU16(self.data, 2), (self.data.len - 4) / 6);
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

/// OpenType features parsed from a font
pub const OpenTypeFeatures = struct {
    allocator: std.mem.Allocator,

    /// GSUB parsed for the engine (shared by FontFace clones)
    gsub: ?gsub_mod.Table = null,

    /// GDEF glyph classes (also for fonts with GPOS but no GSUB)
    gdef: gsub_mod.Gdef = .{},
    /// GPOS parsed for the engine (gpos.zig)
    gpos: ?gsub_mod.Table = null,
    /// The 'kern' table, for the shaping engine: set when there is no GPOS
    /// 'kern' feature (HarfBuzz's apply_kern)
    shaping_kern: ?KernTable = null,

    /// True on per-document clones of a FontFace: the parsed lookup
    /// tables are borrowed from the prototype and must not be freed here.
    borrowed_tables: bool = false,

    pub fn init(allocator: std.mem.Allocator) OpenTypeFeatures {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OpenTypeFeatures) void {
        // Per-document clones of a FontFace borrow the parsed tables;
        // only the prototype frees them
        if (self.borrowed_tables) return;
        if (self.gsub) |*g| g.deinit(self.allocator);
        if (self.gpos) |*g| g.deinit(self.allocator);
    }

    /// Parse the GSUB table (and GDEF glyph classes, which lookup flags
    /// need) from font data
    pub fn parseGSUB(self: *OpenTypeFeatures, gsub_data: []const u8, gdef_data: ?[]const u8) !void {
        if (self.gsub) |*g| g.deinit(self.allocator);
        self.gsub = null;
        self.gsub = try gsub_mod.Table.parse(self.allocator, gsub_data, gdef_data, .gsub);
    }

    /// Parse GPOS for the shaping engine (with the font's GDEF).
    pub fn parseGPOSTable(self: *OpenTypeFeatures, gpos_data: []const u8, gdef_data: ?[]const u8) !void {
        if (self.gpos) |*g| g.deinit(self.allocator);
        self.gpos = null;
        self.gpos = try gsub_mod.Table.parse(self.allocator, gpos_data, gdef_data, .gpos);
    }

    /// True if a layout table's FeatureList has `tag` under any script
    /// (HarfBuzz's hb_ot_layout_table_find_feature).
    pub fn tableHasFeatureTag(data: []const u8, tag_value: u32) bool {
        if (data.len < 10) return false;
        const list: usize = readU16(data, 6);
        const count = readU16(data, list);
        for (0..count) |i| {
            const rec = list + 2 + i * 6;
            if (rec + 4 > data.len) return false;
            if (std.mem.readInt(u32, data[rec..][0..4], .big) == tag_value) return true;
        }
        return false;
    }

    /// Get kerning adjustment between two glyphs (O(1) with lazy caching)
    const kern_cache_size = 4096; // power of two

};

// Helper functions
fn readU16(data: []const u8, offset: usize) u16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
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
    try std.testing.expect(features.gpos == null);
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

/// Parse `data` as GSUB and as GPOS for the engine and run every lookup
/// over a few glyphs: a hostile table must stay in bounds.
fn parseBoth(data: []const u8) !void {
    const a = std.testing.allocator;
    var ot = OpenTypeFeatures.init(a);
    defer ot.deinit();
    try ot.parseGSUB(data, data);
    try ot.parseGPOSTable(data, data);
    var shaper: gsub_mod.Shaper = .{};
    defer shaper.deinit(a);
    const glyphs = try shaper.shape(a, &ot.gsub.?, &.{ 0, 1, 2, 3, 0xFFFF }, null, FeatureFlags.initAllEnabled());
    const pos = try a.alloc(@import("gpos.zig").Position, glyphs.len);
    defer a.free(pos);
    @memset(pos, .{});
    var lookups: std.ArrayListUnmanaged(u16) = .empty;
    defer lookups.deinit(a);
    for (0..ot.gpos.?.lookups.len) |i| try lookups.append(a, @intCast(i));
    @import("gpos.zig").apply(&ot.gpos.?, shaper.buf.items, pos, lookups.items);
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

    try parseBoth(&data);
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

test "coverage tables longer than a u16 byte count do not overflow" {
    // 40,000 records: their byte length (240,000 / 80,000) is past u16
    const a = std.testing.allocator;
    for ([_]struct { u16, usize }{ .{ 2, 6 }, .{ 1, 2 } }) |c| {
        const n = 40000;
        const data = try a.alloc(u8, 4 + n * c[1]);
        defer a.free(data);
        @memset(data, 0);
        std.mem.writeInt(u16, data[0..2], c[0], .big);
        std.mem.writeInt(u16, data[2..4], n, .big);
        const cov: CoverageTable = .{ .format = c[0], .data = data };
        try std.testing.expectEqual(@as(?u16, null), cov.getCoverageIndex(5));
        // Format 1: glyph 0 is listed (all zero), at some index
        if (c[0] == 1) try std.testing.expect(cov.getCoverageIndex(0) != null);
    }
}
