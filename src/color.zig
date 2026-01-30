const std = @import("std");

/// Color with support for multiple color spaces.
/// All values are normalized to 0.0-1.0 range.
pub const Color = union(enum) {
    /// Grayscale: 0 = black, 1 = white
    greyscale_val: f64,
    /// RGB color space (screen/web)
    rgb_val: struct { r: f64, g: f64, b: f64 },
    /// CMYK color space (print)
    cmyk_val: struct { c: f64, m: f64, y: f64, k: f64 },

    // CSS Named Colors (148 colors)
    // https://www.w3.org/TR/css-color-4/#named-colors

    // Blacks and Grays
    pub const black = Color{ .greyscale_val = 0 };
    pub const white = Color{ .greyscale_val = 1 };
    pub const gray = Color.rgb(128, 128, 128);
    pub const grey = gray;
    pub const silver = Color.rgb(192, 192, 192);
    pub const darkgray = Color.rgb(169, 169, 169);
    pub const darkgrey = darkgray;
    pub const dimgray = Color.rgb(105, 105, 105);
    pub const dimgrey = dimgray;
    pub const lightgray = Color.rgb(211, 211, 211);
    pub const lightgrey = lightgray;
    pub const gainsboro = Color.rgb(220, 220, 220);
    pub const whitesmoke = Color.rgb(245, 245, 245);

    // Slate grays
    pub const slategray = Color.rgb(112, 128, 144);
    pub const slategrey = slategray;
    pub const lightslategray = Color.rgb(119, 136, 153);
    pub const lightslategrey = lightslategray;
    pub const darkslategray = Color.rgb(47, 79, 79);
    pub const darkslategrey = darkslategray;

    // Reds
    pub const red = Color.rgb(255, 0, 0);
    pub const darkred = Color.rgb(139, 0, 0);
    pub const firebrick = Color.rgb(178, 34, 34);
    pub const indianred = Color.rgb(205, 92, 92);
    pub const lightcoral = Color.rgb(240, 128, 128);
    pub const crimson = Color.rgb(220, 20, 60);
    pub const maroon = Color.rgb(128, 0, 0);

    // Pinks
    pub const pink = Color.rgb(255, 192, 203);
    pub const lightpink = Color.rgb(255, 182, 193);
    pub const hotpink = Color.rgb(255, 105, 180);
    pub const deeppink = Color.rgb(255, 20, 147);
    pub const palevioletred = Color.rgb(219, 112, 147);
    pub const mediumvioletred = Color.rgb(199, 21, 133);

    // Oranges
    pub const orange = Color.rgb(255, 165, 0);
    pub const darkorange = Color.rgb(255, 140, 0);
    pub const orangered = Color.rgb(255, 69, 0);
    pub const tomato = Color.rgb(255, 99, 71);
    pub const coral = Color.rgb(255, 127, 80);

    // Yellows
    pub const yellow = Color.rgb(255, 255, 0);
    pub const lightyellow = Color.rgb(255, 255, 224);
    pub const lemonchiffon = Color.rgb(255, 250, 205);
    pub const lightgoldenrodyellow = Color.rgb(250, 250, 210);
    pub const papayawhip = Color.rgb(255, 239, 213);
    pub const moccasin = Color.rgb(255, 228, 181);
    pub const peachpuff = Color.rgb(255, 218, 185);
    pub const palegoldenrod = Color.rgb(238, 232, 170);
    pub const khaki = Color.rgb(240, 230, 140);
    pub const darkkhaki = Color.rgb(189, 183, 107);
    pub const gold = Color.rgb(255, 215, 0);

    // Browns
    pub const brown = Color.rgb(165, 42, 42);
    pub const saddlebrown = Color.rgb(139, 69, 19);
    pub const sienna = Color.rgb(160, 82, 45);
    pub const chocolate = Color.rgb(210, 105, 30);
    pub const peru = Color.rgb(205, 133, 63);
    pub const sandybrown = Color.rgb(244, 164, 96);
    pub const burlywood = Color.rgb(222, 184, 135);
    pub const tan = Color.rgb(210, 180, 140);
    pub const rosybrown = Color.rgb(188, 143, 143);
    pub const goldenrod = Color.rgb(218, 165, 32);
    pub const darkgoldenrod = Color.rgb(184, 134, 11);

    // Greens
    pub const green = Color.rgb(0, 128, 0);
    pub const lime = Color.rgb(0, 255, 0);
    pub const limegreen = Color.rgb(50, 205, 50);
    pub const lightgreen = Color.rgb(144, 238, 144);
    pub const palegreen = Color.rgb(152, 251, 152);
    pub const darkgreen = Color.rgb(0, 100, 0);
    pub const forestgreen = Color.rgb(34, 139, 34);
    pub const seagreen = Color.rgb(46, 139, 87);
    pub const mediumseagreen = Color.rgb(60, 179, 113);
    pub const springgreen = Color.rgb(0, 255, 127);
    pub const mediumspringgreen = Color.rgb(0, 250, 154);
    pub const mediumaquamarine = Color.rgb(102, 205, 170);
    pub const aquamarine = Color.rgb(127, 255, 212);
    pub const darkseagreen = Color.rgb(143, 188, 143);
    pub const yellowgreen = Color.rgb(154, 205, 50);
    pub const greenyellow = Color.rgb(173, 255, 47);
    pub const chartreuse = Color.rgb(127, 255, 0);
    pub const lawngreen = Color.rgb(124, 252, 0);
    pub const olive = Color.rgb(128, 128, 0);
    pub const olivedrab = Color.rgb(107, 142, 35);
    pub const darkolivegreen = Color.rgb(85, 107, 47);

    // Cyans
    pub const cyan = Color.rgb(0, 255, 255);
    pub const aqua = cyan;
    pub const lightcyan = Color.rgb(224, 255, 255);
    pub const paleturquoise = Color.rgb(175, 238, 238);
    pub const turquoise = Color.rgb(64, 224, 208);
    pub const mediumturquoise = Color.rgb(72, 209, 204);
    pub const darkturquoise = Color.rgb(0, 206, 209);
    pub const darkcyan = Color.rgb(0, 139, 139);
    pub const teal = Color.rgb(0, 128, 128);
    pub const lightseagreen = Color.rgb(32, 178, 170);
    pub const cadetblue = Color.rgb(95, 158, 160);

    // Blues
    pub const blue = Color.rgb(0, 0, 255);
    pub const navy = Color.rgb(0, 0, 128);
    pub const darkblue = Color.rgb(0, 0, 139);
    pub const mediumblue = Color.rgb(0, 0, 205);
    pub const midnightblue = Color.rgb(25, 25, 112);
    pub const royalblue = Color.rgb(65, 105, 225);
    pub const steelblue = Color.rgb(70, 130, 180);
    pub const dodgerblue = Color.rgb(30, 144, 255);
    pub const deepskyblue = Color.rgb(0, 191, 255);
    pub const cornflowerblue = Color.rgb(100, 149, 237);
    pub const skyblue = Color.rgb(135, 206, 235);
    pub const lightskyblue = Color.rgb(135, 206, 250);
    pub const lightblue = Color.rgb(173, 216, 230);
    pub const lightsteelblue = Color.rgb(176, 196, 222);
    pub const powderblue = Color.rgb(176, 224, 230);
    pub const aliceblue = Color.rgb(240, 248, 255);

    // Purples
    pub const purple = Color.rgb(128, 0, 128);
    pub const magenta = Color.rgb(255, 0, 255);
    pub const fuchsia = magenta;
    pub const darkmagenta = Color.rgb(139, 0, 139);
    pub const indigo = Color.rgb(75, 0, 130);
    pub const darkslateblue = Color.rgb(72, 61, 139);
    pub const slateblue = Color.rgb(106, 90, 205);
    pub const mediumslateblue = Color.rgb(123, 104, 238);
    pub const mediumpurple = Color.rgb(147, 112, 219);
    pub const blueviolet = Color.rgb(138, 43, 226);
    pub const darkviolet = Color.rgb(148, 0, 211);
    pub const darkorchid = Color.rgb(153, 50, 204);
    pub const mediumorchid = Color.rgb(186, 85, 211);
    pub const orchid = Color.rgb(218, 112, 214);
    pub const violet = Color.rgb(238, 130, 238);
    pub const plum = Color.rgb(221, 160, 221);
    pub const thistle = Color.rgb(216, 191, 216);
    pub const lavender = Color.rgb(230, 230, 250);
    pub const rebeccapurple = Color.rgb(102, 51, 153);

    // Whites and off-whites
    pub const snow = Color.rgb(255, 250, 250);
    pub const honeydew = Color.rgb(240, 255, 240);
    pub const mintcream = Color.rgb(245, 255, 250);
    pub const azure = Color.rgb(240, 255, 255);
    pub const ghostwhite = Color.rgb(248, 248, 255);
    pub const floralwhite = Color.rgb(255, 250, 240);
    pub const ivory = Color.rgb(255, 255, 240);
    pub const beige = Color.rgb(245, 245, 220);
    pub const linen = Color.rgb(250, 240, 230);
    pub const oldlace = Color.rgb(253, 245, 230);
    pub const antiquewhite = Color.rgb(250, 235, 215);
    pub const bisque = Color.rgb(255, 228, 196);
    pub const blanchedalmond = Color.rgb(255, 235, 205);
    pub const navajowhite = Color.rgb(255, 222, 173);
    pub const wheat = Color.rgb(245, 222, 179);
    pub const cornsilk = Color.rgb(255, 248, 220);
    pub const seashell = Color.rgb(255, 245, 238);
    pub const lavenderblush = Color.rgb(255, 240, 245);
    pub const mistyrose = Color.rgb(255, 228, 225);

    // Salmons
    pub const salmon = Color.rgb(250, 128, 114);
    pub const lightsalmon = Color.rgb(255, 160, 122);
    pub const darksalmon = Color.rgb(233, 150, 122);

    /// Create grayscale color (0 = black, 1 = white)
    pub fn greyscale(value: f64) Color {
        return .{ .greyscale_val = value };
    }

    /// Create RGB color from 0-255 values
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb_val = .{
            .r = @as(f64, @floatFromInt(r)) / 255.0,
            .g = @as(f64, @floatFromInt(g)) / 255.0,
            .b = @as(f64, @floatFromInt(b)) / 255.0,
        } };
    }

    /// Create RGB color (values 0.0-1.0)
    pub fn rgbf(r: f64, g: f64, b: f64) Color {
        return .{ .rgb_val = .{ .r = r, .g = g, .b = b } };
    }

    /// Create CMYK color (values 0-1)
    pub fn cmyk(c: f64, m: f64, y: f64, k: f64) Color {
        return .{ .cmyk_val = .{ .c = c, .m = m, .y = y, .k = k } };
    }

    /// Create RGB color from hex string (e.g., "#FF0000", "FF0000", "#F00", "F00")
    /// Returns null if the string is invalid.
    pub fn hex(hex_str: []const u8) ?Color {
        var s = hex_str;
        // Skip leading #
        if (s.len > 0 and s[0] == '#') {
            s = s[1..];
        }

        if (s.len == 3) {
            // Short form: "F00" -> "FF0000"
            const r = parseHexDigit(s[0]) orelse return null;
            const g = parseHexDigit(s[1]) orelse return null;
            const b = parseHexDigit(s[2]) orelse return null;
            return rgb(r * 17, g * 17, b * 17);
        } else if (s.len == 6) {
            // Full form: "FF0000"
            const r = parseHexByte(s[0..2]) orelse return null;
            const g = parseHexByte(s[2..4]) orelse return null;
            const b = parseHexByte(s[4..6]) orelse return null;
            return rgb(r, g, b);
        }
        return null;
    }

    fn parseHexDigit(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn parseHexByte(s: *const [2]u8) ?u8 {
        const high = parseHexDigit(s[0]) orelse return null;
        const low = parseHexDigit(s[1]) orelse return null;
        return high * 16 + low;
    }

    /// Format color as PDF fill operator (g, rg, or k)
    pub fn writeFill(self: Color, writer: anytype) !void {
        switch (self) {
            .greyscale_val => |v| try writer.print("{d:.3} g\n", .{v}),
            .rgb_val => |c| try writer.print("{d:.3} {d:.3} {d:.3} rg\n", .{ c.r, c.g, c.b }),
            .cmyk_val => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} k\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// Format color as PDF stroke operator (G, RG, or K)
    pub fn writeStroke(self: Color, writer: anytype) !void {
        switch (self) {
            .greyscale_val => |v| try writer.print("{d:.3} G\n", .{v}),
            .rgb_val => |c| try writer.print("{d:.3} {d:.3} {d:.3} RG\n", .{ c.r, c.g, c.b }),
            .cmyk_val => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} K\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// RGB tuple type for 0-255 values
    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    /// Convert to RGB 0-255 values
    pub fn toRgb(self: Color) Rgb {
        const c = self.toRgbf();
        return .{
            .r = @intFromFloat(@round(c.r * 255)),
            .g = @intFromFloat(@round(c.g * 255)),
            .b = @intFromFloat(@round(c.b * 255)),
        };
    }

    /// RGB float tuple type (0.0-1.0) for gradient functions
    pub const Rgbf = struct { r: f64, g: f64, b: f64 };

    /// Convert to RGB float values (normalizing grayscale and approximating CMYK)
    pub fn toRgbf(self: Color) Rgbf {
        return switch (self) {
            .greyscale_val => |v| .{ .r = v, .g = v, .b = v },
            .rgb_val => |c| .{ .r = c.r, .g = c.g, .b = c.b },
            .cmyk_val => |c| .{
                // Simple CMYK to RGB conversion
                .r = (1 - c.c) * (1 - c.k),
                .g = (1 - c.m) * (1 - c.k),
                .b = (1 - c.y) * (1 - c.k),
            },
        };
    }

    /// Comptime-optimized lookup table for named CSS/SVG colors.
    const named_colors = std.StaticStringMap(Color).initComptime(.{
        // Blacks and Grays
        .{ "black", black },
        .{ "white", white },
        .{ "gray", gray },
        .{ "grey", grey },
        .{ "silver", silver },
        .{ "darkgray", darkgray },
        .{ "darkgrey", darkgrey },
        .{ "dimgray", dimgray },
        .{ "dimgrey", dimgrey },
        .{ "lightgray", lightgray },
        .{ "lightgrey", lightgrey },
        .{ "gainsboro", gainsboro },
        .{ "whitesmoke", whitesmoke },
        // Slate grays
        .{ "slategray", slategray },
        .{ "slategrey", slategrey },
        .{ "lightslategray", lightslategray },
        .{ "lightslategrey", lightslategrey },
        .{ "darkslategray", darkslategray },
        .{ "darkslategrey", darkslategrey },
        // Reds
        .{ "red", red },
        .{ "darkred", darkred },
        .{ "firebrick", firebrick },
        .{ "indianred", indianred },
        .{ "lightcoral", lightcoral },
        .{ "crimson", crimson },
        .{ "maroon", maroon },
        // Pinks
        .{ "pink", pink },
        .{ "lightpink", lightpink },
        .{ "hotpink", hotpink },
        .{ "deeppink", deeppink },
        .{ "palevioletred", palevioletred },
        .{ "mediumvioletred", mediumvioletred },
        // Oranges
        .{ "orange", orange },
        .{ "darkorange", darkorange },
        .{ "orangered", orangered },
        .{ "tomato", tomato },
        .{ "coral", coral },
        .{ "salmon", salmon },
        .{ "lightsalmon", lightsalmon },
        .{ "darksalmon", darksalmon },
        // Yellows
        .{ "yellow", yellow },
        .{ "lightyellow", lightyellow },
        .{ "gold", gold },
        .{ "khaki", khaki },
        .{ "darkkhaki", darkkhaki },
        .{ "palegoldenrod", palegoldenrod },
        .{ "moccasin", moccasin },
        .{ "peachpuff", peachpuff },
        .{ "papayawhip", papayawhip },
        .{ "lemonchiffon", lemonchiffon },
        .{ "cornsilk", cornsilk },
        // Browns
        .{ "brown", brown },
        .{ "saddlebrown", saddlebrown },
        .{ "sienna", sienna },
        .{ "chocolate", chocolate },
        .{ "peru", peru },
        .{ "sandybrown", sandybrown },
        .{ "burlywood", burlywood },
        .{ "tan", tan },
        .{ "rosybrown", rosybrown },
        .{ "goldenrod", goldenrod },
        .{ "darkgoldenrod", darkgoldenrod },
        // Greens
        .{ "green", green },
        .{ "lime", lime },
        .{ "limegreen", limegreen },
        .{ "lightgreen", lightgreen },
        .{ "palegreen", palegreen },
        .{ "darkgreen", darkgreen },
        .{ "forestgreen", forestgreen },
        .{ "seagreen", seagreen },
        .{ "mediumseagreen", mediumseagreen },
        .{ "springgreen", springgreen },
        .{ "mediumspringgreen", mediumspringgreen },
        .{ "mediumaquamarine", mediumaquamarine },
        .{ "aquamarine", aquamarine },
        .{ "darkseagreen", darkseagreen },
        .{ "yellowgreen", yellowgreen },
        .{ "greenyellow", greenyellow },
        .{ "chartreuse", chartreuse },
        .{ "lawngreen", lawngreen },
        .{ "olive", olive },
        .{ "olivedrab", olivedrab },
        .{ "darkolivegreen", darkolivegreen },
        // Cyans
        .{ "cyan", cyan },
        .{ "aqua", aqua },
        .{ "lightcyan", lightcyan },
        .{ "paleturquoise", paleturquoise },
        .{ "turquoise", turquoise },
        .{ "mediumturquoise", mediumturquoise },
        .{ "darkturquoise", darkturquoise },
        .{ "darkcyan", darkcyan },
        .{ "teal", teal },
        .{ "lightseagreen", lightseagreen },
        .{ "cadetblue", cadetblue },
        // Blues
        .{ "blue", blue },
        .{ "navy", navy },
        .{ "darkblue", darkblue },
        .{ "mediumblue", mediumblue },
        .{ "midnightblue", midnightblue },
        .{ "royalblue", royalblue },
        .{ "steelblue", steelblue },
        .{ "dodgerblue", dodgerblue },
        .{ "deepskyblue", deepskyblue },
        .{ "cornflowerblue", cornflowerblue },
        .{ "skyblue", skyblue },
        .{ "lightskyblue", lightskyblue },
        .{ "lightblue", lightblue },
        .{ "lightsteelblue", lightsteelblue },
        .{ "powderblue", powderblue },
        .{ "aliceblue", aliceblue },
        // Purples
        .{ "purple", purple },
        .{ "magenta", magenta },
        .{ "fuchsia", fuchsia },
        .{ "darkmagenta", darkmagenta },
        .{ "indigo", indigo },
        .{ "darkslateblue", darkslateblue },
        .{ "slateblue", slateblue },
        .{ "mediumslateblue", mediumslateblue },
        .{ "mediumpurple", mediumpurple },
        .{ "blueviolet", blueviolet },
        .{ "darkviolet", darkviolet },
        .{ "darkorchid", darkorchid },
        .{ "mediumorchid", mediumorchid },
        .{ "orchid", orchid },
        .{ "violet", violet },
        .{ "plum", plum },
        .{ "thistle", thistle },
        .{ "lavender", lavender },
        .{ "rebeccapurple", rebeccapurple },
        // Whites and off-whites
        .{ "snow", snow },
        .{ "honeydew", honeydew },
        .{ "mintcream", mintcream },
        .{ "azure", azure },
        .{ "ghostwhite", ghostwhite },
        .{ "floralwhite", floralwhite },
        .{ "ivory", ivory },
        .{ "beige", beige },
        .{ "linen", linen },
        .{ "oldlace", oldlace },
        .{ "antiquewhite", antiquewhite },
        .{ "bisque", bisque },
        .{ "blanchedalmond", blanchedalmond },
        .{ "navajowhite", navajowhite },
        .{ "wheat", wheat },
        .{ "seashell", seashell },
        .{ "lavenderblush", lavenderblush },
        .{ "mistyrose", mistyrose },
    });

    /// Look up a named CSS/SVG color by name (case-sensitive).
    /// Returns null if the name is not recognized.
    /// Uses comptime-optimized hash lookup.
    pub fn fromName(name: []const u8) ?Color {
        return named_colors.get(name);
    }

    /// Check if two colors are equal
    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .greyscale_val => |v| switch (other) {
                .greyscale_val => |ov| v == ov,
                else => false,
            },
            .rgb_val => |c| switch (other) {
                .rgb_val => |oc| c.r == oc.r and c.g == oc.g and c.b == oc.b,
                else => false,
            },
            .cmyk_val => |c| switch (other) {
                .cmyk_val => |oc| c.c == oc.c and c.m == oc.m and c.y == oc.y and c.k == oc.k,
                else => false,
            },
        };
    }
};

