//! COLR color-font (Type3) emission subsystem.
//!
//! A color font (COLR paint graphs, OT-SVG documents, or CBDT/sbix/EBDT
//! bitmap strikes) is emitted as one or more PDF Type3 fonts alongside the
//! regular CID font: one CharProc per color glyph, 254 single-byte codes per
//! subfont. `buildColorFontPlans` runs as a pre-pass over the document's text
//! before object-ID reservation; `reserveIds` claims the object IDs;
//! `writeColorFont` emits the objects; `renderColorText` segments text runs
//! between the Type3 and CID fonts. All functions take the owning `*Document`
//! explicitly — the plans live in `Document.color_plans`.

const std = @import("std");
const objects = @import("objects.zig");
const embedded = @import("embedded.zig");
const images = @import("images.zig");
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const svg = @import("svg.zig");
const format = @import("format.zig");
const colr = @import("colr.zig");
const pagemod = @import("page.zig");
const text_render = @import("text_render.zig");

const Document = @import("document.zig").Document;
const Writer = @import("writer.zig").Writer;
const ObjectId = objects.ObjectId;
const Dict = objects.Dict;
const Value = objects.Value;
const EmbeddedFont = embedded.EmbeddedFont;
const Image = images.Image;
const ContentWriter = pagemod.ContentWriter;

/// Output-scoped plan for emitting a COLR color font as a PDF Type3 font.
/// Built in a pre-pass over the document's text before object IDs are reserved.
pub const ColorFontPlan = struct {
    font_index: usize, // index into doc.embedded_fonts
    emb: *EmbeddedFont,
    gids: std.ArrayListUnmanaged(u16) = .empty, // ordered; ordinal = index + 1
    code_of: std.AutoHashMapUnmanaged(u16, u16) = .empty, // original gid → ordinal (1-based)
    char_procs: std.ArrayListUnmanaged([]u8) = .empty, // CharProc content per gid
    widths_fu: std.ArrayListUnmanaged(u16) = .empty, // advance width per gid, font units
    pages: std.AutoHashMapUnmanaged(usize, void) = .empty, // page indices that use this font
    res: colr.ColorResources, // shadings/ExtGStates shared by all subfonts
    /// Bitmap-glyph images, one per image CharProc; referenced as /Im{i+1}
    /// from the shared Resources.
    images: std.ArrayListUnmanaged(PlanImage) = .empty,
    font_obj_ids: std.ArrayListUnmanaged(ObjectId) = .empty, // one font dict per subfont
    tounicode_ids: std.ArrayListUnmanaged(ObjectId) = .empty, // one CMap per subfont
    first_charproc_id: ObjectId = 0, // contiguous block, one stream per gid
    image_obj_ids: std.ArrayListUnmanaged(ObjectId) = .empty, // one per image
    image_smask_ids: std.ArrayListUnmanaged(?ObjectId) = .empty, // per image, if it has alpha
    first_soft_mask_id: ObjectId = 0, // contiguous block, one form per res.soft_masks entry

    /// Subfont index + single-byte PDF code of a color glyph.
    const Slot = struct { sub: usize, code: u8 };

    /// Type3 font resource name number (`/Tc{num}`).
    fn resourceNum(self: ColorFontPlan) usize {
        return self.font_index + 1;
    }

    /// Number of Type3 subfonts needed (254 single-byte codes each).
    fn subfontCount(self: ColorFontPlan) usize {
        return (self.gids.items.len + max_color_glyphs - 1) / max_color_glyphs;
    }

    /// Gid range [lo, hi) of subfont `sub`.
    fn subfontRange(self: ColorFontPlan, sub: usize) struct { lo: usize, hi: usize } {
        const lo = sub * max_color_glyphs;
        return .{ .lo = lo, .hi = @min(self.gids.items.len, lo + max_color_glyphs) };
    }

    /// Single-byte PDF code of the glyph at 0-based index `idx` within its
    /// subfont. Code 32 is never assigned: PDF word spacing (Tw) adds extra
    /// advance to every single-byte code 32, which would silently mis-space
    /// the 32nd color glyph whenever word spacing is active.
    fn localCode(idx: usize) u8 {
        return @intCast(if (idx < 31) idx + 1 else idx + 2);
    }

    /// Subfont + PDF code for a color glyph, or null if it has none (not a
    /// color glyph — caller falls back to the CID font).
    pub fn slotFor(self: ColorFontPlan, gid: u16) ?Slot {
        const ord = self.code_of.get(gid) orelse return null;
        return .{
            .sub = (ord - 1) / max_color_glyphs,
            .code = localCode((ord - 1) % max_color_glyphs),
        };
    }

    fn deinit(self: *ColorFontPlan, allocator: std.mem.Allocator) void {
        self.gids.deinit(allocator);
        self.code_of.deinit(allocator);
        for (self.char_procs.items) |cp| allocator.free(cp);
        self.char_procs.deinit(allocator);
        self.widths_fu.deinit(allocator);
        self.pages.deinit(allocator);
        self.res.deinit();
        for (self.images.items) |img| switch (img) {
            .color => |c| c.deinit(), // deinit destroys the Image itself
            .mask => |m| allocator.free(m.rows),
        };
        self.images.deinit(allocator);
        self.font_obj_ids.deinit(allocator);
        self.tounicode_ids.deinit(allocator);
        self.image_obj_ids.deinit(allocator);
        self.image_smask_ids.deinit(allocator);
    }
};

