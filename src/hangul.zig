//! HarfBuzz's Hangul shaper (hb-ot-shaper-hangul.cc), for text whose
//! script is Hangul:
//!
//! - conjoining jamo L V or L V T become their precomposed syllable when
//!   the font has it, and a syllable LV followed by T becomes LVT;
//! - otherwise the jamo take the ljmo, vjmo and tjmo features; a
//!   precomposed syllable the font lacks (or an LV before a T it cannot
//!   take) is first decomposed into its jamo, when the font has them;
//! - a tone mark (U+302E, U+302F) right after a syllable moves before it,
//!   unless it is zero-width; with no syllable before it, it gets a
//!   dotted circle.
//!
//! Each syllable is one cluster. Nothing else is recomposed
//! (normalization mode NONE), 'calt' is off, and marks keep their
//! advances (no mark zeroing, no fallback positioning).

const std = @import("std");
const decode = @import("decode.zig");
const gsub = @import("gsub.zig");
const opentype = @import("opentype.zig");
const ttf = @import("ttf.zig");
const unicode_props = @import("unicode_props.zig");
const unicode_compose = @import("unicode_compose.zig");

const Allocator = std.mem.Allocator;
const LookupParams = gsub.LookupParams;

const s_base: u21 = 0xAC00;
const l_base: u21 = 0x1100;
const v_base: u21 = 0x1161;
const t_base: u21 = 0x11A7;
const l_count = 19;
const v_count = 21;
const t_count = 28;
const n_count = v_count * t_count;
const s_count = l_count * n_count;

fn isL(u: u21) bool {
    return (u >= 0x1100 and u <= 0x115F) or (u >= 0xA960 and u <= 0xA97C);
}
fn isV(u: u21) bool {
    return (u >= 0x1160 and u <= 0x11A7) or (u >= 0xD7B0 and u <= 0xD7C6);
}
fn isT(u: u21) bool {
    return (u >= 0x11A8 and u <= 0x11FF) or (u >= 0xD7CB and u <= 0xD7FB);
}
fn isTone(u: u21) bool {
    return u == 0x302E or u == 0x302F;
}
fn isCombiningL(u: u21) bool {
    return u >= l_base and u < l_base + l_count;
}
fn isCombiningV(u: u21) bool {
    return u >= v_base and u < v_base + v_count;
}
fn isCombiningT(u: u21) bool {
    return u > t_base and u < t_base + t_count;
}
fn isCombinedS(u: u21) bool {
    return u >= s_base and u < s_base + s_count;
}

/// The canonical decomposition of a precomposed syllable (algorithmic,
/// not in UnicodeData): LV -> L, V and LVT -> LV, T. Null otherwise.
pub fn decompose(cp: u21) ?[2]u21 {
    if (!isCombinedS(cp)) return null;
    const si = cp - s_base;
    const ti = si % t_count;
    if (ti != 0) return .{ cp - ti, t_base + ti };
    return .{ l_base + si / n_count, v_base + (si % n_count) / t_count };
}

/// The jamo feature the shaper gives a code point (Decoded.jamo); or
/// `tone_circle`, a dotted circle inserted for a tone mark, which sorts
/// with the tone mark's combining class in normalization.
pub const Jamo = enum(u8) { none, ljmo, vjmo, tjmo, tone_circle = unicode_compose.tag_tone_class };

const mask_ljmo: u8 = 2;
const mask_vjmo: u8 = 4;
const mask_tjmo: u8 = 8;

fn maskOf(j: Jamo) u8 {
    return switch (j) {
        .none, .tone_circle => 0,
        .ljmo => mask_ljmo,
        .vjmo => mask_vjmo,
        .tjmo => mask_tjmo,
    };
}

fn hasGlyph(font: *const ttf.Font, cp: u21) bool {
    return (font.getGlyphId(cp) orelse 0) != 0;
}

/// HarfBuzz's is_zero_width_char: the font has it, with no advance.
fn isZeroWidth(font: *const ttf.Font, cp: u21) bool {
    const gid = font.getGlyphId(cp) orelse 0;
    return gid != 0 and (font.getGlyphWidth(gid) orelse 0) == 0;
}

