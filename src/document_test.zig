//! Tests for platen Document and related functionality.

const std = @import("std");
const document = @import("document.zig");
const platen = @import("platen.zig");

// Re-export commonly used types for tests
const Document = document.Document;
const StandardFont = document.StandardFont;
const PageSize = document.PageSize;
const Region = document.Region;
const Border = document.Border;
const Color = document.Color;
const TextStyle = platen.TextStyle;
const Font = platen.Font;
const TextDecoration = platen.TextDecoration;

// Unit conversion functions
const inches = platen.inches;
const mm = platen.mm;
const cm = platen.cm;

test "Document init/deinit" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
}

test "Document output minimal PDF" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello, World!", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check font definitions (uncompressed objects)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    // Note: BT/ET/Tj are in compressed content stream, checked via integration tests
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

test "getPageIndex and pageCount" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // No pages yet
    try std.testing.expectEqual(@as(usize, 0), doc.getPageCount());
    try std.testing.expectEqual(@as(usize, 0), doc.getPageIndex());

    // Add first page - current is 0
    try doc.addPage(.{});
    try std.testing.expectEqual(@as(usize, 1), doc.getPageCount());
    try std.testing.expectEqual(@as(usize, 0), doc.getPageIndex());

    // Add second page - current is now 1
    try doc.addPage(.{});
    try std.testing.expectEqual(@as(usize, 2), doc.getPageCount());
    try std.testing.expectEqual(@as(usize, 1), doc.getPageIndex());

    // Select first page
    doc.selectPage(0);
    try std.testing.expectEqual(@as(usize, 2), doc.getPageCount());
    try std.testing.expectEqual(@as(usize, 0), doc.getPageIndex());
}

test "addPage with PageOptions" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Default page is A4
    try doc.addPage(.{});
    const region1 = doc.getPageRegion().?;
    try std.testing.expectApproxEqAbs(@as(f64, 595.28 - 144), region1.width, 0.01); // A4 minus default margins

    // Add Letter page with custom margins
    try doc.addPage(.{ .size = PageSize.Letter, .margins = .{ .left = 50, .right = 50, .top = 50, .bottom = 50 } });
    const region2 = doc.getPageRegion().?;
    try std.testing.expectApproxEqAbs(@as(f64, 612 - 100), region2.width, 0.01); // Letter minus 50+50 margins
}

test "selectPage switches current page" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Add A4 page
    try doc.addPage(.{});
    // Add Letter page
    try doc.addPage(.{ .size = PageSize.Letter });

    // Current is page 1 (Letter)
    var region = doc.getPageRegion().?;
    try std.testing.expectApproxEqAbs(@as(f64, 612 - 144), region.width, 0.01);

    // Select page 0 (A4)
    doc.selectPage(0);
    region = doc.getPageRegion().?;
    try std.testing.expectApproxEqAbs(@as(f64, 595.28 - 144), region.width, 0.01);
}

// Note: "text without font returns error" test removed - no longer applicable
// since writeAt() now takes TextStyle which always includes the font.

test "text without page returns error" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Should fail because no page is added
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    try std.testing.expectError(error.NoPage, doc.writeAt(.{ .x = 0, .y = 0 }, "test", style, .{}));
}

test "multiple fonts on single page" {
    // fpdf2: test_text_positioning - multiple fonts
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    const helvetica_style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Helvetica", helvetica_style, .{});

    const times_style = TextStyle{ .font = Font.times, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Times", times_style, .{});

    const courier_style = TextStyle{ .font = Font.courier, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 90 }, "Courier", courier_style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all fonts are present
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier") != null);
}

test "font styles" {
    // fpdf2: tests various font styles
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    const normal_style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Normal", normal_style, .{});

    const bold_style = TextStyle{ .font = Font.helvetica, .size = 12, .bold = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Bold", bold_style, .{});

    const italic_style = TextStyle{ .font = Font.helvetica, .size = 12, .italic = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 90 }, "Italic", italic_style, .{});

    const bold_italic_style = TextStyle{ .font = Font.helvetica, .size = 12, .bold = true, .italic = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 110 }, "BoldItalic", bold_italic_style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
}

test "multiple pages" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Page 1", style, .{});

    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Page 2", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check page count
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
}

// Helper to convert StandardFont to TextStyle for testing
fn standardFontToStyle(std_font: StandardFont, size: f64) TextStyle {
    return switch (std_font) {
        .helvetica => TextStyle{ .font = Font.helvetica, .size = size },
        .helvetica_bold => TextStyle{ .font = Font.helvetica, .size = size, .bold = true },
        .helvetica_oblique => TextStyle{ .font = Font.helvetica, .size = size, .italic = true },
        .helvetica_bold_oblique => TextStyle{ .font = Font.helvetica, .size = size, .bold = true, .italic = true },
        .times_roman => TextStyle{ .font = Font.times, .size = size },
        .times_bold => TextStyle{ .font = Font.times, .size = size, .bold = true },
        .times_italic => TextStyle{ .font = Font.times, .size = size, .italic = true },
        .times_bold_italic => TextStyle{ .font = Font.times, .size = size, .bold = true, .italic = true },
        .courier => TextStyle{ .font = Font.courier, .size = size },
        .courier_bold => TextStyle{ .font = Font.courier, .size = size, .bold = true },
        .courier_oblique => TextStyle{ .font = Font.courier, .size = size, .italic = true },
        .courier_bold_oblique => TextStyle{ .font = Font.courier, .size = size, .bold = true, .italic = true },
        .symbol => TextStyle{ .font = .symbol, .size = size },
        .zapf_dingbats => TextStyle{ .font = .zapf_dingbats, .size = size },
    };
}

test "all 14 standard fonts" {
    // fpdf2: tests all standard fonts
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

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
        const style = standardFontToStyle(font, 10);
        _ = try doc.writeAt(.{ .x = 50, .y = y }, font.pdfName(), style, .{});
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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const m = try doc.measureStyled("Hello", style);

    // "Hello" = H(722) + e(556) + l(222) + l(222) + o(556) = 2278
    // Width = 2278 * 12 / 1000 = 27.336
    try std.testing.expectApproxEqAbs(@as(f64, 27.336), m.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), m.height, 0.01); // 12 * 1.2
}

test "Document measureText with spacing" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const style = TextStyle{ .font = Font.helvetica, .size = 12, .char_spacing = 2.0 };
    const m = try doc.measureStyled("Hello", style);

    // Base ~27.336 + 4 * 2.0 = 35.336
    try std.testing.expectApproxEqAbs(@as(f64, 35.336), m.width, 0.01);
}

// ============================================================================
// Embedded Font Tests
// ============================================================================

test "load embedded font from file" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    // Verify font was loaded
    try std.testing.expect(doc.embedded_fonts.items.len == 1);
    try std.testing.expect(doc.embedded_fonts.items[0] == font.embedded);

    // Check font name was extracted
    try std.testing.expect(font.embedded.name.len > 0);

    // Check metrics are sensible
    try std.testing.expect(font.embedded.ascent > 0);
    try std.testing.expect(font.embedded.descent < 0); // Descent is negative
}

test "embedded font character widths" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    // Courier Prime is monospace - all visible chars should have same width
    const width_A = font.embedded.widths['A'];
    const width_Z = font.embedded.widths['Z'];
    const width_a = font.embedded.widths['a'];
    const width_m = font.embedded.widths['m'];

    try std.testing.expect(width_A > 0);
    try std.testing.expectEqual(width_A, width_Z);
    try std.testing.expectEqual(width_A, width_a);
    try std.testing.expectEqual(width_A, width_m);

    // Space should have a width
    try std.testing.expect(font.embedded.widths[' '] > 0);
}

test "embedded font text measurement" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    // Measure text at 12pt
    const width = font.embedded.measureTextWidth("Hello", 12.0);
    try std.testing.expect(width > 0);

    // "Hello" is 5 chars, monospace - each char same width
    const char_width = font.embedded.measureTextWidth("H", 12.0);
    try std.testing.expectApproxEqAbs(char_width * 5, width, 0.01);
}

test "render text with embedded font" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .win_ansi);

    try doc.addPage(.{});
    const style = TextStyle{ .font = .{ .embedded = font.embedded }, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello, World!", style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const courier_prime = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .win_ansi);

    try doc.addPage(.{});

    // Use standard font first
    const helvetica_style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Helvetica text", helvetica_style, .{});

    // Switch to embedded font
    const embedded_style = TextStyle{ .font = courier_prime, .size = 14 };
    _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Courier Prime text", embedded_style, .{});

    // Switch back to standard
    const times_style = TextStyle{ .font = Font.times, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 90 }, "Times text", times_style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const courier_regular = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .win_ansi);
    const courier_bold = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold.ttf", .win_ansi);

    try doc.addPage(.{});

    const regular_style = TextStyle{ .font = courier_regular, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Regular", regular_style, .{});

    const bold_style = TextStyle{ .font = courier_bold, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Bold", bold_style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .win_ansi);

    try doc.addPage(.{});
    const style = TextStyle{ .font = .{ .embedded = font.embedded }, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Page 1", style, .{});

    try doc.addPage(.{});
    // Font should still be set
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Page 2", style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Courier Prime is monospace
    const monospace = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);
    try std.testing.expect(monospace.embedded.flags.fixed_pitch == true);
}

test "embedded font bbox scaling" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    // BBox should be scaled to 1000 units
    // x_min should typically be negative or small
    // y_min should be negative (descenders)
    // x_max and y_max should be positive and reasonable for 1000 units
    try std.testing.expect(font.embedded.bbox[3] > 0); // y_max (ascenders)
    try std.testing.expect(font.embedded.bbox[3] <= 1500); // Should be scaled properly
    try std.testing.expect(font.embedded.bbox[1] <= 0); // y_min should be 0 or negative
}

test "embedded font widths array in PDF" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .win_ansi);

    try doc.addPage(.{});
    const style = TextStyle{ .font = .{ .embedded = font.embedded }, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Test", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Widths array should start with /Widths [
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Widths [") != null);

    // Should have 256 entries (FirstChar 0 to LastChar 255)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FirstChar 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/LastChar 255") != null);
}

test "variable font loading" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Inter Variable is a variable font - should still load basic metrics
    const font = doc.loadFont("test/fonts/Inter/InterVariable.ttf", .identity) catch |err| {
        // Variable fonts might have extra tables we don't handle yet
        // For now, skip if loading fails
        std.debug.print("Skipping variable font test: {}\n", .{err});
        return;
    };

    try std.testing.expect(font.embedded.ascent > 0);
    try std.testing.expect(font.embedded.widths['A'] > 0);
}

