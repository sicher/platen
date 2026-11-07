//! SVG gradient paint servers: `<linearGradient>`, `<radialGradient>` and
//! their `<stop>`s, and the `url(#id)` paint that references them.
//!
//! Parsing keeps every gradient attribute optional (null = not given), so a
//! gradient that inherits from another through `href` can tell what it set
//! itself; defaults are applied when the gradient is resolved for rendering.
//! svg.zig owns the element loop; this file holds the types and the
//! attribute-level parsers.

const std = @import("std");
const svg = @import("svg.zig");
const Color = svg.Color;
const Transform = svg.Transform;

/// A gradient coordinate: a number, or a percentage (`50%`). With
/// objectBoundingBox units a number is a fraction of the box and a
/// percentage is that fraction times 100; with userSpaceOnUse a
/// percentage is of the viewport.
pub const Length = struct {
    value: f64,
    percent: bool = false,

    /// The coordinate as a fraction (percentages / 100) or a plain number.
    pub fn number(self: Length) f64 {
        return if (self.percent) self.value / 100.0 else self.value;
    }
};

pub const Units = enum { object_bounding_box, user_space_on_use };

pub const Spread = enum { pad, reflect, repeat };

pub const Kind = enum { linear, radial };

/// One `<stop>`: offset in [0, 1] as written (clamped, not yet made
/// monotonic - that needs the whole list), color and opacity.
pub const Stop = struct {
    offset: f64 = 0,
    color: Color = .{},
    /// stop-opacity times the stop-color's own alpha, in [0, 1].
    opacity: f64 = 1,
};

/// A parsed gradient element. Attributes it did not set are null.
pub const Gradient = struct {
    kind: Kind,
    // Linear
    x1: ?Length = null,
    y1: ?Length = null,
    x2: ?Length = null,
    y2: ?Length = null,
    // Radial
    cx: ?Length = null,
    cy: ?Length = null,
    r: ?Length = null,
    fx: ?Length = null,
    fy: ?Length = null,
    // Both
    units: ?Units = null,
    transform: ?Transform = null,
    spread: ?Spread = null,
    /// `href` / `xlink:href` target id (without `#`), owned.
    href: ?[]u8 = null,
    stops: std.ArrayListUnmanaged(Stop) = .empty,

    pub fn deinit(self: *Gradient, allocator: std.mem.Allocator) void {
        if (self.href) |h| allocator.free(h);
        self.stops.deinit(allocator);
    }
};

/// Parse a gradient coordinate: `0.5`, `50%`, `10px`. Unit suffixes other
/// than `%` are dropped, as svg.zig does for other lengths. Null when the
/// number does not parse or is not finite: the attribute is then unset.
pub fn parseLength(str: []const u8) ?Length {
    const s = std.mem.trim(u8, str, " \t\n\r");
    if (s.len > 0 and s[s.len - 1] == '%') {
        const v = parseNumber(s[0 .. s.len - 1]) orelse return null;
        return .{ .value = v, .percent = true };
    }
    var end = s.len;
    while (end > 0 and std.ascii.isAlphabetic(s[end - 1])) end -= 1;
    return .{ .value = parseNumber(s[0..end]) orelse return null };
}

/// A `<stop>` offset: number or percentage, clamped to [0, 1]. An offset
/// that does not parse is 0, the attribute's initial value.
pub fn parseOffset(str: []const u8) f64 {
    const len = parseLength(str) orelse return 0;
    return std.math.clamp(len.number(), 0, 1);
}

/// `stop-opacity` / an opacity value: number or percentage, clamped to
/// [0, 1]; null when it does not parse (the attribute is then ignored).
pub fn parseOpacity(str: []const u8) ?f64 {
    const len = parseLength(str) orelse return null;
    return std.math.clamp(len.number(), 0, 1);
}

pub fn parseUnits(str: []const u8) ?Units {
    const s = std.mem.trim(u8, str, " \t\n\r");
    if (std.mem.eql(u8, s, "objectBoundingBox")) return .object_bounding_box;
    if (std.mem.eql(u8, s, "userSpaceOnUse")) return .user_space_on_use;
    return null;
}

pub fn parseSpread(str: []const u8) ?Spread {
    const s = std.mem.trim(u8, str, " \t\n\r");
    if (std.mem.eql(u8, s, "pad")) return .pad;
    if (std.mem.eql(u8, s, "reflect")) return .reflect;
    if (std.mem.eql(u8, s, "repeat")) return .repeat;
    return null;
}

