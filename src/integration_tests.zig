//! Integration Tests
//!
//! Tests that generate PDFs and compare them against reference files.
//! These tests verify the complete PDF generation pipeline.

const std = @import("std");
const zpdf = @import("zpdf.zig");
const testing = @import("testing.zig");
const embedded = @import("embedded.zig");

/// Reference test case
const TestCase = struct {
    name: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
};

/// All integration test cases (compared against fpdf2 references)
const test_cases = [_]TestCase{
    .{ .name = "minimal", .generate = generateMinimalPdf },
    .{ .name = "hello_world", .generate = generateHelloWorldPdf },
    .{ .name = "multi_font", .generate = generateMultiFontPdf },
    .{ .name = "all_fonts", .generate = generateAllFontsPdf },
    .{ .name = "multi_page", .generate = generateMultiPagePdf },
    .{ .name = "embedded_fonts", .generate = generateEmbeddedFontsPdf },
    .{ .name = "cid_fonts", .generate = generateCIDFontsPdf },
    .{ .name = "inter_fonts", .generate = generateInterFontsPdf },
    .{ .name = "gentium_diacritics", .generate = generateGentiumDiacriticsPdf },
    .{ .name = "opentype_features", .generate = generateOpenTypeFeaturessPdf },
    .{ .name = "text_flow", .generate = generateTextFlowPdf },
    .{ .name = "justify", .generate = generateJustifyPdf },
    .{ .name = "optimal_breaks", .generate = generateOptimalBreaksPdf },
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
    try doc.writeAt(50, 50, "Hello, World!");
    return doc.output();
}

fn generateMultiFontPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();
    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, 50, "Helvetica Normal");

    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(50, 70, "Helvetica Bold");

    try doc.setFont(.times_roman, 12);
    try doc.writeAt(50, 90, "Times Roman");

    try doc.setFont(.courier, 12);
    try doc.writeAt(50, 110, "Courier");

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
        try doc.writeAt(50, y, font.pdfName());
        y += 15;
    }

    return doc.output();
}

