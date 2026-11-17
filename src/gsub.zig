//! GSUB glyph substitution: every lookup type (single, multiple,
//! alternate, ligature, context, chained context, extension, reverse
//! chained), applied the way HarfBuzz does: the lookups of all enabled
//! features in lookup-list order, each over the whole run, honoring lookup
//! flags (ignore base/ligature/marks, mark attachment class, mark filtering
//! sets) through GDEF glyph classes.
//!
//! Tables are read in place from the font bytes; parsing only collects the
//! lookup headers, the feature -> lookup lists of the selected language
//! system, and a small bloom digest per lookup to skip glyphs it can't
//! apply to. Each shaped glyph carries the index of the code point it came
//! from (its cluster), so callers can map glyphs back to text: a ligature
//! takes the cluster of its first component and merges the span, the
//! glyphs a multiple substitution produces share the cluster of the source.
//!
//! Reference: https://learn.microsoft.com/en-us/typography/opentype/spec/gsub

const std = @import("std");
const opentype = @import("opentype.zig");
const unicode_props = @import("unicode_props.zig");

const Feature = opentype.Feature;
const FeatureFlags = opentype.FeatureFlags;
const CoverageTable = opentype.CoverageTable;
const ClassDef = opentype.ClassDef;

pub fn readU16(data: []const u8, offset: usize) u16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

pub fn readU32(data: []const u8, offset: usize) u32 {
    if (offset + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

pub fn coverageAt(data: []const u8, addr: usize) CoverageTable {
    if (addr + 4 > data.len) return .{ .format = 0, .data = &.{} };
    return .{ .format = readU16(data, addr), .data = data[addr..] };
}

pub fn classDefAt(data: []const u8, addr: usize) ClassDef {
    if (addr + 4 > data.len) return .{ .format = 0, .data = &.{} };
    return .{ .format = readU16(data, addr), .data = data[addr..] };
}

/// GDEF glyph classes
pub const GlyphClass = enum(u8) { unclassified = 0, base = 1, ligature = 2, mark = 3, component = 4, _ };

/// Glyph properties: GDEF class in the low byte, mark attachment class in
/// the high byte.
pub const Props = u16;
/// Not looked up yet: GDEF classes are read when a lookup flag needs them.
pub const props_unknown: Props = 0xFFFF;

/// Lookup flag bits
pub const ignore_base_glyphs: u16 = 0x0002;
pub const ignore_ligatures: u16 = 0x0004;
pub const ignore_marks: u16 = 0x0008;
const use_mark_filtering_set: u16 = 0x0010;
const mark_attachment_type_mask: u16 = 0xFF00;

/// Contexts nest lookups; fonts need a few levels, hostile ones loops.
pub const max_nesting = 8;
/// Matched input sequence length limit (HarfBuzz: HB_MAX_CONTEXT_LENGTH).
pub const max_context = 64;

/// GDEF: glyph classes, mark attachment classes, mark glyph sets.
pub const Gdef = struct {
    data: []const u8 = &.{},
    glyph_class: ?ClassDef = null,
    mark_attach_class: ?ClassDef = null,
    mark_glyph_sets: usize = 0, // offset of MarkGlyphSetsDef, 0 = none

    pub fn parse(data: []const u8) Gdef {
        if (data.len < 12) return .{};
        var g: Gdef = .{ .data = data };
        const class_off = readU16(data, 4);
        if (class_off != 0) g.glyph_class = classDefAt(data, class_off);
        const attach_off = readU16(data, 10);
        if (attach_off != 0) g.mark_attach_class = classDefAt(data, attach_off);
        // Version 1.2+: markGlyphSetsDefOffset at 12
        if (readU16(data, 2) >= 2 and data.len >= 14) g.mark_glyph_sets = readU16(data, 12);
        return g;
    }

    pub fn props(self: Gdef, gid: u16) Props {
        const class: u16 = if (self.glyph_class) |c| c.getClass(gid) else 0;
        if (class != @backingInt(GlyphClass.mark)) return class;
        const attach: u16 = if (self.mark_attach_class) |c| c.getClass(gid) else 0;
        return class | ((attach & 0xFF) << 8);
    }

    fn markSetCovers(self: Gdef, set_index: u16, gid: u16) bool {
        if (self.mark_glyph_sets == 0) return false;
        const base = self.mark_glyph_sets;
        if (readU16(self.data, base) != 1) return false;
        if (set_index >= readU16(self.data, base + 2)) return false;
        const off = readU32(self.data, base + 4 + @as(usize, set_index) * 4);
        if (off == 0) return false;
        return coverageAt(self.data, base + off).getCoverageIndex(gid) != null;
    }
};

/// Bloom digest of the glyphs a lookup's subtables cover (as HarfBuzz's
/// hb_set_digest): three 64-bit masks over different bit slices of the ID.
/// No false negatives, so a miss safely skips the lookup for a glyph.
pub const Digest = struct {
    masks: [3]u64 = .{ 0, 0, 0 },
    const shifts = [3]u4{ 0, 4, 9 };

    pub fn addGlyph(self: *Digest, gid: u16) void {
        inline for (shifts, 0..) |s, i| self.masks[i] |= @as(u64, 1) << @truncate(gid >> s);
    }

    fn addRange(self: *Digest, first: u16, last: u16) void {
        inline for (shifts, 0..) |s, i| {
            const a: u32 = first >> s;
            const b: u32 = last >> s;
            if (b - a >= 63) {
                self.masks[i] = std.math.maxInt(u64);
            } else {
                var v = a;
                while (v <= b) : (v += 1) self.masks[i] |= @as(u64, 1) << @truncate(v);
            }
        }
    }

    fn addCoverage(self: *Digest, cov: CoverageTable) void {
        const d = cov.data;
        const count = readU16(d, 2);
        switch (cov.format) {
            1 => for (0..count) |k| self.addGlyph(readU16(d, 4 + k * 2)),
            2 => for (0..count) |k| {
                const first = readU16(d, 4 + k * 6);
                const last = readU16(d, 4 + k * 6 + 2);
                if (last >= first) self.addRange(first, last);
            },
            else => {},
        }
    }

    fn add(self: *Digest, other: Digest) void {
        for (&self.masks, other.masks) |*m, o| m.* |= o;
    }

    pub fn mayIntersect(self: Digest, other: Digest) bool {
        inline for (self.masks, other.masks) |a, b| {
            if (a & b == 0) return false;
        }
        return true;
    }

    pub fn mayHave(self: Digest, gid: u16) bool {
        inline for (shifts, 0..) |s, i| {
            if (self.masks[i] & (@as(u64, 1) << @truncate(gid >> s)) == 0) return false;
        }
        return true;
    }
};

pub const Lookup = struct {
    /// Lookup type with extensions (7) resolved
    type: u16,
    flag: u16,
    mark_set: u16,
    /// Absolute offsets of the subtables in the GSUB data
    subtables: []const u32,
    /// Per subtable, the glyphs it may apply to; `digest` is their union
    subtable_digests: []const Digest,
    /// Ligature lookups: per subtable, the second components of its
    /// ligatures, so a glyph followed by none of them skips the subtable
    /// without a coverage search (Inter's ccmp composes base + mark, and
    /// text is mostly base + base)
    second_digests: []const Digest = &.{},
    digest: Digest,
    /// Lookups with many subtables (Inter's calt has 61): the subtables
    /// whose coverage holds each glyph, so a glyph tries only those
    index: ?SubtableIndex = null,
};

/// Exact glyph -> subtables map of a lookup, from the subtables' first
/// coverages. Sorted arrays: one binary search per glyph.
pub const SubtableIndex = struct {
    glyphs: []u16, // sorted, unique
    starts: []u32, // per glyph, into subs; glyphs.len + 1 entries
    subs: []u16, // subtable indices, ascending per glyph

    /// Built for lookups with at least this many subtables
    const min_subtables = 8;
    /// A hostile font's coverages could list every glyph in every
    /// subtable; past this many entries the lookup goes without
    const max_entries = 1 << 20;

    fn build(allocator: std.mem.Allocator, data: []const u8, kind: TableKind, lookup_type: u16, subtables: []const u32) !?SubtableIndex {
        var pairs: std.ArrayListUnmanaged(u32) = .empty; // glyph << 16 | subtable
        defer pairs.deinit(allocator);
        for (subtables, 0..) |addr, k| {
            const cov = firstCoverage(data, kind, lookup_type, addr);
            const d = cov.data;
            const count = readU16(d, 2);
            switch (cov.format) {
                1 => for (0..count) |j| {
                    try pairs.append(allocator, @as(u32, readU16(d, 4 + j * 2)) << 16 | @as(u32, @intCast(k)));
                },
                2 => for (0..count) |j| {
                    const first: u32 = readU16(d, 4 + j * 6);
                    const last: u32 = readU16(d, 4 + j * 6 + 2);
                    if (last < first) continue;
                    if (pairs.items.len + (last - first + 1) > max_entries) return null;
                    var g = first;
                    while (g <= last) : (g += 1) try pairs.append(allocator, g << 16 | @as(u32, @intCast(k)));
                },
                else => {},
            }
            if (pairs.items.len > max_entries) return null;
        }
        std.mem.sort(u32, pairs.items, {}, std.sort.asc(u32));

        var glyph_count: usize = 0;
        for (pairs.items, 0..) |p, j| {
            if (j == 0 or p >> 16 != pairs.items[j - 1] >> 16) glyph_count += 1;
        }
        const glyphs = try allocator.alloc(u16, glyph_count);
        errdefer allocator.free(glyphs);
        const starts = try allocator.alloc(u32, glyph_count + 1);
        errdefer allocator.free(starts);
        const subs = try allocator.alloc(u16, pairs.items.len);
        var n: usize = 0;
        for (pairs.items, 0..) |p, j| {
            if (j == 0 or p >> 16 != pairs.items[j - 1] >> 16) {
                glyphs[n] = @intCast(p >> 16);
                starts[n] = @intCast(j);
                n += 1;
            }
            subs[j] = @truncate(p);
        }
        starts[glyph_count] = @intCast(pairs.items.len);
        return .{ .glyphs = glyphs, .starts = starts, .subs = subs };
    }

    fn deinit(self: SubtableIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.starts);
        allocator.free(self.subs);
    }

    pub fn subtablesFor(self: SubtableIndex, gid: u16) []const u16 {
        var lo: usize = 0;
        var hi: usize = self.glyphs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.glyphs[mid] < gid) lo = mid + 1 else hi = mid;
        }
        if (lo == self.glyphs.len or self.glyphs[lo] != gid) return &.{};
        return self.subs[self.starts[lo]..self.starts[lo + 1]];
    }
};