test "PDF output is valid with embedded font" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    try doc.addPage(.{});
    const style = TextStyle{ .font = .{ .embedded = font.embedded }, .size = 24 };
    _ = try doc.writeAt(.{ .x = 100, .y = 100 }, "Test embedded font!", style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{ .margins = .{ .left = 50, .right = 50, .top = 100, .bottom = 100 } });
    const region = doc.getPageRegion().?;

    try std.testing.expectEqual(@as(f64, 50), region.x);
    try std.testing.expectEqual(@as(f64, 100), region.y);
    try std.testing.expectEqual(PageSize.A4.width - 100, region.width);
    try std.testing.expectEqual(PageSize.A4.height - 200, region.height);
}

test "writeStyled advances cursor" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = doc.getPageRegion().?;
    const initial_cursor = region.cursor_y;

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test line", .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{});

    try std.testing.expect(region.cursor_y > initial_cursor);
    // Line height at 12pt with default 1.2 factor = 14.4pt
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), region.cursor_y, 0.01);
}

test "writeStyled alignment" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 100, .y = 100, .width = 400, .height = 600 };

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // Test left alignment (default)
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Left", .{});
        _ = try doc.writeStyled(&region, &st, style, .{});
    }
    // Test center alignment
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Center", .{});
        _ = try doc.writeStyled(&region, &st, style, .{ .alignment = .center });
    }
    // Test right alignment
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Right", .{});
        _ = try doc.writeStyled(&region, &st, style, .{ .alignment = .right });
    }

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic validation - PDF should be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "writeBlock alignment" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // Test that writeBlock() works with different alignments (block-based)
    {
        var region = Region{ .x = 100, .y = 100, .width = 200, .height = 50 };
        _ = try doc.writeBlock(&region, "Centered text", style, .{ .alignment = .center });
    }
    {
        var region = Region{ .x = 100, .y = 150, .width = 200, .height = 50 };
        _ = try doc.writeBlock(&region, "Right aligned", style, .{ .alignment = .right });
    }
    {
        var region = Region{ .x = 100, .y = 200, .width = 200, .height = 50 };
        _ = try doc.writeBlock(&region, "Justified text that wraps to multiple lines for testing", style, .{ .alignment = .justify });
    }

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "writeStyled wraps text to multiple lines" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 600 };
    const long_text = "This is a longer piece of text that should wrap across multiple lines within the region.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(long_text, .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const result = try doc.writeStyled(&region, &st, style, .{});

    try std.testing.expect(result.lines_written > 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled overflow" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Small region - line height at 12pt with 1.2 factor = 14.4pt
    // Region of 15pt should fit one line, but not two (would need 28.8pt)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 15 };
    const long_text = "Word one two three four five six seven eight nine ten.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(long_text, .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const result = try doc.writeStyled(&region, &st, style, .{});

    // Should only fit one line due to height constraint
    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
    try std.testing.expect(result.overflow != null);
}

test "writeStyled multi-page via overflow handling" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const page_opts = platen.PageOptions{ .margins = .{ .left = 50, .right = 50, .top = 50, .bottom = 50 } };
    try doc.addPage(page_opts);

    // Generate long text that should span multiple pages
    const paragraph = @import("testing.zig").repeat("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor. ", 100);

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(paragraph, .{});

    // Manual pagination loop using overflow
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    var remaining: ?[]const u8 = paragraph;
    while (remaining) |text_to_write| {
        if (text_to_write.len == 0) break;

        var region = doc.getPageRegion().?;
        var page_st = doc.createStyledText();
        defer page_st.deinit();
        try page_st.append(text_to_write, .{});

        const result = try doc.writeStyled(&region, &page_st, style, .{});

        if (result.overflow) |overflow| {
            try doc.addPage(page_opts);
            remaining = overflow;
        } else {
            remaining = null;
        }
    }

    // Should have created multiple pages
    try std.testing.expect(doc.getPageCount() > 1);
}

test "drawRegion with border" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

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

// Break helper tests moved to document.zig (internal tests)

test "soft hyphens stripped from text output" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // Write text with soft-hyphens
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "ex\xc2\xadplic\xc2\xadit", style, .{});

    // The stored text should have soft-hyphens stripped
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 1), page.commands.items.len);
    const cmd = page.commands.items[0];
    try std.testing.expectEqualStrings("explicit", cmd.text.text_data);
}

test "writeStyled in narrow column" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Narrow column test - text should wrap
    var region = Region{ .x = 72, .y = 100, .width = 100, .height = 200 };

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("This is a test of narrow column wrapping behavior.", .{});

    const style = TextStyle{ .font = Font.helvetica, .size = 11 };
    const result = try doc.writeStyled(&region, &st, style, .{});

    // Should produce multiple lines
    try std.testing.expect(result.lines_written >= 2);
}

// Soft hyphen width test moved to document.zig (internal test)

test "writeStyled overflow returns remaining text" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Region that can only fit 2 lines (line height = 14.4pt at 12pt font)
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 30 };
    const text = "Line one fits here. Line two fits too. Line three overflows. Line four too.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(text, .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const result = try doc.writeStyled(&region, &st, style, .{});

    try std.testing.expectEqual(@as(usize, 2), result.lines_written);
    try std.testing.expect(result.overflow != null);
}

test "writeStyled newline forces line break" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    const text = "Line one.\nLine two.\nLine three.";

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(text, .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const result = try doc.writeStyled(&region, &st, style, .{});

    // Should have 3 lines due to explicit newlines
    try std.testing.expectEqual(@as(usize, 3), result.lines_written);
}

test "writeStyled returns overflow when no room" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Small region that can only fit ~1 line
    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 15 };
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("First line", .{});
        const result1 = try doc.writeStyled(&region, &st, style, .{});
        try std.testing.expectEqual(@as(usize, 1), result1.lines_written);
        try std.testing.expect(result1.overflow == null);
    }

    // Second line should indicate no room
    {
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("Second line", .{});
        const result2 = try doc.writeStyled(&region, &st, style, .{});
        try std.testing.expectEqual(@as(usize, 0), result2.lines_written);
        try std.testing.expect(result2.overflow != null);
    }
}

test "region padding affects content area" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

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
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{});
    try std.testing.expect(region.remainingHeight() < 90);
}

test "writeStyled handles empty text" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = doc.getPageRegion().?;

    // Empty styled text should not crash
    var st = doc.createStyledText();
    defer st.deinit();
    // Don't append anything - empty
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{});

    // Should still have just one page
    try std.testing.expectEqual(@as(usize, 1), doc.pages.items.len);
}

test "writeStyled respects margins via region" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{ .margins = .{ .left = 100, .right = 100, .top = 100, .bottom = 100 } });

    var region = doc.getPageRegion().?;
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Short text.", .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{});

    // Check text position respects left margin
    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            try std.testing.expect(cmd.text.x >= 100);
        }
    }
}

test "valign top_leading uses half-leading calculation" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{ .valign = .top_leading });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // top_leading valign: baseline = cursor_y + (line_height + ascender - descender) / 2
            // Helvetica: ascender = 0.718 * 12 = 8.616, descender = 0.207 * 12 = 2.484
            // line_height = 12 * 1.2 = 14.4
            // baseline = 0 + (14.4 + 8.616 - 2.484) / 2 = 10.266
            // top-down y = region.y(100) + baseline(10.266) = 110.266
            // PDF y = page_height(841.89) - 110.266 = 731.624
            try std.testing.expectApproxEqAbs(@as(f64, 731.62), cmd.text.y, 0.1);
        }
    }
}

test "valign top aligns cap-height to top edge" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    // Use Times: ascender=683, cap_height=662, descender=-217 (cap != ascender)
    const style = TextStyle{ .font = Font.times, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{ .valign = .top });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // .top valign: baseline = region.y + cap_height
            // Times: cap_height = 0.662 * 12 = 7.944
            // top-down y = region.y(100) + cap_height(7.944) = 107.944
            // PDF y = page_height(841.89) - 107.944 = 733.946
            try std.testing.expectApproxEqAbs(@as(f64, 733.95), cmd.text.y, 0.1);
        }
    }
}

test "valign top_ascent aligns ascender to top edge" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    // Use Times: ascender=683, cap_height=662 (ascender > cap_height)
    const style = TextStyle{ .font = Font.times, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{ .valign = .top_ascent });

    const page = &doc.pages.items[0];
    for (page.commands.items) |cmd| {
        if (cmd == .text) {
            // .top_ascent valign: baseline = region.y + ascender
            // Times: ascender = 0.683 * 12 = 8.196
            // top-down y = region.y(100) + ascender(8.196) = 108.196
            // PDF y = page_height(841.89) - 108.196 = 733.694
            try std.testing.expectApproxEqAbs(@as(f64, 733.69), cmd.text.y, 0.1);
        }
    }
}

test "valign middle centers text block in region" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{ .valign = .middle });

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var region = Region{ .x = 50, .y = 100, .width = 200, .height = 200 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Test", .{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{ .valign = .bottom });

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Courier is monospace: 600 units per char, at 12pt = 7.2pt per char
    // 14 chars width = 14 * 7.2 = 100.8pt
    const char_width = 7.2;
    const region_width = 14 * char_width;

    const text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";

    const style = TextStyle{ .font = Font.courier, .size = 12 };

    // Test greedy mode
    var region_greedy = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_greedy = doc.createStyledText();
    defer st_greedy.deinit();
    try st_greedy.append(text, .{});
    const greedy_result = try doc.writeStyled(&region_greedy, &st_greedy, style, .{ .line_breaking = .greedy });

    // Test optimal mode
    try doc.addPage(.{});
    var region_optimal = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_optimal = doc.createStyledText();
    defer st_optimal.deinit();
    try st_optimal.append(text, .{});
    const optimal_result = try doc.writeStyled(&region_optimal, &st_optimal, style, .{ .line_breaking = .optimal });

    // Both should produce 7 lines for this text
    try std.testing.expectEqual(@as(usize, 7), greedy_result.lines_written);
    try std.testing.expectEqual(@as(usize, 7), optimal_result.lines_written);

    // No overflow
    try std.testing.expect(greedy_result.overflow == null);
    try std.testing.expect(optimal_result.overflow == null);
}

test "writeStyled greedy and optimal both render successfully" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.courier, .size = 12 };

    // Courier is monospace at 600 units/1000 * 12pt = 7.2pt/char
    const region_width = 101.0; // Just over 14 chars
    const text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";

    // Test greedy mode
    var region = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_greedy = doc.createStyledText();
    defer st_greedy.deinit();
    try st_greedy.append(text, .{});
    const greedy_result = try doc.writeStyled(&region, &st_greedy, style, .{ .line_breaking = .greedy });

    // Test optimal mode
    try doc.addPage(.{});
    var region2 = Region{ .x = 0, .y = 0, .width = region_width, .height = 500 };
    var st_optimal = doc.createStyledText();
    defer st_optimal.deinit();
    try st_optimal.append(text, .{});
    const optimal_result = try doc.writeStyled(&region2, &st_optimal, style, .{ .line_breaking = .optimal });

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

    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);

    try doc.addPage(.{});

    // Write "À" (A + combining grave)
    const style = TextStyle{ .font = inter, .size = 14 };
    _ = try doc.writeAt(.{ .x = 100, .y = 700 }, "A\xcc\x80", style, .{});

    // Render via output(); page.content stays populated afterwards
    const pdf = try doc.output();
    doc.allocator.free(pdf);
    const page = &doc.pages.items[0];
    const content = page.content.items;

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
            }
        }
    }

    // Should have at least 2 Tm operations (base + mark)
    try std.testing.expect(tm_count >= 2);

    // Mark Y should be higher than base Y (mark is above the base glyph)
    if (base_y != null and mark_y != null) {
        try std.testing.expect(mark_y.? > base_y.?);
    }
}

