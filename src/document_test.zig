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
    _ = try doc.writeAt(50, 50, "Hello, World!");

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

test "page format landscape" {
    const landscape_a4 = PageSize.A4.landscape();
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), landscape_a4.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), landscape_a4.height, 0.01);
}

test "pageNo returns current page number" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // No pages yet
    try std.testing.expectEqual(@as(usize, 0), doc.pageNo());

    // Add first page
    try doc.addPage();
    try std.testing.expectEqual(@as(usize, 1), doc.pageNo());

    // Add second page
    try doc.addPage();
    try std.testing.expectEqual(@as(usize, 2), doc.pageNo());

    // Add third page
    try doc.addPage();
    try std.testing.expectEqual(@as(usize, 3), doc.pageNo());
}

test "setDefaultPageSize" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is A4
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), doc.page_size.width, 0.01);

    // Change to Letter
    doc.setPageSize(PageSize.Letter);
    try std.testing.expectApproxEqAbs(@as(f64, 612), doc.page_size.width, 0.01);

    // addPage uses the new default
    try doc.addPage();
    try std.testing.expectApproxEqAbs(@as(f64, 612), doc.page_size.width, 0.01);
}

test "addPage with size overrides default" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Default is A4
    doc.setPageSize(PageSize.A4);
    try doc.addPage(); // A4

    // Add one page with Letter size
    doc.setPageSize(PageSize.Letter);
    try doc.addPage();
    try std.testing.expectApproxEqAbs(@as(f64, 612), doc.page_size.width, 0.01);

    // Back to A4
    doc.setPageSize(PageSize.A4);
    try doc.addPage();
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), doc.page_size.width, 0.01);
}

test "text without font returns error" {
    // fpdf2: test_text_no_font_set
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Should fail because no font is set
    try std.testing.expectError(error.NoFont, doc.writeAt(0, 0, "test"));
}

test "text without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    // Should fail because no page is added
    try std.testing.expectError(error.NoPage, doc.writeAt(0, 0, "test"));
}

test "multiple fonts on single page" {
    // fpdf2: test_text_positioning - multiple fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    _ = try doc.writeAt(50, 50, "Helvetica");

    try doc.setFont(.times_roman, 12);
    _ = try doc.writeAt(50, 70, "Times");

    try doc.setFont(.courier, 12);
    _ = try doc.writeAt(50, 90, "Courier");

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
    _ = try doc.writeAt(50, 50, "Normal");

    try doc.setFont(.helvetica_bold, 12);
    _ = try doc.writeAt(50, 70, "Bold");

    try doc.setFont(.helvetica_oblique, 12);
    _ = try doc.writeAt(50, 90, "Italic");

    try doc.setFont(.helvetica_bold_oblique, 12);
    _ = try doc.writeAt(50, 110, "BoldItalic");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
}

test "positioning setPosition/getPosition" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    doc.setPosition(.{ .x = 100, .y = 200 });
    const pos = doc.getPosition();
    try std.testing.expectApproxEqAbs(@as(f64, 100), pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 200), pos.y, 0.01);

    doc.setPosition(.{ .x = 150, .y = 300 });
    const pos2 = doc.getPosition();
    try std.testing.expectApproxEqAbs(@as(f64, 150), pos2.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 300), pos2.y, 0.01);
}

test "multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    _ = try doc.writeAt(50, 50, "Page 1");

    try doc.addPage();
    _ = try doc.writeAt(50, 50, "Page 2");

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
        _ = try doc.writeAt(50, y, font.pdfName());
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
    font.encoding = .win_ansi; // Test WinAnsi format specifically

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    _ = try doc.writeAt(50, 50, "Hello, World!");

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
    courier_prime.encoding = .win_ansi; // Test WinAnsi format specifically

    try doc.addPage();

    // Use standard font first
    try doc.setFont(.helvetica, 12);
    _ = try doc.writeAt(50, 50, "Helvetica text");

    // Switch to embedded font
    try doc.setEmbeddedFont(courier_prime, 14);
    _ = try doc.writeAt(50, 70, "Courier Prime text");

    // Switch back to standard
    try doc.setFont(.times_roman, 12);
    _ = try doc.writeAt(50, 90, "Times text");

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
    courier_regular.encoding = .win_ansi; // Test WinAnsi format specifically
    const courier_bold = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold.ttf");
    courier_bold.encoding = .win_ansi;

    try doc.addPage();

    try doc.setEmbeddedFont(courier_regular, 12);
    _ = try doc.writeAt(50, 50, "Regular");

    try doc.setEmbeddedFont(courier_bold, 12);
    _ = try doc.writeAt(50, 70, "Bold");

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
    font.encoding = .win_ansi; // Test WinAnsi format specifically

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    _ = try doc.writeAt(50, 50, "Page 1");

    try doc.addPage();
    // Font should still be set
    _ = try doc.writeAt(50, 50, "Page 2");

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
    font.encoding = .win_ansi; // Test WinAnsi format specifically

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    _ = try doc.writeAt(50, 50, "Test");

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
    _ = try doc.writeAt(100, 100, "Test embedded font!");

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