/// The id in a local IRI `#id`; null for anything else (external
/// references are not followed).
pub fn parseHref(str: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, str, " \t\n\r");
    if (s.len < 2 or s[0] != '#') return null;
    return s[1..];
}

/// A paint `url(#id)` with what follows it (the fallback, unparsed and
/// trimmed; empty when there is none).
pub const UrlPaint = struct {
    id: []const u8,
    fallback: []const u8,
};

/// Parse `url(#id)`, `url('#id')`, `url("#id") red`. Null when the value
/// is not a url() or the url is not a local `#id`.
pub fn parseUrlPaint(str: []const u8) ?UrlPaint {
    const s = std.mem.trim(u8, str, " \t\n\r");
    if (!std.ascii.startsWithIgnoreCase(s, "url(")) return null;
    const close = std.mem.indexOfScalarPos(u8, s, 4, ')') orelse return null;
    var inner = std.mem.trim(u8, s[4..close], " \t\n\r");
    if (inner.len >= 2 and (inner[0] == '\'' or inner[0] == '"') and inner[inner.len - 1] == inner[0]) {
        inner = inner[1 .. inner.len - 1];
    }
    return .{
        .id = parseHref(inner) orelse return null,
        .fallback = std.mem.trim(u8, s[close + 1 ..], " \t\n\r"),
    };
}

fn parseNumber(str: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, str, " \t\n\r")) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

// ============================================================================
// Rendering: a gradient for one element, as a PDF shading pattern
// ============================================================================

pub const Box = @import("svg_path.zig").Box;

/// The SVG viewport, which percentages in userSpaceOnUse refer to.
pub const Viewport = struct { width: f64, height: f64 };

/// One shading pattern: everything writePattern needs.
pub const PatternSpec = struct {
    kind: Kind,
    /// Linear: x1 y1 x2 y2 (the rest unused); radial: fx fy fr cx cy r.
    coords: [6]f64,
    /// Gradient space to the SVG form's space.
    matrix: Transform,
    /// The stops as written (at least 2); writePattern normalizes them.
    stops: []const Stop,

    pub fn eql(a: PatternSpec, b: PatternSpec) bool {
        return a.kind == b.kind and std.mem.eql(f64, &a.coords, &b.coords) and
            std.meta.eql(a.matrix, b.matrix) and
            a.stops.ptr == b.stops.ptr and a.stops.len == b.stops.len;
    }
};

/// What a gradient paints on one element.
pub const Prepared = union(enum) {
    none,
    color: Color,
    pattern: PatternSpec,
};

/// Prepare `g` for an element whose geometry has bounding box `bbox`
/// (null when it has none) in its user space, which `ctm` maps to the
/// form's space. SVG's rules: no stops paint nothing, one stop paints its
/// color, as does the last stop when the gradient has no extent (equal
/// end points, zero radius); objectBoundingBox on a box without width or
/// height paints nothing, as do a negative radius and a gradientTransform
/// that cannot be inverted.
pub fn prepare(g: *const Gradient, bbox: ?Box, ctm: Transform, viewport: Viewport) Prepared {
    const stops = g.stops.items;
    if (stops.len == 0) return .none;
    if (stops.len == 1) return .{ .color = stops[0].color };
    const last = stops[stops.len - 1].color;

    const units = g.units orelse .object_bounding_box;
    const space = Space{ .units = units, .viewport = viewport };
    var coords: [6]f64 = @splat(0);
    switch (g.kind) {
        .linear => {
            coords[0] = space.resolve(g.x1 orelse .{ .value = 0, .percent = true }, .x);
            coords[1] = space.resolve(g.y1 orelse .{ .value = 0, .percent = true }, .y);
            coords[2] = space.resolve(g.x2 orelse .{ .value = 100, .percent = true }, .x);
            coords[3] = space.resolve(g.y2 orelse .{ .value = 0, .percent = true }, .y);
            if (coords[0] == coords[2] and coords[1] == coords[3]) return .{ .color = last };
        },
        .radial => {
            const half = Length{ .value = 50, .percent = true };
            const cx = g.cx orelse half;
            const cy = g.cy orelse half;
            coords[0] = space.resolve(g.fx orelse cx, .x);
            coords[1] = space.resolve(g.fy orelse cy, .y);
            coords[3] = space.resolve(cx, .x);
            coords[4] = space.resolve(cy, .y);
            coords[5] = space.resolve(g.r orelse half, .r);
            if (coords[5] < 0) return .none;
            if (coords[5] == 0) return .{ .color = last };
        },
    }

    var matrix = ctm;
    if (units == .object_bounding_box) {
        const box = bbox orelse return .none;
        if (box.width == 0 or box.height == 0) return .none;
        matrix = matrix.multiply(.{ .a = box.width, .d = box.height, .e = box.x, .f = box.y });
    }
    if (g.transform) |t| {
        if (t.a * t.d - t.b * t.c == 0) return .none;
        matrix = matrix.multiply(t);
    }
    return .{ .pattern = .{ .kind = g.kind, .coords = coords, .matrix = matrix, .stops = stops } };
}

