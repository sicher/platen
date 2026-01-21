//! Gradient support for zpdf - linear and radial gradients.
//!
//! PDF gradients are implemented using:
//! - Shading dictionaries (Type 2 for linear/axial, Type 3 for radial)
//! - Pattern resources referencing the shading
//! - Pattern color space for fills

const std = @import("std");
const Color = @import("color.zig").Color;

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

        try writer.print(
            \\<<
            \\/ShadingType 2
            \\/ColorSpace /DeviceRGB
            \\/Coords [{d:.2} {d:.2} {d:.2} {d:.2}]
            \\/Function {d} 0 R
            \\/Extend [{s} {s}]
            \\>>
        , .{
            self.x0,
            pdf_y0,
            self.x1,
            pdf_y1,
            func_ref,
            if (self.extend_before) "true" else "false",
            if (self.extend_after) "true" else "false",
        });
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

        try writer.print(
            \\<<
            \\/ShadingType 3
            \\/ColorSpace /DeviceRGB
            \\/Coords [{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}]
            \\/Function {d} 0 R
            \\/Extend [{s} {s}]
            \\>>
        , .{
            self.x0,
            pdf_y0,
            self.r0,
            self.x1,
            pdf_y1,
            self.r1,
            func_ref,
            if (self.extend_before) "true" else "false",
            if (self.extend_after) "true" else "false",
        });
    }
};

/// Write a PDF function for gradient color interpolation.
/// For 2 stops: Type 2 exponential interpolation function.
/// For 3+ stops: Type 3 stitching function.
pub fn writeFunctionDict(stops: []const ColorStop, writer: anytype) !void {
    if (stops.len < 2) return error.InvalidGradient;

    if (stops.len == 2) {
        // Simple 2-color: Type 2 exponential interpolation
        const c0 = stops[0].color.toRgb();
        const c1 = stops[1].color.toRgb();
        try writer.print(
            \\<<
            \\/FunctionType 2
            \\/Domain [0 1]
            \\/C0 [{d:.3} {d:.3} {d:.3}]
            \\/C1 [{d:.3} {d:.3} {d:.3}]
            \\/N 1
            \\>>
        , .{ c0.r, c0.g, c0.b, c1.r, c1.g, c1.b });
    } else {
        // Multi-color: Type 3 stitching function
        // Each pair of adjacent stops needs a Type 2 function
        try writer.writeAll("<<\n/FunctionType 3\n/Domain [0 1]\n");

        // Functions array (inline Type 2 functions)
        try writer.writeAll("/Functions [\n");
        for (0..stops.len - 1) |i| {
            const c0 = stops[i].color.toRgb();
            const c1 = stops[i + 1].color.toRgb();
            try writer.print(
                \\<< /FunctionType 2 /Domain [0 1] /C0 [{d:.3} {d:.3} {d:.3}] /C1 [{d:.3} {d:.3} {d:.3}] /N 1 >>
                \\
            , .{ c0.r, c0.g, c0.b, c1.r, c1.g, c1.b });
        }
        try writer.writeAll("]\n");

        // Bounds array (offsets between stops, excluding first and last)
        try writer.writeAll("/Bounds [");
        for (1..stops.len - 1) |i| {
            if (i > 1) try writer.writeAll(" ");
            try writer.print("{d:.3}", .{stops[i].offset});
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
    var fbs = std.io.fixedBufferStream(&buf);
    try writeFunctionDict(&stops, fbs.writer());

    const output = fbs.getWritten();
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
    var fbs = std.io.fixedBufferStream(&buf);
    try writeFunctionDict(&stops, fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "/FunctionType 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/Bounds [0.500]") != null);
}
