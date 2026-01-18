//! zpdf - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = "0.1.0";

// Modules
pub const objects = @import("objects.zig");
pub const fonts = @import("fonts.zig");
pub const metrics = @import("metrics.zig");
pub const ttf = @import("ttf.zig");
pub const embedded = @import("embedded.zig");
pub const Writer = @import("writer.zig").Writer;
pub const zlib = @import("zlib.zig");
pub const testing = @import("testing.zig");
pub const integration_tests = @import("integration_tests.zig");

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

pub const StandardFont = fonts.StandardFont;
pub const Font = fonts.Font;
pub const TextMetrics = metrics.TextMetrics;
pub const TextStyle = metrics.TextStyle;
pub const EmbeddedFont = embedded.EmbeddedFont;
pub const opentype = embedded.opentype;

/// Handle to a loaded font (either standard or embedded)
pub const FontHandle = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,

    pub fn name(self: FontHandle) []const u8 {
        return switch (self) {
            .standard => |f| f.pdfName(),
            .embedded => |e| e.name,
        };
    }
};

// ============================================================================
// Units - all measurements in PDF are in points (1pt = 1/72 inch)
// ============================================================================

/// Points per inch.
pub const pt_per_inch = 72.0;

/// Points per millimeter.
pub const pt_per_mm = 72.0 / 25.4;

/// Points per centimeter.
pub const pt_per_cm = 72.0 / 2.54;

/// Converts inches to points.
pub fn inches(n: f64) f64 {
    return n * pt_per_inch;
}

/// Converts millimeters to points.
pub fn mm(n: f64) f64 {
    return n * pt_per_mm;
}

/// Converts centimeters to points.
pub fn cm(n: f64) f64 {
    return n * pt_per_cm;
}

// ============================================================================
// Text Flow API Types
// ============================================================================

/// RGB color. Values are 0.0 to 1.0.
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };
    // TODO: CMYK, grayscale, spot colors
};

/// Border specification for regions.
pub const Border = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub const none = Border{};
    pub const all = Border{ .top = true, .bottom = true, .left = true, .right = true };
};

/// Text alignment.
/// Horizontal text alignment.
pub const Align = enum {
    left,
    center,
    right,
    justify,
};

/// Vertical text alignment within line height.
pub const VAlign = enum {
    /// Baseline at content_y + font_size (simple, no leading adjustment).
    top,
    /// Baseline centered: content_y + font_size - leading/2 (fpdf2 compatible).
    middle,
    /// Baseline at content_y + line_height (text sits on bottom edge).
    bottom,
};

/// Document margins in points.
pub const Margins = struct {
    left: f64 = 72,
    right: f64 = 72,
    top: f64 = 72,
    bottom: f64 = 72,
};

/// Region padding in points (defaults to zero).
pub const Padding = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,
};

/// Rectangular area for content placement with cursor tracking.
pub const Region = struct {
    /// Left edge x coordinate.
    x: f64,
    /// Top edge y coordinate (from page top).
    y: f64,
    /// Region width.
    width: f64,
    /// Region height.
    height: f64,
    /// Current cursor y position within content area (relative to top padding).
    cursor_y: f64 = 0,
    /// Inner padding (content inset from region edges).
    padding: Padding = .{},
    /// Border styling.
    border: Border = .{},
    /// Background fill color.
    fill: ?Color = null,

    /// Returns remaining height in content area.
    pub fn remainingHeight(self: Region) f64 {
        return self.height - self.padding.top - self.padding.bottom - self.cursor_y;
    }

    /// Returns usable width inside padding.
    pub fn contentWidth(self: Region) f64 {
        return self.width - self.padding.left - self.padding.right;
    }

    /// Returns true if the given metrics fit in remaining space.
    pub fn fits(self: Region, m: TextMetrics) bool {
        return m.height <= self.remainingHeight();
    }
};

/// Result of writeLine or writeParagraph.
pub const WriteResult = struct {
    /// Number of lines rendered.
    lines_written: usize,
    /// Text that didn't fit, or null if all text was written.
    overflow: ?[]const u8,
};

/// Options for writeLine (single line, no wrap).
pub const LineOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
};

/// Options for writeParagraph (wrapped text).
pub const ParagraphOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// First line indent in points.
    first_indent: f64 = 0,
    /// Allow breaking after regular hyphens in compound words (e.g., "state-of-the-art").
    /// Default true. Set false for fpdf2 compatibility (only soft-hyphens break).
    break_on_hyphens: bool = true,
};

/// Options for writeFlow (auto-pagination).
pub const FlowOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// First line indent in points.
    first_indent: f64 = 0,
};

/// Page size in points (1 point = 1/72 inch)
pub const PageSize = struct {
    width: f64,
    height: f64,

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
};

/// Font reference for deferred text commands
const FontRef = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,
};

/// Text command parameters for deferred rendering
const TextCommand = struct {
    x: f64,
    y: f64,
    font_size: f64,
    char_spacing: f64,
    text_data: []const u8, // Owned copy of text
    font: FontRef,
};

/// Content command for deferred rendering (enables glyph ID remapping)
const ContentCommand = union(enum) {
    /// Text command with all rendering parameters
    text: TextCommand,
    /// Raw content (for non-text operations that don't need deferred processing)
    raw: []const u8, // Owned copy
};

/// Internal page representation
const Page = struct {
    content: std.ArrayListUnmanaged(u8), // Legacy: direct content bytes
    commands: std.ArrayListUnmanaged(ContentCommand), // Deferred commands
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void),
    used_embedded: std.ArrayListUnmanaged(*EmbeddedFont),

    fn init() Page {
        return .{
            .content = .{},
            .commands = .{},
            .used_fonts = .{},
            .used_embedded = .{},
        };
    }

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        // Free owned text data in commands
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| allocator.free(t.text_data),
                .raw => |r| allocator.free(r),
            }
        }
        self.commands.deinit(allocator);
        self.content.deinit(allocator);
        self.used_fonts.deinit(allocator);
        self.used_embedded.deinit(allocator);
    }

    fn markFontUsed(self: *Page, allocator: std.mem.Allocator, font: StandardFont) !void {
        try self.used_fonts.put(allocator, font, {});
    }

    fn markEmbeddedUsed(self: *Page, allocator: std.mem.Allocator, font: *EmbeddedFont) !void {
        // Check if already in list
        for (self.used_embedded.items) |f| {
            if (f == font) return;
        }
        try self.used_embedded.append(allocator, font);
    }

    fn writer(self: *Page, allocator: std.mem.Allocator) ContentWriter {
        return ContentWriter{ .page = self, .allocator = allocator };
    }
};

/// Writer for page content stream
const ContentWriter = struct {
    page: *Page,
    allocator: std.mem.Allocator,

    fn append(self: *ContentWriter, data: []const u8) !void {
        try self.page.content.appendSlice(self.allocator, data);
    }

    fn print(self: *ContentWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
            // Buffer too small, allocate
            const str = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(str);
            try self.append(str);
            return;
        };
        try self.append(slice);
    }

    /// Append a string with PDF string escaping (for literal strings)
    /// Escapes (, ), and \ characters
    fn appendEscaped(self: *ContentWriter, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '\\' => try self.page.content.appendSlice(self.allocator, "\\\\"),
                '(' => try self.page.content.appendSlice(self.allocator, "\\("),
                ')' => try self.page.content.appendSlice(self.allocator, "\\)"),
                else => try self.page.content.append(self.allocator, c),
            }
        }
    }
};