const Space = struct {
    units: Units,
    viewport: Viewport,

    fn resolve(self: Space, len: Length, axis: enum { x, y, r }) f64 {
        if (self.units == .object_bounding_box or !len.percent) return len.number();
        const w = self.viewport.width;
        const h = self.viewport.height;
        const extent = switch (axis) {
            .x => w,
            .y => h,
            .r => @sqrt((w * w + h * h) / 2),
        };
        return len.number() * extent;
    }
};

/// Write `spec` as a PDF shading pattern dictionary (PatternType 2): an
/// axial or radial shading, extended at both ends (spreadMethod pad), whose
/// function interpolates the stops in RGB.
pub fn writePattern(allocator: std.mem.Allocator, spec: PatternSpec, w: *std.Io.Writer) !void {
    try w.writeAll("<< /PatternType 2 /Matrix [");
    const m = spec.matrix;
    try writeNumbers(w, &.{ m.a, m.b, m.c, m.d, m.e, m.f });
    try w.print("] /Shading << /ShadingType {d} /ColorSpace /DeviceRGB /Coords [", .{@as(u8, if (spec.kind == .linear) 2 else 3)});
    try writeNumbers(w, if (spec.kind == .linear) spec.coords[0..4] else &spec.coords);
    try w.writeAll("] /Function ");
    try writeStopFunction(allocator, spec.stops, w);
    try w.writeAll(" /Extend [true true] >> >>");
}

/// A stop placed on [0, 1], in order: what the PDF function interpolates.
const Point = struct { t: f64, color: Color };

/// The stops as points covering [0, 1]: offsets made non-decreasing (a stop
/// before an earlier one moves up to it, as SVG specifies), the first and
/// last colors held out to 0 and 1.
fn stopPoints(allocator: std.mem.Allocator, stops: []const Stop) !std.ArrayListUnmanaged(Point) {
    var points: std.ArrayListUnmanaged(Point) = .empty;
    errdefer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, stops.len + 2);
    if (stops[0].offset > 0) points.appendAssumeCapacity(.{ .t = 0, .color = stops[0].color });
    var t: f64 = 0;
    for (stops) |stop| {
        t = @max(t, stop.offset);
        points.appendAssumeCapacity(.{ .t = t, .color = stop.color });
    }
    if (t < 1) points.appendAssumeCapacity(.{ .t = 1, .color = stops[stops.len - 1].color });
    return points;
}

/// The PDF function over [0, 1]: one Type 2 (linear) function per span
/// between neighbouring points, stitched (Type 3) when there are several.
/// Spans of zero width (two stops at one offset: a hard edge) are left
/// out, so the color jumps there.
fn writeStopFunction(allocator: std.mem.Allocator, stops: []const Stop, w: *std.Io.Writer) !void {
    var points = try stopPoints(allocator, stops);
    defer points.deinit(allocator);
    const p = points.items;

    var spans: usize = 0;
    for (p[0 .. p.len - 1], p[1..]) |a, b| {
        if (b.t > a.t) spans += 1;
    }
    // Points always run from 0 to 1, so there is at least one span.
    std.debug.assert(spans > 0);
    if (spans == 1) {
        for (p[0 .. p.len - 1], p[1..]) |a, b| {
            if (b.t > a.t) try writeSpan(w, a.color, b.color);
        }
        return;
    }
    try w.writeAll("<< /FunctionType 3 /Domain [0 1] /Functions [");
    for (p[0 .. p.len - 1], p[1..]) |a, b| {
        if (b.t > a.t) try writeSpan(w, a.color, b.color);
    }
    try w.writeAll("] /Bounds [");
    var first_span = true;
    var sep = false;
    for (p[0 .. p.len - 1], p[1..]) |a, b| {
        if (!(b.t > a.t)) continue;
        // Each span after the first starts at a bound.
        if (!first_span) {
            if (sep) try w.writeByte(' ');
            try writeNumber(w, a.t);
            sep = true;
        }
        first_span = false;
    }
    try w.writeAll("] /Encode [");
    for (0..spans) |i| try w.writeAll(if (i == 0) "0 1" else " 0 1");
    try w.writeAll("] >>");
}

