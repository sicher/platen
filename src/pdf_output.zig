//! PDF output generation for platen.
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
// Time
// ============================================================================

/// Current time in milliseconds since the Unix epoch (libc REALTIME clock).
/// Replacement for the Zig 0.15 `std.time.milliTimestamp()`.
pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

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

// ============================================================================
// Helper Functions
// ============================================================================

/// Date/time components for formatting.
const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    fn now() DateTime {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const epoch_secs: u64 = @intCast(ts.sec);
        const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();
        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = day_secs.getHoursIntoDay(),
            .minute = day_secs.getMinutesIntoHour(),
            .second = day_secs.getSecondsIntoMinute(),
        };
    }
};

/// Format current UTC time as PDF date string: D:YYYYMMDDHHmmSSZ
/// Returns a slice into the provided buffer.
pub fn formatPdfDate(buf: *[24]u8) []const u8 {
    const dt = DateTime.now();
    _ = std.fmt.bufPrint(buf, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    }) catch unreachable;
    return buf[0..17];
}

/// Format current UTC time as ISO 8601 date string: YYYY-MM-DDTHH:mm:ssZ
/// Required for XMP metadata in PDF/A documents.
/// Returns a slice into the provided buffer.
pub fn formatIsoDate(buf: *[21]u8) []const u8 {
    const dt = DateTime.now();
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    }) catch unreachable;
    return buf[0..20];
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
