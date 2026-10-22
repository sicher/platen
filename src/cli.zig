//! platen command line tool

const std = @import("std");
const platen = @import("platen.zig");
const integration_tests = @import("integration_tests.zig");
const cli_fonts = @import("cli_fonts.zig");

var stdout_buffer: [4096]u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stdout: *std.Io.Writer = undefined;
var app_io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    app_io = init.io;
    integration_tests.app_io = init.io;
    stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        try printUsage();
        return;
    };

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version")) {
        try print("platen version {s}\n", .{platen.version.version});
    } else if (std.mem.eql(u8, cmd, "test")) {
        // Generate a minimal test PDF
        const output_path = if (args.len > 2) args[2] else "test.pdf";
        try generateTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "text")) {
        // Generate a PDF with text
        const output_path = if (args.len > 2) args[2] else "text.pdf";
        try generateTextPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "check-refs")) {
        // Compare against reference PDFs
        // Parse mode: --structural, --semantic, or default (auto)
        var mode: testing.CompareMode = .auto;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--structural")) {
                mode = .structural;
            } else if (std.mem.eql(u8, arg, "--semantic")) {
                mode = .semantic;
            }
        }
        try checkAllReferences(allocator, mode);
    } else if (std.mem.eql(u8, cmd, "font-info")) {
        // Show font information
        if (args.len < 3) {
            try print("Usage: platen font-info <font.ttf>\n", .{});
            return;
        }
        try showFontInfo(allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "font-faces")) {
        try cli_fonts.fontFaces(init.io, allocator, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "shape")) {
        try cli_fonts.shape(init.io, allocator, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "extract-face")) {
        try cli_fonts.extractFace(init.io, allocator, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "find-font")) {
        try cli_fonts.findFont(init.io, allocator, stdout, args[2..], init.environ_map.get("HOME"));
    } else if (std.mem.eql(u8, cmd, "embed-test")) {
        // Generate a PDF with embedded font
        const font_path = if (args.len > 2) args[2] else "test/fonts/Courier Prime/Courier Prime.ttf";
        const output_path = if (args.len > 3) args[3] else "embed_test.pdf";
        try generateEmbedTestPdf(allocator, font_path, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "cff-test")) {
        // Test CFF subsetting
        const font_path = if (args.len > 2) args[2] else "test/fonts/Inter/Inter-Regular.otf";
        const output_path = if (args.len > 3) args[3] else "cff_test.pdf";
        try generateCffTestPdf(allocator, font_path, output_path);
    } else if (std.mem.eql(u8, cmd, "mark-test")) {
        // Test mark positioning (GPOS mark/mkmk)
        const font_path = if (args.len > 2) args[2] else "test/fonts/Inter/Inter-Regular.ttf";
        const output_path = if (args.len > 3) args[3] else "mark_test.pdf";
        try generateMarkTestPdf(allocator, font_path, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "calt-test")) {
        // Test contextual alternates (GSUB calt)
        const font_path = if (args.len > 2) args[2] else "test/fonts/Inter/Inter-Regular.ttf";
        const output_path = if (args.len > 3) args[3] else "calt_test.pdf";
        try generateCaltTestPdf(allocator, font_path, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "path-test")) {
        // Test path API (moveTo, lineTo, curveTo)
        const output_path = if (args.len > 2) args[2] else "path_test.pdf";
        try generatePathTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "gradient-test")) {
        // Test gradient API (linear, radial)
        const output_path = if (args.len > 2) args[2] else "gradient_test.pdf";
        try generateGradientTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "opacity-test")) {
        // Test opacity API (fill/stroke alpha)
        const output_path = if (args.len > 2) args[2] else "opacity_test.pdf";
        try generateOpacityTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "metadata-test")) {
        // Test document metadata
        const output_path = if (args.len > 2) args[2] else "metadata_test.pdf";
        try generateMetadataTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "pdfa-test")) {
        // Test PDF/A conformance
        const output_path = if (args.len > 2) args[2] else "pdfa_test.pdf";
        try generatePdfaTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "optical-test")) {
        // Test optical alignment of text in boxes
        const output_path = if (args.len > 2) args[2] else "optical_test.pdf";
        try generateOpticalTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else if (std.mem.eql(u8, cmd, "color-test")) {
        // Test COLR/CPAL color-emoji rendering (Type3 color fonts)
        const font_path = if (args.len > 2) args[2] else "test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf";
        const output_path = if (args.len > 3) args[3] else "color_test.pdf";
        try generateColorTestPdf(allocator, font_path, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else {
        try printUsage();
    }
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    try stdout.print(fmt, args);
}

fn printUsage() !void {
    const usage =
        \\platen - PDF generation library and tool
        \\
        \\Usage: platen <command> [args]
        \\
        \\Commands:
        \\  version              Print version
        \\  test [output]        Generate a minimal test PDF (default: test.pdf)
        \\  text [output]        Generate a PDF with text (default: text.pdf)
        \\  check-refs [opts]    Compare output against reference PDFs (from fpdf2)
        \\                         --structural  Use qpdf structural comparison
        \\                         --semantic    Use pdftotext semantic comparison
        \\                         (default: auto - structural first, then semantic)
        \\  font-info <ttf>      Show TrueType font information
        \\  font-faces <file>    List the faces of a font or collection (.ttc)
        \\  extract-face <ttc> <index> <out>  Write one face as a standalone font
        \\  shape <font> [+feat|-feat]...  Shape stdin lines (one text per line); print glyph IDs
        \\  find-font <family> [--bold] [--italic] [--dir DIR]... [--out FILE]
        \\                       Find an installed font (whole family without flags)
        \\  embed-test [ttf] [out]  Generate PDF with embedded font
        \\  mark-test [ttf] [out]   Test GPOS mark positioning (diacritics)
        \\  calt-test [ttf] [out]   Test GSUB contextual alternates (arrows, ligatures)
        \\  path-test [out]         Test path API (moveTo, lineTo, curveTo)
        \\  gradient-test [out]     Test gradient API (linear, radial)
        \\  opacity-test [out]      Test opacity API (fill/stroke alpha)
        \\  pdfa-test [out]         Test PDF/A-1b conformance output
        \\  optical-test [out]      Test optical alignment of text in boxes
        \\  color-test [ttf] [out]  Test COLR color-emoji rendering (Type3 color fonts)
        \\
    ;
    try stdout.writeAll(usage);
}

fn showFontInfo(allocator: std.mem.Allocator, path: []const u8) !void {
    const result = platen.ttf.Font.fromFile(app_io, allocator, path) catch |err| {
        try print("Error loading font: {}\n", .{err});
        return;
    };
    defer allocator.free(result.data);

    const font = result.font;

    try print("Font: {s}\n", .{path});
    try print("Size: {d} bytes\n\n", .{result.data.len});

    if (font.head) |head| {
        try print("head table:\n", .{});
        try print("  units_per_em: {d}\n", .{head.units_per_em});
        try print("  bbox: [{d}, {d}] - [{d}, {d}]\n", .{ head.x_min, head.y_min, head.x_max, head.y_max });
        try print("  loca format: {s}\n\n", .{if (head.index_to_loc_format == 0) "short" else "long"});
    }

    if (font.hhea) |hhea| {
        try print("hhea table:\n", .{});
        try print("  ascent: {d}\n", .{hhea.ascent});
        try print("  descent: {d}\n", .{hhea.descent});
        try print("  line_gap: {d}\n", .{hhea.line_gap});
        try print("  num_metrics: {d}\n\n", .{hhea.num_of_long_hor_metrics});
    }

    if (font.maxp) |maxp| {
        try print("maxp table:\n", .{});
        try print("  num_glyphs: {d}\n\n", .{maxp.num_glyphs});
    }

    // Show some character widths
    try print("Sample character widths (in font units):\n", .{});
    const samples = "ABCabc0123";
    for (samples) |c| {
        if (font.getCharWidth(c)) |w| {
            try print("  '{c}': {d}\n", .{ c, w });
        }
    }

    try showKerning(font);

    // Show name if available
    if (font.getFamilyName()) |name| {
        try print("\nFamily: ", .{});
        // Name might be UTF-16BE, handle both cases
        if (name.len > 0 and name[0] == 0) {
            // UTF-16BE - print every other byte
            var i: usize = 1;
            while (i < name.len) : (i += 2) {
                try print("{c}", .{name[i]});
            }
        } else {
            try print("{s}", .{name});
        }
        try print("\n", .{});
    }
}

/// Kerning sources: GPOS, and the legacy 'kern' table (platen uses the
/// table only when GPOS has no kern lookups).
fn showKerning(font: platen.ttf.Font) !void {
    try print("\nKerning:\n", .{});
    try print("  GPOS: {s}\n", .{if (font.getTable("GPOS".*) != null) "present" else "absent"});
    const data = font.getTable("kern".*) orelse return print("  kern table: absent\n", .{});
    const t = platen.kern_table.KernTable.parse(data);
    try print("  kern table: {d} usable subtable(s), {d} pairs\n", .{ t.count, t.pairCount() });
    const pairs = [_][2]u21{ .{ 'A', 'V' }, .{ 'T', 'o' }, .{ 'V', 'a' }, .{ 'L', 'T' } };
    for (pairs) |p| {
        const l = font.getGlyphId(p[0]) orelse continue;
        const r = font.getGlyphId(p[1]) orelse continue;
        try print("    '{u}{u}': {d}\n", .{ p[0], p[1], t.get(l, r) });
    }
}

fn generateTestPdf(allocator: std.mem.Allocator, path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    try doc.addPage(.{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = path, .data = pdf });
}

fn generateTextPdf(allocator: std.mem.Allocator, path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    try doc.addPage(.{});
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello, World!", platen.TextStyle{ .font = platen.Font.helvetica, .size = 24 }, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "This is platen - a PDF library for Zig", platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true }, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 150 }, "Built-in fonts: Helvetica, Times, Courier, Symbol, ZapfDingbats", platen.TextStyle{ .font = platen.Font.times, .size = 12 }, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 200 }, "Fixed-width font for code", platen.TextStyle{ .font = platen.Font.courier, .size = 10 }, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = path, .data = pdf });
}

fn generateEmbedTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    // Load the embedded font
    const custom_font = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };

    try doc.addPage(.{});

    // Title with standard font
    const title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 24, .bold = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Embedded Font Test", title_style, .{});

    // Show font info
    const info_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
    var info_buf: [256]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "Font: {s}", .{custom_font.embedded.name}) catch "Font: Unknown";
    _ = try doc.writeAt(.{ .x = 50, .y = 80 }, info, info_style, .{});

    // Use embedded font at various sizes
    const embed24_style = platen.TextStyle{ .font = custom_font, .size = 24 };
    _ = try doc.writeAt(.{ .x = 50, .y = 120 }, "The quick brown fox jumps over the lazy dog.", embed24_style, .{});

    const embed18_style = platen.TextStyle{ .font = custom_font, .size = 18 };
    _ = try doc.writeAt(.{ .x = 50, .y = 160 }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", embed18_style, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 190 }, "abcdefghijklmnopqrstuvwxyz", embed18_style, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 220 }, "0123456789 !@#$%^&*()", embed18_style, .{});

    // Mix with standard fonts
    const helv12_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 270 }, "Standard font (Helvetica) for comparison", helv12_style, .{});

    const embed12_style = platen.TextStyle{ .font = custom_font, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = 290 }, "Embedded font at same size (12pt)", embed12_style, .{});

    // Multiple lines
    const embed14_style = platen.TextStyle{ .font = custom_font, .size = 14 };
    _ = try doc.writeAt(.{ .x = 50, .y = 340 }, "Line 1: This is a test of the embedded font.", embed14_style, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 360 }, "Line 2: Lorem ipsum dolor sit amet.", embed14_style, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 380 }, "Line 3: Consectetur adipiscing elit.", embed14_style, .{});

    // Page 2 - stress test
    try doc.addPage(.{});
    const page2_title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 18, .bold = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Page 2: Extended Character Test", page2_title_style, .{});

    const page2_embed_style = platen.TextStyle{ .font = custom_font, .size = 14 };
    var y: f64 = 80;

    // ASCII printable range
    const line1 = " !\"#$%&'()*+,-./";
    const line2 = "0123456789:;<=>?";
    const line3 = "@ABCDEFGHIJKLMNO";
    const line4 = "PQRSTUVWXYZ[\\]^_";
    const line5 = "`abcdefghijklmno";
    const line6 = "pqrstuvwxyz{|}~";

    _ = try doc.writeAt(.{ .x = 50, .y = y }, line1, page2_embed_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, line2, page2_embed_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, line3, page2_embed_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, line4, page2_embed_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, line5, page2_embed_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, line6, page2_embed_style, .{});
    y += 30;

    // Show metrics
    const metrics_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10 };
    var metrics_buf: [256]u8 = undefined;

    const ascent_info = std.fmt.bufPrint(&metrics_buf, "Ascent: {d}, Descent: {d}, CapHeight: {d}", .{
        custom_font.embedded.ascent,
        custom_font.embedded.descent,
        custom_font.embedded.cap_height,
    }) catch "Metrics unavailable";
    _ = try doc.writeAt(.{ .x = 50, .y = y }, ascent_info, metrics_style, .{});
    y += 15;

    const bbox_info = std.fmt.bufPrint(&metrics_buf, "BBox: [{d}, {d}, {d}, {d}]", .{
        custom_font.embedded.bbox[0],
        custom_font.embedded.bbox[1],
        custom_font.embedded.bbox[2],
        custom_font.embedded.bbox[3],
    }) catch "BBox unavailable";
    _ = try doc.writeAt(.{ .x = 50, .y = y }, bbox_info, metrics_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generateColorTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    const emoji = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };

    try doc.addPage(.{});

    const title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 20, .bold = true };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "COLR Color Emoji Test", title_style, .{});

    const note_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 11 };
    _ = try doc.writeAt(.{ .x = 50, .y = 78 }, "Rendered via PDF Type3 color fonts (COLR v1 + CPAL).", note_style, .{});

    // Flat-color and gradient emoji at a few sizes.
    const rows = [_][]const u8{
        "\u{2601}\u{1F600}\u{1F389}\u{1F680}\u{2764}\u{2B50}",
        "\u{1F31F}\u{1F308}\u{1F34E}\u{1F355}\u{1F381}\u{1F3A8}",
        "\u{1F600}\u{1F601}\u{1F602}\u{1F603}\u{1F604}\u{1F605}",
    };
    var y: f64 = 130;
    for ([_]f64{ 48, 36, 24 }, 0..) |size, i| {
        _ = try doc.writeAt(.{ .x = 50, .y = y }, rows[i], .{ .font = emoji, .size = size }, .{});
        y += size + 30;
    }

    // Space-separated emoji: exercises segmented rendering (color glyphs via
    // the Type3 font, the blank space glyph via the mono CID font).
    _ = try doc.writeAt(.{ .x = 50, .y = y + 20 }, "\u{1F600} \u{1F389} \u{1F680} \u{2764} \u{2B50}", .{ .font = emoji, .size = 28 }, .{});

    // Gradients whose color stops fade (stop alpha): drawn through soft masks
    _ = try doc.writeAt(.{ .x = 50, .y = y + 80 }, "\u{1F4E3}\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}\u{1F466}\u{1F458}\u{1F3A0}\u{1F4F0}", .{ .font = emoji, .size = 48 }, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generateCffTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    // Load font with identity encoding (CID mode for full Unicode)
    const font = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };

    try doc.addPage(.{});

    // Just a few characters to test subsetting
    const cff24_style = platen.TextStyle{ .font = font, .size = 24 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello CFF!", cff24_style, .{});

    const cff18_style = platen.TextStyle{ .font = font, .size = 18 };
    _ = try doc.writeAt(.{ .x = 50, .y = 100 }, "ABCDEFGHIJ", cff18_style, .{});
    _ = try doc.writeAt(.{ .x = 50, .y = 130 }, "0123456789", cff18_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });

    // Show stats
    const cff_data = font.embedded.font.getCFFTable();
    const orig_size = if (cff_data) |d| d.len else 0;
    const subset_size = if (font.embedded.subset_data) |s| s.len else orig_size;
    const used_glyphs = font.embedded.cid_used_glyphs.count();

    // Find max glyph ID
    var max_gid: u16 = 0;
    for (font.embedded.cid_used_glyphs.values()) |gid| {
        if (gid > max_gid) max_gid = gid;
    }

    try print("Generated: {s}\n", .{output_path});
    try print("  PDF size: {} bytes\n", .{pdf.len});
    try print("  Original CFF: {} bytes\n", .{orig_size});
    try print("  Subset CFF: {} bytes\n", .{subset_size});
    try print("  Glyphs used: {} (max gid: {})\n", .{ used_glyphs, max_gid });
    try print("  Reduction: {d:.1}%\n", .{100.0 - @as(f64, @floatFromInt(subset_size)) / @as(f64, @floatFromInt(orig_size)) * 100.0});
}