/// One bitmap-glyph image of a color-font plan: either a decoded PNG strike
/// (CBDT/sbix color glyph) or a 1-bit stencil mask (EBDT pixel glyph;
/// byte-aligned rows, painted in the text color via /ImageMask).
pub const PlanImage = union(enum) {
    color: *Image,
    mask: struct { width: u32, height: u32, rows: []u8 },
};

/// Max distinct color glyphs per Type3 subfont: single-byte PDF codes
/// 1..255 minus code 32 (see ColorFontPlan.localCode). Fonts using more
/// color glyphs are split across multiple Type3 fonts.
pub const max_color_glyphs = 254;

/// Format the /Font resource name of a plan's subfont: `Tc{n}` for the first
/// (the common case, and the historical name), `Tc{n}s{k}` for overflow
/// subfonts past the 255-glyph code space.
pub fn subfontResName(buf: []u8, plan: *const ColorFontPlan, sub: usize) []const u8 {
    return if (sub == 0)
        std.fmt.bufPrint(buf, "Tc{d}", .{plan.resourceNum()}) catch unreachable
    else
        std.fmt.bufPrint(buf, "Tc{d}s{d}", .{ plan.resourceNum(), sub }) catch unreachable;
}

/// Free and reset all color-font plans built for a previous `output()`.
pub fn clearColorPlans(doc: *Document) void {
    for (doc.color_plans.items) |plan| {
        plan.deinit(doc.allocator);
        doc.allocator.destroy(plan);
    }
    doc.color_plans.clearRetainingCapacity();
}

/// Existing plan for `emb`, or null if none has been built.
pub fn colorPlanFor(doc: *Document, emb: *EmbeddedFont) ?*ColorFontPlan {
    for (doc.color_plans.items) |plan| {
        if (plan.emb == emb) return plan;
    }
    return null;
}

/// Pre-pass: scan every page's text for COLR color glyphs and build one
/// Type3 emission plan per color font. Must run before object-ID
/// reservation. Skipped entirely under PDF/A (color Type3 fonts are not
/// emitted; those glyphs fall back to the monochrome CID outline).
pub fn buildColorFontPlans(doc: *Document) !void {
    clearColorPlans(doc);
    if (doc.conformance != .none) return;

    for (doc.pages.items, 0..) |*page, page_idx| {
        for (page.commands.items) |cmd| {
            const t = switch (cmd) {
                .text => |t| t,
                else => continue,
            };
            const emb = switch (t.font) {
                .embedded => |e| e,
                else => continue,
            };
            // Source priority: COLR paint graphs, then OT-SVG documents,
            // then CBDT/sbix PNG strikes / EBDT pixel strikes.
            const has_colr = emb.colorInfo() != null;
            const has_svg = !has_colr and emb.svgInfo() != null;
            if (!has_colr and !has_svg and emb.bitmapInfo() == null) continue;
            const glyphs = t.cached_glyphs orelse continue; // identity fonts always cache
            // Create the plan lazily on the first color glyph, so a color
            // font used only for non-color text (e.g. spaces) never produces
            // an empty (malformed) Type3 font.
            var plan: ?*ColorFontPlan = null;
            for (glyphs) |gid| {
                const is_color = if (has_colr)
                    emb.isColorGlyph(gid)
                else if (has_svg)
                    emb.isSvgGlyph(gid)
                else
                    emb.isBitmapGlyph(gid);
                if (!is_color) continue;
                if (plan == null) plan = try colorPlanForOrCreate(doc, emb);
                try ensureColorGlyph(doc, plan.?, emb, gid);
            }
            if (plan) |p| try p.pages.put(doc.allocator, page_idx, {});
        }
    }
}

