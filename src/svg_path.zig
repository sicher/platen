//! SVG path geometry: walking parsed path commands (smooth-curve
//! reflection, quadratics as cubics, arcs as Beziers) into a sink, and a
//! sink that measures the path's tight bounding box.
//!
//! A sink has moveTo(x, y), lineTo(x, y), curveTo(x1, y1, x2, y2, x, y)
//! and close(); svg.zig's PdfPathSink writes PDF operators, Bounds below
//! measures.

const std = @import("std");
const PathCommand = @import("svg.zig").PathCommand;

/// Give `commands` to `sink` as moves, lines, cubic curves and closes.
pub fn walk(commands: []const PathCommand, sink: anytype) !void {
    var cur_x: f64 = 0;
    var cur_y: f64 = 0;
    var start_x: f64 = 0;
    var start_y: f64 = 0;
    var last_ctrl_x: f64 = 0;
    var last_ctrl_y: f64 = 0;
    var last_cmd_was_curve = false;

    for (commands) |cmd| {
        switch (cmd) {
            .move_to => |m| {
                try sink.moveTo(m.x, m.y);
                cur_x = m.x;
                cur_y = m.y;
                start_x = m.x;
                start_y = m.y;
                last_cmd_was_curve = false;
            },
            .line_to => |l| {
                try sink.lineTo(l.x, l.y);
                cur_x = l.x;
                cur_y = l.y;
                last_cmd_was_curve = false;
            },
            .horiz_to => |h| {
                try sink.lineTo(h.x, cur_y);
                cur_x = h.x;
                last_cmd_was_curve = false;
            },
            .vert_to => |v| {
                try sink.lineTo(cur_x, v.y);
                cur_y = v.y;
                last_cmd_was_curve = false;
            },
            .curve_to => |c| {
                try sink.curveTo(c.x1, c.y1, c.x2, c.y2, c.x, c.y);
                last_ctrl_x = c.x2;
                last_ctrl_y = c.y2;
                cur_x = c.x;
                cur_y = c.y;
                last_cmd_was_curve = true;
            },
            .smooth_curve => |s| {
                // Reflect last control point
                const x1 = if (last_cmd_was_curve) 2 * cur_x - last_ctrl_x else cur_x;
                const y1 = if (last_cmd_was_curve) 2 * cur_y - last_ctrl_y else cur_y;
                try sink.curveTo(x1, y1, s.x2, s.y2, s.x, s.y);
                last_ctrl_x = s.x2;
                last_ctrl_y = s.y2;
                cur_x = s.x;
                cur_y = s.y;
                last_cmd_was_curve = true;
            },
            .quad_to => |q| {
                // Convert quadratic to cubic bezier
                const cp1_x = cur_x + 2.0 / 3.0 * (q.x1 - cur_x);
                const cp1_y = cur_y + 2.0 / 3.0 * (q.y1 - cur_y);
                const cp2_x = q.x + 2.0 / 3.0 * (q.x1 - q.x);
                const cp2_y = q.y + 2.0 / 3.0 * (q.y1 - q.y);
                try sink.curveTo(cp1_x, cp1_y, cp2_x, cp2_y, q.x, q.y);
                last_ctrl_x = q.x1;
                last_ctrl_y = q.y1;
                cur_x = q.x;
                cur_y = q.y;
                last_cmd_was_curve = true;
            },
            .smooth_quad => |t| {
                // Reflect last quadratic control point
                const x1 = if (last_cmd_was_curve) 2 * cur_x - last_ctrl_x else cur_x;
                const y1 = if (last_cmd_was_curve) 2 * cur_y - last_ctrl_y else cur_y;
                // Convert quadratic to cubic
                const cp1_x = cur_x + 2.0 / 3.0 * (x1 - cur_x);
                const cp1_y = cur_y + 2.0 / 3.0 * (y1 - cur_y);
                const cp2_x = t.x + 2.0 / 3.0 * (x1 - t.x);
                const cp2_y = t.y + 2.0 / 3.0 * (y1 - t.y);
                try sink.curveTo(cp1_x, cp1_y, cp2_x, cp2_y, t.x, t.y);
                last_ctrl_x = x1;
                last_ctrl_y = y1;
                cur_x = t.x;
                cur_y = t.y;
                last_cmd_was_curve = true;
            },
            .arc_to => |a| {
                try arcTo(sink, cur_x, cur_y, a.rx, a.ry, a.angle, a.large_arc, a.sweep, a.x, a.y);
                cur_x = a.x;
                cur_y = a.y;
                last_cmd_was_curve = false;
            },
            .close_path => {
                try sink.close();
                cur_x = start_x;
                cur_y = start_y;
                last_cmd_was_curve = false;
            },
        }
    }
}

