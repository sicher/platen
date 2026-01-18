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
    .{ .name = "opentype_features", .generate = generateOpenTypeFeaturessPdf },
    .{ .name = "text_flow", .generate = generateTextFlowPdf },
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

    // Load Inter TTF versions
    // Disable kerning to match fpdf2 reference (which uses text() without shaping)
    const inter_ttf = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf");
    inter_ttf.encoding = .identity;
    inter_ttf.setFeature(.kern, false);
    const inter_ttf_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf");
    inter_ttf_bold.encoding = .identity;
    inter_ttf_bold.setFeature(.kern, false);
    const inter_ttf_italic = try doc.loadFont("test/fonts/Inter/Inter-Italic.ttf");
    inter_ttf_italic.encoding = .identity;
    inter_ttf_italic.setFeature(.kern, false);
    const inter_ttf_bolditalic = try doc.loadFont("test/fonts/Inter/Inter-BoldItalic.ttf");
    inter_ttf_bolditalic.encoding = .identity;
    inter_ttf_bolditalic.setFeature(.kern, false);

    // Load Inter OTF versions (CFF outlines)
    const inter_otf = try doc.loadFont("test/fonts/Inter/Inter-Regular.otf");
    inter_otf.encoding = .identity;
    inter_otf.setFeature(.kern, false);
    const inter_otf_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.otf");
    inter_otf_bold.encoding = .identity;
    inter_otf_bold.setFeature(.kern, false);
    const inter_otf_italic = try doc.loadFont("test/fonts/Inter/Inter-Italic.otf");
    inter_otf_italic.encoding = .identity;
    inter_otf_italic.setFeature(.kern, false);
    const inter_otf_bolditalic = try doc.loadFont("test/fonts/Inter/Inter-BoldItalic.otf");
    inter_otf_bolditalic.encoding = .identity;
    inter_otf_bolditalic.setFeature(.kern, false);

    try doc.addPage();
    var y: f64 = 30;

    // Title
    try doc.setEmbeddedFont(inter_ttf_bold, 24);
    try doc.writeAt(50, y, "Inter Font Showcase");
    y += 20;
    try doc.setEmbeddedFont(inter_ttf, 8);
    try doc.writeAt(50, y, "TTF (TrueType) and OTF (CFF) versions with OpenType features");
    y += 20;

    // === TTF Section ===
    try doc.setEmbeddedFont(inter_ttf_bold, 14);
    try doc.writeAt(50, y, "TrueType (.ttf)");
    y += 16;

    try doc.setEmbeddedFont(inter_ttf, 10);
    try doc.writeAt(50, y, "Regular: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_ttf_bold, 10);
    try doc.writeAt(50, y, "Bold: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_ttf_italic, 10);
    try doc.writeAt(50, y, "Italic: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_ttf_bolditalic, 10);
    try doc.writeAt(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 16;

    // === OTF Section ===
    try doc.setEmbeddedFont(inter_otf_bold, 14);
    try doc.writeAt(50, y, "OpenType/CFF (.otf)");
    y += 16;

    try doc.setEmbeddedFont(inter_otf, 10);
    try doc.writeAt(50, y, "Regular: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_otf_bold, 10);
    try doc.writeAt(50, y, "Bold: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_otf_italic, 10);
    try doc.writeAt(50, y, "Italic: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 12;
    try doc.setEmbeddedFont(inter_otf_bolditalic, 10);
    try doc.writeAt(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog. 0123456789");
    y += 18;

    // === Unicode Coverage ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "Unicode Coverage");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 9);
    try doc.writeAt(50, y, "Latin Extended: ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏ àáâãäåæçèéêëìíîï");
    y += 11;
    try doc.writeAt(50, y, "More Latin: ÐÑÒÓÔÕÖØÙÚÛÜÝÞ\xc3\x9f ðñòóôõöøùúûüýþÿ");
    y += 11;
    try doc.writeAt(50, y, "Latin Extended-A: \xc4\x80\xc4\x81\xc4\x82\xc4\x83\xc4\x84\xc4\x85\xc4\x86\xc4\x87\xc4\x88\xc4\x89\xc4\x8a\xc4\x8b\xc4\x8c\xc4\x8d\xc4\x8e\xc4\x8f\xc4\x90\xc4\x91\xc4\x92\xc4\x93\xc4\x94\xc4\x95");
    y += 11;
    try doc.writeAt(50, y, "Latin Extended-B: Œœ\xc5\xa0\xc5\xa1\xc5\xb8\xc5\xbd\xc5\xbe\xc6\x92");
    y += 11;
    try doc.writeAt(50, y, "Greek: ΑΒΓΔΕΖΗΘΙ αβγδεζηθι");
    y += 11;
    try doc.writeAt(50, y, "Cyrillic: АБВГДЕЖЗИ абвгдежзи");
    y += 13;

    // === Punctuation & Symbols ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "Punctuation & Symbols");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 9);
    try doc.writeAt(50, y, "Quotes: \xe2\x80\x98single\xe2\x80\x99 \xe2\x80\x9cdouble\xe2\x80\x9d « guillemets » \xe2\x80\xb9single\xe2\x80\xba");
    y += 11;
    try doc.writeAt(50, y, "Dashes: hyphen- en\xe2\x80\x93dash em\xe2\x80\x94dash horizontal\xe2\x80\x95bar");
    y += 11;
    try doc.writeAt(50, y, "Currency: $ ¢ £ ¥ \xe2\x82\xac \xe2\x82\xa3 \xe2\x82\xa4 \xe2\x82\xb9 \xe2\x82\xbd");
    y += 11;
    try doc.writeAt(50, y, "Math: + \xe2\x88\x92 × ÷ = \xe2\x89\xa0 < > \xe2\x89\xa4 \xe2\x89\xa5 ± \xe2\x88\x9e \xe2\x89\x88");
    y += 11;
    try doc.writeAt(50, y, "Arrows: \xe2\x86\x90 \xe2\x86\x91 \xe2\x86\x92 \xe2\x86\x93 \xe2\x86\x94 \xe2\x86\x95 \xe2\x87\x90 \xe2\x87\x92 \xe2\x87\x94");
    y += 11;
    try doc.writeAt(50, y, "Misc: © ® \xe2\x84\xa2 ° § ¶ \xe2\x80\xa0 \xe2\x80\xa1 \xe2\x80\xa2 \xe2\x80\xa6 ¦");
    y += 13;

    // === Numbers & Figures ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "Numbers & Figures");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 9);
    try doc.writeAt(50, y, "Lining figures: 0123456789 (default)");
    y += 11;
    try doc.writeAt(50, y, "Fractions: ¼ ½ ¾ \xe2\x85\x93 \xe2\x85\x94 \xe2\x85\x9b \xe2\x85\x9c \xe2\x85\x9d \xe2\x85\x9e");
    y += 11;
    try doc.writeAt(50, y, "Superscript: ¹ ² ³ \xe2\x81\xb4 \xe2\x81\xb5 \xe2\x81\xb6 \xe2\x81\xb7 \xe2\x81\xb8 \xe2\x81\xb9 \xe2\x81\xb0");
    y += 11;
    try doc.writeAt(50, y, "Subscript: \xe2\x82\x80 \xe2\x82\x81 \xe2\x82\x82 \xe2\x82\x83 \xe2\x82\x84 \xe2\x82\x85 \xe2\x82\x86 \xe2\x82\x87 \xe2\x82\x88 \xe2\x82\x89");
    y += 11;
    try doc.writeAt(50, y, "Ordinals: 1ª 2º 1st 2nd 3rd");
    y += 13;

    // === OpenType Features ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "OpenType Features Available");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 8);
    try doc.writeAt(50, y, "GSUB: aalt calt case ccmp cv01-cv14 dlig dnom frac locl numr ordn pnum salt sinf ss01-ss08 subs sups tnum zero");
    y += 10;
    try doc.writeAt(50, y, "GPOS: cpsp kern mark mkmk");
    y += 12;

    try doc.setEmbeddedFont(inter_ttf, 9);
    try doc.writeAt(50, y, "zero: Slashed zero 0 vs O (cv feature)");
    y += 11;
    try doc.writeAt(50, y, "tnum: Tabular 1111 vs pnum: Proportional 1111");
    y += 11;
    try doc.writeAt(50, y, "case: H·I vs H\xe2\x80\xa2I (case-sensitive punctuation)");
    y += 11;
    try doc.writeAt(50, y, "frac: 1/2 1/4 3/4 (fraction feature)");
    y += 13;

    // === ASCII Range ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "ASCII Character Set");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 8);
    try doc.writeAt(50, y, "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`");
    y += 10;
    try doc.writeAt(50, y, "abcdefghijklmnopqrstuvwxyz{|}~");
    y += 13;

    // === Size Comparison ===
    try doc.setEmbeddedFont(inter_ttf_bold, 12);
    try doc.writeAt(50, y, "Size Comparison (TTF vs OTF)");
    y += 14;

    try doc.setEmbeddedFont(inter_ttf, 18);
    try doc.writeAt(50, y, "Inter TTF 18pt");
    try doc.setEmbeddedFont(inter_otf, 18);
    try doc.writeAt(250, y, "Inter OTF 18pt");
    y += 22;

    try doc.setEmbeddedFont(inter_ttf_bold, 18);
    try doc.writeAt(50, y, "Inter TTF Bold");
    try doc.setEmbeddedFont(inter_otf_bold, 18);
    try doc.writeAt(250, y, "Inter OTF Bold");

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

test "integration: opentype_features PDF" {
    // Tests OpenType ligatures (liga) and kerning (kern)
    try runIntegrationTest("opentype_features", generateOpenTypeFeaturessPdf);
}

test "integration: text_flow PDF" {
    // Tests Text Flow API: regions, margins, writeLine, writeParagraph, drawRegion
    try runIntegrationTest("text_flow", generateTextFlowPdf);
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