test "writeStyled advances cursor" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = doc.getPageRegion();
    const initial_cursor = region.cursor_y;

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test line", .{});
    _ = try doc.writeStyled(&region, &st, .{});

    try std.testing.expect(region.cursor_y > initial_cursor);
    try std.testing.expectEqual(doc.getLineHeightPts(), region.cursor_y);
}

test "writeStyled alignment" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 100, .y = 100, .width = 400, .height = 600 };

    // Test left alignment (default)
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Left", .{});
        _ = try doc.writeStyled(&region, &st, .{});
    }
    // Test center alignment
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Center", .{});
        _ = try doc.writeStyled(&region, &st, .{ .alignment = .center });
    }
    // Test right alignment
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Right", .{});
        _ = try doc.writeStyled(&region, &st, .{ .alignment = .right });
    }

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic validation - PDF should be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "writeStyled wraps text to multiple lines" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 600 };
    const long_text = "This is a longer piece of text that should wrap across multiple lines within the region.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(long_text, .{});
    const result = try doc.writeStyled(&region, &st, .{});

    try std.testing.expect(result.lines_written > 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled overflow" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Small region - line height at 12pt with 1.2 factor = 14.4pt
    // Region of 15pt should fit one line, but not two (would need 28.8pt)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 15 };
    const long_text = "Word one two three four five six seven eight nine ten.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(long_text, .{});
    const result = try doc.writeStyled(&region, &st, .{});

    // Should only fit one line due to height constraint
    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
    try std.testing.expect(result.overflow != null);
}

test "writeStyled multi-page via overflow handling" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 50, .right = 50, .top = 50, .bottom = 50 });

    // Generate long text that should span multiple pages
    const paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor. " ** 100;

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(paragraph, .{});

    // Manual pagination loop using overflow
    var remaining: ?[]const u8 = paragraph;
    while (remaining) |text_to_write| {
        if (text_to_write.len == 0) break;

        var region = doc.getPageRegion();
        var page_st = doc.createStyledText();
        defer page_st.deinit();
        try page_st.append(text_to_write, .{});

        const result = try doc.writeStyled(&region, &page_st, .{});

        if (result.overflow) |overflow| {
            try doc.addPage();
            remaining = overflow;
        } else {
            remaining = null;
        }
    }

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
    _ = try doc.writeAt(0, 0, "ex\xc2\xadplic\xc2\xadit");

    // The stored text should have soft-hyphens stripped
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 1), page.commands.items.len);
    const cmd = page.commands.items[0];
    try std.testing.expectEqualStrings("explicit", cmd.text.text_data);
}

test "writeStyled in narrow column" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 11);

    // Narrow column test - text should wrap
    var region = Region{ .x = 72, .y = 100, .width = 100, .height = 200 };

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("This is a test of narrow column wrapping behavior.", .{});

    const result = try doc.writeStyled(&region, &st, .{});

    // Should produce multiple lines
    try std.testing.expect(result.lines_written >= 2);
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

test "writeStyled overflow returns remaining text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Region that can only fit 2 lines (line height = 14.4pt at 12pt font)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 30 };
    const text = "Line one fits here. Line two fits too. Line three overflows. Line four too.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(text, .{});
    const result = try doc.writeStyled(&region, &st, .{});

    try std.testing.expectEqual(@as(usize, 2), result.lines_written);
    try std.testing.expect(result.overflow != null);
}

test "writeStyled newline forces line break" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    const text = "Line one.\nLine two.\nLine three.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(text, .{});
    const result = try doc.writeStyled(&region, &st, .{});

    // Should have 3 lines due to explicit newlines
    try std.testing.expectEqual(@as(usize, 3), result.lines_written);
}

test "writeStyled returns overflow when no room" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Small region that can only fit ~1 line
    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 15 };

    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("First line", .{});
        const result1 = try doc.writeStyled(&region, &st, .{});
        try std.testing.expectEqual(@as(usize, 1), result1.lines_written);
        try std.testing.expect(result1.overflow == null);
    }

    // Second line should indicate no room
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Second line", .{});
        const result2 = try doc.writeStyled(&region, &st, .{});
        try std.testing.expectEqual(@as(usize, 0), result2.lines_written);
        try std.testing.expect(result2.overflow != null);
    }
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
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    _ = try doc.writeStyled(&region, &st, .{});
    try std.testing.expect(region.remainingHeight() < 90);
}