test "Color greyscale" {
    const black = Color.black;
    try std.testing.expectEqual(Color{ .greyscale_val = 0 }, black);

    const white = Color.white;
    try std.testing.expectEqual(Color{ .greyscale_val = 1 }, white);

    const gray50 = Color.greyscale(0.5);
    try std.testing.expectEqual(@as(f64, 0.5), gray50.greyscale_val);
}

test "Color RGB" {
    const red = Color.red;
    try std.testing.expectEqual(@as(f64, 1), red.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 0), red.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 0), red.rgb_val.b);

    const custom = Color.rgbf(0.5, 0.25, 0.75);
    try std.testing.expectEqual(@as(f64, 0.5), custom.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 0.25), custom.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 0.75), custom.rgb_val.b);
}

test "Color RGB from 255" {
    const color = Color.rgb(255, 128, 0);
    try std.testing.expectEqual(@as(f64, 1.0), color.rgb_val.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), color.rgb_val.g, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), color.rgb_val.b);
}

test "Color CMYK" {
    const cyan = Color.cmyk(1, 0, 0, 0);
    try std.testing.expectEqual(@as(f64, 1), cyan.cmyk_val.c);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk_val.m);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk_val.y);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk_val.k);
}

test "Color writeFill formats correctly" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Grayscale
    try Color.black.writeFill(writer);
    try std.testing.expectEqualStrings("0.000 g\n", fbs.getWritten());

    // RGB
    fbs.reset();
    try Color.red.writeFill(writer);
    try std.testing.expectEqualStrings("1.000 0.000 0.000 rg\n", fbs.getWritten());

    // CMYK
    fbs.reset();
    try Color.cmyk(1, 0, 0, 0).writeFill(writer);
    try std.testing.expectEqualStrings("1.000 0.000 0.000 0.000 k\n", fbs.getWritten());
}