/// Get a short resource name for a font (F1, F2, etc.)
fn fontResourceName(font: StandardFont) []const u8 {
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

/// Static resource names for embedded fonts (E1, E2, etc.)
const embedded_font_names = [_][]const u8{
    "E1",  "E2",  "E3",  "E4",  "E5",  "E6",  "E7",  "E8",
    "E9",  "E10", "E11", "E12", "E13", "E14", "E15", "E16",
    "E17", "E18", "E19", "E20", "E21", "E22", "E23", "E24",
    "E25", "E26", "E27", "E28", "E29", "E30", "E31", "E32",
};

/// Get a short resource name for an embedded font by index
fn embeddedFontResourceName(idx: usize) []const u8 {
    if (idx < embedded_font_names.len) {
        return embedded_font_names[idx];
    }
    // Fallback - this shouldn't happen with reasonable font counts
    return "E99";
}

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,
    /// Document margins.
    margins: Margins = .{},
    // Text state
    current_font: ?StandardFont = null,
    current_embedded: ?*EmbeddedFont = null,
    font_size: f64 = 12,
    x: f64 = 0,
    y: f64 = 0,
    /// Extra space between characters (in points). Can be negative.
    char_spacing: f64 = 0,
    /// Line height as multiple of font size. Default 1.2 (20% leading).
    line_height: f64 = 1.2,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .{},
    // Track all embedded fonts
    embedded_fonts: std.ArrayListUnmanaged(*EmbeddedFont) = .{},

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .pages = .{},
            .page_size = PageSize.A4,
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
        self.used_fonts.deinit(self.allocator);
        // Clean up embedded fonts
        for (self.embedded_fonts.items) |font| {
            font.deinit();
        }
        self.embedded_fonts.deinit(self.allocator);
    }

    /// Add a new page
    pub fn addPage(self: *Document) !void {
        try self.pages.append(self.allocator, Page.init());
        // Reset position to top-left (PDF coordinates: origin at bottom-left)
        self.x = 0;
        self.y = self.page_size.height;
    }

    /// Set the current font and size (standard font)
    pub fn setFont(self: *Document, font: StandardFont, size: f64) !void {
        self.current_font = font;
        self.current_embedded = null; // Clear embedded font
        self.font_size = size;
        try self.used_fonts.put(self.allocator, font, {});
    }

    /// Load a TrueType font from file
    pub fn loadFont(self: *Document, path: []const u8) !*EmbeddedFont {
        const font = try EmbeddedFont.fromFile(self.allocator, path);
        try self.embedded_fonts.append(self.allocator, font);
        return font;
    }

    /// Set an embedded font as current
    pub fn setEmbeddedFont(self: *Document, font: *EmbeddedFont, size: f64) !void {
        self.current_embedded = font;
        self.current_font = null; // Clear standard font
        self.font_size = size;
        // Ensure font is in our list
        for (self.embedded_fonts.items) |f| {
            if (f == font) return;
        }
        try self.embedded_fonts.append(self.allocator, font);
    }

    /// Get index of embedded font (for resource naming)
    fn getEmbeddedFontIndex(self: *Document, font: *EmbeddedFont) ?usize {
        for (self.embedded_fonts.items, 0..) |f, i| {
            if (f == font) return i;
        }
        return null;
    }

    /// Set character spacing (extra space between characters, in points)
    pub fn setCharSpacing(self: *Document, spacing: f64) void {
        self.char_spacing = spacing;
    }

    /// Set line height (as multiple of font size, e.g. 1.2 = 120%)
    pub fn setLineHeight(self: *Document, height: f64) void {
        self.line_height = height;
    }

    /// Set document margins.
    pub fn setMargins(self: *Document, m: Margins) void {
        self.margins = m;
    }

    /// Returns a region for the current page respecting document margins.
    pub fn getPageRegion(self: *Document) Region {
        return .{
            .x = self.margins.left,
            .y = self.margins.top,
            .width = self.page_size.width - self.margins.left - self.margins.right,
            .height = self.page_size.height - self.margins.top - self.margins.bottom,
        };
    }

    /// Set OpenType feature for all embedded fonts
    /// Example: doc.setFeature(.liga, false) to disable ligatures
    pub fn setFeature(self: *Document, feature: opentype.Feature, enabled: bool) void {
        for (self.embedded_fonts.items) |font| {
            font.setFeature(feature, enabled);
        }
    }

    /// Set OpenType feature for a specific embedded font
    pub fn setFontFeature(self: *Document, font: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void {
        _ = self;
        font.setFeature(feature, enabled);
    }

    /// Get current line height in points
    pub fn getLineHeightPts(self: *Document) f64 {
        return self.font_size * self.line_height;
    }

    /// Get current text style for measurement
    pub fn getTextStyle(self: *Document) TextStyle {
        return .{
            .font = self.current_font orelse .helvetica,
            .size = self.font_size,
            .char_spacing = self.char_spacing,
            .line_height = self.line_height,
        };
    }

    /// Measure text dimensions without rendering
    pub fn measureText(self: *Document, text_str: []const u8) TextMetrics {
        return metrics.measureText(text_str, self.getTextStyle());
    }

    /// Measure text width in points
    pub fn measureTextWidth(self: *Document, text_str: []const u8) f64 {
        return metrics.measureTextWidth(text_str, self.getTextStyle());
    }

    /// Set current position (in points from top-left)
    pub fn setXY(self: *Document, x: f64, y: f64) void {
        self.x = x;
        // Convert from top-left to PDF coordinates (bottom-left origin)
        self.y = self.page_size.height - y;
    }

    /// Set X position
    pub fn setX(self: *Document, x: f64) void {
        self.x = x;
    }

    /// Set Y position (from top)
    pub fn setY(self: *Document, y: f64) void {
        self.y = self.page_size.height - y;
    }

    /// Get current X position
    pub fn getX(self: *Document) f64 {
        return self.x;
    }

    /// Get current Y position (from top)
    pub fn getY(self: *Document) f64 {
        return self.page_size.height - self.y;
    }

    /// Writes text at the current cursor position.
    pub fn write(self: *Document, str: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];

        // Determine font reference and mark as used
        const font_ref: FontRef = if (self.current_embedded) |emb| blk: {
            try page.markEmbeddedUsed(self.allocator, emb);
            // Mark chars/glyphs as used for subsetting
            if (emb.encoding == .identity) {
                try emb.markUnicodeCharsUsed(str);
            } else {
                emb.markCharsUsed(str);
            }
            break :blk .{ .embedded = emb };
        } else if (self.current_font) |font| blk: {
            try page.markFontUsed(self.allocator, font);
            break :blk .{ .standard = font };
        } else {
            return error.NoFont;
        };

        // Create owned copy of text, stripping soft-hyphens (U+00AD)
        // Soft-hyphens are invisible unless used as break points
        const text_copy = try stripSoftHyphens(self.allocator, str);
        errdefer self.allocator.free(text_copy);

        // Store deferred command
        try page.commands.append(self.allocator, .{
            .text = .{
                .x = self.x,
                .y = self.y,
                .font_size = self.font_size,
                .char_spacing = self.char_spacing,
                .text_data = text_copy,
                .font = font_ref,
            },
        });
    }

    /// Render CID text with ligatures and kerning using TJ operator
    /// Returns true if kerning was applied (used TJ), false if simple Tj was used
    fn renderCIDTextWithKerning(self: *Document, cw: *ContentWriter, emb: *EmbeddedFont, str: []const u8) !bool {
        _ = self;
        // Get glyph sequence with ligatures applied
        const glyphs = try emb.getGlyphsForText(str);
        defer emb.allocator.free(glyphs);

        if (glyphs.len == 0) return false;

        const has_remap = emb.gid_remap.count() > 0;
        const units_per_em = emb.font.head.?.units_per_em;

        // Check if we have any kerning
        var has_kerning = false;
        if (emb.feature_flags.kern and emb.ot_features != null) {
            for (0..glyphs.len - 1) |i| {
                if (emb.getKerning(glyphs[i], glyphs[i + 1]) != 0) {
                    has_kerning = true;
                    break;
                }
            }
        }

        if (!has_kerning) {
            // No kerning - use simple hex string
            try cw.append("<");
            for (glyphs) |gid| {
                const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
                var hex_buf: [4]u8 = undefined;
                _ = std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{final_gid}) catch unreachable;
                try cw.append(&hex_buf);
            }
            try cw.append("> Tj\n");
            return false;
        }

        // Use TJ operator with kerning adjustments
        // Format: [<HexGlyphs> kern <HexGlyphs> kern ...] TJ
        try cw.append("[<");

        for (glyphs, 0..) |gid, i| {
            const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
            var hex_buf: [4]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{final_gid}) catch unreachable;
            try cw.append(&hex_buf);

            // Add kerning adjustment before next glyph
            if (i + 1 < glyphs.len) {
                const kern = emb.getKerning(gid, glyphs[i + 1]);
                if (kern != 0) {
                    // Convert from font units to 1/1000 em, negate for TJ
                    // TJ uses positive values to move left (reduce spacing)
                    const kern_1000: i32 = @divTrunc(@as(i32, kern) * 1000, @as(i32, units_per_em));
                    try cw.print("> {d} <", .{-kern_1000});
                }
            }
        }

        try cw.append(">] TJ\n");
        return true;
    }

    /// Writes text at the specified position.
    pub fn writeAt(self: *Document, x: f64, y: f64, str: []const u8) !void {
        self.setXY(x, y);
        try self.write(str);
    }

    /// Measures text width using current font (standard or embedded).
    /// Soft-hyphens (U+00AD) are excluded from measurement as they're invisible.
    pub fn getTextWidth(self: *Document, str: []const u8) f64 {
        // Fast path: no soft-hyphens
        if (!containsSoftHyphens(str)) {
            if (self.current_embedded) |emb| {
                return emb.measureTextWidth(str, self.font_size);
            }
            return metrics.measureTextWidth(str, self.getTextStyle());
        }

        // Slow path: filter out soft-hyphens using stack buffer
        var buf: [4096]u8 = undefined;
        var j: usize = 0;
        var i: usize = 0;
        while (i < str.len and j < buf.len) {
            if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
                i += 2; // Skip soft-hyphen
            } else {
                buf[j] = str[i];
                j += 1;
                i += 1;
            }
        }
        const filtered = buf[0..j];

        if (self.current_embedded) |emb| {
            return emb.measureTextWidth(filtered, self.font_size);
        }
        return metrics.measureTextWidth(filtered, self.getTextStyle());
    }

    /// Writes a single line of text into a region.
    /// Does not wrap text. Advances the region cursor by one line height.
    pub fn writeLine(self: *Document, region: *Region, str: []const u8, opts: LineOptions) !WriteResult {
        return self.writeLineInternal(region, str, opts.alignment, opts.valign, 0);
    }

    /// Internal line writer with indent and valign support.
    fn writeLineInternal(self: *Document, region: *Region, str: []const u8, alignment: Align, valign: VAlign, indent: f64) !WriteResult {
        const line_height = self.getLineHeightPts();

        // Check if we have room for a line
        if (region.remainingHeight() < line_height) {
            return .{
                .lines_written = 0,
                .overflow = str,
            };
        }

        const text_width = self.getTextWidth(str);
        const content_width = region.contentWidth();
        const available_width = content_width - indent;

        // Calculate x position based on alignment (content starts at x + padding.left)
        const content_x = region.x + region.padding.left;
        const x = switch (alignment) {
            .left => content_x + indent,
            .center => content_x + indent + (available_width - text_width) / 2,
            .right => content_x + content_width - text_width,
            .justify => content_x + indent, // justify handled separately for multi-word lines
        };

        // Calculate y position based on vertical alignment
        const content_y = region.y + region.padding.top;
        const leading = line_height - self.font_size;
        const y = switch (valign) {
            // Baseline at content_y + cursor_y + font_size (simple)
            .top => content_y + region.cursor_y + self.font_size,
            // Baseline centered: subtract leading/2 (fpdf2 compatible)
            .middle => content_y + region.cursor_y + self.font_size - leading / 2,
            // Baseline at bottom of line height
            .bottom => content_y + region.cursor_y + line_height,
        };

        // Render text
        try self.writeAt(x, y, str);

        // Advance cursor
        region.cursor_y += line_height;

        return .{
            .lines_written = 1,
            .overflow = null,
        };
    }

    /// Find a soft-hyphen break point in a word that fits within max_width.
    /// Soft-hyphen (U+00AD, 0xC2 0xAD in UTF-8) marks optional break points.
    /// Returns the byte position where to break (soft-hyphen will be replaced with visible hyphen).
    fn findSoftHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        var i: usize = 0;
        while (i + 1 < word.len) {
            // Soft-hyphen in UTF-8 is 0xC2 0xAD
            if (word[i] == 0xC2 and word[i + 1] == 0xAD) {
                // Found a soft-hyphen - measure prefix with a visible hyphen substituted
                const prefix = word[0..i];
                const prefix_width = self.getTextWidth(prefix) + self.getTextWidth("-");
                if (prefix_width <= max_width) {
                    best_break = i; // Position of the soft-hyphen
                } else {
                    break; // Prefix too wide, no point checking further
                }
                i += 2; // Skip the 2-byte soft-hyphen
            } else {
                i += 1;
            }
        }
        return best_break;
    }

    /// Find a regular hyphen break point in a word that fits within max_width.
    /// Regular hyphens stay visible; we break AFTER the hyphen (e.g., "state-" / "of-the-art").
    /// Returns the byte position after the hyphen where to split.
    fn findHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        for (word, 0..) |c, i| {
            if (c == '-' and i > 0 and i + 1 < word.len) {
                // Found a hyphen - measure prefix including the hyphen
                const prefix = word[0 .. i + 1];
                const prefix_width = self.getTextWidth(prefix);
                if (prefix_width <= max_width) {
                    best_break = i + 1; // Position after the hyphen
                } else {
                    break; // Prefix too wide, no point checking further
                }
            }
        }
        return best_break;
    }

    /// Find a character break point in a word that fits within max_width.
    /// This is a last resort when no hyphen or soft-hyphen breaks are available.
    /// Returns the byte position where to break (respecting UTF-8 boundaries).
    fn findCharacterBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        var current_width: f64 = 0;
        var i: usize = 0;

        while (i < word.len) {
            // Find the end of the current UTF-8 character
            const char_len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
            const char_end = @min(i + char_len, word.len);

            // Measure width including this character
            const prefix_width = self.getTextWidth(word[0..char_end]);

            if (prefix_width <= max_width) {
                best_break = char_end;
                current_width = prefix_width;
                i = char_end;
            } else {
                break;
            }
        }

        // Only return if we found at least one character that fits
        if (best_break) |pos| {
            if (pos > 0 and pos < word.len) {
                return pos;
            }
        }
        return null;
    }

    /// Strip soft-hyphens (U+00AD) from text.
    /// Soft-hyphens are invisible formatting characters that only appear as visible
    /// hyphens when text breaks at that point. Returns allocated copy without soft-hyphens.
    fn stripSoftHyphens(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
        // Count non-soft-hyphen bytes
        var count: usize = 0;
        var i: usize = 0;
        while (i < str.len) {
            if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
                i += 2; // Skip soft-hyphen
            } else {
                count += 1;
                i += 1;
            }
        }

        // If no soft-hyphens, just duplicate
        if (count == str.len) {
            return allocator.dupe(u8, str);
        }

        // Copy without soft-hyphens
        const result = try allocator.alloc(u8, count);
        var j: usize = 0;
        i = 0;
        while (i < str.len) {
            if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
                i += 2; // Skip soft-hyphen
            } else {
                result[j] = str[i];
                j += 1;
                i += 1;
            }
        }
        return result;
    }

    /// Check if text contains any soft-hyphens.
    fn containsSoftHyphens(str: []const u8) bool {
        var i: usize = 0;
        while (i + 1 < str.len) : (i += 1) {
            if (str[i] == 0xC2 and str[i + 1] == 0xAD) {
                return true;
            }
        }
        return false;
    }

    /// Writes wrapped text into a region.
    /// Returns overflow text if it doesn't fit in the remaining region height.
    pub fn writeParagraph(self: *Document, region: *Region, str: []const u8, opts: ParagraphOptions) !WriteResult {
        const line_height = self.getLineHeightPts();
        const space_width = self.getTextWidth(" ");
        var lines_written: usize = 0;
        var is_first_line = true;

        // Process text word by word
        var remaining = str;
        while (remaining.len > 0) {
            // Check if we have room for another line
            if (region.remainingHeight() < line_height) {
                return .{
                    .lines_written = lines_written,
                    .overflow = remaining,
                };
            }

            // Calculate available width for this line (respects padding)
            const indent = if (is_first_line) opts.first_indent else 0;
            const line_width = region.contentWidth() - indent;

            // Build a line by collecting words
            var line_end: usize = 0;
            var current_width: f64 = 0;
            var word_start: usize = 0;
            var in_word = false;
            var soft_hyphen_break = false;

            for (remaining, 0..) |c, i| {
                const is_space = c == ' ' or c == '\t' or c == '\n';

                if (is_space and in_word) {
                    // End of word - check if it fits
                    const word = remaining[word_start..i];
                    const word_width = self.getTextWidth(word);

                    if (current_width + word_width <= line_width) {
                        // Word fits
                        current_width += word_width + space_width;
                        line_end = i;
                    } else if (line_end == 0) {
                        // First word doesn't fit on empty line - try breaking at hyphens
                        if (opts.break_on_hyphens) {
                            if (findHyphenBreak(self, word, line_width)) |break_pos| {
                                line_end = word_start + break_pos;
                                break;
                            }
                        }
                        // Try soft-hyphen break as fallback
                        if (findSoftHyphenBreak(self, word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                            soft_hyphen_break = true;
                        } else if (findCharacterBreak(self, word, line_width)) |break_pos| {
                            // Last resort: character-level break
                            line_end = word_start + break_pos;
                        } else {
                            // Nothing fits, include word anyway (will overflow)
                            line_end = i;
                        }
                        break;
                    } else {
                        // Word doesn't fit, wrap to next line (keep word intact)
                        break;
                    }
                    in_word = false;

                    // Handle newline as line break
                    if (c == '\n') {
                        line_end = i;
                        break;
                    }
                } else if (!is_space and !in_word) {
                    // Start of word
                    word_start = i;
                    in_word = true;
                }
            }

            // Handle last word if we're still in one
            if (in_word) {
                const word = remaining[word_start..];
                const word_width = self.getTextWidth(word);

                if (current_width + word_width <= line_width) {
                    line_end = remaining.len;
                } else if (line_end == 0) {
                    // First word doesn't fit - try breaking at hyphens
                    if (opts.break_on_hyphens) {
                        if (findHyphenBreak(self, word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                        }
                    }
                    // Try soft-hyphen break as fallback
                    if (line_end == 0) {
                        if (findSoftHyphenBreak(self, word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                            soft_hyphen_break = true;
                        } else if (findCharacterBreak(self, word, line_width)) |break_pos| {
                            // Last resort: character-level break
                            line_end = word_start + break_pos;
                        } else {
                            line_end = remaining.len; // Nothing fits, include anyway
                        }
                    }
                }
                // else: word doesn't fit, leave line_end as is (wrap word to next line)
            }

            // Handle empty remaining (shouldn't happen but safety)
            if (line_end == 0) {
                break;
            }

            // Get the line text and trim trailing spaces
            var line = remaining[0..line_end];
            while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
                line = line[0 .. line.len - 1];
            }

            // Render the line (with visible hyphen if breaking at soft-hyphen)
            if (soft_hyphen_break) {
                // Append visible hyphen for soft-hyphen break
                var buf: [4096]u8 = undefined;
                if (line.len < buf.len - 1) {
                    @memcpy(buf[0..line.len], line);
                    buf[line.len] = '-';
                    _ = try self.writeLineInternal(region, buf[0 .. line.len + 1], opts.alignment, opts.valign, indent);
                } else {
                    // Line too long for buffer, render without hyphen (fallback)
                    _ = try self.writeLineInternal(region, line, opts.alignment, opts.valign, indent);
                }
            } else {
                _ = try self.writeLineInternal(region, line, opts.alignment, opts.valign, indent);
            }
            lines_written += 1;
            is_first_line = false;

            // Skip past rendered text
            if (soft_hyphen_break) {
                // Skip the 2-byte soft-hyphen (0xC2 0xAD)
                remaining = remaining[line_end + 2 ..];
            } else {
                remaining = remaining[line_end..];
            }
            // Skip any following whitespace
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                remaining = remaining[1..];
            }
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
        };
    }

    /// Writes text flowing across pages automatically.
    /// Adds new pages as needed when text overflows.
    pub fn writeFlow(self: *Document, str: []const u8, opts: FlowOptions) !void {
        var remaining: ?[]const u8 = str;

        while (remaining) |txt| {
            var region = self.getPageRegion();
            const result = try self.writeParagraph(&region, txt, .{
                .alignment = opts.alignment,
                .valign = opts.valign,
                .first_indent = opts.first_indent,
            });
            remaining = result.overflow;
            if (remaining != null) {
                try self.addPage();
            }
        }
    }

    /// Draws a region's border and fill (without text).
    pub fn drawRegion(self: *Document, region: *const Region) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];

        // Convert from top-left coordinates to PDF coordinates (bottom-left origin)
        const pdf_y = self.page_size.height - region.y - region.height;

        // Build raw PDF commands for the region
        // Use q/Q (save/restore) to isolate graphics state changes (colors, etc.)
        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Fill if specified
        if (region.fill) |color| {
            len += (std.fmt.bufPrint(buf[len..], "{d:.3} {d:.3} {d:.3} rg\n", .{ color.r, color.g, color.b }) catch unreachable).len;
            len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ region.x, pdf_y, region.width, region.height }) catch unreachable).len;
        }

        // Draw border if specified
        if (region.border.top or region.border.bottom or region.border.left or region.border.right) {
            // Set line width to 0.567pt (fpdf2 default: 0.2mm)
            len += (std.fmt.bufPrint(buf[len..], "0.567 w\n", .{}) catch unreachable).len;
            // Set stroke color to black
            len += (std.fmt.bufPrint(buf[len..], "0 0 0 RG\n", .{}) catch unreachable).len;

            if (region.border.top) {
                const y_top = pdf_y + region.height;
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, y_top, region.x + region.width, y_top }) catch unreachable).len;
            }
            if (region.border.bottom) {
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, pdf_y, region.x + region.width, pdf_y }) catch unreachable).len;
            }
            if (region.border.left) {
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, pdf_y, region.x, pdf_y + region.height }) catch unreachable).len;
            }
            if (region.border.right) {
                const x_right = region.x + region.width;
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ x_right, pdf_y, x_right, pdf_y + region.height }) catch unreachable).len;
            }
        }

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        if (len > 0) {
            const raw_copy = try self.allocator.dupe(u8, buf[0..len]);
            errdefer self.allocator.free(raw_copy);
            try page.commands.append(self.allocator, .{ .raw = raw_copy });
        }
    }

    /// Render deferred commands to page content bytes
    /// Called after subsetting so glyph IDs are properly remapped
    fn renderPageCommands(self: *Document, page: *Page) !void {
        var cw = page.writer(self.allocator);

        for (page.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| {
                    // Begin text block
                    try cw.append("BT\n");

                    switch (t.font) {
                        .embedded => |emb| {
                            const idx = self.getEmbeddedFontIndex(emb) orelse continue;
                            try cw.print("/E{d} {d:.2} Tf\n", .{ idx + 1, t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });

                            if (emb.encoding == .identity) {
                                // CID mode: output with ligatures and kerning
                                _ = try self.renderCIDTextWithKerning(&cw, emb, t.text_data);
                            } else {
                                // WinAnsi mode
                                try cw.append("(");
                                try cw.appendEscaped(t.text_data);
                                try cw.append(") Tj\n");
                            }
                        },
                        .standard => |font| {
                            try cw.print("/{s} {d:.2} Tf\n", .{ fontResourceName(font), t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
                            try cw.append("(");
                            try cw.appendEscaped(t.text_data);
                            try cw.append(") Tj\n");
                        },
                    }

                    try cw.append("ET\n");
                },
                .raw => |data| {
                    try cw.append(data);
                },
            }
        }
    }

    /// Output the PDF document as bytes
    /// Caller owns the returned memory and must free it with the document's allocator
    pub fn output(self: *Document) ![]u8 {
        // Ensure at least one page
        if (self.pages.items.len == 0) {
            try self.addPage();
        }

        var w = Writer.init(self.allocator);
        defer w.offsets.deinit(self.allocator); // Clean up offsets, output is transferred

        try w.writeHeader();

        // Collect used standard fonts into a list for stable ordering
        var font_list = std.ArrayListUnmanaged(StandardFont){};
        defer font_list.deinit(self.allocator);
        var font_iter = self.used_fonts.keyIterator();
        while (font_iter.next()) |font| {
            try font_list.append(self.allocator, font.*);
        }

        // Object ID allocation:
        // 1 = Catalog
        // 2 = Pages (root)
        // 3 to 3+num_standard_fonts-1 = Standard Font objects
        // Then for each embedded font:
        //   WinAnsi: Font, FontDescriptor, FontFile2, ToUnicode (4 objects)
        //   Identity/CID: Type0, CIDFont, FontDescriptor, FontFile2, ToUnicode (5 objects)
        // After fonts = Pages (each page needs 2 objects: page dict + content stream)

        const catalog_id: ObjectId = 1;
        const pages_root_id: ObjectId = 2;
        const first_std_font_id: ObjectId = 3;
        const first_emb_font_id: ObjectId = first_std_font_id + @as(ObjectId, @intCast(font_list.items.len));

        // Calculate total objects needed for embedded fonts and track base IDs
        var emb_font_base_ids = std.ArrayListUnmanaged(ObjectId){};
        defer emb_font_base_ids.deinit(self.allocator);

        var next_emb_id = first_emb_font_id;
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font_base_ids.append(self.allocator, next_emb_id);
            const obj_count: ObjectId = if (emb_font.encoding == .identity) 5 else 4;
            next_emb_id += obj_count;
        }
        const first_page_id: ObjectId = next_emb_id;

        // Build page refs array for Pages object
        var page_refs = Array.init(self.allocator);
        defer page_refs.deinit();

        var next_id = first_page_id;
        for (self.pages.items) |_| {
            try page_refs.append(Value.ref(.{ .id = next_id }));
            next_id += 2; // Each page uses 2 objects (page dict + content stream)
        }

        // Write Catalog
        try w.beginObject(catalog_id);
        var catalog = Dict.init(self.allocator);
        defer catalog.deinit();
        try catalog.put("Type", Value.name("Catalog"));
        try catalog.put("Pages", Value.ref(.{ .id = pages_root_id }));
        try w.writeDict(catalog);
        try w.endObject();

        // Write Pages (root)
        try w.beginObject(pages_root_id);
        var pages_dict = Dict.init(self.allocator);
        defer pages_dict.deinit();
        try pages_dict.put("Type", Value.name("Pages"));
        try pages_dict.put("Kids", .{ .array_val = &page_refs });
        try pages_dict.put("Count", Value.int(@intCast(self.pages.items.len)));
        try w.writeDict(pages_dict);
        try w.endObject();

        // Write standard font objects
        for (font_list.items, 0..) |font, i| {
            const font_id = first_std_font_id + @as(ObjectId, @intCast(i));
            try w.beginObject(font_id);
            var font_dict = Dict.init(self.allocator);
            defer font_dict.deinit();
            try font_dict.put("Type", Value.name("Font"));
            try font_dict.put("Subtype", Value.name("Type1"));
            try font_dict.put("BaseFont", Value.name(font.pdfName()));
            try w.writeDict(font_dict);
            try w.endObject();
        }

        // Generate font subsets (only include used glyphs)
        // This also populates gid_remap for compact CFF subsetting
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font.generateSubset();
        }

        // Render deferred commands to content bytes (AFTER subsetting so glyph IDs are remapped)
        for (self.pages.items) |*page| {
            try self.renderPageCommands(page);
        }

        // Write embedded font objects
        for (self.embedded_fonts.items, 0..) |emb_font, i| {
            const base_id = emb_font_base_ids.items[i];

            if (emb_font.encoding == .identity) {
                // CID font: Type0, CIDFont, FontDescriptor, FontFile2, ToUnicode (5 objects)
                const type0_id = base_id;
                const cidfont_id = base_id + 1;
                const descriptor_id = base_id + 2;
                const fontfile_id = base_id + 3;
                const tounicode_id = base_id + 4;

                // Generate ToUnicode CMap for CID
                const tounicode_cmap = try emb_font.generateCIDToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // Generate /W width array
                const w_array = try emb_font.generateWidthArray();
                defer self.allocator.free(w_array);

                // 1. Type0 (composite) font
                try w.beginObject(type0_id);
                {
                    var font_dict = Dict.init(self.allocator);
                    defer font_dict.deinit();
                    try font_dict.put("Type", Value.name("Font"));
                    try font_dict.put("Subtype", Value.name("Type0"));
                    try font_dict.put("BaseFont", Value.name(emb_font.name));
                    try font_dict.put("Encoding", Value.name("Identity-H"));
                    try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

                    // DescendantFonts array with single CIDFont reference
                    var descendants = Array.init(self.allocator);
                    defer descendants.deinit();
                    try descendants.append(Value.ref(.{ .id = cidfont_id }));
                    try font_dict.put("DescendantFonts", .{ .array_val = &descendants });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. CIDFont (CIDFontType2 for TrueType, CIDFontType0 for CFF)
                const is_cff = emb_font.font.isCFF();
                try w.beginObject(cidfont_id);
                {
                    var cid_dict = Dict.init(self.allocator);
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
                    var cidsysinfo = Dict.init(self.allocator);
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
                try w.beginObject(descriptor_id);
                {
                    var desc_dict = Dict.init(self.allocator);
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

                    var bbox_array = Array.init(self.allocator);
                    defer bbox_array.deinit();
                    for (emb_font.bbox) |val| {
                        try bbox_array.append(Value.int(val));
                    }
                    try desc_dict.put("FontBBox", .{ .array_val = &bbox_array });

                    try w.writeDict(desc_dict);
                }
                try w.endObject();

                // 4. FontFile stream (FontFile2 for TTF, FontFile3 for CFF)
                try w.beginObject(fontfile_id);
                {
                    const font_data = emb_font.getFontData();
                    var stream_dict = Dict.init(self.allocator);
                    defer stream_dict.deinit();

                    if (is_cff) {
                        // CFF requires Subtype
                        try stream_dict.put("Subtype", Value.name("CIDFontType0C"));
                    } else {
                        try stream_dict.put("Length1", Value.int(@intCast(font_data.len)));
                    }
                    try w.writeStreamCompressed(&stream_dict, font_data);
                }
                try w.endObject();

                // 5. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStreamCompressed(&tounicode_dict, tounicode_cmap);
                }
                try w.endObject();
            } else {
                // WinAnsi font: Font, FontDescriptor, FontFile2, ToUnicode (4 objects)
                const font_dict_id = base_id;
                const descriptor_id = base_id + 1;
                const fontfile_id = base_id + 2;
                const tounicode_id = base_id + 3;

                // Generate ToUnicode CMap
                const tounicode_cmap = try emb_font.generateToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // 1. Font dictionary
                try w.beginObject(font_dict_id);
                {
                    var font_dict = Dict.init(self.allocator);
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
                    var widths_array = Array.init(self.allocator);
                    defer widths_array.deinit();
                    for (emb_font.widths) |width| {
                        try widths_array.append(Value.int(@intCast(width)));
                    }
                    try font_dict.put("Widths", .{ .array_val = &widths_array });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. FontDescriptor
                const is_cff_wa = emb_font.font.isCFF();
                try w.beginObject(descriptor_id);
                {
                    var desc_dict = Dict.init(self.allocator);
                    defer desc_dict.deinit();
                    try desc_dict.put("Type", Value.name("FontDescriptor"));
                    try desc_dict.put("FontName", Value.name(emb_font.name));
                    try desc_dict.put("Flags", Value.int(@intCast(emb_font.flags.toInt())));
                    try desc_dict.put("ItalicAngle", Value.int(emb_font.italic_angle));
                    try desc_dict.put("Ascent", Value.int(emb_font.ascent));
                    try desc_dict.put("Descent", Value.int(emb_font.descent));
                    try desc_dict.put("CapHeight", Value.int(emb_font.cap_height));
                    try desc_dict.put("StemV", Value.int(@intCast(emb_font.stem_v)));

                    if (is_cff_wa) {
                        try desc_dict.put("FontFile3", Value.ref(.{ .id = fontfile_id }));
                    } else {
                        try desc_dict.put("FontFile2", Value.ref(.{ .id = fontfile_id }));
                    }

                    var bbox_array = Array.init(self.allocator);
                    defer bbox_array.deinit();
                    for (emb_font.bbox) |val| {
                        try bbox_array.append(Value.int(val));
                    }
                    try desc_dict.put("FontBBox", .{ .array_val = &bbox_array });

                    try w.writeDict(desc_dict);
                }
                try w.endObject();

                // 3. FontFile stream
                try w.beginObject(fontfile_id);
                {
                    const font_data = emb_font.getFontData();
                    var stream_dict = Dict.init(self.allocator);
                    defer stream_dict.deinit();

                    if (is_cff_wa) {
                        try stream_dict.put("Subtype", Value.name("Type1C"));
                    } else {
                        try stream_dict.put("Length1", Value.int(@intCast(font_data.len)));
                    }
                    try w.writeStreamCompressed(&stream_dict, font_data);
                }
                try w.endObject();

                // 4. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStreamCompressed(&tounicode_dict, tounicode_cmap);
                }
                try w.endObject();
            }
        }

        // Write each page
        next_id = first_page_id;
        for (self.pages.items) |page| {
            const page_id = next_id;
            const content_id = next_id + 1;
            next_id += 2;

            // Page dictionary
            try w.beginObject(page_id);
            var page_dict = Dict.init(self.allocator);
            defer page_dict.deinit();
            try page_dict.put("Type", Value.name("Page"));
            try page_dict.put("Parent", Value.ref(.{ .id = pages_root_id }));

            // MediaBox
            var media_box = Array.init(self.allocator);
            defer media_box.deinit();
            try media_box.append(Value.int(0));
            try media_box.append(Value.int(0));
            try media_box.append(Value.real(self.page_size.width));
            try media_box.append(Value.real(self.page_size.height));
            try page_dict.put("MediaBox", .{ .array_val = &media_box });

            try page_dict.put("Contents", Value.ref(.{ .id = content_id }));

            // Font resources (must stay in scope until writeDict completes)
            var font_res = Dict.init(self.allocator);
            defer font_res.deinit();
            var resources = Dict.init(self.allocator);
            defer resources.deinit();

            var has_fonts = false;

            // Add standard font resources
            for (font_list.items, 0..) |font, idx| {
                if (page.used_fonts.contains(font)) {
                    const font_obj_id = first_std_font_id + @as(ObjectId, @intCast(idx));
                    try font_res.put(fontResourceName(font), Value.ref(.{ .id = font_obj_id }));
                    has_fonts = true;
                }
            }

            // Add embedded font resources
            for (page.used_embedded.items) |emb_font| {
                // Find index of this font
                for (self.embedded_fonts.items, 0..) |doc_font, idx| {
                    if (doc_font == emb_font) {
                        // Use pre-calculated base ID for this font
                        const font_obj_id = emb_font_base_ids.items[idx];
                        const res_name = embeddedFontResourceName(idx);
                        try font_res.put(res_name, Value.ref(.{ .id = font_obj_id }));
                        has_fonts = true;
                        break;
                    }
                }
            }

            if (has_fonts) {
                try resources.put("Font", .{ .dict_val = &font_res });
                try page_dict.put("Resources", .{ .dict_val = &resources });
            }

            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream (compressed)
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStreamCompressed(&content_dict, page.content.items);
            try w.endObject();
        }

        // Finish with xref and trailer
        return try w.finish(.{ .id = catalog_id });
    }
};