/// The output of `preprocess`, built as HarfBuzz's out-buffer.
const Out = struct {
    cps: std.ArrayListUnmanaged(u21) = .empty,
    offsets: std.ArrayListUnmanaged(u32) = .empty,
    spans: std.ArrayListUnmanaged([2]u32) = .empty,
    jamo: std.ArrayListUnmanaged(u8) = .empty,

    fn append(o: *Out, cp: u21, offset: u32, span: [2]u32, jamo: Jamo) void {
        o.cps.appendAssumeCapacity(cp);
        o.offsets.appendAssumeCapacity(offset);
        o.spans.appendAssumeCapacity(span);
        o.jamo.appendAssumeCapacity(@backingInt(jamo));
    }

    fn len(o: *const Out) usize {
        return o.cps.items.len;
    }
};

/// HarfBuzz's form_clusters and then the Hangul shaper's preprocess_text,
/// on `d` as decoded (with offsets) before normalization. Clusters are
/// carried in `d.offsets`, as HarfBuzz carries them in byte values: a
/// continuation (a mark...) takes its predecessor's offset, and merged
/// ranges take their smallest. Fills `d.jamo`.
pub fn preprocess(allocator: Allocator, font: *const ttf.Font, d: *decode.Decoded) !void {
    const cps = d.codepoints.items;
    const offsets = d.offsets.items;
    const spans = d.spans.items;
    const n = cps.len;

    const cont = try allocator.alloc(bool, n);
    defer allocator.free(cont);
    unicode_props.markContinuations(cps, cont);
    for (1..n) |i| {
        if (cont[i]) offsets[i] = offsets[i - 1];
    }

    // A tone mark may become two code points (with a dotted circle);
    // nothing else grows
    var out: Out = .{};
    errdefer {
        out.cps.deinit(allocator);
        out.offsets.deinit(allocator);
        out.spans.deinit(allocator);
        out.jamo.deinit(allocator);
    }
    try out.cps.ensureTotalCapacity(allocator, 2 * n);
    try out.offsets.ensureTotalCapacity(allocator, 2 * n);
    try out.spans.ensureTotalCapacity(allocator, 2 * n);
    try out.jamo.ensureTotalCapacity(allocator, 2 * n);

    // The last syllable's range in the output (start < end: one ends there)
    var start: usize = 0;
    var end: usize = 0;
    var i: usize = 0;
    while (i < n) {
        const u = cps[i];
        if (isTone(u)) {
            if (start < end and end == out.len()) {
                // A tone mark after a syllable goes before it, unless it
                // is zero-width
                out.append(u, offsets[i], spans[i], .none);
                i += 1;
                if (!isZeroWidth(font, u)) {
                    mergeOut(&out, offsets[i..], start, end + 1);
                    rotateRight(&out, start, end + 1);
                }
            } else if (hasGlyph(font, 0x25CC)) {
                // No syllable for it: a dotted circle, after it unless it
                // is zero-width (both in its cluster; the circle has the
                // tone mark's properties, as replace_glyphs copies them)
                const empty: [2]u32 = .{ spans[i][1], spans[i][1] };
                if (!isZeroWidth(font, u)) {
                    out.append(u, offsets[i], spans[i], .none);
                    out.append(0x25CC, offsets[i], empty, .tone_circle);
                } else {
                    out.append(0x25CC, offsets[i], empty, .tone_circle);
                    out.append(u, offsets[i], spans[i], .none);
                }
                i += 1;
            } else {
                out.append(u, offsets[i], spans[i], .none);
                i += 1;
            }
            start = out.len();
            end = out.len();
            continue;
        }
        start = out.len();

        if (isL(u) and i + 1 < n) {
            const l = u;
            const v = cps[i + 1];
            if (isV(v)) {
                // <L,V> or <L,V,T>
                var t: u21 = 0;
                var tindex: u21 = 0;
                if (i + 2 < n and isT(cps[i + 2])) {
                    t = cps[i + 2];
                    tindex = t - t_base;
                }
                const k: usize = if (t != 0) 3 else 2;
                if (isCombiningL(l) and isCombiningV(v) and (t == 0 or isCombiningT(t))) {
                    const s = s_base + (l - l_base) * n_count + (v - v_base) * t_count + tindex;
                    if (hasGlyph(font, s)) {
                        replace(&out, offsets, spans, i, k, s);
                        i += k;
                        end = start + 1;
                        continue;
                    }
                }
                // Not composed (Old Hangul, or the font lacks the
                // syllable): the jamo take their features
                out.append(l, offsets[i], spans[i], .ljmo);
                out.append(v, offsets[i + 1], spans[i + 1], .vjmo);
                if (t != 0) out.append(t, offsets[i + 2], spans[i + 2], .tjmo);
                i += k;
                end = start + k;
                mergeOut(&out, offsets[i..], start, end);
                continue;
            }
        } else if (isCombinedS(u)) {
            // <LV>, <LVT> or <LV,T>
            const has = hasGlyph(font, u);
            const lindex = (u - s_base) / n_count;
            const nindex = (u - s_base) % n_count;
            const vindex = nindex / t_count;
            const tindex = nindex % t_count;
            const next_t = tindex == 0 and i + 1 < n and isT(cps[i + 1]);

            if (next_t and isCombiningT(cps[i + 1])) {
                // <LV,T>: try LVT
                const new_s = u + (cps[i + 1] - t_base);
                if (hasGlyph(font, new_s)) {
                    replace(&out, offsets, spans, i, 2, new_s);
                    i += 2;
                    end = start + 1;
                    continue;
                }
            }

            // Decomposed when the font lacks <LV> or <LVT>, or before a T
            // it could not take (a combining one is handled above)
            if (!has or next_t) {
                const parts = [3]u21{ l_base + lindex, v_base + vindex, t_base + tindex };
                if (hasGlyph(font, parts[0]) and hasGlyph(font, parts[1]) and (tindex == 0 or hasGlyph(font, parts[2]))) {
                    const empty: [2]u32 = .{ spans[i][1], spans[i][1] };
                    out.append(parts[0], offsets[i], spans[i], .ljmo);
                    out.append(parts[1], offsets[i], empty, .vjmo);
                    var s_len: usize = 2;
                    if (tindex != 0) {
                        out.append(parts[2], offsets[i], empty, .tjmo);
                        s_len = 3;
                    }
                    i += 1;
                    // An LV decomposed because of the T after it takes it
                    // into the syllable
                    if (has and tindex == 0) {
                        out.append(cps[i], offsets[i], spans[i], .tjmo);
                        i += 1;
                        s_len += 1;
                    }
                    end = start + s_len;
                    mergeOut(&out, offsets[i..], start, end);
                    continue;
                }
            }
            // Not decomposed: kept as it is
            if (has) end = start + 1;
        }

        // Not a syllable start we know: end <= start, so no tone mark
        // moves before it
        out.append(u, offsets[i], spans[i], .none);
        i += 1;
    }

    d.codepoints.deinit(allocator);
    d.codepoints = out.cps;
    d.offsets.deinit(allocator);
    d.offsets = out.offsets;
    d.spans.deinit(allocator);
    d.spans = out.spans;
    d.jamo.deinit(allocator);
    d.jamo = out.jamo;
}

