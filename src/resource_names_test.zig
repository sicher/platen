//! Regression test: resource names past the old fixed tables.
//! Names came from comptime tables of 32 entries (16 for shadings) with a
//! shared fallback ("Im99", "Sv99", "GS99", "Sh99", "E99"), so the 33rd
//! image onward collided in the page's resource dictionary while content
//! streams referenced /Im33... - a broken PDF. Found by the PngSuite test.

const std = @import("std");
const platen = @import("platen.zig");

const n = 40;

fn qpdfCheck(pdf: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.pdf", .data = pdf });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "many.pdf", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "qpdf", "--check", path },
    }) catch return error.SkipZigTest; // qpdf not installed
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok or std.mem.indexOf(u8, result.stderr, "WARNING") != null) {
        std.debug.print("qpdf --check failed:\n{s}{s}\n", .{ result.stdout, result.stderr });
        return error.InvalidPdf;
    }
}

fn countOf(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "documents with more than 32 images, SVGs, opacities and gradients name every resource uniquely" {
    const allocator = std.testing.allocator;
    var doc = platen.Document.init(allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // readable content streams
    try doc.addPage(.{});

    const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fuzz/tiny_rgb.png", allocator, .limited(1 << 20));
    defer allocator.free(png);
    const stops = [_]platen.ColorStop{ .{ .offset = 0, .color = platen.Color.red }, .{ .offset = 1, .color = platen.Color.blue } };

    for (0..n) |i| {
        const x: f64 = @floatFromInt(10 + (i % 10) * 50);
        const y: f64 = @floatFromInt(10 + (i / 10) * 50);
        const img = try doc.loadImageFromMemory(png);
        try doc.drawImage(img, .{ .x = x, .y = y, .width = 10, .height = 10 });
        const svg = try doc.loadSvgFromMemory("<svg width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\" fill=\"green\"/></svg>");
        try doc.drawSvg(svg, .{ .x = x + 12, .y = y, .width = 10, .height = 10 });
        const opacity = 0.01 + @as(f64, @floatFromInt(i)) * 0.02; // n distinct states
        try doc.drawRect(.{ .x = x, .y = y + 12, .width = 10, .height = 10 }, .{ .fill = .{ .color = platen.Color.navy, .opacity = opacity } });
        const g = try doc.addLinearGradient(.{ .x0 = x, .y0 = 0, .x1 = x + 10, .y1 = 0, .stops = &stops });
        try doc.fillRectGradient(.{ .x = x + 12, .y = y + 12, .width = 10, .height = 10 }, g);
    }
    const pdf = try doc.output();
    defer allocator.free(pdf);

    // The old fallbacks must not appear, and the last of each is named.
    for ([_][]const u8{ "/Im99", "/Sv99", "/GS99", "/Sh99" }) |fallback| {
        try std.testing.expectEqual(@as(usize, 0), countOf(pdf, fallback));
    }
    for ([_][]const u8{ "/Im40 ", "/Sv40 ", "/GS40 ", "/Sh40 " }) |last| {
        try std.testing.expect(countOf(pdf, last) >= 2); // resource key + use
    }
    try qpdfCheck(pdf);
}

test "more than 32 embedded fonts on one page name every font uniquely" {
    const allocator = std.testing.allocator;
    var doc = platen.Document.init(allocator, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fuzz/tiny.ttf", allocator, .limited(1 << 20));
    defer allocator.free(data);
    for (0..n) |i| {
        const font = try doc.loadFontFromMemory(data, .identity);
        _ = try doc.writeAt(.{ .x = 20, .y = 20 + @as(f64, @floatFromInt(i)) * 15 }, "A", .{ .font = font, .size = 10 }, .{});
    }
    const pdf = try doc.output();
    defer allocator.free(pdf);
    try std.testing.expectEqual(@as(usize, 0), countOf(pdf, "/E99"));
    try std.testing.expect(countOf(pdf, "/E40 ") >= 2);
    try qpdfCheck(pdf);
}