test "Document init/deinit" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
}

test "Document output minimal PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF structure
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test "Document with text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Hello, World!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check text content
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "BT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Hello, World!) Tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "ET") != null);
}

// Tests ported from fpdf2

test "page format A4" {
    // fpdf2: test_page_format_ok - a4 format
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), PageSize.A4.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), PageSize.A4.height, 0.01);
}

test "page format Letter" {
    // fpdf2: test_page_format_ok - letter format
    try std.testing.expectApproxEqAbs(@as(f64, 612), PageSize.Letter.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 792), PageSize.Letter.height, 0.01);
}

test "text without font returns error" {
    // fpdf2: test_text_no_font_set
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Should fail because no font is set
    try std.testing.expectError(error.NoFont, doc.write("test"));
}

test "text without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    // Should fail because no page is added
    try std.testing.expectError(error.NoPage, doc.write("test"));
}

test "multiple fonts on single page" {
    // fpdf2: test_text_positioning - multiple fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Helvetica");

    try doc.setFont(.times_roman, 12);
    try doc.writeAt(50, 70, "Times");

    try doc.setFont(.courier, 12);
    try doc.writeAt(50, 90, "Courier");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all fonts are present
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier") != null);
}

test "font styles" {
    // fpdf2: tests various font styles
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Normal");

    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(50, 70, "Bold");

    try doc.setFont(.helvetica_oblique, 12);
    try doc.writeAt(50, 90, "Italic");

    try doc.setFont(.helvetica_bold_oblique, 12);
    try doc.writeAt(50, 110, "BoldItalic");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
}