fn colorPlanForOrCreate(doc: *Document, emb: *EmbeddedFont) !*ColorFontPlan {
    if (colorPlanFor(doc, emb)) |plan| return plan;
    const font_index = doc.getEmbeddedFontIndex(emb) orelse return error.FontNotRegistered;
    const plan = try doc.allocator.create(ColorFontPlan);
    plan.* = .{
        .font_index = font_index,
        .emb = emb,
        .res = colr.ColorResources.init(doc.allocator),
    };
    try doc.color_plans.append(doc.allocator, plan);
    return plan;
}

/// Assign an ordinal and render the CharProc for one color glyph, if not
/// already present. Ordinals map to (subfont, single-byte code) pairs;
/// every 255 glyphs open a new Type3 subfont, so there is no cap.
fn ensureColorGlyph(doc: *Document, plan: *ColorFontPlan, emb: *EmbeddedFont, gid: u16) !void {
    if (plan.code_of.contains(gid)) return;
    if (plan.gids.items.len >= 0xFFFF) return; // ordinal is u16; unreachable for real fonts
    const content = blk: {
        if (emb.colorInfo()) |info|
            break :blk try renderColorGlyphCharProc(doc.allocator, &plan.res, info, emb, gid);
        const render = if (emb.svgInfo() != null)
            renderSvgGlyphCharProc(doc, emb, gid)
        else
            renderBitmapGlyphCharProc(doc, plan, emb, gid);
        break :blk render catch |err| switch (err) {
            // Unsupported glyph (e.g. an SVG doc using features svg.zig
            // can't render): leave it un-coded so it falls back to the
            // monochrome CID outline.
            error.NotAColorGlyph => return,
            else => return err,
        };
    };
    errdefer doc.allocator.free(content);
    const ord: u16 = @intCast(plan.gids.items.len + 1);
    try plan.gids.append(doc.allocator, gid);
    try plan.char_procs.append(doc.allocator, content);
    try plan.widths_fu.append(doc.allocator, emb.glyphAdvanceFontUnits(gid));
    try plan.code_of.put(doc.allocator, gid, ord);
}

/// Build a Type3 CharProc content stream for a single color glyph:
/// `wx 0 d0` (colored-glyph metrics) followed by the paint operators in
/// glyph space (font units, y-up). Shadings/ExtGStates land in `res`.
fn renderColorGlyphCharProc(
    allocator: std.mem.Allocator,
    res: *colr.ColorResources,
    info: EmbeddedFont.ColorInfo,
    emb: *EmbeddedFont,
    gid: u16,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const wx = emb.glyphAdvanceFontUnits(gid);
    try aw.writer.print("{d} 0 d0\n", .{wx});

    var interp = colr.PaintInterp{
        .w = &aw.writer,
        .arena = arena_state.allocator(),
        .colr = info.colr,
        .cpal = info.cpal,
        .glyf = info.glyf,
        .res = res,
    };
    // A malformed paint graph yields a blank (advance-only) glyph rather
    // than aborting the whole document.
    interp.render(gid) catch {};

    return aw.toOwnedSlice();
}