test "Color writeStroke formats correctly" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Grayscale
    try Color.white.writeStroke(writer);
    try std.testing.expectEqualStrings("1.000 G\n", fbs.getWritten());

    // RGB
    fbs.reset();
    try Color.blue.writeStroke(writer);
    try std.testing.expectEqualStrings("0.000 0.000 1.000 RG\n", fbs.getWritten());
}

test "Color equality" {
    try std.testing.expect(Color.black.eql(Color.black));
    try std.testing.expect(Color.red.eql(Color.red));
    try std.testing.expect(!Color.black.eql(Color.white));
    try std.testing.expect(!Color.black.eql(Color.red)); // gray vs rgb
}

test "Color hex" {
    // Full hex with #
    const red = Color.hex("#FF0000").?;
    try std.testing.expectEqual(@as(f64, 1.0), red.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 0.0), red.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 0.0), red.rgb_val.b);

    // Full hex without #
    const green = Color.hex("00FF00").?;
    try std.testing.expectEqual(@as(f64, 0.0), green.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 1.0), green.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 0.0), green.rgb_val.b);

    // Short hex with #
    const blue = Color.hex("#00F").?;
    try std.testing.expectEqual(@as(f64, 0.0), blue.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 0.0), blue.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 1.0), blue.rgb_val.b);

    // Short hex without #
    const white = Color.hex("FFF").?;
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb_val.b);

    // Lowercase
    const coral = Color.hex("#ff7f50").?;
    try std.testing.expectEqual(@as(f64, 1.0), coral.rgb_val.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.498), coral.rgb_val.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.314), coral.rgb_val.b, 0.01);

    // Invalid inputs return null
    try std.testing.expect(Color.hex("") == null);
    try std.testing.expect(Color.hex("#") == null);
    try std.testing.expect(Color.hex("GG0000") == null);
    try std.testing.expect(Color.hex("#12345") == null);
}

test "Color presets" {
    // Verify some preset colors have expected values
    // Navy is #000080 = rgb(0, 0, 128)
    try std.testing.expectEqual(@as(f64, 0.0), Color.navy.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 0.0), Color.navy.rgb_val.g);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), Color.navy.rgb_val.b, 0.01);

    // Cyan is #00FFFF
    try std.testing.expectEqual(@as(f64, 1.0), Color.cyan.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 1.0), Color.cyan.rgb_val.b);

    // Yellow is #FFFF00
    try std.testing.expectEqual(@as(f64, 1.0), Color.yellow.rgb_val.r);
    try std.testing.expectEqual(@as(f64, 1.0), Color.yellow.rgb_val.g);
    try std.testing.expectEqual(@as(f64, 0.0), Color.yellow.rgb_val.b);

    // Aliases work
    try std.testing.expect(Color.grey.eql(Color.gray));
    try std.testing.expect(Color.aqua.eql(Color.cyan));
    try std.testing.expect(Color.fuchsia.eql(Color.magenta));
}
