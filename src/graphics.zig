//! Graphics helpers for PDF path generation and drawing state.
//!
//! This module provides utilities for generating PDF path content and managing
//! graphics state for drawing operations. It separates geometric path generation
//! from document state management.

const std = @import("std");
const layout = @import("layout.zig");
const color = @import("color.zig");

pub const DrawStyle = layout.DrawStyle;
pub const LineCap = layout.LineCap;
pub const LineJoin = layout.LineJoin;
pub const DashPattern = layout.DashPattern;
pub const Color = color.Color;
pub const Point = layout.Point;

/// Kappa constant for approximating circles/arcs with cubic Bezier curves.
/// This is (4/3)*tan(pi/8) ≈ 0.5522847498
pub const KAPPA: f64 = 0.5522847498307936;

/// Graphics state for drawing operations.
/// Aggregates all drawing parameters needed to generate PDF graphics state operators.
pub const GraphicsState = struct {
    line_width: f64 = 0.567,
    dash_pattern: DashPattern = .{},
    line_cap: LineCap = .square,
    line_join: LineJoin = .miter,
    stroke_color: Color = Color.black,
    fill_color: Color = Color.black,
};

/// Get PDF path operator for the given draw style.
pub fn getPathOperator(style: DrawStyle) []const u8 {
    return switch (style) {
        .stroke => "S\n",
        .fill => "f\n",
        .fill_stroke => "B\n",
    };
}

/// Write graphics state operators to buffer.
/// Returns number of bytes written.
pub fn writeGraphicsState(state: GraphicsState, buf: []u8, style: DrawStyle) usize {
    var len: usize = 0;

    // Line width
    len += (std.fmt.bufPrint(buf[len..], "{d:.3} w\n", .{state.line_width}) catch unreachable).len;

    // Dash pattern
    if (state.dash_pattern.dash > 0) {
        len += (std.fmt.bufPrint(buf[len..], "[{d:.3} {d:.3}] {d:.3} d\n", .{
            state.dash_pattern.dash,
            state.dash_pattern.gap,
            state.dash_pattern.phase,
        }) catch unreachable).len;
    } else {
        len += (std.fmt.bufPrint(buf[len..], "[] 0 d\n", .{}) catch unreachable).len;
    }

    // Line cap and join
    len += (std.fmt.bufPrint(buf[len..], "{d} J {d} j\n", .{
        @intFromEnum(state.line_cap),
        @intFromEnum(state.line_join),
    }) catch unreachable).len;

    // Stroke color (for stroke and fill_stroke)
    if (style == .stroke or style == .fill_stroke) {
        var color_buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&color_buf);
        state.stroke_color.writeStroke(fbs.writer()) catch unreachable;
        const color_str = fbs.getWritten();
        @memcpy(buf[len .. len + color_str.len], color_str);
        len += color_str.len;
    }

    // Fill color (for fill and fill_stroke)
    if (style == .fill or style == .fill_stroke) {
        var color_buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&color_buf);
        state.fill_color.writeFill(fbs.writer()) catch unreachable;
        const color_str = fbs.getWritten();
        @memcpy(buf[len .. len + color_str.len], color_str);
        len += color_str.len;
    }

    return len;
}

// ============================================================================
// Path Generation Helpers
// ============================================================================

/// Generate PDF path operators for an ellipse using 4 cubic Bezier curves.
/// cx, cy are the center coordinates (in PDF bottom-left coordinate system).
/// rx, ry are the horizontal and vertical radii.
/// Returns number of bytes written to buf.
pub fn writeEllipsePath(buf: []u8, cx: f64, cy: f64, rx: f64, ry: f64) usize {
    const kx = rx * KAPPA;
    const ky = ry * KAPPA;
    var len: usize = 0;

    // Start at right-most point (cx + rx, cy)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ cx + rx, cy }) catch unreachable).len;

    // Top-right quadrant: from (cx+rx, cy) to (cx, cy+ry)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        cx + rx, cy + ky,
        cx + kx, cy + ry,
        cx,      cy + ry,
    }) catch unreachable).len;

    // Top-left quadrant: from (cx, cy+ry) to (cx-rx, cy)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        cx - kx, cy + ry,
        cx - rx, cy + ky,
        cx - rx, cy,
    }) catch unreachable).len;

    // Bottom-left quadrant: from (cx-rx, cy) to (cx, cy-ry)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        cx - rx, cy - ky,
        cx - kx, cy - ry,
        cx,      cy - ry,
    }) catch unreachable).len;

    // Bottom-right quadrant: from (cx, cy-ry) to (cx+rx, cy)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        cx + kx, cy - ry,
        cx + rx, cy - ky,
        cx + rx, cy,
    }) catch unreachable).len;

    return len;
}

