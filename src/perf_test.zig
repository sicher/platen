//! Performance Test Suite
//!
//! Stress tests the PDF library with heavy workloads to measure performance.
//! Run with: zig build perf -- [options]
//!
//! Options:
//!   --pages=N       Number of pages to generate (default: 100)
//!   --iterations=N  Number of test iterations (default: 3)
//!   --output=PATH   Write final PDF to file (optional)
//!   --quiet         Only show summary

const std = @import("std");
const zpdf = @import("zpdf");

const Timer = struct {
    start: i64,
    name: []const u8,

    fn begin(name: []const u8) Timer {
        return .{ .start = std.time.milliTimestamp(), .name = name };
    }

    fn end(self: Timer) i64 {
        return std.time.milliTimestamp() - self.start;
    }

    fn endPrint(self: Timer, quiet: bool) i64 {
        const elapsed = self.end();
        if (!quiet) {
            std.debug.print("  {s}: {d}ms\n", .{ self.name, elapsed });
        }
        return elapsed;
    }
};

const TestConfig = struct {
    pages: u32 = 100,
    iterations: u32 = 3,
    output_path: ?[]const u8 = null,
    quiet: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    const config = parseArgs(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        return;
    };

    std.debug.print("\n=== ZPDF Performance Test ===\n", .{});
    std.debug.print("Pages: {d}, Iterations: {d}\n\n", .{ config.pages, config.iterations });

    var total_times = [_]i64{0} ** 6;
    var pdf_bytes: ?[]u8 = null;
    defer if (pdf_bytes) |b| allocator.free(b);

    for (0..config.iterations) |i| {
        if (!config.quiet) {
            std.debug.print("--- Iteration {d}/{d} ---\n", .{ i + 1, config.iterations });
        }

        const result = try runFullTest(allocator, config);
        total_times[0] += result.font_load_ms;
        total_times[1] += result.simple_text_ms;
        total_times[2] += result.opentype_ms;
        total_times[3] += result.unicode_ms;
        total_times[4] += result.text_flow_ms;
        total_times[5] += result.output_ms;

        // Keep last PDF for output
        if (pdf_bytes) |b| allocator.free(b);
        pdf_bytes = result.pdf_data;

        if (!config.quiet) {
            std.debug.print("  Total: {d}ms, Size: {d} KB\n\n", .{
                result.total_ms,
                result.pdf_data.len / 1024,
            });
        }
    }

    // Summary
    const n: i64 = @intCast(config.iterations);
    std.debug.print("=== SUMMARY (avg of {d} iterations) ===\n", .{config.iterations});
    std.debug.print("  Font loading:    {d}ms\n", .{@divTrunc(total_times[0], n)});
    std.debug.print("  Simple text:     {d}ms\n", .{@divTrunc(total_times[1], n)});
    std.debug.print("  OpenType heavy:  {d}ms\n", .{@divTrunc(total_times[2], n)});
    std.debug.print("  Unicode/marks:   {d}ms\n", .{@divTrunc(total_times[3], n)});
    std.debug.print("  Text flow:       {d}ms\n", .{@divTrunc(total_times[4], n)});
    std.debug.print("  PDF output:      {d}ms\n", .{@divTrunc(total_times[5], n)});
    std.debug.print("  ---\n", .{});
    std.debug.print("  TOTAL:           {d}ms\n", .{@divTrunc(total_times[0] + total_times[1] + total_times[2] + total_times[3] + total_times[4] + total_times[5], n)});

    if (pdf_bytes) |data| {
        std.debug.print("  PDF size:        {d} KB\n", .{data.len / 1024});
    }

    // Write output if requested
    if (config.output_path) |path| {
        if (pdf_bytes) |data| {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
            std.debug.print("\nWrote: {s}\n", .{path});
        }
    }

    // Compression microbenchmark
    std.debug.print("\n=== Compression Microbenchmark ===\n", .{});
    try runCompressionBenchmark(allocator);

    // Shaping microbenchmark
    std.debug.print("\n=== Shaping Microbenchmark ===\n", .{});
    try runShapingBenchmark(allocator);
}