fn generateMultiPagePdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.writeAt(50, 50, "Page 1");

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.writeAt(50, 50, "Page 2");

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.writeAt(50, 50, "Page 3");

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
    try doc.writeAt(50, y, "Embedded Fonts");
    y += 50;

    // Courier Prime - all styles
    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.writeAt(50, y, "Courier Prime Regular: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_bold, 12);
    try doc.writeAt(50, y, "Courier Prime Bold: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_italic, 12);
    try doc.writeAt(50, y, "Courier Prime Italic: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(courier_bold_italic, 12);
    try doc.writeAt(50, y, "Courier Prime Bold Italic: ABCabc 0123456789");
    y += 24;

    // Charter - all styles
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "Charter Regular: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_bold, 12);
    try doc.writeAt(50, y, "Charter Bold: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_italic, 12);
    try doc.writeAt(50, y, "Charter Italic: The quick brown fox jumps over the lazy dog.");
    y += 16;
    try doc.setEmbeddedFont(charter_bold_italic, 12);
    try doc.writeAt(50, y, "Charter Bold Italic: ABCabc 0123456789");
    y += 24;

    // Unicode - Latin Extended (WinAnsi compatible)
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "Extended Latin: \xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb \xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "More Latin: \xd1\xf1 \xd8\xf8 \xdf \xc6\xe6 \xd0\xf0 \xde\xfe \xbf\xa1");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "Currency: \xa3 \xa5 \xa2 \x83 | Math: \xb1 \xd7 \xf7 \xb0 \xb2 \xb3 \xb9 \xbc \xbd \xbe \xb5");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "Punctuation: \x91single\x92 \x93double\x94 \x96 \x97 \x85 \xab\xbb \xa9 \xae \x99");
    y += 16;
    try doc.setEmbeddedFont(charter_regular, 12);
    try doc.writeAt(50, y, "Symbols: \xa7 \xb6 \x86 \x87 \x95 \xa6 \xac \xb7 \xaa \xba");
    y += 24;

    // Mixed standard and embedded
    try doc.setFont(.helvetica, 12);
    try doc.writeAt(50, y, "Helvetica (standard): ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    y += 16;
    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.writeAt(50, y, "Courier Prime (embedded): ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    y += 24;

    // Large sizes
    try doc.setEmbeddedFont(charter_bold, 24);
    try doc.writeAt(50, y, "24pt Charter Bold");
    y += 32;
    try doc.setEmbeddedFont(courier_regular, 18);
    try doc.writeAt(50, y, "18pt Courier Prime Regular");
    y += 28;

    // Character set
    try doc.setEmbeddedFont(courier_regular, 10);
    try doc.writeAt(50, y, "!\"#$%&'()*+,-./0123456789:;<=>?@[\\]^_`{|}~");

    return doc.output();
}

fn generateCIDFontsPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Load fonts and set to CID (Identity-H) mode for full Unicode
    // Disable kerning to match fpdf2 reference (which uses text() without shaping)
    const charter = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf");
    charter.encoding = .identity;
    charter.setFeature(.kern, false);

    const courier = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    courier.encoding = .identity;
    courier.setFeature(.kern, false);

    try doc.addPage();
    var y: f64 = 50;

    // Title (using CID font)
    try doc.setEmbeddedFont(charter, 24);
    try doc.writeAt(50, y, "CID Font Test (Identity-H Encoding)");
    y += 40;

    // Basic ASCII text
    try doc.setEmbeddedFont(charter, 12);
    try doc.writeAt(50, y, "ASCII: The quick brown fox jumps over the lazy dog.");
    y += 20;

    // UTF-8 encoded Unicode characters (Latin Extended)
    try doc.writeAt(50, y, "Latin Extended: ÀÁÂÃÄÅÆÇÈÉÊË àáâãäåæçèéêë");
    y += 20;

    // More Latin characters via UTF-8
    try doc.writeAt(50, y, "More Latin: Ññ Øø ß Ææ Ðð Þþ ¿¡ Œœ");
    y += 20;

    // Currency and math symbols (only those in Charter font)
    try doc.writeAt(50, y, "Symbols: £ ¥ ¢ ± × ÷ ° ² ³ ¹ ¼ ½ ¾");
    y += 20;

    // Punctuation (using escape sequences for curly quotes, only those in Charter)
    try doc.writeAt(50, y, "Punctuation: \xe2\x80\x98single\xe2\x80\x99 \xe2\x80\x9cdouble\xe2\x80\x9d \xe2\x80\x93 \xe2\x80\x94 \xe2\x80\xa6 \xc2\xab \xc2\xbb \xc2\xa9 \xc2\xae");
    y += 20;

    // Mixed with Courier Prime
    try doc.setEmbeddedFont(courier, 12);
    try doc.writeAt(50, y, "Courier (CID): ABCDabcd 0123456789 £¥");
    y += 24;

    // Compare with WinAnsi mode (should look the same for basic chars)
    const charter_winansi = try doc.loadFont("test/fonts/Charter/Charter Bold.ttf");
    charter_winansi.setFeature(.kern, false);
    // Default is .win_ansi

    try doc.setEmbeddedFont(charter_winansi, 12);
    try doc.writeAt(50, y, "WinAnsi comparison: The quick brown fox");
    y += 20;

    try doc.setEmbeddedFont(charter, 12);
    try doc.writeAt(50, y, "CID comparison: The quick brown fox");

    return doc.output();
}

fn generateInterFontsPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Load all font variants
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter.encoding = .identity;
    const inter_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf");
    inter_bold.encoding = .identity;
    const inter_italic = try doc.loadFont("test/fonts/Inter/Inter-Italic.ttf");
    inter_italic.encoding = .identity;
    const inter_bolditalic = try doc.loadFont("test/fonts/Inter/Inter-BoldItalic.ttf");
    inter_bolditalic.encoding = .identity;

    // Feature comparison fonts
    const inter_no_kern = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_no_kern.encoding = .identity;
    inter_no_kern.setFeature(.kern, false);

    const inter_no_mark = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_no_mark.encoding = .identity;
    inter_no_mark.setFeature(.mark, false);
    inter_no_mark.setFeature(.mkmk, false);

    // Contextual alternates comparison (calt is ON by default now)
    const inter_no_calt = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_no_calt.encoding = .identity;
    inter_no_calt.setFeature(.calt, false);

    // Discretionary ligatures comparison (dlig is OFF by default)
    const inter_dlig = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_dlig.encoding = .identity;
    inter_dlig.setFeature(.dlig, true);

    // Tabular figures comparison (tnum is OFF by default - proportional is default)
    const inter_tnum = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_tnum.encoding = .identity;
    inter_tnum.setFeature(.tnum, true);

    // Fractions comparison (frac is OFF by default)
    const inter_frac = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_frac.encoding = .identity;
    inter_frac.setFeature(.frac, true);

    // Slashed zero comparison (zero is OFF by default)
    const inter_zero = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_zero.encoding = .identity;
    inter_zero.setFeature(.zero, true);

    // Case-sensitive forms comparison (case is OFF by default)
    const inter_case = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_case.encoding = .identity;
    inter_case.setFeature(.case, true);

    // Stylistic set 1 comparison (ss01 is OFF by default)
    const inter_ss01 = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_ss01.encoding = .identity;
    inter_ss01.setFeature(.ss01, true);

    try doc.addPage();
    var y: f64 = 32;

    // ===== Title =====
    try doc.setEmbeddedFont(inter_bold, 22);
    try doc.writeAt(50, y, "Inter Font Family");
    y += 32;

    // ===== Font Styles =====
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(50, y, "Regular: The quick brown fox jumps over the lazy dog.");
    y += 15;
    try doc.setEmbeddedFont(inter_bold, 11);
    try doc.writeAt(50, y, "Bold: The quick brown fox jumps over the lazy dog.");
    y += 15;
    try doc.setEmbeddedFont(inter_italic, 11);
    try doc.writeAt(50, y, "Italic: The quick brown fox jumps over the lazy dog.");
    y += 15;
    try doc.setEmbeddedFont(inter_bolditalic, 11);
    try doc.writeAt(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog.");
    y += 24;

    // ===== OpenType Features =====
    try doc.setEmbeddedFont(inter_bold, 13);
    try doc.writeAt(50, y, "OpenType Features");
    y += 20;

    // --- Kerning ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Kerning (kern)");
    y += 14;
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter_no_kern, 14);
    try doc.writeAt(78, y, "AV AWAY To Wave");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(240, y, "ON:");
    try doc.setEmbeddedFont(inter, 14);
    try doc.writeAt(262, y, "AV AWAY To Wave");
    y += 22;

    // --- Mark Positioning ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Mark Positioning (mark/mkmk)");
    y += 14;
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter_no_mark, 14);
    try doc.writeAt(78, y, "A\xcc\x80 E\xcc\x81 O\xcc\x83 N\xcc\x83");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(180, y, "ON:");
    try doc.setEmbeddedFont(inter, 14);
    try doc.writeAt(202, y, "A\xcc\x80 E\xcc\x81 O\xcc\x83 N\xcc\x83");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(310, y, "Stacked:");
    try doc.setEmbeddedFont(inter, 14);
    try doc.writeAt(358, y, "e\xcc\x82\xcc\x81 o\xcc\x82\xcc\x83 a\xcc\x86\xcc\x89");
    y += 20;
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(310, y, "Below+Above:");
    try doc.setEmbeddedFont(inter, 14);
    // s + cedilla (below) + acute (above), c + cedilla + circumflex, t + cedilla + tilde
    // Note: Inter font has proper anchors for cedilla but not for ogonek/dot-below
    try doc.writeAt(380, y, "s\xcc\xa7\xcc\x81 c\xcc\xa7\xcc\x82 t\xcc\xa7\xcc\x83");
    y += 22;

    // --- Contextual Alternates (calt) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Contextual Alternates (calt)");
    y += 14;
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter_no_calt, 12);
    try doc.writeAt(78, y, "-> => <- <=> 3*9 12:34 3\xe2\x80\x938 +8+x");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(310, y, "ON:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(332, y, "-> => <- <=> 3*9 12:34 3\xe2\x80\x938 +8+x");
    y += 18;

    // --- Discretionary Ligatures (dlig) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Discretionary Ligatures (dlig)");
    y += 14;
    // Interrobangs
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter, 14);
    try doc.writeAt(78, y, "!? ?!");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(140, y, "ON:");
    try doc.setEmbeddedFont(inter_dlig, 14);
    try doc.writeAt(162, y, "!? ?!");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(210, y, "(interrobangs \xe2\x80\xbd)");
    y += 18;
    // Contextual f/t variants
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(78, y, "ff fi ffi ft tt tf rf rt vf wt");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(270, y, "ON:");
    try doc.setEmbeddedFont(inter_dlig, 12);
    try doc.writeAt(292, y, "ff fi ffi ft tt tf rf rt vf wt");
    y += 22;

    // --- Tabular/Proportional Figures (tnum/pnum) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Figure Styles (tnum/pnum)");
    y += 14;
    // Side-by-side comparison showing alignment difference
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "Proportional:");
    try doc.writeAt(200, y, "Tabular:");
    y += 12;
    // Row 1
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(50, y, "1111.00");
    try doc.setEmbeddedFont(inter_tnum, 11);
    try doc.writeAt(200, y, "1111.00");
    y += 13;
    // Row 2
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(50, y, "2480.50");
    try doc.setEmbeddedFont(inter_tnum, 11);
    try doc.writeAt(200, y, "2480.50");
    y += 13;
    // Row 3
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(50, y, "9999.99");
    try doc.setEmbeddedFont(inter_tnum, 11);
    try doc.writeAt(200, y, "9999.99");
    y += 18;

    // --- Fractions (frac) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Fractions (frac)");
    y += 14;
    // OFF uses regular slash, ON uses fraction slash U+2044 with frac feature
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(50, y, "OFF:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(78, y, "1/2 3/4 5/8 7/16"); // regular slash
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(220, y, "ON:");
    try doc.setEmbeddedFont(inter_frac, 12);
    try doc.writeAt(242, y, "1\xe2\x81\x842 3\xe2\x81\x844 5\xe2\x81\x848 7\xe2\x81\x8416"); // fraction slash U+2044
    y += 20;

    // --- Slashed Zero (zero) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Slashed Zero (zero)");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(175, y, "OFF:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(200, y, "0 10 20 100");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(295, y, "ON:");
    try doc.setEmbeddedFont(inter_zero, 12);
    try doc.writeAt(316, y, "0 10 20 100");
    y += 18;

    // --- Case-Sensitive Forms (case) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Case-Sensitive (case)");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(175, y, "OFF:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(200, y, "A@B 3+9\xe2\x89\x8812*1"); // ≈ is U+2248 = E2 89 88
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(320, y, "ON:");
    try doc.setEmbeddedFont(inter_case, 12);
    try doc.writeAt(340, y, "A@B 3+9\xe2\x89\x8812*1");
    y += 18;

    // --- Stylistic Set 1 (ss01) ---
    try doc.setEmbeddedFont(inter_bold, 10);
    try doc.writeAt(50, y, "Stylistic Set 1 (ss01)");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(175, y, "OFF:");
    try doc.setEmbeddedFont(inter, 12);
    try doc.writeAt(200, y, "3 4 6 9 a g");
    try doc.setEmbeddedFont(inter, 8);
    try doc.writeAt(295, y, "ON:");
    try doc.setEmbeddedFont(inter_ss01, 12);
    try doc.writeAt(316, y, "3 4 6 9 a g");
    y += 22;

    // ===== Unicode Coverage =====
    try doc.setEmbeddedFont(inter_bold, 13);
    try doc.writeAt(50, y, "Unicode Coverage");
    y += 18;

    // Latin Extended
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Latin");
    try doc.setEmbeddedFont(inter, 10);
    try doc.writeAt(88, y, "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏ ÐÑÒÓÔÕÖØÙÚÛÜÝÞ\xc3\x9f àáâãäåæçèéêëìíîï ðñòóôõöøùúûüýþÿ");
    y += 14;
    try doc.writeAt(88, y, "\xc4\x80\xc4\x81\xc4\x82\xc4\x83\xc4\x84\xc4\x85\xc4\x86\xc4\x87\xc4\x88\xc4\x89\xc4\x8a\xc4\x8b\xc4\x8c\xc4\x8d\xc4\x8e\xc4\x8f\xc4\x90\xc4\x91\xc4\x92\xc4\x93\xc4\x94\xc4\x95 Œœ\xc5\xa0\xc5\xa1\xc5\xb8\xc5\xbd\xc5\xbe\xc6\x92");
    y += 16;

    // Greek & Cyrillic
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Greek");
    try doc.setEmbeddedFont(inter, 10);
    try doc.writeAt(88, y, "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠ αβγδεζηθικλμνξοπ");
    y += 14;
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Cyrillic");
    try doc.setEmbeddedFont(inter, 10);
    try doc.writeAt(98, y, "АБВГДЕЖЗИЙКЛМНОП абвгдежзийклмноп");
    y += 16;

    // Punctuation
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Punctuation");
    try doc.setEmbeddedFont(inter, 10);
    try doc.writeAt(118, y, "\xe2\x80\x98single\xe2\x80\x99 \xe2\x80\x9cdouble\xe2\x80\x9d \xc2\xabguillemets\xc2\xbb  hyphen- en\xe2\x80\x93dash em\xe2\x80\x94dash \xe2\x80\xa6");
    y += 16;

    // Currency & Math
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Currency");
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(105, y, "$ \xc2\xa2 \xc2\xa3 \xc2\xa5 \xe2\x82\xac \xe2\x82\xa3 \xe2\x82\xb9 \xe2\x82\xbd");
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(260, y, "Math");
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(295, y, "+ \xe2\x88\x92 \xc3\x97 \xc3\xb7 = \xe2\x89\xa0 \xe2\x89\xa4 \xe2\x89\xa5 \xc2\xb1 \xe2\x88\x9e \xe2\x88\x9a \xe2\x88\x91");
    y += 16;

    // Arrows & Symbols
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Arrows");
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(95, y, "\xe2\x86\x90 \xe2\x86\x91 \xe2\x86\x92 \xe2\x86\x93 \xe2\x86\x94 \xe2\x86\x95 \xe2\x87\x90 \xe2\x87\x92 \xe2\x87\x94");
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(260, y, "Symbols");
    try doc.setEmbeddedFont(inter, 11);
    try doc.writeAt(305, y, "\xc2\xa9 \xc2\xae \xe2\x84\xa2 \xc2\xb0 \xc2\xa7 \xc2\xb6 \xe2\x80\xa0 \xe2\x80\xa1 \xe2\x80\xa2");
    y += 16;

    // Figures
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "Figures");
    try doc.setEmbeddedFont(inter, 10);
    try doc.writeAt(98, y, "0123456789  \xc2\xbc \xc2\xbd \xc2\xbe \xe2\x85\x93 \xe2\x85\x94  Super: \xc2\xb9\xc2\xb2\xc2\xb3\xe2\x81\xb4\xe2\x81\xb5  Sub: \xe2\x82\x80\xe2\x82\x81\xe2\x82\x82\xe2\x82\x83\xe2\x82\x84  H\xe2\x82\x82O CO\xe2\x82\x82 E=mc\xc2\xb2");
    y += 16;

    // ASCII
    try doc.setEmbeddedFont(inter_bold, 9);
    try doc.writeAt(50, y, "ASCII");
    try doc.setEmbeddedFont(inter, 9);
    try doc.writeAt(85, y, "!\"#$%&'()*+,-./0123456789:;<=>?@ ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_` abcdefghijklmnopqrstuvwxyz{|}~");
    y += 18;

    // Footer: Available Features
    try doc.setEmbeddedFont(inter, 7);
    try doc.writeAt(50, y, "GSUB: aalt calt case ccmp cv01-14 dlig dnom frac locl numr ordn pnum salt sinf ss01-08 subs sups tnum zero | GPOS: cpsp kern mark mkmk");

    return doc.output();
}