/// Generate PDF path operators for a rounded rectangle.
/// x, y are the bottom-left corner (in PDF coordinate system).
/// w, h are width and height.
/// r is the corner radius.
/// Returns number of bytes written to buf.
pub fn writeRoundedRectPath(buf: []u8, x: f64, y: f64, w: f64, h: f64, r: f64) usize {
    const k = r * KAPPA;
    var len: usize = 0;

    // Start at top-left corner, after the rounded part
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ x + r, y + h }) catch unreachable).len;

    // Top edge (left to right)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + w - r, y + h }) catch unreachable).len;

    // Top-right corner (curve)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + w - r + k, y + h,
        x + w,         y + h - r + k,
        x + w,         y + h - r,
    }) catch unreachable).len;

    // Right edge (top to bottom)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + w, y + r }) catch unreachable).len;

    // Bottom-right corner (curve)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + w,         y + r - k,
        x + w - r + k, y,
        x + w - r,     y,
    }) catch unreachable).len;

    // Bottom edge (right to left)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + r, y }) catch unreachable).len;

    // Bottom-left corner (curve)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + r - k, y,
        x,         y + r - k,
        x,         y + r,
    }) catch unreachable).len;

    // Left edge (bottom to top)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x, y + h - r }) catch unreachable).len;

    // Top-left corner (curve)
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x,         y + h - r + k,
        x + r - k, y + h,
        x + r,     y + h,
    }) catch unreachable).len;

    // Close path
    len += (std.fmt.bufPrint(buf[len..], "h ", .{}) catch unreachable).len;

    return len;
}

/// Generate PDF path operators for a polygon.
/// Points are in PDF coordinate system (bottom-left origin).
/// Returns number of bytes written to buf.
pub fn writePolygonPath(buf: []u8, points: []const Point) usize {
    if (points.len < 3) return 0;

    var len: usize = 0;

    // Move to first point
    len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ points[0].x, points[0].y }) catch unreachable).len;

    // Line to remaining points
    for (points[1..]) |pt| {
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ pt.x, pt.y }) catch unreachable).len;
    }

    // Close path
    len += (std.fmt.bufPrint(buf[len..], "h ", .{}) catch unreachable).len;

    return len;
}

// ============================================================================
// Tests
// ============================================================================

test "getPathOperator" {
    const testing = std.testing;
    try testing.expectEqualStrings("S\n", getPathOperator(.stroke));
    try testing.expectEqualStrings("f\n", getPathOperator(.fill));
    try testing.expectEqualStrings("B\n", getPathOperator(.fill_stroke));
}

test "writeGraphicsState basic" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;

    const state = GraphicsState{};
    const len = writeGraphicsState(state, &buf, .stroke);

    // Should contain line width, dash, cap/join, and stroke color
    const output = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, output, "0.567 w") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[] 0 d") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2 J 0 j") != null); // square cap, miter join
}

test "writeEllipsePath" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;

    const len = writeEllipsePath(&buf, 100, 100, 50, 30);
    const output = buf[0..len];

    // Should start at right-most point
    try testing.expect(std.mem.indexOf(u8, output, "150") != null); // cx + rx
    // Should have 4 curve commands
    var count: usize = 0;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] == 'c' and (i + 1 >= output.len or output[i + 1] == '\n')) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "writeRoundedRectPath" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;

    const len = writeRoundedRectPath(&buf, 10, 10, 100, 50, 5);
    const output = buf[0..len];

    // Should close path
    try testing.expect(std.mem.indexOf(u8, output, "h ") != null);
    // Should have 4 curve commands (one per corner)
    var count: usize = 0;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] == 'c' and (i + 1 >= output.len or output[i + 1] == '\n')) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), count);
}
