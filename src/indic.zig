//! The Indic shaper (Devanagari for now), ported from HarfBuzz 12.3.0's
//! hb-ot-shaper-indic.cc: character categories, syllables, initial and
//! final reordering around the basic shaping features, dotted circles for
//! broken clusters, and the vowel constraints. shaping.zig drives it.

const std = @import("std");
const data = @import("indic_data.zig");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const ttf = @import("ttf.zig");
const unicode_props = @import("unicode_props.zig");

const Glyph = gsub.Glyph;
const LookupParams = gsub.LookupParams;
const Feature = opentype.Feature;

/// HarfBuzz's indic_category_t (values as in its syllable machine).
pub const Category = enum(u8) {
    x = 0,
    c = 1,
    v = 2,
    n = 3,
    h = 4,
    zwnj = 5,
    zwj = 6,
    m = 7,
    sm = 8,
    a = 9, // also VD
    placeholder = 10,
    dotted_circle = 11,
    rs = 12,
    m_pst = 13,
    repha = 14,
    ra = 15,
    cm = 16,
    symbol = 17,
    cs = 18,
    sm_pst = 57,
};

/// HarfBuzz's ot_position_t: visual positions in a syllable, left to right.
pub const Position = enum(u8) {
    start = 0,
    ra_to_become_reph = 1,
    pre_m = 2,
    pre_c = 3,
    base_c = 4,
    after_main = 5,
    above_c = 6,
    before_sub = 7,
    below_c = 8,
    after_sub = 9,
    before_post = 10,
    post_c = 11,
    after_post = 12,
    smvd = 13,
    end = 14,
};

pub const Props = struct { category: Category, position: Position };

/// Category and position of a character (hb_indic_get_categories).
pub fn props(cp: u21) Props {
    const t = &data.entries;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < t[mid].cp) {
            hi = mid;
        } else if (cp > t[mid].cp) {
            lo = mid + 1;
        } else return .{ .category = t[mid].category, .position = t[mid].position };
    }
    return .{ .category = .x, .position = .end };
}

// ============================================================================
// Syllables (hb-ot-shaper-indic-machine.rl)
// ============================================================================

pub const SyllableType = enum(u4) {
    consonant = 0,
    vowel = 1,
    standalone = 2,
    symbol = 3,
    broken = 4,
    non_indic = 5,
};

/// The longest syllable the machine looks at; HarfBuzz has no limit, but
/// longer runs of combining characters are not text.
const max_window = 255;
const Set = std.bit_set.Integer(max_window + 1);