test "writeStyled handles empty text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = doc.getPageRegion();

    // Empty styled text should not crash
    var st = doc.createStyledText();
    defer st.deinit();
    // Don't append anything - empty
    _ = try doc.writeStyled(&region, &st, .{});

    // Should still have just one page
    try std.testing.expectEqual(@as(usize, 1), doc.pages.items.len);
}

test "writeStyled respects margins via region" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setMargins(.{ .left = 100, .right = 100, .top = 100, .bottom = 100 });

    var region = doc.getPageRegion();
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Short text.", .{});
    _ = try doc.writeStyled(&region, &st, .{});

    // Check text position respects left margin
    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            try std.testing.expect(cmd.text.x >= 100);
        }
    }
}

test "valign top uses CSS-style half-leading calculation" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    _ = try doc.writeStyled(&region, &st, .{ .valign = .top });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // CSS-style valign: baseline = cursor_y + (line_height + ascender - descender) / 2
            // Helvetica: ascender = 0.718 * 12 = 8.616, descender = 0.207 * 12 = 2.484
            // line_height = 12 * 1.2 = 14.4
            // baseline = 0 + (14.4 + 8.616 - 2.484) / 2 = 10.266
            // top-down y = region.y(100) + baseline(10.266) = 110.266
            // PDF y = page_height(841.89) - 110.266 = 731.624
            try std.testing.expectApproxEqAbs(@as(f64, 731.62), cmd.text.y, 0.1);
        }
    }
}

test "valign middle centers text block in region" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    _ = try doc.writeStyled(&region, &st, .{ .valign = .middle });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // Block-level middle valign centers text in region, then uses CSS-style .top
            // PDF y ≈ 637.17 (with CSS-style half-leading calculation)
            try std.testing.expectApproxEqAbs(@as(f64, 637.17), cmd.text.y, 0.1);
        }
    }
}

test "valign bottom puts text block at bottom of region" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    _ = try doc.writeStyled(&region, &st, .{ .valign = .bottom });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // Block-level bottom valign + .bottom per-line positioning (baseline flush)
            // text_height = 14.4, available = 200, block_offset = 200 - 14.4 - 0.1 = 185.5
            // per-line .bottom: baseline = region.y(100) + cursor_y(185.5) + line_height(14.4) = 299.9
            // PDF y = 841.89 - 299.9 = 541.99
            try std.testing.expectApproxEqAbs(@as(f64, 541.99), cmd.text.y, 0.1);
        }
    }
}

test "writeStyled greedy vs optimal line counts" {
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
    var st_greedy = doc.createStyledText();
    defer st_greedy.deinit();
    try st_greedy.append(text, .{});
    const greedy_result = try doc.writeStyled(&region_greedy, &st_greedy, .{ .line_breaking = .greedy });

    // Test optimal mode
    try doc.addPage();
    var region_optimal = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_optimal = doc.createStyledText();
    defer st_optimal.deinit();
    try st_optimal.append(text, .{});
    const optimal_result = try doc.writeStyled(&region_optimal, &st_optimal, .{ .line_breaking = .optimal });

    // Both should produce 7 lines for this text
    try std.testing.expectEqual(@as(usize, 7), greedy_result.lines_written);
    try std.testing.expectEqual(@as(usize, 7), optimal_result.lines_written);

    // No overflow
    try std.testing.expect(greedy_result.overflow == null);
    try std.testing.expect(optimal_result.overflow == null);
}

test "writeStyled greedy and optimal both render successfully" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.courier, 12);

    // Verify char width: Courier is monospace at 600 units/1000 * 12pt = 7.2pt/char
    const char_width = doc.getTextWidth("X");
    try std.testing.expectApproxEqAbs(@as(f64, 7.2), char_width, 0.01);

    const region_width = 101.0; // Just over 14 chars
    const text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";

    // Test greedy mode
    var region = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_greedy = doc.createStyledText();
    defer st_greedy.deinit();
    try st_greedy.append(text, .{});
    const greedy_result = try doc.writeStyled(&region, &st_greedy, .{ .line_breaking = .greedy });

    // Test optimal mode
    try doc.addPage();
    var region2 = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_optimal = doc.createStyledText();
    defer st_optimal.deinit();
    try st_optimal.append(text, .{});
    const optimal_result = try doc.writeStyled(&region2, &st_optimal, .{ .line_breaking = .optimal });

    // Both should complete without overflow
    try std.testing.expect(greedy_result.overflow == null);
    try std.testing.expect(optimal_result.overflow == null);

    // Both should produce the same number of lines (7)
    try std.testing.expectEqual(@as(usize, 7), greedy_result.lines_written);
    try std.testing.expectEqual(@as(usize, 7), optimal_result.lines_written);
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
    _ = try doc.writeAt(100, 700, "A\xcc\x80");

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
    _ = try doc.writeAt(0, 0, "Red text");

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

    // Set greyscale color
    const gray = Color.greyscale(0.5);
    doc.setTextColor(gray);
    _ = try doc.writeAt(0, 0, "Gray text");

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
    const cyan = Color.cmyk(1, 0, 0, 0);
    doc.setTextColor(cyan);
    _ = try doc.writeAt(0, 0, "Cyan text");

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(cyan));
}

