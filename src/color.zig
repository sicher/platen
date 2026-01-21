const std = @import("std");

/// Color with support for multiple color spaces.
/// All values are normalized to 0.0-1.0 range.
pub const Color = union(enum) {
    /// Grayscale: 0 = black, 1 = white
    gray: f64,
    /// RGB color space (screen/web)
    rgb: struct { r: f64, g: f64, b: f64 },
    /// CMYK color space (print)
    cmyk: struct { c: f64, m: f64, y: f64, k: f64 },

    // Common colors
    pub const black = Color{ .gray = 0 };
    pub const white = Color{ .gray = 1 };
    pub const red = Color{ .rgb = .{ .r = 1, .g = 0, .b = 0 } };
    pub const green = Color{ .rgb = .{ .r = 0, .g = 1, .b = 0 } };
    pub const blue = Color{ .rgb = .{ .r = 0, .g = 0, .b = 1 } };

    /// Create grayscale color (0 = black, 1 = white)
    pub fn grayscale(value: f64) Color {
        return .{ .gray = value };
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

    /// Format color as PDF fill operator (g, rg, or k)
    pub fn writeFill(self: Color, writer: anytype) !void {
        switch (self) {
            .gray => |g| try writer.print("{d:.3} g\n", .{g}),
            .rgb => |c| try writer.print("{d:.3} {d:.3} {d:.3} rg\n", .{ c.r, c.g, c.b }),
            .cmyk => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} k\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// Format color as PDF stroke operator (G, RG, or K)
    pub fn writeStroke(self: Color, writer: anytype) !void {
        switch (self) {
            .gray => |g| try writer.print("{d:.3} G\n", .{g}),
            .rgb => |c| try writer.print("{d:.3} {d:.3} {d:.3} RG\n", .{ c.r, c.g, c.b }),
            .cmyk => |c| try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} K\n", .{ c.c, c.m, c.y, c.k }),
        }
    }

    /// RGB tuple type for gradient functions
    pub const Rgb = struct { r: f64, g: f64, b: f64 };

    /// Convert to RGB values (normalizing grayscale and approximating CMYK)
    pub fn toRgb(self: Color) Rgb {
        return switch (self) {
            .gray => |g| .{ .r = g, .g = g, .b = g },
            .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b },
            .cmyk => |c| .{
                // Simple CMYK to RGB conversion
                .r = (1 - c.c) * (1 - c.k),
                .g = (1 - c.m) * (1 - c.k),
                .b = (1 - c.y) * (1 - c.k),
            },
        };
    }

    /// Check if two colors are equal
    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .gray => |g| switch (other) {
                .gray => |og| g == og,
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
    try std.testing.expectEqual(Color{ .gray = 0 }, black);

    const white = Color.white;
    try std.testing.expectEqual(Color{ .gray = 1 }, white);

    const gray50 = Color.grayscale(0.5);
    try std.testing.expectEqual(@as(f64, 0.5), gray50.gray);
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