/// GSUB and GPOS share their layout (script, feature and lookup lists);
/// they differ in the extension lookup type and what each type holds.
pub const TableKind = enum { gsub, gpos };

/// Parsed GSUB or GPOS table. Immutable after parse; shared by
/// per-document font clones. Slices point into the font bytes, which must
/// outlive it.
pub const Table = struct {
    kind: TableKind = .gsub,
    data: []const u8,
    gdef: Gdef,
    lookups: []Lookup,
    subtable_storage: []u32,
    digest_storage: []Digest,
    second_digest_storage: []Digest,
    /// Features of the default script (DFLT, else dflt, else latn)
    default: LangSysMap = .{},
    /// Features for Devanagari text (dev2, else deva, else the default's)
    devanagari: LangSysMap = .{},
    lookup_index_storage: []u16,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8, gdef_data: ?[]const u8, kind: TableKind) !Table {
        var t: Table = .{
            .kind = kind,
            .data = data,
            .gdef = if (gdef_data) |g| Gdef.parse(g) else .{},
            .lookups = &.{},
            .subtable_storage = &.{},
            .digest_storage = &.{},
            .second_digest_storage = &.{},
            .lookup_index_storage = &.{},
        };
        errdefer t.deinit(allocator);
        if (data.len < 10) return t;
        try t.parseLookups(allocator);
        try t.parseFeatures(allocator);
        return t;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.lookups) |l| if (l.index) |ix| ix.deinit(allocator);
        allocator.free(self.lookups);
        allocator.free(self.second_digest_storage);
        self.second_digest_storage = &.{};
        allocator.free(self.subtable_storage);
        allocator.free(self.digest_storage);
        allocator.free(self.lookup_index_storage);
        self.lookups = &.{};
        self.subtable_storage = &.{};
        self.digest_storage = &.{};
        self.lookup_index_storage = &.{};
    }

    fn parseLookups(self: *Table, allocator: std.mem.Allocator) !void {
        const data = self.data;
        const list: usize = readU16(data, 8);
        const count = readU16(data, list);
        const extension: u16 = if (self.kind == .gsub) 7 else 9;
        // Two passes: count subtables, then fill one shared array
        var total: usize = 0;
        for (0..count) |i| {
            const lt = list + readU16(data, list + 2 + i * 2);
            total += readU16(data, lt + 4);
        }
        self.lookups = try allocator.alloc(Lookup, count);
        self.subtable_storage = try allocator.alloc(u32, total);
        self.digest_storage = try allocator.alloc(Digest, total);
        var used: usize = 0;
        for (self.lookups, 0..) |*l, i| {
            const lt = list + readU16(data, list + 2 + i * 2);
            var lookup_type = readU16(data, lt);
            const flag = readU16(data, lt + 2);
            const sub_count = readU16(data, lt + 4);
            const subs = self.subtable_storage[used..][0..sub_count];
            const digests = self.digest_storage[used..][0..sub_count];
            used += sub_count;
            for (subs, 0..) |*s, k| {
                var addr = lt + readU16(data, lt + 6 + k * 2);
                if (lookup_type == extension) {
                    // Extension: format 1, real type, 32-bit offset
                    lookup_type = readU16(data, addr + 2);
                    addr += readU32(data, addr + 4);
                } else if (readU16(data, lt) == extension) {
                    // Later subtables of an extension lookup
                    addr += readU32(data, addr + 4);
                }
                s.* = @intCast(@min(addr, std.math.maxInt(u32)));
            }
            l.* = .{
                .type = lookup_type,
                .flag = flag,
                .mark_set = if (flag & use_mark_filtering_set != 0) readU16(data, lt + 6 + @as(usize, sub_count) * 2) else 0,
                .subtables = subs,
                .subtable_digests = digests,
                .digest = .{},
            };
            for (subs, digests) |addr, *dg| {
                dg.* = .{};
                dg.addCoverage(firstCoverage(data, self.kind, lookup_type, addr));
                l.digest.add(dg.*);
            }
        }
        // Second-component digests of the ligature subtables
        var lig_subtables: usize = 0;
        for (self.lookups) |l| {
            if (self.kind == .gsub and l.type == 4) lig_subtables += l.subtables.len;
        }
        self.second_digest_storage = try allocator.alloc(Digest, lig_subtables);
        var lig_used: usize = 0;
        for (self.lookups) |*l| {
            if (self.kind != .gsub or l.type != 4) continue;
            const digests = self.second_digest_storage[lig_used..][0..l.subtables.len];
            lig_used += l.subtables.len;
            for (l.subtables, digests) |addr, *dg| dg.* = secondComponents(data, addr);
            l.second_digests = digests;
        }
        // Separate pass: deinit frees every lookup's index, so all must be
        // initialized before one can fail
        for (self.lookups) |*l| {
            // (GSUB reverse chaining, type 8, runs backwards without one)
            if (l.subtables.len >= SubtableIndex.min_subtables and !(self.kind == .gsub and l.type == 8)) {
                l.index = try SubtableIndex.build(allocator, data, self.kind, l.type, l.subtables);
            }
        }
    }

    fn parseFeatures(self: *Table, allocator: std.mem.Allocator) !void {
        const data = self.data;
        const script_list: usize = readU16(data, 4);
        const default_tags = [_]u32{ tag("DFLT"), tag("dflt"), tag("latn") };
        const deva_tags = [_]u32{ tag("dev2"), tag("deva") } ++ default_tags;
        const default_script = selectScript(data, script_list, &default_tags);
        const deva_script = selectScript(data, script_list, &deva_tags);

        const default_ls = if (default_script) |sc| langSysOf(data, sc.offset) else null;
        const deva_ls = if (deva_script) |sc| langSysOf(data, sc.offset) else null;
        const shared = default_ls != null and deva_ls != null and default_ls.? == deva_ls.?;
        var total: usize = 0;
        if (default_ls) |ls| total += self.langSysLookupCount(ls);
        if (deva_ls) |ls| {
            if (!shared) total += self.langSysLookupCount(ls);
        }
        self.lookup_index_storage = try allocator.alloc(u16, total);
        var used: usize = 0;
        if (default_ls) |ls| {
            self.default.script = default_script.?.tag;
            used += self.fillLangSys(ls, &self.default, self.lookup_index_storage[used..]);
        }
        if (deva_ls) |ls| {
            if (shared) {
                self.devanagari = self.default;
            } else {
                used += self.fillLangSys(ls, &self.devanagari, self.lookup_index_storage[used..]);
            }
            self.devanagari.script = deva_script.?.tag;
        }
    }

    /// Lookup indices the features of the language system at `langsys` use.
    fn langSysLookupCount(self: *const Table, langsys: usize) usize {
        const data = self.data;
        const feature_list: usize = readU16(data, 6);
        const feature_count = readU16(data, feature_list);
        const index_count = readU16(data, langsys + 4);
        const required = readU16(data, langsys + 2);
        var total: usize = 0;
        for (0..@as(usize, index_count) + 1) |k| {
            const fi = if (k == index_count) required else readU16(data, langsys + 6 + k * 2);
            if (fi >= feature_count) continue;
            const ft = feature_list + readU16(data, feature_list + 2 + @as(usize, fi) * 6 + 4);
            total += readU16(data, ft + 2);
        }
        return total;
    }

    /// Fill `map` from the language system at `langsys`, its lookup
    /// indices into `storage`; returns how many it used.
    fn fillLangSys(self: *const Table, langsys: usize, map: *LangSysMap, storage: []u16) usize {
        const data = self.data;
        const feature_list: usize = readU16(data, 6);
        const feature_count = readU16(data, feature_list);
        const index_count = readU16(data, langsys + 4);
        const required = readU16(data, langsys + 2);
        var used: usize = 0;
        for (0..@as(usize, index_count) + 1) |k| {
            const is_required = k == index_count;
            const fi = if (is_required) required else readU16(data, langsys + 6 + k * 2);
            if (fi >= feature_count) continue;
            const record = feature_list + 2 + @as(usize, fi) * 6;
            const ft = feature_list + readU16(data, record + 4);
            const n = readU16(data, ft + 2);
            const indices = storage[used..][0..n];
            used += n;
            for (indices, 0..) |*li, j| li.* = readU16(data, ft + 4 + j * 2);
            if (is_required) {
                map.required_lookups = indices;
            } else if (Feature.fromTag(readU32(data, record))) |feature| {
                const slot = &map.feature_lookups[FeatureFlags.featureIndex(feature)];
                // A feature listed twice (rare): keep the first
                if (slot.len == 0) slot.* = indices;
            }
        }
        return used;
    }

    /// HarfBuzz's hb_ot_layout_lookup_would_substitute over `lookups`:
    /// would one of them substitute exactly this glyph sequence?
    /// `zero_context` refuses chain rules with backtrack or lookahead.
    pub fn wouldSubstitute(self: *const Table, lookups: []const LookupParams, glyphs: []const u16, zero_context: bool) bool {
        for (lookups) |lp| {
            if (self.wouldApply(lp.index, glyphs, zero_context)) return true;
        }
        return false;
    }

    fn wouldApply(self: *const Table, li: u16, glyphs: []const u16, zero_context: bool) bool {
        if (glyphs.len == 0 or li >= self.lookups.len) return false;
        const lookup = &self.lookups[li];
        if (!lookup.digest.mayHave(glyphs[0])) return false;
        const d = self.data;
        for (lookup.subtables) |addr| {
            const format = readU16(d, addr);
            const covered = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(glyphs[0]);
            const applies = switch (lookup.type) {
                1, 2, 3, 8 => glyphs.len == 1 and covered != null,
                4 => blk: {
                    const ci = covered orelse break :blk false;
                    if (format != 1 or ci >= readU16(d, addr + 4)) break :blk false;
                    const set = addr + readU16(d, addr + 6 + @as(usize, ci) * 2);
                    for (0..readU16(d, set)) |k| {
                        const lig = set + readU16(d, set + 2 + k * 2);
                        if (readU16(d, lig + 2) != glyphs.len) continue;
                        for (glyphs[1..], 0..) |g, j| {
                            if (readU16(d, lig + 4 + j * 2) != g) break;
                        } else break :blk true;
                    }
                    break :blk false;
                },
                5 => self.contextWouldApply(addr, glyphs),
                6 => self.chainWouldApply(addr, glyphs, zero_context),
                else => false,
            };
            if (applies) return true;
        }
        return false;
    }

    /// Does input value k (a glyph, class or coverage offset from `base`)
    /// accept `gid`?
    fn inputMatches(self: *const Table, kind: enum { glyph, class, coverage }, value: u16, class_def: ClassDef, base: usize, gid: u16) bool {
        return switch (kind) {
            .glyph => gid == value,
            .class => class_def.getClass(gid) == value,
            .coverage => coverageAt(self.data, base + value).getCoverageIndex(gid) != null,
        };
    }

    fn contextWouldApply(self: *const Table, addr: usize, glyphs: []const u16) bool {
        const d = self.data;
        switch (readU16(d, addr)) {
            1, 2 => |format| {
                const class_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 4)) else ClassDef{ .format = 0, .data = &.{} };
                const sets_at = if (format == 2) addr + 6 else addr + 4;
                const set_index: usize = if (format == 2)
                    class_def.getClass(glyphs[0])
                else
                    coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(glyphs[0]) orelse return false;
                if (set_index >= readU16(d, sets_at)) return false;
                const set_off = readU16(d, sets_at + 2 + set_index * 2);
                if (set_off == 0) return false;
                const set = addr + set_off;
                for (0..readU16(d, set)) |r| {
                    const rule = set + readU16(d, set + 2 + r * 2);
                    if (readU16(d, rule) != glyphs.len) continue;
                    for (glyphs[1..], 0..) |g, k| {
                        if (!self.inputMatches(if (format == 2) .class else .glyph, readU16(d, rule + 4 + k * 2), class_def, 0, g)) break;
                    } else return true;
                }
                return false;
            },
            3 => {
                if (readU16(d, addr + 2) != glyphs.len) return false;
                for (glyphs[1..], 1..) |g, k| {
                    if (!self.inputMatches(.coverage, readU16(d, addr + 6 + k * 2), .{ .format = 0, .data = &.{} }, addr, g)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    fn chainWouldApply(self: *const Table, addr: usize, glyphs: []const u16, zero_context: bool) bool {
        const d = self.data;
        switch (readU16(d, addr)) {
            1, 2 => |format| {
                const input_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 6)) else ClassDef{ .format = 0, .data = &.{} };
                const sets_at = if (format == 2) addr + 10 else addr + 4;
                const set_index: usize = if (format == 2)
                    input_def.getClass(glyphs[0])
                else
                    coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(glyphs[0]) orelse return false;
                if (set_index >= readU16(d, sets_at)) return false;
                const set_off = readU16(d, sets_at + 2 + set_index * 2);
                if (set_off == 0) return false;
                const set = addr + set_off;
                for (0..readU16(d, set)) |r| {
                    const rule = set + readU16(d, set + 2 + r * 2);
                    const back_count = readU16(d, rule);
                    const input_at = rule + 2 + @as(usize, back_count) * 2;
                    const input_count = readU16(d, input_at);
                    if (input_count != glyphs.len or input_count == 0) continue;
                    const ahead_count = readU16(d, input_at + 2 + (@as(usize, input_count) - 1) * 2);
                    if (zero_context and (back_count != 0 or ahead_count != 0)) continue;
                    for (glyphs[1..], 0..) |g, k| {
                        if (!self.inputMatches(if (format == 2) .class else .glyph, readU16(d, input_at + 2 + k * 2), input_def, 0, g)) break;
                    } else return true;
                }
                return false;
            },
            3 => {
                const back_count = readU16(d, addr + 2);
                const input_at = addr + 4 + @as(usize, back_count) * 2;
                const input_count = readU16(d, input_at);
                const ahead_count = readU16(d, input_at + 2 + @as(usize, input_count) * 2);
                if (zero_context and (back_count != 0 or ahead_count != 0)) return false;
                if (input_count != glyphs.len) return false;
                for (glyphs[1..], 1..) |g, k| {
                    if (!self.inputMatches(.coverage, readU16(d, input_at + 2 + k * 2), .{ .format = 0, .data = &.{} }, addr, g)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// The language system map for a script choice.
    pub fn langSys(self: *const Table, script: Script) *const LangSysMap {
        return switch (script) {
            .default => &self.default,
            .devanagari => &self.devanagari,
        };
    }

    /// Sorted, deduplicated lookup indices of the enabled features.
    pub fn collectLookups(self: *const Table, allocator: std.mem.Allocator, flags: FeatureFlags, out: *std.ArrayListUnmanaged(u16)) !void {
        return self.collectLookupsFor(allocator, &self.default, flags, out);
    }

    /// collectLookups for the language system of another script.
    pub fn collectLookupsFor(self: *const Table, allocator: std.mem.Allocator, map: *const LangSysMap, flags: FeatureFlags, out: *std.ArrayListUnmanaged(u16)) !void {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, map.required_lookups);
        for (map.feature_lookups, flags.flags) |indices, on| {
            if (on) try out.appendSlice(allocator, indices);
        }
        std.mem.sort(u16, out.items, {}, std.sort.asc(u16));
        var n: usize = 0;
        for (out.items) |li| {
            if (li >= self.lookups.len) continue;
            if (n > 0 and out.items[n - 1] == li) continue;
            out.items[n] = li;
            n += 1;
        }
        out.shrinkRetainingCapacity(n);
    }

    /// True if the feature has lookups in this font.
    pub fn hasFeature(self: *const Table, feature: Feature) bool {
        return self.default.feature_lookups[FeatureFlags.featureIndex(feature)].len > 0;
    }
};

/// Which script's language system shaping uses.
pub const Script = enum { default, devanagari };

/// Lookup indices per feature for one script's language system.
pub const LangSysMap = struct {
    /// The script tag found (0: the table has none of those tried)
    script: u32 = 0,
    /// Lookup indices per feature (FeatureFlags index)
    feature_lookups: [FeatureFlags.num_features][]const u16 = @splat(&.{}),
    /// The language system's required feature, applied always
    required_lookups: []const u16 = &.{},
};

pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// The first of `tags` the ScriptList has (HarfBuzz's script selection).
fn selectScript(data: []const u8, script_list: usize, tags: []const u32) ?struct { offset: usize, tag: u32 } {
    const count = readU16(data, script_list);
    for (tags) |want| {
        for (0..count) |i| {
            const rec = script_list + 2 + i * 6;
            if (rec + 6 > data.len) break;
            if (readU32(data, rec) == want) return .{ .offset = script_list + readU16(data, rec + 4), .tag = want };
        }
    }
    return null;
}

/// A script's default language system, else its first one.
fn langSysOf(data: []const u8, script: usize) ?usize {
    const default_off = readU16(data, script);
    if (default_off != 0) return script + default_off;
    if (readU16(data, script + 2) == 0) return null;
    return script + readU16(data, script + 4 + 4);
}

/// Digest of the second components of a ligature subtable's ligatures;
/// all glyphs if one has a single component.
fn secondComponents(data: []const u8, addr: usize) Digest {
    var dg: Digest = .{};
    const all: Digest = .{ .masks = @splat(std.math.maxInt(u64)) };
    if (readU16(data, addr) != 1) return all;
    const set_count = readU16(data, addr + 4);
    for (0..set_count) |k| {
        const set = addr + readU16(data, addr + 6 + k * 2);
        for (0..readU16(data, set)) |j| {
            const lig = set + readU16(data, set + 2 + j * 2);
            if (readU16(data, lig + 2) < 2) return all;
            dg.addGlyph(readU16(data, lig + 4));
        }
    }
    return dg;
}

/// Coverage of the first glyph a subtable applies to (for the digest).
/// GPOS types 1-6 have it at offset 2 (a mark lookup's: the marks'); its
/// context types 7 and 8 are GSUB's 5 and 6.
fn firstCoverage(data: []const u8, kind: TableKind, gsub_type: u16, addr: usize) CoverageTable {
    const format = readU16(data, addr);
    const lookup_type: u16 = switch (kind) {
        .gsub => gsub_type,
        .gpos => switch (gsub_type) {
            1...6 => 1,
            7 => 5,
            8 => 6,
            else => 0,
        },
    };
    return switch (lookup_type) {
        1, 2, 3, 4 => coverageAt(data, addr + readU16(data, addr + 2)),
        5 => switch (format) {
            1, 2 => coverageAt(data, addr + readU16(data, addr + 2)),
            3 => coverageAt(data, addr + readU16(data, addr + 6)),
            else => .{ .format = 0, .data = &.{} },
        },
        6 => switch (format) {
            1, 2 => coverageAt(data, addr + readU16(data, addr + 2)),
            3 => blk: {
                const backtrack = readU16(data, addr + 2);
                const input = addr + 4 + @as(usize, backtrack) * 2;
                break :blk coverageAt(data, addr + readU16(data, input + 2));
            },
            else => .{ .format = 0, .data = &.{} },
        },
        8 => coverageAt(data, addr + readU16(data, addr + 2)),
        else => .{ .format = 0, .data = &.{} },
    };
}

/// A shaped glyph: glyph ID and the index of the code point it came from.
pub const Glyph = struct {
    id: u16,
    cluster: u32,
    props: Props = 0,
    /// Ligature bookkeeping, as HarfBuzz's lig_props: a ligature formed
    /// here has a nonzero lig_id and its component count; a mark that was
    /// between or after its components gets the same lig_id and the
    /// (1-based) component it belongs to, so later lookups don't join
    /// marks of different components.
    lig_id: u8 = 0,
    lig_comp: u8 = 0,
    lig_comps: u8 = 0,
    /// Index of the code point this glyph was decoded from (never merged,
    /// unlike `cluster`)
    cp: u32 = 0,
    /// Default-ignorable code point (U+FE0F, ZWJ, soft hyphen...): may be
    /// skipped while matching, and is removed after shaping unless a
    /// lookup substituted it
    ignorable: Ignorable = .none,
    substituted: bool = false,
    /// Produced by a multiple substitution into two or more glyphs
    /// (HarfBuzz's MULTIPLIED glyph property): GPOS attaches marks to the
    /// first of them only
    multiplied: bool = false,
    /// A ligature substitution produced it (HarfBuzz's LIGATED)
    ligated: bool = false,
    /// Feature mask: lookups apply where theirs intersects it. Bit 0 is the
    /// global features'; the Indic shaper sets the others (indic.zig).
    mask: u8 = mask_global,
    /// Syllable (serial << 4 | type), for per-syllable lookups; 0 = none
    syllable: u8 = 0,
    /// Indic category and position (indic.zig), carried through
    /// substitutions as HarfBuzz carries its shaper variables
    indic_category: u8 = 0,
    indic_position: u8 = 0,
    /// Inserted by the shaper (a dotted circle), no character of its own
    inserted: bool = false,
    /// The code points (indices, [src_lo, src_hi)) this glyph was formed
    /// from: its own at first; a ligature's components' together; the
    /// first glyph of a multiple substitution keeps them, the others have
    /// none. Unlike `cluster`, never merged with neighbors.
    src_lo: u32 = 0,
    src_hi: u32 = 0,
};

/// HarfBuzz's merge_clusters: the range takes its smallest cluster,
/// extended over the neighbors that share an end's cluster value.
pub fn mergeClusters(items: []Glyph, start_in: usize, end_in: usize) void {
    var start = start_in;
    var end = end_in;
    if (end - start < 2) return;
    var cluster = items[start].cluster;
    for (items[start + 1 .. end]) |g| cluster = @min(cluster, g.cluster);
    if (cluster != items[end - 1].cluster) {
        while (end < items.len and items[end - 1].cluster == items[end].cluster) end += 1;
    }
    if (cluster != items[start].cluster) {
        while (start > 0 and items[start - 1].cluster == items[start].cluster) start -= 1;
    }
    for (items[start..end]) |*g| g.cluster = cluster;
}

/// HarfBuzz's delete_glyph, before glyph i is removed: its cluster
/// survives in a neighbor that shares it, else merges backward if smaller,
/// else (at the start) into the next glyph.
fn deleteGlyph(items: []Glyph, i: usize) void {
    const cluster = items[i].cluster;
    if ((i + 1 < items.len and cluster == items[i + 1].cluster) or (i > 0 and cluster == items[i - 1].cluster)) return;
    if (i > 0) {
        if (cluster < items[i - 1].cluster) {
            const old = items[i - 1].cluster;
            var k = i;
            while (k > 0 and items[k - 1].cluster == old) : (k -= 1) items[k - 1].cluster = cluster;
        }
        return;
    }
    if (i + 1 < items.len) mergeClusters(items, i, i + 2);
}

/// Glyph.mask bit of the global (always applied) features.
pub const mask_global: u8 = 1;

/// How a lookup applies, from the feature(s) it serves (HarfBuzz's
/// hb_ot_map_t::lookup_map_t): to glyphs whose mask intersects `mask`;
/// ZWJ/ZWNJ skipped automatically or not; within one syllable or not.
pub const LookupParams = struct {
    index: u16,
    mask: u8 = mask_global,
    auto_zwj: bool = true,
    auto_zwnj: bool = true,
    per_syllable: bool = false,
};

/// Default_Ignorable_Code_Point, as HarfBuzz classifies it. ZWJ and ZWNJ
/// are skipped under different rules; "hidden" ones (CGJ, Mongolian free
/// variation selectors, tag characters) are not skipped in GSUB at all.
/// Like HarfBuzz, U+115F, U+1160, U+3164, U+FFA0 and U+1BCA0..3 are not
/// treated as ignorable (fonts draw them as spacing glyphs).
pub const Ignorable = enum(u8) {
    none,
    zwj,
    zwnj,
    hidden,
    other,

    pub fn of(cp: u21) Ignorable {
        const ignorable = switch (cp >> 8) {
            0x00 => cp == 0x00AD,
            0x03 => cp == 0x034F,
            0x06 => cp == 0x061C,
            0x17 => cp == 0x17B4 or cp == 0x17B5,
            0x18 => cp >= 0x180B and cp <= 0x180F,
            0x20 => (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x206F),
            0xFE => (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF,
            0xFF => cp >= 0xFFF0 and cp <= 0xFFF8,
            else => (cp >= 0x1D173 and cp <= 0x1D17A) or (cp >= 0xE0000 and cp <= 0xE0FFF),
        };
        if (!ignorable) return .none;
        return switch (cp) {
            0x200D => .zwj,
            0x200C => .zwnj,
            0x034F, 0x180B...0x180D, 0x180F, 0xE0020...0xE007F => .hidden,
            else => .other,
        };
    }
};

/// Per-font-instance shaping state: the glyph buffer and the lookup list
/// for the last feature flags. Not shared between font clones.
pub const Shaper = struct {
    buf: std.ArrayListUnmanaged(Glyph) = .empty,
    active: std.ArrayListUnmanaged(u16) = .empty,
    active_flags: ?FeatureFlags = null,
    params: std.ArrayListUnmanaged(LookupParams) = .empty,
    next_lig_id: u8 = 0,
    input_len: usize = 0,
    any_ignorable: bool = false,
    /// Per input code point of the last shape call: true if it was a
    /// default ignorable that shaping removed (it has no glyph and belongs
    /// in no glyph's text)
    dropped: std.ArrayListUnmanaged(bool) = .empty,

    pub fn deinit(self: *Shaper, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.active.deinit(allocator);
        self.params.deinit(allocator);
        self.dropped.deinit(allocator);
    }

    /// Lookups the flags enable (cached per flags).
    pub fn activeLookups(self: *Shaper, allocator: std.mem.Allocator, table: *const Table, flags: FeatureFlags) ![]const u16 {
        if (self.active_flags) |f| {
            if (std.mem.eql(bool, &f.flags, &flags.flags)) return self.active.items;
        }
        self.active_flags = null;
        try table.collectLookups(allocator, flags, &self.active);
        self.active_flags = flags;
        return self.active.items;
    }

    /// Substitute `glyphs` (one per code point; cluster = index). The
    /// result is valid until the next call. `codepoints` (same length)
    /// classify glyphs as marks when the font has no GDEF classes, and as
    /// default ignorables: those are skipped while matching where
    /// HarfBuzz skips them, and removed afterwards (`dropped`).
    pub fn shape(
        self: *Shaper,
        allocator: std.mem.Allocator,
        table: *const Table,
        glyphs: []const u16,
        codepoints: ?[]const u21,
        flags: FeatureFlags,
    ) ![]const Glyph {
        return self.shapeClustered(allocator, table, glyphs, codepoints, null, flags);
    }

    /// `shape` with initial clusters (see `beginClustered`).
    pub fn shapeClustered(
        self: *Shaper,
        allocator: std.mem.Allocator,
        table: *const Table,
        glyphs: []const u16,
        codepoints: ?[]const u21,
        clusters: ?[]const u32,
        flags: FeatureFlags,
    ) ![]const Glyph {
        const lookups = try self.activeLookups(allocator, table, flags);
        try self.beginClustered(allocator, table, glyphs, codepoints, clusters);
        try self.params.resize(allocator, lookups.len);
        for (self.params.items, lookups) |*pp, li| pp.* = .{ .index = li };
        self.applyStage(table, self.params.items);
        return self.finish(allocator);
    }

    /// Fill the buffer for staged shaping: one glyph per code point
    /// (cluster = index), as `shape` starts.
    pub fn begin(self: *Shaper, allocator: std.mem.Allocator, table: *const Table, glyphs: []const u16, codepoints: ?[]const u21) !void {
        return self.beginClustered(allocator, table, glyphs, codepoints, null);
    }

    /// `begin` with initial clusters (code point indices, non-decreasing):
    /// HarfBuzz seeds them per grapheme before shaping.
    pub fn beginClustered(self: *Shaper, allocator: std.mem.Allocator, table: *const Table, glyphs: []const u16, codepoints: ?[]const u21, clusters: ?[]const u32) !void {
        self.buf.clearRetainingCapacity();
        self.next_lig_id = 0;
        self.input_len = glyphs.len;
        // Growth room for multiple substitutions; capped in applyMultiple
        try self.buf.ensureTotalCapacity(allocator, maxLen(glyphs.len));
        self.any_ignorable = false;
        for (glyphs, 0..) |gid, i| {
            var props = props_unknown;
            if (table.gdef.glyph_class == null) {
                // No GDEF classes: nonspacing marks (Mn) are marks, default
                // ignorables never (as HarfBuzz synthesizes them)
                const is_mark = if (codepoints) |cps| unicode_props.isNonspacingMark(cps[i]) and Ignorable.of(cps[i]) == .none else false;
                props = @backingInt(if (is_mark) GlyphClass.mark else GlyphClass.base);
            }
            const ignorable: Ignorable = if (codepoints) |cps| (if (cps[i] < 0xAD) .none else Ignorable.of(cps[i])) else .none;
            self.any_ignorable = self.any_ignorable or ignorable != .none;
            self.buf.appendAssumeCapacity(.{
                .id = gid,
                .cluster = if (clusters) |c| c[i] else @intCast(i),
                .cp = @intCast(i),
                .src_lo = @intCast(i),
                .src_hi = @intCast(i + 1),
                .props = props,
                .ignorable = ignorable,
            });
        }
    }

    /// Apply one stage's lookups (sorted by index) over the buffer.
    pub fn applyStage(self: *Shaper, table: *const Table, lookups: []const LookupParams) void {
        var ctx: Context = .{
            .table = table,
            .buf = &self.buf,
            .max_len = @max(maxLen(self.input_len), self.buf.items.len),
            .next_lig_id = self.next_lig_id,
        };
        // Lookups that cover no glyph of the run are skipped whole (as
        // HarfBuzz does); the run's digest is refreshed after a lookup
        // changed the run, since substitutes may bring new glyphs in
        var run: Digest = .{};
        for (self.buf.items) |g| run.addGlyph(g.id);
        for (lookups) |lp| {
            if (lp.index >= table.lookups.len) continue;
            if (!table.lookups[lp.index].digest.mayIntersect(run)) continue;
            ctx.params = lp;
            if (ctx.applyLookup(lp.index)) {
                run = .{};
                for (self.buf.items) |g| run.addGlyph(g.id);
            }
        }
        self.next_lig_id = ctx.next_lig_id;
    }

    /// End staged shaping: remove the default ignorables no lookup took up
    /// (HarfBuzz's REMOVE_DEFAULT_IGNORABLES; drawn they would be .notdef
    /// or a visible glyph for an invisible character).
    pub fn finish(self: *Shaper, allocator: std.mem.Allocator) ![]const Glyph {
        try self.dropped.resize(allocator, self.input_len);
        @memset(self.dropped.items, false);
        if (!self.any_ignorable) return self.buf.items;
        // HarfBuzz's delete_glyphs_inplace: a removed glyph's cluster
        // merges into its neighbors as delete_glyph does
        const items = self.buf.items;
        var n: usize = 0;
        for (items, 0..) |g, i| {
            if (g.ignorable != .none and !g.substituted and !g.inserted) {
                if (g.cp < self.dropped.items.len) self.dropped.items[g.cp] = true;
                const cluster = g.cluster;
                if (i + 1 < items.len and cluster == items[i + 1].cluster) continue;
                if (n > 0) {
                    if (cluster < items[n - 1].cluster) {
                        const old = items[n - 1].cluster;
                        var k = n;
                        while (k > 0 and items[k - 1].cluster == old) : (k -= 1) items[k - 1].cluster = cluster;
                    }
                    continue;
                }
                if (i + 1 < items.len) mergeClusters(items, i, i + 2);
                continue;
            }
            items[n] = items[i];
            n += 1;
        }
        self.buf.shrinkRetainingCapacity(n);
        return self.buf.items;
    }

    fn maxLen(n: usize) usize {
        return n * 8 + 64;
    }
};

pub const Context = struct {
    table: *const Table,
    buf: *std.ArrayListUnmanaged(Glyph),
    max_len: usize,
    next_lig_id: u8 = 0,
    /// The lookup being applied (nested lookups keep their parent's)
    params: LookupParams = .{ .index = 0 },
    /// Syllable of the glyph matching started at (per-syllable lookups)
    start_syllable: u8 = 0,

    pub fn data(self: *const Context) []const u8 {
        return self.table.data;
    }

    /// Is `gid` in the coverage table at `addr`?
    fn covers(self: *const Context, addr: usize, gid: u16) bool {
        return coverageAt(self.data(), addr).getCoverageIndex(gid) != null;
    }

    /// Apply a lookup over the run; true if it substituted anything.
    fn applyLookup(self: *Context, li: u16) bool {
        const lookup = &self.table.lookups[li];
        if (lookup.type == 8) return self.applyReverse(lookup);
        var applied = false;
        var i: usize = 0;
        while (i < self.buf.items.len) {
            if (lookup.digest.mayHave(self.buf.items[i].id) and self.buf.items[i].mask & self.params.mask != 0 and !self.skips(lookup, i)) {
                const len_before = self.buf.items.len;
                if (self.applyAt(lookup, li, i, 0)) |next| {
                    applied = true;
                    // Always move forward unless the buffer shrank at i
                    i = if (next > i or self.buf.items.len < len_before) next else i + 1;
                    continue;
                }
            }
            i += 1;
        }
        return applied;
    }

    pub fn propsOf(self: *Context, i: usize) Props {
        const g = &self.buf.items[i];
        if (g.props == props_unknown) g.props = self.table.gdef.props(g.id);
        return g.props;
    }

    pub fn classOf(self: *Context, i: usize) GlyphClass {
        return @fromBackingInt(@intCast(@as(u8, @truncate(self.propsOf(i)))));
    }

    /// Components of a ligature formed here, else 1.
    pub fn numComps(self: *Context, i: usize) u8 {
        const g = self.buf.items[i];
        return if (g.lig_comps > 0 and self.classOf(i) == .ligature) g.lig_comps else 1;
    }

    /// True if the lookup's flags make it ignore the glyph at i.
    pub fn skips(self: *Context, lookup: *const Lookup, i: usize) bool {
        const flag = lookup.flag;
        if (flag & (ignore_base_glyphs | ignore_ligatures | ignore_marks | use_mark_filtering_set | mark_attachment_type_mask) == 0) return false;
        const g = self.buf.items[i];
        const props = self.propsOf(i);
        switch (@as(GlyphClass, @fromBackingInt(@intCast(@as(u8, @truncate(props)))))) {
            .base => return flag & ignore_base_glyphs != 0,
            .ligature => return flag & ignore_ligatures != 0,
            .mark => {
                if (flag & ignore_marks != 0) return true;
                if (flag & use_mark_filtering_set != 0) return !self.table.gdef.markSetCovers(lookup.mark_set, g.id);
                if (flag & mark_attachment_type_mask != 0) return (props >> 8) != (flag >> 8);
                return false;
            },
            else => return false,
        }
    }

    /// HarfBuzz's may_skip: `yes` for glyphs the lookup flags ignore;
    /// `maybe` for default ignorables not yet substituted - skipped
    /// unless they match. ZWJ is always a maybe, ZWNJ only in backtrack
    /// and lookahead (so it blocks ligatures), hidden ones never.
    fn skipKind(self: *Context, lookup: *const Lookup, p: usize, context: bool) enum { no, yes, maybe } {
        if (self.skips(lookup, p)) return .yes;
        const g = self.buf.items[p];
        if (g.substituted) return .no;
        return switch (g.ignorable) {
            .none, .hidden => .no,
            .other => .maybe,
            .zwj => if (context or self.params.auto_zwj) .maybe else .no,
            .zwnj => if (context and self.params.auto_zwnj) .maybe else .no,
        };
    }

    /// HarfBuzz's may_match before the glyph test: input glyphs must carry
    /// the lookup's mask (context glyphs any), and a per-syllable lookup
    /// stays in the syllable matching started in.
    fn mayMatch(self: *const Context, p: usize, context: bool) bool {
        const g = self.buf.items[p];
        if (!context and g.mask & self.params.mask == 0) return false;
        if (self.params.per_syllable and self.start_syllable != 0 and g.syllable != self.start_syllable) return false;
        return true;
    }

    /// The next glyph from `from` in `dir` that the matcher accepts as
    /// item `k`, skipping what may be skipped; null if a glyph that may
    /// not be skipped doesn't match (HarfBuzz's skippy_iter).
    fn nextMatch(self: *Context, lookup: *const Lookup, m: Matcher, k: usize, from: usize, dir: Direction, context: bool) ?usize {
        var p = from;
        while (true) {
            if (dir == .back) {
                if (p == 0) return null;
                p -= 1;
            } else {
                p += 1;
                if (p >= self.buf.items.len) return null;
            }
            const kind = self.skipKind(lookup, p, context);
            if (kind == .yes) continue;
            if (self.mayMatch(p, context) and m.matches(self, k, self.buf.items[p].id)) return p;
            if (kind == .no) return null;
        }
    }

    const Direction = enum { back, ahead };

    /// What follows position i for a ligature's second component: a
    /// glyph that can't be skipped, nothing, or unknown (a skippable
    /// ignorable comes first, which might match or be skipped).
    const Follow = union(enum) { none, glyph: u16, unknown };

    fn following(self: *Context, lookup: *const Lookup, i: usize) Follow {
        var p = i + 1;
        while (p < self.buf.items.len) : (p += 1) {
            switch (self.skipKind(lookup, p, false)) {
                .yes => continue,
                .maybe => return .unknown,
                .no => return .{ .glyph = self.buf.items[p].id },
            }
        }
        return .none;
    }

    /// Try the lookup's subtables at position i; the first that applies
    /// wins. Returns the position to continue from.
    fn applyAt(self: *Context, lookup: *const Lookup, li: u16, i: usize, depth: u8) ?usize {
        const gid = self.buf.items[i].id;
        self.start_syllable = self.buf.items[i].syllable;
        // Ligatures: the glyph matching would compare second components to
        const second: Follow = if (lookup.type == 4) self.following(lookup, i) else .unknown;
        if (lookup.index) |index| {
            for (index.subtablesFor(gid)) |k| {
                if (lookup.type == 4 and !mayFollow(lookup.second_digests[k], second)) continue;
                if (self.applySubtable(lookup, li, lookup.subtables[k], i, depth)) |n| return n;
            }
            return null;
        }
        for (lookup.subtables, lookup.subtable_digests, 0..) |addr, digest, k| {
            if (!digest.mayHave(gid)) continue;
            if (lookup.type == 4 and !mayFollow(lookup.second_digests[k], second)) continue;
            if (self.applySubtable(lookup, li, addr, i, depth)) |n| return n;
        }
        return null;
    }

    /// Can a ligature subtable whose second components are `seconds`
    /// match when `second` follows? (Nothing follows: only
    /// single-component ligatures could, which make the digest full.)
    fn mayFollow(seconds: Digest, second: Follow) bool {
        return switch (second) {
            .glyph => |g| seconds.mayHave(g),
            .none => std.mem.allEqual(u64, &seconds.masks, std.math.maxInt(u64)),
            .unknown => true,
        };
    }

    fn applySubtable(self: *Context, lookup: *const Lookup, li: u16, addr: usize, i: usize, depth: u8) ?usize {
        return switch (lookup.type) {
            1 => self.applySingle(addr, i),
            2 => self.applyMultiple(addr, i),
            3 => self.applyAlternate(addr, i),
            4 => self.applyLigature(lookup, addr, i),
            5 => self.applyContext(lookup, li, addr, i, depth),
            6 => self.applyChainContext(lookup, li, addr, i, depth),
            else => null,
        };
    }

    fn replace(self: *Context, i: usize, gid: u16) void {
        const g = &self.buf.items[i];
        g.id = gid;
        g.substituted = true;
        if (self.table.gdef.glyph_class != null) g.props = props_unknown;
    }

    // Type 1
    fn applySingle(self: *Context, addr: usize, i: usize) ?usize {
        const d = self.data();
        const gid = self.buf.items[i].id;
        const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(gid) orelse return null;
        switch (readU16(d, addr)) {
            1 => self.replace(i, gid +% readU16(d, addr + 4)),
            2 => {
                if (ci >= readU16(d, addr + 4)) return null;
                self.replace(i, readU16(d, addr + 6 + @as(usize, ci) * 2));
            },
            else => return null,
        }
        return i + 1;
    }

    /// Multiple, alternate and ligature subtables (format 1): coverage,
    /// then one table per covered glyph. The address of the glyph at i's.
    fn setFor(self: *Context, addr: usize, i: usize) ?usize {
        const d = self.data();
        if (readU16(d, addr) != 1) return null;
        const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(self.buf.items[i].id) orelse return null;
        if (ci >= readU16(d, addr + 4)) return null;
        return addr + readU16(d, addr + 6 + @as(usize, ci) * 2);
    }

    // Type 2: one glyph -> a sequence (empty deletes it)
    fn applyMultiple(self: *Context, addr: usize, i: usize) ?usize {
        const d = self.data();
        const seq = self.setFor(addr, i) orelse return null;
        const n = readU16(d, seq);
        if (n == 0) {
            deleteGlyph(self.buf.items, i);
            _ = self.buf.orderedRemove(i);
            return i;
        }
        if (self.buf.items.len + n - 1 > self.max_len) return null;
        const src_class = self.classOf(i);
        const src = self.buf.items[i];
        for (0..n) |k| {
            var g = src;
            g.id = readU16(d, seq + 2 + k * 2);
            g.substituted = true;
            g.multiplied = n >= 2;
            if (self.table.gdef.glyph_class != null) {
                g.props = props_unknown;
            } else if (src_class == .ligature) {
                g.props = @backingInt(GlyphClass.base);
            }
            // Components of the sequence, unless attached to a ligature
            if (src.lig_id == 0) g.lig_comp = @truncate(k);
            // The source text goes with the first glyph
            if (k > 0) g.src_lo = g.src_hi;
            if (k == 0) self.buf.items[i] = g else self.buf.insertAssumeCapacity(i + k, g);
        }
        return i + n;
    }

    // Type 3: the first alternate (a feature enabled with value 1)
    fn applyAlternate(self: *Context, addr: usize, i: usize) ?usize {
        const d = self.data();
        const set = self.setFor(addr, i) orelse return null;
        if (readU16(d, set) == 0) return null;
        self.replace(i, readU16(d, set + 2));
        return i + 1;
    }

    // Type 4
    fn applyLigature(self: *Context, lookup: *const Lookup, addr: usize, i: usize) ?usize {
        const d = self.data();
        const set = self.setFor(addr, i) orelse return null;
        const lig_count = readU16(d, set);
        var positions: [max_context]usize = undefined;
        // Most ligatures of a set fail on their second component: compare
        // it first, against the glyph matching would reach
        const second = self.following(lookup, i);
        for (0..lig_count) |k| {
            const lig = set + readU16(d, set + 2 + k * 2);
            const comp_count = readU16(d, lig + 2);
            if (comp_count >= 2) switch (second) {
                .none => continue,
                .glyph => |g| if (readU16(d, lig + 4) != g) continue,
                .unknown => {},
            };
            if (!self.matchInput(lookup, .{ .kind = .glyph, .values = lig + 4 }, comp_count, false, i, &positions)) continue;
            self.ligate(readU16(d, lig), positions[0..comp_count]);
            return i + 1;
        }
        return null;
    }

    /// Replace the matched glyphs with a ligature (HarfBuzz's ligate):
    /// merge their clusters, give marks skipped between components the
    /// component they follow, and remove the components after the first.
    fn ligate(self: *Context, lig_glyph: u16, positions: []const usize) void {
        const items = self.buf.items;
        const i = positions[0];
        const last = positions[positions.len - 1];
        var is_mark_ligature = self.classOf(i) == .mark;
        var is_base_ligature = self.classOf(i) == .base;
        var total: usize = 0;
        for (positions, 0..) |p, k| {
            total += self.numComps(p);
            if (k > 0 and self.classOf(p) != .mark) {
                is_base_ligature = false;
                is_mark_ligature = false;
            }
        }
        const is_ligature = !is_base_ligature and !is_mark_ligature;
        var lig_id: u8 = 0;
        if (is_ligature) {
            self.next_lig_id +%= 1;
            if (self.next_lig_id == 0) self.next_lig_id = 1;
            lig_id = self.next_lig_id;
        }
        var last_lig_id = items[i].lig_id;
        var last_num_comps: usize = self.numComps(i);
        var so_far: usize = last_num_comps;

        // The ligature stands for its components' text (not the marks it
        // skipped, which keep theirs)
        var src_lo = items[i].src_lo;
        var src_hi = items[i].src_hi;
        for (positions[1..]) |p| {
            const c = items[p];
            if (c.src_lo == c.src_hi) continue;
            if (src_lo == src_hi) {
                src_lo = c.src_lo;
                src_hi = c.src_hi;
            } else {
                src_lo = @min(src_lo, c.src_lo);
                src_hi = @max(src_hi, c.src_hi);
            }
        }
        items[i].src_lo = src_lo;
        items[i].src_hi = src_hi;
        // Merge the clusters of the span (skipped marks included), as
        // HarfBuzz's ligate_input
        mergeClusters(items, i, last + 1);
        self.replace(i, lig_glyph);
        items[i].multiplied = false;
        items[i].ligated = true;
        if (is_ligature) {
            items[i].lig_id = lig_id;
            items[i].lig_comp = 0;
            items[i].lig_comps = @intCast(@min(total, 255));
            if (self.table.gdef.glyph_class == null) items[i].props = @backingInt(GlyphClass.ligature);
        }
        for (positions[1..], 1..) |p, k| {
            if (is_ligature) {
                for (items[positions[k - 1] + 1 .. p]) |*m| {
                    const this_comp: usize = if (m.lig_comp == 0) last_num_comps else m.lig_comp;
                    m.lig_id = lig_id;
                    m.lig_comp = @intCast(@min(so_far - last_num_comps + @min(this_comp, last_num_comps), 255));
                }
            }
            last_lig_id = items[p].lig_id;
            last_num_comps = self.numComps(p);
            so_far += last_num_comps;
        }
        if (!is_mark_ligature and last_lig_id != 0) {
            // Re-adjust components for any marks following
            for (items[last + 1 ..]) |*m| {
                if (m.lig_id != last_lig_id or m.lig_comp == 0) break;
                m.lig_id = lig_id;
                m.lig_comp = @intCast(@min(so_far - last_num_comps + @min(@as(usize, m.lig_comp), last_num_comps), 255));
            }
        }
        var c = positions.len - 1;
        while (c > 0) : (c -= 1) _ = self.buf.orderedRemove(positions[c]);
    }

    /// How a rule's u16 values match glyphs: as glyph IDs, classes in a
    /// ClassDef, or offsets (from `base`) to coverage tables.
    const Matcher = struct {
        kind: enum { glyph, class, coverage },
        values: usize, // offset of the u16 array
        class_def: ClassDef = .{ .format = 0, .data = &.{} },
        base: usize = 0,

        fn matches(m: Matcher, ctx: *Context, k: usize, gid: u16) bool {
            const d = ctx.data();
            const v = readU16(d, m.values + k * 2);
            return switch (m.kind) {
                .glyph => gid == v,
                .class => m.class_def.getClass(gid) == v,
                .coverage => ctx.covers(m.base + v, gid),
            };
        }
    };

    /// Match `count` input glyphs from i; `first_listed` says whether the
    /// matcher's values include the first glyph (format 3) or start at
    /// the second (formats 1, 2).
    ///
    /// Marks that belong to ligature components only match together when
    /// they belong to the same component (HarfBuzz's match_input).
    fn matchInput(self: *Context, lookup: *const Lookup, m: Matcher, count: usize, first_listed: bool, i: usize, positions: *[max_context]usize) bool {
        if (count == 0 or count > max_context) return false;
        const items = self.buf.items;
        if (first_listed and !m.matches(self, 0, items[i].id)) return false;
        const first = items[i];
        var ligbase: enum { unchecked, may_not_skip, may_skip } = .unchecked;
        positions[0] = i;
        for (1..count) |k| {
            const p = self.nextMatch(lookup, m, if (first_listed) k else k - 1, positions[k - 1], .ahead, false) orelse return false;
            const this = items[p];
            if (first.lig_id != 0 and first.lig_comp != 0) {
                // Attached to a ligature component: the others must be on
                // the same component, unless the ligature is skipped
                if (first.lig_id != this.lig_id or first.lig_comp != this.lig_comp) {
                    if (ligbase == .unchecked) {
                        var j = i;
                        var found = false;
                        while (j > 0 and items[j - 1].lig_id == first.lig_id) {
                            j -= 1;
                            if (items[j].lig_comp == 0) {
                                found = true;
                                break;
                            }
                        }
                        ligbase = if (found and self.skips(lookup, j)) .may_skip else .may_not_skip;
                    }
                    if (ligbase == .may_not_skip) return false;
                }
            } else if (this.lig_id != 0 and this.lig_comp != 0 and this.lig_id != first.lig_id) {
                // Not attached: the others may only be attached to the first
                return false;
            }
            positions[k] = p;
        }
        return true;
    }

    /// Match `count` context glyphs going back from `from` (backtrack,
    /// nearest first) or forward from it (lookahead).
    fn matchContext(self: *Context, lookup: *const Lookup, m: Matcher, count: usize, from: usize, dir: Direction) bool {
        var p = from;
        for (0..count) |k| {
            p = self.nextMatch(lookup, m, k, p, dir, true) orelse return false;
        }
        return true;
    }

    /// A context rule that matched: its input positions and the nested
    /// lookups (SequenceLookupRecords) to apply at them.
    pub const RuleMatch = struct {
        positions: [max_context]usize,
        count: usize,
        records: usize,
        record_count: usize,
    };

    // Type 5
    fn applyContext(self: *Context, lookup: *const Lookup, li: u16, addr: usize, i: usize, depth: u8) ?usize {
        var m = self.matchContextRule(lookup, addr, i) orelse return null;
        return self.applyRecords(li, &m.positions, m.count, m.records, m.record_count, depth);
    }

    // Type 6
    fn applyChainContext(self: *Context, lookup: *const Lookup, li: u16, addr: usize, i: usize, depth: u8) ?usize {
        var m = self.matchChainRule(lookup, addr, i) orelse return null;
        return self.applyRecords(li, &m.positions, m.count, m.records, m.record_count, depth);
    }

    /// The first rule of a context subtable (GSUB 5, GPOS 7) matching at i.
    pub fn matchContextRule(self: *Context, lookup: *const Lookup, addr: usize, i: usize) ?RuleMatch {
        const d = self.data();
        const format = readU16(d, addr);
        const gid = self.buf.items[i].id;
        var m: RuleMatch = .{ .positions = undefined, .count = 0, .records = 0, .record_count = 0 };
        switch (format) {
            1, 2 => {
                const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(gid) orelse return null;
                const class_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 4)) else ClassDef{ .format = 0, .data = &.{} };
                const sets_at = if (format == 2) addr + 6 else addr + 4;
                const set_index: usize = if (format == 2) class_def.getClass(gid) else ci;
                if (set_index >= readU16(d, sets_at)) return null;
                const set_off = readU16(d, sets_at + 2 + set_index * 2);
                if (set_off == 0) return null;
                const set = addr + set_off;
                for (0..readU16(d, set)) |r| {
                    const rule = set + readU16(d, set + 2 + r * 2);
                    const glyph_count = readU16(d, rule);
                    const record_count = readU16(d, rule + 2);
                    const matcher: Matcher = .{ .kind = if (format == 2) .class else .glyph, .values = rule + 4, .class_def = class_def };
                    if (!self.matchInput(lookup, matcher, glyph_count, false, i, &m.positions)) continue;
                    m.count = glyph_count;
                    m.records = rule + 4 + (@as(usize, glyph_count) - 1) * 2;
                    m.record_count = record_count;
                    return m;
                }
                return null;
            },
            3 => {
                const glyph_count = readU16(d, addr + 2);
                const matcher: Matcher = .{ .kind = .coverage, .values = addr + 6, .base = addr };
                if (!self.matchInput(lookup, matcher, glyph_count, true, i, &m.positions)) return null;
                m.count = glyph_count;
                m.records = addr + 6 + @as(usize, glyph_count) * 2;
                m.record_count = readU16(d, addr + 4);
                return m;
            },
            else => return null,
        }
    }

    /// The first rule of a chained context subtable (GSUB 6, GPOS 8)
    /// matching at i.
    pub fn matchChainRule(self: *Context, lookup: *const Lookup, addr: usize, i: usize) ?RuleMatch {
        const d = self.data();
        const format = readU16(d, addr);
        const gid = self.buf.items[i].id;
        var m: RuleMatch = .{ .positions = undefined, .count = 0, .records = 0, .record_count = 0 };
        switch (format) {
            1, 2 => {
                const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(gid) orelse return null;
                const none: ClassDef = .{ .format = 0, .data = &.{} };
                const back_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 4)) else none;
                const input_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 6)) else none;
                const ahead_def = if (format == 2) classDefAt(d, addr + readU16(d, addr + 8)) else none;
                const sets_at = if (format == 2) addr + 10 else addr + 4;
                const set_index: usize = if (format == 2) input_def.getClass(gid) else ci;
                if (set_index >= readU16(d, sets_at)) return null;
                const set_off = readU16(d, sets_at + 2 + set_index * 2);
                if (set_off == 0) return null;
                const set = addr + set_off;
                const kind: @FieldType(Matcher, "kind") = if (format == 2) .class else .glyph;
                for (0..readU16(d, set)) |r| {
                    const rule = set + readU16(d, set + 2 + r * 2);
                    const back_count = readU16(d, rule);
                    const input_at = rule + 2 + @as(usize, back_count) * 2;
                    const input_count = readU16(d, input_at);
                    if (input_count == 0) continue;
                    const ahead_at = input_at + 2 + (@as(usize, input_count) - 1) * 2;
                    const ahead_count = readU16(d, ahead_at);
                    const records_at = ahead_at + 2 + @as(usize, ahead_count) * 2;
                    const input: Matcher = .{ .kind = kind, .values = input_at + 2, .class_def = input_def };
                    if (!self.matchInput(lookup, input, input_count, false, i, &m.positions)) continue;
                    if (!self.matchContext(lookup, .{ .kind = kind, .values = rule + 2, .class_def = back_def }, back_count, i, .back)) continue;
                    if (!self.matchContext(lookup, .{ .kind = kind, .values = ahead_at + 2, .class_def = ahead_def }, ahead_count, m.positions[input_count - 1], .ahead)) continue;
                    m.count = input_count;
                    m.records = records_at + 2;
                    m.record_count = readU16(d, records_at);
                    return m;
                }
                return null;
            },
            3 => {
                const back_count = readU16(d, addr + 2);
                const input_at = addr + 4 + @as(usize, back_count) * 2;
                const input_count = readU16(d, input_at);
                const ahead_at = input_at + 2 + @as(usize, input_count) * 2;
                const ahead_count = readU16(d, ahead_at);
                const records_at = ahead_at + 2 + @as(usize, ahead_count) * 2;
                const input: Matcher = .{ .kind = .coverage, .values = input_at + 2, .base = addr };
                if (!self.matchInput(lookup, input, input_count, true, i, &m.positions)) return null;
                if (!self.matchContext(lookup, .{ .kind = .coverage, .values = addr + 4, .base = addr }, back_count, i, .back)) return null;
                if (!self.matchContext(lookup, .{ .kind = .coverage, .values = ahead_at + 2, .base = addr }, ahead_count, m.positions[input_count - 1], .ahead)) return null;
                m.count = input_count;
                m.records = records_at + 2;
                m.record_count = readU16(d, records_at);
                return m;
            },
            else => return null,
        }
    }

    /// Apply a context rule's nested lookups (SequenceLookupRecords) at
    /// the matched positions, in record order. A nested lookup that
    /// changes the buffer length shifts the later positions, as in
    /// HarfBuzz's apply_lookup. Returns the position after the input.
    fn applyRecords(self: *Context, li: u16, positions: *[max_context]usize, input_count: usize, records: usize, record_count: usize, depth: u8) usize {
        const d = self.data();
        var count = input_count;
        var end: isize = @intCast(positions[count - 1] + 1);
        if (depth >= max_nesting) return @intCast(end);
        for (0..record_count) |r| {
            const idx: usize = readU16(d, records + r * 4);
            const nested: u16 = readU16(d, records + r * 4 + 2);
            if (idx >= count or nested >= self.table.lookups.len) continue;
            // Don't recurse into ourselves at the same position
            if (r == 0 and nested == li) continue;
            const pos = positions[idx];
            if (pos >= self.buf.items.len) continue;
            const before: isize = @intCast(self.buf.items.len);
            const nested_lookup = &self.table.lookups[nested];
            if (nested_lookup.type == 8) continue; // reverse chaining is top-level only
            _ = self.applyAt(nested_lookup, nested, pos, depth + 1);
            var delta: isize = @as(isize, @intCast(self.buf.items.len)) - before;
            if (delta == 0) continue;

            end += delta;
            if (end < @as(isize, @intCast(pos))) {
                delta += @as(isize, @intCast(pos)) - end;
                end = @intCast(pos);
            }
            var next: isize = @intCast(idx + 1);
            if (delta > 0) {
                if (@as(isize, @intCast(count)) + delta > max_context) break;
            } else {
                delta = @max(delta, next - @as(isize, @intCast(count)));
                next -= delta;
            }
            // Move the positions from `next` on by delta entries
            const n: usize = @intCast(next);
            const new_next: usize = @intCast(next + delta);
            if (delta < 0) {
                std.mem.copyForwards(usize, positions[new_next..][0 .. count - n], positions[n..count]);
            } else {
                std.mem.copyBackwards(usize, positions[new_next..][0 .. count - n], positions[n..count]);
            }
            count = @intCast(@as(isize, @intCast(count)) + delta);
            // Inserted glyphs follow the substituted one
            for (idx + 1..new_next) |j| positions[j] = positions[j - 1] + 1;
            for (new_next..count) |j| positions[j] = @intCast(@as(isize, @intCast(positions[j])) + delta);
        }
        return @intCast(@max(end, 0));
    }

    // Type 8: single substitutions in context, applied end to start
    fn applyReverse(self: *Context, lookup: *const Lookup) bool {
        const d = self.data();
        var applied = false;
        var i = self.buf.items.len;
        while (i > 0) {
            i -= 1;
            const g = self.buf.items[i];
            if (!lookup.digest.mayHave(g.id) or g.mask & self.params.mask == 0 or self.skips(lookup, i)) continue;
            self.start_syllable = g.syllable;
            for (lookup.subtables, lookup.subtable_digests) |addr, digest| {
                if (!digest.mayHave(g.id) or readU16(d, addr) != 1) continue;
                const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(g.id) orelse continue;
                const back_count = readU16(d, addr + 4);
                const ahead_at = addr + 6 + @as(usize, back_count) * 2;
                const ahead_count = readU16(d, ahead_at);
                const subst_at = ahead_at + 2 + @as(usize, ahead_count) * 2;
                if (ci >= readU16(d, subst_at)) continue;
                if (!self.matchContext(lookup, .{ .kind = .coverage, .values = addr + 6, .base = addr }, back_count, i, .back)) continue;
                if (!self.matchContext(lookup, .{ .kind = .coverage, .values = ahead_at + 2, .base = addr }, ahead_count, i, .ahead)) continue;
                self.replace(i, readU16(d, subst_at + 2 + @as(usize, ci) * 2));
                applied = true;
                break;
            }
        }
        return applied;
    }
};

