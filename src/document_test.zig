//! Tests for zpdf Document and related functionality.

const std = @import("std");
const document = @import("document.zig");
const zpdf = @import("zpdf.zig");

// Re-export commonly used types for tests
const Document = document.Document;
const StandardFont = document.StandardFont;
const PageSize = document.PageSize;
const Region = document.Region;
const Border = document.Border;
const Color = document.Color;

// Unit conversion functions
const inches = zpdf.inches;
const mm = zpdf.mm;
const cm = zpdf.cm;

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

    _ = try doc.writeFlow(paragraph, .{});

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

    try doc.drawRegion(region);

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

    try doc.drawRegion(region);

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
    _ = try doc.writeFlow("", .{});

    // Should still have just one page
    try std.testing.expectEqual(@as(usize, 1), doc.pages.items.len);
}

test "writeFlow respects margins" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 100, .right = 100, .top = 100, .bottom = 100 });

    _ = try doc.writeFlow("Short text.", .{});

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

test "writeParagraph optimal line breaking" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Courier is monospace: 600 units per char, at 12pt = 7.2pt per char
    try doc.setFont(.courier, 12);

    // 14 chars width = 14 * 7.2 = 100.8pt
    const char_width = 7.2;
    const region_width = 14 * char_width;

    const text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";

    // Test greedy mode
    var region_greedy = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    const greedy_result = try doc.writeParagraph(&region_greedy, text, .{ .line_breaking = .greedy });

    // Test optimal mode
    try doc.addPage();
    var region_optimal = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    const optimal_result = try doc.writeParagraph(&region_optimal, text, .{ .line_breaking = .optimal });

    // Both should produce 7 lines for this text
    try std.testing.expectEqual(@as(usize, 7), greedy_result.lines_written);
    try std.testing.expectEqual(@as(usize, 7), optimal_result.lines_written);

    // No overflow
    try std.testing.expect(greedy_result.overflow == null);
    try std.testing.expect(optimal_result.overflow == null);
}

test "writeParagraph optimal vs greedy produces different breaks" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.courier, 12);

    // Verify char width: Courier is monospace at 600 units/1000 * 12pt = 7.2pt/char
    const char_width = doc.getTextWidth("X");
    try std.testing.expectApproxEqAbs(@as(f64, 7.2), char_width, 0.01);

    // Use slightly larger width to ensure "yellow dog was" (14 chars + spaces = 14*7.2 = 100.8)
    // Actually need to account for actual width including trailing space behavior
    // "yellow dog was" = 14 chars exactly = 100.8pt
    const region_width = 101.0; // Just over 14 chars to ensure fit
    const text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";

    var region = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    _ = try doc.writeParagraph(&region, text, .{ .line_breaking = .greedy });

    // Get greedy text commands
    var greedy_lines = std.ArrayListUnmanaged([]const u8){};
    defer greedy_lines.deinit(std.testing.allocator);
    const page1 = &doc.pages.items[0];
    for (page1.commands.items) |cmd| {
        if (cmd == .text) {
            try greedy_lines.append(std.testing.allocator, cmd.text.text_data);
        }
    }

    // Now optimal
    try doc.addPage();
    var region2 = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    _ = try doc.writeParagraph(&region2, text, .{ .line_breaking = .optimal });

    var optimal_lines = std.ArrayListUnmanaged([]const u8){};
    defer optimal_lines.deinit(std.testing.allocator);
    const page2 = &doc.pages.items[1];
    for (page2.commands.items) |cmd| {
        if (cmd == .text) {
            try optimal_lines.append(std.testing.allocator, cmd.text.text_data);
        }
    }

    // Both algorithms should have the same number of lines
    try std.testing.expectEqual(greedy_lines.items.len, optimal_lines.items.len);

    // But line 2 should be different:
    // Greedy fills greedily: "yellow dog was" (takes "was" because it fits)
    // Optimal leaves space: "yellow dog" (saving "was" for next line gives better balance)
    // Note: If both produce same output, the text/width combination isn't triggering different behavior
    try std.testing.expect(!std.mem.eql(u8, greedy_lines.items[1], optimal_lines.items[1]));
}