/// Build a Type3 CharProc for an OT-SVG glyph: parse the glyph's SVG
/// document and emit `wx 0 d0` plus its PDF drawing ops. The document
/// declares no size/viewBox, so svg.zig's output flip is `1 0 0 -1 0 0`
/// — exactly the OT-SVG y-down → glyph-space y-up mirror. Documents
/// using features the renderer can't express in a shared-resource Type3
/// font (transparency, text) fall back to the mono outline.
fn renderSvgGlyphCharProc(doc: *Document, emb: *EmbeddedFont, gid: u16) ![]u8 {
    const table = emb.svgInfo() orelse return error.NotAColorGlyph;
    const svg_doc = table.docForGlyph(gid) orelse return error.NotAColorGlyph;

    const s = svg.Svg.fromMemory(doc.allocator, svg_doc) catch return error.NotAColorGlyph;
    defer {
        s.deinit();
    }

    var opacity_states = std.ArrayListUnmanaged(svg.OpacityState).empty;
    defer opacity_states.deinit(doc.allocator);
    const ops = try s.toPdfContent(doc.allocator, &opacity_states);
    defer doc.allocator.free(ops);
    // Transparency/text usage is only known after rendering (the ops
    // would reference /GS{n} or font resources that the Type3 font's
    // shared Resources dict does not carry).
    if (opacity_states.items.len > 0 or s.hasText()) return error.NotAColorGlyph;

    const wx = emb.glyphAdvanceFontUnits(gid);
    return std.fmt.allocPrint(doc.allocator, "{d} 0 d0\n{s}", .{ wx, ops });
}

/// Build a Type3 CharProc for a bitmap glyph: decode the strike into a
/// plan image and emit the glyph metrics plus a `cm`/`Do` placing
/// /Im{k} in glyph space (strike pixels scaled to font units). Color
/// strikes (PNG) use `d0`; monochrome pixel glyphs use `d1` + ImageMask
/// so they are painted with the current text color.
fn renderBitmapGlyphCharProc(doc: *Document, plan: *ColorFontPlan, emb: *EmbeddedFont, gid: u16) ![]u8 {
    const info = emb.bitmapInfo() orelse return error.NotAColorGlyph;
    const bg = info.glyphBitmap(gid) orelse return error.NotAColorGlyph;

    switch (bg.pixels) {
        .png => |png| {
            // The image borrows the PNG slice (font data outlives the
            // plan) and owns only its decoded/recompressed buffers.
            const img = try Image.fromMemory(doc.allocator, png);
            {
                errdefer {
                    img.deinit();
                }
                try plan.images.append(doc.allocator, .{ .color = img });
            }
        },
        .mono => |mono| {
            const rows = try bitmap_glyphs.packMonoRows(doc.allocator, mono, bg.width_px, bg.height_px);
            {
                errdefer doc.allocator.free(rows);
                try plan.images.append(doc.allocator, .{ .mask = .{
                    .width = bg.width_px,
                    .height = bg.height_px,
                    .rows = rows,
                } });
            }
        },
    }

    const upem: f64 = @floatFromInt(emb.font.head.?.units_per_em);
    const scale = upem / @as(f64, @floatFromInt(info.ppem()));
    const wx = emb.glyphAdvanceFontUnits(gid);
    const w_fu = @as(f64, @floatFromInt(bg.width_px)) * scale;
    const h_fu = @as(f64, @floatFromInt(bg.height_px)) * scale;
    const x_fu = bg.bearing_x * scale;
    const y_fu = bg.bottom_y * scale;
    const im_index = plan.images.items.len; // 1-based /Im index of the image just added

    return switch (bg.pixels) {
        .png => std.fmt.allocPrint(
            doc.allocator,
            "{d} 0 d0\nq\n{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n/Im{d} Do\nQ\n",
            .{ wx, w_fu, h_fu, x_fu, y_fu, im_index },
        ),
        .mono => std.fmt.allocPrint(
            doc.allocator,
            "{d} 0 {d:.2} {d:.2} {d:.2} {d:.2} d1\nq\n{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n/Im{d} Do\nQ\n",
            .{ wx, x_fu, y_fu, x_fu + w_fu, y_fu + h_fu, w_fu, h_fu, x_fu, y_fu, im_index },
        ),
    };
}