/// Convert an SVG arc from (x1, y1) into cubic Beziers (90-degree segments
/// at most), given to `sink`. Out-of-range radii are scaled up and a zero
/// radius is a line, as SVG specifies.
fn arcTo(
    sink: anytype,
    x1: f64,
    y1: f64,
    rx_in: f64,
    ry_in: f64,
    angle: f64,
    large_arc: bool,
    sweep: bool,
    x2: f64,
    y2: f64,
) !void {
    // Handle degenerate cases
    if (x1 == x2 and y1 == y2) return;

    var rx = @abs(rx_in);
    var ry = @abs(ry_in);

    if (rx == 0 or ry == 0) {
        // Treat as line
        try sink.lineTo(x2, y2);
        return;
    }

    const phi = angle * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // Step 1: Compute (x1', y1')
    const dx = (x1 - x2) / 2;
    const dy = (y1 - y2) / 2;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // Step 2: Compute (cx', cy')
    // Scale radii if necessary
    var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        const sqrt_lambda = @sqrt(lambda);
        rx *= sqrt_lambda;
        ry *= sqrt_lambda;
        lambda = 1;
    }

    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const x1p2 = x1p * x1p;
    const y1p2 = y1p * y1p;

    var sq = (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2) / (rx2 * y1p2 + ry2 * x1p2);
    if (sq < 0) sq = 0;
    var coef = @sqrt(sq);
    if (large_arc == sweep) coef = -coef;

    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;

    // Step 3: Compute (cx, cy) from (cx', cy')
    const cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2;
    const cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2;

    // Step 4: Compute angles
    const theta1 = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = vectorAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);

    if (!sweep and dtheta > 0) {
        dtheta -= 2 * std.math.pi;
    } else if (sweep and dtheta < 0) {
        dtheta += 2 * std.math.pi;
    }

    // Step 5: Draw arc as bezier curves (split into 90-degree segments)
    const n_segs = @as(usize, @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 2.0))));
    if (n_segs == 0) return;

    const delta = dtheta / @as(f64, @floatFromInt(n_segs));
    const t = 4.0 / 3.0 * @tan(delta / 4.0);

    var theta = theta1;
    for (0..n_segs) |_| {
        const cos_t1 = @cos(theta);
        const sin_t1 = @sin(theta);
        const cos_t2 = @cos(theta + delta);
        const sin_t2 = @sin(theta + delta);

        // Control point 1
        const p1x = cx + (rx * cos_t1 - t * rx * sin_t1) * cos_phi - (ry * sin_t1 + t * ry * cos_t1) * sin_phi;
        const p1y = cy + (rx * cos_t1 - t * rx * sin_t1) * sin_phi + (ry * sin_t1 + t * ry * cos_t1) * cos_phi;

        // Control point 2
        const p2x = cx + (rx * cos_t2 + t * rx * sin_t2) * cos_phi - (ry * sin_t2 - t * ry * cos_t2) * sin_phi;
        const p2y = cy + (rx * cos_t2 + t * rx * sin_t2) * sin_phi + (ry * sin_t2 - t * ry * cos_t2) * cos_phi;

        // End point
        const ex = cx + rx * cos_t2 * cos_phi - ry * sin_t2 * sin_phi;
        const ey = cy + rx * cos_t2 * sin_phi + ry * sin_t2 * cos_phi;

        try sink.curveTo(p1x, p1y, p2x, p2y, ex, ey);

        theta += delta;
    }
}

fn vectorAngle(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
    const n = @sqrt(ux * ux + uy * uy) * @sqrt(vx * vx + vy * vy);
    if (n == 0) return 0;

    var c = (ux * vx + uy * vy) / n;
    c = @max(-1, @min(1, c)); // Clamp to [-1, 1]

    const angle = std.math.acos(c);
    if (ux * vy - uy * vx < 0) {
        return -angle;
    }
    return angle;
}