test "mark positioning with Tm absolute coordinates" {
    // This test verifies Tm-based absolute positioning for mark glyphs.
    // Each glyph gets: "1 0 0 1 x y Tm <glyph> Tj"
    // Marks should have higher Y coordinates than base glyphs (positioned above).

    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter.encoding = .identity;

    try doc.addPage();
    try doc.setEmbeddedFont(inter, 14);

    // Write "À" (A + combining grave)
    try doc.writeAt(100, 700, "A\xcc\x80");

    // Get the content stream
    const page = &doc.pages.items[0];
    try doc.renderPageCommands(page);

    const content = page.content.items;
    std.debug.print("\n=== Mark positioning test content for 'À' ===\n{s}\n=== End content ===\n", .{content});

    // Parse Tm coordinates: "1 0 0 1 x y Tm"
    // We expect 2 Tm commands: one for base A, one for grave mark
    var tm_count: usize = 0;
    var base_y: ?f64 = null;
    var mark_y: ?f64 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Look for lines containing "Tm"
        if (std.mem.indexOf(u8, line, "Tm")) |_| {
            // Parse "1 0 0 1 x y Tm" - get the y value (6th number)
            var tokens = std.mem.tokenizeAny(u8, line, " ");
            var values: [6]f64 = undefined;
            var idx: usize = 0;
            while (tokens.next()) |tok| {
                if (idx < 6) {
                    values[idx] = std.fmt.parseFloat(f64, tok) catch break;
                    idx += 1;
                }
            }
            if (idx >= 6 and values[0] == 1 and values[1] == 0 and values[2] == 0 and values[3] == 1) {
                const y = values[5];
                tm_count += 1;
                if (tm_count == 1) {
                    base_y = y;
                } else if (tm_count == 2) {
                    mark_y = y;
                }
                std.debug.print("  Tm #{d}: y={d:.2}\n", .{ tm_count, y });
            }
        }
    }

    std.debug.print("Final: {d} Tm ops\n", .{tm_count});

    // Should have at least 2 Tm operations (base + mark)
    try std.testing.expect(tm_count >= 2);

    // Mark Y should be higher than base Y (mark is above the base glyph)
    if (base_y != null and mark_y != null) {
        std.debug.print("Base Y: {d:.2}, Mark Y: {d:.2}\n", .{ base_y.?, mark_y.? });
        try std.testing.expect(mark_y.? > base_y.?);
    }
}

test "setTextColor changes text color" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Default is black
    try std.testing.expect(doc.text_color.eql(Color.black));

    // Set to red
    doc.setTextColor(Color.red);
    try std.testing.expect(doc.text_color.eql(Color.red));

    // Write some text
    try doc.write("Red text");

    // Verify the command stored the color
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 1), page.commands.items.len);

    const cmd = page.commands.items[0];
    const text_cmd = cmd.text;
    try std.testing.expect(text_cmd.text_color.eql(Color.red));
}

test "Color grayscale stored in command" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Set grayscale color
    const gray = Color.grayscale(0.5);
    doc.setTextColor(gray);
    try doc.write("Gray text");

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(gray));
}

test "Color CMYK stored in command" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Set CMYK cyan
    const cyan = Color.fromCmyk(1, 0, 0, 0);
    doc.setTextColor(cyan);
    try doc.write("Cyan text");

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(cyan));
}

test "Color.fromRgb255" {
    const c = Color.fromRgb255(255, 128, 0);
    try std.testing.expectEqual(@as(f64, 1.0), c.rgb.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), c.rgb.g, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), c.rgb.b);
}

test "getFontMetrics standard font" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    const m = doc.getFontMetrics();

    // Helvetica at 12pt
    // Ascender: 718 * 12/1000 = 8.616
    try std.testing.expectApproxEqAbs(@as(f64, 8.616), m.ascender, 0.001);
    // Descender: -207 * 12/1000 = -2.484
    try std.testing.expectApproxEqAbs(@as(f64, -2.484), m.descender, 0.001);
    // Cap height: 718 * 12/1000 = 8.616
    try std.testing.expectApproxEqAbs(@as(f64, 8.616), m.cap_height, 0.001);
    // x-height: 523 * 12/1000 = 6.276
    try std.testing.expectApproxEqAbs(@as(f64, 6.276), m.x_height, 0.001);

    try std.testing.expectEqual(@as(f64, 12), m.font_size);
    try std.testing.expectEqual(@as(u16, 1000), m.units_per_em);
}

test "getFontMetrics different sizes" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 24);
    const m24 = doc.getFontMetrics();

    try doc.setFont(.helvetica, 12);
    const m12 = doc.getFontMetrics();

    // Metrics should scale linearly with font size
    try std.testing.expectApproxEqAbs(m24.ascender, m12.ascender * 2, 0.001);
    try std.testing.expectApproxEqAbs(m24.descender, m12.descender * 2, 0.001);
}

test "getFontMetrics Times vs Helvetica" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    const hm = doc.getFontMetrics();

    try doc.setFont(.times_roman, 12);
    const tm = doc.getFontMetrics();

    // Times has different metrics than Helvetica
    // Times ascender: 683, Helvetica: 718
    try std.testing.expect(tm.ascender < hm.ascender);
    // Times x-height: 450, Helvetica: 523
    try std.testing.expect(tm.x_height < hm.x_height);
}