fn generateMarkTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    const font = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };
    // Enable mark positioning features
    font.embedded.setFeature(.mark, true);
    font.embedded.setFeature(.mkmk, true);

    try doc.addPage(.{});

    const mark24_style = platen.TextStyle{ .font = font, .size = 24 };
    const mark14_style = platen.TextStyle{ .font = font, .size = 14 };
    const mark18_style = platen.TextStyle{ .font = font, .size = 18 };

    var y: f64 = 30;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Mark Positioning Test", mark24_style, .{});
    y += 30;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "GPOS Type 4 (mark-to-base) and Type 6 (mark-to-mark)", mark14_style, .{});
    y += 24;

    // Test text with combining diacritical marks
    // These are separate Unicode combining characters (U+0300-U+036F)

    // Pre-composed vs combining (visual comparison)
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Pre-composed: À É Î Õ Ü ñ", mark18_style, .{});
    y += 24;
    // U+0041 U+0300 = A + COMBINING GRAVE ACCENT
    // U+0045 U+0301 = E + COMBINING ACUTE ACCENT
    // U+0049 U+0302 = I + COMBINING CIRCUMFLEX ACCENT
    // U+004F U+0303 = O + COMBINING TILDE
    // U+0055 U+0308 = U + COMBINING DIAERESIS
    // U+006E U+0303 = n + COMBINING TILDE
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Combining: A\xcc\x80 E\xcc\x81 I\xcc\x82 O\xcc\x83 U\xcc\x88 n\xcc\x83", mark18_style, .{});
    y += 30;

    // More complex combinations
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Double marks: o\xcc\x82\xcc\x81 e\xcc\x84\xcc\x81", mark18_style, .{}); // ô + acute, ē + acute
    y += 24;

    // Vietnamese-style stacked diacritics
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Vietnamese: a\xcc\x82\xcc\x80 e\xcc\x82\xcc\x81 o\xcc\x82\xcc\x83", mark18_style, .{}); // â + grave, ê + acute, ô + tilde
    y += 30;

    // Comparison row
    const mark12_style = platen.TextStyle{ .font = font, .size = 12 };
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "If mark positioning works, combining characters should align with pre-composed.", mark12_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Without mark positioning, combining marks appear after the base character.", mark12_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });

    // Show mark/mkmk lookup stats
    if (font.embedded.ot_features) |ot| {
        try print("GPOS stats:\n", .{});
        try print("  Mark-to-Base lookups: {}\n", .{ot.mark_base_lookups.items.len});
        try print("  Mark-to-Mark lookups: {}\n", .{ot.mark_mark_lookups.items.len});
    }
}

