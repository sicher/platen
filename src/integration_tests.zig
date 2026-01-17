//! Integration Tests
//!
//! Tests that generate PDFs and compare them against reference files.
//! These tests verify the complete PDF generation pipeline.

const std = @import("std");
const zpdf = @import("zpdf.zig");
const testing = @import("testing.zig");

/// Reference test case
const TestCase = struct {
    name: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
};

/// All integration test cases
const test_cases = [_]TestCase{
    .{ .name = "minimal", .generate = generateMinimalPdf },
    .{ .name = "hello_world", .generate = generateHelloWorldPdf },
    .{ .name = "multi_font", .generate = generateMultiFontPdf },
    .{ .name = "all_fonts", .generate = generateAllFontsPdf },
    .{ .name = "multi_page", .generate = generateMultiPagePdf },
    .{ .name = "embedded_fonts", .generate = generateEmbeddedFontsPdf },
};

// ============================================================================
// PDF Generation Functions
// ============================================================================

fn generateMinimalPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();
    try doc.addPage();
    return doc.output();
}

fn generateHelloWorldPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();
    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.textAt(50, 50, "Hello, World!");
    return doc.output();
}

fn generateMultiFontPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();
    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Helvetica Normal");

    try doc.setFont(.helvetica_bold, 12);
    try doc.textAt(50, 70, "Helvetica Bold");

    try doc.setFont(.times_roman, 12);
    try doc.textAt(50, 90, "Times Roman");

    try doc.setFont(.courier, 12);
    try doc.textAt(50, 110, "Courier");

    return doc.output();
}

fn generateAllFontsPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();
    try doc.addPage();

    const fonts = [_]zpdf.StandardFont{
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

    var y: f64 = 30;
    for (fonts) |font| {
        try doc.setFont(font, 10);
        try doc.textAt(50, y, font.pdfName());
        y += 15;
    }

    return doc.output();
}

fn generateMultiPagePdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.textAt(50, 50, "Page 1");

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.textAt(50, 50, "Page 2");

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.textAt(50, 50, "Page 3");

    return doc.output();
}

fn generateEmbeddedFontsPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Load font families
    const courier_regular = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    const courier_bold = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold.ttf");
    const courier_italic = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Italic.ttf");
    const courier_bold_italic = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold Italic.ttf");

    const charter_regular = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf");
    const charter_bold = try doc.loadFont("test/fonts/Charter/Charter Bold.ttf");
    const charter_italic = try doc.loadFont("test/fonts/Charter/Charter Italic.ttf");
    const charter_bold_italic = try doc.loadFont("test/fonts/Charter/Charter Bold Italic.ttf");

    try doc.addPage();
    var y: f64 = 50;

    // Large title
    try doc.setEmbeddedFont(charter_bold, 36);
    try doc.textAt(50, y, "Embedded Fonts");
    y += 50;

    // Courier Prime - all styles
    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.textAt(50, y, "Courier Prime Regular: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_bold, 12);
    try doc.textAt(50, y, "Courier Prime Bold: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_italic, 12);
    try doc.textAt(50, y, "Courier Prime Italic: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_bold_italic, 12);
    try doc.textAt(50, y, "Courier Prime Bold Italic: ABCabc 0123456789");
    y += 24;

    // Charter - all styles
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "Charter Regular: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_bold, 12);
    try doc.textAt(50, y, "Charter Bold: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_italic, 12);
    try doc.textAt(50, y, "Charter Italic: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_bold_italic, 12);
    try doc.textAt(50, y, "Charter Bold Italic: ABCabc 0123456789");
    y += 24;

    // Unicode - Latin Extended (WinAnsi compatible)
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "Extended Latin: \xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb \xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "More Latin: \xd1\xf1 \xd8\xf8 \xdf \xc6\xe6 \xd0\xf0 \xde\xfe \xbf\xa1");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "Currency: \xa3 \xa5 \xa2 \x83 | Math: \xb1 \xd7 \xf7 \xb0 \xb2 \xb3 \xb9 \xbc \xbd \xbe \xb5");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "Punctuation: \x91single\x92 \x93double\x94 \x96 \x97 \x85 \xab\xbb \xa9 \xae \x99");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.textAt(50, y, "Symbols: \xa7 \xb6 \x86 \x87 \x95 \xa6 \xac \xb7 \xaa \xba");
    y += 24;

    // Mixed standard and embedded
    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, y, "Helvetica (standard): ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    y += 16;
    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.textAt(50, y, "Courier Prime (embedded): ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    y += 24;

    // Large sizes
    try doc.setEmbeddedFont(charter_bold, 24);
    try doc.textAt(50, y, "24pt Charter Bold");
    y += 32;
    try doc.setEmbeddedFont(courier_regular, 18);
    try doc.textAt(50, y, "18pt Courier Prime Regular");
    y += 28;

    // Character set
    try doc.setEmbeddedFont(courier_regular, 10);
    try doc.textAt(50, y, "!\"#$%&'()*+,-./0123456789:;<=>?@[\\]^_`{|}~");

    return doc.output();
}

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: minimal PDF" {
    try runIntegrationTest("minimal", generateMinimalPdf);
}

test "integration: hello_world PDF" {
    try runIntegrationTest("hello_world", generateHelloWorldPdf);
}

test "integration: multi_font PDF" {
    try runIntegrationTest("multi_font", generateMultiFontPdf);
}

test "integration: all_fonts PDF" {
    try runIntegrationTest("all_fonts", generateAllFontsPdf);
}

test "integration: multi_page PDF" {
    try runIntegrationTest("multi_page", generateMultiPagePdf);
}

test "integration: embedded_fonts PDF" {
    try runIntegrationTest("embedded_fonts", generateEmbeddedFontsPdf);
}

fn runIntegrationTest(
    name: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
) !void {
    const allocator = std.testing.allocator;

    // Generate PDF
    const pdf = try generate(allocator);
    defer allocator.free(pdf);

    // Build reference path
    var path_buf: [256]u8 = undefined;
    const ref_path = std.fmt.bufPrint(&path_buf, "test/reference/{s}.pdf", .{name}) catch unreachable;

    // Compare against reference
    var result = try testing.compareWithReference(allocator, pdf, ref_path);
    defer result.deinit();

    if (!result.equal) {
        std.debug.print("\n=== Integration test failed: {s} ===\n", .{name});
        if (result.diff) |diff| {
            std.debug.print("{s}\n", .{diff});
        }
        return error.TestFailed;
    }
}

// Export test cases for CLI use
pub const cases = test_cases;
pub const Case = TestCase;
