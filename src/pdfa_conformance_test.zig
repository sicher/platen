//! PDF/A conformance rules enforced at the API (veraPDF validates the
//! output in integration_tests.zig). Images: PDF/A-1b (PDF 1.4) forbids
//! soft masks and has no 16-bit samples; PDF/A-2b allows both. Fonts:
//! every PDF/A level requires embedded fonts, which the standard 14 lack.

const std = @import("std");
const platen = @import("platen.zig");

const Case = struct { file: []const u8, pdfa_1b: ?anyerror };

const cases = [_]Case{
    .{ .file = "basn2c08.png", .pdfa_1b = null }, // 8-bit RGB, opaque
    .{ .file = "basn3p04.png", .pdfa_1b = null }, // indexed, opaque
    .{ .file = "basn6a08.png", .pdfa_1b = error.TransparencyNotAllowed }, // RGBA
    .{ .file = "tbrn2c08.png", .pdfa_1b = error.TransparencyNotAllowed }, // tRNS color key
    .{ .file = "basn2c16.png", .pdfa_1b = error.BitDepthNotAllowed }, // 16-bit RGB
    .{ .file = "basn0g16.png", .pdfa_1b = error.BitDepthNotAllowed }, // 16-bit gray
};

fn drawUnder(conformance: platen.Conformance, file: []const u8) !void {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.setConformance(conformance);
    try doc.addPage(.{});
    var path_buf: [64]u8 = undefined;
    const img = try doc.loadImage(try std.fmt.bufPrint(&path_buf, "test/images/pngsuite/{s}", .{file}));
    const before = doc.pages.items[0].commands.items.len;
    doc.drawImage(img, .{ .x = 10, .y = 10, .width = 20, .height = 20 }) catch |err| {
        // Rejected before anything is recorded.
        try std.testing.expectEqual(before, doc.pages.items[0].commands.items.len);
        try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].used_images.items.len);
        return err;
    };
    const pdf = try doc.output();
    a.free(pdf);
}

test "PDF/A-1b rejects images with soft masks or 16-bit samples" {
    for (cases) |c| {
        if (c.pdfa_1b) |expected| {
            try std.testing.expectError(expected, drawUnder(.pdfa_1b, c.file));
        } else {
            try drawUnder(.pdfa_1b, c.file);
        }
    }
}

test "PDF/A-2b and plain output accept every case" {
    for (cases) |c| {
        try drawUnder(.pdfa_2b, c.file);
        try drawUnder(.none, c.file);
    }
}

test "PDF/A rejects standard (non-embedded) fonts in every text call" {
    const a = std.testing.allocator;
    const helv = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
    for ([_]platen.Conformance{ .pdfa_1b, .pdfa_2b }) |conformance| {
        var doc = platen.Document.init(a, std.testing.io);
        defer doc.deinit();
        doc.setConformance(conformance);
        try doc.addPage(.{});
        var region = platen.Region{ .x = 50, .y = 50, .width = 200, .height = 200 };
        try std.testing.expectError(error.FontNotEmbedded, doc.writeAt(.{ .x = 50, .y = 50 }, "x", helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.write(&region, "x", helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.writeBlock(&region, "x", helv, .{}));
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("x", .{});
        try std.testing.expectError(error.FontNotEmbedded, doc.writeStyled(&region, &st, helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = .symbol, .size = 12 }, .{}));
        try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].commands.items.len);

        // Embedded fonts are fine.
        const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
        _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = inter, .size = 12 }, .{});
    }
    // Outside PDF/A, standard fonts work as always.
    var plain = platen.Document.init(a, std.testing.io);
    defer plain.deinit();
    try plain.addPage(.{});
    _ = try plain.writeAt(.{ .x = 50, .y = 50 }, "x", helv, .{});
}

test "PDF/A rejects SVGs with text (rendered in standard fonts)" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_2b);
    try doc.addPage(.{});
    const with_text = try doc.loadSvgFromMemory("<svg width=\"40\" height=\"20\"><text x=\"2\" y=\"12\">Hi</text></svg>");
    try std.testing.expectError(error.FontNotEmbedded, doc.drawSvg(with_text, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].used_svgs.items.len);
    const shapes = try doc.loadSvgFromMemory("<svg width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>");
    try doc.drawSvg(shapes, .{ .x = 10, .y = 10 });
}