/// Positions reachable by a pattern: `Set` bit i = i categories consumed.
const Machine = struct {
    cats: []const Category,

    fn one(m: Machine, s: Set, comptime allowed: []const Category) Set {
        var out = Set.empty;
        var it = s.iterator(.{});
        while (it.next()) |i| {
            if (i >= m.cats.len or i >= max_window) continue;
            const cat = m.cats[i];
            inline for (allowed) |a| {
                if (cat == a) out.set(i + 1);
            }
        }
        return out;
    }

    fn opt(m: Machine, s: Set, comptime f: fn (Machine, Set) Set) Set {
        return s.unionWith(f(m, s));
    }

    fn star(m: Machine, s: Set, comptime f: fn (Machine, Set) Set) Set {
        var acc = s;
        var frontier = s;
        while (true) {
            const next = f(m, frontier);
            const fresh = next.differenceWith(acc);
            if (fresh.count() == 0) return acc;
            acc = acc.unionWith(fresh);
            frontier = fresh;
        }
    }

    // c = (C | Ra)
    fn c(m: Machine, s: Set) Set {
        return m.one(s, &.{ .c, .ra });
    }
    // n = ((ZWNJ?.RS)? (N.N?)?)
    fn n(m: Machine, s: Set) Set {
        const rs = struct {
            fn f(mm: Machine, ss: Set) Set {
                return mm.one(mm.opt(ss, zwnj), &.{.rs});
            }
        }.f;
        const nn = struct {
            fn f(mm: Machine, ss: Set) Set {
                return mm.opt(mm.one(ss, &.{.n}), nOne);
            }
        }.f;
        return m.opt(m.opt(s, rs), nn);
    }
    fn nOne(m: Machine, s: Set) Set {
        return m.one(s, &.{.n});
    }
    fn zwnj(m: Machine, s: Set) Set {
        return m.one(s, &.{.zwnj});
    }
    fn zwj(m: Machine, s: Set) Set {
        return m.one(s, &.{.zwj});
    }
    // z = ZWJ|ZWNJ
    fn z(m: Machine, s: Set) Set {
        return m.one(s, &.{ .zwj, .zwnj });
    }
    fn h(m: Machine, s: Set) Set {
        return m.one(s, &.{.h});
    }
    // reph = (Ra H | Repha)
    fn reph(m: Machine, s: Set) Set {
        return m.h(m.one(s, &.{.ra})).unionWith(m.one(s, &.{.repha}));
    }
    // sm = SM | SMPst
    fn sm(m: Machine, s: Set) Set {
        return m.one(s, &.{ .sm, .sm_pst });
    }
    // cn = c.ZWJ?.n?
    fn cn(m: Machine, s: Set) Set {
        return m.opt(m.opt(m.c(s), zwj), n);
    }
    // symbol = Symbol.N?
    fn symbol(m: Machine, s: Set) Set {
        return m.opt(m.one(s, &.{.symbol}), nOne);
    }
    // matra_group = z*.(M | sm? MPst).N?.H?
    fn matraGroup(m: Machine, s: Set) Set {
        const zs = m.star(s, z);
        const core = m.one(zs, &.{.m}).unionWith(m.one(m.opt(zs, sm), &.{.m_pst}));
        return m.opt(m.opt(core, nOne), h);
    }
    // syllable_tail = (z?.sm.sm?.ZWNJ?)? (A | VD)*
    fn syllableTail(m: Machine, s: Set) Set {
        const head = struct {
            fn f(mm: Machine, ss: Set) Set {
                return mm.opt(mm.opt(mm.sm(mm.opt(ss, z)), Machine.sm), zwnj);
            }
        }.f;
        const a = struct {
            fn f(mm: Machine, ss: Set) Set {
                return mm.one(ss, &.{.a});
            }
        }.f;
        return m.star(m.opt(s, head), a);
    }
    // halant_group = (z?.H.(ZWJ.N?)?)
    fn halantGroup(m: Machine, s: Set) Set {
        const zn = struct {
            fn f(mm: Machine, ss: Set) Set {
                return mm.opt(mm.zwj(ss), nOne);
            }
        }.f;
        return m.opt(m.h(m.opt(s, z)), zn);
    }
    // final_halant_group = halant_group | H.ZWNJ
    fn finalHalantGroup(m: Machine, s: Set) Set {
        return m.halantGroup(s).unionWith(m.zwnj(m.h(s)));
    }
    // halant_or_matra_group = (final_halant_group | matra_group*)
    fn halantOrMatraGroup(m: Machine, s: Set) Set {
        return m.finalHalantGroup(s).unionWith(m.star(s, matraGroup));
    }
    fn halantCn(m: Machine, s: Set) Set {
        return m.cn(m.halantGroup(s));
    }
    fn cm(m: Machine, s: Set) Set {
        return m.one(s, &.{.cm});
    }
    // complex_syllable_tail = (halant_group.cn)* medial_group
    //                         halant_or_matra_group syllable_tail
    fn complexTail(m: Machine, s: Set) Set {
        return m.syllableTail(m.halantOrMatraGroup(m.opt(m.star(s, halantCn), cm)));
    }
    fn rephaOrCs(m: Machine, s: Set) Set {
        return m.one(s, &.{ .repha, .cs });
    }
    // consonant_syllable = (Repha|CS)? cn complex_syllable_tail
    fn consonantSyllable(m: Machine, s: Set) Set {
        return m.complexTail(m.cn(m.opt(s, rephaOrCs)));
    }
    // vowel_syllable = reph? V.n? (ZWJ | complex_syllable_tail)
    fn vowelSyllable(m: Machine, s: Set) Set {
        const vn = m.opt(m.one(m.opt(s, reph), &.{.v}), n);
        return m.zwj(vn).unionWith(m.complexTail(vn));
    }
    // standalone_cluster = ((Repha|CS)? PLACEHOLDER | reph? DOTTEDCIRCLE).n?
    //                      complex_syllable_tail
    fn standaloneCluster(m: Machine, s: Set) Set {
        const head = m.one(m.opt(s, rephaOrCs), &.{.placeholder})
            .unionWith(m.one(m.opt(s, reph), &.{.dotted_circle}));
        return m.complexTail(m.opt(head, n));
    }
    // symbol_cluster = symbol syllable_tail
    fn symbolCluster(m: Machine, s: Set) Set {
        return m.syllableTail(m.symbol(s));
    }
    // broken_cluster = reph? n? complex_syllable_tail
    fn brokenCluster(m: Machine, s: Set) Set {
        return m.complexTail(m.opt(m.opt(s, reph), n));
    }
};

/// One syllable: its type and length.
pub const Found = struct { kind: SyllableType, len: usize };

/// The syllable at the start of `cats`: the longest match, earlier rules
/// first on a tie (Ragel's scanner), never empty.
pub fn nextSyllable(cats: []const Category) Found {
    const m: Machine = .{ .cats = cats };
    var start = Set.empty;
    start.set(0);
    const rules = [_]struct { SyllableType, Set }{
        .{ .consonant, m.consonantSyllable(start) },
        .{ .vowel, m.vowelSyllable(start) },
        .{ .standalone, m.standaloneCluster(start) },
        .{ .symbol, m.symbolCluster(start) },
        .{ .non_indic, m.one(start, &.{.sm_pst}) },
        .{ .broken, m.brokenCluster(start) },
    };
    var best: Found = .{ .kind = .non_indic, .len = 0 };
    for (rules) |r| {
        const len = r[1].findLastSet() orelse 0;
        if (len > best.len) best = .{ .kind = r[0], .len = len };
    }
    // other = any
    if (best.len == 0) best = .{ .kind = .non_indic, .len = @min(cats.len, 1) };
    return best;
}

// ============================================================================
// The plan: GSUB stages (collect_features_indic, override_features_indic)
// ============================================================================