test "positioning setXY" {
    // fpdf2: test_positioning tests
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    doc.setXY(100, 200);
    try std.testing.expectApproxEqAbs(@as(f64, 100), doc.getX(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 200), doc.getY(), 0.01);

    doc.setX(150);
    try std.testing.expectApproxEqAbs(@as(f64, 150), doc.getX(), 0.01);

    doc.setY(300);
    try std.testing.expectApproxEqAbs(@as(f64, 300), doc.getY(), 0.01);
}

test "multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Page 1");

    try doc.addPage();
    try doc.writeAt(50, 50, "Page 2");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check page count
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
}

test "all 14 standard fonts" {
    // fpdf2: tests all standard fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    const all_fonts = [_]StandardFont{
        .helvetica,
        .helvetica_bold,
        .helvetica_oblique,
        .helvetica_bold_oblique,
        .times_roman,
        .times_bold,
        .times_italic,
        .times_bold_italic,
        .courier,
        .courier_bold,
        .courier_oblique,
        .courier_bold_oblique,
        .symbol,
        .zapf_dingbats,
    };

    var y: f64 = 50;
    for (all_fonts) |font| {
        try doc.setFont(font, 10);
        try doc.writeAt(50, y, font.pdfName());
        y += 15;
    }

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all 14 fonts are used by name
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Italic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-BoldItalic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-BoldOblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /ZapfDingbats") != null);
}