fn writeSpan(w: *std.Io.Writer, c0: Color, c1: Color) !void {
    try w.writeAll("<< /FunctionType 2 /Domain [0 1] /C0 [");
    try writeRgb(w, c0);
    try w.writeAll("] /C1 [");
    try writeRgb(w, c1);
    try w.writeAll("] /N 1 >>");
}

fn writeRgb(w: *std.Io.Writer, c: Color) !void {
    const rgb = c.toPdfRgb();
    try writeNumbers(w, &.{ rgb.r, rgb.g, rgb.b });
}

fn writeNumbers(w: *std.Io.Writer, values: []const f64) !void {
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try writeNumber(w, v);
    }
}

/// A number with up to 6 decimals and no trailing zeros (`0.5`, `-12`,
/// `0`). Gradient coordinates in objectBoundingBox units are fractions,
/// and the matrix scales them up, so 2 decimals would not do.
fn writeNumber(w: *std.Io.Writer, v: f64) !void {
    // Inputs are bounded (svg.zig's max_magnitude, 1e9), products of a few
    // of them are not far off; a non-finite value cannot occur, but would
    // not be a PDF number, so it is written as 0.
    if (!std.math.isFinite(v)) return w.writeByte('0');
    var buf: [400]u8 = undefined; // {d:.6} of the largest finite f64 fits
    var text: []const u8 = std.fmt.bufPrint(&buf, "{d:.6}", .{v}) catch unreachable;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        text = std.mem.trimEnd(u8, text, "0");
        text = std.mem.trimEnd(u8, text, ".");
    }
    if (std.mem.eql(u8, text, "-0")) text = "0";
    try w.writeAll(text);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseLength: numbers, percentages, units, junk" {
    try testing.expectEqual(Length{ .value = 0.5 }, parseLength("0.5").?);
    try testing.expectEqual(Length{ .value = 50, .percent = true }, parseLength("50%").?);
    try testing.expectEqual(Length{ .value = 10 }, parseLength(" 10px ").?);
    try testing.expectEqual(Length{ .value = -2e-3 }, parseLength("-2e-3").?);
    try testing.expectEqual(@as(f64, 0.5), parseLength("50%").?.number());
    try testing.expect(parseLength("") == null);
    try testing.expect(parseLength("abc") == null);
    try testing.expect(parseLength("%") == null);
    try testing.expect(parseLength("inf") == null);
    try testing.expect(parseLength("nan%") == null);
}

test "parseOffset clamps and defaults to 0" {
    try testing.expectEqual(@as(f64, 0.25), parseOffset("0.25"));
    try testing.expectEqual(@as(f64, 0.25), parseOffset("25%"));
    try testing.expectEqual(@as(f64, 1), parseOffset("150%"));
    try testing.expectEqual(@as(f64, 0), parseOffset("-1"));
    try testing.expectEqual(@as(f64, 0), parseOffset("x"));
}

test "parseOpacity clamps, null on junk" {
    try testing.expectEqual(@as(f64, 0.5), parseOpacity("0.5").?);
    try testing.expectEqual(@as(f64, 0.5), parseOpacity("50%").?);
    try testing.expectEqual(@as(f64, 1), parseOpacity("2").?);
    try testing.expect(parseOpacity("half") == null);
}

test "parseUnits and parseSpread" {
    try testing.expectEqual(Units.user_space_on_use, parseUnits("userSpaceOnUse").?);
    try testing.expectEqual(Units.object_bounding_box, parseUnits(" objectBoundingBox ").?);
    try testing.expect(parseUnits("userspaceonuse") == null);
    try testing.expectEqual(Spread.reflect, parseSpread("reflect").?);
    try testing.expectEqual(Spread.pad, parseSpread("pad").?);
    try testing.expect(parseSpread("mirror") == null);
}

