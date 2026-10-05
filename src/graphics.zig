//! Graphics helpers for PDF path generation and drawing state.
//!
//! This module provides utilities for generating PDF path content and managing
//! graphics state for drawing operations. It separates geometric path generation
//! from document state management.

const std = @import("std");
const layout = @import("layout.zig");
const color = @import("color.zig");
const format = @import("format.zig");

pub const LineCap = layout.LineCap;
pub const LineJoin = layout.LineJoin;
pub const DashPattern = layout.DashPattern;
pub const Color = color.Color;
pub const Point = layout.Point;

// Explicit style types
pub const StrokeStyle = layout.StrokeStyle;
pub const FillStyle = layout.FillStyle;
pub const ShapeStyle = layout.ShapeStyle;
pub const OpacityState = layout.OpacityState;

/// Kappa constant for approximating circles/arcs with cubic Bezier curves.
/// This is (4/3)*tan(pi/8) ≈ 0.5522847498
pub const KAPPA: f64 = 0.5522847498307936;

/// Extract opacity state from a ShapeStyle.
/// Returns null if fully opaque (no ExtGState needed).
pub fn getShapeOpacity(style: ShapeStyle) ?OpacityState {
    // Get stroke opacity (default 1.0 if no stroke)
    const stroke_opacity: f64 = if (style.stroke) |s| s.opacity else 1.0;
    // Get fill opacity (default 1.0 if no fill)
    const fill_opacity: f64 = if (style.fill) |f| f.opacity else 1.0;

    const state = OpacityState{ .fill_opacity = fill_opacity, .stroke_opacity = stroke_opacity };
    if (state.isOpaque()) return null;
    return state;
}

/// Write ExtGState reference operator (e.g., "/GS1 gs\n").
/// Index is 0-based but resource names are 1-indexed (index 0 → "GS1").
/// Returns number of bytes written.
pub fn writeExtGStateRef(buf: []u8, index: usize) usize {
    @memcpy(buf[0..3], "/GS");
    // Resource names are 1-indexed: index 0 → "GS1", index 1 → "GS2", etc.
    const idx_str = format.writeInt(buf[3..], @as(u32, @intCast(index + 1)));
    const total = 3 + idx_str.len;
    @memcpy(buf[total..][0..4], " gs\n");
    return total + 4;
}

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
        const width_str = format.writeF64_3(buf[len..], s.width);
        len += width_str.len;
        @memcpy(buf[len..][0..3], " w\n");
        len += 3;

        // Dash pattern
        if (s.dash.dash > 0) {
            buf[len] = '[';
            len += 1;
            const dash_str = format.writeF64_3(buf[len..], s.dash.dash);
            len += dash_str.len;
            buf[len] = ' ';
            len += 1;
            const gap_str = format.writeF64_3(buf[len..], s.dash.gap);
            len += gap_str.len;
            @memcpy(buf[len..][0..2], "] ");
            len += 2;
            const phase_str = format.writeF64_3(buf[len..], s.dash.phase);
            len += phase_str.len;
            @memcpy(buf[len..][0..3], " d\n");
            len += 3;
        } else {
            @memcpy(buf[len..][0..7], "[] 0 d\n");
            len += 7;
        }

        // Line cap and join
        buf[len] = @intCast(@backingInt(s.cap) + '0');
        len += 1;
        @memcpy(buf[len..][0..3], " J ");
        len += 3;
        buf[len] = @intCast(@backingInt(s.join) + '0');
        len += 1;
        @memcpy(buf[len..][0..3], " j\n");
        len += 3;

        // Stroke color
        var color_buf: [64]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&color_buf);
        s.color.writeStroke(&fbs) catch unreachable;
        const color_str = fbs.buffered();
        @memcpy(buf[len .. len + color_str.len], color_str);
        len += color_str.len;
    }

    // Write fill color if filling
    if (style.fill) |f| {
        var color_buf: [64]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&color_buf);
        f.color.writeFill(&fbs) catch unreachable;
        const color_str = fbs.buffered();
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
    len += format.writeCoord2Suffix(buf[len..], cx + rx, cy, " m\n");

    // Top-right quadrant: from (cx+rx, cy) to (cx, cy+ry)
    len += format.writeCubic(buf[len..], cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);

    // Top-left quadrant: from (cx, cy+ry) to (cx-rx, cy)
    len += format.writeCubic(buf[len..], cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);

    // Bottom-left quadrant: from (cx-rx, cy) to (cx, cy-ry)
    len += format.writeCubic(buf[len..], cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);

    // Bottom-right quadrant: from (cx, cy-ry) to (cx+rx, cy)
    len += format.writeCubic(buf[len..], cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);

    // Close path
    @memcpy(buf[len..][0..2], "h\n");
    len += 2;

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
    len += format.writeCoord2Suffix(buf[len..], x + r, y + h, " m\n");

    // Top edge (left to right)
    len += format.writeCoord2Suffix(buf[len..], x + w - r, y + h, " l\n");

    // Top-right corner (curve)
    len += format.writeCubic(buf[len..], x + w - r + k, y + h, x + w, y + h - r + k, x + w, y + h - r);

    // Right edge (top to bottom)
    len += format.writeCoord2Suffix(buf[len..], x + w, y + r, " l\n");

    // Bottom-right corner (curve)
    len += format.writeCubic(buf[len..], x + w, y + r - k, x + w - r + k, y, x + w - r, y);

    // Bottom edge (right to left)
    len += format.writeCoord2Suffix(buf[len..], x + r, y, " l\n");

    // Bottom-left corner (curve)
    len += format.writeCubic(buf[len..], x + r - k, y, x, y + r - k, x, y + r);

    // Left edge (bottom to top)
    len += format.writeCoord2Suffix(buf[len..], x, y + h - r, " l\n");

    // Top-left corner (curve)
    len += format.writeCubic(buf[len..], x, y + h - r + k, x + r - k, y + h, x + r, y + h);

    // Close path
    @memcpy(buf[len..][0..2], "h ");
    len += 2;

    return len;
}

/// Generate PDF path operators for a polygon.
/// Points are in PDF coordinate system (bottom-left origin).
/// Returns number of bytes written to buf.
pub fn writePolygonPath(buf: []u8, points: []const Point) usize {
    if (points.len < 3) return 0;

    var len: usize = 0;

    // Move to first point
    len += format.writeCoord2Suffix(buf[len..], points[0].x, points[0].y, " m\n");

    // Line to remaining points
    for (points[1..]) |pt| {
        len += format.writeCoord2Suffix(buf[len..], pt.x, pt.y, " l\n");
    }

    // Close path
    @memcpy(buf[len..][0..2], "h ");
    len += 2;

    return len;
}

// ============================================================================
// Shape Command Helpers
// ============================================================================

/// Begin a shape command: save graphics state and apply style.
/// Returns the number of bytes written.
pub fn beginShapeCommand(buf: []u8, style: ShapeStyle) usize {
    var len: usize = 0;
    @memcpy(buf[len..][0..2], "q\n");
    len += 2;
    len += writeShapeGraphicsState(style, buf[len..]);
    return len;
}

/// Finish a shape command: add path operator and restore graphics state.
/// Returns the number of bytes written.
pub fn finishShapeCommand(buf: []u8, style: ShapeStyle) usize {
    var len: usize = 0;
    const op = getShapePathOperator(style);
    @memcpy(buf[len..][0..op.len], op);
    len += op.len;
    @memcpy(buf[len..][0..2], "Q\n");
    len += 2;
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
