//! GPOS glyph positioning, the way HarfBuzz does it: the lookups of all
//! enabled features in lookup-list order, each over the whole run, with
//! lookup flags through GDEF classes. Every lookup type: single, pair,
//! cursive, mark-to-base, mark-to-ligature, mark-to-mark, context, chained
//! context (extension resolved at parse). Then HarfBuzz's finishing steps
//! for the default shaper: GDEF marks lose their advance, and attached
//! glyphs take on the offsets of what they attach to.
//!
//! The table is a `gsub.Table` parsed as `.gpos` (the layout is GSUB's);
//! glyph classes, ligature components and the lookup-flag skipping come
//! from GSUB's output buffer and matcher. Values are font units; device
//! tables and variations are ignored (no hinting, default instance).
//!
//! Reference: https://learn.microsoft.com/en-us/typography/opentype/spec/gpos
//! and HarfBuzz's hb-ot-layout-gpos-table.hh, hb-ot-shape.cc.

const std = @import("std");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const KernTable = @import("kern_table.zig").KernTable;

const Glyph = gsub.Glyph;
const Table = gsub.Table;
const Lookup = gsub.Lookup;
const readU16 = gsub.readU16;
const coverageAt = gsub.coverageAt;
const classDefAt = gsub.classDefAt;

fn readI16(data: []const u8, offset: usize) i32 {
    return @as(i16, @bitCast(readU16(data, offset)));
}

/// A glyph's position, font units, y up (HarfBuzz's hb_glyph_position_t).
pub const Position = struct {
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// Relative index of the glyph this one is attached to (0: none)
    attach_chain: i32 = 0,
    attach_type: AttachType = .none,
};

pub const AttachType = enum(u2) { none, mark, cursive };

/// Applies the GPOS `lookups` (sorted indices, `Table.collectLookups`) to
/// `glyphs` (GSUB's output) and `pos` (their advances, offsets zero).
/// Allocation-free.
pub fn apply(table: *const Table, glyphs: []Glyph, pos: []Position, lookups: []const u16) void {
    applyCached(table, glyphs, pos, lookups, null);
}

/// The pair adjustment a PairPos lookup gives a glyph pair: which record
/// of which subtable (or none). Fixed for (lookup, first, second), so a
/// font's shaping cache remembers it (repeated pairs skip the coverage and
/// class searches).
pub const PairRecord = struct {
    found: bool,
    vf1: u16 = 0,
    vf2: u16 = 0,
    rec1: u32 = 0,
    rec2: u32 = 0,
};

pub const PairCache = struct {
    map: std.AutoHashMapUnmanaged(u64, PairRecord) = .empty,
    allocator: std.mem.Allocator,

    /// Entries kept before the cache starts over
    const max_entries = 1 << 16;

    pub fn deinit(self: *PairCache) void {
        self.map.deinit(self.allocator);
    }

    fn key(li: u16, first: u16, second: u16) u64 {
        return @as(u64, li) << 32 | @as(u64, first) << 16 | second;
    }

    fn put(self: *PairCache, k: u64, r: PairRecord) void {
        if (self.map.count() >= max_entries) self.map.clearRetainingCapacity();
        self.map.put(self.allocator, k, r) catch {}; // a cache: OOM only skips it
    }
};

/// `apply`, with PairPos results remembered in `cache` (one table's).
pub fn applyCached(table: *const Table, glyphs: []Glyph, pos: []Position, lookups: []const u16, cache: ?*PairCache) void {
    var list: std.ArrayListUnmanaged(Glyph) = .fromOwnedSlice(glyphs);
    var ctx: Ctx = .{
        .m = .{ .table = table, .buf = &list, .max_len = glyphs.len },
        .pos = pos,
        .pair_cache = cache,
    };
    var run: gsub.Digest = .{};
    for (glyphs) |g| run.addGlyph(g.id);
    for (lookups) |li| {
        const lookup = &table.lookups[li];
        if (!lookup.digest.mayIntersect(run)) continue;
        var i: usize = 0;
        while (i < glyphs.len) {
            if (lookup.digest.mayHave(glyphs[i].id) and !ctx.m.skips(lookup, i)) {
                if (ctx.applyAt(lookup, li, i, 0)) |next| {
                    i = @max(next, i + 1);
                    continue;
                }
            }
            i += 1;
        }
    }
}