test "parseUrlPaint: quoting, fallback, rejects" {
    const a = parseUrlPaint("url(#g)").?;
    try testing.expectEqualStrings("g", a.id);
    try testing.expectEqualStrings("", a.fallback);

    const b = parseUrlPaint(" url( '#grad-1' )  red ").?;
    try testing.expectEqualStrings("grad-1", b.id);
    try testing.expectEqualStrings("red", b.fallback);

    const c = parseUrlPaint("URL(\"#x\") none").?;
    try testing.expectEqualStrings("x", c.id);
    try testing.expectEqualStrings("none", c.fallback);

    try testing.expect(parseUrlPaint("red") == null);
    try testing.expect(parseUrlPaint("url(other.svg#g)") == null);
    try testing.expect(parseUrlPaint("url(#)") == null);
    try testing.expect(parseUrlPaint("url(#g") == null);
}

fn expectLength(expected: Length, actual: ?Length) !void {
    try testing.expectEqual(expected, actual orelse return error.TestExpectedLength);
}

test "Svg reads gradient elements, their attributes and stops" {
    const doc =
        \\<svg width="100" height="100">
        \\  <defs>
        \\    <linearGradient id="lin" x1="10%" y1="0" x2="0.9" y2="1" gradientUnits="userSpaceOnUse"
        \\        spreadMethod="reflect" gradientTransform="rotate(90)">
        \\      <stop offset="0" stop-color="red"/>
        \\      <stop offset="50%" stop-color="#0000ff" stop-opacity="0.5"/>
        \\      <stop offset="2" style="stop-color: rgba(0, 255, 0, 0.5); stop-opacity: 0.5" stop-color="red"/>
        \\    </linearGradient>
        \\    <radialGradient id="rad" cx="1" cy="2" r="3" fx="4" fy="5" xlink:href="#lin"/>
        \\  </defs>
        \\</svg>
    ;
    const s = try svg.Svg.fromMemory(testing.allocator, doc);
    defer s.deinit();
    try testing.expectEqual(@as(u32, 2), s.gradients.count());

    const lin = s.gradients.getPtr("lin").?;
    try testing.expectEqual(Kind.linear, lin.kind);
    try expectLength(.{ .value = 10, .percent = true }, lin.x1);
    try expectLength(.{ .value = 0 }, lin.y1);
    try expectLength(.{ .value = 0.9 }, lin.x2);
    try expectLength(.{ .value = 1 }, lin.y2);
    try testing.expectEqual(Units.user_space_on_use, lin.units.?);
    try testing.expectEqual(Spread.reflect, lin.spread.?);
    try testing.expectApproxEqAbs(@as(f64, 1), lin.transform.?.b, 1e-12); // rotate(90): b = sin
    try testing.expect(lin.href == null);
    try testing.expect(lin.cx == null); // radial attributes are not linear's

    const stops = lin.stops.items;
    try testing.expectEqual(@as(usize, 3), stops.len);
    try testing.expectEqual(Stop{ .offset = 0, .color = .{ .r = 255 }, .opacity = 1 }, stops[0]);
    try testing.expectEqual(Stop{ .offset = 0.5, .color = .{ .b = 255 }, .opacity = 0.5 }, stops[1]);
    // style wins over the attribute; the color's alpha multiplies
    // stop-opacity (0.5 * 128/255); the offset is clamped to 1.
    try testing.expectEqual(@as(f64, 1), stops[2].offset);
    try testing.expectEqual(Color{ .g = 255 }, stops[2].color);
    try testing.expectApproxEqAbs(0.5 * 128.0 / 255.0, stops[2].opacity, 1e-12);

    const rad = s.gradients.getPtr("rad").?;
    try testing.expectEqual(Kind.radial, rad.kind);
    try expectLength(.{ .value = 1 }, rad.cx);
    try expectLength(.{ .value = 2 }, rad.cy);
    try expectLength(.{ .value = 3 }, rad.r);
    try expectLength(.{ .value = 4 }, rad.fx);
    try expectLength(.{ .value = 5 }, rad.fy);
    try testing.expectEqualStrings("lin", rad.href.?);
    try testing.expectEqual(@as(usize, 0), rad.stops.items.len);
    try testing.expect(rad.units == null and rad.spread == null and rad.transform == null);
}