/// Glyph.mask bits of the non-global Indic features (bit 0 is global).
pub const mask_rphf: u8 = 1 << 1;
pub const mask_pref: u8 = 1 << 2;
pub const mask_blwf: u8 = 1 << 3;
pub const mask_abvf: u8 = 1 << 4;
pub const mask_half: u8 = 1 << 5;
pub const mask_pstf: u8 = 1 << 6;
pub const mask_init: u8 = 1 << 7;

const FeatureSpec = struct {
    feature: Feature,
    mask: u8 = gsub.mask_global,
    manual_joiners: bool = false,
    per_syllable: bool = false,
};

/// The basic features, one stage each, in order (HarfBuzz's
/// indic_features up to init).
const basic_features = [_]FeatureSpec{
    .{ .feature = .nukt, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .akhn, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .rphf, .mask = mask_rphf, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .rkrf, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .pref, .mask = mask_pref, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .blwf, .mask = mask_blwf, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .abvf, .mask = mask_abvf, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .half, .mask = mask_half, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .pstf, .mask = mask_pstf, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .vatu, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .cjct, .manual_joiners = true, .per_syllable = true },
};
const stage_rphf = 2;
const stage_pref = 4;
const stage_blwf = 5;
const stage_pstf = 8;
const stage_vatu = 9;

/// After final reordering: the presentation features, then HarfBuzz's
/// common and horizontal features (ccmp and locl went first; liga is off
/// for Indic).
const tail_features = [_]FeatureSpec{
    .{ .feature = .init, .mask = mask_init, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .pres, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .abvs, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .blws, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .psts, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .haln, .manual_joiners = true, .per_syllable = true },
    .{ .feature = .abvm },
    .{ .feature = .blwm },
    .{ .feature = .mark, .manual_joiners = true },
    .{ .feature = .mkmk, .manual_joiners = true },
    .{ .feature = .rlig },
    .{ .feature = .calt },
    .{ .feature = .clig },
    .{ .feature = .curs },
    .{ .feature = .dist },
    .{ .feature = .kern },
    .{ .feature = .rclt },
};

fn isIndicFeature(f: Feature) bool {
    for (basic_features ++ tail_features) |spec| {
        if (spec.feature == f) return true;
    }
    return f == .ccmp or f == .locl or f == .liga;
}

pub const Plan = struct {
    table: *const gsub.Table,
    /// Old-spec Indic (the font's script is 'deva', not 'dev2')
    old_spec: bool,
    /// The font's virama glyph (0: none)
    virama: u16,
    first: []LookupParams,
    basic: [basic_features.len][]LookupParams,
    tail: []LookupParams,
    /// Features the user enabled beyond these: after the syllables are gone
    user: []LookupParams,
    storage: []LookupParams,

    /// The plan for `table`'s Devanagari language system; `flags` say which
    /// of the common features and which others are on.
    pub fn init(allocator: std.mem.Allocator, table: *const gsub.Table, flags: opentype.FeatureFlags, virama: u16) !Plan {
        const map = table.langSys(.devanagari);
        var list: std.ArrayListUnmanaged(LookupParams) = .empty;
        defer list.deinit(allocator);
        var bounds: [basic_features.len + 4]usize = undefined;
        var nb: usize = 0;

        // ccmp and locl: per syllable (the Indic shaper adds them first);
        // the required feature with them
        bounds[nb] = list.items.len;
        nb += 1;
        for (map.required_lookups) |li| try list.append(allocator, .{ .index = li });
        try addFeature(allocator, &list, map, table, .{ .feature = .locl, .per_syllable = true });
        try addFeature(allocator, &list, map, table, .{ .feature = .ccmp, .per_syllable = true });
        for (basic_features) |spec| {
            bounds[nb] = list.items.len;
            nb += 1;
            try addFeature(allocator, &list, map, table, spec);
        }
        bounds[nb] = list.items.len;
        nb += 1;
        for (tail_features) |spec| {
            if (spec.per_syllable or flags.isEnabled(spec.feature)) try addFeature(allocator, &list, map, table, spec);
        }
        bounds[nb] = list.items.len;
        nb += 1;
        for (std.enums.values(Feature)) |f| {
            if (isIndicFeature(f) or !flags.isEnabled(f)) continue;
            try addFeature(allocator, &list, map, table, .{ .feature = f });
        }
        bounds[nb] = list.items.len;

        const storage = try list.toOwnedSlice(allocator);
        errdefer allocator.free(storage);
        // Sort and merge each stage
        var plan: Plan = undefined;
        plan.table = table;
        plan.old_spec = map.script != gsub.tag("dev2");
        plan.virama = virama;
        plan.storage = storage;
        var stages: [basic_features.len + 3][]LookupParams = undefined;
        for (&stages, 0..) |*st, k| st.* = mergeStage(storage[bounds[k]..bounds[k + 1]]);
        plan.first = stages[0];
        for (&plan.basic, 0..) |*b, k| b.* = stages[1 + k];
        plan.tail = stages[1 + basic_features.len];
        plan.user = stages[2 + basic_features.len];
        return plan;
    }

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }

    fn addFeature(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(LookupParams), map: *const gsub.LangSysMap, table: *const gsub.Table, spec: FeatureSpec) !void {
        for (map.feature_lookups[opentype.FeatureFlags.featureIndex(spec.feature)]) |li| {
            if (li >= table.lookups.len) continue;
            try list.append(allocator, .{
                .index = li,
                .mask = spec.mask,
                .auto_zwj = !spec.manual_joiners,
                .auto_zwnj = !spec.manual_joiners,
                .per_syllable = spec.per_syllable,
            });
        }
    }

    /// Sort a stage's lookups by index and merge duplicates as HarfBuzz's
    /// map builder: masks or'ed, automatic joiners only if all say so.
    fn mergeStage(stage: []LookupParams) []LookupParams {
        if (stage.len < 2) return stage;
        std.sort.insertion(LookupParams, stage, {}, struct {
            fn lt(_: void, a: LookupParams, b: LookupParams) bool {
                return a.index < b.index;
            }
        }.lt);
        var j: usize = 0;
        for (stage[1..]) |lp| {
            if (lp.index != stage[j].index) {
                j += 1;
                stage[j] = lp;
            } else {
                stage[j].mask |= lp.mask;
                stage[j].auto_zwnj = stage[j].auto_zwnj and lp.auto_zwnj;
                stage[j].auto_zwj = stage[j].auto_zwj and lp.auto_zwj;
            }
        }
        return stage[0 .. j + 1];
    }

    fn wouldSubstitute(self: *const Plan, stage: usize, glyphs: []const u16) bool {
        // Zero-context matching for new-spec Devanagari (data_create_indic)
        return self.table.wouldSubstitute(self.basic[stage], glyphs, !self.old_spec);
    }
};