/// Write one Type3 bitmap-glyph image XObject: a PNG strike (+ SMask,
/// mirroring the page-image PNG path; no ICC profiles here) or a 1-bit
/// stencil mask for pixel glyphs.
fn writePlanImage(doc: *Document, w: *Writer, plan_image: PlanImage, img_id: ObjectId, smask_id: ?ObjectId) !void {
    const image = switch (plan_image) {
        .color => |c| c,
        .mask => |m| {
            try w.beginObject(img_id);
            var mask_dict = Dict.init(doc.allocator);
            defer mask_dict.deinit();
            try mask_dict.put("Type", Value.name("XObject"));
            try mask_dict.put("Subtype", Value.name("Image"));
            try mask_dict.put("Width", Value.int(@intCast(m.width)));
            try mask_dict.put("Height", Value.int(@intCast(m.height)));
            try mask_dict.put("ImageMask", Value.literal("true"));
            try mask_dict.put("BitsPerComponent", Value.int(1));
            // EBDT bit 1 = ink; ImageMask paints where the decoded
            // sample is 0, so invert.
            try mask_dict.put("Decode", Value.literal("[1 0]"));
            try w.writeStreamCompressed(&mask_dict, m.rows);
            try w.endObject();
            return;
        },
    };

    if (smask_id) |sid| {
        try w.beginObject(sid);
        var smask_dict = Dict.init(doc.allocator);
        defer smask_dict.deinit();
        try smask_dict.put("Type", Value.name("XObject"));
        try smask_dict.put("Subtype", Value.name("Image"));
        try smask_dict.put("Width", Value.int(@intCast(image.width)));
        try smask_dict.put("Height", Value.int(@intCast(image.height)));
        try smask_dict.put("ColorSpace", Value.name("DeviceGray"));
        try smask_dict.put("BitsPerComponent", Value.int(image.alpha_bits_per_component));
        try smask_dict.put("Filter", Value.name("FlateDecode")); // alpha is pre-compressed
        try w.writeStream(&smask_dict, image.alpha_data.?);
        try w.endObject();
    }

    try w.beginObject(img_id);
    var img_dict = Dict.init(doc.allocator);
    defer img_dict.deinit();
    try img_dict.put("Type", Value.name("XObject"));
    try img_dict.put("Subtype", Value.name("Image"));
    try img_dict.put("Width", Value.int(@intCast(image.width)));
    try img_dict.put("Height", Value.int(@intCast(image.height)));
    try img_dict.put("ColorSpace", Value.name(image.color_space.pdfName()));
    try img_dict.put("BitsPerComponent", Value.int(image.bits_per_component));
    try img_dict.put("Filter", Value.name("FlateDecode")); // PNG pixels are re-compressed
    if (smask_id) |sid| {
        try img_dict.put("SMask", Value.ref(.{ .id = sid }));
    }
    try w.writeStream(&img_dict, image.data);
    try w.endObject();
}