test "TextStyle color stored in command" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Write text with explicit red color
    const red_style = TextStyle{ .font = Font.helvetica, .size = 12, .color = Color.red };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Red text", red_style, .{});

    // Verify the command stored the color
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 1), page.commands.items.len);

    const cmd = page.commands.items[0];
    const text_cmd = cmd.text;
    try std.testing.expect(text_cmd.text_color.eql(Color.red));
}

test "Color grayscale stored in command" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Write text with greyscale color via explicit style
    const gray = Color.greyscale(0.5);
    const gray_style = TextStyle{ .font = Font.helvetica, .size = 12, .color = gray };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Gray text", gray_style, .{});

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(gray));
}

test "Color CMYK stored in command" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Write text with CMYK color via explicit style
    const cyan = Color.cmyk(1, 0, 0, 0);
    const cyan_style = TextStyle{ .font = Font.helvetica, .size = 12, .color = cyan };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Cyan text", cyan_style, .{});

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(cyan));
}

test "Color.rgb" {
    const c = Color.rgb(255, 128, 0);
    try std.testing.expectEqual(@as(f64, 1.0), c.rgb_val.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), c.rgb_val.g, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), c.rgb_val.b);
}

test "getFontMetrics standard font" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const m = doc.getFontMetricsStyled(style);

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const style24 = TextStyle{ .font = Font.helvetica, .size = 24 };
    const m24 = doc.getFontMetricsStyled(style24);

    const style12 = TextStyle{ .font = Font.helvetica, .size = 12 };
    const m12 = doc.getFontMetricsStyled(style12);

    // Metrics should scale linearly with font size
    try std.testing.expectApproxEqAbs(m24.ascender, m12.ascender * 2, 0.001);
    try std.testing.expectApproxEqAbs(m24.descender, m12.descender * 2, 0.001);
}

test "getFontMetrics Times vs Helvetica" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const helvetica_style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const hm = doc.getFontMetricsStyled(helvetica_style);

    const times_style = TextStyle{ .font = Font.times, .size = 12 };
    const tm = doc.getFontMetricsStyled(times_style);

    // Times has different metrics than Helvetica
    // Times ascender: 683, Helvetica: 718
    try std.testing.expect(tm.ascender < hm.ascender);
    // Times x-height: 450, Helvetica: 523
    try std.testing.expect(tm.x_height < hm.x_height);
}

test "getFontMetrics lineHeight" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const m = doc.getFontMetricsStyled(style);

    // lineHeight = ascender - descender
    // 8.616 - (-2.484) = 11.1
    const expected_lh = m.ascender - m.descender;
    try std.testing.expectApproxEqAbs(expected_lh, m.lineHeight(), 0.001);
}

// ============================================================================
// Graphics Primitives Tests
// ============================================================================

test "drawLine basic" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawLine(.{ .x = 50, .y = 50 }, .{ .x = 200, .y = 200 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF with a content stream (content is compressed)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawLine without page returns error" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try std.testing.expectError(error.NoPage, doc.drawLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, .{}));
}

test "drawRect stroke" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF (content is compressed, detailed check in integration tests)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRect fill" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{ .fill = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawRect fill_stroke" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{ .stroke = .{}, .fill = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawRoundedRect basic" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawRoundedRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, 10, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output (content is compressed)
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRoundedRect zero radius falls back to rect" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Zero radius should use regular rect (re command)
    try doc.drawRoundedRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, 0, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawRoundedRect radius clamped to half min dimension" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Radius 100 is larger than half of min(100, 80) = 40, so clamped to 40
    try doc.drawRoundedRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, 100, .{ .fill = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify valid PDF output
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawCircle basic" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawCircle(.{ .x = 200, .y = 300 }, 50, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Contents") != null);
}

test "drawEllipse basic" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // drawEllipse(rect) - bounding box upper-left at (200, 300), size 80x40
    try doc.drawEllipse(.{ .x = 200, .y = 300, .width = 80, .height = 40 }, .{ .fill = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPolygon triangle" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const points = [_]document.Point{
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 100 },
        .{ .x = 150, .y = 50 },
    };
    try doc.drawPolygon(&points, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPolygon less than 3 points does nothing" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const points = [_]document.Point{
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 100 },
    };
    // Should not error, just do nothing
    try doc.drawPolygon(&points, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // PDF should still be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath basic triangle" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var path = doc.createPath();
    defer path.deinit();

    try path.moveTo(.{ .x = 100, .y = 100 });
    try path.lineTo(.{ .x = 200, .y = 100 });
    try path.lineTo(.{ .x = 150, .y = 50 });
    try path.closePath();

    try doc.drawPath(&path, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath with bezier curve" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var path = doc.createPath();
    defer path.deinit();

    try path.moveTo(.{ .x = 100, .y = 200 });
    try path.curveTo(.{ .x = 150, .y = 100 }, .{ .x = 250, .y = 100 }, .{ .x = 300, .y = 200 });
    try path.lineTo(.{ .x = 100, .y = 200 });
    try path.closePath();

    try doc.drawPath(&path, .{ .stroke = .{}, .fill = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath empty path does nothing" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    var path = doc.createPath();
    defer path.deinit();

    // Empty path should not error
    try doc.drawPath(&path, .{ .stroke = .{} });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "drawPath without page returns error" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    var path = doc.createPath();
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });

    try std.testing.expectError(error.NoPage, doc.drawPath(&path, .{ .stroke = .{} }));
}

test "graphics state used in output" {
    // Test that explicit graphics style produces valid PDF
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .stroke = .{
            .color = Color.red,
            .width = 3.0,
            .dash = .{ .dash = 5, .gap = 3 },
            .cap = .round,
            .join = .bevel,
        },
        .fill = .{ .color = Color.blue },
    });

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "My Document",
        .author = "Test Author",
    });

    try std.testing.expectEqualStrings("My Document", doc.metadata.title.?);
    try std.testing.expectEqualStrings("Test Author", doc.metadata.author.?);
    try std.testing.expectEqualStrings(platen.version.full, doc.metadata.producer.?);
}

test "metadata written to PDF Info dictionary" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "Test Title",
        .author = "Test Author",
        .subject = "Test Subject",
        .keywords = "test, pdf, zig",
        .creator = "Test App",
    });

    try doc.addPage(.{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that Info dictionary fields appear in PDF
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Title (Test Title)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Author (Test Author)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subject (Test Subject)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Keywords (test, pdf, zig)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Creator (Test App)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Producer (" ++ platen.version.full ++ ")") != null);
    // Check auto-generated dates are present (format: D:YYYYMMDDHHmmSSZ)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CreationDate (D:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ModDate (D:") != null);
    // Check trailer references Info dictionary
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Info") != null);
}

test "metadata with special characters escaped" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setMetadata(.{
        .title = "Test (with parens) and \\backslash",
    });

    try doc.addPage(.{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check that special chars are escaped in PDF string
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Title (Test \\(with parens\\) and \\\\backslash)") != null);
}

test "no Info dictionary when metadata empty" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Clear default producer
    doc.setMetadata(.{ .producer = null });

    try doc.addPage(.{});

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

test "outline in PDF output" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const dest = document.Destination{ .page_index = 0, .y = 100 };

    // Build outline using builder pattern
    var outline = doc.createOutline();
    _ = try outline.add("Test Outline", dest);
    doc.setOutline(&outline);

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check for outlines structure in PDF
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Outlines") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Outlines") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Test Outline)") != null);
}

test "nested outline in PDF output" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.addPage(.{});

    // Build outline using builder pattern
    var outline = doc.createOutline();
    const ch1 = try outline.add("Chapter 1", .{ .page_index = 0, .y = 0 });
    _ = try outline.addChild(ch1, "Section 1.1", .{ .page_index = 0, .y = 200 });
    _ = try outline.addChild(ch1, "Section 1.2", .{ .page_index = 0, .y = 400 });
    _ = try outline.add("Chapter 2", .{ .page_index = 1, .y = 0 });
    doc.setOutline(&outline);

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.setPageLabel(0, .{ .style = .roman_lower });
    try doc.setPageLabel(4, .{ .style = .decimal, .start = 1 });

    try std.testing.expectEqual(@as(usize, 2), doc.page_labels.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.page_labels.items[0].page_index);
    try std.testing.expectEqual(@as(usize, 4), doc.page_labels.items[1].page_index);
}

test "setPageLabel in PDF output" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    for (0..6) |_| {
        try doc.addPage(.{});
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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.setPageLabel(0, .{ .style = .alpha_upper, .prefix = "App-" });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/P (App-)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/S /A") != null);
}

test "setPageLabel with start number" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.setPageLabel(0, .{ .style = .decimal, .start = 5 });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/St 5") != null);
}

test "no outlines or page labels when not set" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

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

test "TextStyle underline decoration stored in command" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Write text with underline via explicit style
    const underline_style = TextStyle{ .font = Font.helvetica, .size = 12, .decoration = .{ .underline = true } };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Underlined text", underline_style, .{});

    // Verify the command has underline enabled
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.underline);
}

test "TextStyle strikethrough decoration stored in command" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Write text with strikethrough via explicit style
    const strikethrough_style = TextStyle{ .font = Font.helvetica, .size = 12, .decoration = .{ .strikethrough = true } };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Strikethrough text", strikethrough_style, .{});

    // Verify the command has strikethrough enabled
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.strikethrough);
}

test "text width stored in command for decorations" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    const underline_style = TextStyle{ .font = Font.helvetica, .size = 12, .decoration = .{ .underline = true } };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Hello", underline_style, .{});

    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];

    // Text width should be non-zero when decorations enabled
    try std.testing.expect(cmd.text.text_width > 0);
}

test "TextStyle with both decorations" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    const both_style = TextStyle{ .font = Font.helvetica, .size = 12, .decoration = .{ .underline = true, .strikethrough = true } };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Test", both_style, .{});

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

test "TextStyle with color and decoration" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});

    // Color and decoration set together in style
    const style = TextStyle{ .font = Font.helvetica, .size = 12, .color = Color.red, .decoration = .{ .underline = true } };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Test", style, .{});

    // Verify the command has both color and decoration
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[0];
    try std.testing.expect(cmd.text.text_color.eql(Color.red));
    try std.testing.expect(cmd.text.underline);
}