test "Document measureText" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    const m = doc.measureText("Hello");

    // "Hello" = H(722) + e(556) + l(222) + l(222) + o(556) = 2278
    // Width = 2278 * 12 / 1000 = 27.336
    try std.testing.expectApproxEqAbs(@as(f64, 27.336), m.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), m.height, 0.01); // 12 * 1.2
}

test "Document measureText with spacing" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    doc.setCharSpacing(2.0);

    const m = doc.measureText("Hello");

    // Base ~27.336 + 4 * 2.0 = 35.336
    try std.testing.expectApproxEqAbs(@as(f64, 35.336), m.width, 0.01);
}

test "Document line height" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);

    // Default line height is 1.2
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), doc.getLineHeightPts(), 0.01);

    doc.setLineHeight(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 18.0), doc.getLineHeightPts(), 0.01);
}

test {
    _ = objects;
    _ = fonts;
    _ = metrics;
    _ = ttf;
    _ = embedded;
    _ = @import("writer.zig");
    _ = @import("testing.zig");
    _ = @import("integration_tests.zig");
}

// ============================================================================
// Embedded Font Tests
// ============================================================================

test "load embedded font from file" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Verify font was loaded
    try std.testing.expect(doc.embedded_fonts.items.len == 1);
    try std.testing.expect(doc.embedded_fonts.items[0] == font);

    // Check font name was extracted
    try std.testing.expect(font.name.len > 0);

    // Check metrics are sensible
    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.descent < 0); // Descent is negative
}

