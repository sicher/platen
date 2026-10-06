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