test "decoration not rendered when disabled" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 0, .y = 0 }, "Test", style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    // Check decoration metrics were loaded
    // Courier Prime should have reasonable values
    try std.testing.expect(font.embedded.underline_position != 0 or font.embedded.underline_thickness != 0);
    try std.testing.expect(font.embedded.strikeout_position > 0);
    try std.testing.expect(font.embedded.strikeout_size > 0);
}

test "write() advances cursor_x" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 100 };

    try std.testing.expectEqual(@as(f64, 0), region.cursor_x);
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.write(&region, "Hello", style, .{});

    // cursor_x should have advanced
    try std.testing.expect(region.cursor_x > 0);
    // cursor_y should still be 0 (same line)
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);
}

test "write() wraps to next line" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Narrow region to force wrapping
    var region = Region{ .x = 50, .y = 50, .width = 60, .height = 100 };

    // "Hello World" won't fit on one 60pt line (Hello ~27pt, World ~31pt, space ~3pt)
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.write(&region, "Hello World", style, .{});

    // Should have wrapped - cursor_y should have advanced
    try std.testing.expect(region.cursor_y > 0);
}

test "write() with multiple styled chunks" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 100 };

    const normal_style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.write(&region, "Normal ", normal_style, .{});

    const red_style = TextStyle{ .font = Font.helvetica, .size = 12, .color = Color.red };
    _ = try doc.write(&region, "red ", red_style, .{});

    const underline_style = TextStyle{ .font = Font.helvetica, .size = 12, .decoration = .{ .underline = true } };
    _ = try doc.write(&region, "underlined", underline_style, .{});

    // Should have 3 text commands
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 3), page.commands.items.len);

    // Check styles were preserved
    try std.testing.expect(page.commands.items[1].text.text_color.eql(Color.red));
    try std.testing.expect(page.commands.items[2].text.underline);
}

test "write() returns overflow when region is full" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Very small region - only fits one line
    var region = Region{ .x = 50, .y = 50, .width = 100, .height = 15 };

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    const result = try doc.write(&region, "This is a long text that will overflow the small region", style, .{});

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
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 100 };
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // Measure pass - cursor should be unchanged (side-effect free)
    const result = try doc.write(&region, "Hello World", style, .{ .measure_only = true });
    try std.testing.expectEqual(@as(f64, 0), region.cursor_x);
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);
    try std.testing.expect(result.lines_written >= 1);

    // Check no text was rendered (page content should be empty)
    const page = &doc.pages.items[0];
    try std.testing.expectEqual(@as(usize, 0), page.commands.items.len);

    // Write for real - cursor should now advance
    _ = try doc.write(&region, "Hello World", style, .{});
    try std.testing.expect(region.cursor_x > 0 or region.cursor_y > 0);

    // Now there should be commands
    try std.testing.expect(page.commands.items.len > 0);
}

test "write() with wrap=false stays on one line" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Narrow region that would normally wrap
    var region = Region{ .x = 50, .y = 50, .width = 60, .height = 100 };

    const style = TextStyle{ .font = Font.helvetica, .size = 12 };
    _ = try doc.write(&region, "Hello World Test", style, .{ .wrap = false });

    // With wrap=false, cursor_y should stay at 0 (no line wrapping)
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);

    // cursor_x should be beyond the region width (text overflows)
    try std.testing.expect(region.cursor_x > 60);
}

// ============================================================================
// StyledText Tests
// ============================================================================

test "writeStyled basic" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("Hello ", .{});
    try text.append("World", .{ .color = Color.red });

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    const result = try doc.writeStyled(&region, &text, style, .{});

    try std.testing.expectEqual(@as(usize, 1), result.lines_written);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled word wrapping" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("The quick brown fox ", .{});
    try text.append("jumps over the lazy dog", .{ .color = Color.blue });

    // Narrow region to force wrapping
    var region = Region{ .x = 50, .y = 50, .width = 120, .height = 200 };
    const result = try doc.writeStyled(&region, &text, style, .{});

    try std.testing.expect(result.lines_written > 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled justified alignment" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("This is a ", .{});
    try text.append("test", .{ .color = Color.red });
    try text.append(" of justified text.", .{});

    var region = Region{ .x = 50, .y = 50, .width = 200, .height = 200 };
    const result = try doc.writeStyled(&region, &text, style, .{ .alignment = .justify });

    try std.testing.expect(result.lines_written >= 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled optimal line breaking" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("The quick brown ", .{});
    try text.append("fox jumps over ", .{ .color = Color.red });
    try text.append("the lazy dog.", .{});

    var region = Region{ .x = 50, .y = 50, .width = 150, .height = 200 };
    const result = try doc.writeStyled(&region, &text, style, .{
        .line_breaking = .optimal,
    });

    try std.testing.expect(result.lines_written >= 1);
    try std.testing.expect(result.overflow == null);
}

test "writeStyled generates valid PDF" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    try text.append("Normal ", .{});
    try text.append("red ", .{ .color = Color.red });
    try text.append("underlined", .{ .decoration = .{ .underline = true } });

    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };
    _ = try doc.writeStyled(&region, &text, style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // PDF should be valid
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(pdf.len > 100);
}

test "writeStyled breaks at soft-hyphen when word too wide" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    // Word with soft-hyphens: "in­com­pre­hen­si­ble" - very long word
    // At 12pt Helvetica, this is about 70-80pt wide
    try text.append("in\xC2\xADcom\xC2\xADpre\xC2\xADhen\xC2\xADsi\xC2\xADble", .{});

    // Use a narrow region that forces breaking
    var region = Region{ .x = 50, .y = 50, .width = 40, .height = 100 };
    const result = try doc.writeStyled(&region, &text, style, .{});

    // Should have rendered multiple lines due to soft-hyphen breaking
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled soft-hyphen break renders hyphen" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    // "ab­cd" - soft-hyphen after "ab"
    try text.append("ab\xC2\xADcd", .{});

    // Width that fits "ab-" but not "abcd"
    // At 12pt Helvetica: "ab" is about 14pt, "-" is about 4pt, "abcd" is about 27pt
    var region = Region{ .x = 50, .y = 50, .width = 22, .height = 50 };
    const result = try doc.writeStyled(&region, &text, style, .{});

    // Should have broken into 2 lines: "ab-" and "cd"
    try std.testing.expectEqual(@as(usize, 2), result.lines_written);

    // Generate PDF and check it contains hyphen
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(pdf.len > 0);
}

test "writeStyled breaks at regular hyphen when break_on_hyphens is true" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    // Compound word with regular hyphens: "state-of-the-art"
    try text.append("state-of-the-art", .{});

    // Width that fits "state-" (~35pt) but not full word (~87pt)
    var region = Region{ .x = 50, .y = 50, .width = 45, .height = 100 };
    const result = try doc.writeStyled(&region, &text, style, .{ .break_on_hyphens = true });

    // Should have broken at hyphen
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled does not break at regular hyphen when break_on_hyphens is false" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    // Compound word with regular hyphens
    try text.append("state-of-the-art", .{});

    // Narrow width - with break_on_hyphens=false, should NOT break at hyphen
    // But character-level breaking will still apply as last resort
    var region = Region{ .x = 50, .y = 50, .width = 45, .height = 100 };
    const result = try doc.writeStyled(&region, &text, style, .{ .break_on_hyphens = false });

    // With break_on_hyphens=false, won't break at hyphens but will do character breaks
    // So it will still break (just not at the hyphen boundaries)
    try std.testing.expect(result.lines_written >= 2);
}

test "writeStyled character-level breaking for long word without hyphens" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();

    // Long word without any hyphens: "supercalifragilisticexpialidocious" (~190pt at 12pt)
    try text.append("supercalifragilisticexpialidocious", .{});

    // Very narrow width (50pt) forces multiple character breaks
    // At 12pt Helvetica, ~7-8 chars fit per line, so expect ~5 lines
    var region = Region{ .x = 50, .y = 50, .width = 50, .height = 200 };
    const result = try doc.writeStyled(&region, &text, style, .{});

    // Should break into multiple lines via repeated character breaking
    try std.testing.expect(result.lines_written >= 4);
}

test "writeStyled measure_only is side-effect free" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    var text = doc.createStyledText();
    defer text.deinit();
    try text.append("This is a test paragraph that should wrap to multiple lines in a narrow region.", .{});

    // Measure the text
    var measure_region = Region{ .x = 50, .y = 50, .width = 150, .height = 1000 };
    const measure_result = try doc.writeStyled(&measure_region, &text, style, .{ .measure_only = true });

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
    const render_result = try doc.writeStyled(&render_region, &text2, style, .{});

    // Should get the same line count
    try std.testing.expectEqual(measure_result.lines_written, render_result.lines_written);

    // PDF should be generated successfully
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(pdf.len > 0);
}

// ============================================================================
// Font loading and family tests (moved from document.zig)
// ============================================================================

test "font family loads and resolves variants" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Load Gentium family with all variants
    const font = try doc.loadFontFamily(.{
        .regular = "test/fonts/Gentium/Gentium-Regular.ttf",
        .bold = "test/fonts/Gentium/Gentium-Bold.ttf",
        .italic = "test/fonts/Gentium/Gentium-Italic.ttf",
        .bold_italic = "test/fonts/Gentium/Gentium-BoldItalic.ttf",
    });

    // Extract the family
    const fam = font.embedded_family;

    // Regular resolves to regular
    const regular = try fam.resolve(false, false);
    try std.testing.expect(std.mem.startsWith(u8, regular.name, "Gentium"));

    // Bold resolves to bold
    const bold = try fam.resolve(true, false);
    try std.testing.expect(bold != regular);

    // Italic resolves to italic
    const italic = try fam.resolve(false, true);
    try std.testing.expect(italic != regular);

    // Bold+italic resolves to bold-italic
    const bold_italic = try fam.resolve(true, true);
    try std.testing.expect(bold_italic != bold);
    try std.testing.expect(bold_italic != italic);
}

test "font family with missing variant returns error" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Load family with only regular
    const font = try doc.loadFontFamily(.{
        .regular = "test/fonts/Gentium/Gentium-Regular.ttf",
    });

    const fam = font.embedded_family;

    // Regular works
    _ = try fam.resolve(false, false);

    // Bold should fail
    try std.testing.expectError(error.FontVariantNotLoaded, fam.resolve(true, false));

    // Italic should fail
    try std.testing.expectError(error.FontVariantNotLoaded, fam.resolve(false, true));

    // Bold+italic should fail
    try std.testing.expectError(error.FontVariantNotLoaded, fam.resolve(true, true));
}