test "Svg stop-color: invalid, none and currentColor are black" {
    const doc =
        \\<svg width="10" height="10"><linearGradient id="g">
        \\  <stop stop-color="bogus"/><stop stop-color="none"/><stop stop-color="currentColor" stop-opacity="x"/>
        \\</linearGradient></svg>
    ;
    const s = try svg.Svg.fromMemory(testing.allocator, doc);
    defer s.deinit();
    for (s.gradients.getPtr("g").?.stops.items) |stop| {
        try testing.expectEqual(Stop{ .offset = 0, .color = Color.black, .opacity = 1 }, stop);
    }
}

test "Svg url() paints: interned ids, fallbacks, forward references" {
    const doc =
        \\<svg width="10" height="10">
        \\  <rect width="1" height="1" fill="url(#later)" stroke="url(#missing) blue"/>
        \\  <rect width="1" height="1" style="fill: url('#later') none"/>
        \\  <linearGradient id="later"><stop offset="0"/></linearGradient>
        \\</svg>
    ;
    const s = try svg.Svg.fromMemory(testing.allocator, doc);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.paint_refs.items.len);
    try testing.expectEqualStrings("later", s.paint_refs.items[0]);
    try testing.expectEqualStrings("missing", s.paint_refs.items[1]);

    const a = s.elements.items[0].rect.style;
    try testing.expectEqual(@as(u32, 0), a.fill.?.server.ref);
    try testing.expect(a.fill.?.server.fallback == null);
    try testing.expectEqual(@as(u32, 1), a.stroke.?.server.ref);
    try testing.expectEqual(Color{ .b = 255 }, a.stroke.?.server.fallback.?);

    const b = s.elements.items[1].rect.style;
    try testing.expectEqual(@as(u32, 0), b.fill.?.server.ref); // same id, same entry
    try testing.expect(b.fill.?.server.fallback.?.isNone());

    // The forward reference resolves: the gradient follows its first use.
    try testing.expect(s.gradients.getPtr(s.paint_refs.items[a.fill.?.server.ref]) != null);
    try testing.expect(s.gradients.getPtr(s.paint_refs.items[a.stroke.?.server.ref]) == null);
}

test "Svg gradients: no id, duplicate ids, nesting, unclosed - no leaks" {
    // std.testing.allocator fails the test on any leak.
    const docs = [_][]const u8{
        // No id: never referenced, dropped.
        "<svg width=\"1\" height=\"1\"><linearGradient><stop offset=\"0\"/></linearGradient></svg>",
        // A duplicate id replaces the earlier gradient (as for defs).
        "<svg width=\"1\" height=\"1\"><linearGradient id=\"g\" href=\"#a\"><stop/></linearGradient><radialGradient id=\"g\" href=\"#b\"/></svg>",
        // A gradient inside a gradient is ignored with its stops.
        "<svg width=\"1\" height=\"1\"><linearGradient id=\"g\"><stop/><radialGradient id=\"n\"><stop/><stop/></radialGradient><stop/></linearGradient></svg>",
        // Never closed: dropped at the end of the document.
        "<svg width=\"1\" height=\"1\"><linearGradient id=\"g\" href=\"#x\"><stop/>",
        // A stop outside any gradient is ignored.
        "<svg width=\"1\" height=\"1\"><stop offset=\"0\"/></svg>",
    };
    for (docs) |doc| {
        const s = try svg.Svg.fromMemory(testing.allocator, doc);
        s.deinit();
    }

    const dup = try svg.Svg.fromMemory(testing.allocator, docs[1]);
    defer dup.deinit();
    try testing.expectEqual(Kind.radial, dup.gradients.getPtr("g").?.kind);

    const nested = try svg.Svg.fromMemory(testing.allocator, docs[2]);
    defer nested.deinit();
    try testing.expectEqual(@as(u32, 1), nested.gradients.count());
    try testing.expectEqual(@as(usize, 2), nested.gradients.getPtr("g").?.stops.items.len);

    // A gradientTransform that overflows is an invalid SVG, as for elements.
    try testing.expectError(error.InvalidSvg, svg.Svg.fromMemory(testing.allocator,
        "<svg width=\"1\" height=\"1\"><linearGradient id=\"g\" gradientTransform=\"scale(1e9) scale(1e9)\"/></svg>"));
}