fn runCompressionBenchmark(allocator: std.mem.Allocator) !void {
    // Simulate typical PDF content: text commands
    const sample_line = "BT /F1 12 Tf 50 700 Td (The quick brown fox jumps over the lazy dog.) Tj ET\n";
    const repeat_count = 10000; // ~500KB of content

    // Build test data
    var test_data = std.ArrayListUnmanaged(u8){};
    defer test_data.deinit(allocator);
    for (0..repeat_count) |_| {
        try test_data.appendSlice(allocator, sample_line);
    }

    std.debug.print("Test data size: {d} KB\n", .{test_data.items.len / 1024});

    // Benchmark zlib compression at different levels
    const levels = [_]struct { level: i32, name: []const u8 }{
        .{ .level = 1, .name = "Level 1 (fastest)" },
        .{ .level = 6, .name = "Level 6 (default)" },
        .{ .level = 9, .name = "Level 9 (best)" },
    };

    for (levels) |l| {
        const t = Timer.begin(l.name);
        const compressed = try zpdf.zlib.compressLevel(allocator, test_data.items, l.level);
        const elapsed = t.end();
        defer allocator.free(compressed);

        const ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(test_data.items.len)) * 100;
        std.debug.print("  {s}: {d}ms, {d} KB ({d:.1}%)\n", .{
            l.name,
            elapsed,
            compressed.len / 1024,
            ratio,
        });
    }
}

fn runShapingBenchmark(allocator: std.mem.Allocator) !void {
    // Load Inter font with OpenType features
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    const emb = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", null);
    emb.encoding = .identity;

    // Test strings of varying complexity
    const test_cases = [_]struct {
        name: []const u8,
        text: []const u8,
        calt: bool,
        liga: bool,
        dlig: bool,
        frac: bool,
    }{
        .{ .name = "Simple ASCII (calt+liga)", .text = "The quick brown fox jumps over the lazy dog.", .calt = true, .liga = true, .dlig = false, .frac = false },
        .{ .name = "Ligatures (fi fl ffi)", .text = "office efficient difficult buffer fjord", .calt = true, .liga = true, .dlig = false, .frac = false },
        .{ .name = "Arrows (calt)", .text = "-> => <- <=> --> <-- != == >= <= 3*9", .calt = true, .liga = true, .dlig = false, .frac = false },
        .{ .name = "Fractions (frac)", .text = "1/2 3/4 5/8 7/16 11/32 1/3 2/3", .calt = true, .liga = true, .dlig = false, .frac = true },
        .{ .name = "All features", .text = "fi fl -> 1/2 WAVE efficient", .calt = true, .liga = true, .dlig = true, .frac = true },
        .{ .name = "No features", .text = "The quick brown fox jumps over the lazy dog.", .calt = false, .liga = false, .dlig = false, .frac = false },
        .{ .name = "Calt only", .text = "-> => <- <=> --> <--", .calt = true, .liga = false, .dlig = false, .frac = false },
        .{ .name = "Liga only", .text = "office efficient difficult buffer fjord", .calt = false, .liga = true, .dlig = false, .frac = false },
    };

    const iterations: usize = 5000;

    for (test_cases) |tc| {
        // Set feature flags
        emb.feature_flags.calt = tc.calt;
        emb.feature_flags.liga = tc.liga;
        emb.feature_flags.dlig = tc.dlig;
        emb.feature_flags.frac = tc.frac;

        const t = Timer.begin(tc.name);
        for (0..iterations) |_| {
            const glyphs = try emb.markUnicodeCharsUsed(tc.text, null);
            emb.allocator.free(glyphs);
        }
        const elapsed = t.end();
        const per_call = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("  {s}: {d}ms total, {d:.3}ms/call ({d} iters)\n", .{
            tc.name,
            elapsed,
            per_call,
            iterations,
        });
    }
}

const TestResult = struct {
    font_load_ms: i64,
    simple_text_ms: i64,
    opentype_ms: i64,
    unicode_ms: i64,
    text_flow_ms: i64,
    output_ms: i64,
    total_ms: i64,
    pdf_data: []u8,
};