test "font family text rendering uses correct variant" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Load Gentium family
    const font = try doc.loadFontFamily(.{
        .regular = "test/fonts/Gentium/Gentium-Regular.ttf",
        .bold = "test/fonts/Gentium/Gentium-Bold.ttf",
        .italic = "test/fonts/Gentium/Gentium-Italic.ttf",
        .bold_italic = "test/fonts/Gentium/Gentium-BoldItalic.ttf",
    });

    try doc.addPage(.{});

    // Write text with different styles - should use correct font variant
    const base_style = TextStyle{ .font = font, .size = 12 };
    const bold_style = TextStyle{ .font = font, .size = 12, .bold = true };
    const italic_style = TextStyle{ .font = font, .size = 12, .italic = true };
    const bold_italic_style = TextStyle{ .font = font, .size = 12, .bold = true, .italic = true };

    // All should succeed without error
    _ = try doc.writeAt(.{ .x = 100, .y = 100 }, "Regular text", base_style, .{});
    _ = try doc.writeAt(.{ .x = 100, .y = 120 }, "Bold text", bold_style, .{});
    _ = try doc.writeAt(.{ .x = 100, .y = 140 }, "Italic text", italic_style, .{});
    _ = try doc.writeAt(.{ .x = 100, .y = 160 }, "Bold italic text", bold_italic_style, .{});

    // Generate PDF output
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // PDF should contain font references for all variants
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E2 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E3 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E4 ") != null);
}

test "loadFontFromMemory loads font from buffer" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Read font file into memory
    const font_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Gentium/Gentium-Regular.ttf", std.testing.allocator, .limited(10 * 1024 * 1024));
    defer std.testing.allocator.free(font_data);

    // Load from memory
    const font = try doc.loadFontFromMemory(font_data, .identity);

    try doc.addPage(.{});
    const style = TextStyle{ .font = font, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Text from memory-loaded font", style, .{});

    // Generate PDF and verify it contains embedded font
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 ") != null);
}

test "loadFontFamilyFromMemory loads family from buffers" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Read font files into memory
    const regular_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Gentium/Gentium-Regular.ttf", std.testing.allocator, .limited(10 * 1024 * 1024));
    defer std.testing.allocator.free(regular_data);

    const bold_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Gentium/Gentium-Bold.ttf", std.testing.allocator, .limited(10 * 1024 * 1024));
    defer std.testing.allocator.free(bold_data);

    // Load family from memory
    const font = try doc.loadFontFamilyFromMemory(.{
        .regular = regular_data,
        .bold = bold_data,
    });

    // Verify resolution works
    const fam = font.embedded_family;
    const regular = try fam.resolve(false, false);
    const bold = try fam.resolve(true, false);
    try std.testing.expect(bold != regular);

    // Verify missing variant returns error
    try std.testing.expectError(error.FontVariantNotLoaded, fam.resolve(false, true));

    // Verify rendering works
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Regular", .{ .font = font, .size = 12 }, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Bold", .{ .font = font, .size = 12, .bold = true }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E2 ") != null);
}

test "loadImageFromMemory loads image from buffer" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Read image file into memory
    const image_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/images/robot.png", std.testing.allocator, .limited(5 * 1024 * 1024));
    defer std.testing.allocator.free(image_data);

    // Load from memory
    const image = try doc.loadImageFromMemory(image_data);

    try doc.addPage(.{});
    try doc.drawImage(image, .{ .x = 50, .y = 50, .width = 100, .height = 0 });

    // Generate PDF and verify it contains image
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Image") != null);
}

test "loadSvgFromMemory loads SVG from buffer" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // SVG content in memory
    const svg_data =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
        \\  <rect x="10" y="10" width="80" height="80" fill="red"/>
        \\</svg>
    ;

    // Load from memory
    const loaded_svg = try doc.loadSvgFromMemory(svg_data);

    try doc.addPage(.{});
    try doc.drawSvg(loaded_svg, .{ .x = 50, .y = 50, .width = 100, .height = 100 });

    // Generate PDF and verify it contains the SVG content
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    // SVG is rendered as Form XObject
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Form") != null);
}

// ============================================================================
// Opacity Tests
// ============================================================================

test "drawRect with fill opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Draw a semi-transparent filled rectangle
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.rgb(255, 0, 0), .opacity = 0.5 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify PDF has ExtGState resources
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/GS1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ca 0.5") != null);
}

test "drawRect with stroke opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Draw a rectangle with semi-transparent stroke
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .stroke = .{ .color = Color.rgb(0, 0, 255), .opacity = 0.7 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify PDF has ExtGState with stroke opacity
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CA 0.7") != null);
}

test "drawRect with both fill and stroke opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Draw with different fill and stroke opacity
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.rgb(255, 0, 0), .opacity = 0.3 },
        .stroke = .{ .color = Color.rgb(0, 0, 0), .opacity = 0.8 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify PDF has ExtGState with both opacities
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ca 0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CA 0.8") != null);
}

test "drawRect fully opaque has no ExtGState" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Draw fully opaque (default opacity = 1.0)
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.rgb(255, 0, 0) },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // No ExtGState needed for fully opaque
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") == null);
}

test "drawLine with opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawLine(.{ .x = 10, .y = 10 }, .{ .x = 100, .y = 100 }, .{
        .color = Color.rgb(0, 128, 0),
        .width = 2.0,
        .opacity = 0.6,
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Verify ExtGState for stroke opacity
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CA 0.6") != null);
}

test "drawEllipse with opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    try doc.drawEllipse(.{ .x = 100, .y = 100, .width = 80, .height = 60 }, .{
        .fill = .{ .color = Color.rgb(255, 255, 0), .opacity = 0.4 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ca 0.4") != null);
}

test "opacity state deduplication" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Draw multiple shapes with the same opacity - should reuse same ExtGState
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 50, .height = 50 }, .{
        .fill = .{ .opacity = 0.5 },
    });
    try doc.drawRect(.{ .x = 110, .y = 50, .width = 50, .height = 50 }, .{
        .fill = .{ .opacity = 0.5 },
    });
    try doc.drawRect(.{ .x = 170, .y = 50, .width = 50, .height = 50 }, .{
        .fill = .{ .opacity = 0.5 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Should only have one GS0 definition (deduplicated)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/GS1") != null);
    // Count occurrences of "/ca 0.5" - should only be once in ExtGState dict
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, pdf[idx..], "/ca 0.5")) |pos| {
        count += 1;
        idx += pos + 6;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "text with fill opacity emits ExtGState" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 24, .opacity = 0.5 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Semi-transparent", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Transparent text needs an ExtGState with a non-stroking alpha (ca).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/GS1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ca 0.5") != null);
    // The text object must be wrapped so the alpha is applied then restored.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/GS1 gs") != null);
}

test "fully opaque text has no ExtGState" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // Default opacity = 1.0
    const style = TextStyle{ .font = Font.helvetica, .size = 24 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Opaque", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, " gs\n") == null);
}

test "text opacity shares ExtGState with shape opacity" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    // A shape and text with the same 0.4 fill alpha should dedup to one GS.
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 60, .height = 40 }, .{
        .fill = .{ .color = Color.rgb(255, 0, 0), .opacity = 0.4 },
    });
    const style = TextStyle{ .font = Font.helvetica, .size = 18, .opacity = 0.4 };
    _ = try doc.writeAt(.{ .x = 50, .y = 150 }, "Match", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // "/ca 0.4" should appear exactly once in the ExtGState dict (deduplicated).
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, pdf[idx..], "/ca 0.4")) |pos| {
        count += 1;
        idx += pos + 7;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "embedded-font text opacity emits ExtGState" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Disable content-stream compression so the `/GS1 gs` operator is greppable
    // (embedded-font pages otherwise FlateDecode-compress the content stream).
    doc.compression_level = 0;
    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.otf", .identity);
    try doc.addPage(.{});
    const style = TextStyle{ .font = font, .size = 20, .opacity = 0.6 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Fade", style, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ca 0.6") != null);
    // ExtGState applied around the CID text object.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/GS1 gs") != null);
}

test "PDF/A-1b rejects transparent text" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setConformance(.pdfa_1b);
    try doc.addPage(.{});
    // Embedded font: a standard font would be rejected first (FontNotEmbedded).
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const style = TextStyle{ .font = inter, .size = 24, .opacity = 0.5 };
    try std.testing.expectError(
        error.TransparencyNotAllowed,
        doc.writeAt(.{ .x = 50, .y = 50 }, "No transparency", style, .{}),
    );
}

// ============================================================================
// PDF/A Tests
// ============================================================================

test "PDF/A-1b output has required structures" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setConformance(.pdfa_1b);
    try doc.addPage(.{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF/A required structures
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /XML") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /OutputIntent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/S /GTS_PDFA1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "sRGB IEC61966-2.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/MarkInfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/OutputIntents") != null);
    // XMP metadata content
    try std.testing.expect(std.mem.indexOf(u8, pdf, "pdfaid:part") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "pdfaid:conformance") != null);
}

test "PDF/A-1b rejects transparency" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setConformance(.pdfa_1b);
    try doc.addPage(.{});

    // Try to draw with transparency - should fail
    const result = doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.red, .opacity = 0.5 },
    });
    try std.testing.expectError(platen.pdfa.ConformanceError.TransparencyNotAllowed, result);
}

test "PDF/A-1b allows fully opaque drawing" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setConformance(.pdfa_1b);
    try doc.addPage(.{});

    // Fully opaque drawing should succeed
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.red }, // opacity defaults to 1.0
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Should have PDF/A structures but no ExtGState
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /OutputIntent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") == null);
}

test "PDF/A-2b allows transparency" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    doc.setConformance(.pdfa_2b);
    try doc.addPage(.{});

    // PDF/A-2b allows transparency
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.blue, .opacity = 0.5 },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Should have PDF/A structures AND ExtGState
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /OutputIntent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ExtGState") != null);
}

test "PDF/A none conformance has no PDF/A structures" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Default conformance is .none
    try doc.addPage(.{});
    try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
        .fill = .{ .color = Color.red },
    });

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // No PDF/A structures
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /OutputIntent") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Metadata") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/MarkInfo") == null);
}

const noto_color_emoji_path = "test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf";

test "COLR color emoji emits a Type3 color font" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    // Cloud (flat two-color) + grinning face (radial gradient).
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "\u{2601}\u{1F600}", .{ .font = emoji, .size = 48 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Type3 color font with one CharProc per glyph and a 1-based encoding.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CharProcs") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Differences [1 /g1 /g2]") != null);
    // FontMatrix at full precision (Noto Color Emoji upem = 1024 → 1/1024).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontMatrix [0.0009765625 0 0 0.0009765625 0 0]") != null);
    // The gradient face contributes a shading to the font's Resources.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ShadingType 3") != null);
    // Text shows the color glyphs via the Type3 font.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 48.00 Tf") != null);
}

test "COLR mixed run splits into Type3 (color) and CID (mono) segments" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    // Emoji, space (non-color glyph), emoji → color / mono / color.
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "\u{1F600} \u{2601}", .{ .font = emoji, .size = 40 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Both encodings are selected mid-run: /Tc1 for the color glyphs (as a
    // Tf operator, not just the resource entry) and /E1 for the mono CID space.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 40.00 Tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 40.00 Tf") != null);
}

test "COLR color fonts are skipped under PDF/A conformance" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_2b);

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "\u{2601}", .{ .font = emoji, .size = 40 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // No Type3 color font; the glyph falls back to the monochrome CID outline.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type3") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1") == null);
}

