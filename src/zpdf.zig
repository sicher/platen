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
pub const Writer = @import("writer.zig").Writer;

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

pub const StandardFont = fonts.StandardFont;
pub const Font = fonts.Font;
pub const TextMetrics = metrics.TextMetrics;
pub const TextStyle = metrics.TextStyle;

/// Page size in points (1 point = 1/72 inch)
pub const PageSize = struct {
    width: f64,
    height: f64,

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
};

/// Internal page representation
const Page = struct {
    content: std.ArrayListUnmanaged(u8),
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void),

    fn init() Page {
        return .{
            .content = .{},
            .used_fonts = .{},
        };
    }

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.used_fonts.deinit(allocator);
    }

    fn markFontUsed(self: *Page, allocator: std.mem.Allocator, font: StandardFont) !void {
        try self.used_fonts.put(allocator, font, {});
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

/// Escape special characters in PDF strings
fn escapePdfString(str: []const u8) []const u8 {
    // TODO: properly escape (, ), and \ characters
    // For now, assume input is safe
    return str;
}

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,
    // Text state
    current_font: ?StandardFont = null,
    font_size: f64 = 12,
    x: f64 = 0,
    y: f64 = 0,
    /// Extra space between characters (in points). Can be negative.
    char_spacing: f64 = 0,
    /// Line height as multiple of font size. Default 1.2 (20% leading).
    line_height: f64 = 1.2,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .{},

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
    }

    /// Add a new page
    pub fn addPage(self: *Document) !void {
        try self.pages.append(self.allocator, Page.init());
        // Reset position to top-left (PDF coordinates: origin at bottom-left)
        self.x = 0;
        self.y = self.page_size.height;
    }

    /// Set the current font and size
    pub fn setFont(self: *Document, font: StandardFont, size: f64) !void {
        self.current_font = font;
        self.font_size = size;
        try self.used_fonts.put(self.allocator, font, {});
    }

    /// Set character spacing (extra space between characters, in points)
    pub fn setCharSpacing(self: *Document, spacing: f64) void {
        self.char_spacing = spacing;
    }

    /// Set line height (as multiple of font size, e.g. 1.2 = 120%)
    pub fn setLineHeight(self: *Document, height: f64) void {
        self.line_height = height;
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

    /// Draw text at the current position
    pub fn text(self: *Document, str: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        const font = self.current_font orelse return error.NoFont;

        var page = &self.pages.items[self.pages.items.len - 1];
        try page.markFontUsed(self.allocator, font);

        var cw = page.writer(self.allocator);

        // Begin text block
        try cw.append("BT\n");

        // Set font
        try cw.print("/{s} {d:.2} Tf\n", .{ fontResourceName(font), self.font_size });

        // Set character spacing if non-zero (Tc operator)
        if (self.char_spacing != 0) {
            try cw.print("{d:.2} Tc\n", .{self.char_spacing});
        }

        // Position and show text
        try cw.print("{d:.2} {d:.2} Td\n", .{ self.x, self.y });
        try cw.append("(");
        try cw.append(escapePdfString(str));
        try cw.append(") Tj\n");

        // End text block
        try cw.append("ET\n");
    }

    /// Draw text at a specific position
    pub fn textAt(self: *Document, x: f64, y: f64, str: []const u8) !void {
        self.setXY(x, y);
        try self.text(str);
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

        // Collect used fonts into a list for stable ordering
        var font_list = std.ArrayListUnmanaged(StandardFont){};
        defer font_list.deinit(self.allocator);
        var font_iter = self.used_fonts.keyIterator();
        while (font_iter.next()) |font| {
            try font_list.append(self.allocator, font.*);
        }

        // Object ID allocation:
        // 1 = Catalog
        // 2 = Pages (root)
        // 3 to 3+num_fonts-1 = Font objects
        // After fonts = Pages (each page needs 2 objects: page dict + content stream)

        const catalog_id: ObjectId = 1;
        const pages_root_id: ObjectId = 2;
        const first_font_id: ObjectId = 3;
        const first_page_id: ObjectId = first_font_id + @as(ObjectId, @intCast(font_list.items.len));

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

        // Write font objects
        for (font_list.items, 0..) |font, i| {
            const font_id = first_font_id + @as(ObjectId, @intCast(i));
            try w.beginObject(font_id);
            var font_dict = Dict.init(self.allocator);
            defer font_dict.deinit();
            try font_dict.put("Type", Value.name("Font"));
            try font_dict.put("Subtype", Value.name("Type1"));
            try font_dict.put("BaseFont", Value.name(font.pdfName()));
            try w.writeDict(font_dict);
            try w.endObject();
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

            // Add font resources if page uses any fonts
            if (page.used_fonts.count() > 0) {
                // Add references to each font used by this page
                for (font_list.items, 0..) |font, i| {
                    if (page.used_fonts.contains(font)) {
                        const font_obj_id = first_font_id + @as(ObjectId, @intCast(i));
                        try font_res.put(fontResourceName(font), Value.ref(.{ .id = font_obj_id }));
                    }
                }
                try resources.put("Font", .{ .dict_val = &font_res });
                try page_dict.put("Resources", .{ .dict_val = &resources });
            }

            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStream(&content_dict, page.content.items);
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
    try doc.textAt(50, 50, "Hello, World!");

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
    try std.testing.expectError(error.NoFont, doc.text("test"));
}

test "text without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    // Should fail because no page is added
    try std.testing.expectError(error.NoPage, doc.text("test"));
}

test "multiple fonts on single page" {
    // fpdf2: test_text_positioning - multiple fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Helvetica");

    try doc.setFont(.times_roman, 12);
    try doc.textAt(50, 70, "Times");

    try doc.setFont(.courier, 12);
    try doc.textAt(50, 90, "Courier");

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
    try doc.textAt(50, 50, "Normal");

    try doc.setFont(.helvetica_bold, 12);
    try doc.textAt(50, 70, "Bold");

    try doc.setFont(.helvetica_oblique, 12);
    try doc.textAt(50, 90, "Italic");

    try doc.setFont(.helvetica_bold_oblique, 12);
    try doc.textAt(50, 110, "BoldItalic");

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
    try doc.textAt(50, 50, "Page 1");

    try doc.addPage();
    try doc.textAt(50, 50, "Page 2");

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
        try doc.textAt(50, y, font.pdfName());
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
    _ = @import("writer.zig");
}