// ============================================================================
// Shaping
// ============================================================================

fn categoryOf(g: Glyph) Category {
    return std.enums.fromInt(Category, g.indic_category) orelse .x;
}

fn positionOf(g: Glyph) Position {
    return std.enums.fromInt(Position, g.indic_position) orelse .end;
}

fn setPosition(g: *Glyph, p: Position) void {
    g.indic_position = @backingInt(p);
}

/// HarfBuzz's is_one_of: a ligated glyph is none of these.
fn isOneOf(g: Glyph, comptime cats_: []const Category) bool {
    if (g.ligated) return false;
    const c = categoryOf(g);
    inline for (cats_) |x| {
        if (c == x) return true;
    }
    return false;
}

fn isConsonant(g: Glyph) bool {
    return isOneOf(g, &.{ .c, .cs, .ra, .cm, .v, .placeholder, .dotted_circle });
}

fn isJoiner(g: Glyph) bool {
    return isOneOf(g, &.{ .zwj, .zwnj });
}

fn isHalant(g: Glyph) bool {
    return isOneOf(g, &.{.h});
}

const mergeClusters = gsub.mergeClusters;

/// Shapes the GSUB part of a Devanagari run: `shaper` is begun (one
/// glyph per code point of `cps`); applies the stages around the Indic
/// reorderings and returns the result of `finish`.
pub fn substitute(allocator: std.mem.Allocator, shaper: *gsub.Shaper, plan: *const Plan, font: *const ttf.Font, cps: []const u21) ![]const Glyph {
    const table = plan.table;
    for (shaper.buf.items) |*g| {
        const p = props(cps[g.cp]);
        g.indic_category = @backingInt(p.category);
        g.indic_position = @backingInt(p.position);
    }
    const has_broken = setupSyllables(shaper.buf.items);
    shaper.applyStage(table, plan.first);

    // initial_reordering_indic
    updateConsonantPositions(plan, shaper.buf.items);
    if (has_broken) try insertDottedCircles(allocator, &shaper.buf, font);
    {
        var it = SyllableIterator{ .items = shaper.buf.items };
        while (it.next()) |r| {
            switch (syllableType(shaper.buf.items[r.start])) {
                .consonant, .vowel, .broken, .standalone => try initialReorder(allocator, plan, shaper.buf.items, r.start, r.end),
                .symbol, .non_indic => {},
            }
        }
    }
    for (plan.basic) |stage| shaper.applyStage(table, stage);
    {
        var it = SyllableIterator{ .items = shaper.buf.items };
        while (it.next()) |r| finalReorder(plan, cps, shaper.buf.items, r.start, r.end);
    }
    shaper.applyStage(table, plan.tail);
    // hb_syllabic_clear_var: the user's features see no syllables
    for (shaper.buf.items) |*g| g.syllable = 0;
    shaper.applyStage(table, plan.user);
    return shaper.finish(allocator);
}

fn syllableType(g: Glyph) SyllableType {
    return std.enums.fromInt(SyllableType, @as(u4, @truncate(g.syllable))) orelse .non_indic;
}

const SyllableIterator = struct {
    items: []const Glyph,
    pos: usize = 0,

    fn next(it: *SyllableIterator) ?struct { start: usize, end: usize } {
        if (it.pos >= it.items.len) return null;
        const start = it.pos;
        const syl = it.items[start].syllable;
        var end = start + 1;
        while (end < it.items.len and it.items[end].syllable == syl) end += 1;
        it.pos = end;
        return .{ .start = start, .end = end };
    }
};