test "embedded font character widths" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Courier Prime is monospace - all visible chars should have same width
    const width_A = font.widths['A'];
    const width_Z = font.widths['Z'];
    const width_a = font.widths['a'];
    const width_m = font.widths['m'];

    try std.testing.expect(width_A > 0);
    try std.testing.expectEqual(width_A, width_Z);
    try std.testing.expectEqual(width_A, width_a);
    try std.testing.expectEqual(width_A, width_m);

    // Space should have a width
    try std.testing.expect(font.widths[' '] > 0);
}

test "embedded font text measurement" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Measure text at 12pt
    const width = font.measureTextWidth("Hello", 12.0);
    try std.testing.expect(width > 0);

    // "Hello" is 5 chars, monospace - each char same width
    const char_width = font.measureTextWidth("H", 12.0);
    try std.testing.expectApproxEqAbs(char_width * 5, width, 0.01);
}

test "render text with embedded font" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.writeAt(50, 50, "Hello, World!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF structure for embedded font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /TrueType") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontDescriptor") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontFile2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Widths [") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Encoding /WinAnsiEncoding") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ToUnicode") != null);

    // Check FontDescriptor fields
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /FontDescriptor") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Ascent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Descent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CapHeight") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontBBox") != null);

    // Check text rendering uses embedded font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 12") != null); // Embedded font E1 at 12pt
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Hello, World!) Tj") != null);
}