/// An axis-aligned box.
pub const Box = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// A sink that measures the tight bounding box of what it is given: the
/// points on the path, curves by their extrema rather than their control
/// points (the SVG bounding box is geometric).
pub const Bounds = struct {
    min_x: f64 = std.math.inf(f64),
    min_y: f64 = std.math.inf(f64),
    max_x: f64 = -std.math.inf(f64),
    max_y: f64 = -std.math.inf(f64),
    cur_x: f64 = 0,
    cur_y: f64 = 0,
    start_x: f64 = 0,
    start_y: f64 = 0,

    pub fn include(self: *Bounds, x: f64, y: f64) void {
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, x);
        self.max_y = @max(self.max_y, y);
    }

    pub fn moveTo(self: *Bounds, x: f64, y: f64) !void {
        self.include(x, y);
        self.cur_x = x;
        self.cur_y = y;
        self.start_x = x;
        self.start_y = y;
    }

    pub fn lineTo(self: *Bounds, x: f64, y: f64) !void {
        self.include(x, y);
        self.cur_x = x;
        self.cur_y = y;
    }

    pub fn curveTo(self: *Bounds, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) !void {
        self.include(x, y);
        var ts: [4]f64 = undefined;
        var n = cubicExtrema(self.cur_x, x1, x2, x, ts[0..2]);
        n += cubicExtrema(self.cur_y, y1, y2, y, ts[n..][0..2]);
        for (ts[0..n]) |t| {
            self.include(cubicAt(self.cur_x, x1, x2, x, t), cubicAt(self.cur_y, y1, y2, y, t));
        }
        self.cur_x = x;
        self.cur_y = y;
    }

    pub fn close(self: *Bounds) !void {
        self.cur_x = self.start_x;
        self.cur_y = self.start_y;
    }

    /// The box, or null when nothing was given.
    pub fn box(self: Bounds) ?Box {
        if (self.min_x > self.max_x) return null;
        return .{ .x = self.min_x, .y = self.min_y, .width = self.max_x - self.min_x, .height = self.max_y - self.min_y };
    }
};

fn cubicAt(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1 - t;
    return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
}

/// The parameters in (0, 1) where one coordinate of a cubic Bezier has a
/// zero derivative; returns how many were written to `out`.
fn cubicExtrema(p0: f64, p1: f64, p2: f64, p3: f64, out: *[2]f64) usize {
    // B'(t)/3 = a t^2 + b t + c
    const a = -p0 + 3 * p1 - 3 * p2 + p3;
    const b = 2 * (p0 - 2 * p1 + p2);
    const c = p1 - p0;
    var n: usize = 0;
    const eps = 1e-12;
    if (@abs(a) < eps) {
        if (@abs(b) >= eps) {
            const t = -c / b;
            if (t > 0 and t < 1) {
                out[n] = t;
                n += 1;
            }
        }
        return n;
    }
    const disc = b * b - 4 * a * c;
    if (disc < 0) return 0;
    const sq = @sqrt(disc);
    for ([_]f64{ (-b + sq) / (2 * a), (-b - sq) / (2 * a) }) |t| {
        if (t > 0 and t < 1) {
            out[n] = t;
            n += 1;
        }
    }
    return n;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn pathBox(d: []const u8) !?Box {
    var buf: [256]u8 = undefined;
    const doc = try std.fmt.bufPrint(&buf, "<svg width=\"1\" height=\"1\"><path d=\"{s}\"/></svg>", .{d});
    const s = try @import("svg.zig").Svg.fromMemory(testing.allocator, doc);
    defer s.deinit();
    var bounds = Bounds{};
    try walk(s.elements.items[0].path.commands.items, &bounds);
    return bounds.box();
}

fn expectBox(expected: Box, actual: ?Box) !void {
    const b = actual orelse return error.TestExpectedBox;
    inline for (.{ "x", "y", "width", "height" }) |f| {
        try testing.expectApproxEqAbs(@field(expected, f), @field(b, f), 1e-9);
    }
}

test "Bounds: lines, and curves by their extrema, not control points" {
    try expectBox(.{ .x = 1, .y = 2, .width = 9, .height = 18 }, try pathBox("M1 2 L10 2 L10 20 Z"));
    try expectBox(.{ .x = 1, .y = 2, .width = 4, .height = 3 }, try pathBox("M1 2 h4 v3"));
    // Cubic peak: B(0.5) = 3/4 of the control height.
    try expectBox(.{ .x = 0, .y = 0, .width = 10, .height = 7.5 }, try pathBox("M0 0 C0 10 10 10 10 0"));
    // Quadratic peak: half the control height.
    try expectBox(.{ .x = 0, .y = 0, .width = 10, .height = 5 }, try pathBox("M0 0 Q5 10 10 0"));
    // S-curve: both extrema inside, neither at a control point.
    const s_box = (try pathBox("M0 0 C10 10 -10 10 0 20")).?;
    try testing.expectApproxEqAbs(@as(f64, 20), s_box.height, 1e-9);
    try testing.expect(s_box.width > 0 and s_box.width < 20);
    // Half circle of radius 5: its bounding box is 10 by 5 (the arc's
    // Bezier approximation reaches the radius exactly at its segment ends).
    try expectBox(.{ .x = 0, .y = -5, .width = 10, .height = 5 }, try pathBox("M0 0 A5 5 0 0 1 10 0"));
    try testing.expect(try pathBox("") == null);
}