/// find_syllables_indic: syllable = serial << 4 | type, serials 1..15.
/// True if a broken cluster was found.
fn setupSyllables(items: []Glyph) bool {
    var cats_buf: [max_window + 1]Category = undefined;
    var serial: u8 = 1;
    var broken = false;
    var i: usize = 0;
    while (i < items.len) {
        const n = @min(items.len - i, cats_buf.len);
        for (items[i..][0..n], cats_buf[0..n]) |g, *c| c.* = categoryOf(g);
        const found = nextSyllable(cats_buf[0..n]);
        const len = @max(found.len, 1);
        for (items[i..][0..len]) |*g| g.syllable = (serial << 4) | @backingInt(found.kind);
        if (found.kind == .broken) broken = true;
        serial += 1;
        if (serial == 16) serial = 1;
        i += len;
    }
    return broken;
}

/// update_consonant_positions_indic: a consonant with a below-base (or
/// vattu) form is below_c, with a post-base or pre-base-reordering form
/// post_c, judged by the font's lookups on virama + consonant (both
/// orders).
fn updateConsonantPositions(plan: *const Plan, items: []Glyph) void {
    if (plan.virama == 0) return;
    for (items) |*g| {
        if (positionOf(g.*) != .base_c) continue;
        const glyphs = [3]u16{ plan.virama, g.id, plan.virama };
        const pos: Position = if (plan.wouldSubstitute(stage_blwf, glyphs[0..2]) or plan.wouldSubstitute(stage_blwf, glyphs[1..3]) or
            plan.wouldSubstitute(stage_vatu, glyphs[0..2]) or plan.wouldSubstitute(stage_vatu, glyphs[1..3]))
            .below_c
        else if (plan.wouldSubstitute(stage_pstf, glyphs[0..2]) or plan.wouldSubstitute(stage_pstf, glyphs[1..3]))
            .post_c
        else if (plan.wouldSubstitute(stage_pref, glyphs[0..2]) or plan.wouldSubstitute(stage_pref, glyphs[1..3]))
            .post_c
        else
            .base_c;
        setPosition(g, pos);
    }
}

/// hb_syllabic_insert_dotted_circles: a dotted circle at the start of
/// each broken cluster (after a Repha), if the font has one.
fn insertDottedCircles(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(Glyph), font: *const ttf.Font) !void {
    const dc = font.getGlyphId(0x25CC) orelse 0;
    if (dc == 0) return;
    var out: std.ArrayListUnmanaged(Glyph) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, buf.items.len + 8);
    var last_syllable: u8 = 0;
    var i: usize = 0;
    const items = buf.items;
    while (i < items.len) {
        const syl = items[i].syllable;
        if (last_syllable != syl and syllableType(items[i]) == .broken) {
            last_syllable = syl;
            const first = items[i];
            // After a possible Repha
            while (i < items.len and items[i].syllable == last_syllable and categoryOf(items[i]) == .repha) {
                try out.append(allocator, items[i]);
                i += 1;
            }
            try out.append(allocator, .{
                .id = dc,
                .cluster = first.cluster,
                .cp = first.cp,
                .props = 0,
                .mask = first.mask,
                .syllable = syl,
                .indic_category = @backingInt(Category.dotted_circle),
                .indic_position = @backingInt(Position.end),
                .inserted = true,
            });
        } else {
            try out.append(allocator, items[i]);
            i += 1;
        }
    }
    // Keep the buffer's capacity for later multiple substitutions
    try buf.ensureTotalCapacity(allocator, out.items.len + buf.capacity - buf.items.len);
    buf.items.len = out.items.len;
    @memcpy(buf.items, out.items);
    out.deinit(allocator);
}