/// Emit a COLR color font as one or more PDF Type3 fonts: one CharProc
/// stream per color glyph plus a font dictionary (Encoding/CharProcs/
/// Widths/FontMatrix/Resources) per 255-glyph subfont. Glyph space is font
/// units, mapped to text space by FontMatrix [1/upem ...], matching the
/// CID font's advances.
pub fn writeColorFont(doc: *Document, w: *Writer, plan: *ColorFontPlan) !void {
    // 1. CharProc streams (one contiguous block covering all subfonts).
    for (plan.char_procs.items, 0..) |content, i| {
        try w.beginObject(plan.first_charproc_id + @as(ObjectId, @intCast(i)));
        var cp_dict = Dict.init(doc.allocator);
        defer cp_dict.deinit();
        try w.writeStreamCompressed(&cp_dict, content);
        try w.endObject();
    }

    // 1b. Image XObjects for bitmap (CBDT/sbix) glyphs.
    for (plan.images.items, 0..) |img, i| {
        try writePlanImage(doc, w, img, plan.image_obj_ids.items[i], plan.image_smask_ids.items[i]);
    }

    // 1c. Soft-mask forms (gradient stop alpha): a gray transparency group
    // painting the mask's shading over any glyph's extent.
    for (plan.res.soft_masks.items, 0..) |shading, i| {
        try w.beginObject(plan.first_soft_mask_id + @as(ObjectId, @intCast(i)));
        var form = Dict.init(doc.allocator);
        defer form.deinit();
        const resources = try std.fmt.allocPrint(doc.allocator, "<< /Shading << /Sh1 {s} >> >>", .{shading});
        defer doc.allocator.free(resources);
        try form.put("Type", Value.name("XObject"));
        try form.put("Subtype", Value.name("Form"));
        try form.put("BBox", Value.literal("[-32768 -32768 32768 32768]"));
        try form.put("Group", Value.literal("<< /S /Transparency /CS /DeviceGray >>"));
        try form.put("Resources", Value.literal(resources));
        try w.writeStreamCompressed(&form, "/Sh1 sh\n");
        try w.endObject();
    }

    // 2. Font dictionaries. Composite entries are built as literal strings
    // in an arena so their backing memory outlives writeDict.
    var arena_state = std.heap.ArenaAllocator.init(doc.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = plan.emb.font.head.?;
    const upem: f64 = @floatFromInt(head.units_per_em);
    const inv = 1.0 / upem;

    const font_matrix = try std.fmt.allocPrint(arena, "[{d:.10} 0 0 {d:.10} 0 0]", .{ inv, inv });
    // A font without outlines (bitmap-only, e.g. OTB pixel fonts) has an
    // empty head box that no glyph fits; all zeros tells the viewer to make
    // no assumptions about glyph sizes (PDF 32000 9.6.5)
    const font_bbox = if (head.x_min < head.x_max and head.y_min < head.y_max)
        try std.fmt.allocPrint(arena, "[{d} {d} {d} {d}]", .{ head.x_min, head.y_min, head.x_max, head.y_max })
    else
        "[0 0 0 0]";

    // All subfonts share the plan's accumulated shadings/ExtGStates.
    const resources = try buildColorFontResources(arena, plan);

    for (0..plan.subfontCount()) |sub| {
        const range = plan.subfontRange(sub);
        const count = range.hi - range.lo;
        const last_code = ColorFontPlan.localCode(count - 1);

        // CharProcs: << /g1 id 0 R ... >> (codes local to the subfont;
        // code 32 is never assigned, see ColorFontPlan.localCode).
        var cp = std.Io.Writer.Allocating.init(arena);
        try cp.writer.writeAll("<< ");
        for (0..count) |i| {
            try cp.writer.print("/g{d} {d} 0 R ", .{ ColorFontPlan.localCode(i), plan.first_charproc_id + @as(ObjectId, @intCast(range.lo + i)) });
        }
        try cp.writer.writeAll(">>");

        // Encoding: << /Type /Encoding /Differences [1 /g1 ... /g31 33
        // /g33 ... ] >> (a restart marker jumps over unassigned code 32).
        var enc = std.Io.Writer.Allocating.init(arena);
        try enc.writer.writeAll("<< /Type /Encoding /Differences [1");
        var prev_code: u8 = 0;
        for (0..count) |i| {
            const code = ColorFontPlan.localCode(i);
            if (i > 0 and code != prev_code + 1) {
                try enc.writer.print(" {d}", .{code});
            }
            try enc.writer.print(" /g{d}", .{code});
            prev_code = code;
        }
        try enc.writer.writeAll("] >>");

        // Widths: [w1 w2 ...] in glyph space (font units), contiguous
        // from FirstChar; the unassigned code 32 gets a zero entry.
        var wd = std.Io.Writer.Allocating.init(arena);
        try wd.writer.writeByte('[');
        {
            var i: usize = 0;
            var code: usize = 1; // wider than u8: code 255 + 1 must not overflow
            while (code <= last_code) : (code += 1) {
                if (code > 1) try wd.writer.writeByte(' ');
                if (code == 32) {
                    try wd.writer.writeByte('0');
                    continue;
                }
                try wd.writer.print("{d}", .{plan.widths_fu.items[range.lo + i]});
                i += 1;
            }
        }
        try wd.writer.writeByte(']');

        // ToUnicode CMap so viewers can extract/copy the emoji as their
        // real codepoints (color glyph codes are otherwise opaque bytes).
        const tounicode = try buildColorFontToUnicode(arena, plan, range.lo, range.hi);
        const tounicode_id = plan.tounicode_ids.items[sub];

        try w.beginObject(tounicode_id);
        {
            var tu_dict = Dict.init(doc.allocator);
            defer tu_dict.deinit();
            try w.writeStreamCompressed(&tu_dict, tounicode);
        }
        try w.endObject();

        try w.beginObject(plan.font_obj_ids.items[sub]);
        var font_dict = Dict.init(doc.allocator);
        defer font_dict.deinit();
        try font_dict.put("Type", Value.name("Font"));
        try font_dict.put("Subtype", Value.name("Type3"));
        try font_dict.put("FontBBox", Value.literal(font_bbox));
        try font_dict.put("FontMatrix", Value.literal(font_matrix));
        try font_dict.put("CharProcs", Value.literal(cp.writer.buffered()));
        try font_dict.put("Encoding", Value.literal(enc.writer.buffered()));
        try font_dict.put("FirstChar", Value.int(1));
        try font_dict.put("LastChar", Value.int(last_code));
        try font_dict.put("Widths", Value.literal(wd.writer.buffered()));
        try font_dict.put("Resources", Value.literal(resources));
        try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));
        try w.writeDict(font_dict);
        try w.endObject();
    }
}