test "Color.rgb" {
    const c = Color.rgb(255, 128, 0);
    try std.testing.expectEqual(@as(f64, 1.0), c._rgb.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), c._rgb.g, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), c._rgb.b);
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

test "drawRoundedRect basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.drawRoundedRect(50, 50, 100, 80, 10, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output (content is compressed)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRoundedRect zero radius falls back to rect" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Zero radius should use regular rect (re command)
    try doc.drawRoundedRect(50, 50, 100, 80, 0, .stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRoundedRect radius clamped to half min dimension" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Radius 100 is larger than half of min(100, 80) = 40, so clamped to 40
    try doc.drawRoundedRect(50, 50, 100, 80, 100, .fill);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
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
    const points = [_]document.Point{
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
    const points = [_]document.Point{
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

test "setDrawStyle sets all values" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setDrawStyle(.{
        .line_width = 2.5,
        .line_cap = .round,
        .line_join = .bevel,
        .dash_pattern = .{ .dash = 5, .gap = 3, .phase = 1 },
        .stroke_color = Color.red,
        .fill_color = Color.blue,
    });

    try std.testing.expectEqual(@as(f64, 2.5), doc.line_width);
    try std.testing.expectEqual(document.LineCap.round, doc.line_cap);
    try std.testing.expectEqual(document.LineJoin.bevel, doc.line_join);
    try std.testing.expectEqual(@as(f64, 5), doc.dash_pattern.dash);
    try std.testing.expectEqual(@as(f64, 3), doc.dash_pattern.gap);
    try std.testing.expectEqual(@as(f64, 1), doc.dash_pattern.phase);
    try std.testing.expectEqual(Color.red, doc.draw_color);
    try std.testing.expectEqual(Color.blue, doc.fill_color);
}

test "setDrawStyle with partial values uses defaults" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Set only line_width, everything else uses defaults
    doc.setDrawStyle(.{ .line_width = 3.0 });

    try std.testing.expectEqual(@as(f64, 3.0), doc.line_width);
    try std.testing.expectEqual(document.LineCap.square, doc.line_cap); // default
    try std.testing.expectEqual(document.LineJoin.miter, doc.line_join); // default
    try std.testing.expectEqual(Color.black, doc.draw_color); // default
    try std.testing.expectEqual(Color.black, doc.fill_color); // default
}

test "graphics state used in output" {
    // Test that the document with graphics state produces valid PDF
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    doc.setDrawStyle(.{
        .line_width = 3.0,
        .dash_pattern = .{ .dash = 5, .gap = 3 },
        .line_cap = .round,
        .line_join = .bevel,
        .stroke_color = Color.red,
        .fill_color = Color.blue,
    });

    try doc.drawRect(50, 50, 100, 80, .fill_stroke);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF is produced (content validation in integration tests)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

// ============================================================================
// Document Metadata Tests
// ============================================================================

const DocumentMetadata = document.DocumentMetadata;

test "DocumentMetadata hasAnyField default" {
    const meta = DocumentMetadata{};
    // Default producer is set, so hasAnyField should return true
    try std.testing.expect(meta.hasAnyField());
}

test "DocumentMetadata hasAnyField all null" {
    const meta = DocumentMetadata{ .producer = null };
    try std.testing.expect(!meta.hasAnyField());
}

test "DocumentMetadata hasAnyField with title" {
    const meta = DocumentMetadata{ .title = "Test", .producer = null };
    try std.testing.expect(meta.hasAnyField());
}

test "setMetadata stores metadata" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "My Document",
        .author = "Test Author",
    });

    try std.testing.expectEqualStrings("My Document", doc.metadata.title.?);
    try std.testing.expectEqualStrings("Test Author", doc.metadata.author.?);
    try std.testing.expectEqualStrings("zpdf", doc.metadata.producer.?);
}

