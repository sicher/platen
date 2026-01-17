//! zpdf command line tool

const std = @import("std");
const zpdf = @import("zpdf");

const stdout = std.fs.File.stdout();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        try printUsage();
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version")) {
        try print("zpdf version {s}\n", .{zpdf.version});
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
            try print("Usage: zpdf font-info <font.ttf>\n", .{});
            return;
        }
        try showFontInfo(allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "embed-test")) {
        // Generate a PDF with embedded font
        const font_path = if (args.len > 2) args[2] else "test/fonts/Courier Prime/Courier Prime.ttf";
        const output_path = if (args.len > 3) args[3] else "embed_test.pdf";
        try generateEmbedTestPdf(allocator, font_path, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else {
        try printUsage();
    }
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.BufferTooSmall;
    try stdout.writeAll(msg);
}

fn printUsage() !void {
    const usage =
        \\zpdf - PDF generation library and tool
        \\
        \\Usage: zpdf <command> [args]
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
        \\  embed-test [ttf] [out]  Generate PDF with embedded font
        \\
    ;
    try stdout.writeAll(usage);
}

fn showFontInfo(allocator: std.mem.Allocator, path: []const u8) !void {
    const result = zpdf.ttf.Font.fromFile(allocator, path) catch |err| {
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

fn generateTestPdf(allocator: std.mem.Allocator, path: []const u8) !void {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();

    const pdf = try doc.output();
    defer allocator.free(pdf);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(pdf);
}

fn generateTextPdf(allocator: std.mem.Allocator, path: []const u8) !void {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.textAt(50, 50, "Hello, World!");

    try doc.setFont(.helvetica_bold, 16);
    try doc.textAt(50, 100, "This is zpdf - a PDF library for Zig");

    try doc.setFont(.times_roman, 12);
    try doc.textAt(50, 150, "Built-in fonts: Helvetica, Times, Courier, Symbol, ZapfDingbats");

    try doc.setFont(.courier, 10);
    try doc.textAt(50, 200, "Fixed-width font for code");

    const pdf = try doc.output();
    defer allocator.free(pdf);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(pdf);
}

fn generateEmbedTestPdf(allocator: std.mem.Allocator, font_path: []const u8, output_path: []const u8) !void {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Load the embedded font
    const custom_font = doc.loadFont(font_path) catch |err| {
        try print("Error loading font '{s}': {}\n", .{ font_path, err });
        return;
    };

    try doc.addPage();

    // Title with standard font
    try doc.setFont(.helvetica_bold, 24);
    try doc.textAt(50, 50, "Embedded Font Test");

    // Show font info
    try doc.setFont(.helvetica, 12);
    var info_buf: [256]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "Font: {s}", .{custom_font.name}) catch "Font: Unknown";
    try doc.textAt(50, 80, info);

    // Use embedded font at various sizes
    try doc.setEmbeddedFont(custom_font, 24);
    try doc.textAt(50, 120, "The quick brown fox jumps over the lazy dog.");

    try doc.setEmbeddedFont(custom_font, 18);
    try doc.textAt(50, 160, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");

    try doc.setEmbeddedFont(custom_font, 18);
    try doc.textAt(50, 190, "abcdefghijklmnopqrstuvwxyz");

    try doc.setEmbeddedFont(custom_font, 18);
    try doc.textAt(50, 220, "0123456789 !@#$%^&*()");

    // Mix with standard fonts
    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 270, "Standard font (Helvetica) for comparison");

    try doc.setEmbeddedFont(custom_font, 12);
    try doc.textAt(50, 290, "Embedded font at same size (12pt)");

    // Multiple lines
    try doc.setEmbeddedFont(custom_font, 14);
    try doc.textAt(50, 340, "Line 1: This is a test of the embedded font.");
    try doc.textAt(50, 360, "Line 2: Lorem ipsum dolor sit amet.");
    try doc.textAt(50, 380, "Line 3: Consectetur adipiscing elit.");

    // Page 2 - stress test
    try doc.addPage();
    try doc.setFont(.helvetica_bold, 18);
    try doc.textAt(50, 50, "Page 2: Extended Character Test");

    try doc.setEmbeddedFont(custom_font, 14);
    var y: f64 = 80;

    // ASCII printable range
    const line1 = " !\"#$%&'()*+,-./";
    const line2 = "0123456789:;<=>?";
    const line3 = "@ABCDEFGHIJKLMNO";
    const line4 = "PQRSTUVWXYZ[\\]^_";
    const line5 = "`abcdefghijklmno";
    const line6 = "pqrstuvwxyz{|}~";

    try doc.textAt(50, y, line1);
    y += 20;
    try doc.textAt(50, y, line2);
    y += 20;
    try doc.textAt(50, y, line3);
    y += 20;
    try doc.textAt(50, y, line4);
    y += 20;
    try doc.textAt(50, y, line5);
    y += 20;
    try doc.textAt(50, y, line6);
    y += 30;

    // Show metrics
    try doc.setFont(.helvetica, 10);
    var metrics_buf: [256]u8 = undefined;

    const ascent_info = std.fmt.bufPrint(&metrics_buf, "Ascent: {d}, Descent: {d}, CapHeight: {d}", .{
        custom_font.ascent,
        custom_font.descent,
        custom_font.cap_height,
    }) catch "Metrics unavailable";
    try doc.textAt(50, y, ascent_info);
    y += 15;

    const bbox_info = std.fmt.bufPrint(&metrics_buf, "BBox: [{d}, {d}, {d}, {d}]", .{
        custom_font.bbox[0],
        custom_font.bbox[1],
        custom_font.bbox[2],
        custom_font.bbox[3],
    }) catch "BBox unavailable";
    try doc.textAt(50, y, bbox_info);

    const pdf = try doc.output();
    defer allocator.free(pdf);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(pdf);
}

// Use shared test infrastructure from zpdf module
const testing = zpdf.testing;
const test_cases = zpdf.integration_tests.cases;

const TestResult = struct {
    name: []const u8,
    passed: bool,
};

fn checkAllReferences(allocator: std.mem.Allocator, mode: testing.CompareMode) !void {
    var passed: usize = 0;
    var failed: usize = 0;
    var results = std.ArrayListUnmanaged(TestResult){};
    defer results.deinit(allocator);

    // Show mode being used
    const mode_name = switch (mode) {
        .structural => "structural (qpdf)",
        .semantic => "semantic (pdftotext)",
        .auto => "auto (structural -> semantic)",
    };
    try print("Comparison mode: {s}\n\n", .{mode_name});

    // Create output directory for test results
    std.fs.cwd().makeDir("test/output") catch |err| {
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
            const file = try std.fs.cwd().createFile(actual_path, .{});
            defer file.close();
            try file.writeAll(pdf);
        }

        // Copy reference PDF to output folder (browsers block cross-directory file:// embeds)
        var expected_path_buf: [256]u8 = undefined;
        const expected_output_path = std.fmt.bufPrint(&expected_path_buf, "test/output/{s}_expected.pdf", .{tc.name}) catch unreachable;
        std.fs.cwd().copyFile(ref_path, std.fs.cwd(), expected_output_path, .{}) catch {};

        var result = testing.compareWithReferenceMode(allocator, pdf, ref_path, mode, .{}) catch |err| {
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
    var html = std.ArrayListUnmanaged(u8){};
    defer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>zpdf Test Results</title>
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
        \\  <h1>zpdf Test Results</h1>
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
            \\        <div class="pdf-label">Actual (zpdf output)</div>
            \\        <embed src="{s}_actual.pdf" type="application/pdf">
            \\      </div>
            \\
        , .{r.name});
        try html.appendSlice(allocator, msg);

        try html.appendSlice(allocator, "    </div>\n  </div>\n");
    }

    try html.appendSlice(allocator, "</body>\n</html>\n");

    // Write report
    const file = try std.fs.cwd().createFile("test/output/report.html", .{});
    defer file.close();
    try file.writeAll(html.items);
}