fn generateCaltTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    const font = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };
    // Enable calt feature
    font.embedded.setFeature(.calt, true);

    // Also load a version without calt for comparison
    const font_no_calt = doc.loadFont(font_path, .identity) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };
    font_no_calt.embedded.setFeature(.calt, false);

    try doc.addPage(.{});

    // Define all styles
    const calt24_style = platen.TextStyle{ .font = font, .size = 24 };
    const calt16_style = platen.TextStyle{ .font = font, .size = 16 };
    const calt14_style = platen.TextStyle{ .font = font, .size = 14 };
    const calt12_style = platen.TextStyle{ .font = font, .size = 12 };
    const calt11_style = platen.TextStyle{ .font = font, .size = 11 };
    const calt10_style = platen.TextStyle{ .font = font, .size = 10 };
    const no_calt16_style = platen.TextStyle{ .font = font_no_calt, .size = 16 };
    const no_calt11_style = platen.TextStyle{ .font = font_no_calt, .size = 11 };

    var y: f64 = 30;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Contextual Alternates (calt) Test", calt24_style, .{});
    y += 30;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Inter font: GSUB calt feature for programming ligatures", calt12_style, .{});
    y += 24;

    // Test arrow sequences
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "calt OFF:", calt10_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "-> => <- <=> !== ===", no_calt16_style, .{});
    y += 22;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "calt ON:", calt10_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "-> => <- <=> !== ===", calt16_style, .{});
    y += 30;

    // Test in context
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "In context (calt ON):", calt10_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "function arrow() { return x => x + 1; }", calt14_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "if (a !== b && c <= d) { return a <=> b; }", calt14_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "const diff = a -> b -> c;", calt14_style, .{});
    y += 30;

    // Test ASCII line (the problematic one from integration tests)
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Full ASCII (calt ON):", calt10_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "!\"#$%&'()*+,-./0123456789:;<=>?@", calt11_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`", calt11_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "abcdefghijklmnopqrstuvwxyz{|}~", calt11_style, .{});
    y += 24;

    // Same without calt for comparison
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Full ASCII (calt OFF):", calt10_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "!\"#$%&'()*+,-./0123456789:;<=>?@", no_calt11_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`", no_calt11_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "abcdefghijklmnopqrstuvwxyz{|}~", no_calt11_style, .{});
    y += 24;

    // Regular text should be unchanged
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Regular text (should be identical with/without calt):", calt10_style, .{});
    y += 16;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "The quick brown fox jumps over the lazy dog.", calt12_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });

    // Show calt lookup stats
    if (font.embedded.ot_features) |ot| {
        if (ot.gsub) |*g| {
            try print("GSUB: {} lookups, calt {s}\n", .{ g.lookups.len, if (g.hasFeature(.calt)) "present" else "absent" });
        }
    }
}