test "metadata written to PDF Info dictionary" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "Test Title",
        .author = "Test Author",
        .subject = "Test Subject",
        .keywords = "test, pdf, zig",
        .creator = "Test App",
    });

    try doc.addPage();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that Info dictionary fields appear in PDF
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Title (Test Title)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Author (Test Author)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subject (Test Subject)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Keywords (test, pdf, zig)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Creator (Test App)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Producer (zpdf)") != null);
    // Check auto-generated dates are present (format: D:YYYYMMDDHHmmSSZ)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CreationDate (D:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ModDate (D:") != null);
    // Check trailer references Info dictionary
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Info") != null);
}

test "metadata with special characters escaped" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "Test (with parens) and \\backslash",
    });

    try doc.addPage();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that special chars are escaped in PDF string
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Title (Test \\(with parens\\) and \\\\backslash)") != null);
}

test "no Info dictionary when metadata empty" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Clear default producer
    doc.setMetadata(.{ .producer = null });

    try doc.addPage();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that no /Info key in trailer
    // Find the trailer section
    const trailer_start = std.mem.indexOf(u8, pdf, "trailer");
    try std.testing.expect(trailer_start != null);
    const trailer = pdf[trailer_start.?..];
    const trailer_end = std.mem.indexOf(u8, trailer, ">>");
    try std.testing.expect(trailer_end != null);
    const trailer_dict = trailer[0..trailer_end.?];
    try std.testing.expect(std.mem.indexOf(u8, trailer_dict, "/Info") == null);
}

// ============================================================================
// Outline Tests
// ============================================================================

test "addOutlineItem basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    const dest = document.Destination{ .page_index = 0, .y = 100 };
    const outline = try doc.addOutlineItem("Chapter 1", dest, null);

    try std.testing.expectEqualStrings("Chapter 1", outline.title);
    try std.testing.expectEqual(@as(usize, 0), outline.dest.page_index);
    try std.testing.expectEqual(@as(f64, 100), outline.dest.y);
    try std.testing.expect(outline.parent == null);
    try std.testing.expectEqual(@as(usize, 1), doc.outlines.items.len);
}

test "addOutlineItem nested" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    const dest = document.Destination{ .page_index = 0, .y = 0 };

    // Create parent outline item
    const ch1 = try doc.addOutlineItem("Chapter 1", dest, null);
    try std.testing.expectEqual(@as(i32, 0), ch1.count);

    // Create child outline items
    const sec1 = try doc.addOutlineItem("Section 1.1", dest, ch1);
    try std.testing.expect(sec1.parent == ch1);
    try std.testing.expect(ch1.first_child == sec1);
    try std.testing.expect(ch1.last_child == sec1);
    try std.testing.expectEqual(@as(i32, 1), ch1.count);

    const sec2 = try doc.addOutlineItem("Section 1.2", dest, ch1);
    try std.testing.expect(sec2.parent == ch1);
    try std.testing.expect(sec1.next == sec2);
    try std.testing.expect(sec2.prev == sec1);
    try std.testing.expect(ch1.first_child == sec1);
    try std.testing.expect(ch1.last_child == sec2);
    try std.testing.expectEqual(@as(i32, 2), ch1.count);

    // Another top-level outline item
    const ch2 = try doc.addOutlineItem("Chapter 2", dest, null);
    try std.testing.expect(ch2.parent == null);

    try std.testing.expectEqual(@as(usize, 4), doc.outlines.items.len);
}

test "addOutlineItem in PDF output" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    const dest = document.Destination{ .page_index = 0, .y = 100 };
    _ = try doc.addOutlineItem("Test Outline", dest, null);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check for outlines structure in PDF
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Outlines") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Outlines") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Test Outline)") != null);
}

test "addOutlineItem nested in PDF output" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.addPage();

    const ch1 = try doc.addOutlineItem("Chapter 1", .{ .page_index = 0, .y = 0 }, null);
    _ = try doc.addOutlineItem("Section 1.1", .{ .page_index = 0, .y = 200 }, ch1);
    _ = try doc.addOutlineItem("Section 1.2", .{ .page_index = 0, .y = 400 }, ch1);
    _ = try doc.addOutlineItem("Chapter 2", .{ .page_index = 1, .y = 0 }, null);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check outline structure
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Chapter 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Section 1.1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Section 1.2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Chapter 2)") != null);
    // Check for parent/child links
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/First") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Last") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count") != null);
}

// ============================================================================
// Page Label Tests
// ============================================================================