/// Comprehensive diacritics test using Gentium font
/// Gentium has extensive mark positioning support for combining diacritics
fn generateGentiumDiacriticsPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    const gentium = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf");
    gentium.encoding = .identity;
    const gentium_bold = try doc.loadFont("test/fonts/Gentium/Gentium-Bold.ttf");
    gentium_bold.encoding = .identity;
    const gentium_italic = try doc.loadFont("test/fonts/Gentium/Gentium-Italic.ttf");
    gentium_italic.encoding = .identity;

    try doc.addPage();
    var y: f64 = 32;
    const desc_x: f64 = 280; // Right column for descriptions
    const desc_width: f64 = 270; // Width of description region
    const desc_offset: f64 = 12; // Alignment offset for description baseline

    // Title
    try doc.setEmbeddedFont(gentium_bold, 18);
    try doc.writeAt(50, y, "Gentium Diacritics Reference");
    y += 28;

    // --- Basic Combining Marks (Above) ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Combining Marks (Above)");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // grave, acute, circumflex, tilde, macron - Aa Ee Oo pairs
    try doc.writeAt(50, y, "A\xcc\x80a\xcc\x80 A\xcc\x81a\xcc\x81 A\xcc\x82a\xcc\x82 A\xcc\x83a\xcc\x83 A\xcc\x84a\xcc\x84");
    try doc.setEmbeddedFont(gentium, 9);
    var region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "grave, acute, circumflex, tilde, macron", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // breve, dot above, diaeresis, hook above, ring above
    try doc.writeAt(50, y, "A\xcc\x86a\xcc\x86 A\xcc\x87a\xcc\x87 A\xcc\x88a\xcc\x88 A\xcc\x89a\xcc\x89 A\xcc\x8aa\xcc\x8a");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "breve, dot above, diaeresis, hook above, ring above", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // double acute, caron, double grave
    try doc.writeAt(50, y, "A\xcc\x8ba\xcc\x8b A\xcc\x8ca\xcc\x8c A\xcc\x8fa\xcc\x8f O\xcc\x8bo\xcc\x8b O\xcc\x8co\xcc\x8c");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "double acute, caron, double grave (Hungarian, Czech)", .{});
    y += 20;

    // --- Combining Marks (Below) ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Combining Marks (Below)");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // cedilla, ogonek, dot below
    try doc.writeAt(50, y, "C\xcc\xa7c\xcc\xa7 S\xcc\xa7s\xcc\xa7 A\xcc\xa8a\xcc\xa8 E\xcc\xa8e\xcc\xa8 A\xcc\xa3a\xcc\xa3");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "cedilla (French, Turkish), ogonek (Polish), dot below (Vietnamese)", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // macron below, line below, ring below
    try doc.writeAt(50, y, "A\xcc\xb1a\xcc\xb1 A\xcc\xb2a\xcc\xb2 A\xcc\xa5a\xcc\xa5 O\xcc\xa3o\xcc\xa3 U\xcc\xa3u\xcc\xa3");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "macron below, line below, ring below, more dot below", .{});
    y += 20;

    // --- Stacked Diacritics (Vietnamese style) ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Stacked Diacritics (Vietnamese)");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // circumflex + tone marks
    try doc.writeAt(50, y, "A\xcc\x82\xcc\x81a\xcc\x82\xcc\x81 E\xcc\x82\xcc\x80e\xcc\x82\xcc\x80 O\xcc\x82\xcc\x89o\xcc\x82\xcc\x89 A\xcc\x82\xcc\x83a\xcc\x82\xcc\x83");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "circumflex + acute, grave, hook above, tilde (Vietnamese vowels)", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // breve + tone, horn + tone (precomposed)
    try doc.writeAt(50, y, "A\xcc\x86\xcc\x81a\xcc\x86\xcc\x81 A\xcc\x86\xcc\x80a\xcc\x86\xcc\x80 \xe1\xbb\x9a\xe1\xbb\x9b \xe1\xbb\x9c\xe1\xbb\x9d \xe1\xbb\xa8\xe1\xbb\xa9 \xe1\xbb\xaa\xe1\xbb\xab");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "breve+tone (combining), horn+tone (precomposed: Ớờ Ứừ)", .{});
    y += 20;

    // --- Above + Below Combinations ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Above + Below Combinations");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // cedilla + above marks
    try doc.writeAt(50, y, "S\xcc\xa7\xcc\x81s\xcc\xa7\xcc\x81 C\xcc\xa7\xcc\x82c\xcc\xa7\xcc\x82 T\xcc\xa7\xcc\x83t\xcc\xa7\xcc\x83");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "cedilla combined with acute, circumflex, tilde above", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // ogonek + above marks
    try doc.writeAt(50, y, "A\xcc\xa8\xcc\x84a\xcc\xa8\xcc\x84 E\xcc\xa8\xcc\x81e\xcc\xa8\xcc\x81 O\xcc\xa3\xcc\x82o\xcc\xa3\xcc\x82");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "ogonek + macron, ogonek + acute, dot below + circumflex", .{});
    y += 20;

    // --- Precomposed Characters ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Precomposed Characters");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // Precomposed grave, acute, circumflex, tilde
    try doc.writeAt(50, y, "\xc3\x80\xc3\xa0 \xc3\x81\xc3\xa1 \xc3\x82\xc3\xa2 \xc3\x83\xc3\xa3 \xc3\x88\xc3\xa8 \xc3\x89\xc3\xa9 \xc3\x8a\xc3\xaa \xc3\x92\xc3\xb2 \xc3\x93\xc3\xb3 \xc3\x94\xc3\xb4");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Precomposed Latin letters with grave, acute, circumflex, tilde", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // Vietnamese precomposed
    try doc.writeAt(50, y, "\xe1\xba\xa0\xe1\xba\xa1 \xe1\xba\xa2\xe1\xba\xa3 \xe1\xba\xa4\xe1\xba\xa5 \xc6\xa0\xc6\xa1 \xc6\xaf\xc6\xb0");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Vietnamese precomposed: A with dot, hook, circumflex+acute, horn", .{});
    y += 20;

    // --- Latin Extended (Ogonek, Cedilla, Caron) ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Latin Extended");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // Polish ogonek
    try doc.writeAt(50, y, "\xc4\x84\xc4\x85 \xc4\x98\xc4\x99 \xc4\xae\xc4\xaf \xc5\xb2\xc5\xb3");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Polish: A, E, I, U with ogonek", .{});
    y += 17;
    try doc.setEmbeddedFont(gentium, 13);
    // Turkish/Romanian cedilla, Czech caron
    try doc.writeAt(50, y, "\xc5\x9e\xc5\x9f \xc5\xa2\xc5\xa3 \xc4\x8e\xc4\x8f \xc4\xbd\xc4\xbe \xc5\xa4\xc5\xa5 \xc5\x87\xc5\x88");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Turkish/Romanian cedilla; Czech/Slovak caron", .{});
    y += 20;

    // --- Multiple Diacritics Stress Test ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Multiple Diacritics (3 marks)");
    y += 15;
    try doc.setEmbeddedFont(gentium, 13);
    // Triple stacked marks
    try doc.writeAt(50, y, "A\xcc\xa3\xcc\x82\xcc\x81a\xcc\xa3\xcc\x82\xcc\x81 E\xcc\xa8\xcc\x84\xcc\x87e\xcc\xa8\xcc\x84\xcc\x87 O\xcc\xa7\xcc\x83\xcc\x8ao\xcc\xa7\xcc\x83\xcc\x8a");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 40 };
    _ = try doc.writeParagraph(&region, "dot below + circumflex + acute; ogonek + macron + dot above; cedilla + tilde + ring", .{});
    y += 22;

    // --- Sample Text in Various Languages ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Sample Text");
    y += 15;
    try doc.setEmbeddedFont(gentium, 11);
    try doc.writeAt(50, y, "Ti\xe1\xba\xbfng Vi\xe1\xbb\x87t: X\xc3\xa3 h\xe1\xbb\x99i ch\xe1\xbb\xa7 ngh\xc4\xa9a Vi\xe1\xbb\x87t Nam");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Vietnamese with stacked diacritics and horn", .{});
    y += 15;
    try doc.setEmbeddedFont(gentium, 11);
    try doc.writeAt(50, y, "Polski: Zwy\xc5\xbc\xc4\x87 \xc5\x82\xc3\xb3dki\xc4\x99 sta\xc5\x84cie\xc4\x87 \xc5\xbcmij\xc4\x85");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Polish with ogonek, kreska, overdot", .{});
    y += 15;
    try doc.setEmbeddedFont(gentium, 11);
    try doc.writeAt(50, y, "T\xc3\xbcrk\xc3\xa7e: \xc3\x87al\xc4\xb1\xc5\x9fkan \xc3\xb6\xc4\x9frenciler");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "Turkish with cedilla, dotless i, breve", .{});
    y += 15;
    try doc.setEmbeddedFont(gentium_italic, 11);
    try doc.writeAt(50, y, "Fran\xc3\xa7ais: L'\xc3\xa9l\xc3\xa8ve na\xc3\xaff re\xc3\xa7oit");
    try doc.setEmbeddedFont(gentium, 9);
    region = zpdf.Region{ .x = desc_x, .y = y - desc_offset, .width = desc_width, .height = 30 };
    _ = try doc.writeParagraph(&region, "French with cedilla, accents, diaeresis", .{});
    y += 18;

    // --- Font Styles ---
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Font Styles");
    y += 15;
    try doc.setEmbeddedFont(gentium, 11);
    try doc.writeAt(50, y, "Regular: \xc3\x80\xc3\xa0 \xc3\x81\xc3\xa1 \xc3\x82\xc3\xa2 \xc3\x88\xc3\xa8 \xc3\x89\xc3\xa9 \xc3\x8a\xc3\xaa \xc3\x92\xc3\xb2 \xc3\x93\xc3\xb3 \xc3\x94\xc3\xb4");
    y += 14;
    try doc.setEmbeddedFont(gentium_bold, 11);
    try doc.writeAt(50, y, "Bold: \xc3\x80\xc3\xa0 \xc3\x81\xc3\xa1 \xc3\x82\xc3\xa2 \xc3\x88\xc3\xa8 \xc3\x89\xc3\xa9 \xc3\x8a\xc3\xaa \xc3\x92\xc3\xb2 \xc3\x93\xc3\xb3 \xc3\x94\xc3\xb4");
    y += 14;
    try doc.setEmbeddedFont(gentium_italic, 11);
    try doc.writeAt(50, y, "Italic: \xc3\x80\xc3\xa0 \xc3\x81\xc3\xa1 \xc3\x82\xc3\xa2 \xc3\x88\xc3\xa8 \xc3\x89\xc3\xa9 \xc3\x8a\xc3\xaa \xc3\x92\xc3\xb2 \xc3\x93\xc3\xb3 \xc3\x94\xc3\xb4");

    return doc.output();
}

fn generateOpenTypeFeaturessPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Satoshi has liga (fi, fl, ff, ffi, ffl), kern, tnum, pnum
    const satoshi = try doc.loadFont("test/fonts/Satoshi/Satoshi-Regular.otf");
    satoshi.encoding = .identity;
    const satoshi_bold = try doc.loadFont("test/fonts/Satoshi/Satoshi-Bold.otf");
    satoshi_bold.encoding = .identity;
    const satoshi_italic = try doc.loadFont("test/fonts/Satoshi/Satoshi-Italic.otf");
    satoshi_italic.encoding = .identity;

    // Charter has kern but no liga
    const charter = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf");
    charter.encoding = .identity;
    const charter_bold = try doc.loadFont("test/fonts/Charter/Charter Bold.ttf");
    charter_bold.encoding = .identity;

    // Inter has tnum, pnum, zero features
    // Note: Disable kerning for Inter - fpdf2 reference uses text() without shaping for these
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter.encoding = .identity;
    inter.setFeature(.kern, false);
    const inter_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf");
    inter_bold.encoding = .identity;
    inter_bold.setFeature(.kern, false);

    try doc.addPage();
    var y: f64 = 25;

    // Title
    try doc.setEmbeddedFont(satoshi_bold, 20);
    try doc.writeAt(50, y, "OpenType Features Showcase");
    y += 16;
    try doc.setEmbeddedFont(satoshi, 7);
    try doc.writeAt(50, y, "Ligatures (liga), Kerning (kern), Tabular Figures (tnum), and more");
    y += 12;

    // === Ligatures Section ===
    try doc.setEmbeddedFont(satoshi_bold, 11);
    try doc.writeAt(50, y, "Standard Ligatures (liga)");
    y += 11;

    try doc.setEmbeddedFont(satoshi, 9);
    try doc.writeAt(50, y, "Satoshi: fi fl ff ffi ffl ligatures enabled");
    y += 10;

    // Words with ligatures - compact layout
    try doc.setEmbeddedFont(satoshi, 10);
    try doc.writeAt(50, y, "office efficient waffle difficult affidavit affluent");
    y += 12;
    try doc.writeAt(50, y, "find five flow flag coffee effect staff differ suffix");
    y += 12;
    try doc.writeAt(50, y, "after soft gift lift draft shift swift left craft");
    y += 14;

    // === Kerning Section ===
    try doc.setEmbeddedFont(charter_bold, 11);
    try doc.writeAt(50, y, "Kerning (kern)");
    y += 11;

    try doc.setEmbeddedFont(charter, 10);
    try doc.writeAt(50, y, "AV AWAY AVATAR To Today We Weather LT AT TA VA WA Yo");
    y += 12;
    try doc.writeAt(50, y, "Typography: proper letter spacing for readability");
    y += 14;

    // === Tabular Figures ===
    try doc.setEmbeddedFont(satoshi_bold, 11);
    try doc.writeAt(50, y, "Tabular vs Proportional Figures (tnum/pnum)");
    y += 11;

    try doc.setEmbeddedFont(satoshi, 9);
    try doc.writeAt(50, y, "Numbers align in columns when using tabular figures:");
    y += 10;

    try doc.setEmbeddedFont(satoshi, 10);
    try doc.writeAt(50, y, "tnum: 1111  0000  1234");
    try doc.writeAt(200, y, "1,234.56");
    y += 11;
    try doc.writeAt(50, y, "tnum: 9999  1010  5678");
    try doc.writeAt(200, y, "9,876.54");
    y += 12;
    try doc.writeAt(50, y, "pnum: 1111  0000  1234");
    try doc.writeAt(200, y, "1,234.56");
    y += 11;
    try doc.writeAt(50, y, "pnum: 9999  1010  5678");
    try doc.writeAt(200, y, "9,876.54");
    y += 14;

    // === Inter stylistic features ===
    try doc.setEmbeddedFont(inter_bold, 11);
    try doc.writeAt(50, y, "Inter: Character Variants & Stylistic Sets");
    y += 11;

    try doc.setEmbeddedFont(inter, 9);
    try doc.writeAt(50, y, "Default: 0123456789 Il1| agy");
    y += 10;
    try doc.writeAt(50, y, "zero feature: 0123456789 (slashed zero)");
    y += 10;
    try doc.writeAt(50, y, "tnum+zero: 0123456789 (tabular + slashed)");
    y += 12;

    // === Combined features paragraph ===
    try doc.setEmbeddedFont(satoshi_bold, 11);
    try doc.writeAt(50, y, "Paragraph with Multiple Features:");
    y += 11;

    try doc.setEmbeddedFont(satoshi, 8);
    try doc.writeAt(50, y, "The efficient office staff finished 5,432 affidavits in 2024. Officials offered");
    y += 9;
    try doc.writeAt(50, y, "to fix afflicted files worth $1,234,567.89. The coffee effect was sufficient after fifty");
    y += 9;
    try doc.writeAt(50, y, "efforts. Different offices refined workflow: Task A=1111, B=2222, C=3333.");
    y += 12;

    // === Bold/Italic with ligatures ===
    try doc.setEmbeddedFont(satoshi_bold, 10);
    try doc.writeAt(50, y, "Styles: Bold: office efficient waffle");
    y += 11;
    try doc.setEmbeddedFont(satoshi_italic, 10);
    try doc.writeAt(50, y, "Styles: Italic: office efficient waffle");
    y += 12;

    // Footer note
    try doc.setEmbeddedFont(satoshi, 6);
    try doc.writeAt(50, y, "Features: liga=ligatures, kern=kerning, tnum=tabular figures, pnum=proportional figures, zero=slashed zero");

    return doc.output();
}

