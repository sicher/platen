//! Path API for programmatic path building.
//!
//! Provides a builder pattern for constructing paths with
//! moveTo, lineTo, curveTo, quadTo, and closePath operations.

const std = @import("std");
const layout = @import("layout.zig");

pub const Point = layout.Point;

/// Path command types
pub const Command = union(enum) {
    move_to: Point,
    line_to: Point,
    curve_to: CubicBezier,
    quad_to: QuadBezier,
    close,
};

pub const CubicBezier = struct {
    cp1: Point, // First control point
    cp2: Point, // Second control point
    end: Point, // End point
};

pub const QuadBezier = struct {
    cp: Point, // Control point
    end: Point, // End point
};

/// Path builder for constructing vector paths.
pub const Path = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(Command) = .empty,
    current: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Path) void {
        self.commands.deinit(self.allocator);
    }

    /// Move to a new position without drawing.
    pub fn moveTo(self: *Path, p: Point) !void {
        try self.commands.append(self.allocator, .{ .move_to = p });
        self.current = p;
        self.start = p;
    }

    /// Draw a line from current position to the given point.
    pub fn lineTo(self: *Path, p: Point) !void {
        try self.commands.append(self.allocator, .{ .line_to = p });
        self.current = p;
    }

    /// Draw a cubic Bezier curve.
    /// cp1 and cp2 are control points, end is the end point.
    pub fn curveTo(self: *Path, cp1: Point, cp2: Point, end: Point) !void {
        try self.commands.append(self.allocator, .{ .curve_to = .{
            .cp1 = cp1,
            .cp2 = cp2,
            .end = end,
        } });
        self.current = end;
    }

    /// Draw a quadratic Bezier curve.
    /// cp is the control point, end is the end point.
    pub fn quadTo(self: *Path, cp: Point, end: Point) !void {
        try self.commands.append(self.allocator, .{ .quad_to = .{
            .cp = cp,
            .end = end,
        } });
        self.current = end;
    }

    /// Close the current subpath by drawing a line to the start.
    pub fn closePath(self: *Path) !void {
        try self.commands.append(self.allocator, .close);
        self.current = self.start;
    }

    /// Render path commands to PDF content stream.
    /// Converts from top-left origin to PDF bottom-left origin.
    pub fn toPdfContent(self: *const Path, page_height: f64, writer: anytype) !void {
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .move_to => |p| {
                    const pdf_y = page_height - p.y;
                    try writer.print("{d:.2} {d:.2} m\n", .{ p.x, pdf_y });
                },
                .line_to => |p| {
                    const pdf_y = page_height - p.y;
                    try writer.print("{d:.2} {d:.2} l\n", .{ p.x, pdf_y });
                },
                .curve_to => |c| {
                    // Convert all Y coordinates
                    const pdf_y1 = page_height - c.cp1.y;
                    const pdf_y2 = page_height - c.cp2.y;
                    const pdf_y = page_height - c.end.y;
                    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                        c.cp1.x, pdf_y1, c.cp2.x, pdf_y2, c.end.x, pdf_y,
                    });
                },
                .quad_to => |q| {
                    // Convert quadratic to cubic Bezier
                    // Cubic control points: CP1 = P0 + 2/3*(P1-P0), CP2 = P2 + 2/3*(P1-P2)
                    // We need current point for this conversion
                    // For now, approximate by using the quad control point for both
                    // TODO: proper conversion requires tracking current point during render
                    const pdf_y1 = page_height - q.cp.y;
                    const pdf_y = page_height - q.end.y;
                    // Simple approximation: use control point for both cubic control points
                    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                        q.cp.x, pdf_y1, q.cp.x, pdf_y1, q.end.x, pdf_y,
                    });
                },
                .close => {
                    try writer.print("h\n", .{});
                },
            }
        }
    }

    /// Returns true if the path has no commands.
    pub fn isEmpty(self: *const Path) bool {
        return self.commands.items.len == 0;
    }
};

test "path basic operations" {
    const allocator = std.testing.allocator;
    var p = Path.init(allocator);
    defer p.deinit();

    try p.moveTo(.{ .x = 100, .y = 100 });
    try p.lineTo(.{ .x = 200, .y = 100 });
    try p.lineTo(.{ .x = 200, .y = 200 });
    try p.closePath();

    try std.testing.expectEqual(@as(usize, 4), p.commands.items.len);
    try std.testing.expectEqual(Command{ .move_to = .{ .x = 100, .y = 100 } }, p.commands.items[0]);
    try std.testing.expectEqual(Command{ .line_to = .{ .x = 200, .y = 100 } }, p.commands.items[1]);
}

test "path pdf output" {
    const allocator = std.testing.allocator;
    var p = Path.init(allocator);
    defer p.deinit();

    try p.moveTo(.{ .x = 100, .y = 100 });
    try p.lineTo(.{ .x = 200, .y = 100 });
    try p.closePath();

    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try p.toPdfContent(842, &fbs); // A4 height

    const expected = "100.00 742.00 m\n200.00 742.00 l\nh\n";
    try std.testing.expectEqualStrings(expected, fbs.buffered());
}
