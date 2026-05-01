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
const zapdf = @import("zapdf");

var app_io: std.Io = undefined;

const Timer = struct {
    start: i64,
    name: []const u8,

    fn begin(name: []const u8) Timer {
        return .{ .start = zapdf.pdf_output.milliTimestamp(), .name = name };
    }

    fn end(self: Timer) i64 {
        return zapdf.pdf_output.milliTimestamp() - self.start;
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    app_io = init.io;

    // Parse args
    const config = parseArgs(init.minimal.args) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        return;
    };

    std.debug.print("\n=== ZAPDF Performance Test ===\n", .{});
    std.debug.print("Pages: {d}, Iterations: {d}\n\n", .{ config.pages, config.iterations });

    var total_times = [_]i64{0} ** 7;
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
        total_times[5] += result.drawing_ms;
        total_times[6] += result.output_ms;

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
    std.debug.print("  Drawing shapes:  {d}ms\n", .{@divTrunc(total_times[5], n)});
    std.debug.print("  PDF output:      {d}ms\n", .{@divTrunc(total_times[6], n)});
    std.debug.print("  ---\n", .{});
    std.debug.print("  TOTAL:           {d}ms\n", .{@divTrunc(total_times[0] + total_times[1] + total_times[2] + total_times[3] + total_times[4] + total_times[5] + total_times[6], n)});

    if (pdf_bytes) |data| {
        std.debug.print("  PDF size:        {d} KB\n", .{data.len / 1024});
    }

    // Write output if requested
    if (config.output_path) |path| {
        if (pdf_bytes) |data| {
            try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = path, .data = data });
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
    var test_data = std.ArrayListUnmanaged(u8).empty;
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
        const compressed = try zapdf.zlib.compressLevel(allocator, test_data.items, l.level);
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
    var doc = zapdf.Document.init(allocator, app_io);
    defer doc.deinit();

    const emb = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);

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
        emb.embedded.feature_flags.set(.calt, tc.calt);
        emb.embedded.feature_flags.set(.liga, tc.liga);
        emb.embedded.feature_flags.set(.dlig, tc.dlig);
        emb.embedded.feature_flags.set(.frac, tc.frac);

        const t = Timer.begin(tc.name);
        for (0..iterations) |_| {
            const glyphs = try emb.embedded.markUnicodeCharsUsed(tc.text, null);
            emb.embedded.allocator.free(glyphs);
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
    drawing_ms: i64,
    output_ms: i64,
    total_ms: i64,
    pdf_data: []u8,
};

