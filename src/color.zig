const std = @import("std");

/// Color with support for multiple color spaces.
/// All values are normalized to 0.0-1.0 range.
pub const Color = union(enum) {
    /// Grayscale: 0 = black, 1 = white
    g: f64,
    /// RGB color space (screen/web)
    rgb: struct { r: f64, g: f64, b: f64 },
    /// CMYK color space (print)
    cmyk: struct { c: f64, m: f64, y: f64, k: f64 },

    // CSS Named Colors (148 colors)
    // https://www.w3.org/TR/css-color-4/#named-colors

    // Blacks and Grays
    pub const black = Color{ .g = 0 };
    pub const white = Color{ .g = 1 };
    pub const gray = Color.fromRgb255(128, 128, 128);
    pub const grey = gray;
    pub const silver = Color.fromRgb255(192, 192, 192);
    pub const darkgray = Color.fromRgb255(169, 169, 169);
    pub const darkgrey = darkgray;
    pub const dimgray = Color.fromRgb255(105, 105, 105);
    pub const dimgrey = dimgray;
    pub const lightgray = Color.fromRgb255(211, 211, 211);
    pub const lightgrey = lightgray;
    pub const gainsboro = Color.fromRgb255(220, 220, 220);
    pub const whitesmoke = Color.fromRgb255(245, 245, 245);

    // Slate grays
    pub const slategray = Color.fromRgb255(112, 128, 144);
    pub const slategrey = slategray;
    pub const lightslategray = Color.fromRgb255(119, 136, 153);
    pub const lightslategrey = lightslategray;
    pub const darkslategray = Color.fromRgb255(47, 79, 79);
    pub const darkslategrey = darkslategray;

    // Reds
    pub const red = Color.fromRgb255(255, 0, 0);
    pub const darkred = Color.fromRgb255(139, 0, 0);
    pub const firebrick = Color.fromRgb255(178, 34, 34);
    pub const indianred = Color.fromRgb255(205, 92, 92);
    pub const lightcoral = Color.fromRgb255(240, 128, 128);
    pub const crimson = Color.fromRgb255(220, 20, 60);
    pub const maroon = Color.fromRgb255(128, 0, 0);

    // Pinks
    pub const pink = Color.fromRgb255(255, 192, 203);
    pub const lightpink = Color.fromRgb255(255, 182, 193);
    pub const hotpink = Color.fromRgb255(255, 105, 180);
    pub const deeppink = Color.fromRgb255(255, 20, 147);
    pub const palevioletred = Color.fromRgb255(219, 112, 147);
    pub const mediumvioletred = Color.fromRgb255(199, 21, 133);

    // Oranges
    pub const orange = Color.fromRgb255(255, 165, 0);
    pub const darkorange = Color.fromRgb255(255, 140, 0);
    pub const orangered = Color.fromRgb255(255, 69, 0);
    pub const tomato = Color.fromRgb255(255, 99, 71);
    pub const coral = Color.fromRgb255(255, 127, 80);

    // Yellows
    pub const yellow = Color.fromRgb255(255, 255, 0);
    pub const lightyellow = Color.fromRgb255(255, 255, 224);
    pub const lemonchiffon = Color.fromRgb255(255, 250, 205);
    pub const lightgoldenrodyellow = Color.fromRgb255(250, 250, 210);
    pub const papayawhip = Color.fromRgb255(255, 239, 213);
    pub const moccasin = Color.fromRgb255(255, 228, 181);
    pub const peachpuff = Color.fromRgb255(255, 218, 185);
    pub const palegoldenrod = Color.fromRgb255(238, 232, 170);
    pub const khaki = Color.fromRgb255(240, 230, 140);
    pub const darkkhaki = Color.fromRgb255(189, 183, 107);
    pub const gold = Color.fromRgb255(255, 215, 0);

    // Browns
    pub const brown = Color.fromRgb255(165, 42, 42);
    pub const saddlebrown = Color.fromRgb255(139, 69, 19);
    pub const sienna = Color.fromRgb255(160, 82, 45);
    pub const chocolate = Color.fromRgb255(210, 105, 30);
    pub const peru = Color.fromRgb255(205, 133, 63);
    pub const sandybrown = Color.fromRgb255(244, 164, 96);
    pub const burlywood = Color.fromRgb255(222, 184, 135);
    pub const tan = Color.fromRgb255(210, 180, 140);
    pub const rosybrown = Color.fromRgb255(188, 143, 143);
    pub const goldenrod = Color.fromRgb255(218, 165, 32);
    pub const darkgoldenrod = Color.fromRgb255(184, 134, 11);

    // Greens
    pub const green = Color.fromRgb255(0, 128, 0);
    pub const lime = Color.fromRgb255(0, 255, 0);
    pub const limegreen = Color.fromRgb255(50, 205, 50);
    pub const lightgreen = Color.fromRgb255(144, 238, 144);
    pub const palegreen = Color.fromRgb255(152, 251, 152);
    pub const darkgreen = Color.fromRgb255(0, 100, 0);
    pub const forestgreen = Color.fromRgb255(34, 139, 34);
    pub const seagreen = Color.fromRgb255(46, 139, 87);
    pub const mediumseagreen = Color.fromRgb255(60, 179, 113);
    pub const springgreen = Color.fromRgb255(0, 255, 127);
    pub const mediumspringgreen = Color.fromRgb255(0, 250, 154);
    pub const mediumaquamarine = Color.fromRgb255(102, 205, 170);
    pub const aquamarine = Color.fromRgb255(127, 255, 212);
    pub const darkseagreen = Color.fromRgb255(143, 188, 143);
    pub const yellowgreen = Color.fromRgb255(154, 205, 50);
    pub const greenyellow = Color.fromRgb255(173, 255, 47);
    pub const chartreuse = Color.fromRgb255(127, 255, 0);
    pub const lawngreen = Color.fromRgb255(124, 252, 0);
    pub const olive = Color.fromRgb255(128, 128, 0);
    pub const olivedrab = Color.fromRgb255(107, 142, 35);
    pub const darkolivegreen = Color.fromRgb255(85, 107, 47);

    // Cyans
    pub const cyan = Color.fromRgb255(0, 255, 255);
    pub const aqua = cyan;
    pub const lightcyan = Color.fromRgb255(224, 255, 255);
    pub const paleturquoise = Color.fromRgb255(175, 238, 238);
    pub const turquoise = Color.fromRgb255(64, 224, 208);
    pub const mediumturquoise = Color.fromRgb255(72, 209, 204);
    pub const darkturquoise = Color.fromRgb255(0, 206, 209);
    pub const darkcyan = Color.fromRgb255(0, 139, 139);
    pub const teal = Color.fromRgb255(0, 128, 128);
    pub const lightseagreen = Color.fromRgb255(32, 178, 170);
    pub const cadetblue = Color.fromRgb255(95, 158, 160);

    // Blues
    pub const blue = Color.fromRgb255(0, 0, 255);
    pub const navy = Color.fromRgb255(0, 0, 128);
    pub const darkblue = Color.fromRgb255(0, 0, 139);
    pub const mediumblue = Color.fromRgb255(0, 0, 205);
    pub const midnightblue = Color.fromRgb255(25, 25, 112);
    pub const royalblue = Color.fromRgb255(65, 105, 225);
    pub const steelblue = Color.fromRgb255(70, 130, 180);
    pub const dodgerblue = Color.fromRgb255(30, 144, 255);
    pub const deepskyblue = Color.fromRgb255(0, 191, 255);
    pub const cornflowerblue = Color.fromRgb255(100, 149, 237);
    pub const skyblue = Color.fromRgb255(135, 206, 235);
    pub const lightskyblue = Color.fromRgb255(135, 206, 250);
    pub const lightblue = Color.fromRgb255(173, 216, 230);
    pub const lightsteelblue = Color.fromRgb255(176, 196, 222);
    pub const powderblue = Color.fromRgb255(176, 224, 230);
    pub const aliceblue = Color.fromRgb255(240, 248, 255);

    // Purples
    pub const purple = Color.fromRgb255(128, 0, 128);
    pub const magenta = Color.fromRgb255(255, 0, 255);
    pub const fuchsia = magenta;
    pub const darkmagenta = Color.fromRgb255(139, 0, 139);
    pub const indigo = Color.fromRgb255(75, 0, 130);
    pub const darkslateblue = Color.fromRgb255(72, 61, 139);
    pub const slateblue = Color.fromRgb255(106, 90, 205);
    pub const mediumslateblue = Color.fromRgb255(123, 104, 238);
    pub const mediumpurple = Color.fromRgb255(147, 112, 219);
    pub const blueviolet = Color.fromRgb255(138, 43, 226);
    pub const darkviolet = Color.fromRgb255(148, 0, 211);
    pub const darkorchid = Color.fromRgb255(153, 50, 204);
    pub const mediumorchid = Color.fromRgb255(186, 85, 211);
    pub const orchid = Color.fromRgb255(218, 112, 214);
    pub const violet = Color.fromRgb255(238, 130, 238);
    pub const plum = Color.fromRgb255(221, 160, 221);
    pub const thistle = Color.fromRgb255(216, 191, 216);
    pub const lavender = Color.fromRgb255(230, 230, 250);
    pub const rebeccapurple = Color.fromRgb255(102, 51, 153);

    // Whites and off-whites
    pub const snow = Color.fromRgb255(255, 250, 250);
    pub const honeydew = Color.fromRgb255(240, 255, 240);
    pub const mintcream = Color.fromRgb255(245, 255, 250);
    pub const azure = Color.fromRgb255(240, 255, 255);
    pub const ghostwhite = Color.fromRgb255(248, 248, 255);
    pub const floralwhite = Color.fromRgb255(255, 250, 240);
    pub const ivory = Color.fromRgb255(255, 255, 240);
    pub const beige = Color.fromRgb255(245, 245, 220);
    pub const linen = Color.fromRgb255(250, 240, 230);
    pub const oldlace = Color.fromRgb255(253, 245, 230);
    pub const antiquewhite = Color.fromRgb255(250, 235, 215);
    pub const bisque = Color.fromRgb255(255, 228, 196);
    pub const blanchedalmond = Color.fromRgb255(255, 235, 205);
    pub const navajowhite = Color.fromRgb255(255, 222, 173);
    pub const wheat = Color.fromRgb255(245, 222, 179);
    pub const cornsilk = Color.fromRgb255(255, 248, 220);
    pub const seashell = Color.fromRgb255(255, 245, 238);
    pub const lavenderblush = Color.fromRgb255(255, 240, 245);
    pub const mistyrose = Color.fromRgb255(255, 228, 225);

    // Salmons
    pub const salmon = Color.fromRgb255(250, 128, 114);
    pub const lightsalmon = Color.fromRgb255(255, 160, 122);
    pub const darksalmon = Color.fromRgb255(233, 150, 122);

    /// Create grayscale color (0 = black, 1 = white)
    pub fn grayscale(value: f64) Color {
        return .{ .g = value };
    }

    /// Create RGB color (values 0-1)
    pub fn fromRgb(r: f64, g: f64, b: f64) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create RGB color from 0-255 values
    pub fn fromRgb255(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{
            .r = @as(f64, @floatFromInt(r)) / 255.0,
            .g = @as(f64, @floatFromInt(g)) / 255.0,
            .b = @as(f64, @floatFromInt(b)) / 255.0,
        } };
    }

    /// Create CMYK color (values 0-1)
    pub fn fromCmyk(c: f64, m: f64, y: f64, k: f64) Color {
        return .{ .cmyk = .{ .c = c, .m = m, .y = y, .k = k } };
    }

    /// Create RGB color from hex string (e.g., "#FF0000", "FF0000", "#F00", "F00")
    /// Returns null if the string is invalid.
    pub fn fromHex(hex: []const u8) ?Color {
        var s = hex;
        // Skip leading #
        if (s.len > 0 and s[0] == '#') {
            s = s[1..];
        }

        if (s.len == 3) {
            // Short form: "F00" -> "FF0000"
            const r = parseHexDigit(s[0]) orelse return null;
            const g = parseHexDigit(s[1]) orelse return null;
            const b = parseHexDigit(s[2]) orelse return null;
            return fromRgb255(r * 17, g * 17, b * 17);
        } else if (s.len == 6) {
            // Full form: "FF0000"
            const r = parseHexByte(s[0..2]) orelse return null;
            const g = parseHexByte(s[2..4]) orelse return null;
            const b = parseHexByte(s[4..6]) orelse return null;
            return fromRgb255(r, g, b);
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
            .g => |v| try writer.print("{d:.3} g\n", .{v}),
            .rgb => |c| try writer.print("{d:.3} {d:.3} {d:.3} rg\n", .{ c.r, c.g, c.b }),
            .cmyk => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} k\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// Format color as PDF stroke operator (G, RG, or K)
    pub fn writeStroke(self: Color, writer: anytype) !void {
        switch (self) {
            .g => |v| try writer.print("{d:.3} G\n", .{v}),
            .rgb => |c| try writer.print("{d:.3} {d:.3} {d:.3} RG\n", .{ c.r, c.g, c.b }),
            .cmyk => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} K\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// RGB tuple type for gradient functions
    pub const Rgb = struct { r: f64, g: f64, b: f64 };

    /// Convert to RGB values (normalizing grayscale and approximating CMYK)
    pub fn toRgb(self: Color) Rgb {
        return switch (self) {
            .g => |v| .{ .r = v, .g = v, .b = v },
            .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b },
            .cmyk => |c| .{
                // Simple CMYK to RGB conversion
                .r = (1 - c.c) * (1 - c.k),
                .g = (1 - c.m) * (1 - c.k),
                .b = (1 - c.y) * (1 - c.k),
            },
        };
    }

    /// RGB tuple type for 0-255 values (useful for SVG)
    pub const Rgb255 = struct { r: u8, g: u8, b: u8 };

    /// Convert to RGB 0-255 values
    pub fn toRgb255(self: Color) Rgb255 {
        const rgb = self.toRgb();
        return .{
            .r = @intFromFloat(@round(rgb.r * 255)),
            .g = @intFromFloat(@round(rgb.g * 255)),
            .b = @intFromFloat(@round(rgb.b * 255)),
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
            .g => |v| switch (other) {
                .g => |ov| v == ov,
                else => false,
            },
            .rgb => |c| switch (other) {
                .rgb => |oc| c.r == oc.r and c.g == oc.g and c.b == oc.b,
                else => false,
            },
            .cmyk => |c| switch (other) {
                .cmyk => |oc| c.c == oc.c and c.m == oc.m and c.y == oc.y and c.k == oc.k,
                else => false,
            },
        };
    }
};

