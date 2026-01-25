//! PDF output generation for zpdf.
//!
//! This module handles the serialization of Document data to PDF format.
//! It's separated from document.zig to reduce file size and improve modularity.

const std = @import("std");
const objects = @import("objects.zig");
const fonts = @import("fonts.zig");
const embedded = @import("embedded.zig");
const gradient = @import("gradient.zig");
const Writer = @import("writer.zig").Writer;

const ObjectId = objects.ObjectId;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;
const EmbeddedFont = embedded.EmbeddedFont;
const StandardFont = fonts.StandardFont;

// ============================================================================
// Resource Naming
// ============================================================================

/// Get PDF resource name for a standard font.
pub fn fontResourceName(font: StandardFont) []const u8 {
    return switch (font) {
        .helvetica => "F1",
        .helvetica_bold => "F2",
        .helvetica_oblique => "F3",
        .helvetica_bold_oblique => "F4",
        .times_roman => "F5",
        .times_bold => "F6",
        .times_italic => "F7",
        .times_bold_italic => "F8",
        .courier => "F9",
        .courier_bold => "F10",
        .courier_oblique => "F11",
        .courier_bold_oblique => "F12",
        .symbol => "F13",
        .zapf_dingbats => "F14",
    };
}

/// Generate resource names at comptime.
fn makeResourceNames(comptime prefix: []const u8, comptime count: usize) [count][]const u8 {
    @setEvalBranchQuota(10000);
    var names: [count][]const u8 = undefined;
    for (0..count) |i| {
        names[i] = std.fmt.comptimePrint("{s}{d}", .{ prefix, i + 1 });
    }
    return names;
}

fn getResourceName(comptime names: []const []const u8, idx: usize, comptime fallback: []const u8) []const u8 {
    return if (idx < names.len) names[idx] else fallback;
}

const embedded_font_names = makeResourceNames("E", 32);
const image_names = makeResourceNames("Im", 32);
const svg_names = makeResourceNames("Sv", 32);
const extgstate_names = makeResourceNames("GS", 32);
const shading_names = makeResourceNames("Sh", 16);

pub fn embeddedFontResourceName(idx: usize) []const u8 {
    return getResourceName(&embedded_font_names, idx, "E99");
}

pub fn imageResourceName(idx: usize) []const u8 {
    return getResourceName(&image_names, idx, "Im99");
}

pub fn svgResourceName(idx: usize) []const u8 {
    return getResourceName(&svg_names, idx, "Sv99");
}

pub fn extgstateResourceName(idx: usize) []const u8 {
    return getResourceName(&extgstate_names, idx, "GS99");
}

pub fn shadingResourceName(idx: usize) []const u8 {
    return getResourceName(&shading_names, idx, "Sh99");
}

// ============================================================================
// Output Timing
// ============================================================================

/// Output timing information for performance analysis.
pub const OutputTiming = struct {
    subset_ms: i64 = 0,
    render_ms: i64 = 0,
    font_write_ms: i64 = 0,
    page_write_ms: i64 = 0,
    finish_ms: i64 = 0,
};

/// Last output timing (for performance debugging).
pub var last_output_timing: OutputTiming = .{};

// ============================================================================
// Helper Functions
// ============================================================================