fn generatePathTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    try doc.addPage(.{});

    const path_title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true };
    const path_label_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10 };

    // Title
    _ = try doc.writeAt(.{ .x = 50, .y = 30 }, "Path API Test", path_title_style, .{});

    var y: f64 = 70;

    // Triangle using moveTo/lineTo
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Triangle (moveTo, lineTo, closePath):", path_label_style, .{});
    y += 15;

    var triangle = doc.createPath();
    defer triangle.deinit();
    try triangle.moveTo(.{ .x = 100, .y = y });
    try triangle.lineTo(.{ .x = 180, .y = y });
    try triangle.lineTo(.{ .x = 140, .y = y + 60 });
    try triangle.closePath();
    try doc.drawPath(&triangle, .{
        .stroke = .{ .color = platen.Color.blue, .width = 2 },
        .fill = .{ .color = platen.Color.rgb(200, 200, 255) },
    });
    y += 80;

    // Bezier curve
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Cubic Bezier curve (curveTo):", path_label_style, .{});
    y += 15;

    var bezier = doc.createPath();
    defer bezier.deinit();
    try bezier.moveTo(.{ .x = 50, .y = y + 50 });
    try bezier.curveTo(.{ .x = 100, .y = y }, .{ .x = 200, .y = y }, .{ .x = 250, .y = y + 50 });
    try bezier.lineTo(.{ .x = 250, .y = y + 80 });
    try bezier.curveTo(.{ .x = 200, .y = y + 30 }, .{ .x = 100, .y = y + 30 }, .{ .x = 50, .y = y + 80 });
    try bezier.closePath();
    try doc.drawPath(&bezier, .{
        .stroke = .{ .color = platen.Color.red },
        .fill = .{ .color = platen.Color.rgb(255, 200, 200) },
    });
    y += 100;

    // Heart shape using curves
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Heart shape (multiple curveTo):", path_label_style, .{});
    y += 15;

    var heart = doc.createPath();
    defer heart.deinit();
    const hx: f64 = 140;
    const hy: f64 = y + 60;
    try heart.moveTo(.{ .x = hx, .y = hy });
    try heart.curveTo(.{ .x = hx - 50, .y = hy - 50 }, .{ .x = hx - 80, .y = hy + 10 }, .{ .x = hx, .y = hy + 60 });
    try heart.curveTo(.{ .x = hx + 80, .y = hy + 10 }, .{ .x = hx + 50, .y = hy - 50 }, .{ .x = hx, .y = hy });
    try doc.drawPath(&heart, .{
        .stroke = .{ .color = platen.Color.rgb(200, 0, 0) },
        .fill = .{ .color = platen.Color.red },
    });
    y += 90;

    // Stroke only path
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Stroke only (zigzag):", path_label_style, .{});
    y += 15;

    var zigzag = doc.createPath();
    defer zigzag.deinit();
    try zigzag.moveTo(.{ .x = 50, .y = y });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const px = 50 + @as(f64, @floatFromInt(i + 1)) * 25;
        const py = if (i % 2 == 0) y + 30 else y;
        try zigzag.lineTo(.{ .x = px, .y = py });
    }
    try doc.drawPath(&zigzag, .{
        .stroke = .{ .color = platen.Color.rgb(0, 128, 0), .width = 3 },
    });

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generateGradientTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    try doc.addPage(.{});

    const grad_title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true };
    const grad_label_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10 };

    // Title
    _ = try doc.writeAt(.{ .x = 50, .y = 30 }, "Gradient Test", grad_title_style, .{});

    var y: f64 = 70;

    // Linear gradient horizontal
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Linear gradient (horizontal):", grad_label_style, .{});
    y += 15;

    const lin_stops1 = [_]platen.ColorStop{
        .{ .offset = 0.0, .color = platen.Color.red },
        .{ .offset = 1.0, .color = platen.Color.blue },
    };
    const grad1 = try doc.addLinearGradient(.{
        .x0 = 50,
        .y0 = y,
        .x1 = 250,
        .y1 = y,
        .stops = &lin_stops1,
    });
    try doc.fillRectGradient(.{ .x = 50, .y = y, .width = 200, .height = 50 }, grad1);
    y += 70;

    // Linear gradient vertical
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Linear gradient (vertical):", grad_label_style, .{});
    y += 15;

    const lin_stops2 = [_]platen.ColorStop{
        .{ .offset = 0.0, .color = platen.Color.rgb(255, 255, 0) },
        .{ .offset = 1.0, .color = platen.Color.rgb(0, 128, 0) },
    };
    const grad2 = try doc.addLinearGradient(.{
        .x0 = 50,
        .y0 = y,
        .x1 = 50,
        .y1 = y + 50,
        .stops = &lin_stops2,
    });
    try doc.fillRectGradient(.{ .x = 50, .y = y, .width = 200, .height = 50 }, grad2);
    y += 70;

    // Linear gradient 3 colors
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Linear gradient (3 colors):", grad_label_style, .{});
    y += 15;

    const lin_stops3 = [_]platen.ColorStop{
        .{ .offset = 0.0, .color = platen.Color.red },
        .{ .offset = 0.5, .color = platen.Color.white },
        .{ .offset = 1.0, .color = platen.Color.blue },
    };
    const grad3 = try doc.addLinearGradient(.{
        .x0 = 50,
        .y0 = y,
        .x1 = 250,
        .y1 = y,
        .stops = &lin_stops3,
    });
    try doc.fillRectGradient(.{ .x = 50, .y = y, .width = 200, .height = 50 }, grad3);
    y += 70;

    // Radial gradient
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Radial gradient:", grad_label_style, .{});
    y += 15;

    const rad_stops = [_]platen.ColorStop{
        .{ .offset = 0.0, .color = platen.Color.white },
        .{ .offset = 1.0, .color = platen.Color.rgb(0, 0, 128) },
    };
    const grad4 = try doc.addRadialGradient(.{
        .x0 = 150,
        .y0 = y + 40,
        .r0 = 0,
        .x1 = 150,
        .y1 = y + 40,
        .r1 = 60,
        .stops = &rad_stops,
    });
    try doc.fillRectGradient(.{ .x = 50, .y = y, .width = 200, .height = 80 }, grad4);

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generateOpacityTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    try doc.addPage(.{});

    const title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true };
    const label_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10 };

    // Title
    _ = try doc.writeAt(.{ .x = 50, .y = 30 }, "Opacity Test", title_style, .{});

    var y: f64 = 70;

    // Overlapping rectangles with fill opacity
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Fill opacity (overlapping rectangles):", label_style, .{});
    y += 20;

    // Draw a solid background rectangle
    try doc.drawRect(.{ .x = 50, .y = y, .width = 120, .height = 80 }, .{
        .fill = .{ .color = platen.Color.red },
    });
    // Draw overlapping semi-transparent blue rectangle
    try doc.drawRect(.{ .x = 90, .y = y + 20, .width = 120, .height = 80 }, .{
        .fill = .{ .color = platen.Color.blue, .opacity = 0.5 },
    });
    // Draw another overlapping green rectangle
    try doc.drawRect(.{ .x = 130, .y = y + 40, .width = 120, .height = 80 }, .{
        .fill = .{ .color = platen.Color.rgb(0, 200, 0), .opacity = 0.5 },
    });
    y += 150;

    // Different opacity levels
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Fill opacity levels (100%, 75%, 50%, 25%):", label_style, .{});
    y += 20;

    const opacities = [_]f64{ 1.0, 0.75, 0.5, 0.25 };
    for (opacities, 0..) |op, i| {
        try doc.drawRect(.{ .x = 50 + @as(f64, @floatFromInt(i)) * 55, .y = y, .width = 50, .height = 50 }, .{
            .fill = .{ .color = platen.Color.rgb(0, 100, 200), .opacity = op },
        });
    }
    y += 80;

    // Stroke opacity
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Stroke opacity (overlapping lines):", label_style, .{});
    y += 20;

    // Draw lines with different stroke opacities
    try doc.drawLine(.{ .x = 50, .y = y }, .{ .x = 250, .y = y + 60 }, .{
        .color = platen.Color.red,
        .width = 8,
    });
    try doc.drawLine(.{ .x = 50, .y = y + 60 }, .{ .x = 250, .y = y }, .{
        .color = platen.Color.blue,
        .width = 8,
        .opacity = 0.5,
    });
    y += 90;

    // Combined fill and stroke opacity
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Combined fill + stroke opacity:", label_style, .{});
    y += 20;

    try doc.drawRoundedRect(.{ .x = 50, .y = y, .width = 100, .height = 60 }, 10, .{
        .fill = .{ .color = platen.Color.rgb(255, 200, 0), .opacity = 0.6 },
        .stroke = .{ .color = platen.Color.rgb(100, 0, 100), .width = 4, .opacity = 0.8 },
    });

    // Semi-transparent circle
    try doc.drawCircle(.{ .x = 250, .y = y + 30 }, 35, .{
        .fill = .{ .color = platen.Color.rgb(0, 180, 180), .opacity = 0.4 },
        .stroke = .{ .color = platen.Color.black, .width = 2 },
    });
    y += 100;

    // Ellipse with opacity
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Ellipse with opacity:", label_style, .{});
    y += 20;

    try doc.drawEllipse(.{ .x = 50, .y = y, .width = 120, .height = 60 }, .{
        .fill = .{ .color = platen.Color.rgb(200, 100, 50), .opacity = 0.7 },
    });
    y += 90;

    // Text opacity: semi-transparent text over a solid background bar.
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Text opacity (100%, 60%, 30%):", label_style, .{});
    y += 25;

    try doc.drawRect(.{ .x = 50, .y = y - 18, .width = 300, .height = 26 }, .{
        .fill = .{ .color = platen.Color.rgb(255, 210, 0) },
    });
    const big = platen.TextStyle{ .font = platen.Font.helvetica, .size = 20, .bold = true, .color = platen.Color.rgb(0, 60, 160) };
    _ = try doc.writeAt(.{ .x = 55, .y = y }, "Full", big, .{});
    var faded = big;
    faded.opacity = 0.6;
    _ = try doc.writeAt(.{ .x = 130, .y = y }, "60%", faded, .{});
    faded.opacity = 0.3;
    _ = try doc.writeAt(.{ .x = 210, .y = y }, "30%", faded, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generateMetadataTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    // Set document metadata
    doc.setMetadata(.{
        .title = "platen Metadata Demo",
        .author = "platen Library",
        .subject = "Demonstrating PDF metadata support",
        .keywords = "pdf, zig, metadata, demo",
        .creator = "platen CLI tool",
    });

    try doc.addPage(.{});

    const meta_title_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 24, .bold = true };
    const meta12_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
    const meta_bold11_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 11, .bold = true };
    const meta11_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 11 };
    const meta_italic10_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10, .italic = true };

    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Document with Metadata", meta_title_style, .{});

    var y: f64 = 100;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "This PDF has the following metadata set in the Info dictionary:", meta12_style, .{});
    y += 30;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Title:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "platen Metadata Demo", meta11_style, .{});
    y += 18;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Author:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "platen Library", meta11_style, .{});
    y += 18;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Subject:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "Demonstrating PDF metadata support", meta11_style, .{});
    y += 18;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Keywords:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "pdf, zig, metadata, demo", meta11_style, .{});
    y += 18;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Creator:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "platen CLI tool", meta11_style, .{});
    y += 18;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Producer:", meta_bold11_style, .{});
    _ = try doc.writeAt(.{ .x = 120, .y = y }, "platen (default)", meta11_style, .{});
    y += 40;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Use 'pdfinfo' or your PDF viewer's document properties to verify.", meta_italic10_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