/// HarfBuzz's replace_glyphs(k, 1, s): input [i, i+k) becomes `s` with
/// their merged cluster (and the text of all of them).
fn replace(out: *Out, offsets: []u32, spans: []const [2]u32, i: usize, k: usize, s: u21) void {
    // merge_clusters(i, i+k): the smallest (the first: clusters do not
    // decrease), extended over the following input that shares the last
    const cluster = offsets[i];
    const last = offsets[i + k - 1];
    var j = i + k;
    while (j < offsets.len and offsets[j] == last) : (j += 1) offsets[j] = cluster;
    var span = spans[i];
    for (spans[i + 1 .. i + k]) |sp| {
        if (sp[0] == sp[1]) continue;
        if (span[0] == span[1]) {
            span = sp;
            continue;
        }
        span = .{ @min(span[0], sp[0]), @max(span[1], sp[1]) };
    }
    out.append(s, cluster, span, .none);
}

/// HarfBuzz's merge_out_clusters(start, end): the output range takes its
/// smallest cluster, extended over the output before it and the input
/// after it (`rest`) that share an end's cluster.
fn mergeOut(out: *Out, rest: []u32, start_in: usize, end_in: usize) void {
    const offs = out.offsets.items;
    var start = start_in;
    var end = end_in;
    if (end - start < 2) return;
    var cluster = offs[start];
    for (offs[start + 1 .. end]) |c| cluster = @min(cluster, c);
    while (start > 0 and offs[start - 1] == offs[start]) start -= 1;
    while (end < offs.len and offs[end - 1] == offs[end]) end += 1;
    if (end == offs.len) {
        const last = offs[end - 1];
        for (rest) |*c| {
            if (c.* != last) break;
            c.* = cluster;
        }
    }
    for (offs[start..end]) |*c| c.* = cluster;
}

