//! Gradient support for platen - linear and radial gradients.
//!
//! PDF gradients are implemented using:
//! - Shading dictionaries (Type 2 for linear/axial, Type 3 for radial)
//! - Pattern resources referencing the shading
//! - Pattern color space for fills

const std = @import("std");
const Color = @import("color.zig").Color;
const format = @import("format.zig");

/// A color stop in a gradient.
pub const ColorStop = struct {
    offset: f64, // 0.0 to 1.0
    color: Color,
};

/// Linear (axial) gradient definition.
pub const LinearGradient = struct {
    /// Start point X
    x0: f64,
    /// Start point Y
    y0: f64,
    /// End point X
    x1: f64,
    /// End point Y
    y1: f64,
    /// Color stops (must have at least 2)
    stops: []const ColorStop,
    /// Extend gradient before start point
    extend_before: bool = false,
    /// Extend gradient after end point
    extend_after: bool = true,

    /// Write PDF shading dictionary content.
    /// Returns the function object references needed.
    pub fn writeShadingDict(self: LinearGradient, writer: anytype, page_height: f64, func_ref: u32) !void {
        // Convert Y coordinates from top-left to PDF bottom-left
        const pdf_y0 = page_height - self.y0;
        const pdf_y1 = page_height - self.y1;

        var buf: [32]u8 = undefined;
        try writer.writeAll("<<\n/ShadingType 2\n/ColorSpace /DeviceRGB\n/Coords [");
        try writer.writeAll(format.writeF64_2(&buf, self.x0));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, pdf_y0));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, self.x1));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, pdf_y1));
        try writer.writeAll("]\n/Function ");
        try writer.writeAll(format.writeInt(&buf, func_ref));
        try writer.writeAll(" 0 R\n/Extend [");
        try writer.writeAll(if (self.extend_before) "true " else "false ");
        try writer.writeAll(if (self.extend_after) "true" else "false");
        try writer.writeAll("]\n>>");
    }
};

/// Radial gradient definition.
pub const RadialGradient = struct {
    /// Inner circle center X
    x0: f64,
    /// Inner circle center Y
    y0: f64,
    /// Inner circle radius
    r0: f64,
    /// Outer circle center X
    x1: f64,
    /// Outer circle center Y
    y1: f64,
    /// Outer circle radius
    r1: f64,
    /// Color stops (must have at least 2)
    stops: []const ColorStop,
    /// Extend gradient before start circle
    extend_before: bool = false,
    /// Extend gradient after end circle
    extend_after: bool = true,

    /// Write PDF shading dictionary content.
    pub fn writeShadingDict(self: RadialGradient, writer: anytype, page_height: f64, func_ref: u32) !void {
        // Convert Y coordinates from top-left to PDF bottom-left
        const pdf_y0 = page_height - self.y0;
        const pdf_y1 = page_height - self.y1;

        var buf: [32]u8 = undefined;
        try writer.writeAll("<<\n/ShadingType 3\n/ColorSpace /DeviceRGB\n/Coords [");
        try writer.writeAll(format.writeF64_2(&buf, self.x0));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, pdf_y0));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, self.r0));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, self.x1));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, pdf_y1));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_2(&buf, self.r1));
        try writer.writeAll("]\n/Function ");
        try writer.writeAll(format.writeInt(&buf, func_ref));
        try writer.writeAll(" 0 R\n/Extend [");
        try writer.writeAll(if (self.extend_before) "true " else "false ");
        try writer.writeAll(if (self.extend_after) "true" else "false");
        try writer.writeAll("]\n>>");
    }
};

/// Write a PDF Type 2 exponential interpolation function for two colors.
fn writeType2Function(writer: anytype, c0: Color.Rgbf, c1: Color.Rgbf, comptime compact: bool) !void {
    var buf: [32]u8 = undefined;
    if (compact) {
        try writer.writeAll("<< /FunctionType 2 /Domain [0 1] /C0 [");
        try writer.writeAll(format.writeF64_3(&buf, c0.r));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c0.g));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c0.b));
        try writer.writeAll("] /C1 [");
        try writer.writeAll(format.writeF64_3(&buf, c1.r));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c1.g));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c1.b));
        try writer.writeAll("] /N 1 >>\n");
    } else {
        try writer.writeAll("<<\n/FunctionType 2\n/Domain [0 1]\n/C0 [");
        try writer.writeAll(format.writeF64_3(&buf, c0.r));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c0.g));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c0.b));
        try writer.writeAll("]\n/C1 [");
        try writer.writeAll(format.writeF64_3(&buf, c1.r));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c1.g));
        try writer.writeByte(' ');
        try writer.writeAll(format.writeF64_3(&buf, c1.b));
        try writer.writeAll("]\n/N 1\n>>");
    }
}

/// Write a PDF function for gradient color interpolation.
/// For 2 stops: Type 2 exponential interpolation function.
/// For 3+ stops: Type 3 stitching function.
pub fn writeFunctionDict(stops: []const ColorStop, writer: anytype) !void {
    if (stops.len < 2) return error.InvalidGradient;

    if (stops.len == 2) {
        // Simple 2-color: Type 2 exponential interpolation
        try writeType2Function(writer, stops[0].color.toRgbf(), stops[1].color.toRgbf(), false);
    } else {
        // Multi-color: Type 3 stitching function
        // Each pair of adjacent stops needs a Type 2 function
        try writer.writeAll("<<\n/FunctionType 3\n/Domain [0 1]\n");

        // Functions array (inline Type 2 functions)
        try writer.writeAll("/Functions [\n");
        for (0..stops.len - 1) |i| {
            try writeType2Function(writer, stops[i].color.toRgbf(), stops[i + 1].color.toRgbf(), true);
        }
        try writer.writeAll("]\n");

        // Bounds array (offsets between stops, excluding first and last)
        try writer.writeAll("/Bounds [");
        var buf: [32]u8 = undefined;
        for (1..stops.len - 1) |i| {
            if (i > 1) try writer.writeAll(" ");
            try writer.writeAll(format.writeF64_3(&buf, stops[i].offset));
        }
        try writer.writeAll("]\n");

        // Encode array (map each function's domain)
        try writer.writeAll("/Encode [");
        for (0..stops.len - 1) |_| {
            try writer.writeAll("0 1 ");
        }
        try writer.writeAll("]\n>>");
    }
}

test "linear gradient 2 colors" {
    const stops = [_]ColorStop{
        .{ .offset = 0.0, .color = Color.red },
        .{ .offset = 1.0, .color = Color.blue },
    };

    var buf: [512]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeFunctionDict(&stops, &fbs);

    const output = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "/FunctionType 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/C0 [1.000 0.000 0.000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/C1 [0.000 0.000 1.000]") != null);
}

test "linear gradient 3 colors" {
    const stops = [_]ColorStop{
        .{ .offset = 0.0, .color = Color.red },
        .{ .offset = 0.5, .color = Color.white },
        .{ .offset = 1.0, .color = Color.blue },
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeFunctionDict(&stops, &fbs);

    const output = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "/FunctionType 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/Bounds [0.500]") != null);
}
