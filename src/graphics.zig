//! Graphics helpers for PDF path generation and drawing state.
//!
//! This module provides utilities for generating PDF path content and managing
//! graphics state for drawing operations. It separates geometric path generation
//! from document state management.

const std = @import("std");
const layout = @import("layout.zig");
const color = @import("color.zig");

pub const LineCap = layout.LineCap;
pub const LineJoin = layout.LineJoin;
pub const DashPattern = layout.DashPattern;
pub const Color = color.Color;
pub const Point = layout.Point;

// Explicit style types
pub const StrokeStyle = layout.StrokeStyle;
pub const FillStyle = layout.FillStyle;
pub const ShapeStyle = layout.ShapeStyle;

/// Kappa constant for approximating circles/arcs with cubic Bezier curves.
/// This is (4/3)*tan(pi/8) ≈ 0.5522847498
pub const KAPPA: f64 = 0.5522847498307936;

/// Get PDF path operator for a ShapeStyle.
/// Returns the appropriate operator based on stroke/fill settings.
pub fn getShapePathOperator(style: ShapeStyle) []const u8 {
    const has_stroke = style.stroke != null;
    const has_fill = style.fill != null;

    if (has_stroke and has_fill) {
        return "B\n"; // Fill and stroke
    } else if (has_fill) {
        return "f\n"; // Fill only
    } else {
        return "S\n"; // Stroke only (default if neither specified)
    }
}

/// Write graphics state operators for a ShapeStyle.
/// Returns number of bytes written.
pub fn writeShapeGraphicsState(style: ShapeStyle, buf: []u8) usize {
    var len: usize = 0;

    // Get stroke settings (use defaults if stroking without explicit style)
    const stroke = style.stroke orelse if (style.fill == null) StrokeStyle{} else null;

    // Write stroke settings if stroking
    if (stroke) |s| {
        // Line width
        len += (std.fmt.bufPrint(buf[len..], "{d:.3} w\n", .{s.width}) catch unreachable).len;

        // Dash pattern
        if (s.dash.dash > 0) {
            len += (std.fmt.bufPrint(buf[len..], "[{d:.3} {d:.3}] {d:.3} d\n", .{
                s.dash.dash,
                s.dash.gap,
                s.dash.phase,
            }) catch unreachable).len;
        } else {
            len += (std.fmt.bufPrint(buf[len..], "[] 0 d\n", .{}) catch unreachable).len;
        }

        // Line cap and join
        len += (std.fmt.bufPrint(buf[len..], "{d} J {d} j\n", .{
            @intFromEnum(s.cap),
            @intFromEnum(s.join),
        }) catch unreachable).len;

        // Stroke color
        var color_buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&color_buf);
        s.color.writeStroke(fbs.writer()) catch unreachable;
        const color_str = fbs.getWritten();
        @memcpy(buf[len .. len + color_str.len], color_str);
        len += color_str.len;
    }

    // Write fill color if filling
    if (style.fill) |f| {
        var color_buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&color_buf);
        f.color.writeFill(fbs.writer()) catch unreachable;
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

    // Close path
    len += (std.fmt.bufPrint(buf[len..], "h\n", .{}) catch unreachable).len;

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

test "getShapePathOperator" {
    const testing = std.testing;
    try testing.expectEqualStrings("S\n", getShapePathOperator(.{ .stroke = .{} }));
    try testing.expectEqualStrings("f\n", getShapePathOperator(.{ .fill = .{} }));
    try testing.expectEqualStrings("B\n", getShapePathOperator(.{ .stroke = .{}, .fill = .{} }));
    // Default (neither set) should stroke
    try testing.expectEqualStrings("S\n", getShapePathOperator(.{}));
}

test "writeShapeGraphicsState stroke" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;

    const len = writeShapeGraphicsState(.{ .stroke = .{} }, &buf);

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
    // Should close path
    try testing.expect(std.mem.indexOf(u8, output, "h\n") != null);
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
