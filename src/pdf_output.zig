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

/// Resource name for a 0-based index: prefix + (idx + 1), e.g. "Im1",
/// "GS12" - the names content streams reference ("/Im{d} Do", "/GS{d} gs",
/// "/E{d} Tf", "/Sh{d} sh", "/Sv{d} Do"). Generated, not tabled: the old
/// comptime tables (32 entries, 16 for shadings) gave every later resource
/// the same fallback name ("Im99"), breaking documents with >32 images.
pub fn resourceName(buf: *[24]u8, prefix: []const u8, idx: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, idx + 1 }) catch unreachable;
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
pub const DateTime = struct {
    /// Unsigned on purpose: Zig 0.17 formats a signed integer with a width
    /// ({d:0>4}) with a leading "+", which broke every PDF/XMP date.
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    /// Current UTC time. Read it ONCE per output: /Info and XMP must carry
    /// the same instant (PDF/A 6.7.3), and two readings can straddle a
    /// second boundary.
    pub fn now() DateTime {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return fromEpochSeconds(@intCast(ts.sec));
    }

    pub fn fromEpochSeconds(epoch_secs: u64) DateTime {
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

/// Format `dt` (UTC) as PDF date string: D:YYYYMMDDHHmmSSZ
/// Returns a slice into the provided buffer.
pub fn formatPdfDate(buf: *[24]u8, dt: DateTime) []const u8 {
    return std.fmt.bufPrint(buf, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    }) catch unreachable;
}

/// Format `dt` (UTC) as ISO 8601 date string: YYYY-MM-DDTHH:mm:ssZ
/// Required for XMP metadata in PDF/A documents.
/// Returns a slice into the provided buffer.
pub fn formatIsoDate(buf: *[21]u8, dt: DateTime) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    }) catch unreachable;
}

/// Converts a PDF date (ISO 32000 7.9.4: D:YYYYMMDDHHmmSSOHH'mm', every
/// field after the year optional, "D:" prefix optional) to the XMP form
/// (ISO 8601 as profiled by XMP: YYYY[-MM[-DD[Thh:mm[:ss][TZD]]]]) with
/// the same precision. Null if `pdf` is not a valid PDF date.
pub fn pdfDateToIso(buf: *[32]u8, pdf: []const u8) ?[]const u8 {
    var s = if (std.mem.startsWith(u8, pdf, "D:")) pdf[2..] else pdf;
    const year = takeDigits(&s, 4) orelse return null;
    // MM DD HH mm SS, each optional but only in order.
    const limits = [_][2]u8{ .{ 1, 12 }, .{ 1, 31 }, .{ 0, 23 }, .{ 0, 59 }, .{ 0, 59 } };
    var fields: [5]?u8 = @splat(null);
    for (&fields, limits) |*f, lim| {
        const v = takeDigits(&s, 2) orelse break;
        if (v < lim[0] or v > lim[1]) return null;
        f.* = @intCast(v);
    }

    // Time zone: Z, or +/- HH['mm['] ] (the trailing apostrophe is optional).
    var tz_buf: [6]u8 = undefined;
    var tz: []const u8 = "";
    if (s.len > 0) {
        const sign = s[0];
        if (sign != 'Z' and sign != '+' and sign != '-') return null;
        s = s[1..];
        if (sign == 'Z') {
            tz = "Z";
            // Some writers emit "Z00'00'": accept a zero offset after Z.
            if (s.len > 0 and !std.mem.eql(u8, s, "00'00'") and !std.mem.eql(u8, s, "00'00")) return null;
            s = "";
        } else {
            const tzh = takeDigits(&s, 2) orelse return null;
            if (tzh > 23) return null;
            var tzm: u32 = 0;
            if (s.len > 0 and s[0] == '\'') s = s[1..];
            if (s.len > 0) {
                tzm = takeDigits(&s, 2) orelse return null;
                if (tzm > 59) return null;
                if (s.len > 0 and s[0] == '\'') s = s[1..];
            }
            if (s.len != 0) return null;
            tz = std.fmt.bufPrint(&tz_buf, "{c}{d:0>2}:{d:0>2}", .{ sign, tzh, tzm }) catch unreachable;
        }
    }

    var w: std.Io.Writer = .fixed(buf);
    w.print("{d:0>4}", .{year}) catch unreachable;
    if (fields[0]) |mo| w.print("-{d:0>2}", .{mo}) catch unreachable;
    if (fields[1]) |d| w.print("-{d:0>2}", .{d}) catch unreachable;
    // XMP times need hours and minutes; a PDF hour alone means minute 0.
    if (fields[2]) |h| {
        w.print("T{d:0>2}:{d:0>2}", .{ h, fields[3] orelse 0 }) catch unreachable;
        if (fields[4]) |sec| w.print(":{d:0>2}", .{sec}) catch unreachable;
        w.writeAll(tz) catch unreachable;
    }
    return w.buffered();
}