fn generatePdfaTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    // Set PDF/A-1b conformance
    doc.setConformance(.pdfa_1b);

    // Set document metadata (required for PDF/A)
    doc.setMetadata(.{
        .title = "platen PDF/A-1b Test Document",
        .author = "platen Library",
        .subject = "Testing PDF/A-1b conformance",
        .keywords = "pdf, pdfa, archival, conformance",
        .creator = "platen pdfa-test command",
    });

    // Load embedded font (PDF/A requires all fonts to be embedded)
    const font = doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity) catch |err| {
        try print("Error: Could not load font for PDF/A test: {}\n", .{err});
        try print("  PDF/A-1b requires embedded fonts. Make sure test/fonts/Inter/Inter-Regular.ttf exists.\n", .{});
        return err;
    };

    try doc.addPage(.{});

    const title_style = platen.TextStyle{ .font = font, .size = 24 };
    const body_style = platen.TextStyle{ .font = font, .size = 12 };
    const small_style = platen.TextStyle{ .font = font, .size = 10 };

    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "PDF/A-1b Test Document", title_style, .{});

    var y: f64 = 100;
    _ = try doc.writeAt(.{ .x = 50, .y = y }, "This PDF conforms to PDF/A-1b (ISO 19005-1:2005 Level B).", body_style, .{});
    y += 30;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "PDF/A-1b Requirements:", body_style, .{});
    y += 20;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- No transparency (opacity must be 1.0)", small_style, .{});
    y += 15;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- All fonts must be embedded (using Inter font)", small_style, .{});
    y += 15;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- XMP metadata required", small_style, .{});
    y += 15;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- OutputIntent with ICC profile required", small_style, .{});
    y += 15;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- MarkInfo dictionary required", small_style, .{});
    y += 15;
    _ = try doc.writeAt(.{ .x = 70, .y = y }, "- Document ID in trailer required", small_style, .{});
    y += 30;

    // Draw some shapes (fully opaque - required for PDF/A-1b)
    try doc.drawRect(.{ .x = 50, .y = y, .width = 100, .height = 50 }, .{
        .fill = .{ .color = platen.Color.rgb(200, 220, 255) },
        .stroke = .{ .color = platen.Color.rgb(0, 50, 150) },
    });
    try doc.drawRect(.{ .x = 160, .y = y, .width = 100, .height = 50 }, .{
        .fill = .{ .color = platen.Color.rgb(255, 220, 200) },
        .stroke = .{ .color = platen.Color.rgb(150, 50, 0) },
    });
    try doc.drawRect(.{ .x = 270, .y = y, .width = 100, .height = 50 }, .{
        .fill = .{ .color = platen.Color.rgb(220, 255, 220) },
        .stroke = .{ .color = platen.Color.rgb(0, 150, 50) },
    });
    y += 70;

    _ = try doc.writeAt(.{ .x = 50, .y = y }, "Validate with: verapdf --flavour 1b <file>", small_style, .{});

    const pdf = try doc.output();
    defer allocator.free(pdf);

    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf });
}