fn runFullTest(allocator: std.mem.Allocator, config: TestConfig) !TestResult {
    const total_timer = Timer.begin("Total");
    var result: TestResult = undefined;

    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // 1. Font loading test (use separate doc to avoid polluting main doc with unused fonts)
    {
        const t = Timer.begin("Font loading");
        var timing_doc = zpdf.Document.init(allocator);
        defer timing_doc.deinit();

        // Load multiple fonts to measure parsing time
        const inter = try timing_doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", null);
        inter.encoding = .identity;
        const inter_bold = try timing_doc.loadFont("test/fonts/Inter/Inter-Bold.ttf", null);
        inter_bold.encoding = .identity;
        const inter_italic = try timing_doc.loadFont("test/fonts/Inter/Inter-Italic.ttf", null);
        inter_italic.encoding = .identity;
        const charter = try timing_doc.loadFont("test/fonts/Charter/Charter Regular.ttf", null);
        charter.encoding = .identity;
        const gentium = try timing_doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", null);
        gentium.encoding = .identity;
        const courier = try timing_doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", null);
        courier.encoding = .identity;

        result.font_load_ms = t.endPrint(config.quiet);
        _ = .{ inter, inter_bold, inter_italic, charter, gentium, courier };
    }

    // Load fonts for actual use in main document
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", null);
    inter.encoding = .identity;
    const inter_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf", null);
    inter_bold.encoding = .identity;
    const charter = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", null);
    charter.encoding = .identity;
    const gentium = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", null);
    gentium.encoding = .identity;

    // Font with all OpenType features enabled
    const inter_ot = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", null);
    inter_ot.encoding = .identity;
    inter_ot.setFeature(.liga, true);
    inter_ot.setFeature(.dlig, true);
    inter_ot.setFeature(.calt, true);
    inter_ot.setFeature(.frac, true);

    const pages_per_section = config.pages / 4;

    // 2. Simple text test (minimal OpenType)
    {
        const t = Timer.begin("Simple text");
        const simple_font = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", null);
        simple_font.encoding = .identity;
        simple_font.setFeature(.kern, false);
        simple_font.setFeature(.liga, false);
        simple_font.setFeature(.calt, false);

        for (0..pages_per_section) |_| {
            try doc.addPage();
            try doc.setEmbeddedFont(simple_font, 10);
            var y: f64 = 30;
            // 50 lines of text per page
            for (0..50) |_| {
                _ = try doc.writeAt(50, y, "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.");
                y += 14;
            }
        }
        result.simple_text_ms = t.endPrint(config.quiet);
    }

    // 3. OpenType heavy test (ligatures, kerning, contextual alternates)
    {
        const t = Timer.begin("OpenType heavy");
        for (0..pages_per_section) |_| {
            try doc.addPage();
            var y: f64 = 30;

            // Ligature-heavy text
            try doc.setEmbeddedFont(inter_ot, 11);
            for (0..15) |_| {
                _ = try doc.writeAt(50, y, "ффи|fi fl ffi ffl|office efficientifficiently buffer difficult fjord");
                y += 14;
            }

            // Contextual alternates (arrows, math)
            for (0..15) |_| {
                _ = try doc.writeAt(50, y, "-> => <- <=> --> <-- != == >= <= 3*9 12:34 a--b c++d");
                y += 14;
            }

            // Fractions
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "1/2 3/4 5/8 7/16 11/32 1/3 2/3 1/5 2/5 3/5 4/5 99/100");
                y += 14;
            }

            // Kerning stress (AV, To, Ty, etc.)
            try doc.setEmbeddedFont(inter_bold, 12);
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "AVATAR WAVE TYPEWRITER Today Tomorrow Typography WATTAGE");
                y += 15;
            }
        }
        result.opentype_ms = t.endPrint(config.quiet);
    }

    // 4. Unicode and diacritics test
    {
        const t = Timer.begin("Unicode/marks");
        for (0..pages_per_section) |_| {
            try doc.addPage();
            var y: f64 = 30;

            // Latin extended with diacritics
            try doc.setEmbeddedFont(gentium, 11);
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞß àáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ");
                y += 14;
            }

            // Stacked diacritics (Vietnamese, etc.)
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "ẳ ế ộ ỗ ầ ẫ ồ ổ ứ ự ề ể ễ ệ ỉ ị ọ ỏ ố ớ ờ ở ợ ụ ủ ứ ừ");
                y += 14;
            }

            // Mixed scripts
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "Ćçčđ ěęėē ğģġ ħĥ įīĩ ķĸ ĺļľŀł ńņňŉŋ őœ ŕŗř śşšș ţťŧț űů");
                y += 14;
            }

            // Currency and symbols
            try doc.setEmbeddedFont(inter, 11);
            for (0..10) |_| {
                _ = try doc.writeAt(50, y, "€£¥¢₹₽₿ §¶†‡ ©®™ °′″ ±×÷≠≈≤≥ ∞∑∏∫√ ←→↑↓↔ •◦○●■□▲△");
                y += 14;
            }

            // Greek
            for (0..5) |_| {
                _ = try doc.writeAt(50, y, "αβγδεζηθικλμνξοπρστυφχψω ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ");
                y += 14;
            }
        }
        result.unicode_ms = t.endPrint(config.quiet);
    }

    // 5. Text flow test (justification, multi-column)
    {
        const t = Timer.begin("Text flow");

        const lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. ";
        const full_text = lorem ++ lorem ++ lorem;

        for (0..pages_per_section) |_| {
            try doc.addPage();
            try doc.setEmbeddedFont(charter, 10);

            // Left column - justified with optimal line breaking
            var region = zpdf.Region{ .x = 50, .y = 50, .width = 230, .height = 700 };
            {
                var st = doc.createStyledText();
                defer st.deinit();
                try st.append(full_text, .{});
                _ = try doc.writeStyled(&region, &st, .{
                    .alignment = .justify,
                    .valign = .top,
                    .line_breaking = .optimal,
                });
            }

            // Right column - justified with optimal line breaking
            region = zpdf.Region{ .x = 320, .y = 50, .width = 230, .height = 700 };
            {
                var st = doc.createStyledText();
                defer st.deinit();
                try st.append(full_text, .{});
                _ = try doc.writeStyled(&region, &st, .{
                    .alignment = .justify,
                    .valign = .top,
                    .line_breaking = .optimal,
                });
            }
        }
        result.text_flow_ms = t.endPrint(config.quiet);
    }

    // 6. PDF output generation
    {
        const t = Timer.begin("PDF output");
        result.pdf_data = try doc.output();
        result.output_ms = t.endPrint(config.quiet);

        // Print output timing breakdown
        if (!config.quiet) {
            const ot = zpdf.Document.last_output_timing;
            std.debug.print("    - Subset generation: {d}ms\n", .{ot.subset_ms});
            std.debug.print("    - Page rendering:    {d}ms\n", .{ot.render_ms});
            std.debug.print("    - Font writing:      {d}ms\n", .{ot.font_write_ms});
            std.debug.print("    - Page writing:      {d}ms\n", .{ot.page_write_ms});
            std.debug.print("    - Finish (xref):     {d}ms\n", .{ot.finish_ms});
        }
    }

    result.total_ms = total_timer.end();
    return result;
}

fn parseArgs(allocator: std.mem.Allocator) !TestConfig {
    _ = allocator;
    var config = TestConfig{};

    var args = std.process.args();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--pages=")) {
            config.pages = try std.fmt.parseInt(u32, arg[8..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            config.iterations = try std.fmt.parseInt(u32, arg[13..], 10);
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            config.output_path = arg[9..];
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\ZPDF Performance Test
                \\
                \\Usage: zig build perf -- [options]
                \\
                \\Options:
                \\  --pages=N       Number of pages to generate (default: 100)
                \\  --iterations=N  Number of test iterations (default: 3)
                \\  --output=PATH   Write final PDF to file
                \\  --quiet         Only show summary
                \\  --help          Show this help
                \\
            , .{});
            std.process.exit(0);
        }
    }

    return config;
}