/// Parses exactly `n` ASCII digits from the front of `s`, advancing it.
fn takeDigits(s: *[]const u8, n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s.*[0..n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    s.* = s.*[n..];
    return v;
}

/// The creation and modification dates of one output, for /Info (PDF
/// format) and XMP (ISO 8601), all from a single clock reading. Explicit
/// metadata dates are used verbatim in /Info and converted for XMP, so
/// the two always describe the same instants (PDF/A 6.7.3).
pub const OutputDates = struct {
    creation_pdf: []const u8,
    mod_pdf: []const u8,
    /// Null when an explicit date is not a valid PDF date (PDF/A output
    /// then fails with error.InvalidDate).
    create_iso: ?[]const u8,
    modify_iso: ?[]const u8,

    pub const Buffers = struct {
        now_pdf: [24]u8 = undefined,
        create_iso: [32]u8 = undefined,
        modify_iso: [32]u8 = undefined,
    };

    pub fn resolve(bufs: *Buffers, now: DateTime, creation_date: ?[]const u8, mod_date: ?[]const u8) OutputDates {
        const creation = creation_date orelse formatPdfDate(&bufs.now_pdf, now);
        const modified = mod_date orelse creation; // same as creation if not set
        const create_iso = pdfDateToIso(&bufs.create_iso, creation);
        const modify_iso = if (mod_date == null) create_iso else pdfDateToIso(&bufs.modify_iso, modified);
        return .{ .creation_pdf = creation, .mod_pdf = modified, .create_iso = create_iso, .modify_iso = modify_iso };
    }
};

/// File identifiers of one output, all drawn from the document's RNG (the
/// injected Document.rng, else the system CSPRNG): the trailer /ID and the
/// XMP DocumentID/InstanceID. Never derived from the clock, so concurrent
/// outputs cannot collide and a seeded RNG gives reproducible bytes.
pub const FileIds = struct {
    /// Trailer /ID: 16 random bytes as 32 hex digits.
    trailer_hex: [32]u8,
    /// XMP xmpMM:DocumentID / InstanceID: RFC 4122 version-4 UUIDs
    /// (pdfa.zig adds the "uuid:" prefix).
    document_uuid: [36]u8,
    instance_uuid: [36]u8,

    pub fn generate(random: std.Random) FileIds {
        var trailer: [16]u8 = undefined;
        random.bytes(&trailer);
        return .{
            .trailer_hex = std.fmt.bytesToHex(trailer, .lower),
            .document_uuid = uuidV4(random),
            .instance_uuid = uuidV4(random),
        };
    }
};

fn uuidV4(random: std.Random) [36]u8 {
    var b: [16]u8 = undefined;
    random.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
    const hex = std.fmt.bytesToHex(b, .lower);
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return out;
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

test "PDF and XMP dates have exact formats (no sign, nothing truncated)" {
    // Zig 0.17 prints "+2026" for a signed year with a width ({d:0>4});
    // with a hard-coded slice length that dropped the trailing "Z" too,
    // and veraPDF rejected every PDF/A file (XMP dates not dates).
    const now = DateTime.now();
    var pdf_buf: [24]u8 = undefined;
    const pdf = formatPdfDate(&pdf_buf, now);
    try std.testing.expectEqual(@as(usize, 17), pdf.len); // D:YYYYMMDDHHmmSSZ
    try std.testing.expectEqualStrings("D:", pdf[0..2]);
    for (pdf[2..16]) |c| try std.testing.expect(std.ascii.isDigit(c));
    try std.testing.expectEqual(@as(u8, 'Z'), pdf[16]);

    var iso_buf: [21]u8 = undefined;
    const iso = formatIsoDate(&iso_buf, now);
    try std.testing.expectEqual(@as(usize, 20), iso.len); // YYYY-MM-DDTHH:mm:ssZ
    for (iso, "dddd-dd-ddTdd:dd:ddZ") |c, pattern| {
        if (pattern == 'd') try std.testing.expect(std.ascii.isDigit(c)) else try std.testing.expectEqual(pattern, c);
    }
}

test "PDF and ISO dates of one instant agree" {
    const dt = DateTime.fromEpochSeconds(1_791_892_799); // 2026-10-13T11:59:59Z
    var pdf_buf: [24]u8 = undefined;
    var iso_buf: [21]u8 = undefined;
    var conv_buf: [32]u8 = undefined;
    const pdf = formatPdfDate(&pdf_buf, dt);
    try std.testing.expectEqualStrings("D:20261013115959Z", pdf);
    try std.testing.expectEqualStrings(formatIsoDate(&iso_buf, dt), pdfDateToIso(&conv_buf, pdf).?);
}

test "pdfDateToIso keeps precision and time zone" {
    const cases = [_][2][]const u8{
        .{ "D:2026", "2026" },
        .{ "D:202603", "2026-03" },
        .{ "D:20260315", "2026-03-15" },
        .{ "D:2026031508", "2026-03-15T08:00" },
        .{ "D:202603150830", "2026-03-15T08:30" },
        .{ "D:20260315083005", "2026-03-15T08:30:05" },
        .{ "D:20260315083005Z", "2026-03-15T08:30:05Z" },
        .{ "D:20260315083005Z00'00'", "2026-03-15T08:30:05Z" },
        .{ "D:20260315083005+02'00'", "2026-03-15T08:30:05+02:00" },
        .{ "D:20260315083005-05'30", "2026-03-15T08:30:05-05:30" },
        .{ "D:20260315083005+01", "2026-03-15T08:30:05+01:00" },
        .{ "20260315083005Z", "2026-03-15T08:30:05Z" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(c[1], pdfDateToIso(&buf, c[0]) orelse return error.TestUnexpectedResult);
    }
    for ([_][]const u8{ "", "D:", "D:26", "D:20261", "D:20261315", "D:20260332", "D:2026031524", "D:20260315083060", "D:20260315083005X", "D:20260315083005+2", "D:20260315083005+02'00'x", "D:20260315083005Z01'00'", "2026-03-15" }) |bad| {
        var buf: [32]u8 = undefined;
        try std.testing.expect(pdfDateToIso(&buf, bad) == null);
    }
}

test "OutputDates: one instant, explicit dates mirrored into XMP" {
    const now = DateTime.fromEpochSeconds(1_791_892_799);
    var bufs: OutputDates.Buffers = .{};
    const auto = OutputDates.resolve(&bufs, now, null, null);
    try std.testing.expectEqualStrings("D:20261013115959Z", auto.creation_pdf);
    try std.testing.expectEqualStrings("D:20261013115959Z", auto.mod_pdf);
    try std.testing.expectEqualStrings("2026-10-13T11:59:59Z", auto.create_iso.?);
    try std.testing.expectEqualStrings("2026-10-13T11:59:59Z", auto.modify_iso.?);

    var bufs2: OutputDates.Buffers = .{};
    const explicit = OutputDates.resolve(&bufs2, now, "D:20260101120000+02'00'", "D:20260315083005Z");
    try std.testing.expectEqualStrings("D:20260101120000+02'00'", explicit.creation_pdf);
    try std.testing.expectEqualStrings("2026-01-01T12:00:00+02:00", explicit.create_iso.?);
    try std.testing.expectEqualStrings("D:20260315083005Z", explicit.mod_pdf);
    try std.testing.expectEqualStrings("2026-03-15T08:30:05Z", explicit.modify_iso.?);

    var bufs3: OutputDates.Buffers = .{};
    const bad = OutputDates.resolve(&bufs3, now, "yesterday", null);
    try std.testing.expect(bad.create_iso == null and bad.modify_iso == null);
}