test "Color grayscale" {
    const black = Color.black;
    try std.testing.expectEqual(Color{ .g = 0 }, black);

    const white = Color.white;
    try std.testing.expectEqual(Color{ .g = 1 }, white);

    const gray50 = Color.grayscale(0.5);
    try std.testing.expectEqual(@as(f64, 0.5), gray50.g);
}

test "Color RGB" {
    const red = Color.red;
    try std.testing.expectEqual(@as(f64, 1), red.rgb.r);
    try std.testing.expectEqual(@as(f64, 0), red.rgb.g);
    try std.testing.expectEqual(@as(f64, 0), red.rgb.b);

    const custom = Color.fromRgb(0.5, 0.25, 0.75);
    try std.testing.expectEqual(@as(f64, 0.5), custom.rgb.r);
    try std.testing.expectEqual(@as(f64, 0.25), custom.rgb.g);
    try std.testing.expectEqual(@as(f64, 0.75), custom.rgb.b);
}

test "Color RGB from 255" {
    const color = Color.fromRgb255(255, 128, 0);
    try std.testing.expectEqual(@as(f64, 1.0), color.rgb.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), color.rgb.g, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), color.rgb.b);
}

test "Color CMYK" {
    const cyan = Color.fromCmyk(1, 0, 0, 0);
    try std.testing.expectEqual(@as(f64, 1), cyan.cmyk.c);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk.m);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk.y);
    try std.testing.expectEqual(@as(f64, 0), cyan.cmyk.k);
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
    try Color.fromCmyk(1, 0, 0, 0).writeFill(writer);
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