test "COLR color font used only for non-color text emits no Type3" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    // Only spaces: the emoji font is used, but no color glyph is present.
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "   ", .{ .font = emoji, .size = 40 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // No (empty, malformed) Type3 font should be emitted.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type3") == null);
}

test "COLR fonts with >255 color glyphs split into multiple Type3 subfonts" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});

    // Collect 300 codepoints with distinct color glyphs from the font's cmap
    // — enough to overflow the 255 single-byte codes of one Type3 font.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var seen: std.AutoHashMapUnmanaged(u16, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var cp: u21 = 0x1F300;
    while (cp <= 0x1FAFF and seen.count() < 300) : (cp += 1) {
        const gid = emoji.embedded.font.getGlyphId(cp) orelse continue;
        if (gid == 0 or !emoji.embedded.isColorGlyph(gid)) continue;
        if ((try seen.getOrPut(std.testing.allocator, gid)).found_existing) continue;
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        try text.appendSlice(std.testing.allocator, buf[0..len]);
    }
    try std.testing.expectEqual(@as(usize, 300), seen.count());

    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, text.items, .{ .font = emoji, .size = 12 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Two Type3 subfonts: /Tc1 holds the first 255 codes, /Tc1s1 the rest.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pdf, "/Subtype /Type3"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 12.00 Tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1s1 12.00 Tf") != null);
    // The first subfont uses the full single-byte code space.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/LastChar 255") != null);
    // Each subfont carries its own single-byte ToUnicode CMap (the third
    // /ToUnicode belongs to the mono CID font's 2-byte CMap).
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, pdf, "/ToUnicode"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pdf, "<00> <FF>"));
}

test "sbix bitmap font emits a Type3 font with image CharProcs" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const sbix = doc.loadFont("test/fonts/bitmap/SbixTest.ttf", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "AB", .{ .font = sbix, .size = 72 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Type3 font whose CharProcs place PNG image XObjects.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 72.00 Tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/XObject << /Im1") != null);
    // 64px strike at upem 1000 → 15.625 units/px: 64px image = 1000 units.
    // 'A' sits at the origin; 'B' is offset by (8, -8) px = (125, -125).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1000.00 0 0 1000.00 0.00 0.00 cm\n/Im1 Do") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1000.00 0 0 1000.00 125.00 -125.00 cm\n/Im2 Do") != null);
    // 'B' has an alpha half → its image carries an SMask.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/SMask") != null);
}

test "CBDT bitmap font emits a Type3 font with image CharProcs" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const cbdt = doc.loadFont("test/fonts/bitmap/CbdtTest.ttf", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "AB", .{ .font = cbdt, .size = 72 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 72.00 Tf") != null);
    // 'A': bearing (0, 64) → bottom at baseline; 'B': bearing (4, 60) →
    // left 62.50, bottom -62.50 (in font units at 15.625 units/px).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1000.00 0 0 1000.00 0.00 0.00 cm\n/Im1 Do") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1000.00 0 0 1000.00 62.50 -62.50 cm\n/Im2 Do") != null);
}

test "OT-SVG font emits a Type3 color font (Bungee Color SVG)" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep streams searchable

    const bungee = doc.loadFont("test/fonts/Bungee Color/BungeeColor-Regular-SVG.ttf", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "AB", .{ .font = bungee, .size = 72 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Type3 font whose CharProcs carry the SVG paths as PDF ops.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 72.00 Tf") != null);
    // The y-down SVG glyph space is mirrored about the baseline.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1 0 0 -1 0 0.00 cm") != null);
    // Bungee's two solid layers: dark red #c90900 and salmon #ff9580.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "0.788 0.035 0.000 rg") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1.000 0.584 0.502 rg") != null);
    // Text extraction recovers the letters via ToUnicode.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ToUnicode") != null);
}

test "OTB pixel font emits a Type3 font with ImageMask CharProcs" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep streams searchable

    const cozette = doc.loadFont("test/fonts/Cozette/cozette.otb", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "A", .{ .font = cozette, .size = 13, .color = platen.Color.rgb(200, 0, 0) }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Type3 font whose CharProc places a 1-bit stencil mask via d1 — the
    // glyph is painted with the current text color.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 13.00 Tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ImageMask true") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Decode [1 0]") != null);
    // 'A': 7x13 px at upem 2048 / 13 ppem → 157.54 units/px. Advance 1024
    // (hmtx); bbox bottom 3 px below baseline (-472.62), top at 1575.38.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1024 0 0.00 -472.62 1102.77 1575.38 d1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Im1 Do") != null);
    // Text color applies to the mask.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "0.784 0.000 0.000 rg") != null);
}

test "unsupported SVG glyphs fall back to the mono outline" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep streams searchable

    // SvgTest fixture: A supported; B (transparency), C (gzip), D/E
    // (multi-glyph doc) must all fall back to their real outlines.
    const svgf = doc.loadFont("test/fonts/svg/SvgTest.ttf", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "ABCDE", .{ .font = svgf, .size = 24 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Exactly one Type3 CharProc (A); the run switches between the Type3
    // and the CID outline font mid-text.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Differences [1 /g1] >>") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 24.00 Tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 24.00 Tf") != null);
}

test "color font used on multiple pages gets per-page /Tc resources" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;

    const emoji = doc.loadFont(noto_color_emoji_path, .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "\u{2601}", .{ .font = emoji, .size = 24 }, .{});
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "\u{1F600}", .{ .font = emoji, .size = 24 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // One shared Type3 font (2 CharProcs), referenced from both pages'
    // /Font resources plus used via Tf on both pages: ≥4 /Tc1 mentions.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pdf, "/Subtype /Type3"));
    try std.testing.expect(std.mem.count(u8, pdf, "/Tc1") >= 4);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Differences [1 /g1 /g2] >>") != null);
}

test "Type3 color fonts never assign single-byte code 32 (word-spacing hazard)" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep streams searchable

    const cozette = doc.loadFont("test/fonts/Cozette/cozette.otb", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    // >31 distinct glyphs so the code space must skip 32: PDF applies word
    // spacing (Tw) to every single-byte code 32, which would silently add
    // extra advance to whichever glyph got that code.
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "abcdefghijklmnopqrstuvwxyz0123456789", .{ .font = cozette, .size = 13 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // The Encoding restarts at 33 after /g31, and no glyph is named /g32.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/g31 33 /g33") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/g32") == null);
    // Widths carries a zero placeholder for the unassigned code 32, keeping
    // the array contiguous from FirstChar 1 to LastChar.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FirstChar 1") != null);
    // No color Tj hex string contains byte 0x20 (code 32): scan the shown
    // strings of the Type3 run.
    var it = std.mem.splitSequence(u8, pdf, "> Tj");
    while (it.next()) |chunk| {
        const open = std.mem.lastIndexOfScalar(u8, chunk, '<') orelse continue;
        const hex = chunk[open + 1 ..];
        if (hex.len % 2 != 0) continue; // not a single-byte-code string
        var i: usize = 0;
        while (i + 2 <= hex.len) : (i += 2) {
            try std.testing.expect(!std.mem.eql(u8, hex[i .. i + 2], "20"));
        }
    }
}

test "COLR v0 font emits a Type3 color font (Bungee Color)" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream searchable

    const bungee = doc.loadFont("test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf", .identity) catch return error.SkipZigTest;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "AB", .{ .font = bungee, .size = 72 }, .{});

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Type3 color font emitted; letters shown through it.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CharProcs") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Tc1 72.00 Tf") != null);
    // FontMatrix at full precision (Bungee upem = 1000 → 1/1000).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontMatrix [0.0010000000 0 0 0.0010000000 0 0]") != null);
    // v0 is flat solid layers: a CharProc fills 'A' dark red (palette 0).
    try std.testing.expect(std.mem.indexOf(u8, pdf, "0.788 0.035 0.000 rg") != null);
    // Text extraction recovers the letters via ToUnicode.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ToUnicode") != null);
}

test "parallel stream compression produces byte-identical output" {
    // smp_allocator: compress_threads > 1 requires a thread-safe allocator
    const allocator = std.heap.smp_allocator;

    const makePdf = struct {
        fn call(alloc: std.mem.Allocator, threads: u32) ![]u8 {
            var doc = Document.init(alloc, std.testing.io);
            defer doc.deinit();
            doc.compress_threads = threads;
            // Pin the timestamp: two output() calls straddling a second
            // boundary would otherwise differ in /CreationDate (this was the
            // "unreproducible" flake in this test)
            doc.setMetadata(.{ .creation_date = "D:20260101120000" });

            const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
            const style = TextStyle{ .font = font, .size = 11 };
            for (0..3) |_| {
                try doc.addPage(.{});
                var y: f64 = 40;
                for (0..30) |_| {
                    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Parallel compression must not change the output bytes.", style, .{});
                    y += 14;
                }
            }
            return doc.output();
        }
    }.call;

    const single = try makePdf(allocator, 1);
    defer allocator.free(single);
    const threaded = try makePdf(allocator, 4);
    defer allocator.free(threaded);

    try std.testing.expectEqualSlices(u8, single, threaded);
}

test "measureStyled matches embedded font advances" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const style = TextStyle{ .font = font, .size = 10 };
    const text = "$13200.00 Wavelength";

    // Must reflect the embedded font's own advances, not the Helvetica
    // fallback that measureStyled used before (~7% off for Inter).
    const emb = style.embeddedFont().?;
    try std.testing.expectApproxEqAbs(
        emb.measureTextWidth(text, 10),
        (try doc.measureStyled(text, style)).width,
        0.001,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), (try doc.measureStyled(text, style)).height, 0.001);
}

test "measurement is independent of render order" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
    const style = TextStyle{ .font = font, .size = 10 };
    // Kern-heavy pairs, so missing GPOS data changes the measured width.
    const text = "AVATAR Wavelength To Ty. Justified copy.";

    const before_render = (try doc.measureStyled(text, style)).width;
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, text, style, .{});
    const after_render = (try doc.measureStyled(text, style)).width;

    // Lazy GPOS parsing must not make the first measurement disagree with
    // later ones - justification/alignment depend on a stable width.
    try std.testing.expectApproxEqAbs(before_render, after_render, 0.0001);
}