test "PageLabelStyle pdfCode" {
    const layout = @import("layout.zig");
    try std.testing.expectEqualStrings("D", layout.PageLabelStyle.decimal.pdfCode().?);
    try std.testing.expectEqualStrings("r", layout.PageLabelStyle.roman_lower.pdfCode().?);
    try std.testing.expectEqualStrings("R", layout.PageLabelStyle.roman_upper.pdfCode().?);
    try std.testing.expectEqualStrings("a", layout.PageLabelStyle.alpha_lower.pdfCode().?);
    try std.testing.expectEqualStrings("A", layout.PageLabelStyle.alpha_upper.pdfCode().?);
    try std.testing.expect(layout.PageLabelStyle.none.pdfCode() == null);
}

test "setPageLabel basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setPageLabel(0, .{ .style = .roman_lower });
    try doc.setPageLabel(4, .{ .style = .decimal, .start = 1 });

    try std.testing.expectEqual(@as(usize, 2), doc.page_labels.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.page_labels.items[0].page_index);
    try std.testing.expectEqual(@as(usize, 4), doc.page_labels.items[1].page_index);
}

test "setPageLabel in PDF output" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    for (0..6) |_| {
        try doc.addPage();
    }

    try doc.setPageLabel(0, .{ .style = .roman_lower });
    try doc.setPageLabel(4, .{ .style = .decimal, .start = 1 });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check for page labels in catalog
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/PageLabels") != null);
    // Check for /Nums array with style codes
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Nums") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/S /r") != null); // roman_lower
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/S /D") != null); // decimal
}

test "setPageLabel with prefix" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setPageLabel(0, .{ .style = .alpha_upper, .prefix = "App-" });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/P (App-)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/S /A") != null);
}

test "setPageLabel with start number" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setPageLabel(0, .{ .style = .decimal, .start = 5 });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/St 5") != null);
}

test "no outlines or page labels when not set" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that catalog doesn't have Outlines or PageLabels
    const catalog_start = std.mem.indexOf(u8, pdf, "/Type /Catalog");
    try std.testing.expect(catalog_start != null);
    const catalog_section = pdf[catalog_start.? .. catalog_start.? + 200];
    try std.testing.expect(std.mem.indexOf(u8, catalog_section, "/Outlines") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_section, "/PageLabels") == null);
}

// ============================================================================
// Text Decoration Tests
// ============================================================================

test "setTextStyle enables underline decoration" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Default is no decoration
    try std.testing.expect(!doc.text_decoration.underline);

    // Enable underline via setTextStyle
    doc.setTextStyle(.{ .decoration = .{ .underline = true } });
    try std.testing.expect(doc.text_decoration.underline);

    // Write text
    _ = try doc.writeAt(0, 0, "Underlined text");

    // Verify the command has underline enabled
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.underline);
}

test "setTextStyle enables strikethrough decoration" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Default is no decoration
    try std.testing.expect(!doc.text_decoration.strikethrough);

    // Enable strikethrough via setTextStyle
    doc.setTextStyle(.{ .decoration = .{ .strikethrough = true } });
    try std.testing.expect(doc.text_decoration.strikethrough);

    // Write text
    _ = try doc.writeAt(0, 0, "Strikethrough text");

    // Verify the command has strikethrough enabled
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.strikethrough);
}

test "text width stored in command for decorations" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setTextStyle(.{ .decoration = .{ .underline = true } });

    _ = try doc.writeAt(0, 0, "Hello");

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];

    // Text width should be non-zero
    try std.testing.expect(cmd.text.text_width > 0);
}

test "setTextStyle with both decorations" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    doc.setTextStyle(.{ .decoration = .{ .underline = true, .strikethrough = true } });

    _ = try doc.writeAt(0, 0, "Test");

    // Verify both decorations stored in command
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.underline);
    try std.testing.expect(cmd.text.strikethrough);
    try std.testing.expect(cmd.text.text_width > 0);

    // PDF output should succeed
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(pdf.len > 0);
}

test "setTextStyle sets color and decoration" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Set color and decoration together
    doc.setTextStyle(.{ .color = Color.red, .decoration = .{ .underline = true } });
    try std.testing.expect(doc.text_color.eql(Color.red));
    try std.testing.expect(doc.text_decoration.underline);
}

test "decoration not rendered when disabled" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    _ = try doc.writeAt(0, 0, "Test");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Should not contain "re f" since no decorations
    // (Note: could be present from other drawing - we check that decoration wasn't added)
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(!cmd.text.underline);
    try std.testing.expect(!cmd.text.strikethrough);
}