/// Moves the output's item at end-1 to `start`, the others up one.
fn rotateRight(out: *Out, start: usize, end: usize) void {
    std.mem.rotate(u21, out.cps.items[start..end], end - start - 1);
    std.mem.rotate(u32, out.offsets.items[start..end], end - start - 1);
    std.mem.rotate([2]u32, out.spans.items[start..end], end - start - 1);
    std.mem.rotate(u8, out.jamo.items[start..end], end - start - 1);
}

/// The Hangul shaper's GSUB lookups for one font and feature set: the
/// language system's required feature and the enabled features (not
/// 'calt', which the Hangul shaper turns off), global; ljmo, vjmo and
/// tjmo on the jamo `preprocess` marks (ljmo with manual joiners), all in
/// one stage, as HarfBuzz orders them.
pub const Plan = struct {
    table: *const gsub.Table,
    lookups: []LookupParams,
    storage: []LookupParams,

    pub fn init(allocator: Allocator, table: *const gsub.Table, flags: opentype.FeatureFlags) !Plan {
        const map = table.langSys(.hangul);
        var list: std.ArrayListUnmanaged(LookupParams) = .empty;
        defer list.deinit(allocator);
        for (map.required_lookups) |li| try list.append(allocator, .{ .index = li });
        for (std.enums.values(opentype.Feature)) |f| {
            const lp: LookupParams = switch (f) {
                .ljmo => .{ .index = 0, .mask = mask_ljmo, .auto_zwj = false },
                .vjmo => .{ .index = 0, .mask = mask_vjmo },
                .tjmo => .{ .index = 0, .mask = mask_tjmo },
                .calt => continue,
                else => if (flags.isEnabled(f)) .{ .index = 0 } else continue,
            };
            for (map.feature_lookups[opentype.FeatureFlags.featureIndex(f)]) |li| {
                if (li >= table.lookups.len) continue;
                var p = lp;
                p.index = li;
                try list.append(allocator, p);
            }
        }
        const storage = try list.toOwnedSlice(allocator);
        return .{ .table = table, .lookups = gsub.mergeLookups(storage), .storage = storage };
    }

    pub fn deinit(self: Plan, allocator: Allocator) void {
        allocator.free(self.storage);
    }
};

/// Substitutes the shaper's buffer (begun from `preprocess`'s code
/// points): each glyph takes its jamo feature's mask, then the plan's
/// lookups apply.
pub fn substitute(allocator: Allocator, shaper: *gsub.Shaper, plan: *const Plan, jamo: []const u8) ![]const gsub.Glyph {
    for (shaper.buf.items) |*g| g.mask |= maskOf(@fromBackingInt(@intCast(jamo[g.cp])));
    shaper.applyStage(plan.table, plan.lookups);
    return shaper.finish(allocator);
}

// ============================================================================
// Tests (HarfBuzz differential: shaping_test.zig)
// ============================================================================

const testing = std.testing;

test "decompose: LV into L V, LVT into LV T" {
    try testing.expectEqual([2]u21{ 0x1100, 0x1161 }, decompose(0xAC00).?); // 가
    try testing.expectEqual([2]u21{ 0xD558, 0x11AB }, decompose(0xD55C).?); // 한 = 하 + ᆫ
    try testing.expectEqual([2]u21{ 0x1112, 0x1161 }, decompose(0xD558).?); // 하
    try testing.expect(decompose(0xD7A4) == null);
    try testing.expect(decompose(0x1100) == null);
}