/// HarfBuzz's legacy 'kern' table pass (hb_kern_machine_t), for fonts
/// whose GPOS has no kern feature: each glyph kerns with the next non-mark
/// glyph, half the value on each side.
pub fn applyKernTable(table: *const Table, kern: *const KernTable, glyphs: []Glyph, pos: []Position) void {
    var list: std.ArrayListUnmanaged(Glyph) = .fromOwnedSlice(glyphs);
    var m: gsub.Context = .{ .table = table, .buf = &list, .max_len = glyphs.len };
    const ignore: Lookup = ignoreLookup(gsub.ignore_marks, 0);
    var i: usize = 0;
    while (i < glyphs.len) {
        const j = nextIndex(&m, &ignore, i) orelse {
            i += 1;
            continue;
        };
        const value: i32 = kern.get(glyphs[i].id, glyphs[j].id);
        if (value != 0) {
            const half = value >> 1;
            pos[i].x_advance += half;
            pos[j].x_advance += value - half;
            pos[j].x_offset += value - half;
        }
        i = j;
    }
}

/// HarfBuzz's zero_mark_widths_by_gdef: marks (GDEF class, or Mn when the
/// font has no classes) get no advance. Fonts without GPOS shift the mark
/// back by its old advance, so it hangs over the glyph before it.
pub fn zeroMarkWidths(table: *const Table, glyphs: []Glyph, pos: []Position, adjust_offsets: bool) void {
    var list: std.ArrayListUnmanaged(Glyph) = .fromOwnedSlice(glyphs);
    var m: gsub.Context = .{ .table = table, .buf = &list, .max_len = glyphs.len };
    for (pos, 0..) |*p, i| {
        if (m.classOf(i) != .mark) continue;
        if (adjust_offsets) {
            p.x_offset -= p.x_advance;
            p.y_offset -= p.y_advance;
        }
        p.x_advance = 0;
        p.y_advance = 0;
    }
}

/// HarfBuzz's propagate_attachment_offsets (left to right): an attached
/// glyph's offset becomes relative to the pen, adding the offsets of what
/// it attaches to; a mark also subtracts the advances in between.
pub fn propagateAttachments(pos: []Position) void {
    for (0..pos.len) |i| propagate(pos, i, gsub.max_nesting * 8);
}

fn propagate(pos: []Position, i: usize, depth: usize) void {
    const chain = pos[i].attach_chain;
    if (chain == 0) return;
    pos[i].attach_chain = 0;
    const j_signed = @as(isize, @intCast(i)) + chain;
    if (j_signed < 0 or j_signed >= pos.len or depth == 0) return;
    const j: usize = @intCast(j_signed);
    propagate(pos, j, depth - 1);
    switch (pos[i].attach_type) {
        .cursive => pos[i].y_offset += pos[j].y_offset,
        .mark => {
            pos[i].x_offset += pos[j].x_offset;
            pos[i].y_offset += pos[j].y_offset;
            if (j < i) for (pos[j..i]) |p| {
                pos[i].x_offset -= p.x_advance;
                pos[i].y_offset -= p.y_advance;
            };
        },
        .none => {},
    }
}

/// A stand-in lookup with only these flags, for searches HarfBuzz makes
/// with other lookup properties than the lookup's own.
fn ignoreLookup(flag: u16, mark_set: u16) Lookup {
    return .{ .type = 0, .flag = flag, .mark_set = mark_set, .subtables = &.{}, .subtable_digests = &.{}, .digest = .{} };
}

/// The next glyph after `from` the lookup's flags don't skip.
fn nextIndex(m: *gsub.Context, lookup: *const Lookup, from: usize) ?usize {
    var p = from + 1;
    while (p < m.buf.items.len) : (p += 1) {
        if (!m.skips(lookup, p)) return p;
    }
    return null;
}

/// The glyph before `from` the lookup's flags don't skip.
fn prevIndex(m: *gsub.Context, lookup: *const Lookup, from: usize) ?usize {
    var p = from;
    while (p > 0) {
        p -= 1;
        if (!m.skips(lookup, p)) return p;
    }
    return null;
}

