//! Embedded Font Support
//!
//! Handles TrueType font embedding in PDF documents.
//! Uses WinAnsiEncoding (Windows-1252) for simple single-byte text.

const std = @import("std");
const ttf = @import("ttf.zig");

/// WinAnsiEncoding (Windows-1252) to Unicode mapping.
/// Maps byte values 0-255 to Unicode codepoints.
/// Values 0x00-0x7F are identical to ASCII.
/// Values 0x80-0x9F contain special characters (not defined in Latin-1).
/// Values 0xA0-0xFF are Latin-1 Supplement.
pub const win_ansi_to_unicode: [256]u21 = blk: {
    var map: [256]u21 = undefined;

    // 0x00-0x7F: ASCII (identical)
    for (0..128) |i| {
        map[i] = @intCast(i);
    }

    // 0x80-0x9F: Windows-1252 specific characters
    map[0x80] = 0x20AC; // Euro sign
    map[0x81] = 0xFFFD; // Undefined (use replacement char)
    map[0x82] = 0x201A; // Single low-9 quotation mark
    map[0x83] = 0x0192; // Latin small letter f with hook
    map[0x84] = 0x201E; // Double low-9 quotation mark
    map[0x85] = 0x2026; // Horizontal ellipsis
    map[0x86] = 0x2020; // Dagger
    map[0x87] = 0x2021; // Double dagger
    map[0x88] = 0x02C6; // Modifier letter circumflex accent
    map[0x89] = 0x2030; // Per mille sign
    map[0x8A] = 0x0160; // Latin capital letter S with caron
    map[0x8B] = 0x2039; // Single left-pointing angle quotation mark
    map[0x8C] = 0x0152; // Latin capital ligature OE
    map[0x8D] = 0xFFFD; // Undefined
    map[0x8E] = 0x017D; // Latin capital letter Z with caron
    map[0x8F] = 0xFFFD; // Undefined
    map[0x90] = 0xFFFD; // Undefined
    map[0x91] = 0x2018; // Left single quotation mark
    map[0x92] = 0x2019; // Right single quotation mark
    map[0x93] = 0x201C; // Left double quotation mark
    map[0x94] = 0x201D; // Right double quotation mark
    map[0x95] = 0x2022; // Bullet
    map[0x96] = 0x2013; // En dash
    map[0x97] = 0x2014; // Em dash
    map[0x98] = 0x02DC; // Small tilde
    map[0x99] = 0x2122; // Trade mark sign
    map[0x9A] = 0x0161; // Latin small letter s with caron
    map[0x9B] = 0x203A; // Single right-pointing angle quotation mark
    map[0x9C] = 0x0153; // Latin small ligature oe
    map[0x9D] = 0xFFFD; // Undefined
    map[0x9E] = 0x017E; // Latin small letter z with caron
    map[0x9F] = 0x0178; // Latin capital letter Y with diaeresis

    // 0xA0-0xFF: Latin-1 Supplement (identical to Unicode)
    for (0xA0..256) |i| {
        map[i] = @intCast(i);
    }

    break :blk map;
};

/// Font flags for FontDescriptor
pub const FontFlags = packed struct(u32) {
    fixed_pitch: bool = false, // Bit 0: All glyphs have same width
    serif: bool = false, // Bit 1: Serifs present
    symbolic: bool = false, // Bit 2: Non-standard character set
    script: bool = false, // Bit 3: Script/cursive font
    _reserved4: bool = false,
    nonsymbolic: bool = true, // Bit 5: Uses standard Latin encoding
    italic: bool = false, // Bit 6: Italic or oblique
    _reserved7_15: u9 = 0,
    all_cap: bool = false, // Bit 16: No lowercase
    small_cap: bool = false, // Bit 17: Lowercase are small caps
    _reserved18_31: u14 = 0,

    pub fn toInt(self: FontFlags) u32 {
        return @bitCast(self);
    }
};