fn patternText(spec: PatternSpec) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writePattern(testing.allocator, spec, &out.writer);
    return out.toOwnedSlice();
}

test "writePattern: two stops on 0..1 are one Type 2 function" {
    const stops = [_]Stop{ .{ .offset = 0, .color = .{ .r = 255 } }, .{ .offset = 1, .color = .{ .b = 255 } } };
    const text = try patternText(.{ .kind = .linear, .coords = .{ 0, 0, 1, 0, 0, 0 }, .matrix = .{ .a = 100, .d = -50, .e = 10, .f = 60.5 }, .stops = &stops });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("<< /PatternType 2 /Matrix [100 0 0 -50 10 60.5] /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 1 0] " ++
        "/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >> >>", text);
}

test "writePattern: radial coords, inset and out-of-order stops, hard edge" {
    // Stops at 0.25 (red), 0.5 (lime), 0.4 -> 0.5 (blue, a hard edge), 0.75
    // (white): held out to 0 and 1, the zero-width span left out.
    const stops = [_]Stop{
        .{ .offset = 0.25, .color = .{ .r = 255 } },
        .{ .offset = 0.5, .color = .{ .g = 255 } },
        .{ .offset = 0.4, .color = .{ .b = 255 } },
        .{ .offset = 0.75, .color = Color.white },
    };
    const text = try patternText(.{ .kind = .radial, .coords = .{ 0.25, 0.3, 0, 0.5, 0.5, 0.5 }, .matrix = .{}, .stops = &stops });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("<< /PatternType 2 /Matrix [1 0 0 1 0 0] /Shading << /ShadingType 3 /ColorSpace /DeviceRGB /Coords [0.25 0.3 0 0.5 0.5 0.5] " ++
        "/Function << /FunctionType 3 /Domain [0 1] /Functions [" ++
        "<< /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [1 0 0] /N 1 >>" ++
        "<< /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 1 0] /N 1 >>" ++
        "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 1] /C1 [1 1 1] /N 1 >>" ++
        "<< /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 1 1] /N 1 >>" ++
        "] /Bounds [0.25 0.5 0.75] /Encode [0 1 0 1 0 1 0 1] >> /Extend [true true] >> >>", text);
}

test "writePattern: all stops at one offset is a hard edge there" {
    const stops = [_]Stop{ .{ .offset = 0.5, .color = Color.black }, .{ .offset = 0.5, .color = Color.white } };
    const text = try patternText(.{ .kind = .linear, .coords = .{ 0, 0, 1, 0, 0, 0 }, .matrix = .{}, .stops = &stops });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "/C0 [0 0 0] /C1 [0 0 0] /N 1 >><< /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 1 1]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/Bounds [0.5]") != null);
}

test "writeNumber: trimmed, no negative zero, 6 decimals" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for ([_]f64{ 0, -0.0, 1, -2.5, 0.1234567, 1e-9, 123456.75 }) |v| {
        try writeNumber(&w, v);
        try w.writeByte(' ');
    }
    try testing.expectEqualStrings("0 0 1 -2.5 0.123457 0 123456.75 ", w.buffered());
}

fn testGradient(kind: Kind, stops: []const Stop) Gradient {
    var g = Gradient{ .kind = kind };
    g.stops = .initBuffer(@constCast(stops)); // borrowed: never deinit
    g.stops.items.len = stops.len;
    return g;
}