const Ctx = struct {
    /// GSUB's matcher over the same buffer: classes, flags, contexts
    m: gsub.Context,
    pos: []Position,
    pair_cache: ?*PairCache = null,

    fn data(self: *const Ctx) []const u8 {
        return self.m.table.data;
    }

    fn glyphs(self: *const Ctx) []Glyph {
        return self.m.buf.items;
    }

    /// Try the lookup's subtables at i; the first that applies wins.
    /// Returns where to continue.
    fn applyAt(self: *Ctx, lookup: *const Lookup, li: u16, i: usize, depth: u8) ?usize {
        const gid = self.glyphs()[i].id;
        if (lookup.type == 2) {
            if (self.pair_cache) |cache| return self.applyPairCached(cache, lookup, li, i);
        }
        if (lookup.index) |index| {
            for (index.subtablesFor(gid)) |k| {
                if (self.applySubtable(lookup, li, lookup.subtables[k], i, depth)) |n| return n;
            }
            return null;
        }
        for (lookup.subtables, lookup.subtable_digests) |addr, digest| {
            if (!digest.mayHave(gid)) continue;
            if (self.applySubtable(lookup, li, addr, i, depth)) |n| return n;
        }
        return null;
    }

    fn applySubtable(self: *Ctx, lookup: *const Lookup, li: u16, addr: usize, i: usize, depth: u8) ?usize {
        return switch (lookup.type) {
            1 => self.applySingle(addr, i),
            2 => self.applyPair(lookup, addr, i),
            3 => self.applyCursive(lookup, addr, i),
            4 => self.applyMarkBase(addr, i),
            5 => self.applyMarkLig(addr, i),
            6 => self.applyMarkMark(lookup, addr, i),
            7 => if (self.m.matchContextRule(lookup, addr, i)) |r| self.applyRecords(li, r, depth) else null,
            8 => if (self.m.matchChainRule(lookup, addr, i)) |r| self.applyRecords(li, r, depth) else null,
            else => null,
        };
    }

    /// A ValueRecord's size in bytes for `format`.
    fn valueSize(format: u16) usize {
        return @as(usize, @popCount(format & 0xFF)) * 2;
    }

    /// Adds a ValueRecord to a position (horizontal text: YAdvance does
    /// not apply; device tables are ignored).
    fn applyValue(self: *Ctx, format: u16, at: usize, p: *Position) void {
        const d = self.data();
        var o = at;
        if (format & 0x1 != 0) {
            p.x_offset += readI16(d, o);
            o += 2;
        }
        if (format & 0x2 != 0) {
            p.y_offset += readI16(d, o);
            o += 2;
        }
        if (format & 0x4 != 0) p.x_advance += readI16(d, o);
    }

    // Type 1
    fn applySingle(self: *Ctx, addr: usize, i: usize) ?usize {
        const d = self.data();
        const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(self.glyphs()[i].id) orelse return null;
        const format = readU16(d, addr + 4);
        switch (readU16(d, addr)) {
            1 => self.applyValue(format, addr + 6, &self.pos[i]),
            2 => {
                if (ci >= readU16(d, addr + 6)) return null;
                self.applyValue(format, addr + 8 + @as(usize, ci) * valueSize(format), &self.pos[i]);
            },
            else => return null,
        }
        return i + 1;
    }

    // Type 2. The second glyph is the next one the flags don't skip; the
    // run continues from it (after it, if it got a value record).
    fn applyPair(self: *Ctx, lookup: *const Lookup, addr: usize, i: usize) ?usize {
        const items = self.glyphs();
        const j = nextIndex(&self.m, lookup, i) orelse return null;
        const r = findPair(self.data(), addr, items[i].id, items[j].id);
        if (!r.found) return null;
        return self.applyPairRecord(r, i, j);
    }

    /// A PairPos lookup at i through the cache: the record found for
    /// (lookup, glyph, next glyph) in any subtable, searched once.
    fn applyPairCached(self: *Ctx, cache: *PairCache, lookup: *const Lookup, li: u16, i: usize) ?usize {
        const items = self.glyphs();
        const j = nextIndex(&self.m, lookup, i) orelse return null;
        const k = PairCache.key(li, items[i].id, items[j].id);
        const r = cache.map.get(k) orelse blk: {
            var found: PairRecord = .{ .found = false };
            const gid = items[i].id;
            if (lookup.index) |index| {
                for (index.subtablesFor(gid)) |sub| {
                    found = findPair(self.data(), lookup.subtables[sub], gid, items[j].id);
                    if (found.found) break;
                }
            } else for (lookup.subtables, lookup.subtable_digests) |addr, digest| {
                if (!digest.mayHave(gid)) continue;
                found = findPair(self.data(), addr, gid, items[j].id);
                if (found.found) break;
            }
            cache.put(k, found);
            break :blk found;
        };
        if (!r.found) return null;
        return self.applyPairRecord(r, i, j);
    }

    fn applyPairRecord(self: *Ctx, r: PairRecord, i: usize, j: usize) usize {
        self.applyValue(r.vf1, r.rec1, &self.pos[i]);
        self.applyValue(r.vf2, r.rec2, &self.pos[j]);
        return if (valueSize(r.vf2) != 0) j + 1 else j;
    }

    /// The record of PairPos subtable `addr` for (first, second), if any.
    fn findPair(d: []const u8, addr: usize, first: u16, second: u16) PairRecord {
        const none: PairRecord = .{ .found = false };
        const ci = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(first) orelse return none;
        const vf1 = readU16(d, addr + 4);
        const vf2 = readU16(d, addr + 6);
        const len1 = valueSize(vf1);
        const len2 = valueSize(vf2);
        switch (readU16(d, addr)) {
            1 => {
                if (ci >= readU16(d, addr + 8)) return none;
                const set = addr + readU16(d, addr + 10 + @as(usize, ci) * 2);
                const record_size = 2 + len1 + len2;
                // Records are sorted by second glyph
                var lo: usize = 0;
                var hi: usize = readU16(d, set);
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const rec = set + 2 + mid * record_size;
                    const g = readU16(d, rec);
                    if (g < second) {
                        lo = mid + 1;
                    } else if (g > second) {
                        hi = mid;
                    } else {
                        return .{ .found = true, .vf1 = vf1, .vf2 = vf2, .rec1 = @intCast(rec + 2), .rec2 = @intCast(rec + 2 + len1) };
                    }
                }
                return none;
            },
            2 => {
                const class1 = classDefAt(d, addr + readU16(d, addr + 8)).getClass(first);
                const class2 = classDefAt(d, addr + readU16(d, addr + 10)).getClass(second);
                const class1_count = readU16(d, addr + 12);
                const class2_count = readU16(d, addr + 14);
                if (class1 >= class1_count or class2 >= class2_count) return none;
                const rec = addr + 16 + (@as(usize, class1) * class2_count + class2) * (len1 + len2);
                return .{ .found = true, .vf1 = vf1, .vf2 = vf2, .rec1 = @intCast(rec), .rec2 = @intCast(rec + len1) };
            },
            else => return none,
        }
    }

    /// Anchor point (all formats: x, y first; contour points and device
    /// tables only matter when hinting).
    fn anchor(self: *const Ctx, at: usize) [2]i32 {
        const d = self.data();
        return .{ readI16(d, at + 2), readI16(d, at + 4) };
    }

    // Type 3, left to right: the previous glyph's exit meets this one's
    // entry; this glyph hangs off the previous one in y.
    fn applyCursive(self: *Ctx, lookup: *const Lookup, addr: usize, i: usize) ?usize {
        const d = self.data();
        if (readU16(d, addr) != 1) return null;
        const cov = coverageAt(d, addr + readU16(d, addr + 2));
        const count = readU16(d, addr + 4);
        const items = self.glyphs();
        const this_ci = cov.getCoverageIndex(items[i].id) orelse return null;
        if (this_ci >= count) return null;
        const entry_off = readU16(d, addr + 6 + @as(usize, this_ci) * 4);
        if (entry_off == 0) return null;
        const p = prevIndex(&self.m, lookup, i) orelse return null;
        const prev_ci = cov.getCoverageIndex(items[p].id) orelse return null;
        if (prev_ci >= count) return null;
        const exit_off = readU16(d, addr + 6 + @as(usize, prev_ci) * 4 + 2);
        if (exit_off == 0) return null;
        const exit = self.anchor(addr + exit_off);
        const entry = self.anchor(addr + entry_off);

        const pos = self.pos;
        pos[p].x_advance = exit[0] + pos[p].x_offset;
        const dx = entry[0] + pos[i].x_offset;
        pos[i].x_advance -= dx;
        pos[i].x_offset -= dx;

        // Child (this glyph, without RightToLeft) attaches to parent
        const right_to_left = lookup.flag & 0x0001 != 0;
        const child = if (right_to_left) p else i;
        const parent = if (right_to_left) i else p;
        const y_offset = if (right_to_left) entry[1] - exit[1] else exit[1] - entry[1];
        reverseCursive(pos, child, parent);
        pos[child].attach_type = .cursive;
        pos[child].attach_chain = @as(i32, @intCast(parent)) - @as(i32, @intCast(child));
        pos[child].y_offset = y_offset;
        // A parent attached to its child lets go
        if (pos[parent].attach_chain == -pos[child].attach_chain) {
            pos[parent].attach_chain = 0;
            pos[parent].y_offset = 0;
        }
        return i + 1;
    }

    /// HarfBuzz's reverse_cursive_minor_offset: a child already attached
    /// elsewhere turns its old chain around to hang from it.
    fn reverseCursive(pos: []Position, i: usize, new_parent: usize) void {
        reverseCursiveAt(pos, i, new_parent, pos.len);
    }

    fn reverseCursiveAt(pos: []Position, i: usize, new_parent: usize, depth: usize) void {
        const chain = pos[i].attach_chain;
        if (chain == 0 or pos[i].attach_type != .cursive or depth == 0) return;
        pos[i].attach_chain = 0;
        const j_signed = @as(isize, @intCast(i)) + chain;
        if (j_signed < 0 or j_signed >= pos.len) return;
        const j: usize = @intCast(j_signed);
        // Stop at the new parent: it is on the old chain
        if (j == new_parent) return;
        reverseCursiveAt(pos, j, new_parent, depth - 1);
        pos[j].y_offset = -pos[i].y_offset;
        pos[j].attach_chain = -chain;
        pos[j].attach_type = .cursive;
    }

    /// MarkArray: attach the mark at i to the glyph at `base` using the
    /// anchor of the mark's class in `matrix_row` (an array of class_count
    /// anchor offsets from `matrix_base`). False if that anchor is null,
    /// so later subtables get their chance.
    fn attachMark(self: *Ctx, mark_array: usize, mark_index: u16, matrix_base: usize, matrix_row: usize, class_count: u16, i: usize, base: usize) bool {
        const d = self.data();
        if (mark_index >= readU16(d, mark_array)) return false;
        const rec = mark_array + 2 + @as(usize, mark_index) * 4;
        const class = readU16(d, rec);
        if (class >= class_count) return false;
        const base_off = readU16(d, matrix_row + @as(usize, class) * 2);
        if (base_off == 0) return false;
        const mark_anchor = self.anchor(mark_array + readU16(d, rec + 2));
        const base_anchor = self.anchor(matrix_base + base_off);
        const p = &self.pos[i];
        p.x_offset = base_anchor[0] - mark_anchor[0];
        p.y_offset = base_anchor[1] - mark_anchor[1];
        p.attach_type = .mark;
        p.attach_chain = @as(i32, @intCast(base)) - @as(i32, @intCast(i));
        return true;
    }

    /// The glyph a mark at i attaches to as base or ligature: the nearest
    /// non-mark before it (HarfBuzz searches with IgnoreMarks only).
    /// Mark-to-base skips the later glyphs of a multiple substitution
    /// unless `base_coverage` holds them (HarfBuzz issues 740, 1020).
    fn findBase(self: *Ctx, i: usize, base_coverage: ?opentype.CoverageTable) ?usize {
        const ignore = ignoreLookup(gsub.ignore_marks, 0);
        var j = i;
        while (j > 0) {
            j -= 1;
            if (self.m.skips(&ignore, j)) continue;
            if (base_coverage) |cov| {
                if (!self.accept(j) and cov.getCoverageIndex(self.glyphs()[j].id) == null) continue;
            }
            return j;
        }
        return null;
    }

    /// HarfBuzz's MarkBasePos accept: only the first glyph of a multiple
    /// substitution takes marks, unless a mark sits within the sequence.
    fn accept(self: *Ctx, idx: usize) bool {
        const items = self.glyphs();
        const g = items[idx];
        if (!g.multiplied or g.lig_comp == 0 or idx == 0) return true;
        const prev = items[idx - 1];
        return self.m.classOf(idx - 1) == .mark or !prev.multiplied or
            g.lig_id != prev.lig_id or g.lig_comp != prev.lig_comp + 1;
    }

    // Type 4
    fn applyMarkBase(self: *Ctx, addr: usize, i: usize) ?usize {
        const d = self.data();
        if (readU16(d, addr) != 1) return null;
        const mark_index = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(self.glyphs()[i].id) orelse return null;
        const base_cov = coverageAt(d, addr + readU16(d, addr + 4));
        const b = self.findBase(i, base_cov) orelse return null;
        const base_index = base_cov.getCoverageIndex(self.glyphs()[b].id) orelse return null;
        const class_count = readU16(d, addr + 6);
        const base_array = addr + readU16(d, addr + 10);
        if (base_index >= readU16(d, base_array)) return null;
        const row = base_array + 2 + @as(usize, base_index) * class_count * 2;
        if (!self.attachMark(addr + readU16(d, addr + 8), mark_index, base_array, row, class_count, i, b)) return null;
        return i + 1;
    }

    // Type 5: the mark goes on its own ligature component, else the last
    fn applyMarkLig(self: *Ctx, addr: usize, i: usize) ?usize {
        const d = self.data();
        if (readU16(d, addr) != 1) return null;
        const items = self.glyphs();
        const mark_index = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(items[i].id) orelse return null;
        const b = self.findBase(i, null) orelse return null;
        const lig_index = coverageAt(d, addr + readU16(d, addr + 4)).getCoverageIndex(items[b].id) orelse return null;
        const class_count = readU16(d, addr + 6);
        const lig_array = addr + readU16(d, addr + 10);
        if (lig_index >= readU16(d, lig_array)) return null;
        const attach = lig_array + readU16(d, lig_array + 2 + @as(usize, lig_index) * 2);
        const comp_count = readU16(d, attach);
        if (comp_count == 0) return null;
        const mark = items[i];
        const comp: usize = if (items[b].lig_id != 0 and items[b].lig_id == mark.lig_id and mark.lig_comp > 0)
            @min(comp_count, mark.lig_comp) - 1
        else
            comp_count - 1;
        const row = attach + 2 + comp * class_count * 2;
        if (!self.attachMark(addr + readU16(d, addr + 8), mark_index, attach, row, class_count, i, b)) return null;
        return i + 1;
    }

    // Type 6: onto the previous mark, if both belong to the same base or
    // ligature component
    fn applyMarkMark(self: *Ctx, lookup: *const Lookup, addr: usize, i: usize) ?usize {
        const d = self.data();
        if (readU16(d, addr) != 1) return null;
        const items = self.glyphs();
        const mark1_index = coverageAt(d, addr + readU16(d, addr + 2)).getCoverageIndex(items[i].id) orelse return null;
        // The lookup's flags without the ignore-base/ligature/marks bits
        const flags = ignoreLookup(lookup.flag & ~@as(u16, 0x000E), lookup.mark_set);
        const j = prevIndex(&self.m, &flags, i) orelse return null;
        if (self.m.classOf(j) != .mark) return null;
        const id1 = items[i].lig_id;
        const id2 = items[j].lig_id;
        const comp1 = items[i].lig_comp;
        const comp2 = items[j].lig_comp;
        const good = if (id1 == id2)
            id1 == 0 or comp1 == comp2
        else
            (id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0);
        if (!good) return null;
        const mark2_index = coverageAt(d, addr + readU16(d, addr + 4)).getCoverageIndex(items[j].id) orelse return null;
        const class_count = readU16(d, addr + 6);
        const mark2_array = addr + readU16(d, addr + 10);
        if (mark2_index >= readU16(d, mark2_array)) return null;
        const row = mark2_array + 2 + @as(usize, mark2_index) * class_count * 2;
        if (!self.attachMark(addr + readU16(d, addr + 8), mark1_index, mark2_array, row, class_count, i, j)) return null;
        return i + 1;
    }

    /// A matched context rule's nested lookups, at their input positions
    /// (positioning never changes the run's length). Continues after the
    /// input.
    fn applyRecords(self: *Ctx, li: u16, r: gsub.Context.RuleMatch, depth: u8) usize {
        const d = self.data();
        const end = r.positions[r.count - 1] + 1;
        if (depth >= gsub.max_nesting) return end;
        for (0..r.record_count) |k| {
            const idx: usize = readU16(d, r.records + k * 4);
            const nested: u16 = readU16(d, r.records + k * 4 + 2);
            if (idx >= r.count or nested >= self.m.table.lookups.len) continue;
            if (k == 0 and nested == li) continue;
            _ = self.applyAt(&self.m.table.lookups[nested], nested, r.positions[idx], depth + 1);
        }
        return end;
    }
};