// Use shared test infrastructure from platen module
const testing = @import("testing.zig");
const test_cases = integration_tests.cases;

const TestResult = struct {
    name: []const u8,
    passed: bool,
};

fn checkAllReferences(allocator: std.mem.Allocator, mode: testing.CompareMode) !void {
    var passed: usize = 0;
    var failed: usize = 0;
    var results = std.ArrayListUnmanaged(TestResult).empty;
    defer results.deinit(allocator);

    // Show mode being used
    const mode_name = switch (mode) {
        .structural => "structural (qpdf)",
        .semantic => "semantic (pdftotext)",
        .auto => "auto (structural -> semantic)",
    };
    try print("Comparison mode: {s}\n\n", .{mode_name});

    // Create output directory for test results
    std.Io.Dir.cwd().createDir(app_io, "test/output", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    for (test_cases) |tc| {
        const pdf = try tc.generate(allocator);
        defer allocator.free(pdf);

        var path_buf: [256]u8 = undefined;
        const ref_path = std.fmt.bufPrint(&path_buf, "test/reference/{s}.pdf", .{tc.name}) catch unreachable;

        // Save actual output for the report
        var actual_path_buf: [256]u8 = undefined;
        const actual_path = std.fmt.bufPrint(&actual_path_buf, "test/output/{s}_actual.pdf", .{tc.name}) catch unreachable;
        {
            try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = actual_path, .data = pdf });
        }

        // Copy reference PDF to output folder (browsers block cross-directory file:// embeds)
        var expected_path_buf: [256]u8 = undefined;
        const expected_output_path = std.fmt.bufPrint(&expected_path_buf, "test/output/{s}_expected.pdf", .{tc.name}) catch unreachable;
        // Copy reference to expected output (best-effort)
        if (std.Io.Dir.cwd().readFileAlloc(app_io, ref_path, allocator, .limited(50 * 1024 * 1024))) |ref_data| {
            defer allocator.free(ref_data);
            std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = expected_output_path, .data = ref_data }) catch {};
        } else |_| {}

        // Use semantic comparison with options if needed (for SVG Form XObjects)
        var result = if (tc.skip_fonts)
            testing.compareWithReferenceSemantic(app_io, allocator, pdf, ref_path, .{ .skip_fonts = true }) catch |err| {
                try print("FAIL {s}: {any}\n", .{ tc.name, err });
                failed += 1;
                try results.append(allocator, .{ .name = tc.name, .passed = false });
                continue;
            }
        else
            testing.compareWithReferenceMode(app_io, allocator, pdf, ref_path, mode, .{}) catch |err| {
                try print("FAIL {s}: {any}\n", .{ tc.name, err });
                failed += 1;
                try results.append(allocator, .{ .name = tc.name, .passed = false });
                continue;
            };
        defer result.deinit();

        const used_mode = switch (result.mode_used) {
            .structural => "(structural)",
            .semantic => "(semantic)",
            .auto => "",
        };

        if (result.equal) {
            try print("PASS {s} {s}\n", .{ tc.name, used_mode });
            passed += 1;
            try results.append(allocator, .{ .name = tc.name, .passed = true });
        } else {
            try print("FAIL {s} {s}\n", .{ tc.name, used_mode });
            if (result.diff) |diff| {
                // Print first few lines of diff
                var lines: usize = 0;
                for (diff) |c| {
                    if (c == '\n') lines += 1;
                    if (lines >= 5) break;
                }
                const preview = diff[0..@min(500, diff.len)];
                try print("  {s}\n", .{preview});
            }
            failed += 1;
            try results.append(allocator, .{ .name = tc.name, .passed = false });
        }
    }

    try print("\nResults: {d} passed, {d} failed\n", .{ passed, failed });

    // Generate HTML report
    try generateHtmlReport(allocator, results.items, passed, failed);
    try print("\nReport: test/output/report.html\n", .{});

    if (failed > 0) {
        try print("  open test/output/report.html\n", .{});
    }
}