/// initial_reordering_consonant_syllable (also vowel, standalone and
/// broken syllables, whose vowel or dotted circle acts as consonant).
fn initialReorder(allocator: std.mem.Allocator, plan: *const Plan, items: []Glyph, start: usize, end: usize) !void {
    // 1. Find the base consonant
    var base = end;
    var has_reph = false;
    {
        var limit = start;
        // Reph: Ra + Halant at the start, if 'rphf' would form it
        if (plan.basic[stage_rphf].len > 0 and start + 3 <= end and !isJoiner(items[start + 2])) {
            const glyphs = [2]u16{ items[start].id, items[start + 1].id };
            if (plan.wouldSubstitute(stage_rphf, &glyphs)) {
                limit += 2;
                while (limit < end and isJoiner(items[limit])) limit += 1;
                base = start;
                has_reph = true;
            }
        }
        // From the end: a consonant without a below-base or post-base form
        var i = end;
        var seen_below = false;
        while (true) {
            i -= 1;
            if (isConsonant(items[i])) {
                const pos = positionOf(items[i]);
                if (pos != .below_c and (pos != .post_c or seen_below)) {
                    base = i;
                    break;
                }
                if (pos == .below_c) seen_below = true;
                base = i;
            } else if (start < i and categoryOf(items[i]) == .zwj and categoryOf(items[i - 1]) == .h) {
                // ZWJ after a Halant asks for a half form: stop
                break;
            }
            if (i <= limit) break;
        }
        // No other consonant: Ra is the base, no Reph
        if (has_reph and base == start and limit - base <= 2) has_reph = false;
    }

    // Reorder characters
    for (items[start..base]) |*g| {
        if (@backingInt(positionOf(g.*)) > @backingInt(Position.pre_c)) setPosition(g, .pre_c);
    }
    if (base < end) setPosition(&items[base], .base_c);
    if (has_reph) setPosition(&items[start], .ra_to_become_reph);

    // Old spec: the first post-base Halant moves after the last consonant
    if (plan.old_spec) {
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (categoryOf(items[i]) != .h) continue;
            var j = end - 1;
            while (j > i) : (j -= 1) {
                if (isConsonant(items[j])) break;
            }
            if (categoryOf(items[j]) != .h and j > i) {
                const t = items[i];
                std.mem.copyForwards(Glyph, items[i..j], items[i + 1 .. j + 1]);
                items[j] = t;
            }
            break;
        }
    }

    // Misc marks go with the character before them
    {
        var last_pos: Position = .start;
        for (start..end) |i| {
            const c = categoryOf(items[i]);
            if (c == .zwj or c == .zwnj or c == .n or c == .rs or c == .cm or c == .h) {
                setPosition(&items[i], last_pos);
                if (c == .h and last_pos == .pre_m) {
                    // Uniscribe doesn't move the Halant with a Left Matra
                    var j = i;
                    while (j > start) : (j -= 1) {
                        if (positionOf(items[j - 1]) != .pre_m) {
                            setPosition(&items[i], positionOf(items[j - 1]));
                            break;
                        }
                    }
                }
            } else if (positionOf(items[i]) != .smvd) {
                if (c == .m_pst and i > start and categoryOf(items[i - 1]) == .sm) {
                    setPosition(&items[i - 1], positionOf(items[i]));
                }
                last_pos = positionOf(items[i]);
            }
        }
    }
    // Post-base consonants own what comes before them since the last
    // consonant or matra
    {
        var last = base;
        // (no base found: base == end, nothing after it)
        for (@min(base + 1, end)..end) |i| {
            if (isConsonant(items[i])) {
                for (last + 1..i) |j| {
                    if (@backingInt(positionOf(items[j])) < @backingInt(Position.smvd)) setPosition(&items[j], positionOf(items[i]));
                }
                last = i;
            } else {
                const c = categoryOf(items[i]);
                if (c == .m or c == .m_pst) last = i;
            }
        }
    }

    {
        // Stable sort by position, remembering where each glyph came from
        const n = end - start;
        const orig = try allocator.alloc(u32, n);
        defer allocator.free(orig);
        const Item = struct { g: Glyph, from: u32 };
        const tmp = try allocator.alloc(Item, n);
        defer allocator.free(tmp);
        for (tmp, items[start..end], 0..) |*t, g, k| t.* = .{ .g = g, .from = @intCast(k) };
        std.sort.insertion(Item, tmp, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.g.indic_position < b.g.indic_position;
            }
        }.lt);
        for (tmp, items[start..end], orig) |t, *g, *o| {
            g.* = t.g;
            o.* = t.from;
        }

        // Find the base again; flip a left-matra sequence
        var first_left: usize = end;
        var last_left: usize = end;
        base = end;
        for (start..end) |i| {
            const pos = positionOf(items[i]);
            if (pos == .base_c) {
                base = i;
                break;
            } else if (pos == .pre_m) {
                if (first_left == end) first_left = i;
                last_left = i;
            }
        }
        if (first_left < last_left) {
            std.mem.reverse(Glyph, items[first_left .. last_left + 1]);
            std.mem.reverse(u32, orig[first_left - start .. last_left + 1 - start]);
            // Reverse back nuktas etc.
            var i = first_left;
            for (first_left..last_left + 1) |j| {
                const c = categoryOf(items[j]);
                if (c == .m or c == .m_pst) {
                    std.mem.reverse(Glyph, items[i .. j + 1]);
                    std.mem.reverse(u32, orig[i - start .. j + 1 - start]);
                    i = j + 1;
                }
            }
        }

        // Merge clusters of what moved around after the base
        if (plan.old_spec or n > 127) {
            mergeClusters(items, base, end);
        } else {
            const done = try allocator.alloc(bool, n);
            defer allocator.free(done);
            @memset(done, false);
            var i = base;
            while (i < end) : (i += 1) {
                if (done[i - start]) continue;
                var min = i;
                var max = i;
                var j = start + orig[i - start];
                while (j != i) {
                    min = @min(min, j);
                    max = @max(max, j);
                    const next = start + orig[j - start];
                    done[j - start] = true;
                    j = next;
                }
                mergeClusters(items, @max(base, min), max + 1);
            }
        }
    }

    // Masks
    {
        var i = start;
        while (i < end and positionOf(items[i]) == .ra_to_become_reph) : (i += 1) items[i].mask |= mask_rphf;
        var pre: u8 = mask_half;
        if (!plan.old_spec) pre |= mask_blwf;
        for (items[start..base]) |*g| g.mask |= pre;
        if (base + 1 < end) {
            for (items[base + 1 .. end]) |*g| g.mask |= mask_blwf | mask_abvf | mask_pstf;
        }
    }
    if (plan.old_spec) {
        // Old-spec eyelash Ra: Ra + Halant below a half form too
        var i = start;
        while (i + 1 < base) : (i += 1) {
            if (categoryOf(items[i]) == .ra and categoryOf(items[i + 1]) == .h and
                (i + 2 == base or categoryOf(items[i + 2]) != .zwj))
            {
                items[i].mask |= mask_blwf;
                items[i + 1].mask |= mask_blwf;
            }
        }
    }
    if (plan.basic[stage_pref].len > 0 and base + 2 < end) {
        // A Halant + Ra 'pref' would form: mark it
        var i = base + 1;
        while (i + 1 < end) : (i += 1) {
            const glyphs = [2]u16{ items[i].id, items[i + 1].id };
            if (plan.wouldSubstitute(stage_pref, &glyphs)) {
                items[i].mask |= mask_pref;
                items[i + 1].mask |= mask_pref;
                break;
            }
        }
    }
    // A ZWNJ disables the half form of what comes before it
    for (start + 1..end) |i| {
        if (!isJoiner(items[i])) continue;
        const non_joiner = categoryOf(items[i]) == .zwnj;
        var j = i;
        while (true) {
            j -= 1;
            if (non_joiner) items[j].mask &= ~mask_half;
            if (!(j > start and !isConsonant(items[j]))) break;
        }
    }
}