test "mix standard and embedded fonts" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const courier_prime = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();

    // Use standard font first
    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Helvetica text");

    // Switch to embedded font
    try doc.setEmbeddedFont(courier_prime, 14);
    try doc.writeAt(50, 70, "Courier Prime text");

    // Switch back to standard
    try doc.setFont(.times_roman, 12);
    try doc.writeAt(50, 90, "Times text");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all font types present (these are in dict, not compressed content stream)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type1") != null); // Standard fonts
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /TrueType") != null); // Embedded font

    // Check fonts are referenced in page Resources (uncompressed)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/F1 ") != null); // Helvetica ref
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 ") != null); // Embedded font ref
}

test "multiple embedded fonts" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const courier_regular = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    const courier_bold = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold.ttf");

    try doc.addPage();

    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.writeAt(50, 50, "Regular");

    try doc.setEmbeddedFont(courier_bold, 12);
    try doc.writeAt(50, 70, "Bold");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check both fonts are embedded
    try std.testing.expect(doc.embedded_fonts.items.len == 2);

    // Both fonts should have TrueType entries
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, pdf[pos..], "/Subtype /TrueType")) |idx| {
        count += 1;
        pos += idx + 1;
    }
    try std.testing.expect(count >= 2);

    // Check E1 and E2 font references in Resources (uncompressed)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E2 ") != null);
}

test "embedded font on multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.writeAt(50, 50, "Page 1");

    try doc.addPage();
    // Font should still be set
    try doc.writeAt(50, 50, "Page 2");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Font should only be embedded once
    var font_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, pdf[pos..], "/Subtype /TrueType")) |idx| {
        font_count += 1;
        pos += idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), font_count);

    // Both pages should reference the font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
}

test "embedded font flags - monospace detection" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Courier Prime is monospace
    const monospace = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    try std.testing.expect(monospace.flags.fixed_pitch == true);
}

test "embedded font bbox scaling" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // BBox should be scaled to 1000 units
    // x_min should typically be negative or small
    // y_min should be negative (descenders)
    // x_max and y_max should be positive and reasonable for 1000 units
    try std.testing.expect(font.bbox[3] > 0); // y_max (ascenders)
    try std.testing.expect(font.bbox[3] <= 1500); // Should be scaled properly
    try std.testing.expect(font.bbox[1] <= 0); // y_min should be 0 or negative
}

test "embedded font widths array in PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.writeAt(50, 50, "Test");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Widths array should start with /Widths [
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Widths [") != null);

    // Should have 256 entries (FirstChar 0 to LastChar 255)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FirstChar 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/LastChar 255") != null);
}

test "variable font loading" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Inter Variable is a variable font - should still load basic metrics
    const font = doc.loadFont("test/fonts/Inter/InterVariable.ttf") catch |err| {
        // Variable fonts might have extra tables we don't handle yet
        // For now, skip if loading fails
        std.debug.print("Skipping variable font test: {}\n", .{err});
        return;
    };

    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.widths['A'] > 0);
}

test "PDF output is valid with embedded font" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 24);
    try doc.writeAt(100, 100, "Test embedded font!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic PDF structure validation
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "trailer") != null);

    // Font stream data should be present (TTF data embedded)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Length1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "stream\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "\nendstream") != null);
}

// ============================================================================
// Text Flow API Tests
// ============================================================================

test "unit conversions" {
    // 1 inch = 72 points
    try std.testing.expectEqual(@as(f64, 72), inches(1));
    try std.testing.expectEqual(@as(f64, 36), inches(0.5));

    // 25.4mm = 1 inch = 72 points
    try std.testing.expectApproxEqAbs(@as(f64, 72), mm(25.4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.835), mm(1), 0.001);

    // 2.54cm = 1 inch = 72 points
    try std.testing.expectApproxEqAbs(@as(f64, 72), cm(2.54), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 28.35), cm(1), 0.01);
}

test "getPageRegion respects margins" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setMargins(.{ .left = 50, .right = 50, .top = 100, .bottom = 100 });
    const region = doc.getPageRegion();

    try std.testing.expectEqual(@as(f64, 50), region.x);
    try std.testing.expectEqual(@as(f64, 100), region.y);
    try std.testing.expectEqual(PageSize.A4.width - 100, region.width);
    try std.testing.expectEqual(PageSize.A4.height - 200, region.height);
}

test "writeLine advances cursor" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = doc.getPageRegion();
    const initial_cursor = region.cursor_y;

    _ = try doc.writeLine(&region, "Test line", .{});

    try std.testing.expect(region.cursor_y > initial_cursor);
    try std.testing.expectEqual(doc.getLineHeightPts(), region.cursor_y);
}

test "writeLine alignment" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 100, .y = 100, .width = 400, .height = 600 };

    // Test left alignment (default)
    _ = try doc.writeLine(&region, "Left", .{});
    // Test center alignment
    _ = try doc.writeLine(&region, "Center", .{ .alignment = .center });
    // Test right alignment
    _ = try doc.writeLine(&region, "Right", .{ .alignment = .right });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic validation - PDF should be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "writeParagraph word wrapping" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 600 };
    const long_text = "This is a longer piece of text that should wrap across multiple lines within the region.";

    const result = try doc.writeParagraph(&region, long_text, .{});

    try std.testing.expect(result.lines_written > 1);
    try std.testing.expect(result.overflow == null);
}

test "writeParagraph overflow" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Small region - line height at 12pt with 1.2 factor = 14.4pt
    // Region of 15pt should fit one line, but not two (would need 28.8pt)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 15 };
    const long_text = "Word one two three four five six seven eight nine ten.";

    const result = try doc.writeParagraph(&region, long_text, .{});

    // Should only fit one line due to height constraint
    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
    try std.testing.expect(result.overflow != null);
}

test "writeFlow creates multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 50, .right = 50, .top = 50, .bottom = 50 });

    // Generate long text that should span multiple pages
    // A4 height is ~842pt, minus margins (100pt) = 742pt usable
    // At 12pt font with 1.2 line height = 14.4pt per line
    // ~51 lines per page, so we need >51 lines worth of text
    const paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor. " ** 100;

    try doc.writeFlow(paragraph, .{});

    // Should have created multiple pages
    try std.testing.expect(doc.pages.items.len > 1);
}

test "drawRegion with border" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    const region = Region{
        .x = 50,
        .y = 50,
        .width = 200,
        .height = 100,
        .border = Border.all,
    };

    try doc.drawRegion(&region);

    // Verify page has commands (the raw drawing commands)
    try std.testing.expect(doc.pages.items[0].commands.items.len == 1);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic PDF structure validation
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test "drawRegion with fill" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    const region = Region{
        .x = 50,
        .y = 50,
        .width = 200,
        .height = 100,
        .fill = Color.red,
    };

    try doc.drawRegion(&region);

    // Verify page has commands (the raw drawing commands)
    try std.testing.expect(doc.pages.items[0].commands.items.len == 1);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic PDF structure validation
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test "findHyphenBreak finds break at regular hyphen" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // "state-of-the-art" - should find breaks after each hyphen
    const word = "state-of-the-art";

    // Width that fits "state-" but not more
    const state_width = doc.getTextWidth("state-");
    const result = doc.findHyphenBreak(word, state_width + 1);
    try std.testing.expectEqual(@as(?usize, 6), result); // "state-" is 6 bytes

    // Width that fits "state-of-" but not "state-of-the-"
    const state_of_width = doc.getTextWidth("state-of-");
    const result2 = doc.findHyphenBreak(word, state_of_width + 1);
    try std.testing.expectEqual(@as(?usize, 9), result2); // "state-of-" is 9 bytes
}