/// Format current UTC time as PDF date string: D:YYYYMMDDHHmmSSZ
/// Returns a slice into the provided buffer.
pub fn formatPdfDate(buf: *[24]u8) []const u8 {
    const timestamp = std.time.timestamp();
    const epoch_secs: u64 = @intCast(timestamp);
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    _ = std.fmt.bufPrint(buf, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;

    return buf[0..17]; // "D:YYYYMMDDHHmmSSZ"
}

// ============================================================================
// Font Output Helpers
// ============================================================================

/// Write a FontDescriptor PDF object.
pub fn writeFontDescriptor(
    allocator: std.mem.Allocator,
    w: *Writer,
    emb_font: *EmbeddedFont,
    descriptor_id: ObjectId,
    fontfile_id: ObjectId,
    is_cff: bool,
) !void {
    try w.beginObject(descriptor_id);
    var desc_dict = Dict.init(allocator);
    defer desc_dict.deinit();

    try desc_dict.put("Type", Value.name("FontDescriptor"));
    try desc_dict.put("FontName", Value.name(emb_font.name));
    try desc_dict.put("Flags", Value.int(@intCast(emb_font.flags.toInt())));
    try desc_dict.put("ItalicAngle", Value.int(emb_font.italic_angle));
    try desc_dict.put("Ascent", Value.int(emb_font.ascent));
    try desc_dict.put("Descent", Value.int(emb_font.descent));
    try desc_dict.put("CapHeight", Value.int(emb_font.cap_height));
    try desc_dict.put("StemV", Value.int(@intCast(emb_font.stem_v)));

    // CFF fonts use FontFile3, TrueType uses FontFile2
    if (is_cff) {
        try desc_dict.put("FontFile3", Value.ref(.{ .id = fontfile_id }));
    } else {
        try desc_dict.put("FontFile2", Value.ref(.{ .id = fontfile_id }));
    }

    var bbox_array = Array.init(allocator);
    defer bbox_array.deinit();
    for (emb_font.bbox) |val| {
        try bbox_array.append(Value.int(val));
    }
    try desc_dict.put("FontBBox", .{ .array_val = &bbox_array });

    try w.writeDict(desc_dict);
    try w.endObject();
}

/// Write a FontFile stream PDF object.
/// is_cid determines the CFF Subtype: true = CIDFontType0C, false = Type1C.
pub fn writeFontFileStream(
    allocator: std.mem.Allocator,
    w: *Writer,
    emb_font: *EmbeddedFont,
    fontfile_id: ObjectId,
    is_cff: bool,
    is_cid: bool,
) !void {
    try w.beginObject(fontfile_id);
    const font_data = emb_font.getFontData();
    var stream_dict = Dict.init(allocator);
    defer stream_dict.deinit();

    if (is_cff) {
        // CFF requires Subtype
        const subtype = if (is_cid) "CIDFontType0C" else "Type1C";
        try stream_dict.put("Subtype", Value.name(subtype));
    } else {
        try stream_dict.put("Length1", Value.int(@intCast(font_data.len)));
    }
    try w.writeStreamCompressed(&stream_dict, font_data);
    try w.endObject();
}

/// Write a ToUnicode CMap stream PDF object.
pub fn writeToUnicodeStream(
    allocator: std.mem.Allocator,
    w: *Writer,
    tounicode_id: ObjectId,
    tounicode_cmap: []const u8,
) !void {
    try w.beginObject(tounicode_id);
    var tounicode_dict = Dict.init(allocator);
    defer tounicode_dict.deinit();
    try w.writeStreamCompressed(&tounicode_dict, tounicode_cmap);
    try w.endObject();
}

/// Write CID font objects (Type0 + CIDFont + FontDescriptor + FontFile + ToUnicode).
pub fn writeCIDFont(
    allocator: std.mem.Allocator,
    w: *Writer,
    emb_font: *EmbeddedFont,
    base_id: ObjectId,
) !void {
    const type0_id = base_id;
    const cidfont_id = base_id + 1;
    const descriptor_id = base_id + 2;
    const fontfile_id = base_id + 3;
    const tounicode_id = base_id + 4;

    // Generate ToUnicode CMap for CID
    const tounicode_cmap = try emb_font.generateCIDToUnicodeCMap();
    defer allocator.free(tounicode_cmap);

    // Generate /W width array
    const w_array = try emb_font.generateWidthArray();
    defer allocator.free(w_array);

    const is_cff = emb_font.font.isCFF();

    // 1. Type0 (composite) font
    try w.beginObject(type0_id);
    {
        var font_dict = Dict.init(allocator);
        defer font_dict.deinit();
        try font_dict.put("Type", Value.name("Font"));
        try font_dict.put("Subtype", Value.name("Type0"));
        try font_dict.put("BaseFont", Value.name(emb_font.name));
        try font_dict.put("Encoding", Value.name("Identity-H"));
        try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

        // DescendantFonts array with single CIDFont reference
        var descendants = Array.init(allocator);
        defer descendants.deinit();
        try descendants.append(Value.ref(.{ .id = cidfont_id }));
        try font_dict.put("DescendantFonts", .{ .array_val = &descendants });

        try w.writeDict(font_dict);
    }
    try w.endObject();

    // 2. CIDFont (CIDFontType2 for TrueType, CIDFontType0 for CFF)
    try w.beginObject(cidfont_id);
    {
        var cid_dict = Dict.init(allocator);
        defer cid_dict.deinit();
        try cid_dict.put("Type", Value.name("Font"));
        if (is_cff) {
            try cid_dict.put("Subtype", Value.name("CIDFontType0"));
        } else {
            try cid_dict.put("Subtype", Value.name("CIDFontType2"));
        }
        try cid_dict.put("BaseFont", Value.name(emb_font.name));
        try cid_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
        try cid_dict.put("DW", Value.int(emb_font.getDefaultWidth()));

        // CIDSystemInfo dictionary
        var cidsysinfo = Dict.init(allocator);
        defer cidsysinfo.deinit();
        try cidsysinfo.put("Registry", Value.string("Adobe"));
        try cidsysinfo.put("Ordering", Value.string("Identity"));
        try cidsysinfo.put("Supplement", Value.int(0));
        try cid_dict.put("CIDSystemInfo", .{ .dict_val = &cidsysinfo });

        // /W array as raw literal (already formatted)
        try cid_dict.put("W", Value.literal(w_array));

        // CIDToGIDMap - Identity mapping (only for TrueType, not CFF)
        if (!is_cff) {
            try cid_dict.put("CIDToGIDMap", Value.name("Identity"));
        }

        try w.writeDict(cid_dict);
    }
    try w.endObject();

    // 3. FontDescriptor
    try writeFontDescriptor(allocator, w, emb_font, descriptor_id, fontfile_id, is_cff);

    // 4. FontFile stream (FontFile2 for TTF, FontFile3 for CFF)
    try writeFontFileStream(allocator, w, emb_font, fontfile_id, is_cff, true);

    // 5. ToUnicode CMap stream
    try writeToUnicodeStream(allocator, w, tounicode_id, tounicode_cmap);
}

/// Write WinAnsi font objects (Font + FontDescriptor + FontFile + ToUnicode).
pub fn writeWinAnsiFont(
    allocator: std.mem.Allocator,
    w: *Writer,
    emb_font: *EmbeddedFont,
    base_id: ObjectId,
) !void {
    const font_dict_id = base_id;
    const descriptor_id = base_id + 1;
    const fontfile_id = base_id + 2;
    const tounicode_id = base_id + 3;

    // Generate ToUnicode CMap
    const tounicode_cmap = try emb_font.generateToUnicodeCMap();
    defer allocator.free(tounicode_cmap);

    const is_cff = emb_font.font.isCFF();

    // 1. Font dictionary
    try w.beginObject(font_dict_id);
    {
        var font_dict = Dict.init(allocator);
        defer font_dict.deinit();
        try font_dict.put("Type", Value.name("Font"));
        try font_dict.put("Subtype", Value.name("TrueType"));
        try font_dict.put("BaseFont", Value.name(emb_font.name));
        try font_dict.put("FirstChar", Value.int(0));
        try font_dict.put("LastChar", Value.int(255));
        try font_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
        try font_dict.put("Encoding", Value.name("WinAnsiEncoding"));
        try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

        // Widths array
        var widths_array = Array.init(allocator);
        defer widths_array.deinit();
        for (emb_font.widths) |width| {
            try widths_array.append(Value.int(@intCast(width)));
        }
        try font_dict.put("Widths", .{ .array_val = &widths_array });

        try w.writeDict(font_dict);
    }
    try w.endObject();

    // 2. FontDescriptor
    try writeFontDescriptor(allocator, w, emb_font, descriptor_id, fontfile_id, is_cff);

    // 3. FontFile stream
    try writeFontFileStream(allocator, w, emb_font, fontfile_id, is_cff, false);

    // 4. ToUnicode CMap stream
    try writeToUnicodeStream(allocator, w, tounicode_id, tounicode_cmap);
}

/// Write shading dictionary for a gradient.
pub fn writeShadingDict(
    grad_def: anytype,
    page_height: f64,
    writer: anytype,
) !void {
    switch (grad_def) {
        .linear => |lg| {
            const pdf_y0 = page_height - lg.y0;
            const pdf_y1 = page_height - lg.y1;
            try writer.print("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{d:.2} {d:.2} {d:.2} {d:.2}] /Extend [{s} {s}] /Function ", .{
                lg.x0,
                pdf_y0,
                lg.x1,
                pdf_y1,
                if (lg.extend_before) "true" else "false",
                if (lg.extend_after) "true" else "false",
            });
            try gradient.writeFunctionDict(lg.stops, writer);
            try writer.writeAll(" >>");
        },
        .radial => |rg| {
            const pdf_y0 = page_height - rg.y0;
            const pdf_y1 = page_height - rg.y1;
            try writer.print("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}] /Extend [{s} {s}] /Function ", .{
                rg.x0,
                pdf_y0,
                rg.r0,
                rg.x1,
                pdf_y1,
                rg.r1,
                if (rg.extend_before) "true" else "false",
                if (rg.extend_after) "true" else "false",
            });
            try gradient.writeFunctionDict(rg.stops, writer);
            try writer.writeAll(" >>");
        },
    }
}