/// final_reordering_syllable_indic: after the basic features, pre-base
/// matras move next to the base, the Reph to its place, pre-base
/// reordering consonants before the base; a word-initial left matra
/// gets 'init'.
fn finalReorder(plan: *const Plan, cps: []const u21, items: []Glyph, start: usize, end: usize) void {
    // A ligated and multiplied virama is a Halant again
    if (plan.virama != 0) {
        for (items[start..end]) |*g| {
            if (g.id == plan.virama and g.ligated and g.multiplied) {
                g.indic_category = @backingInt(Category.h);
                g.ligated = false;
                g.multiplied = false;
            }
        }
    }

    var try_pref = plan.basic[stage_pref].len > 0;

    // Find the base again
    var base: usize = start;
    while (base < end) : (base += 1) {
        if (@backingInt(positionOf(items[base])) >= @backingInt(Position.base_c)) {
            if (try_pref and base + 1 < end) {
                for (base + 1..end) |i| {
                    if (items[i].mask & mask_pref != 0) {
                        if (!(items[i].substituted and items[i].ligated and !items[i].multiplied)) {
                            // A 'pref' candidate that formed nothing:
                            // the base is around here
                            base = i;
                            while (base < end and isHalant(items[base])) base += 1;
                            if (base < end) setPosition(&items[base], .base_c);
                            try_pref = false;
                        }
                        break;
                    }
                }
                if (base == end) break;
            }
            if (start < base and @backingInt(positionOf(items[base])) > @backingInt(Position.base_c)) base -= 1;
            break;
        }
    }
    if (base == end and start < base and isOneOf(items[base - 1], &.{.zwj})) base -= 1;
    if (base < end) {
        while (start < base and isOneOf(items[base], &.{ .n, .h })) base -= 1;
    }

    // Reorder matras
    if (start + 1 < end and start < base) {
        // Lost track of the base: before the last thing
        var new_pos: usize = if (base == end) base - 2 else base - 1;
        search: while (true) {
            while (new_pos > start and !isOneOf(items[new_pos], &.{ .m, .m_pst, .h })) new_pos -= 1;
            // Only after a Halant that is not the matra's own
            if (isHalant(items[new_pos]) and positionOf(items[new_pos]) != .pre_m) {
                // ZWJ after the Halant: keep searching
                if (new_pos + 1 < end and categoryOf(items[new_pos + 1]) == .zwj and new_pos > start) {
                    new_pos -= 1;
                    continue :search;
                }
            } else new_pos = start;
            break;
        }

        if (start < new_pos and positionOf(items[new_pos]) != .pre_m) {
            var i = new_pos;
            while (i > start) : (i -= 1) {
                if (positionOf(items[i - 1]) != .pre_m) continue;
                const old_pos = i - 1;
                if (old_pos < base and base <= new_pos) base -= 1;
                const tmp = items[old_pos];
                std.mem.copyForwards(Glyph, items[old_pos..new_pos], items[old_pos + 1 .. new_pos + 1]);
                items[new_pos] = tmp;
                mergeClusters(items, new_pos, @min(end, base + 1));
                new_pos -= 1;
            }
        } else {
            for (start..base) |i| {
                if (positionOf(items[i]) == .pre_m) {
                    mergeClusters(items, i, @min(end, base + 1));
                    break;
                }
            }
        }
    }

    // Reorder the Reph (Ra + Halant formed by 'rphf'; Devanagari: before
    // post-base forms)
    if (start + 1 < end and positionOf(items[start]) == .ra_to_become_reph and
        ((categoryOf(items[start]) == .repha) != (items[start].ligated and !items[start].multiplied)))
    {
        var new_reph_pos: usize = undefined;
        found: {
            // Step 2: after the first explicit halant between the Reph and
            // the base (and a joiner after it)
            new_reph_pos = start + 1;
            while (new_reph_pos < base and !isHalant(items[new_reph_pos])) new_reph_pos += 1;
            if (new_reph_pos < base and isHalant(items[new_reph_pos])) {
                if (new_reph_pos + 1 < base and isJoiner(items[new_reph_pos + 1])) new_reph_pos += 1;
                break :found;
            }
            // Steps 3 and 4 do not apply to before-post (Devanagari); step 5
            // repeats step 2. Step 6: the end of the syllable, before the
            // syllable modifiers and vedic signs
            new_reph_pos = end - 1;
            while (new_reph_pos > start and positionOf(items[new_reph_pos]) == .smvd) new_reph_pos -= 1;
            // After a Matra + Halant: before that Halant
            if (isHalant(items[new_reph_pos])) {
                // (HarfBuzz re-reads the bound as it moves)
                var i = base + 1;
                while (i < new_reph_pos) : (i += 1) {
                    const c = categoryOf(items[i]);
                    if (c == .m or c == .m_pst) new_reph_pos -= 1;
                }
            }
        }
        mergeClusters(items, start, new_reph_pos + 1);
        const reph = items[start];
        std.mem.copyForwards(Glyph, items[start..new_reph_pos], items[start + 1 .. new_reph_pos + 1]);
        items[new_reph_pos] = reph;
        if (start < base and base <= new_reph_pos) base -= 1;
    }

    // Pre-base reordering consonants ('pref' that ligated)
    if (try_pref and base + 1 < end) {
        for (base + 1..end) |i| {
            if (items[i].mask & mask_pref == 0) continue;
            if (items[i].ligated and !items[i].multiplied) {
                var new_pos = base;
                while (new_pos > start and !isOneOf(items[new_pos - 1], &.{ .m, .m_pst, .h })) new_pos -= 1;
                if (new_pos > start and isHalant(items[new_pos - 1])) {
                    if (new_pos < end and isJoiner(items[new_pos])) new_pos += 1;
                }
                const old_pos = i;
                mergeClusters(items, new_pos, old_pos + 1);
                const tmp = items[old_pos];
                std.mem.copyBackwards(Glyph, items[new_pos + 1 .. old_pos + 1], items[new_pos..old_pos]);
                items[new_pos] = tmp;
                if (new_pos <= base and base < old_pos) base += 1;
            }
            break;
        }
    }

    // 'init' on a left matra at the start of a word
    if (positionOf(items[start]) == .pre_m) {
        const word_before = start > 0 and !items[start - 1].inserted and unicode_props.isWordChar(cps[items[start - 1].cp]);
        if (!word_before) items[start].mask |= mask_init;
    }
}