fn generateTextFlowPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Set margins (1 inch = 72pt)
    doc.setMargins(.{ .left = 72, .right = 72, .top = 72, .bottom = 72 });

    try doc.addPage();
    try doc.setFont(.helvetica_bold, 16);

    // Title - matches fpdf2 text() positioning
    try doc.writeAt(72, 72, "Text Flow API Test");

    // Single lines with different alignments - use writeAt for exact positioning
    try doc.setFont(.helvetica, 12);
    var y: f64 = 112;
    const region_width = 595.28 - 72 - 72;

    try doc.writeAt(72, y, "Left aligned line (default)");
    y += 14.4;

    // Center aligned
    const center_text = "Center aligned line";
    const center_width = doc.getTextWidth(center_text);
    try doc.writeAt(72 + (region_width - center_width) / 2, y, center_text);
    y += 14.4;

    // Right aligned
    const right_text = "Right aligned line";
    const right_width = doc.getTextWidth(right_text);
    try doc.writeAt(72 + region_width - right_width, y, right_text);
    y += 14.4;

    y += 12;

    // Word wrapping section
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Word Wrapping Test:");
    y += 14.4;

    // Use writeParagraph with valign: .middle for fpdf2-compatible positioning
    try doc.setFont(.helvetica, 11);
    var region = zpdf.Region{ .x = 72, .y = y, .width = region_width, .height = 200 };
    const paragraph1 = "This is a test paragraph that demonstrates word wrapping. " ++
        "The text should automatically wrap to fit within the region width. " ++
        "Long words like supercalifragilisticexpialidocious should also be handled.";
    _ = try doc.writeParagraph(&region, paragraph1, .{ .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Demo 1: Regular hyphens - compound words stay together (100pt column)
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Regular Hyphens (100pt column):");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    // At 11pt: "Look:" ~22pt, "state-of-the-art" ~86pt
    // "Look: state-of-the-art" ~111pt > 100pt, so word wraps to next line
    // With break_on_hyphens=false, the compound word stays intact
    region = zpdf.Region{ .x = 72, .y = y, .width = 100, .height = 60 };
    const paragraph2a = "Look: state-of-the-art works.";
    _ = try doc.writeParagraph(&region, paragraph2a, .{ .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Demo 2: Soft-hyphens - word breaks at soft-hyphen point (26pt column)
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Soft-Hyphens (26pt column):");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    // At 11pt: "in-" ~12.8pt, "com-" ~24.4pt, both fit in 26pt
    // Word breaks recursively at soft-hyphen points
    region = zpdf.Region{ .x = 72, .y = y, .width = 26, .height = 80 };
    // Word has soft-hyphens: in­com­pre­hen­si­ble
    const paragraph2b = "in\xc2\xadcom\xc2\xadpre\xc2\xadhen\xc2\xadsi\xc2\xadble";
    _ = try doc.writeParagraph(&region, paragraph2b, .{ .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Demo 3: Character wrap - long word without soft-hyphens in narrow column
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Character Wrap (50pt column):");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    // "supercalifragilisticexpialidocious" is ~155pt at 11pt, won't fit in 50pt
    // Without soft-hyphens, it overflows the line (character-level handling)
    region = zpdf.Region{ .x = 72, .y = y, .width = 50, .height = 80 };
    _ = try doc.writeParagraph(&region, "supercalifragilisticexpialidocious", .{ .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Centered paragraph section
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Centered Paragraph:");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    region = zpdf.Region{ .x = 72, .y = y, .width = region_width, .height = 100 };
    const paragraph3 = "This paragraph is center aligned. Each line of text " ++
        "will be centered within the region width.";
    _ = try doc.writeParagraph(&region, paragraph3, .{ .alignment = .center, .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Overflow test - small region that forces overflow
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Overflow Test (150pt wide, 30pt tall):");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    // 150pt width forces more line wraps; 30pt height fits ~2 lines at 13.2pt each
    region = zpdf.Region{ .x = 72, .y = y, .width = 150, .height = 30 };
    const overflow_text = "Line one fits here. Line two fits here. " ++
        "Line three overflows. Line four overflows.";
    const result = try doc.writeParagraph(&region, overflow_text, .{ .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    // Show what overflowed
    try doc.setFont(.helvetica_bold, 10);
    try doc.writeAt(72, y, "Overflow content:");
    y += 12;
    try doc.setFont(.helvetica, 10);
    if (result.overflow) |overflow| {
        // Truncate if too long for display
        const display_len = @min(overflow.len, 60);
        try doc.writeAt(72, y, overflow[0..display_len]);
    } else {
        try doc.writeAt(72, y, "(no overflow)");
    }
    y += 16;

    // Bordered region section
    try doc.setFont(.helvetica_bold, 12);
    try doc.writeAt(72, y, "Region with Border:");
    y += 14.4;

    var boxed_region = zpdf.Region{
        .x = 72,
        .y = y,
        .width = region_width,
        .height = 60,
        .border = zpdf.Border.all,
        .fill = zpdf.Color{ .r = 0.95, .g = 0.95, .b = 0.95 },
    };
    try doc.drawRegion(&boxed_region);

    try doc.setFont(.helvetica, 11);
    // fpdf2 uses set_xy(x, y+5), so we set cursor_y = 5 to match
    boxed_region.cursor_y = 5;
    _ = try doc.writeParagraph(&boxed_region, "This text is inside a bordered region with a light gray background fill.", .{ .valign = .middle, .break_on_hyphens = false });

    return doc.output();
}

fn generateJustifyPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();
    var y: f64 = 50;

    // Title
    try doc.setFont(.helvetica_bold, 14);
    try doc.writeAt(50, y, "Justified Text Alignment");
    y += 24;

    // Standard paragraph width (451 pts = page width - 72pt margins each side)
    const region_width = 451;

    // Test 1: Long justified paragraph (multiple lines)
    try doc.setFont(.helvetica_bold, 11);
    try doc.writeAt(50, y, "Long Justified Paragraph:");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    var region = zpdf.Region{ .x = 50, .y = y, .width = region_width, .height = 200 };
    const text1 = "Typography is the art and technique of arranging type to make written " ++
        "language legible, readable, and appealing when displayed. The arrangement " ++
        "of type involves selecting typefaces, point sizes, line lengths, line spacing, " ++
        "and letter spacing, as well as adjusting the space between pairs of letters. " ++
        "Justified text creates clean edges on both sides of a text block, which many " ++
        "readers find visually appealing. However, it can create uneven spacing between " ++
        "words, especially in narrow columns. The last line is typically left-aligned.";
    _ = try doc.writeParagraph(&region, text1, .{ .alignment = .justify, .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 16;

    // Test 2: Narrow column justified (more lines)
    try doc.setFont(.helvetica_bold, 11);
    try doc.writeAt(50, y, "Narrow Column (200pt):");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    region = zpdf.Region{ .x = 50, .y = y, .width = 200, .height = 150 };
    const text2 = "In narrow columns, justified text requires more word spacing adjustment. " ++
        "Each line must stretch to fill the available width, which can create " ++
        "noticeable gaps between words. Good typography balances readability with " ++
        "visual appeal. The spacing should be even across the paragraph.";
    _ = try doc.writeParagraph(&region, text2, .{ .alignment = .justify, .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 16;

    // Test 3: Compare left vs justify with same long text
    const compare_text = "The quick brown fox jumps over the lazy dog. Pack my box with five " ++
        "dozen liquor jugs. How vexingly quick daft zebras jump. The five boxing " ++
        "wizards jump quickly. Sphinx of black quartz, judge my vow.";

    try doc.setFont(.helvetica_bold, 11);
    try doc.writeAt(50, y, "Comparison - Left Aligned:");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    region = zpdf.Region{ .x = 50, .y = y, .width = 300, .height = 100 };
    _ = try doc.writeParagraph(&region, compare_text, .{ .alignment = .left, .valign = .middle, .break_on_hyphens = false });
    y = region.y + region.cursor_y + 12;

    try doc.setFont(.helvetica_bold, 11);
    try doc.writeAt(50, y, "Comparison - Justified:");
    y += 14.4;

    try doc.setFont(.helvetica, 11);
    region = zpdf.Region{ .x = 50, .y = y, .width = 300, .height = 100 };
    _ = try doc.writeParagraph(&region, compare_text, .{ .alignment = .justify, .valign = .middle, .break_on_hyphens = false });

    return doc.output();
}

fn generateOptimalBreaksPdf(allocator: std.mem.Allocator) ![]u8 {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();
    var y: f64 = 40;

    // Title
    try doc.setFont(.helvetica_bold, 16);
    try doc.writeAt(50, y, "Knuth-Plass Optimal Line Breaking");
    y += 22;

    // Explanation
    try doc.setFont(.helvetica, 9);
    const explanation =
        \\The greedy algorithm fills each line as much as possible. Knuth-Plass minimizes total
        \\"badness" (slack squared) across all lines, often leaving space on one line to improve others.
    ;
    var exp_region = zpdf.Region{ .x = 50, .y = y, .width = 495, .height = 30 };
    _ = try doc.writeParagraph(&exp_region, explanation, .{});
    y += 38;

    // Monospace example with the classic test case
    try doc.setFont(.helvetica_bold, 10);
    try doc.writeAt(50, y, "Monospace Example (14 chars wide):");
    y += 14;

    const mono_text = "The lazy yellow dog was caught by the slow red fox as he lay sleeping in the sun.";
    const char_width = 7.2; // Courier 12pt
    const mono_width = 14 * char_width;

    // Two small boxes side by side for monospace
    try doc.setFont(.courier, 12);
    var mono_greedy = zpdf.Region{ .x = 50, .y = y, .width = mono_width, .height = 110, .border = zpdf.Border.all };
    var mono_optimal = zpdf.Region{ .x = 180, .y = y, .width = mono_width, .height = 110, .border = zpdf.Border.all };
    _ = try doc.writeParagraph(&mono_greedy, mono_text, .{ .line_breaking = .greedy });
    _ = try doc.writeParagraph(&mono_optimal, mono_text, .{ .line_breaking = .optimal });
    try doc.drawRegion(&mono_greedy);
    try doc.drawRegion(&mono_optimal);

    // Labels
    try doc.setFont(.helvetica, 8);
    try doc.writeAt(50, y + 118, "Greedy: line 2 = \"yellow dog was\"");
    try doc.writeAt(180, y + 118, "Optimal: line 2 = \"yellow dog\"");
    y += 136;

    // Lorem Ipsum columns
    try doc.setFont(.helvetica_bold, 10);
    try doc.writeAt(50, y, "Dense Text Comparison:");
    y += 14;

    const lorem =
        \\Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Curabitur pretium tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris. Integer in mauris eu nibh euismod gravida. Duis ac tellus et risus vulputate vehicula. Donec lobortis risus a elit. Etiam tempor ultrices. Suspendisse in justo eu magna luctus suscipit.
        \\
        \\Sed lectus. Integer euismod lacus luctus magna. Quisque cursus, metus vitae pharetra auctor, sem massa mattis sem, at interdum magna augue eget diam. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia Curae; Morbi lacinia molestie dui. Praesent blandit dolor. Sed non quam. In vel mi sit amet augue congue elementum. Morbi in ipsum sit amet pede facilisis laoreet. Donec lacus nunc, viverra nec, blandit vel, egestas et, augue. Vestibulum tincidunt malesuada tellus. Ut ultrices ultrices enim. Curabitur sit amet mauris. Morbi in dui quis est pulvinar ullamcorper. Nulla facilisi. Integer lacinia sollicitudin massa. Cras metus. Sed aliquet risus a tortor. Integer id quam. Morbi mi. Quisque nisl felis, venenatis tristique, dignissim in, ultrices sit amet, augue.
    ;

    const col_width: f64 = 230;
    const col_height: f64 = 480;
    const left_x: f64 = 50;
    const right_x: f64 = 310;

    // Column headers
    try doc.setFont(.helvetica_bold, 9);
    try doc.writeAt(left_x, y, "GREEDY");
    try doc.writeAt(right_x, y, "OPTIMAL (Knuth-Plass)");
    y += 12;

    // Left column - Greedy
    try doc.setFont(.times_roman, 10);
    var left_col = zpdf.Region{ .x = left_x, .y = y, .width = col_width, .height = col_height, .border = zpdf.Border.all };
    _ = try doc.writeParagraph(&left_col, lorem, .{ .line_breaking = .greedy, .alignment = .justify });
    try doc.drawRegion(&left_col);

    // Right column - Optimal
    var right_col = zpdf.Region{ .x = right_x, .y = y, .width = col_width, .height = col_height, .border = zpdf.Border.all };
    _ = try doc.writeParagraph(&right_col, lorem, .{ .line_breaking = .optimal, .alignment = .justify });
    try doc.drawRegion(&right_col);

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

test "integration: cid_fonts PDF" {
    // Compares zpdf CID output against fpdf2 reference
    try runIntegrationTest("cid_fonts", generateCIDFontsPdf);
}

test "integration: inter_fonts PDF" {
    // Tests Inter font family in both TTF and OTF (CFF) formats
    try runIntegrationTest("inter_fonts", generateInterFontsPdf);
}

test "integration: gentium_diacritics PDF" {
    // Tests Gentium font with extensive diacritics and mark positioning
    try runIntegrationTest("gentium_diacritics", generateGentiumDiacriticsPdf);
}

test "integration: opentype_features PDF" {
    // Tests OpenType ligatures (liga) and kerning (kern)
    try runIntegrationTest("opentype_features", generateOpenTypeFeaturessPdf);
}

test "integration: text_flow PDF" {
    // Tests Text Flow API: regions, margins, writeLine, writeParagraph, drawRegion
    try runIntegrationTest("text_flow", generateTextFlowPdf);
}

test "integration: justify PDF" {
    // Tests justified text alignment with word spacing
    try runIntegrationTest("justify", generateJustifyPdf);
}

test "integration: optimal_breaks PDF" {
    // Tests Knuth-Plass optimal line breaking vs greedy algorithm
    try runIntegrationTest("optimal_breaks", generateOptimalBreaksPdf);
}

fn runIntegrationTest(
    name: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
) !void {
    const allocator = std.testing.allocator;

    // Generate PDF
    const pdf = try generate(allocator);
    defer allocator.free(pdf);

    // Build paths
    var ref_path_buf: [256]u8 = undefined;
    var actual_path_buf: [256]u8 = undefined;
    var expected_path_buf: [256]u8 = undefined;
    const ref_path = std.fmt.bufPrint(&ref_path_buf, "test/reference/{s}.pdf", .{name}) catch unreachable;
    const actual_path = std.fmt.bufPrint(&actual_path_buf, "test/output/{s}_actual.pdf", .{name}) catch unreachable;
    const expected_path = std.fmt.bufPrint(&expected_path_buf, "test/output/{s}_expected.pdf", .{name}) catch unreachable;

    // Always save actual output for inspection
    if (std.fs.cwd().createFile(actual_path, .{})) |file| {
        defer file.close();
        file.writeAll(pdf) catch {};
    } else |_| {}

    // Copy reference to expected for side-by-side comparison
    std.fs.cwd().copyFile(ref_path, std.fs.cwd(), expected_path, .{}) catch {};

    // Compare against reference
    var result = try testing.compareWithReference(allocator, pdf, ref_path);
    defer result.deinit();

    if (!result.equal) {
        std.debug.print("\n=== Integration test failed: {s} ===\n", .{name});
        std.debug.print("  Actual:   {s}\n", .{actual_path});
        std.debug.print("  Expected: {s}\n", .{expected_path});
        if (result.diff) |diff| {
            std.debug.print("{s}\n", .{diff});
        }
        return error.TestFailed;
    }
}

// Export test cases for CLI use
pub const cases = test_cases;
pub const Case = TestCase;
