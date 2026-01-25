//! Performance benchmark: write() vs writeStyled()
//!
//! Results (Debug build, 1000 iterations):
//!   - writeStyled() is 1.2-1.8x faster for rendering
//!   - write() is 4.8x faster for measure_only
//!
//! TODO: Investigate why write() is slower than writeStyled() for rendering.
//!       They should be similar since write() is essentially writeStyled()
//!       with a single span. Possible causes:
//!       - Extra allocations in write() code path
//!       - Different line-breaking logic
//!       - Redundant text processing
//!
//! Run with: zig build-exe bench_write.zig -O Debug && ./bench_write
//!      or:  zig build-exe bench_write.zig -O ReleaseFast && ./bench_write

const std = @import("std");
const zpdf = @import("src/zpdf.zig");

const iterations = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== write() vs writeStyled() Performance Comparison ===\n\n", .{});

    // Test scenarios
    try benchShortText(allocator);
    try benchMediumParagraph(allocator);
    try benchLongParagraph(allocator);
    try benchMultipleParagraphs(allocator);
    try benchAlignments(allocator);
    try benchLineBreaking(allocator);
    try benchNarrowColumn(allocator);
    try benchMeasureOnly(allocator);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

fn benchShortText(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Short text (single line) ---\n", .{});
    const text = "Hello, World!";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 12 };

    // write()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            const start = std.time.nanoTimestamp();
            _ = try doc.write(&region, text, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write():       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled(): {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchMediumParagraph(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Medium paragraph (~200 chars, wrapping) ---\n", .{});
    const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // write()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            const start = std.time.nanoTimestamp();
            _ = try doc.write(&region, text, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write():       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled(): {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchLongParagraph(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Long paragraph (~1000 chars, heavy wrapping) ---\n", .{});
    const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // write()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            const start = std.time.nanoTimestamp();
            _ = try doc.write(&region, text, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write():       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled(): {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchMultipleParagraphs(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Multiple paragraphs (5x medium) ---\n", .{});
    const para = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // write() - 5 calls
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            const start = std.time.nanoTimestamp();
            for (0..5) |_| {
                _ = try doc.write(&region, para, style, .{});
            }
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write() x5:       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled() - 5 spans in one call
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            for (0..5) |i| {
                try st.append(para, .{});
                if (i < 4) try st.append("\n\n", .{});
            }

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled() 1x: {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchAlignments(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Alignment comparison (writeStyled only) ---\n", .{});
    const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    const alignments = [_]zpdf.Align{ .left, .center, .right, .justify };
    const names = [_][]const u8{ "left", "center", "right", "justify" };

    for (alignments, names) |alignment, name| {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{ .alignment = alignment });
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  {s:<8}: {d:>8.2} µs/call\n", .{ name, @as(f64, @floatFromInt(total_ns)) / iterations / 1000.0 });
    }
    std.debug.print("\n", .{});
}

fn benchLineBreaking(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Line breaking: greedy vs optimal ---\n", .{});
    const text = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump! The five boxing wizards jump quickly.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // Greedy
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{ .line_breaking = .greedy });
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  greedy:  {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // Optimal
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{ .line_breaking = .optimal });
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  optimal: {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchNarrowColumn(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Narrow column (100pt width, many line breaks) ---\n", .{});
    const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // write()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = zpdf.Region{ .x = 0, .y = 0, .width = 100, .height = 500 };

            const start = std.time.nanoTimestamp();
            _ = try doc.write(&region, text, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write():       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled()
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = zpdf.Region{ .x = 0, .y = 0, .width = 100, .height = 500 };

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{});
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled(): {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}

fn benchMeasureOnly(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Measure only (no rendering) ---\n", .{});
    const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.";
    const style = zpdf.TextStyle{ .font = zpdf.Font.helvetica, .size = 11 };

    // write() measure_only
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            const start = std.time.nanoTimestamp();
            _ = try doc.write(&region, text, style, .{ .measure_only = true });
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  write():       {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }

    // writeStyled() measure_only
    {
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            var doc = zpdf.Document.init(allocator);
            defer doc.deinit();
            try doc.addPage(.{});
            var region = doc.getPageRegion().?;

            var st = zpdf.StyledText.init(allocator);
            defer st.deinit();
            try st.append(text, .{});

            const start = std.time.nanoTimestamp();
            _ = try doc.writeStyled(&region, &st, style, .{ .measure_only = true });
            const end = std.time.nanoTimestamp();
            total_ns += @intCast(@as(i128, end - start));
        }
        std.debug.print("  writeStyled(): {d:>8.2} µs/call\n", .{@as(f64, @floatFromInt(total_ns)) / iterations / 1000.0});
    }
    std.debug.print("\n", .{});
}