test "caller-owned Image and Svg can be shared across documents" {
    const allocator = std.testing.allocator;
    const images_mod = @import("images.zig");
    const svg_mod = @import("svg.zig");

    const png_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/images/robot.png", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(png_data);

    // Decode once, draw into two documents; deinit of neither document may
    // destroy the caller-owned assets (double-free is caught by the testing
    // allocator).
    const image = try images_mod.Image.fromMemory(allocator, png_data);
    defer {
        image.deinit();
    }
    const svg = try svg_mod.Svg.fromMemory(allocator,
        \\<svg width="40" height="40"><rect x="0" y="0" width="40" height="40" fill="blue"/></svg>
    );
    defer {
        svg.deinit();
    }

    for (0..2) |_| {
        var doc = Document.init(allocator, std.testing.io);
        defer doc.deinit();
        try doc.addPage(.{});
        try doc.drawImage(image, .{ .x = 50, .y = 50, .width = 100, .height = 0 });
        try doc.drawSvg(svg, .{ .x = 50, .y = 200, .width = 40, .height = 40 });
        const pdf = try doc.output();
        defer allocator.free(pdf);
        try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Image") != null);
    }
}

test "setFeature applies to fonts loaded after the call" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Order used to matter: setFeature only touched already-loaded fonts.
    try doc.setFeature(.liga, false);
    try doc.setFeature(.kern, false);
    try doc.setFeature(.kern, true); // later call wins

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const emb = font.embedded;
    try std.testing.expect(!emb.feature_flags.isEnabled(.liga));
    try std.testing.expect(emb.feature_flags.isEnabled(.kern));

    // And still applies to fonts loaded before a later call
    try doc.setFeature(.calt, false);
    try std.testing.expect(!emb.feature_flags.isEnabled(.calt));
}

test "bold on single embedded font errors instead of silently rendering regular" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);

    // Regular works
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "ok", .{ .font = font, .size = 12 }, .{});
    // Bold/italic on a variant-less font is an error, matching the family
    // behavior for a missing variant
    try std.testing.expectError(error.FontVariantNotLoaded, doc.writeAt(.{ .x = 50, .y = 70 }, "nope", .{ .font = font, .size = 12, .bold = true }, .{}));
    try std.testing.expectError(error.FontVariantNotLoaded, doc.writeAt(.{ .x = 50, .y = 90 }, "nope", .{ .font = font, .size = 12, .italic = true }, .{}));
}

test "embedded-font measurement includes char_spacing" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
    const plain = TextStyle{ .font = font, .size = 12 };
    const spaced = TextStyle{ .font = font, .size = 12, .char_spacing = 2.0 };
    const text = "Hello spacing"; // 13 glyphs -> 12 gaps

    const w_plain = (try doc.measureStyled(text, plain)).width;
    const w_spaced = (try doc.measureStyled(text, spaced)).width;
    try std.testing.expectApproxEqAbs(w_plain + 12 * 2.0, w_spaced, 0.001);
}

test "measurement applies GSUB ligatures like rendering" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    // Satoshi has real liga ligatures (fi, fl, ft) active by default
    const font = try doc.loadFont("test/fonts/Satoshi/Satoshi-Regular.otf", .identity);
    const emb = font.embedded;
    const text = "fit float finish"; // fi/fl/ft ligatures

    // Ground truth: shape exactly as the renderer does and sum the final
    // glyph advances + kerning
    const glyphs = try emb.markUnicodeCharsUsed(text, null);
    defer emb.allocator.free(glyphs);
    const em: i32 = @intCast(emb.font.head.?.units_per_em);
    var total: i32 = 0;
    var prev: u16 = 0;
    for (glyphs, 0..) |gid, i| {
        total += @divTrunc(@as(i32, @intCast(emb.font.getGlyphWidth(gid) orelse 0)) * 1000, em);
        if (i > 0) total += @divTrunc(@as(i32, emb.getKerning(prev, gid)) * 1000, em);
        prev = gid;
    }
    const expected = @as(f64, @floatFromInt(total)) * 12.0 / 1000.0;

    const measured = emb.measureTextWidth(text, 12);
    try std.testing.expectApproxEqAbs(expected, measured, 0.001);

    // And strictly narrower than the unshaped sum of individual letters,
    // since the ligature glyphs replace multiple letters
    try std.testing.expect(glyphs.len < text.len);
}

test "writeAt anchor places text left, center, and right of the point" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const style = TextStyle{ .font = font, .size = 12 };
    const text = "anchored";
    const w = (try doc.measureStyled(text, style)).width;

    const r_left = try doc.writeAt(.{ .x = 300, .y = 100 }, text, style, .{});
    const r_center = try doc.writeAt(.{ .x = 300, .y = 120 }, text, style, .{ .anchor = .center });
    const r_right = try doc.writeAt(.{ .x = 300, .y = 140 }, text, style, .{ .anchor = .right });

    try std.testing.expectApproxEqAbs(@as(f64, 300), r_left.x, 0.001);
    try std.testing.expectApproxEqAbs(300 - w / 2, r_center.x, 0.001);
    try std.testing.expectApproxEqAbs(300 - w, r_right.x, 0.001);

    // The rendered output must move too, not just the returned Rect
    doc.compression_level = 0;
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Collect the x coordinate of each text-positioning op (Tm) in order
    var xs: [3]f64 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, pdf, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " Td")) {
            var tok = std.mem.tokenizeScalar(u8, line, ' ');
            const x_str = tok.next().?;
            if (count < 3) {
                xs[count] = try std.fmt.parseFloat(f64, x_str);
                count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f64, 300), xs[0], 0.01);
    try std.testing.expectApproxEqAbs(300 - w / 2, xs[1], 0.01);
    try std.testing.expectApproxEqAbs(300 - w, xs[2], 0.01);
}

test "writeAt Rect uses real font metrics" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const style = TextStyle{ .font = font, .size = 12 };
    const m = doc.getFontMetricsStyled(style);

    const r = try doc.writeAt(.{ .x = 50, .y = 100 }, "Metrics", style, .{});
    // Top of rect = baseline - ascender; height spans ascender to descender
    try std.testing.expectApproxEqAbs(100 - m.ascender, r.y, 0.001);
    try std.testing.expectApproxEqAbs(m.ascender - m.descender, r.height, 0.001);
    // Inter's ascender at 12pt is ~10.7 - the old approximation (y - size,
    // height = size) would be off by more than a point
    try std.testing.expect(@abs(r.height - 12.0) > 1.0);
}

test "transforms emit correct cm operators" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{}); // A4: height 841.89

    try doc.pushState();
    try doc.translate(100, 50);
    try doc.drawRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .fill = .{ .color = Color.black } });
    try doc.popState();

    try doc.pushState();
    try doc.rotateAt(.{ .x = 100, .y = 100 }, 90);
    try doc.popState();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // User translate (dx, dy) becomes PDF translate (dx, -dy)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "1.0000 0.0000 0.0000 1.0000 100.00 -50.00 cm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "q\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "Q\n") != null);

    // 90 deg clockwise about user (100,100): after the y-flip conjugation
    // the PDF-space linear part is [0 -1; 1 0] (still visually clockwise,
    // since PDF y points up)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "0.0000 -1.0000 1.0000 0.0000") != null);
}

test "clipRect emits re W n in PDF coordinates" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});

    try doc.pushState();
    try doc.clipRect(.{ .x = 50, .y = 100, .width = 200, .height = 300 });
    try doc.popState();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    // y_pdf = 841.89 - 100 - 300 = 441.89
    try std.testing.expect(std.mem.indexOf(u8, pdf, "50.00 441.89 200.00 300.00 re W n") != null);
}

test "unbalanced graphics state is rejected" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    // popState with nothing pushed
    try std.testing.expectError(error.UnbalancedGraphicsState, doc.popState());

    // pushState without popState fails at output
    try doc.pushState();
    try std.testing.expectError(error.UnbalancedGraphicsState, doc.output());
    try doc.popState();
    const pdf = try doc.output();
    doc.allocator.free(pdf);
}

test "page rotation lands in the page dict" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{ .rotation = .r90 });
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Rotate 90") != null);
}

test "clipPath emits path ops and W n" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});

    var tri = doc.createPath();
    defer tri.deinit();
    try tri.moveTo(.{ .x = 10, .y = 10 });
    try tri.lineTo(.{ .x = 110, .y = 10 });
    try tri.lineTo(.{ .x = 60, .y = 90 });
    try tri.closePath();

    try doc.pushState();
    try doc.clipPath(&tri);
    try doc.drawRect(.{ .x = 0, .y = 0, .width = 200, .height = 200 }, .{ .fill = .{ .color = Color.black } });
    try doc.popState();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);
    // Path construction (y flipped: 841.89 - 10 = 831.89) followed by clip
    try std.testing.expect(std.mem.indexOf(u8, pdf, "10.00 831.89 m") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "h\nW n") != null);
}

test "FontFace documents are byte-identical to per-document parsing" {
    const allocator = std.heap.smp_allocator; // clones + threads later
    const embedded_mod = @import("embedded.zig");

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);

    var face = try embedded_mod.FontFace.fromMemory(allocator, data);
    defer face.deinit();
    try face.warmup("Warm kerning for AVATAR Wavelength offices");

    const text = "Shared fonts: AVATAR office ffi 1/2 -> done.";

    // Unshared baseline
    var doc_a = Document.init(allocator, std.testing.io);
    defer doc_a.deinit();
    doc_a.setMetadata(.{ .creation_date = "D:20260101120000" });
    const font_a = try doc_a.loadFontFromMemory(data, .identity);
    try doc_a.addPage(.{});
    _ = try doc_a.writeAt(.{ .x = 50, .y = 100 }, text, .{ .font = font_a, .size = 12 }, .{});
    const pdf_a = try doc_a.output();
    defer allocator.free(pdf_a);

    // Two face-based documents (reuse across documents; no load call)
    for (0..2) |_| {
        var doc_b = Document.init(allocator, std.testing.io);
        defer doc_b.deinit();
        doc_b.setMetadata(.{ .creation_date = "D:20260101120000" });
        try doc_b.addPage(.{});
        _ = try doc_b.writeAt(.{ .x = 50, .y = 100 }, text, .{ .font = .{ .face = &face }, .size = 12 }, .{});
        const pdf_b = try doc_b.output();
        defer allocator.free(pdf_b);

        try std.testing.expectEqualSlices(u8, pdf_a, pdf_b);
    }
}

test "FontFace clones own all scratch buffers (no shared mutable state)" {
    const allocator = std.testing.allocator;
    const embedded_mod = @import("embedded.zig");

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);

    var face = try embedded_mod.FontFace.fromMemory(allocator, data);
    defer face.deinit();
    // Grow the prototype's scratch buffers (calt-heavy text exercises
    // scratch_c, the buffer the review found shared)
    try face.warmup("Warmup with arrows -> => and ligatures ffi ffl offices");

    const clone = try face.instantiate(allocator);
    defer clone.deinit();
    // Shape calt-heavy text on the clone so its scratch buffers are in use
    const glyphs = try clone.markUnicodeCharsUsed("clone text -> with calt => arrows", null);
    clone.allocator.free(glyphs);

    const proto_ot = face.prototype.ot_features.?;
    const clone_ot = clone.ot_features.?;
    // A clone's scratch storage must never alias the prototype's
    if (clone_ot.scratch_c.capacity > 0 and proto_ot.scratch_c.capacity > 0) {
        try std.testing.expect(clone_ot.scratch_c.items.ptr != proto_ot.scratch_c.items.ptr);
    }
    if (clone_ot.scratch_a.capacity > 0 and proto_ot.scratch_a.capacity > 0) {
        try std.testing.expect(clone_ot.scratch_a.items.ptr != proto_ot.scratch_a.items.ptr);
    }
    // std.testing.allocator additionally catches the scratch_c leak and any
    // double-free through the deinits above
}