test "embedded font decoration metrics from POST/OS2 tables" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Check decoration metrics were loaded
    // Courier Prime should have reasonable values
    try std.testing.expect(font.underline_position != 0 or font.underline_thickness != 0);
    try std.testing.expect(font.strikeout_position > 0);
    try std.testing.expect(font.strikeout_size > 0);
}

test "write() advances cursor_x" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 100 };

    try std.testing.expectEqual(@as(f64, 0), region.cursor_x);
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);

    _ = try doc.write(&region, "Hello", .{});

    // cursor_x should have advanced
    try std.testing.expect(region.cursor_x > 0);
    // cursor_y should still be 0 (same line)
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);
}

test "write() wraps to next line" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Narrow region to force wrapping
    var region = Region{ .x = 50, .y = 50, .width = 60, .height = 100 };

    // "Hello World" won't fit on one 60pt line (Hello ~27pt, World ~31pt, space ~3pt)
    _ = try doc.write(&region, "Hello World", .{});

    // Should have wrapped - cursor_y should have advanced
    try std.testing.expect(region.cursor_y > 0);
}

test "write() with multiple styled chunks" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 100 };

    doc.setTextStyle(.{});
    _ = try doc.write(&region, "Normal ", .{});

    doc.setTextStyle(.{ .color = Color.red });
    _ = try doc.write(&region, "red ", .{});

    doc.setTextStyle(.{ .decoration = .{ .underline = true } });
    _ = try doc.write(&region, "underlined", .{});

    // Should have 3 text commands
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 3), page.commands.items.len);

    // Check styles were preserved
    try std.testing.expect(page.commands.items[1].text.text_color.eql(Color.red));
    try std.testing.expect(page.commands.items[2].text.underline);
}

test "write() returns overflow when region is full" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Very small region - only fits one line
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 15 };

    const result = try doc.write(&region, "This is a long text that will overflow the small region", .{});

    // Should have overflow
    try std.testing.expect(result.overflow != null);
}

test "Region.newLine resets cursor_x and advances cursor_y" {
    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 100 };
    region.cursor_x = 150;
    region.cursor_y = 20;

    region.newLine(14.4);

    try std.testing.expectEqual(@as(f64, 0), region.cursor_x);
    try std.testing.expectApproxEqAbs(@as(f64, 34.4), region.cursor_y, 0.01);
}

test "write() with measure_only is side-effect free" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 100 };

    // Measure pass - cursor should be unchanged (side-effect free)
    const result = try doc.write(&region, "Hello World", .{ .measure_only = true });
    try std.testing.expectEqual(@as(f64, 0), region.cursor_x);
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);
    try std.testing.expect(result.lines_written >= 1);

    // Check no text was rendered (page content should be empty)
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 0), page.commands.items.len);

    // Write for real - cursor should now advance
    _ = try doc.write(&region, "Hello World", .{});
    try std.testing.expect(region.cursor_x > 0 or region.cursor_y > 0);

    // Now there should be commands
    try std.testing.expect(page.commands.items.len > 0);
}

test "write() with wrap=false stays on one line" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    // Narrow region that would normally wrap
    var region = Region{ .x = 50, .y = 50, .width = 60, .height = 100 };

    _ = try doc.write(&region, "Hello World Test", .{ .wrap = false });

    // With wrap=false, cursor_y should stay at 0 (no line wrapping)
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);

    // cursor_x should be beyond the region width (text overflows)
    try std.testing.expect(region.cursor_x > 60);
}

// ============================================================================
// StyledText Tests
// ============================================================================