/// Build a single-byte ToUnicode CMap for one subfont's gid range
/// [lo, hi), mapping each color glyph's PDF code to the text it was shaped
/// from - one code point, or the whole sequence of a ligature (emoji ZWJ
/// sequences, flags, keycaps) - in UTF-16 (astral code points as
/// surrogate pairs).
fn buildColorFontToUnicode(arena: std.mem.Allocator, plan: *ColorFontPlan, lo: usize, hi: usize) ![]u8 {
    var w = std.Io.Writer.Allocating.init(arena);
    try w.writer.writeAll(
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
    try w.writer.print("{d} beginbfchar\n", .{hi - lo});
    for (plan.gids.items[lo..hi], 0..) |gid, i| {
        const code = ColorFontPlan.localCode(i);
        var single: [1]u21 = .{0xFFFD};
        const text: []const u21 = if (plan.emb.glyph_to_codepoint.get(gid)) |cp| blk: {
            single[0] = cp;
            break :blk &single;
        } else plan.emb.ligature_codepoints.get(gid) orelse &single;
        try w.writer.print("<{X:0>2}> <", .{code});
        for (text) |cp| {
            if (cp > 0xFFFF) {
                const adjusted = cp - 0x10000;
                const high: u16 = @intCast(0xD800 + (adjusted >> 10));
                const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                try w.writer.print("{X:0>4}{X:0>4}", .{ high, low });
            } else {
                try w.writer.print("{X:0>4}", .{cp});
            }
        }
        try w.writer.writeAll(">\n");
    }
    try w.writer.writeAll(
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    );
    return w.writer.buffered();
}

/// Build the Type3 font's /Resources literal from the plan's accumulated
/// shadings (/Sh{n}), ExtGStates (/Ga{n}, soft masks /Gm{n}) and bitmap
/// images (/Im{n}).
fn buildColorFontResources(arena: std.mem.Allocator, plan: *ColorFontPlan) ![]u8 {
    var r = std.Io.Writer.Allocating.init(arena);
    try r.writer.writeAll("<<");
    if (plan.images.items.len > 0) {
        try r.writer.writeAll(" /XObject <<");
        for (plan.image_obj_ids.items, 0..) |id, i| {
            try r.writer.print(" /Im{d} {d} 0 R", .{ i + 1, id });
        }
        try r.writer.writeAll(" >>");
    }
    if (plan.res.shadings.items.len > 0) {
        try r.writer.writeAll(" /Shading <<");
        for (plan.res.shadings.items, 0..) |body, i| {
            try r.writer.print(" /Sh{d} {s}", .{ i + 1, body });
        }
        try r.writer.writeAll(" >>");
    }
    if (plan.res.ext_gstates.items.len > 0 or plan.res.soft_masks.items.len > 0) {
        try r.writer.writeAll(" /ExtGState <<");
        for (plan.res.ext_gstates.items, 0..) |body, i| {
            try r.writer.print(" /Ga{d} {s}", .{ i + 1, body });
        }
        for (0..plan.res.soft_masks.items.len) |i| {
            try r.writer.print(" /Gm{d} << /Type /ExtGState /SMask << /S /Luminosity /G {d} 0 R >> >>", .{ i + 1, plan.first_soft_mask_id + i });
        }
        try r.writer.writeAll(" >>");
    }
    try r.writer.writeAll(" >>");
    return r.writer.buffered();
}

/// Render a text run through a font that has color glyphs, segmenting into
/// maximal same-kind sub-runs: color glyphs use the Type3 font (`/Tc{n}`,
/// single-byte codes), the rest use the CID font (`/E{n}`, 2-byte GIDs).
/// Both fonts share the text position — each `Tj` advances by the shown
/// glyphs' widths, which agree between the two encodings. Kerning/marks are
/// not applied here (color fonts are typically emoji, which do not kern).
pub fn renderColorText(
    cw: *ContentWriter,
    emb: *EmbeddedFont,
    plan: *ColorFontPlan,
    glyphs: []const u16,
    font_size: f64,
    x: f64,
    y: f64,
    word_spacing: f64,
) !void {
    if (glyphs.len == 0) return;
    const cid_res = plan.font_index + 1; // /E{n}
    const has_remap = emb.gid_remap.count() > 0;
    // Tw never reaches these runs (2-byte CID codes; code 32 is unassigned
    // in the Type3 subfonts), so word spacing goes after space glyphs as
    // TJ adjustments in the mono segments
    const space_gid = text_render.spaceGlyph(emb, glyphs, word_spacing);
    const ws_1000 = text_render.wordSpacing1000(word_spacing, font_size);

    try cw.print("{d:.2} {d:.2} Td\n", .{ x, y });

    var hex_buf: [4]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < glyphs.len) {
        // Sub-run key: the Type3 subfont index, or null for mono glyphs.
        const sub: ?usize = if (plan.slotFor(glyphs[i])) |s| s.sub else null;
        var j = i + 1;
        while (j < glyphs.len) : (j += 1) {
            const sub_j: ?usize = if (plan.slotFor(glyphs[j])) |s| s.sub else null;
            if (!std.meta.eql(sub, sub_j)) break;
        }

        if (sub) |s| {
            try cw.print("/{s} {d:.2} Tf\n", .{ subfontResName(&name_buf, plan, s), font_size });
            try cw.append("<");
            for (glyphs[i..j]) |g| {
                try cw.print("{x:0>2}", .{plan.slotFor(g).?.code});
            }
            try cw.append("> Tj\n");
        } else {
            try cw.print("/E{d} {d:.2} Tf\n", .{ cid_res, font_size });
            // A space ending the segment still widens the gap: the next
            // segment continues from the advanced position
            const widen = if (space_gid) |sp| std.mem.indexOfScalar(u16, glyphs[i..@min(j, glyphs.len - 1)], sp) != null else false;
            try cw.append(if (widen) "[<" else "<");
            for (glyphs[i..j], i..) |g, k| {
                const final_gid = if (has_remap) emb.gid_remap.get(g) orelse 0 else g;
                format.writeHex4(&hex_buf, final_gid);
                try cw.append(&hex_buf);
                if (widen and g == space_gid.? and k + 1 < glyphs.len) {
                    try cw.writeKernAdjust(-ws_1000);
                }
            }
            try cw.append(if (widen) ">] TJ\n" else "> Tj\n");
        }
        i = j;
    }
}
/// Reserve object IDs for all color-font plans, starting at `next_id`:
/// per 255-glyph subfont a font dict + ToUnicode CMap, one stream per
/// CharProc (color glyph), one form per gradient soft mask, and for bitmap
/// glyphs an image XObject (+ SMask when it has alpha). Returns the next free object ID.
pub fn reserveIds(doc: *Document, start_id: ObjectId) !ObjectId {
    var next_id = start_id;
    for (doc.color_plans.items) |plan| {
        for (0..plan.subfontCount()) |_| {
            try plan.font_obj_ids.append(doc.allocator, next_id);
            try plan.tounicode_ids.append(doc.allocator, next_id + 1);
            next_id += 2;
        }
        plan.first_charproc_id = next_id;
        next_id += @intCast(plan.gids.items.len);
        plan.first_soft_mask_id = next_id;
        next_id += @intCast(plan.res.soft_masks.items.len);
        for (plan.images.items) |img| {
            try plan.image_obj_ids.append(doc.allocator, next_id);
            next_id += 1;
            const has_smask = switch (img) {
                .color => |c| c.alpha_data != null,
                .mask => false,
            };
            if (has_smask) {
                try plan.image_smask_ids.append(doc.allocator, next_id);
                next_id += 1;
            } else {
                try plan.image_smask_ids.append(doc.allocator, null);
            }
        }
    }
    return next_id;
}