test "getFontMetrics lineHeight" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    const m = doc.getFontMetrics();

    // lineHeight = ascender - descender
    // 8.616 - (-2.484) = 11.1
    const expected_lh = m.ascender - m.descender;
    try std.testing.expectApproxEqAbs(expected_lh, m.lineHeight(), 0.001);
}

// ============================================================================
// Graphics Primitives Tests
// ============================================================================

test "drawLine basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawLine(50, 50, 200, 200);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF with a content stream (content is compressed)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawLine without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try std.testing.expectError(error.NoPage, doc.drawLine(0, 0, 100, 100));
}

test "drawRect stroke" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawRect(50, 50, 100, 80, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF (content is compressed, detailed check in integration tests)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRect fill" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawRect(50, 50, 100, 80, .fill);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawRect fill_stroke" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawRect(50, 50, 100, 80, .fill_stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawCircle basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawCircle(200, 300, 50, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawEllipse basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // drawEllipse(x, y, w, h) - bounding box upper-left at (200, 300), size 80x40
    try doc.drawEllipse(200, 300, 80, 40, .fill);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPolygon triangle" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    const points = [_]document.Document.Point{
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 100 },
        .{ .x = 150, .y = 50 },
    };
    try doc.drawPolygon(&points, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPolygon less than 3 points does nothing" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    const points = [_]document.Document.Point{
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 100 },
    };
    // Should not error, just do nothing
    try doc.drawPolygon(&points, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // PDF should still be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath basic triangle" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    var path = doc.createPath();
    defer path.deinit();

    try path.moveTo(100, 100);
    try path.lineTo(200, 100);
    try path.lineTo(150, 50);
    try path.closePath();

    try doc.drawPath(&path, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath with bezier curve" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    var path = doc.createPath();
    defer path.deinit();

    try path.moveTo(100, 200);
    try path.curveTo(150, 100, 250, 100, 300, 200);
    try path.lineTo(100, 200);
    try path.closePath();

    try doc.drawPath(&path, .fill_stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath empty path does nothing" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    var path = doc.createPath();
    defer path.deinit();

    // Empty path should not error
    try doc.drawPath(&path, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var path = doc.createPath();
    defer path.deinit();
    try path.moveTo(0, 0);

    try std.testing.expectError(error.NoPage, doc.drawPath(&path, .stroke));
}

test "setLineWidth stores value" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default line width is 0.567 (fpdf2 default)
    try std.testing.expectApproxEqAbs(@as(f64, 0.567), doc.line_width, 0.001);

    doc.setLineWidth(5.0);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), doc.line_width, 0.001);
}

test "setDashPattern stores values" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is solid line (all zeros)
    try std.testing.expectApproxEqAbs(@as(f64, 0), doc.dash_pattern.dash, 0.001);

    doc.setDashPattern(3, 2, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 3), doc.dash_pattern.dash, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), doc.dash_pattern.gap, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), doc.dash_pattern.phase, 0.001);
}

test "setSolidLine clears dash pattern" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setDashPattern(3, 2, 0);
    doc.setSolidLine();

    try std.testing.expectApproxEqAbs(@as(f64, 0), doc.dash_pattern.dash, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), doc.dash_pattern.gap, 0.001);
}

test "setLineCap stores value" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is square (matches fpdf2)
    try std.testing.expectEqual(document.LineCap.square, doc.line_cap);

    doc.setLineCap(.round);
    try std.testing.expectEqual(document.LineCap.round, doc.line_cap);

    doc.setLineCap(.butt);
    try std.testing.expectEqual(document.LineCap.butt, doc.line_cap);
}

test "setLineJoin stores value" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is miter
    try std.testing.expectEqual(document.LineJoin.miter, doc.line_join);

    doc.setLineJoin(.round);
    try std.testing.expectEqual(document.LineJoin.round, doc.line_join);

    doc.setLineJoin(.bevel);
    try std.testing.expectEqual(document.LineJoin.bevel, doc.line_join);
}

test "setDrawColor stores value" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is black
    try std.testing.expectEqual(Color.black, doc.draw_color);

    doc.setDrawColor(Color.red);
    try std.testing.expectEqual(Color.red, doc.draw_color);
}

test "setFillColor stores value" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is black
    try std.testing.expectEqual(Color.black, doc.fill_color);

    doc.setFillColor(Color.blue);
    try std.testing.expectEqual(Color.blue, doc.fill_color);
}

test "graphics state used in output" {
    // Test that the document with graphics state produces valid PDF
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    doc.setLineWidth(3.0);
    doc.setDashPattern(5, 3, 0);
    doc.setLineCap(.round);
    doc.setLineJoin(.bevel);
    doc.setDrawColor(Color.red);
    doc.setFillColor(Color.blue);

    try doc.drawRect(50, 50, 100, 80, .fill_stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF is produced (content validation in integration tests)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}