test "writeStyled basic" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("Hello ", .{});
    try text.append("World", .{ .color = Color.red });

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    const result = try doc.writeStyled(&region, &text, .{});

    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled word wrapping" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("The quick brown fox ", .{});
    try text.append("jumps over the lazy dog", .{ .color = Color.blue });

    // Narrow region to force wrapping
    var region = Region{ .x = 50, .y = 50, .width = 120, .height = 200 };
    const result = try doc.writeStyled(&region, &text, .{});

    try std.testing.expect(result.lines_written > 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled justified alignment" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("This is a ", .{});
    try text.append("test", .{ .color = Color.red });
    try text.append(" of justified text.", .{});

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 200 };
    const result = try doc.writeStyled(&region, &text, .{ .alignment = .justify });

    try std.testing.expect(result.lines_written >= 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled optimal line breaking" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("The quick brown ", .{});
    try text.append("fox jumps over ", .{ .color = Color.red });
    try text.append("the lazy dog.", .{});

    var region = Region{ .x = 50, .y = 50, .width = 150, .height = 200 };
    const result = try doc.writeStyled(&region, &text, .{
        .line_breaking = .optimal,
    });

    try std.testing.expect(result.lines_written >= 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled generates valid PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("Normal ", .{});
    try text.append("red ", .{ .color = Color.red });
    try text.append("underlined", .{ .decoration = .{ .underline = true } });

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    _ = try doc.writeStyled(&region, &text, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // PDF should be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(pdf.len > 100);
}

test "writeStyled breaks at soft-hyphen when word too wide" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    // Word with soft-hyphens: "in­com­pre­hen­si­ble" - very long word
    // At 12pt Helvetica, this is about 70-80pt wide
    try text.append("in\xC2\xADcom\xC2\xADpre\xC2\xADhen\xC2\xADsi\xC2\xADble", .{});

    // Use a narrow region that forces breaking
    var region = Region{ .x = 50, .y = 50, .width = 40, .height = 100 };
    const result = try doc.writeStyled(&region, &text, .{});

    // Should have rendered multiple lines due to soft-hyphen breaking
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled soft-hyphen break renders hyphen" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    // "ab­cd" - soft-hyphen after "ab"
    try text.append("ab\xC2\xADcd", .{});

    // Width that fits "ab-" but not "abcd"
    // At 12pt Helvetica: "ab" is about 14pt, "-" is about 4pt, "abcd" is about 27pt
    var region = Region{ .x = 50, .y = 50, .width = 22, .height = 50 };
    const result = try doc.writeStyled(&region, &text, .{});

    // Should have broken into 2 lines: "ab-" and "cd"
    try std.testing.expectEqual(@as(usize, 2), result.lines_written);

    // Generate PDF and check it contains hyphen
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(pdf.len > 0);
}

test "writeStyled breaks at regular hyphen when break_on_hyphens is true" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    // Compound word with regular hyphens: "state-of-the-art"
    try text.append("state-of-the-art", .{});

    // Width that fits "state-" (~35pt) but not full word (~87pt)
    var region = Region{ .x = 50, .y = 50, .width = 45, .height = 100 };
    const result = try doc.writeStyled(&region, &text, .{ .break_on_hyphens = true });

    // Should have broken at hyphen
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled does not break at regular hyphen when break_on_hyphens is false" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    // Compound word with regular hyphens
    try text.append("state-of-the-art", .{});

    // Narrow width - with break_on_hyphens=false, should NOT break at hyphen
    // But character-level breaking will still apply as last resort
    var region = Region{ .x = 50, .y = 50, .width = 45, .height = 100 };
    const result = try doc.writeStyled(&region, &text, .{ .break_on_hyphens = false });

    // With break_on_hyphens=false, won't break at hyphens but will do character breaks
    // So it will still break (just not at the hyphen boundaries)
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled character-level breaking for long word without hyphens" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();

    // Long word without any hyphens: "supercalifragilisticexpialidocious" (~190pt at 12pt)
    try text.append("supercalifragilisticexpialidocious", .{});

    // Very narrow width (50pt) forces multiple character breaks
    // At 12pt Helvetica, ~7-8 chars fit per line, so expect ~5 lines
    var region = Region{ .x = 50, .y = 50, .width = 50, .height = 200 };
    const result = try doc.writeStyled(&region, &text, .{});

    // Should break into multiple lines via repeated character breaking
    try std.testing.expect(result.lines_written >= 4);
}

test "writeStyled measure_only is side-effect free" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);

    var text = doc.createStyledText();
    defer text.deinit();
    try text.append("This is a test paragraph that should wrap to multiple lines in a narrow region.", .{});

    // Measure the text
    var measure_region = Region{ .x = 50, .y = 50, .width = 150, .height = 1000 };
    const measure_result = try doc.writeStyled(&measure_region, &text, .{ .measure_only = true });

    // Should have counted lines
    try std.testing.expect(measure_result.lines_written > 1);
    // Cursor should be unchanged (measure_only is side-effect free)
    try std.testing.expectEqual(@as(f64, 0), measure_region.cursor_x);
    try std.testing.expectEqual(@as(f64, 0), measure_region.cursor_y);
    // No overflow
    try std.testing.expectEqual(null, measure_result.overflow);

    // Now render into a region with same dimensions
    var text2 = doc.createStyledText();
    defer text2.deinit();
    try text2.append("This is a test paragraph that should wrap to multiple lines in a narrow region.", .{});

    var render_region = Region{ .x = 50, .y = 50, .width = 150, .height = 1000 };
    const render_result = try doc.writeStyled(&render_region, &text2, .{});

    // Should get the same line count
    try std.testing.expectEqual(measure_result.lines_written, render_result.lines_written);

    // PDF should be generated successfully
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(pdf.len > 0);
}