/// Embedded TrueType font for PDF
pub const EmbeddedFont = struct {
    name: []const u8, // PostScript name for PDF
    data: []const u8, // Raw TTF data (for FontFile2)
    font: ttf.Font, // Parsed font
    widths: [256]u16, // Widths in 1/1000 em for WinAnsi chars
    allocator: std.mem.Allocator,
    owns_data: bool, // Whether we own the TTF data

    // Metrics scaled to 1000 units (PDF standard)
    ascent: i16,
    descent: i16,
    cap_height: i16,
    bbox: [4]i16, // [x_min, y_min, x_max, y_max]
    italic_angle: i16,
    stem_v: u16,
    flags: FontFlags,

    /// Load and parse a TTF font from file
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !*EmbeddedFont {
        const result = try ttf.Font.fromFile(allocator, path);
        return try fromParsed(allocator, result.font, result.data, true);
    }

    /// Create from already-parsed font
    pub fn fromParsed(
        allocator: std.mem.Allocator,
        font: ttf.Font,
        data: []const u8,
        owns_data: bool,
    ) !*EmbeddedFont {
        const head = font.head orelse return error.MissingTable;
        const hhea = font.hhea orelse return error.MissingTable;

        const units_per_em = head.units_per_em;
        if (units_per_em == 0) return error.InvalidFont;

        // Scale factor: convert from font units to 1000 units
        const scale = @as(f64, 1000.0) / @as(f64, @floatFromInt(units_per_em));

        // Build widths array for WinAnsiEncoding
        var widths: [256]u16 = undefined;
        for (0..256) |i| {
            const unicode = win_ansi_to_unicode[i];
            if (font.getCharWidth(unicode)) |w| {
                widths[i] = @intFromFloat(@as(f64, @floatFromInt(w)) * scale);
            } else {
                // Use zero width for missing glyphs
                widths[i] = 0;
            }
        }

        // Scale metrics
        const ascent: i16 = @intFromFloat(@as(f64, @floatFromInt(hhea.ascent)) * scale);
        const descent: i16 = @intFromFloat(@as(f64, @floatFromInt(hhea.descent)) * scale);

        // Estimate CapHeight as 70% of ascent if not available
        // (Would need OS/2 table for accurate value)
        const cap_height: i16 = @intFromFloat(@as(f64, @floatFromInt(ascent)) * 0.7);

        // Scale bounding box
        const bbox: [4]i16 = .{
            @intFromFloat(@as(f64, @floatFromInt(head.x_min)) * scale),
            @intFromFloat(@as(f64, @floatFromInt(head.y_min)) * scale),
            @intFromFloat(@as(f64, @floatFromInt(head.x_max)) * scale),
            @intFromFloat(@as(f64, @floatFromInt(head.y_max)) * scale),
        };

        // Estimate StemV (vertical stem width) - typically 80 for normal, higher for bold
        // Would need proper stem detection for accuracy
        const stem_v: u16 = 80;

        // Determine flags from font properties
        var flags = FontFlags{};

        // Check if monospace (compare widths of 'i' and 'm')
        const width_i = font.getCharWidth('i');
        const width_m = font.getCharWidth('m');
        if (width_i != null and width_m != null and width_i.? == width_m.?) {
            flags.fixed_pitch = true;
        }

        // Get PostScript name for PDF BaseFont (preferred)
        // Fall back to family name + style if PostScript name not available
        const ps_name = font.getPostScriptName() orelse font.getFamilyName() orelse "Unknown";

        // Allocate and copy name (may be UTF-16, need to decode)
        const name = try allocator.dupe(u8, decodeFontName(ps_name));

        const embedded = try allocator.create(EmbeddedFont);
        embedded.* = .{
            .name = name,
            .data = data,
            .font = font,
            .widths = widths,
            .allocator = allocator,
            .owns_data = owns_data,
            .ascent = ascent,
            .descent = descent,
            .cap_height = cap_height,
            .bbox = bbox,
            .italic_angle = 0,
            .stem_v = stem_v,
            .flags = flags,
        };

        return embedded;
    }

    pub fn deinit(self: *EmbeddedFont) void {
        self.allocator.free(self.name);
        if (self.owns_data) {
            self.allocator.free(self.data);
        }
        self.allocator.destroy(self);
    }

    /// Get character width for a byte value (WinAnsi encoded)
    pub fn getCharWidth(self: *const EmbeddedFont, char: u8) u16 {
        return self.widths[char];
    }

    /// Get text width in points
    pub fn measureTextWidth(self: *const EmbeddedFont, text: []const u8, size: f64) f64 {
        var total: u32 = 0;
        for (text) |c| {
            total += self.widths[c];
        }
        return @as(f64, @floatFromInt(total)) * size / 1000.0;
    }
};

/// Decode font name (handles UTF-16BE from Windows platform)
fn decodeFontName(raw: []const u8) []const u8 {
    // Simple heuristic: if it looks like UTF-16BE (null bytes), decode it
    if (raw.len >= 2 and raw.len % 2 == 0) {
        var has_nulls = false;
        for (raw, 0..) |b, i| {
            if (b == 0 and i % 2 == 0) {
                has_nulls = true;
                break;
            }
        }
        if (has_nulls) {
            // This is likely UTF-16BE, extract ASCII portion
            // For now, just skip null bytes (works for ASCII names)
            var result: [256]u8 = undefined;
            var len: usize = 0;
            var i: usize = 0;
            while (i + 1 < raw.len and len < 255) : (i += 2) {
                if (raw[i] == 0 and raw[i + 1] >= 0x20 and raw[i + 1] < 0x7F) {
                    result[len] = raw[i + 1];
                    len += 1;
                }
            }
            if (len > 0) {
                return result[0..len];
            }
        }
    }
    return raw;
}

test "win ansi encoding" {
    // ASCII range
    try std.testing.expectEqual(@as(u21, 'A'), win_ansi_to_unicode['A']);
    try std.testing.expectEqual(@as(u21, ' '), win_ansi_to_unicode[' ']);

    // Special characters
    try std.testing.expectEqual(@as(u21, 0x20AC), win_ansi_to_unicode[0x80]); // Euro
    try std.testing.expectEqual(@as(u21, 0x2014), win_ansi_to_unicode[0x97]); // Em dash

    // Latin-1 supplement
    try std.testing.expectEqual(@as(u21, 0xA0), win_ansi_to_unicode[0xA0]); // NBSP
    try std.testing.expectEqual(@as(u21, 0xFF), win_ansi_to_unicode[0xFF]); // ÿ
}

test "font flags" {
    var flags = FontFlags{};
    try std.testing.expectEqual(@as(u32, 32), flags.toInt()); // Bit 5 (nonsymbolic) set

    flags.fixed_pitch = true;
    try std.testing.expectEqual(@as(u32, 33), flags.toInt()); // Bits 0 and 5

    flags.italic = true;
    try std.testing.expectEqual(@as(u32, 97), flags.toInt()); // Bits 0, 5, 6
}