test "prepare: SVG's rules for stops, extent and boxes" {
    const two = [_]Stop{ .{ .offset = 0, .color = .{ .r = 255 } }, .{ .offset = 1, .color = .{ .b = 255 } } };
    const one = [_]Stop{.{ .offset = 0.3, .color = .{ .g = 9 } }};
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const vp = Viewport{ .width = 200, .height = 100 };
    const id = Transform{};

    var g = testGradient(.linear, &.{});
    try testing.expect(prepare(&g, box, id, vp) == .none);
    g = testGradient(.linear, &one);
    try testing.expectEqual(Color{ .g = 9 }, prepare(&g, box, id, vp).color);

    // objectBoundingBox (default): the box maps onto 0..1.
    g = testGradient(.linear, &two);
    const p = prepare(&g, box, id, vp).pattern;
    try testing.expectEqual([6]f64{ 0, 0, 1, 0, 0, 0 }, p.coords);
    try testing.expectEqual(Transform{ .a = 100, .d = 50, .e = 10, .f = 20 }, p.matrix);
    // No box, or one without width or height: nothing.
    try testing.expect(prepare(&g, null, id, vp) == .none);
    try testing.expect(prepare(&g, .{ .x = 0, .y = 5, .width = 10, .height = 0 }, id, vp) == .none);

    // Equal end points: the last stop's color.
    g.x2 = .{ .value = 0 };
    try testing.expectEqual(Color{ .b = 255 }, prepare(&g, box, id, vp).color);

    // userSpaceOnUse: percentages of the viewport, no box needed; the
    // gradientTransform comes after the element's (ctm) transform.
    g = testGradient(.linear, &two);
    g.units = .user_space_on_use;
    g.x2 = .{ .value = 50, .percent = true };
    g.y2 = .{ .value = 7 };
    g.transform = .{ .e = 3 };
    const u = prepare(&g, null, .{ .a = 2, .d = 2 }, vp).pattern;
    try testing.expectEqual([6]f64{ 0, 0, 100, 7, 0, 0 }, u.coords);
    try testing.expectEqual(Transform{ .a = 2, .d = 2, .e = 6 }, u.matrix);
    // A gradientTransform that cannot be inverted: nothing.
    g.transform = .{ .a = 0, .d = 0 };
    try testing.expect(prepare(&g, null, id, vp) == .none);

    // Radial: focal point defaults to the center; r in userSpaceOnUse
    // percent is of the viewport's normalized diagonal.
    var r = testGradient(.radial, &two);
    try testing.expectEqual([6]f64{ 0.5, 0.5, 0, 0.5, 0.5, 0.5 }, prepare(&r, box, id, vp).pattern.coords);
    r.fx = .{ .value = 0.2 };
    try testing.expectEqual([6]f64{ 0.2, 0.5, 0, 0.5, 0.5, 0.5 }, prepare(&r, box, id, vp).pattern.coords);
    r.units = .user_space_on_use;
    r.r = .{ .value = 10, .percent = true };
    r.fx = null;
    const rc = prepare(&r, null, id, vp).pattern.coords;
    try testing.expectApproxEqAbs(0.1 * @sqrt((200.0 * 200.0 + 100.0 * 100.0) / 2.0), rc[5], 1e-9);
    try testing.expectEqual(@as(f64, 100), rc[0]); // 50% of 200
    r.r = .{ .value = 0 };
    try testing.expectEqual(Color{ .b = 255 }, prepare(&r, null, id, vp).color);
    r.r = .{ .value = -1 };
    try testing.expect(prepare(&r, null, id, vp) == .none);
}

fn contentOf(doc: []const u8) ![]u8 {
    const s = try svg.Svg.fromMemory(testing.allocator, doc);
    defer s.deinit();
    var states: std.ArrayListUnmanaged(svg.OpacityState) = .empty;
    defer states.deinit(testing.allocator);
    var patterns: std.ArrayListUnmanaged(PatternSpec) = .empty;
    defer patterns.deinit(testing.allocator);
    return s.toPdfContent(testing.allocator, &states, &patterns);
}

test "Svg content: gradient fills and strokes set patterns, what fails paints nothing" {
    const doc =
        \\<svg width="100" height="100">
        \\  <linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
        \\  <rect width="10" height="10" fill="url(#g)" stroke="url(#g)"/>
        \\  <rect width="10" height="10" fill="url(#nope)"/>
        \\  <line x1="0" y1="5" x2="10" y2="5" stroke="url(#g)"/>
        \\  <text x="1" y="20" fill="url(#g)">Hi</text>
        \\</svg>
    ;
    const content = try contentOf(doc);
    defer testing.allocator.free(content);
    // The rect: one pattern (same gradient, same box) for fill and stroke.
    try testing.expect(std.mem.indexOf(u8, content, "/Pattern cs /P1 scn\n/Pattern CS /P1 SCN\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "re\nB\n") != null);
    // url(#nope) without a fallback paints nothing; the horizontal line has
    // a box without height, so its objectBoundingBox stroke paints nothing.
    try testing.expect(std.mem.indexOf(u8, content, "re\nn\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "l\nn\n") != null);
    // Text gets its own pattern (its own box).
    try testing.expect(std.mem.indexOf(u8, content, "/Pattern cs /P2 scn\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "/P3") == null);
}