const testing = std.testing;

fn categories(comptime text: []const u21) [text.len]Category {
    var out: [text.len]Category = undefined;
    for (text, &out) |cp, *o| o.* = props(cp).category;
    return out;
}

fn expectSyllables(comptime text: []const u21, expected: []const Found) !void {
    const cs = categories(text);
    var i: usize = 0;
    var k: usize = 0;
    while (i < cs.len) : (k += 1) {
        const f = nextSyllable(cs[i..]);
        try testing.expect(k < expected.len);
        try testing.expectEqual(expected[k], f);
        i += f.len;
    }
    try testing.expectEqual(expected.len, k);
}

test "props: Devanagari categories and positions as HarfBuzz has them" {
    try testing.expectEqual(Props{ .category = .c, .position = .base_c }, props(0x0915));
    try testing.expectEqual(Props{ .category = .ra, .position = .base_c }, props(0x0930));
    try testing.expectEqual(Props{ .category = .m, .position = .pre_m }, props(0x093F));
    try testing.expectEqual(Props{ .category = .h, .position = .below_c }, props(0x094D));
    try testing.expectEqual(Props{ .category = .placeholder, .position = .base_c }, props('5'));
    try testing.expectEqual(Props{ .category = .x, .position = .end }, props('a'));
}

test "nextSyllable: consonant, vowel, broken and other clusters" {
    // namaste: na | ma | sa virama ta e
    try expectSyllables(&.{ 0x0928, 0x092E, 0x0938, 0x094D, 0x0924, 0x0947 }, &.{
        .{ .kind = .consonant, .len = 1 }, .{ .kind = .consonant, .len = 1 }, .{ .kind = .consonant, .len = 4 },
    });
    // Matras repeat within a syllable (HarfBuzz puts no dotted circle in
    // "ka i i"); a lone matra is a broken cluster
    try expectSyllables(&.{ 0x0915, 0x093F, 0x093F }, &.{.{ .kind = .consonant, .len = 3 }});
    try expectSyllables(&.{ 0x093F, 0x0915 }, &.{ .{ .kind = .broken, .len = 1 }, .{ .kind = .consonant, .len = 1 } });
    // reph + vowel: ra virama a
    try expectSyllables(&.{ 0x0930, 0x094D, 0x0905 }, &.{.{ .kind = .vowel, .len = 3 }});
    // Latin and space are other; ka virama ZWNJ ends the syllable
    try expectSyllables(&.{ 'a', ' ', 0x0915, 0x094D, 0x200C, 0x0937 }, &.{
        .{ .kind = .non_indic, .len = 1 }, .{ .kind = .non_indic, .len = 1 },
        .{ .kind = .consonant, .len = 3 }, .{ .kind = .consonant, .len = 1 },
    });
    // hain: ha + ai + anusvara
    try expectSyllables(&.{ 0x0939, 0x0948, 0x0902 }, &.{.{ .kind = .consonant, .len = 3 }});
}