fn runFullTest(allocator: std.mem.Allocator, config: TestConfig) !TestResult {
    const total_timer = Timer.begin("Total");
    var result: TestResult = undefined;

    var doc = zapdf.Document.init(allocator, app_io);
    defer doc.deinit();

    // 1. Font loading test (use separate doc to avoid polluting main doc with unused fonts)
    {
        const t = Timer.begin("Font loading");
        var timing_doc = zapdf.Document.init(allocator, app_io);
        defer timing_doc.deinit();

        // Load multiple fonts to measure parsing time
        const inter = try timing_doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
        const inter_bold = try timing_doc.loadFont("test/fonts/Inter/Inter-Bold.ttf", .identity);
        const inter_italic = try timing_doc.loadFont("test/fonts/Inter/Inter-Italic.ttf", .identity);
        const charter = try timing_doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
        const gentium = try timing_doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity);
        const courier = try timing_doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);

        result.font_load_ms = t.endPrint(config.quiet);
        _ = .{ inter, inter_bold, inter_italic, charter, gentium, courier };
    }

    // Load fonts for actual use in main document
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    const inter_bold = try doc.loadFont("test/fonts/Inter/Inter-Bold.ttf", .identity);
    const charter = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
    const gentium = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity);

    // Font with all OpenType features enabled
    const inter_ot = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    inter_ot.embedded.setFeature(.liga, true);
    inter_ot.embedded.setFeature(.dlig, true);
    inter_ot.embedded.setFeature(.calt, true);
    inter_ot.embedded.setFeature(.frac, true);

    const pages_per_section = config.pages / 5;

    // 2. Simple text test (minimal OpenType)
    {
        const t = Timer.begin("Simple text");
        const simple_font = try doc.loadFont("test/fonts/Charter/Charter Regular.ttf", .identity);
        simple_font.embedded.setFeature(.kern, false);
        simple_font.embedded.setFeature(.liga, false);
        simple_font.embedded.setFeature(.calt, false);

        const simple_style = zapdf.TextStyle{ .font = simple_font, .size = 10 };
        for (0..pages_per_section) |_| {
            try doc.addPage(.{});
            var y: f64 = 30;
            // 50 lines of text per page
            for (0..50) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.", simple_style);
                y += 14;
            }
        }
        result.simple_text_ms = t.endPrint(config.quiet);
    }

    // 3. OpenType heavy test (ligatures, kerning, contextual alternates)
    {
        const t = Timer.begin("OpenType heavy");
        const inter_ot_style = zapdf.TextStyle{ .font = inter_ot, .size = 11 };
        const inter_bold_style = zapdf.TextStyle{ .font = inter_bold, .size = 12 };
        for (0..pages_per_section) |_| {
            try doc.addPage(.{});
            var y: f64 = 30;

            // Ligature-heavy text
            for (0..15) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "ффи|fi fl ffi ffl|office efficientifficiently buffer difficult fjord", inter_ot_style);
                y += 14;
            }

            // Contextual alternates (arrows, math)
            for (0..15) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "-> => <- <=> --> <-- != == >= <= 3*9 12:34 a--b c++d", inter_ot_style);
                y += 14;
            }

            // Fractions
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "1/2 3/4 5/8 7/16 11/32 1/3 2/3 1/5 2/5 3/5 4/5 99/100", inter_ot_style);
                y += 14;
            }

            // Kerning stress (AV, To, Ty, etc.)
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "AVATAR WAVE TYPEWRITER Today Tomorrow Typography WATTAGE", inter_bold_style);
                y += 15;
            }
        }
        result.opentype_ms = t.endPrint(config.quiet);
    }

    // 4. Unicode and diacritics test
    {
        const t = Timer.begin("Unicode/marks");
        const gentium_style = zapdf.TextStyle{ .font = gentium, .size = 11 };
        const inter_style = zapdf.TextStyle{ .font = inter, .size = 11 };
        for (0..pages_per_section) |_| {
            try doc.addPage(.{});
            var y: f64 = 30;

            // Latin extended with diacritics
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞß àáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ", gentium_style);
                y += 14;
            }

            // Stacked diacritics (Vietnamese, etc.)
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "ẳ ế ộ ỗ ầ ẫ ồ ổ ứ ự ề ể ễ ệ ỉ ị ọ ỏ ố ớ ờ ở ợ ụ ủ ứ ừ", gentium_style);
                y += 14;
            }

            // Mixed scripts
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "Ćçčđ ěęėē ğģġ ħĥ įīĩ ķĸ ĺļľŀł ńņňŉŋ őœ ŕŗř śşšș ţťŧț űů", gentium_style);
                y += 14;
            }

            // Currency and symbols
            for (0..10) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "€£¥¢₹₽₿ §¶†‡ ©®™ °′″ ±×÷≠≈≤≥ ∞∑∏∫√ ←→↑↓↔ •◦○●■□▲△", inter_style);
                y += 14;
            }

            // Greek
            for (0..5) |_| {
                _ = try doc.writeAt(.{ .x = 50, .y = y }, "αβγδεζηθικλμνξοπρστυφχψω ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ", inter_style);
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
        const charter_10 = zapdf.TextStyle{ .font = charter, .size = 10 };

        for (0..pages_per_section) |_| {
            try doc.addPage(.{});

            // Left column - justified with optimal line breaking
            var region = zapdf.Region{ .x = 50, .y = 50, .width = 230, .height = 700 };
            {
                var st = doc.createStyledText();
                defer st.deinit();
                try st.append(full_text, .{});
                _ = try doc.writeStyled(&region, &st, charter_10, .{
                    .alignment = .justify,
                    .valign = .top_leading,
                    .line_breaking = .optimal,
                });
            }

            // Right column - justified with optimal line breaking
            region = zapdf.Region{ .x = 320, .y = 50, .width = 230, .height = 700 };
            {
                var st = doc.createStyledText();
                defer st.deinit();
                try st.append(full_text, .{});
                _ = try doc.writeStyled(&region, &st, charter_10, .{
                    .alignment = .justify,
                    .valign = .top_leading,
                    .line_breaking = .optimal,
                });
            }
        }
        result.text_flow_ms = t.endPrint(config.quiet);
    }

    // 6. Drawing shapes test (exercises fast coordinate formatting)
    {
        const t = Timer.begin("Drawing shapes");

        for (0..pages_per_section) |_| {
            try doc.addPage(.{});

            // Many rectangles (50 per row, 20 rows = 1000 rects per page)
            for (0..20) |row| {
                const y = 50 + @as(f64, @floatFromInt(row)) * 35;
                for (0..50) |col| {
                    const x = 20 + @as(f64, @floatFromInt(col)) * 11;
                    try doc.drawRect(.{ .x = x, .y = y, .width = 9, .height = 30 }, .{
                        .stroke = .{ .color = zapdf.Color.rgbf(0.2, 0.4, 0.8), .width = 0.5 },
                        .fill = .{ .color = zapdf.Color.rgbf(0.9, 0.95, 1.0) },
                    });
                }
            }

            // Many lines (grid pattern - 100 horizontal + 100 vertical = 200 lines)
            for (0..100) |i| {
                const offset = @as(f64, @floatFromInt(i)) * 5.5;
                // Horizontal lines
                try doc.drawLine(.{ .x = 50, .y = 50 + offset }, .{ .x = 500, .y = 50 + offset }, .{
                    .color = zapdf.Color.greyscale(0.7),
                    .width = 0.25,
                });
                // Vertical lines
                try doc.drawLine(.{ .x = 50 + offset * 0.9, .y = 50 }, .{ .x = 50 + offset * 0.9, .y = 600 }, .{
                    .color = zapdf.Color.greyscale(0.8),
                    .width = 0.25,
                });
            }

            // Ellipses (100 per page) - using bounding box rect
            for (0..10) |row| {
                const y = 100 + @as(f64, @floatFromInt(row)) * 60;
                for (0..10) |col| {
                    const x = 80 + @as(f64, @floatFromInt(col)) * 50;
                    try doc.drawEllipse(.{ .x = x - 18, .y = y - 12, .width = 36, .height = 24 }, .{
                        .stroke = .{ .color = zapdf.Color.rgbf(0.8, 0.2, 0.2) },
                        .fill = .{ .color = zapdf.Color.rgbf(1.0, 0.9, 0.9) },
                    });
                }
            }

            // Circles (100 per page)
            for (0..10) |row| {
                const cy = 120 + @as(f64, @floatFromInt(row)) * 55;
                for (0..10) |col| {
                    const cx = 100 + @as(f64, @floatFromInt(col)) * 45;
                    try doc.drawCircle(.{ .x = cx, .y = cy }, 8, .{
                        .stroke = .{ .color = zapdf.Color.rgbf(0.2, 0.7, 0.2), .width = 1.0 },
                    });
                }
            }

            // Rounded rectangles (50 per page)
            for (0..5) |row| {
                const y = 80 + @as(f64, @floatFromInt(row)) * 130;
                for (0..10) |col| {
                    const x = 30 + @as(f64, @floatFromInt(col)) * 55;
                    try doc.drawRoundedRect(.{ .x = x, .y = y, .width = 50, .height = 100 }, 5, .{
                        .stroke = .{ .color = zapdf.Color.rgbf(0.5, 0.2, 0.7), .width = 0.75 },
                        .fill = .{ .color = zapdf.Color.rgbf(0.95, 0.9, 1.0) },
                    });
                }
            }

            // Polygons (triangles, hexagons - 50 per page)
            for (0..10) |row| {
                const cy = 100 + @as(f64, @floatFromInt(row)) * 70;
                for (0..5) |col| {
                    const cx = 80 + @as(f64, @floatFromInt(col)) * 100;
                    // Triangle
                    const tri_points = [_]zapdf.Point{
                        .{ .x = cx, .y = cy + 20 },
                        .{ .x = cx - 15, .y = cy - 10 },
                        .{ .x = cx + 15, .y = cy - 10 },
                    };
                    try doc.drawPolygon(&tri_points, .{
                        .stroke = .{ .color = zapdf.Color.rgbf(0.9, 0.5, 0.1) },
                        .fill = .{ .color = zapdf.Color.rgbf(1.0, 0.95, 0.85) },
                    });
                }
            }
        }
        result.drawing_ms = t.endPrint(config.quiet);
    }

    // 7. PDF output generation
    {
        const t = Timer.begin("PDF output");
        result.pdf_data = try doc.output();
        result.output_ms = t.endPrint(config.quiet);

        // Print output timing breakdown
        if (!config.quiet) {
            const ot = zapdf.pdf_output.last_output_timing;
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

fn parseArgs(args_obj: std.process.Args) !TestConfig {
    var config = TestConfig{};

    var args = args_obj.iterate();
    _ = args.next(); // program name

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
                \\ZAPDF Performance Test
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