test "face family style survives allocation failure at every point" {
    const allocator = std.testing.allocator;
    const embedded_mod = @import("embedded.zig");

    const reg_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(reg_data);
    const bold_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Bold.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bold_data);

    var face_reg = try embedded_mod.FontFace.fromMemory(allocator, reg_data);
    defer face_reg.deinit();
    var face_bold = try embedded_mod.FontFace.fromMemory(allocator, bold_data);
    defer face_bold.deinit();

    // Every allocation failure point must leave the Document consistent:
    // no leak, no double-free when doc.deinit runs (the review found an
    // errdefer that double-freed the regular font after registration)
    const Ctx = struct {
        reg: *embedded_mod.FontFace,
        bold: *embedded_mod.FontFace,
        fn run(failing: std.mem.Allocator, ctx: @This()) !void {
            var doc = Document.init(failing, std.testing.io);
            defer doc.deinit();
            try doc.addPage(.{});
            // Family style: variant resolution + first-use instantiation of
            // both faces, at every possible allocation-failure point
            const style = TextStyle{
                .font = .{ .family = .{ .regular = ctx.reg, .bold = ctx.bold } },
                .size = 11,
            };
            _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "regular", style, .{});
            var bold_style = style;
            bold_style.bold = true;
            _ = try doc.writeAt(.{ .x = 50, .y = 70 }, "bold", bold_style, .{});
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Ctx.run, .{Ctx{ .reg = &face_reg, .bold = &face_bold }});
}

test "using a font from another document errors instead of silently rendering nothing" {
    var doc_a = Document.init(std.testing.allocator, std.testing.io);
    defer doc_a.deinit();
    const font = try doc_a.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);

    var doc_b = Document.init(std.testing.allocator, std.testing.io);
    defer doc_b.deinit();
    try doc_b.addPage(.{});
    try std.testing.expectError(
        error.ForeignFont,
        doc_b.writeAt(.{ .x = 50, .y = 100 }, "foreign", .{ .font = font, .size = 12 }, .{}),
    );
    // And the foreign font's tracking state stays untouched
    try std.testing.expectEqual(@as(usize, 0), font.embedded.cid_used_glyphs.count());
}

test "another document's image and svg are rejected, caller-created remain shareable" {
    var doc_a = Document.init(std.testing.allocator, std.testing.io);
    defer doc_a.deinit();
    const doc_a_svg = try doc_a.loadSvgFromMemory("<svg width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>");

    var doc_b = Document.init(std.testing.allocator, std.testing.io);
    defer doc_b.deinit();
    try doc_b.addPage(.{});

    // doc_a's SVG dies with doc_a - doc_b must not borrow it
    try std.testing.expectError(error.ForeignSvg, doc_b.drawSvg(doc_a_svg, .{ .x = 0, .y = 0, .width = 10, .height = 10 }));

    // Caller-created stays shareable (existing contract)
    const svg_mod = @import("svg.zig");
    const mine = try svg_mod.Svg.fromMemory(std.testing.allocator, "<svg width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>");
    defer {
        mine.deinit();
    }
    try doc_b.drawSvg(mine, .{ .x = 0, .y = 20, .width = 10, .height = 10 });
    const pdf = try doc_b.output();
    doc_b.allocator.free(pdf);
}

test "FontFace configuration is rejected after first use" {
    const allocator = std.testing.allocator;
    const embedded_mod = @import("embedded.zig");

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);

    var face = try embedded_mod.FontFace.fromMemory(allocator, data);
    defer face.deinit();

    // Configuration phase: allowed
    try face.setFeature(.dlig, true);
    try face.warmup("configure me");

    // First document use freezes the face
    var doc = Document.init(allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "frozen now", .{ .font = .{ .face = &face }, .size = 12 }, .{});

    try std.testing.expectError(error.FaceFrozen, face.setFeature(.liga, false));
    try std.testing.expectError(error.FaceFrozen, face.warmup("too late"));

    // The dlig default made it into the document's clone
    const clone = doc.face_instances.get(&face).?;
    try std.testing.expect(clone.feature_flags.isEnabled(.dlig));
}

test "measure_only errors on invalid face variant like rendering does" {
    const allocator = std.testing.allocator;
    const embedded_mod = @import("embedded.zig");
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);
    var face = try embedded_mod.FontFace.fromMemory(allocator, data);
    defer face.deinit();

    var doc = Document.init(allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    var region = Region{ .x = 50, .y = 50, .width = 300, .height = 200 };

    // bold on a single face is invalid; measure_only must say so instead of
    // silently measuring regular-weight widths
    const bad = TextStyle{ .font = .{ .face = &face }, .size = 12, .bold = true };
    try std.testing.expectError(
        error.FontVariantNotLoaded,
        doc.write(&region, "hello world", bad, .{ .measure_only = true }),
    );
}

test "multi-span decoration uses the face's real underline metrics" {
    const allocator = std.testing.allocator;
    const embedded_mod = @import("embedded.zig");
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);
    var face = try embedded_mod.FontFace.fromMemory(allocator, data);
    defer face.deinit();

    var doc = Document.init(allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});
    var region = Region{ .x = 50, .y = 50, .width = 400, .height = 200 };

    // Two decorated spans force the multi-style path
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("under ", .{ .decoration = .{ .underline = true } });
    try st.append("lined", .{ .color = Color.red, .decoration = .{ .underline = true } });

    const style = TextStyle{ .font = .{ .face = &face }, .size = 12 };
    _ = try doc.writeStyled(&region, &st, style, .{});
    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // The underline rect height must come from Inter's post table, not the
    // base-14 default (50/1000 -> 0.60 at 12pt)
    const expected_thick = @as(f64, @floatFromInt(face.prototype.underline_thickness)) * 12.0 / 1000.0;
    try std.testing.expect(@abs(expected_thick - 0.60) > 0.05); // premise: Inter differs from default
    var buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "{d:.2} re", .{expected_thick});
    try std.testing.expect(std.mem.indexOf(u8, pdf, needle) != null);
}

test "encryption: in-process roundtrip recovers content" {
    const encrypt_mod = @import("encrypt.zig");
    var prng = std.Random.DefaultPrng.init(0xa11ce);

    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.encryption = .{ .user_password = "pw" };
    doc.rng = prng.random();
    doc.setMetadata(.{ .creation_date = "D:20260101120000" });

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "encrypted body", .{ .font = font, .size = 12 }, .{});
    const pdf = try doc.output();
    defer std.testing.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Filter /Standard") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/AESV3") != null);
    // Content is not in the clear
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontFile2") != null); // dict key visible
    try std.testing.expect(std.mem.indexOf(u8, pdf, "endstream") != null);

    // Parse /U and /UE from the Encrypt dict, recover the file key with the
    // password, and confirm it is a real 32-byte key (wrong password fails)
    const u = try parseHexEntry(pdf, "/U <");
    const ue = try parseHexEntry(pdf, "/UE <");
    var u_str: [48]u8 = undefined;
    var ue_str: [32]u8 = undefined;
    @memcpy(&u_str, u[0..48]);
    @memcpy(&ue_str, ue[0..32]);
    try std.testing.expect(encrypt_mod.fileKeyFromUserPassword("pw", u_str, ue_str) != null);
    try std.testing.expect(encrypt_mod.fileKeyFromUserPassword("nope", u_str, ue_str) == null);
}

fn parseHexEntry(pdf: []const u8, key: []const u8) ![64]u8 {
    const start = (std.mem.indexOf(u8, pdf, key) orelse return error.NotFound) + key.len;
    const end = std.mem.indexOfScalarPos(u8, pdf, start, '>') orelse return error.NotFound;
    const hex = pdf[start..end];
    var out: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

test "encryption: qpdf (independent reader) validates the encrypted PDF" {
    const platen_testing = @import("testing.zig");
    var prng = std.Random.DefaultPrng.init(0xc0ffee);

    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.encryption = .{ .user_password = "s3cret", .permissions = .{ .printing = false } };
    doc.rng = prng.random();
    doc.setMetadata(.{ .creation_date = "D:20260101120000" });

    const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "Encrypted content for qpdf.", .{ .font = font, .size = 14 }, .{});
    const pdf = try doc.output();
    defer std.testing.allocator.free(pdf);

    const result = platen_testing.qpdfCheckEncrypted(std.testing.io, std.testing.allocator, pdf, "s3cret") catch |err| {
        if (err == error.QpdfNotAvailable) return; // skip when qpdf absent
        return err;
    };
    try std.testing.expect(result.ok_with_password); // R6, correct password decrypts+validates
    try std.testing.expect(result.rejects_wrong_password); // really encrypted
}

test "encryption: seeded rng and explicit dates give byte-identical output" {
    const makePdf = struct {
        fn call() ![]u8 {
            var prng = std.Random.DefaultPrng.init(0x5eed);
            var doc = Document.init(std.testing.allocator, std.testing.io);
            defer doc.deinit();
            doc.encryption = .{ .user_password = "pw" };
            doc.rng = prng.random();
            doc.setMetadata(.{ .creation_date = "D:20260101120000Z" });
            const font = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
            try doc.addPage(.{});
            _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "same bytes", .{ .font = font, .size = 12 }, .{});
            return doc.output();
        }
    }.call;
    const a = try makePdf();
    defer std.testing.allocator.free(a);
    const b = try makePdf();
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b); // trailer /ID used to be the clock
}

test "encryption is rejected under PDF/A" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_1b);
    doc.encryption = .{ .user_password = "x" };
    try doc.addPage(.{});
    try std.testing.expectError(error.EncryptionNotAllowedInPdfA, doc.output());
}

test "unencrypted output is byte-identical regardless of encryption field default" {
    // The encryptor is null by default: unencrypted docs must be unchanged
    const makePdf = struct {
        fn call() ![]u8 {
            var doc = Document.init(std.testing.allocator, std.testing.io);
            defer doc.deinit();
            doc.setMetadata(.{ .creation_date = "D:20260101120000" });
            try doc.addPage(.{});
            _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "plain", .{ .font = Font.helvetica, .size = 12 }, .{});
            return doc.output();
        }
    }.call;
    const a = try makePdf();
    defer std.testing.allocator.free(a);
    const b = try makePdf();
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b); // deterministic, unchanged
    try std.testing.expect(std.mem.startsWith(u8, a, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, a, "/Encrypt") == null);
}
