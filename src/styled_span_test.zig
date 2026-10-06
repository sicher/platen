//! StyledText span styles are overrides of the base TextStyle: a field
//! left null inherits. Until 2026-10-06 spans carried a full color
//! (default black) and decoration (default none), so writeBlock and
//! writeStyled ignored the base style's color and underline entirely.

const std = @import("std");
const platen = @import("platen.zig");

const red = platen.Color.rgb(255, 0, 0);
const blue = platen.Color.rgb(0, 0, 255);
const base = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12, .color = red, .decoration = .{ .underline = true } };

/// Content-stream facts about one rendered paragraph.
const Seen = struct { red: bool, blue: bool, black: bool, underline: bool };

fn render(comptime how: enum { block, styled, justify }, spans: []const struct { []const u8, platen.TextStyleOptions }) !Seen {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});
    var region = platen.Region{ .x = 50, .y = 50, .width = 120, .height = 400 };
    switch (how) {
        .block => _ = try doc.writeBlock(&region, spans[0][0], base, .{}),
        .styled, .justify => {
            var st = doc.createStyledText();
            defer st.deinit();
            for (spans) |s| try st.append(s[0], s[1]);
            _ = try doc.writeStyled(&region, &st, base, .{ .alignment = if (how == .justify) .justify else .left });
        },
    }
    const pdf = try doc.output();
    defer a.free(pdf);
    return .{
        .red = std.mem.indexOf(u8, pdf, "1.000 0.000 0.000 rg") != null,
        .blue = std.mem.indexOf(u8, pdf, "0.000 0.000 1.000 rg") != null,
        .black = std.mem.indexOf(u8, pdf, "0.000 g") != null or std.mem.indexOf(u8, pdf, "0 g\n") != null,
        .underline = std.mem.indexOf(u8, pdf, " re f") != null or std.mem.indexOf(u8, pdf, " re\nf") != null,
    };
}

const long = "Several words that wrap across more than one justified line here";

test "plain spans inherit the base color and decoration" {
    for ([_]Seen{
        try render(.block, &.{.{ "Hello", .{} }}),
        try render(.styled, &.{.{ "Hello", .{} }}),
        try render(.justify, &.{.{ long, .{} }}),
    }) |seen| {
        try std.testing.expect(seen.red);
        try std.testing.expect(seen.underline);
    }
}

test "span fields override the base style" {
    const seen = try render(.styled, &.{ .{ "base ", .{} }, .{ "blue", .{ .color = blue } } });
    try std.testing.expect(seen.red and seen.blue);

    const plain = try render(.styled, &.{.{ "no underline", .{ .decoration = .none } }});
    try std.testing.expect(plain.red);
    try std.testing.expect(!plain.underline);
}

// ----------------------------------------------------------------------------
// Bold/italic per span (2026-10-06): overrides of the base style's flags,
// resolved through the base font's family like TextStyle.bold/.italic.
// ----------------------------------------------------------------------------

test "bold and italic spans render in their variants" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});
    var region = platen.Region{ .x = 50, .y = 50, .width = 300, .height = 100 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("regular ", .{});
    try st.append("bold ", .{ .bold = true });
    try st.append("italic ", .{ .italic = true });
    try st.append("both", .{ .bold = true, .italic = true });
    _ = try doc.writeStyled(&region, &st, .{ .font = platen.Font.helvetica, .size = 12 }, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold\n") != null or std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null or std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica ") != null);
}

test "a span can turn an inherited bold off" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    var region = platen.Region{ .x = 50, .y = 50, .width = 300, .height = 100 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("plain", .{ .bold = false });
    _ = try doc.writeStyled(&region, &st, .{ .font = platen.Font.helvetica, .size = 12, .bold = true }, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") == null);
}

test "bold span widths drive line breaking" {
    // Helvetica-Bold is wider (m 889 vs 833, i 278 vs 222 units): a region
    // between the regular and bold widths holds the regular text on one
    // line and must wrap the bold text.
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const text = "mmmm iiii";
    const base_style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 10 };
    const regular_w = (try doc.measureStyled(text, base_style)).width;
    var bold_style = base_style;
    bold_style.bold = true;
    const bold_w = (try doc.measureStyled(text, bold_style)).width;
    try std.testing.expect(bold_w > regular_w);

    for ([_]?bool{ null, true }, [_]usize{ 1, 2 }) |bold, expected_lines| {
        var region = platen.Region{ .x = 50, .y = 50, .width = (regular_w + bold_w) / 2, .height = 200 };
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append(text, .{ .bold = bold });
        const r = try doc.writeStyled(&region, &st, base_style, .{ .measure_only = true });
        try std.testing.expectEqual(expected_lines, r.lines_written);
    }
}

test "a bold span resolves through an embedded font family" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.compression_level = 0;
    try doc.addPage(.{});
    const gentium = try doc.loadFontFamily(.{
        .regular = "test/fonts/Gentium/Gentium-Regular.ttf",
        .bold = "test/fonts/Gentium/Gentium-Bold.ttf",
    });
    var region = platen.Region{ .x = 50, .y = 50, .width = 300, .height = 100 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("regular ", .{});
    try st.append("bold", .{ .bold = true });
    _ = try doc.writeStyled(&region, &st, .{ .font = gentium, .size = 12 }, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pdf, "/FontFile2")); // both faces embedded
}

test "a bold span on a font without a bold variant is an error, before any change" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    var region = platen.Region{ .x = 50, .y = 50, .width = 300, .height = 100 };
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("regular ", .{});
    try st.append("bold", .{ .bold = true });
    try std.testing.expectError(error.FontVariantNotLoaded, doc.writeStyled(&region, &st, .{ .font = inter, .size = 12 }, .{}));
    try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].commands.items.len);
    try std.testing.expectEqual(@as(f64, 0), region.cursor_y);
}