test "digest has no false negatives" {
    var d: Digest = .{};
    const glyphs = [_]u16{ 0, 1, 63, 64, 1000, 4095, 65535 };
    for (glyphs) |g| d.addGlyph(g);
    for (glyphs) |g| try std.testing.expect(d.mayHave(g));

    var r: Digest = .{};
    r.addRange(65500, 65535); // must not overflow at the top of the range
    r.addRange(100, 130);
    for (65500..65536) |g| try std.testing.expect(r.mayHave(@intCast(g)));
    for (100..131) |g| try std.testing.expect(r.mayHave(@intCast(g)));
    // Both hold 65535, so they must intersect
    try std.testing.expect(r.mayIntersect(d));
    // An empty digest has nothing
    const empty: Digest = .{};
    try std.testing.expect(!empty.mayHave(5));
}

test "subtable index lists exactly the subtables covering each glyph" {
    // Two single-substitution subtables (format 1): coverage {5, 7} and
    // {7, 9}, each followed by its coverage table
    var data: [64]u8 = @splat(0);
    const put = struct {
        fn f(buf: []u8, off: usize, v: u16) void {
            std.mem.writeInt(u16, buf[off..][0..2], v, .big);
        }
    }.f;
    // Subtable A at 0: format 1, coverage at +6, delta
    put(&data, 0, 1);
    put(&data, 2, 6);
    put(&data, 6, 1); // coverage format 1
    put(&data, 8, 2);
    put(&data, 10, 5);
    put(&data, 12, 7);
    // Subtable B at 20
    put(&data, 20, 1);
    put(&data, 22, 6);
    put(&data, 26, 1);
    put(&data, 28, 2);
    put(&data, 30, 7);
    put(&data, 32, 9);
    const index = (try SubtableIndex.build(std.testing.allocator, &data, .gsub, 1, &.{ 0, 20 })).?;
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u16, &.{0}, index.subtablesFor(5));
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, index.subtablesFor(7));
    try std.testing.expectEqualSlices(u16, &.{1}, index.subtablesFor(9));
    try std.testing.expectEqual(@as(usize, 0), index.subtablesFor(6).len);
    try std.testing.expectEqual(@as(usize, 0), index.subtablesFor(10).len);
}