test "Color fromHex" {
    // Full hex with #
    const red = Color.fromHex("#FF0000").?;
    try std.testing.expectEqual(@as(f64, 1.0), red.rgb.r);
    try std.testing.expectEqual(@as(f64, 0.0), red.rgb.g);
    try std.testing.expectEqual(@as(f64, 0.0), red.rgb.b);

    // Full hex without #
    const green = Color.fromHex("00FF00").?;
    try std.testing.expectEqual(@as(f64, 0.0), green.rgb.r);
    try std.testing.expectEqual(@as(f64, 1.0), green.rgb.g);
    try std.testing.expectEqual(@as(f64, 0.0), green.rgb.b);

    // Short hex with #
    const blue = Color.fromHex("#00F").?;
    try std.testing.expectEqual(@as(f64, 0.0), blue.rgb.r);
    try std.testing.expectEqual(@as(f64, 0.0), blue.rgb.g);
    try std.testing.expectEqual(@as(f64, 1.0), blue.rgb.b);

    // Short hex without #
    const white = Color.fromHex("FFF").?;
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb.r);
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb.g);
    try std.testing.expectEqual(@as(f64, 1.0), white.rgb.b);

    // Lowercase
    const coral = Color.fromHex("#ff7f50").?;
    try std.testing.expectEqual(@as(f64, 1.0), coral.rgb.r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.498), coral.rgb.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.314), coral.rgb.b, 0.01);

    // Invalid inputs return null
    try std.testing.expect(Color.fromHex("") == null);
    try std.testing.expect(Color.fromHex("#") == null);
    try std.testing.expect(Color.fromHex("GG0000") == null);
    try std.testing.expect(Color.fromHex("#12345") == null);
}

test "Color presets" {
    // Verify some preset colors have expected values
    // Navy is #000080 = rgb(0, 0, 128)
    try std.testing.expectEqual(@as(f64, 0.0), Color.navy.rgb.r);
    try std.testing.expectEqual(@as(f64, 0.0), Color.navy.rgb.g);
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), Color.navy.rgb.b, 0.01);

    // Cyan is #00FFFF
    try std.testing.expectEqual(@as(f64, 1.0), Color.cyan.rgb.g);
    try std.testing.expectEqual(@as(f64, 1.0), Color.cyan.rgb.b);

    // Yellow is #FFFF00
    try std.testing.expectEqual(@as(f64, 1.0), Color.yellow.rgb.r);
    try std.testing.expectEqual(@as(f64, 1.0), Color.yellow.rgb.g);
    try std.testing.expectEqual(@as(f64, 0.0), Color.yellow.rgb.b);

    // Aliases work
    try std.testing.expect(Color.grey.eql(Color.gray));
    try std.testing.expect(Color.aqua.eql(Color.cyan));
    try std.testing.expect(Color.fuchsia.eql(Color.magenta));
}