fn generateHtmlReport(allocator: std.mem.Allocator, results: []const TestResult, passed: usize, failed: usize) !void {
    var html = std.ArrayListUnmanaged(u8).empty;
    defer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>platen Test Results</title>
        \\  <style>
        \\    body { font-family: -apple-system, sans-serif; margin: 20px; background: #f5f5f5; }
        \\    h1 { color: #333; }
        \\    .summary { font-size: 18px; margin: 20px 0; display: flex; gap: 20px; align-items: center; }
        \\    .pass { color: #22863a; }
        \\    .fail { color: #cb2431; }
        \\    .controls { font-size: 14px; }
        \\    .controls button { margin-left: 8px; padding: 4px 12px; cursor: pointer; }
        \\    .test-card { background: white; border-radius: 8px; margin: 16px 0; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        \\    .test-header { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
        \\    .status { font-weight: bold; padding: 4px 12px; border-radius: 4px; }
        \\    .status.pass { background: #dcffe4; }
        \\    .status.fail { background: #ffeef0; }
        \\    .pdf-compare { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        \\    .pdf-frame { border: 1px solid #ddd; border-radius: 4px; overflow: hidden; }
        \\    .pdf-label { font-size: 12px; color: #666; margin-bottom: 4px; font-weight: 500; padding: 8px; background: #f9f9f9; }
        \\    embed { width: 100%; height: 500px; display: block; }
        \\    .collapsed .pdf-compare { display: none; }
        \\    .toggle { cursor: pointer; color: #0366d6; font-size: 14px; user-select: none; }
        \\    .toggle:hover { text-decoration: underline; }
        \\  </style>
        \\  <script>
        \\    function toggleAll(show) {
        \\      document.querySelectorAll('.test-card').forEach(card => {
        \\        if (show) card.classList.remove('collapsed');
        \\        else card.classList.add('collapsed');
        \\      });
        \\      updateToggles();
        \\    }
        \\    function toggleCard(el) {
        \\      el.closest('.test-card').classList.toggle('collapsed');
        \\      updateToggles();
        \\    }
        \\    function updateToggles() {
        \\      document.querySelectorAll('.test-card').forEach(card => {
        \\        const toggle = card.querySelector('.toggle');
        \\        if (toggle) toggle.textContent = card.classList.contains('collapsed') ? '[show]' : '[hide]';
        \\      });
        \\    }
        \\  </script>
        \\</head>
        \\<body>
        \\  <h1>platen Test Results</h1>
        \\
    );

    // Summary with controls
    var buf: [512]u8 = undefined;
    var msg = try std.fmt.bufPrint(&buf,
        \\  <div class="summary">
        \\    <span><span class="pass">{d} passed</span>, <span class="fail">{d} failed</span></span>
        \\    <span class="controls">
        \\      <button onclick="toggleAll(true)">Show All</button>
        \\      <button onclick="toggleAll(false)">Hide All</button>
        \\    </span>
        \\  </div>
        \\
    , .{ passed, failed });
    try html.appendSlice(allocator, msg);

    // Test cards - collapsed by default
    for (results) |r| {
        const status_class = if (r.passed) "pass" else "fail";
        const status_text = if (r.passed) "PASS" else "FAIL";

        msg = try std.fmt.bufPrint(&buf,
            \\  <div class="test-card collapsed">
            \\    <div class="test-header">
            \\      <span class="status {s}">{s}</span>
            \\      <strong>{s}</strong>
            \\      <span class="toggle" onclick="toggleCard(this)">[show]</span>
            \\    </div>
            \\    <div class="pdf-compare">
            \\
        , .{ status_class, status_text, r.name });
        try html.appendSlice(allocator, msg);

        // Expected (reference) PDF - use copy in output folder
        msg = try std.fmt.bufPrint(&buf,
            \\      <div class="pdf-frame">
            \\        <div class="pdf-label">Expected (fpdf2 reference)</div>
            \\        <embed src="{s}_expected.pdf" type="application/pdf">
            \\      </div>
            \\
        , .{r.name});
        try html.appendSlice(allocator, msg);

        // Actual (generated) PDF
        msg = try std.fmt.bufPrint(&buf,
            \\      <div class="pdf-frame">
            \\        <div class="pdf-label">Actual (platen output)</div>
            \\        <embed src="{s}_actual.pdf" type="application/pdf">
            \\      </div>
            \\
        , .{r.name});
        try html.appendSlice(allocator, msg);

        try html.appendSlice(allocator, "    </div>\n  </div>\n");
    }

    try html.appendSlice(allocator, "</body>\n</html>\n");

    // Write report
    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = "test/output/report.html", .data = html.items });
}

fn generateOpticalTestPdf(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();

    // Load a variety of fonts
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const inter_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf", .identity);
    const charter = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
    const gentium = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity);
    const satoshi = try doc.loadFont("test/fonts/Satoshi/Satoshi-Regular.otf", .identity);
    const courier = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

    const FontEntry = struct {
        name: []const u8,
        font: platen.Font,
    };
    const test_fonts = [_]FontEntry{
        .{ .name = "Inter", .font = inter },
        .{ .name = "Charter", .font = charter },
        .{ .name = "Gentium", .font = gentium },
        .{ .name = "Satoshi", .font = satoshi },
        .{ .name = "Courier Prime", .font = courier },
    };

    const font_size: f64 = 24;
    const box_height: f64 = 44;
    const box_width: f64 = 480;
    const left_margin: f64 = 56;
    const box_spacing: f64 = 12;
    const label_style = platen.TextStyle{ .font = inter, .size = 9, .color = platen.Color.rgb(120, 120, 120) };
    const title_style = platen.TextStyle{ .font = inter_bold, .size = 18 };
    const subtitle_style = platen.TextStyle{ .font = inter, .size = 10, .color = platen.Color.rgb(100, 100, 100) };

    const thin_stroke = platen.StrokeStyle{ .color = platen.Color.rgb(180, 180, 180), .width = 0.5 };
    const cap_line_stroke = platen.StrokeStyle{ .color = platen.Color.rgb(255, 80, 80), .width = 0.3, .dash = .{ .dash = 2, .gap = 2 } };
    const asc_line_stroke = platen.StrokeStyle{ .color = platen.Color.rgb(80, 80, 255), .width = 0.3, .dash = .{ .dash = 2, .gap = 2 } };

    try doc.addPage(.{});
    var y: f64 = 40;

    // Title
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 18 }, "Optical Top Alignment Test", title_style, .{});
    y += 30;
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 10 }, "Text positioned so cap-height touches the box top edge", subtitle_style, .{});
    y += 20;

    // Legend
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 9 }, "Legend:", label_style, .{});
    try doc.drawLine(.{ .x = left_margin + 40, .y = y + 5 }, .{ .x = left_margin + 60, .y = y + 5 }, cap_line_stroke);
    _ = try doc.writeAt(.{ .x = left_margin + 62, .y = y + 9 }, "cap-height", .{ .font = inter, .size = 9, .color = platen.Color.rgb(255, 80, 80) }, .{});
    try doc.drawLine(.{ .x = left_margin + 115, .y = y + 5 }, .{ .x = left_margin + 135, .y = y + 5 }, asc_line_stroke);
    _ = try doc.writeAt(.{ .x = left_margin + 137, .y = y + 9 }, "ascender", .{ .font = inter, .size = 9, .color = platen.Color.rgb(80, 80, 255) }, .{});
    y += 20;

    // --- Section 1: Naive top alignment (baseline = box top + font_size) ---
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 12 }, "NAIVE: baseline = box.y + font_size (visual gap at top)", .{ .font = inter_bold, .size = 11, .color = platen.Color.rgb(60, 60, 60) }, .{});
    y += 22;

    for (test_fonts) |entry| {
        const style = platen.TextStyle{ .font = entry.font, .size = font_size };
        const fm = doc.getFontMetricsStyled(style);

        // Draw box
        try doc.drawRect(.{ .x = left_margin, .y = y, .width = box_width, .height = box_height }, .{ .stroke = thin_stroke });

        // Naive: place baseline at box top + font_size (ascender extends into font_size space)
        const naive_baseline = y + font_size;
        _ = try doc.writeAt(.{ .x = left_margin + 6, .y = naive_baseline }, "Hbdgpq Ty", style, .{});

        // Draw cap-height line (from baseline upward)
        const cap_y = naive_baseline - fm.cap_height;
        try doc.drawLine(.{ .x = left_margin, .y = cap_y }, .{ .x = left_margin + box_width, .y = cap_y }, cap_line_stroke);

        // Draw ascender line
        const asc_y = naive_baseline - fm.ascender;
        try doc.drawLine(.{ .x = left_margin, .y = asc_y }, .{ .x = left_margin + box_width, .y = asc_y }, asc_line_stroke);

        // Label
        _ = try doc.writeAt(.{ .x = left_margin + box_width + 6, .y = y + 14 }, entry.name, label_style, .{});

        y += box_height + box_spacing;
    }

    y += 10;

    // --- Section 2: Optical alignment (baseline = box top + cap_height) ---
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 12 }, "OPTICAL: baseline = box.y + cap_height (capitals touch top edge)", .{ .font = inter_bold, .size = 11, .color = platen.Color.rgb(60, 60, 60) }, .{});
    y += 22;

    for (test_fonts) |entry| {
        const style = platen.TextStyle{ .font = entry.font, .size = font_size };
        const fm = doc.getFontMetricsStyled(style);

        // Draw box
        try doc.drawRect(.{ .x = left_margin, .y = y, .width = box_width, .height = box_height }, .{ .stroke = thin_stroke });

        // Optical: place baseline so cap_height aligns with box top
        const optical_baseline = y + fm.cap_height;
        _ = try doc.writeAt(.{ .x = left_margin + 6, .y = optical_baseline }, "Hbdgpq Ty", style, .{});

        // Draw cap-height line (should be at box top)
        const cap_y = optical_baseline - fm.cap_height;
        try doc.drawLine(.{ .x = left_margin, .y = cap_y }, .{ .x = left_margin + box_width, .y = cap_y }, cap_line_stroke);

        // Draw ascender line (above box top for tall letters)
        const asc_y = optical_baseline - fm.ascender;
        try doc.drawLine(.{ .x = left_margin, .y = asc_y }, .{ .x = left_margin + box_width, .y = asc_y }, asc_line_stroke);

        // Label
        _ = try doc.writeAt(.{ .x = left_margin + box_width + 6, .y = y + 14 }, entry.name, label_style, .{});

        y += box_height + box_spacing;
    }

    // --- Page 2: Different sizes and mixed-case text ---
    try doc.addPage(.{});
    y = 40;

    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 18 }, "Optical Alignment at Various Sizes", title_style, .{});
    y += 30;
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 10 }, "All text uses cap-height optical alignment", subtitle_style, .{});
    y += 24;

    const sizes = [_]f64{ 12, 16, 24, 36, 48 };
    for (sizes) |size| {
        const style = platen.TextStyle{ .font = inter, .size = size };
        const fm = doc.getFontMetricsStyled(style);
        const bh = fm.cap_height + @abs(fm.descender) + 8; // enough room for descenders + padding

        // Draw box
        try doc.drawRect(.{ .x = left_margin, .y = y, .width = box_width, .height = bh }, .{ .stroke = thin_stroke });

        // Optical alignment
        const baseline = y + fm.cap_height;
        _ = try doc.writeAt(.{ .x = left_margin + 6, .y = baseline }, "Hbdgpq Typography", style, .{});

        // Cap-height line
        try doc.drawLine(.{ .x = left_margin, .y = y }, .{ .x = left_margin + box_width, .y = y }, cap_line_stroke);

        // Size label
        var size_buf: [32]u8 = undefined;
        const size_label = std.fmt.bufPrint(&size_buf, "{d}pt", .{size}) catch "?";
        _ = try doc.writeAt(.{ .x = left_margin + box_width + 6, .y = y + 12 }, size_label, label_style, .{});

        y += bh + box_spacing;
    }

    y += 16;

    // Side-by-side comparison: naive vs optical in same row
    _ = try doc.writeAt(.{ .x = left_margin, .y = y + 12 }, "Side by side: Naive (left) vs Optical (right)", .{ .font = inter_bold, .size = 11, .color = platen.Color.rgb(60, 60, 60) }, .{});
    y += 24;

    const half_width: f64 = 232;
    const compare_size: f64 = 30;
    for (test_fonts) |entry| {
        const style = platen.TextStyle{ .font = entry.font, .size = compare_size };
        const fm = doc.getFontMetricsStyled(style);
        const bh: f64 = 50;

        // Left box: naive
        try doc.drawRect(.{ .x = left_margin, .y = y, .width = half_width, .height = bh }, .{ .stroke = thin_stroke });
        const naive_bl = y + compare_size;
        _ = try doc.writeAt(.{ .x = left_margin + 6, .y = naive_bl }, "Hbdgpq", style, .{});

        // Right box: optical
        try doc.drawRect(.{ .x = left_margin + half_width + 16, .y = y, .width = half_width, .height = bh }, .{ .stroke = thin_stroke });
        const optical_bl = y + fm.cap_height;
        _ = try doc.writeAt(.{ .x = left_margin + half_width + 22, .y = optical_bl }, "Hbdgpq", style, .{});

        // Labels
        _ = try doc.writeAt(.{ .x = left_margin, .y = y - 3 }, entry.name, label_style, .{});
        _ = try doc.writeAt(.{ .x = left_margin + half_width + 16, .y = y - 3 }, entry.name, label_style, .{});

        y += bh + box_spacing + 4;
    }

    // Write output
    const pdf_data = try doc.output();
    defer allocator.free(pdf_data);
    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = output_path, .data = pdf_data });
}