test "findHyphenBreak returns null for word without hyphens" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    const word = "supercalifragilistic";
    const result = doc.findHyphenBreak(word, 1000);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "findSoftHyphenBreak finds break at soft hyphen" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // "ex\xc2\xadplicit" - soft-hyphen between "ex" and "plicit"
    const word = "ex\xc2\xadplicit";

    // Width that fits "ex-" (prefix + visible hyphen)
    const ex_width = doc.getTextWidth("ex-");
    const result = doc.findSoftHyphenBreak(word, ex_width + 1);
    try std.testing.expectEqual(@as(?usize, 2), result); // Position of soft-hyphen
}

test "findSoftHyphenBreak returns null for word without soft hyphens" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    const word = "explicit";
    const result = doc.findSoftHyphenBreak(word, 1000);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "soft hyphens stripped from text output" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Write text with soft-hyphens
    try doc.write("ex\xc2\xadplic\xc2\xadit");

    // The stored text should have soft-hyphens stripped
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 1), page.commands.items.len);
    const cmd = page.commands.items[0];
    try std.testing.expectEqualStrings("explicit", cmd.text.text_data);
}

test "soft-hyphen recursive breaking in narrow column" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 11);

    // At 11pt Helvetica:
    // - "in-" is ~12.8pt (fits in 26pt)
    // - "com-" is ~24.4pt (fits in 26pt)
    // - "compre-" is ~36.7pt (doesn't fit in 26pt)
    // So with 26pt column, we should get: "in-", "com-", "pre-", "hen-", "si-", "ble"

    // 26pt column - wide enough for "com-" to fit
    var region = Region{ .x = 72, .y = 100, .width = 26, .height = 200 };
    const word = "in\xc2\xadcom\xc2\xadpre\xc2\xadhen\xc2\xadsi\xc2\xadble";

    const result = try doc.writeParagraph(&region, word, .{ .break_on_hyphens = false });

    // Should produce multiple lines (at least 3)
    const page = &doc.pages.items[0];
    var text_count: usize = 0;
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            text_count += 1;
        }
    }

    // With 26pt column, "incomprehensible" must break multiple times
    try std.testing.expect(result.lines_written >= 3);
    try std.testing.expect(text_count >= 3);
}

test "soft hyphens excluded from text width" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Width with soft-hyphens should equal width without
    const with_soft = doc.getTextWidth("ex\xc2\xadplic\xc2\xadit");
    const without_soft = doc.getTextWidth("explicit");
    try std.testing.expectEqual(without_soft, with_soft);
}

test "writeParagraph breaks at hyphens when enabled" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Narrow region - forces "state-of-the-art" to break if hyphen breaking enabled
    // At 12pt Helvetica, "state-of-the-art" is about 86pt wide
    // Make region narrow enough to force a break
    var region = Region{ .x = 50, .y = 50, .width = 70, .height = 200 };

    const result = try doc.writeParagraph(&region, "state-of-the-art", .{ .break_on_hyphens = true });

    // With hyphen breaking enabled, should break into multiple lines
    try std.testing.expect(result.lines_written > 1);
}

test "writeParagraph keeps hyphenated words together when disabled" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Region wide enough for the word to fit on one line
    // At 12pt Helvetica, "state-of-the-art" is about 86pt wide
    var region = Region{ .x = 50, .y = 50, .width = 90, .height = 200 };

    const result = try doc.writeParagraph(&region, "state-of-the-art", .{ .break_on_hyphens = false });

    // With hyphen breaking disabled, word stays together on one line
    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
}

test "writeParagraph character-level wrapping for long words" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Narrow region - long word without soft-hyphens will be character-wrapped
    // At 12pt Helvetica, "supercalifragilisticexpialidocious" is about 180pt wide
    var region = Region{ .x = 50, .y = 50, .width = 60, .height = 200 };

    const result = try doc.writeParagraph(&region, "supercalifragilisticexpialidocious", .{});

    // Long word should be broken into multiple lines via character wrapping
    try std.testing.expect(result.lines_written > 1);

    // All characters should be output (no overflow)
    try std.testing.expect(result.overflow == null);
}

test "writeParagraph first line indent" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 200 };
    const text = "First line has indent. Second line does not.";

    _ = try doc.writeParagraph(&region, text, .{ .first_indent = 20 });

    // Check that two text commands were created (two lines)
    const page = &doc.pages.items[0];
    var text_count: usize = 0;
    var first_x: ?f64 = null;
    var second_x: ?f64 = null;
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            text_count += 1;
            if (first_x == null) {
                first_x = cmd.text.x;
            } else if (second_x == null) {
                second_x = cmd.text.x;
            }
        }
    }

    try std.testing.expect(text_count >= 2);
    // First line should be 20pt further right than second line
    if (first_x != null and second_x != null) {
        try std.testing.expectApproxEqAbs(first_x.? - 20, second_x.?, 0.1);
    }
}

test "writeParagraph overflow returns remaining text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Region that can only fit 2 lines (line height = 14.4pt at 12pt font)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 30 };
    const text = "Line one fits here. Line two fits too. Line three overflows. Line four too.";

    const result = try doc.writeParagraph(&region, text, .{});

    try std.testing.expectEqual(@as(usize, 2), result.lines_written);
    try std.testing.expect(result.overflow != null);
    // Overflow should contain the text that didn't fit
    try std.testing.expect(std.mem.indexOf(u8, result.overflow.?, "Line three") != null);
}

test "writeParagraph newline forces line break" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    const text = "Line one.\nLine two.\nLine three.";

    const result = try doc.writeParagraph(&region, text, .{});

    // Should have 3 lines due to explicit newlines
    try std.testing.expectEqual(@as(usize, 3), result.lines_written);
}

test "writeLine returns overflow for too-long text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Small region that can only fit ~1 line
    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 15 };

    const result1 = try doc.writeLine(&region, "First line", .{});
    try std.testing.expectEqual(@as(usize, 1), result1.lines_written);
    try std.testing.expect(result1.overflow == null);

    // Second line should indicate no room
    const result2 = try doc.writeLine(&region, "Second line", .{});
    try std.testing.expectEqual(@as(usize, 0), result2.lines_written);
    try std.testing.expectEqualStrings("Second line", result2.overflow.?);
}

test "region padding affects content area" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Region with padding
    var region = Region{
        .x = 50,
        .y = 50,
        .width = 200,
        .height = 100,
        .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
    };

    // Content width should be width - left - right
    try std.testing.expectEqual(@as(f64, 180), region.contentWidth());

    // Remaining height initially should be height - top - bottom
    try std.testing.expectEqual(@as(f64, 90), region.remainingHeight());

    // Write a line and check remaining height decreased
    _ = try doc.writeLine(&region, "Test", .{});
    try std.testing.expect(region.remainingHeight() < 90);
}

test "writeFlow handles empty text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 50, .right = 50, .top = 50, .bottom = 50 });

    // Empty text should not crash
    try doc.writeFlow("", .{});

    // Should still have just one page
    try std.testing.expectEqual(@as(usize, 1), doc.pages.items.len);
}

test "writeFlow respects margins" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 100, .right = 100, .top = 100, .bottom = 100 });

    try doc.writeFlow("Short text.", .{});

    // Check text position respects left margin
    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            try std.testing.expect(cmd.text.x >= 100);
        }
    }
}

test "valign top puts baseline at cursor + font_size" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    _ = try doc.writeLine(&region, "Test", .{ .valign = .top });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // top-down y = region.y + cursor_y(0) + font_size(12) = 112
            // PDF y = page_height(841.89) - 112 = 729.89
            try std.testing.expectApproxEqAbs(@as(f64, 729.89), cmd.text.y, 0.1);
        }
    }
}

test "valign middle adjusts for leading" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    _ = try doc.writeLine(&region, "Test", .{ .valign = .middle });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // line_height = 12 * 1.2 = 14.4, leading = 2.4
            // top-down y = region.y + cursor_y(0) + font_size(12) - leading/2(1.2) = 110.8
            // PDF y = page_height(841.89) - 110.8 = 731.09
            try std.testing.expectApproxEqAbs(@as(f64, 731.09), cmd.text.y, 0.1);
        }
    }
}

test "valign bottom puts baseline at cursor + line_height" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    _ = try doc.writeLine(&region, "Test", .{ .valign = .bottom });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // top-down y = region.y + cursor_y(0) + line_height(14.4) = 114.4
            // PDF y = page_height(841.89) - 114.4 = 727.49
            try std.testing.expectApproxEqAbs(@as(f64, 727.49), cmd.text.y, 0.1);
        }
    }
}
