//! SVG parsing and PDF Form XObject generation.
//!
//! Converts SVG vector graphics to PDF Form XObjects for embedding in PDF documents.
//! SVG elements are converted to PDF drawing operators that scale without quality loss.

const std = @import("std");
const xml = @import("xml.zig");
const color_module = @import("color.zig");
const layout = @import("layout.zig");
const graphics = @import("graphics.zig");

// ============================================================================
// Types
// ============================================================================

/// RGBA Color (0-255 per channel)
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const none = Color{ .a = 0 }; // Transparent

    pub fn isNone(self: Color) bool {
        return self.a == 0;
    }

    /// RGB color components as PDF floats (0.0-1.0 range).
    pub const PdfRgb = struct { r: f64, g: f64, b: f64 };

    /// Convert to PDF RGB float values (0.0-1.0 range).
    pub fn toPdfRgb(self: Color) PdfRgb {
        return .{
            .r = @as(f64, @floatFromInt(self.r)) / 255.0,
            .g = @as(f64, @floatFromInt(self.g)) / 255.0,
            .b = @as(f64, @floatFromInt(self.b)) / 255.0,
        };
    }
};

/// Line cap style
pub const LineCap = enum {
    butt, // 0
    round, // 1
    square, // 2

    pub fn toPdfValue(self: LineCap) u8 {
        return @intFromEnum(self);
    }
};

/// Line join style
pub const LineJoin = enum {
    miter, // 0
    round, // 1
    bevel, // 2

    pub fn toPdfValue(self: LineJoin) u8 {
        return @intFromEnum(self);
    }
};

/// Font family for SVG text
pub const FontFamily = enum {
    serif, // Times
    sans_serif, // Helvetica
    monospace, // Courier

    /// Map to PDF standard font base name
    pub fn toPdfBaseName(self: FontFamily) []const u8 {
        return switch (self) {
            .serif => "Times",
            .sans_serif => "Helvetica",
            .monospace => "Courier",
        };
    }
};

/// Font weight
pub const FontWeight = enum {
    normal,
    bold,
};

/// Font style
pub const FontStyle = enum {
    normal,
    italic,
    oblique,
};

/// Text anchor for horizontal alignment
pub const TextAnchor = enum {
    start, // Left-aligned (default)
    middle, // Center-aligned
    end, // Right-aligned
};

pub const Point = layout.Point;

/// Style properties for SVG elements
pub const Style = struct {
    fill: ?Color = null, // null = unspecified (inherits from parent, or black if root)
    stroke: ?Color = null,
    stroke_width: ?f64 = null, // null = unspecified
    stroke_linecap: ?LineCap = null,
    stroke_linejoin: ?LineJoin = null,
    opacity: ?f64 = null, // Overall opacity (0.0-1.0)
    fill_opacity: ?f64 = null, // Fill opacity (0.0-1.0)
    stroke_opacity: ?f64 = null, // Stroke opacity (0.0-1.0)

    /// Default style (unspecified - will inherit or use SVG defaults)
    pub const default = Style{};

    /// Merge another style on top of this one (for inheritance)
    /// Child values override parent values when specified.
    pub fn merge(self: Style, child: Style) Style {
        return .{
            .fill = child.fill orelse self.fill,
            .stroke = child.stroke orelse self.stroke,
            .stroke_width = child.stroke_width orelse self.stroke_width,
            .stroke_linecap = child.stroke_linecap orelse self.stroke_linecap,
            .stroke_linejoin = child.stroke_linejoin orelse self.stroke_linejoin,
            .opacity = child.opacity orelse self.opacity,
            .fill_opacity = child.fill_opacity orelse self.fill_opacity,
            .stroke_opacity = child.stroke_opacity orelse self.stroke_opacity,
        };
    }

    /// Get fill color, defaulting to black if unspecified (SVG default)
    pub fn getFill(self: Style) ?Color {
        return self.fill orelse Color.black;
    }

    /// Get stroke color (null if unspecified - no stroke)
    pub fn getStroke(self: Style) ?Color {
        return self.stroke;
    }

    /// Get stroke width, defaulting to 1.0 if unspecified
    pub fn getStrokeWidth(self: Style) f64 {
        return self.stroke_width orelse 1.0;
    }

    /// Get stroke linecap, defaulting to butt if unspecified
    pub fn getStrokeLinecap(self: Style) LineCap {
        return self.stroke_linecap orelse .butt;
    }

    /// Get stroke linejoin, defaulting to miter if unspecified
    pub fn getStrokeLinejoin(self: Style) LineJoin {
        return self.stroke_linejoin orelse .miter;
    }

    /// Get effective fill opacity (opacity * fill_opacity), defaulting to 1.0
    pub fn getFillOpacity(self: Style) f64 {
        const base = self.opacity orelse 1.0;
        const fill_op = self.fill_opacity orelse 1.0;
        return base * fill_op;
    }

    /// Get effective stroke opacity (opacity * stroke_opacity), defaulting to 1.0
    pub fn getStrokeOpacity(self: Style) f64 {
        const base = self.opacity orelse 1.0;
        const stroke_op = self.stroke_opacity orelse 1.0;
        return base * stroke_op;
    }

    /// Check if this style uses any transparency
    pub fn hasTransparency(self: Style) bool {
        const fill_op = self.getFillOpacity();
        const stroke_op = self.getStrokeOpacity();
        return fill_op < 1.0 or stroke_op < 1.0;
    }
};

/// 2D affine transform matrix
/// [a c e]
/// [b d f]
/// [0 0 1]
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity = Transform{};

    /// Check if this is the identity transform (no-op).
    pub fn isIdentity(self: Transform) bool {
        return self.a == 1 and self.b == 0 and self.c == 0 and
            self.d == 1 and self.e == 0 and self.f == 0;
    }

    /// Multiply two transforms: self * other
    pub fn multiply(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }

    /// Create translation transform
    pub fn translate(tx: f64, ty: f64) Transform {
        return .{ .e = tx, .f = ty };
    }

    /// Create scale transform
    pub fn scale(sx: f64, sy: f64) Transform {
        return .{ .a = sx, .d = sy };
    }

    /// Create rotation transform (angle in radians)
    pub fn rotate(angle: f64) Transform {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        return .{ .a = cos_a, .b = sin_a, .c = -sin_a, .d = cos_a };
    }

    /// Create skewX transform (angle in radians)
    pub fn skewX(angle: f64) Transform {
        return .{ .c = @tan(angle) };
    }

    /// Create skewY transform (angle in radians)
    pub fn skewY(angle: f64) Transform {
        return .{ .b = @tan(angle) };
    }
};

/// Path command for SVG paths
pub const PathCommand = union(enum) {
    move_to: struct { x: f64, y: f64 },
    line_to: struct { x: f64, y: f64 },
    horiz_to: struct { x: f64 },
    vert_to: struct { y: f64 },
    curve_to: struct { x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64 },
    smooth_curve: struct { x2: f64, y2: f64, x: f64, y: f64 },
    quad_to: struct { x1: f64, y1: f64, x: f64, y: f64 },
    smooth_quad: struct { x: f64, y: f64 },
    arc_to: struct { rx: f64, ry: f64, angle: f64, large_arc: bool, sweep: bool, x: f64, y: f64 },
    close_path,
};

/// SVG element types
pub const SvgElement = union(enum) {
    rect: struct {
        x: f64 = 0,
        y: f64 = 0,
        width: f64,
        height: f64,
        rx: f64 = 0,
        ry: f64 = 0,
        style: Style = .{},
        transform: Transform = .{},
    },
    circle: struct {
        cx: f64 = 0,
        cy: f64 = 0,
        r: f64,
        style: Style = .{},
        transform: Transform = .{},
    },
    ellipse: struct {
        cx: f64 = 0,
        cy: f64 = 0,
        rx: f64,
        ry: f64,
        style: Style = .{},
        transform: Transform = .{},
    },
    line: struct {
        x1: f64 = 0,
        y1: f64 = 0,
        x2: f64 = 0,
        y2: f64 = 0,
        style: Style = .{},
        transform: Transform = .{},
    },
    polyline: struct {
        points: std.ArrayListUnmanaged(Point),
        style: Style = .{},
        transform: Transform = .{},
    },
    polygon: struct {
        points: std.ArrayListUnmanaged(Point),
        style: Style = .{},
        transform: Transform = .{},
    },
    path: struct {
        commands: std.ArrayListUnmanaged(PathCommand),
        style: Style = .{},
        transform: Transform = .{},
    },
    group: struct {
        children: std.ArrayListUnmanaged(SvgElement),
        style: Style = .{},
        transform: Transform = .{},
    },
    text: struct {
        x: f64 = 0,
        y: f64 = 0,
        content: []const u8,
        font_family: FontFamily = .sans_serif,
        font_size: f64 = 16,
        font_weight: FontWeight = .normal,
        font_style: FontStyle = .normal,
        text_anchor: TextAnchor = .start,
        style: Style = .{},
        transform: Transform = .{},
    },

    /// Clone an element (deep copy for elements with allocated memory)
    pub fn clone(self: SvgElement, allocator: std.mem.Allocator) !SvgElement {
        return switch (self) {
            .rect => |r| .{ .rect = r },
            .circle => |c| .{ .circle = c },
            .ellipse => |e| .{ .ellipse = e },
            .line => |l| .{ .line = l },
            .polyline => |p| blk: {
                var points = std.ArrayListUnmanaged(Point).empty;
                try points.appendSlice(allocator, p.points.items);
                break :blk .{ .polyline = .{
                    .points = points,
                    .style = p.style,
                    .transform = p.transform,
                } };
            },
            .polygon => |p| blk: {
                var points = std.ArrayListUnmanaged(Point).empty;
                try points.appendSlice(allocator, p.points.items);
                break :blk .{ .polygon = .{
                    .points = points,
                    .style = p.style,
                    .transform = p.transform,
                } };
            },
            .path => |p| blk: {
                var commands = std.ArrayListUnmanaged(PathCommand).empty;
                try commands.appendSlice(allocator, p.commands.items);
                break :blk .{ .path = .{
                    .commands = commands,
                    .style = p.style,
                    .transform = p.transform,
                } };
            },
            .group => |g| blk: {
                var children = std.ArrayListUnmanaged(SvgElement).empty;
                for (g.children.items) |child| {
                    try children.append(allocator, try child.clone(allocator));
                }
                break :blk .{ .group = .{
                    .children = children,
                    .style = g.style,
                    .transform = g.transform,
                } };
            },
            .text => |t| .{ .text = .{
                .x = t.x,
                .y = t.y,
                .content = try allocator.dupe(u8, t.content),
                .font_family = t.font_family,
                .font_size = t.font_size,
                .font_weight = t.font_weight,
                .font_style = t.font_style,
                .text_anchor = t.text_anchor,
                .style = t.style,
                .transform = t.transform,
            } },
        };
    }

    pub fn deinit(self: *SvgElement, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .polyline => |*p| p.points.deinit(allocator),
            .polygon => |*p| p.points.deinit(allocator),
            .path => |*p| p.commands.deinit(allocator),
            .group => |*g| {
                for (g.children.items) |*child| {
                    child.deinit(allocator);
                }
                g.children.deinit(allocator);
            },
            .text => |*t| allocator.free(t.content),
            else => {},
        }
    }
};

/// Opacity state for PDF ExtGState (imported from layout)
pub const OpacityState = layout.OpacityState;

/// Parsed SVG document
/// Font used in SVG text elements
pub const UsedFont = struct {
    family: FontFamily,
    weight: FontWeight,
    style: FontStyle,

    /// Get the PDF standard font name (e.g., "Helvetica-Bold")
    pub fn toPdfName(self: UsedFont) []const u8 {
        return switch (self.family) {
            .sans_serif => switch (self.weight) {
                .normal => switch (self.style) {
                    .normal => "Helvetica",
                    .italic, .oblique => "Helvetica-Oblique",
                },
                .bold => switch (self.style) {
                    .normal => "Helvetica-Bold",
                    .italic, .oblique => "Helvetica-BoldOblique",
                },
            },
            .serif => switch (self.weight) {
                .normal => switch (self.style) {
                    .normal => "Times-Roman",
                    .italic, .oblique => "Times-Italic",
                },
                .bold => switch (self.style) {
                    .normal => "Times-Bold",
                    .italic, .oblique => "Times-BoldItalic",
                },
            },
            .monospace => switch (self.weight) {
                .normal => switch (self.style) {
                    .normal => "Courier",
                    .italic, .oblique => "Courier-Oblique",
                },
                .bold => switch (self.style) {
                    .normal => "Courier-Bold",
                    .italic, .oblique => "Courier-BoldOblique",
                },
            },
        };
    }

    pub fn eql(a: UsedFont, b: UsedFont) bool {
        return a.family == b.family and a.weight == b.weight and a.style == b.style;
    }
};

pub const Svg = struct {
    allocator: std.mem.Allocator,
    width: f64,
    height: f64,
    /// Set when a Document created this SVG (doc.loadSvg*): it lives and
    /// dies with that document. Caller-created SVGs (Svg.fromMemory) stay
    /// false and are shareable across documents.
    document_owned: bool = false,
    viewbox_x: f64 = 0,
    viewbox_y: f64 = 0,
    viewbox_width: f64 = 0,
    viewbox_height: f64 = 0,
    elements: std.ArrayListUnmanaged(SvgElement),
    opacity_states: std.ArrayListUnmanaged(OpacityState) = .empty,
    used_fonts: std.ArrayListUnmanaged(UsedFont) = .empty,
    defs: std.StringHashMapUnmanaged(SvgElement) = .empty, // Elements defined in <defs> by ID

    pub fn init(allocator: std.mem.Allocator) Svg {
        return .{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .elements = .empty,
            .opacity_states = .empty,
            .used_fonts = .empty,
            .defs = .empty,
        };
    }

    pub fn deinit(self: *Svg) void {
        for (self.elements.items) |*elem| {
            elem.deinit(self.allocator);
        }
        self.elements.deinit(self.allocator);
        self.opacity_states.deinit(self.allocator);
        self.used_fonts.deinit(self.allocator);
        // Free defs keys and elements
        var it = self.defs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.defs.deinit(self.allocator);
    }

    /// Get or add an opacity state, returns index for naming (GS1, GS2, etc.)
    pub fn getOrAddOpacityState(self: *Svg, fill_op: f64, stroke_op: f64) !usize {
        const state = OpacityState{ .fill_opacity = fill_op, .stroke_opacity = stroke_op };
        for (self.opacity_states.items, 0..) |s, i| {
            if (s.eql(state)) return i;
        }
        try self.opacity_states.append(self.allocator, state);
        return self.opacity_states.items.len - 1;
    }

    /// Get or add a font, returns index for naming (F1, F2, etc.)
    pub fn getOrAddFont(self: *Svg, font: UsedFont) !usize {
        for (self.used_fonts.items, 0..) |f, i| {
            if (f.eql(font)) return i;
        }
        try self.used_fonts.append(self.allocator, font);
        return self.used_fonts.items.len - 1;
    }

    /// Check if this SVG uses any transparency
    pub fn hasTransparency(self: *const Svg) bool {
        return self.opacity_states.items.len > 0;
    }

    /// Check if this SVG uses any text
    pub fn hasText(self: *const Svg) bool {
        return self.used_fonts.items.len > 0;
    }

    /// Load SVG from file
    pub fn fromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*Svg {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
        defer allocator.free(data);

        return fromMemory(allocator, data);
    }

    /// Load SVG from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !*Svg {
        const svg = try allocator.create(Svg);
        errdefer allocator.destroy(svg);
        svg.* = Svg.init(allocator);
        errdefer svg.deinit();

        try svg.parse(data);
        return svg;
    }

    /// Parse SVG XML data
    fn parse(self: *Svg, data: []const u8) !void {
        var parser = xml.XmlParser.init(data);

        // Style and transform stacks for group inheritance
        var style_stack = std.ArrayListUnmanaged(Style).empty;
        defer style_stack.deinit(self.allocator);
        try style_stack.append(self.allocator, Style.default);

        var transform_stack = std.ArrayListUnmanaged(Transform).empty;
        defer transform_stack.deinit(self.allocator);
        try transform_stack.append(self.allocator, Transform.identity);

        // Track when inside <defs> block
        var defs_depth: usize = 0;

        while (parser.nextElement()) |elem| {
            if (elem.is_end_tag) {
                // Track defs end
                if (std.mem.eql(u8, elem.tag, "defs")) {
                    if (defs_depth > 0) defs_depth -= 1;
                    continue;
                }
                // Pop style/transform on group end
                if (std.mem.eql(u8, elem.tag, "g")) {
                    if (transform_stack.items.len > 1) {
                        _ = transform_stack.pop();
                    }
                    if (style_stack.items.len > 1) {
                        _ = style_stack.pop();
                    }
                }
                continue;
            }

            // Track defs start
            if (std.mem.eql(u8, elem.tag, "defs")) {
                defs_depth += 1;
                continue;
            }

            // Skip style elements inside defs (CSS not supported)
            if (std.mem.eql(u8, elem.tag, "style")) {
                continue;
            }

            const current_style = style_stack.getLast();
            const current_transform = transform_stack.getLast();
            const in_defs = defs_depth > 0;

            if (std.mem.eql(u8, elem.tag, "svg")) {
                try self.parseSvgElement(elem);
            } else if (std.mem.eql(u8, elem.tag, "rect")) {
                try self.parseRect(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "circle")) {
                try self.parseCircle(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "ellipse")) {
                try self.parseEllipse(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "line")) {
                try self.parseLine(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "polyline")) {
                try self.parsePolyline(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "polygon")) {
                try self.parsePolygon(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "path")) {
                try self.parsePath(elem, current_style, current_transform, if (in_defs) &self.defs else null);
            } else if (std.mem.eql(u8, elem.tag, "text")) {
                if (!in_defs) {
                    try self.parseText(&parser, elem, current_style, current_transform);
                }
            } else if (std.mem.eql(u8, elem.tag, "use")) {
                if (!in_defs) {
                    try self.parseUse(elem, current_style, current_transform);
                }
            } else if (std.mem.eql(u8, elem.tag, "g")) {
                // Group - push transform and style
                var group_transform = current_transform;
                var group_style = current_style;
                var attrs = elem.attributes();
                while (attrs.next()) |attr| {
                    if (std.mem.eql(u8, attr.name, "transform")) {
                        const t = parseTransform(attr.value);
                        group_transform = group_transform.multiply(t);
                    } else {
                        parseStyleAttribute(attr.name, attr.value, &group_style);
                    }
                }
                try transform_stack.append(self.allocator, group_transform);
                try style_stack.append(self.allocator, group_style);
            }
        }
    }

    fn parseSvgElement(self: *Svg, elem: xml.Element) !void {
        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "width")) {
                // Percentage lengths on the root element are relative to a
                // viewport we don't have; leave 0 so the viewBox fallback
                // below supplies the intrinsic size (matches resvg behavior).
                if (std.mem.indexOfScalar(u8, attr.value, '%') == null) {
                    self.width = parseLengthValue(attr.value);
                }
            } else if (std.mem.eql(u8, attr.name, "height")) {
                if (std.mem.indexOfScalar(u8, attr.value, '%') == null) {
                    self.height = parseLengthValue(attr.value);
                }
            } else if (std.mem.eql(u8, attr.name, "viewBox")) {
                var iter = NumberIterator.init(attr.value);
                self.viewbox_x = iter.next() orelse 0;
                self.viewbox_y = iter.next() orelse 0;
                self.viewbox_width = iter.next() orelse 0;
                self.viewbox_height = iter.next() orelse 0;
            }
        }
        // Default dimensions from viewBox if not specified
        if (self.width == 0 and self.viewbox_width > 0) {
            self.width = self.viewbox_width;
        }
        if (self.height == 0 and self.viewbox_height > 0) {
            self.height = self.viewbox_height;
        }
        // If only one dimension specified, assume square
        if (self.width == 0 and self.height > 0) {
            self.width = self.height;
        }
        if (self.height == 0 and self.width > 0) {
            self.height = self.width;
        }
    }

    /// Store an element either in defs (by id) or in elements list
    fn storeElement(
        self: *Svg,
        element: SvgElement,
        id: ?[]const u8,
        defs: ?*std.StringHashMapUnmanaged(SvgElement),
    ) !void {
        if (defs) |d| {
            if (id) |elem_id| {
                // Store in defs by id (duplicate key for owned storage)
                const owned_id = try self.allocator.dupe(u8, elem_id);
                errdefer self.allocator.free(owned_id);
                try d.put(self.allocator, owned_id, element);
            }
            // If no id, element is discarded (can't be referenced)
        } else {
            try self.elements.append(self.allocator, element);
        }
    }

    fn parseRect(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var rect = SvgElement{ .rect = .{ .width = 0, .height = 0 } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "x")) {
                rect.rect.x = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y")) {
                rect.rect.y = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "width")) {
                rect.rect.width = parseLengthValue(attr.value);
            } else if (std.mem.eql(u8, attr.name, "height")) {
                rect.rect.height = parseLengthValue(attr.value);
            } else if (std.mem.eql(u8, attr.name, "rx")) {
                rect.rect.rx = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "ry")) {
                rect.rect.ry = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        rect.rect.style = parent_style.merge(local_style);
        rect.rect.transform = parent_transform.multiply(local_transform);
        try self.storeElement(rect, id, defs);
    }

    fn parseCircle(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var circle = SvgElement{ .circle = .{ .r = 0 } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "cx")) {
                circle.circle.cx = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "cy")) {
                circle.circle.cy = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "r")) {
                circle.circle.r = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        circle.circle.style = parent_style.merge(local_style);
        circle.circle.transform = parent_transform.multiply(local_transform);
        try self.storeElement(circle, id, defs);
    }

    fn parseEllipse(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var ellipse = SvgElement{ .ellipse = .{ .rx = 0, .ry = 0 } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "cx")) {
                ellipse.ellipse.cx = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "cy")) {
                ellipse.ellipse.cy = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "rx")) {
                ellipse.ellipse.rx = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "ry")) {
                ellipse.ellipse.ry = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        ellipse.ellipse.style = parent_style.merge(local_style);
        ellipse.ellipse.transform = parent_transform.multiply(local_transform);
        try self.storeElement(ellipse, id, defs);
    }

    fn parseLine(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var line = SvgElement{ .line = .{} };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "x1")) {
                line.line.x1 = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y1")) {
                line.line.y1 = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "x2")) {
                line.line.x2 = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y2")) {
                line.line.y2 = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        line.line.style = parent_style.merge(local_style);
        line.line.transform = parent_transform.multiply(local_transform);
        try self.storeElement(line, id, defs);
    }

    fn parsePolyline(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var polyline = SvgElement{ .polyline = .{ .points = .empty } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "points")) {
                try parsePointsList(self.allocator, attr.value, &polyline.polyline.points);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        polyline.polyline.style = parent_style.merge(local_style);
        polyline.polyline.transform = parent_transform.multiply(local_transform);
        try self.storeElement(polyline, id, defs);
    }

    fn parsePolygon(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var polygon = SvgElement{ .polygon = .{ .points = .empty } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "points")) {
                try parsePointsList(self.allocator, attr.value, &polygon.polygon.points);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        polygon.polygon.style = parent_style.merge(local_style);
        polygon.polygon.transform = parent_transform.multiply(local_transform);
        try self.storeElement(polygon, id, defs);
    }

    fn parsePath(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform, defs: ?*std.StringHashMapUnmanaged(SvgElement)) !void {
        var path = SvgElement{ .path = .{ .commands = .empty } };
        var local_transform = Transform.identity;
        var local_style = Style{};
        var id: ?[]const u8 = null;

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "id")) {
                id = attr.value;
            } else if (std.mem.eql(u8, attr.name, "d")) {
                try parsePathData(self.allocator, attr.value, &path.path.commands);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        path.path.style = parent_style.merge(local_style);
        path.path.transform = parent_transform.multiply(local_transform);
        try self.storeElement(path, id, defs);
    }

    fn parseText(self: *Svg, parser: *xml.XmlParser, elem: xml.Element, parent_style: Style, parent_transform: Transform) !void {
        var text_elem = SvgElement{ .text = .{ .content = "" } };
        var local_transform = Transform.identity;
        var local_style = Style{};

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "x")) {
                text_elem.text.x = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y")) {
                text_elem.text.y = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "font-family")) {
                text_elem.text.font_family = parseFontFamily(attr.value);
            } else if (std.mem.eql(u8, attr.name, "font-size")) {
                text_elem.text.font_size = parseLengthValue(attr.value);
            } else if (std.mem.eql(u8, attr.name, "font-weight")) {
                text_elem.text.font_weight = parseFontWeight(attr.value);
            } else if (std.mem.eql(u8, attr.name, "font-style")) {
                text_elem.text.font_style = parseFontStyle(attr.value);
            } else if (std.mem.eql(u8, attr.name, "text-anchor")) {
                text_elem.text.text_anchor = parseTextAnchor(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        // Get text content from parser (text between <text> and </text>)
        if (!elem.is_self_closing) {
            const content = parser.getTextContent();
            if (content.len > 0) {
                text_elem.text.content = try self.allocator.dupe(u8, content);
            }
        }

        // Register the font
        const font = UsedFont{
            .family = text_elem.text.font_family,
            .weight = text_elem.text.font_weight,
            .style = text_elem.text.font_style,
        };
        _ = try self.getOrAddFont(font);

        text_elem.text.style = parent_style.merge(local_style);
        text_elem.text.transform = parent_transform.multiply(local_transform);
        try self.elements.append(self.allocator, text_elem);
    }

    /// Parse <use> element - reference a defined element
    fn parseUse(self: *Svg, elem: xml.Element, parent_style: Style, parent_transform: Transform) !void {
        var href: ?[]const u8 = null;
        var x: f64 = 0;
        var y: f64 = 0;
        var local_transform = Transform.identity;
        var local_style = Style{};

        var attrs = elem.attributes();
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "href") or std.mem.eql(u8, attr.name, "xlink:href")) {
                href = attr.value;
            } else if (std.mem.eql(u8, attr.name, "x")) {
                x = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "y")) {
                y = parseFloat(attr.value);
            } else if (std.mem.eql(u8, attr.name, "transform")) {
                local_transform = parseTransform(attr.value);
            } else {
                parseStyleAttribute(attr.name, attr.value, &local_style);
            }
        }

        // Get the referenced element id (strip leading #)
        const ref_id = blk: {
            const h = href orelse return; // No href, nothing to do
            if (h.len > 0 and h[0] == '#') {
                break :blk h[1..];
            }
            break :blk h;
        };

        // Look up the element in defs
        const def_elem = self.defs.get(ref_id) orelse return; // Element not found

        // Clone the element
        var cloned = try def_elem.clone(self.allocator);
        errdefer cloned.deinit(self.allocator);

        // Build the combined transform: parent * translate(x,y) * use_local
        // SVG spec: x,y translate is applied before (outer to) the transform attribute
        // In matrix terms: parent * translate(x,y) * local_transform
        var use_transform = parent_transform;
        if (x != 0 or y != 0) {
            use_transform = use_transform.multiply(Transform.translate(x, y));
        }
        use_transform = use_transform.multiply(local_transform);

        // Apply transform and style to the cloned element
        applyTransformAndStyle(&cloned, use_transform, parent_style.merge(local_style));

        try self.elements.append(self.allocator, cloned);
    }

    /// Apply transform and style to an element (for use element processing)
    fn applyTransformAndStyle(element: *SvgElement, transform: Transform, style: Style) void {
        switch (element.*) {
            .rect => |*r| {
                r.transform = transform.multiply(r.transform);
                r.style = style.merge(r.style);
            },
            .circle => |*c| {
                c.transform = transform.multiply(c.transform);
                c.style = style.merge(c.style);
            },
            .ellipse => |*e| {
                e.transform = transform.multiply(e.transform);
                e.style = style.merge(e.style);
            },
            .line => |*l| {
                l.transform = transform.multiply(l.transform);
                l.style = style.merge(l.style);
            },
            .polyline => |*p| {
                p.transform = transform.multiply(p.transform);
                p.style = style.merge(p.style);
            },
            .polygon => |*p| {
                p.transform = transform.multiply(p.transform);
                p.style = style.merge(p.style);
            },
            .path => |*p| {
                p.transform = transform.multiply(p.transform);
                p.style = style.merge(p.style);
            },
            .group => |*g| {
                g.transform = transform.multiply(g.transform);
                g.style = style.merge(g.style);
            },
            .text => |*t| {
                t.transform = transform.multiply(t.transform);
                t.style = style.merge(t.style);
            },
        }
    }

    /// Generate PDF content stream for this SVG
    pub fn toPdfContent(self: *Svg, allocator: std.mem.Allocator) ![]u8 {
        var content = std.ArrayListUnmanaged(u8).empty;
        errdefer content.deinit(allocator);

        var writer = ContentWriter{ .buffer = &content, .allocator = allocator };

        // Apply coordinate flip (SVG Y-down to PDF Y-up)
        // Matrix: 1 0 0 -1 0 height
        try writer.print("1 0 0 -1 0 {d:.2} cm\n", .{self.height});

        // Apply viewBox transform if needed
        if (self.viewbox_width > 0 and self.viewbox_height > 0) {
            const sx = self.width / self.viewbox_width;
            const sy = self.height / self.viewbox_height;
            if (sx != 1 or sy != 1 or self.viewbox_x != 0 or self.viewbox_y != 0) {
                // Translate by -viewbox_x, -viewbox_y and scale
                try writer.print("{d:.4} 0 0 {d:.4} {d:.2} {d:.2} cm\n", .{
                    sx,
                    sy,
                    -self.viewbox_x * sx,
                    -self.viewbox_y * sy,
                });
            }
        }

        // Render each element
        for (self.elements.items) |*elem| {
            try self.renderElement(&writer, elem);
        }

        return content.toOwnedSlice(allocator);
    }

    fn renderElement(self: *Svg, writer: *ContentWriter, elem: *SvgElement) !void {
        switch (elem.*) {
            .rect => |r| try renderRect(self, writer, r),
            .circle => |c| try renderCircle(self, writer, c),
            .ellipse => |e| try renderEllipse(self, writer, e),
            .line => |l| try renderLine(self, writer, l),
            .polyline => |p| try renderPolyline(self, writer, p),
            .polygon => |p| try renderPolygon(self, writer, p),
            .path => |p| try renderPath(self, writer, p),
            .text => |t| try renderText(self, writer, t),
            .group => |g| {
                for (g.children.items) |*child| {
                    try self.renderElement(writer, child);
                }
            },
        }
    }
};

// ============================================================================
// PDF Content Generation
// ============================================================================

const ContentWriter = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn print(self: *ContentWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [512]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
            const str = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(str);
            try self.buffer.appendSlice(self.allocator, str);
            return;
        };
        try self.buffer.appendSlice(self.allocator, slice);
    }

    pub fn append(self: *ContentWriter, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
    }
};

fn renderRect(svg: *Svg, writer: *ContentWriter, rect: anytype) !void {
    try applyTransform(writer, rect.transform);
    try applyStyle(svg, writer, rect.style);

    if (rect.rx == 0 and rect.ry == 0) {
        // Simple rectangle
        try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} re\n", .{
            rect.x, rect.y, rect.width, rect.height,
        });
    } else {
        // Rounded rectangle - use bezier curves
        const rx = if (rect.rx > 0) rect.rx else rect.ry;
        const ry = if (rect.ry > 0) rect.ry else rect.rx;
        try renderRoundedRect(writer, rect.x, rect.y, rect.width, rect.height, rx, ry);
    }

    try finishPath(writer, rect.style);
    try restoreTransform(writer, rect.transform);
}

fn renderRoundedRect(writer: *ContentWriter, x: f64, y: f64, w: f64, h: f64, rx: f64, ry: f64) !void {
    // Clamp radii to half of dimensions
    const rx_clamped = @min(rx, w / 2);
    const ry_clamped = @min(ry, h / 2);

    // Bezier control point factor for approximating 90-degree arc
    const kx = rx_clamped * graphics.KAPPA;
    const ky = ry_clamped * graphics.KAPPA;

    // Start at top-left, after the corner
    try writer.print("{d:.2} {d:.2} m\n", .{ x + rx_clamped, y });

    // Top edge
    try writer.print("{d:.2} {d:.2} l\n", .{ x + w - rx_clamped, y });

    // Top-right corner
    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + w - rx_clamped + kx, y,
        x + w,                   y + ry_clamped - ky,
        x + w,                   y + ry_clamped,
    });

    // Right edge
    try writer.print("{d:.2} {d:.2} l\n", .{ x + w, y + h - ry_clamped });

    // Bottom-right corner
    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + w,                   y + h - ry_clamped + ky,
        x + w - rx_clamped + kx, y + h,
        x + w - rx_clamped,      y + h,
    });

    // Bottom edge
    try writer.print("{d:.2} {d:.2} l\n", .{ x + rx_clamped, y + h });

    // Bottom-left corner
    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x + rx_clamped - kx, y + h,
        x,                   y + h - ry_clamped + ky,
        x,                   y + h - ry_clamped,
    });

    // Left edge
    try writer.print("{d:.2} {d:.2} l\n", .{ x, y + ry_clamped });

    // Top-left corner
    try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
        x,                   y + ry_clamped - ky,
        x + rx_clamped - kx, y,
        x + rx_clamped,      y,
    });

    try writer.append("h\n");
}

fn renderCircle(svg: *Svg, writer: *ContentWriter, circle: anytype) !void {
    // Circle is ellipse with rx = ry = r
    try renderEllipse(svg, writer, .{
        .cx = circle.cx,
        .cy = circle.cy,
        .rx = circle.r,
        .ry = circle.r,
        .style = circle.style,
        .transform = circle.transform,
    });
}

fn renderEllipse(svg: *Svg, writer: *ContentWriter, ellipse: anytype) !void {
    try applyTransform(writer, ellipse.transform);
    try applyStyle(svg, writer, ellipse.style);

    // Use shared ellipse path generator
    var buf: [512]u8 = undefined;
    const len = graphics.writeEllipsePath(&buf, ellipse.cx, ellipse.cy, ellipse.rx, ellipse.ry);
    try writer.append(buf[0..len]);

    try finishPath(writer, ellipse.style);
    try restoreTransform(writer, ellipse.transform);
}

fn renderLine(svg: *Svg, writer: *ContentWriter, line: anytype) !void {
    try applyTransform(writer, line.transform);
    try applyStyle(svg, writer, line.style);

    try writer.print("{d:.2} {d:.2} m\n", .{ line.x1, line.y1 });
    try writer.print("{d:.2} {d:.2} l\n", .{ line.x2, line.y2 });

    // Lines only have stroke
    if (line.style.stroke) |_| {
        try writer.append("S\n");
    }

    try restoreTransform(writer, line.transform);
}

fn renderPolyline(svg: *Svg, writer: *ContentWriter, polyline: anytype) !void {
    if (polyline.points.items.len == 0) return;

    try applyTransform(writer, polyline.transform);
    try applyStyle(svg, writer, polyline.style);

    const first = polyline.points.items[0];
    try writer.print("{d:.2} {d:.2} m\n", .{ first.x, first.y });

    for (polyline.points.items[1..]) |pt| {
        try writer.print("{d:.2} {d:.2} l\n", .{ pt.x, pt.y });
    }

    // Polyline doesn't close, only stroke
    if (polyline.style.stroke) |_| {
        try writer.append("S\n");
    }

    try restoreTransform(writer, polyline.transform);
}

fn renderPolygon(svg: *Svg, writer: *ContentWriter, polygon: anytype) !void {
    if (polygon.points.items.len == 0) return;

    try applyTransform(writer, polygon.transform);
    try applyStyle(svg, writer, polygon.style);

    const first = polygon.points.items[0];
    try writer.print("{d:.2} {d:.2} m\n", .{ first.x, first.y });

    for (polygon.points.items[1..]) |pt| {
        try writer.print("{d:.2} {d:.2} l\n", .{ pt.x, pt.y });
    }

    try writer.append("h\n"); // Close path
    try finishPath(writer, polygon.style);
    try restoreTransform(writer, polygon.transform);
}

fn renderPath(svg: *Svg, writer: *ContentWriter, path: anytype) !void {
    try applyTransform(writer, path.transform);
    try applyStyle(svg, writer, path.style);

    var cur_x: f64 = 0;
    var cur_y: f64 = 0;
    var start_x: f64 = 0;
    var start_y: f64 = 0;
    var last_ctrl_x: f64 = 0;
    var last_ctrl_y: f64 = 0;
    var last_cmd_was_curve = false;

    for (path.commands.items) |cmd| {
        switch (cmd) {
            .move_to => |m| {
                try writer.print("{d:.2} {d:.2} m\n", .{ m.x, m.y });
                cur_x = m.x;
                cur_y = m.y;
                start_x = m.x;
                start_y = m.y;
                last_cmd_was_curve = false;
            },
            .line_to => |l| {
                try writer.print("{d:.2} {d:.2} l\n", .{ l.x, l.y });
                cur_x = l.x;
                cur_y = l.y;
                last_cmd_was_curve = false;
            },
            .horiz_to => |h| {
                try writer.print("{d:.2} {d:.2} l\n", .{ h.x, cur_y });
                cur_x = h.x;
                last_cmd_was_curve = false;
            },
            .vert_to => |v| {
                try writer.print("{d:.2} {d:.2} l\n", .{ cur_x, v.y });
                cur_y = v.y;
                last_cmd_was_curve = false;
            },
            .curve_to => |c| {
                try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                    c.x1, c.y1, c.x2, c.y2, c.x, c.y,
                });
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
                try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                    x1, y1, s.x2, s.y2, s.x, s.y,
                });
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
                try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                    cp1_x, cp1_y, cp2_x, cp2_y, q.x, q.y,
                });
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
                try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
                    cp1_x, cp1_y, cp2_x, cp2_y, t.x, t.y,
                });
                last_ctrl_x = x1;
                last_ctrl_y = y1;
                cur_x = t.x;
                cur_y = t.y;
                last_cmd_was_curve = true;
            },
            .arc_to => |a| {
                try renderArc(writer, cur_x, cur_y, a.rx, a.ry, a.angle, a.large_arc, a.sweep, a.x, a.y);
                cur_x = a.x;
                cur_y = a.y;
                last_cmd_was_curve = false;
            },
            .close_path => {
                try writer.append("h\n");
                cur_x = start_x;
                cur_y = start_y;
                last_cmd_was_curve = false;
            },
        }
    }

    try finishPath(writer, path.style);
    try restoreTransform(writer, path.transform);
}

fn renderText(svg: *Svg, writer: *ContentWriter, text: anytype) !void {
    if (text.content.len == 0) return;

    try applyTransform(writer, text.transform);

    // Find font index
    const font = UsedFont{
        .family = text.font_family,
        .weight = text.font_weight,
        .style = text.font_style,
    };
    var font_idx: usize = 0;
    for (svg.used_fonts.items, 0..) |f, i| {
        if (f.eql(font)) {
            font_idx = i;
            break;
        }
    }

    // Calculate text width for alignment (approximate: 0.5 * font_size per char)
    // This is an approximation since we don't have access to actual font metrics here.
    // For pixel-perfect alignment, SVG authors should use explicit positioning.
    const char_width = text.font_size * 0.5;
    const text_width = char_width * @as(f64, @floatFromInt(text.content.len));

    // Calculate x offset based on text-anchor
    var x = text.x;
    switch (text.text_anchor) {
        .start => {},
        .middle => x -= text_width / 2,
        .end => x -= text_width,
    }

    // Apply fill color
    const fill = text.style.getFill();
    if (fill) |c| {
        if (!c.isNone()) {
            const rgb = c.toPdfRgb();
            try writer.print("{d:.3} {d:.3} {d:.3} rg\n", .{ rgb.r, rgb.g, rgb.b });
        }
    }

    // PDF text operators
    // Use Tm (text matrix) with negative Y scale to counter the global SVG Y-flip.
    // The SVG coordinate system is flipped with "1 0 0 -1 0 height cm", so text
    // would appear upside down. Using "1 0 0 -1 x y Tm" cancels the flip for text.
    try writer.append("BT\n");
    try writer.print("/F{d} {d:.2} Tf\n", .{ font_idx + 1, text.font_size });
    try writer.print("1 0 0 -1 {d:.2} {d:.2} Tm\n", .{ x, text.y });

    // Write text content (escape special PDF characters)
    try writer.append("(");
    for (text.content) |c| {
        switch (c) {
            '(' => try writer.append("\\("),
            ')' => try writer.append("\\)"),
            '\\' => try writer.append("\\\\"),
            else => {
                var buf: [1]u8 = .{c};
                try writer.append(&buf);
            },
        }
    }
    try writer.append(") Tj\n");
    try writer.append("ET\n");

    try restoreTransform(writer, text.transform);
}

fn applyTransform(writer: *ContentWriter, transform: Transform) !void {
    if (transform.isIdentity()) return;
    try writer.append("q\n");
    try writer.print("{d:.4} {d:.4} {d:.4} {d:.4} {d:.2} {d:.2} cm\n", .{
        transform.a, transform.b, transform.c, transform.d, transform.e, transform.f,
    });
}

fn restoreTransform(writer: *ContentWriter, transform: Transform) !void {
    if (transform.isIdentity()) return;
    try writer.append("Q\n");
}

fn applyStyle(svg: *Svg, writer: *ContentWriter, style: Style) !void {
    // Apply opacity via ExtGState if not fully opaque
    const fill_op = style.getFillOpacity();
    const stroke_op = style.getStrokeOpacity();
    if (fill_op < 1.0 or stroke_op < 1.0) {
        const gs_index = try svg.getOrAddOpacityState(fill_op, stroke_op);
        try writer.print("/GS{d} gs\n", .{gs_index + 1}); // 1-indexed names
    }

    // Set fill color (default to black if unspecified)
    if (style.getFill()) |fill| {
        if (!fill.isNone()) {
            const rgb = fill.toPdfRgb();
            try writer.print("{d:.3} {d:.3} {d:.3} rg\n", .{ rgb.r, rgb.g, rgb.b });
        }
    }

    // Set stroke color
    if (style.getStroke()) |stroke| {
        if (!stroke.isNone()) {
            const rgb = stroke.toPdfRgb();
            try writer.print("{d:.3} {d:.3} {d:.3} RG\n", .{ rgb.r, rgb.g, rgb.b });
            try writer.print("{d:.2} w\n", .{style.getStrokeWidth()});
            try writer.print("{d} J\n", .{style.getStrokeLinecap().toPdfValue()});
            try writer.print("{d} j\n", .{style.getStrokeLinejoin().toPdfValue()});
        }
    }
}

fn finishPath(writer: *ContentWriter, style: Style) !void {
    const has_fill = if (style.getFill()) |f| !f.isNone() else false;
    const has_stroke = if (style.getStroke()) |s| !s.isNone() else false;

    if (has_fill and has_stroke) {
        try writer.append("B\n"); // Fill and stroke
    } else if (has_fill) {
        try writer.append("f\n"); // Fill only
    } else if (has_stroke) {
        try writer.append("S\n"); // Stroke only
    } else {
        try writer.append("n\n"); // No-op (end path without painting)
    }
}

// ============================================================================
// Arc to Bezier Conversion
// ============================================================================

/// Convert SVG arc to PDF bezier curves
fn renderArc(
    writer: *ContentWriter,
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
        try writer.print("{d:.2} {d:.2} l\n", .{ x2, y2 });
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

        try writer.print("{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            p1x, p1y, p2x, p2y, ex, ey,
        });

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

// ============================================================================
// Parsing Helpers
// ============================================================================

/// Parse font-family attribute
fn parseFontFamily(value: []const u8) FontFamily {
    // Check for common font family names
    const lower = value; // SVG font-family is case-insensitive for generic names
    if (std.mem.indexOf(u8, lower, "mono") != null or
        std.mem.indexOf(u8, lower, "courier") != null or
        std.mem.indexOf(u8, lower, "consolas") != null)
    {
        return .monospace;
    }
    if (std.mem.indexOf(u8, lower, "serif") != null and
        std.mem.indexOf(u8, lower, "sans") == null)
    {
        // "serif" but not "sans-serif"
        if (std.mem.indexOf(u8, lower, "times") != null) {
            return .serif;
        }
        return .serif;
    }
    // Default to sans-serif (Helvetica)
    return .sans_serif;
}

/// Parse font-weight attribute
fn parseFontWeight(value: []const u8) FontWeight {
    if (std.mem.eql(u8, value, "bold") or
        std.mem.eql(u8, value, "bolder") or
        std.mem.eql(u8, value, "700") or
        std.mem.eql(u8, value, "800") or
        std.mem.eql(u8, value, "900"))
    {
        return .bold;
    }
    return .normal;
}

/// Parse font-style attribute
fn parseFontStyle(value: []const u8) FontStyle {
    if (std.mem.eql(u8, value, "italic")) {
        return .italic;
    }
    if (std.mem.eql(u8, value, "oblique")) {
        return .oblique;
    }
    return .normal;
}

/// Parse text-anchor attribute
fn parseTextAnchor(value: []const u8) TextAnchor {
    if (std.mem.eql(u8, value, "middle")) {
        return .middle;
    }
    if (std.mem.eql(u8, value, "end")) {
        return .end;
    }
    return .start;
}

/// Parse a float value
fn parseFloat(str: []const u8) f64 {
    return std.fmt.parseFloat(f64, str) catch 0;
}

/// Parse a length value (with optional units)
fn parseLengthValue(str: []const u8) f64 {
    // Strip units suffix and parse as float
    var end = str.len;
    while (end > 0 and (str[end - 1] < '0' or str[end - 1] > '9') and str[end - 1] != '.') {
        end -= 1;
    }
    return parseFloat(str[0..end]);
}

/// Iterator for parsing numbers from a string
const NumberIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) NumberIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *NumberIterator) ?f64 {
        // Skip whitespace and commas
        while (self.pos < self.data.len and
            (self.data[self.pos] == ' ' or self.data[self.pos] == ',' or
                self.data[self.pos] == '\t' or self.data[self.pos] == '\n' or
                self.data[self.pos] == '\r'))
        {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return null;

        const start = self.pos;

        // Handle sign
        if (self.pos < self.data.len and (self.data[self.pos] == '-' or self.data[self.pos] == '+')) {
            self.pos += 1;
        }

        // Integer part
        while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
            self.pos += 1;
        }

        // Decimal part
        if (self.pos < self.data.len and self.data[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
                self.pos += 1;
            }
        }

        // Exponent
        if (self.pos < self.data.len and (self.data[self.pos] == 'e' or self.data[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.data.len and (self.data[self.pos] == '-' or self.data[self.pos] == '+')) {
                self.pos += 1;
            }
            while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
                self.pos += 1;
            }
        }

        if (self.pos == start) return null;
        return parseFloat(self.data[start..self.pos]);
    }
};

/// Clamp a float value to 0-255 and convert to u8.
fn clampToU8(val: f64) u8 {
    return @intFromFloat(@max(0, @min(255, val)));
}

/// Parse SVG color value
fn parseColor(str: []const u8) ?Color {
    if (str.len == 0) return null;

    // "none" - transparent
    if (std.mem.eql(u8, str, "none")) {
        return Color.none;
    }

    // Hex colors
    if (str[0] == '#') {
        if (str.len == 4) {
            // #RGB
            const r = parseHexDigit(str[1]) orelse return null;
            const g = parseHexDigit(str[2]) orelse return null;
            const b = parseHexDigit(str[3]) orelse return null;
            return Color{ .r = r * 17, .g = g * 17, .b = b * 17 };
        } else if (str.len == 7) {
            // #RRGGBB
            const r = parseHexByte(str[1..3]) orelse return null;
            const g = parseHexByte(str[3..5]) orelse return null;
            const b = parseHexByte(str[5..7]) orelse return null;
            return Color{ .r = r, .g = g, .b = b };
        }
        return null;
    }

    // rgb(r, g, b) or rgb(r%, g%, b%)
    if (std.mem.startsWith(u8, str, "rgb(") and str[str.len - 1] == ')') {
        var iter = NumberIterator.init(str[4 .. str.len - 1]);
        const r_val = iter.next() orelse return null;
        const g_val = iter.next() orelse return null;
        const b_val = iter.next() orelse return null;

        // Check if percentages (simple heuristic: look for %)
        const mult: f64 = if (std.mem.indexOf(u8, str, "%") != null) 2.55 else 1.0;
        return Color{
            .r = clampToU8(r_val * mult),
            .g = clampToU8(g_val * mult),
            .b = clampToU8(b_val * mult),
        };
    }

    // rgba(r, g, b, a) - alpha is 0.0-1.0
    if (std.mem.startsWith(u8, str, "rgba(") and str[str.len - 1] == ')') {
        var iter = NumberIterator.init(str[5 .. str.len - 1]);
        const r_val = iter.next() orelse return null;
        const g_val = iter.next() orelse return null;
        const b_val = iter.next() orelse return null;
        const a_val = iter.next() orelse 1.0;

        // Check if percentages for RGB values
        const mult: f64 = if (std.mem.indexOf(u8, str, "%") != null) 2.55 else 1.0;
        return Color{
            .r = clampToU8(r_val * mult),
            .g = clampToU8(g_val * mult),
            .b = clampToU8(b_val * mult),
            .a = clampToU8(a_val * 255),
        };
    }

    // Named colors (common subset)
    return namedColor(str);
}

fn namedColor(name: []const u8) ?Color {
    // Handle special SVG value
    if (std.mem.eql(u8, name, "transparent")) {
        return Color{ .a = 0 };
    }

    // Look up from shared CSS/SVG color definitions (148 colors)
    const css_color = color_module.Color.fromName(name) orelse return null;
    const rgb = css_color.toRgb();
    return Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

fn parseHexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexByte(str: []const u8) ?u8 {
    if (str.len != 2) return null;
    const hi = parseHexDigit(str[0]) orelse return null;
    const lo = parseHexDigit(str[1]) orelse return null;
    return hi * 16 + lo;
}

/// Parse style attribute
fn parseStyleAttribute(name: []const u8, value: []const u8, style: *Style) void {
    if (std.mem.eql(u8, name, "fill")) {
        style.fill = parseColor(value);
    } else if (std.mem.eql(u8, name, "stroke")) {
        style.stroke = parseColor(value);
    } else if (std.mem.eql(u8, name, "stroke-width")) {
        const w = parseFloat(value);
        if (w > 0) style.stroke_width = w;
    } else if (std.mem.eql(u8, name, "stroke-linecap")) {
        if (std.mem.eql(u8, value, "butt")) {
            style.stroke_linecap = .butt;
        } else if (std.mem.eql(u8, value, "round")) {
            style.stroke_linecap = .round;
        } else if (std.mem.eql(u8, value, "square")) {
            style.stroke_linecap = .square;
        }
    } else if (std.mem.eql(u8, name, "stroke-linejoin")) {
        if (std.mem.eql(u8, value, "miter")) {
            style.stroke_linejoin = .miter;
        } else if (std.mem.eql(u8, value, "round")) {
            style.stroke_linejoin = .round;
        } else if (std.mem.eql(u8, value, "bevel")) {
            style.stroke_linejoin = .bevel;
        }
    } else if (std.mem.eql(u8, name, "opacity")) {
        const op = parseFloat(value);
        if (op >= 0 and op <= 1) style.opacity = op;
    } else if (std.mem.eql(u8, name, "fill-opacity")) {
        const op = parseFloat(value);
        if (op >= 0 and op <= 1) style.fill_opacity = op;
    } else if (std.mem.eql(u8, name, "stroke-opacity")) {
        const op = parseFloat(value);
        if (op >= 0 and op <= 1) style.stroke_opacity = op;
    } else if (std.mem.eql(u8, name, "style")) {
        // Parse CSS-style string: "fill:red;stroke:blue;stroke-width:2"
        var iter = std.mem.splitScalar(u8, value, ';');
        while (iter.next()) |prop| {
            const trimmed = std.mem.trim(u8, prop, " \t\n\r");
            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                const prop_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const prop_value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
                parseStyleAttribute(prop_name, prop_value, style);
            }
        }
    }
}

/// Parse points attribute for polygon/polyline
fn parsePointsList(
    allocator: std.mem.Allocator,
    str: []const u8,
    points: *std.ArrayListUnmanaged(Point),
) !void {
    var iter = NumberIterator.init(str);
    while (iter.next()) |x| {
        const y = iter.next() orelse break;
        try points.append(allocator, .{ .x = x, .y = y });
    }
}

/// Parse transform attribute
fn parseTransform(str: []const u8) Transform {
    var result = Transform.identity;
    var pos: usize = 0;

    while (pos < str.len) {
        // Skip whitespace
        while (pos < str.len and (str[pos] == ' ' or str[pos] == ',' or str[pos] == '\t')) {
            pos += 1;
        }
        if (pos >= str.len) break;

        // Find transform name
        const name_start = pos;
        while (pos < str.len and str[pos] != '(') {
            pos += 1;
        }
        if (pos >= str.len) break;

        const name = std.mem.trim(u8, str[name_start..pos], " \t");
        pos += 1; // Skip (

        // Find closing )
        const args_start = pos;
        while (pos < str.len and str[pos] != ')') {
            pos += 1;
        }
        if (pos >= str.len) break;

        var iter = NumberIterator.init(str[args_start..pos]);
        pos += 1; // Skip )

        if (std.mem.eql(u8, name, "translate")) {
            const tx = iter.next() orelse 0;
            const ty = iter.next() orelse 0;
            result = result.multiply(Transform.translate(tx, ty));
        } else if (std.mem.eql(u8, name, "scale")) {
            const sx = iter.next() orelse 1;
            const sy = iter.next() orelse sx;
            result = result.multiply(Transform.scale(sx, sy));
        } else if (std.mem.eql(u8, name, "rotate")) {
            const angle_deg = iter.next() orelse 0;
            const cx = iter.next();
            const cy = iter.next();
            const angle_rad = angle_deg * std.math.pi / 180.0;
            if (cx != null and cy != null) {
                // Rotate around point
                result = result.multiply(Transform.translate(cx.?, cy.?));
                result = result.multiply(Transform.rotate(angle_rad));
                result = result.multiply(Transform.translate(-cx.?, -cy.?));
            } else {
                result = result.multiply(Transform.rotate(angle_rad));
            }
        } else if (std.mem.eql(u8, name, "skewX")) {
            const angle_deg = iter.next() orelse 0;
            result = result.multiply(Transform.skewX(angle_deg * std.math.pi / 180.0));
        } else if (std.mem.eql(u8, name, "skewY")) {
            const angle_deg = iter.next() orelse 0;
            result = result.multiply(Transform.skewY(angle_deg * std.math.pi / 180.0));
        } else if (std.mem.eql(u8, name, "matrix")) {
            const a = iter.next() orelse 1;
            const b = iter.next() orelse 0;
            const c = iter.next() orelse 0;
            const d = iter.next() orelse 1;
            const e = iter.next() orelse 0;
            const f = iter.next() orelse 0;
            result = result.multiply(.{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f });
        }
    }

    return result;
}

/// Parse path d attribute
fn parsePathData(
    allocator: std.mem.Allocator,
    str: []const u8,
    commands: *std.ArrayListUnmanaged(PathCommand),
) !void {
    var pos: usize = 0;
    var current_cmd: u8 = 0;
    var cur_x: f64 = 0;
    var cur_y: f64 = 0;
    var start_x: f64 = 0;
    var start_y: f64 = 0;

    while (pos < str.len) {
        // Skip whitespace and commas
        while (pos < str.len and (str[pos] == ' ' or str[pos] == ',' or str[pos] == '\t' or str[pos] == '\n' or str[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= str.len) break;

        // Check for command letter
        const c = str[pos];
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            current_cmd = c;
            pos += 1;
            // Handle Z/z immediately (no parameters)
            if (c == 'Z' or c == 'z') {
                try commands.append(allocator, .close_path);
                cur_x = start_x;
                cur_y = start_y;
            }
            continue;
        }

        // Parse number(s) for current command
        const is_relative = current_cmd >= 'a' and current_cmd <= 'z';
        const cmd_upper = if (is_relative) current_cmd - 32 else current_cmd;

        var iter = NumberIterator{ .data = str, .pos = pos };

        switch (cmd_upper) {
            'M' => {
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const abs_x = if (is_relative) cur_x + x else x;
                const abs_y = if (is_relative) cur_y + y else y;
                try commands.append(allocator, .{ .move_to = .{ .x = abs_x, .y = abs_y } });
                cur_x = abs_x;
                cur_y = abs_y;
                start_x = abs_x;
                start_y = abs_y;
                // Subsequent coordinates are LineTo
                current_cmd = if (is_relative) 'l' else 'L';
            },
            'L' => {
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const abs_x = if (is_relative) cur_x + x else x;
                const abs_y = if (is_relative) cur_y + y else y;
                try commands.append(allocator, .{ .line_to = .{ .x = abs_x, .y = abs_y } });
                cur_x = abs_x;
                cur_y = abs_y;
            },
            'H' => {
                const x = iter.next() orelse break;
                const abs_x = if (is_relative) cur_x + x else x;
                try commands.append(allocator, .{ .horiz_to = .{ .x = abs_x } });
                cur_x = abs_x;
            },
            'V' => {
                const y = iter.next() orelse break;
                const abs_y = if (is_relative) cur_y + y else y;
                try commands.append(allocator, .{ .vert_to = .{ .y = abs_y } });
                cur_y = abs_y;
            },
            'C' => {
                const x1 = iter.next() orelse break;
                const y1 = iter.next() orelse break;
                const x2 = iter.next() orelse break;
                const y2 = iter.next() orelse break;
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const offset_x = if (is_relative) cur_x else 0;
                const offset_y = if (is_relative) cur_y else 0;
                try commands.append(allocator, .{ .curve_to = .{
                    .x1 = x1 + offset_x,
                    .y1 = y1 + offset_y,
                    .x2 = x2 + offset_x,
                    .y2 = y2 + offset_y,
                    .x = x + offset_x,
                    .y = y + offset_y,
                } });
                cur_x = x + offset_x;
                cur_y = y + offset_y;
            },
            'S' => {
                const x2 = iter.next() orelse break;
                const y2 = iter.next() orelse break;
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const offset_x = if (is_relative) cur_x else 0;
                const offset_y = if (is_relative) cur_y else 0;
                try commands.append(allocator, .{ .smooth_curve = .{
                    .x2 = x2 + offset_x,
                    .y2 = y2 + offset_y,
                    .x = x + offset_x,
                    .y = y + offset_y,
                } });
                cur_x = x + offset_x;
                cur_y = y + offset_y;
            },
            'Q' => {
                const x1 = iter.next() orelse break;
                const y1 = iter.next() orelse break;
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const offset_x = if (is_relative) cur_x else 0;
                const offset_y = if (is_relative) cur_y else 0;
                try commands.append(allocator, .{ .quad_to = .{
                    .x1 = x1 + offset_x,
                    .y1 = y1 + offset_y,
                    .x = x + offset_x,
                    .y = y + offset_y,
                } });
                cur_x = x + offset_x;
                cur_y = y + offset_y;
            },
            'T' => {
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const abs_x = if (is_relative) cur_x + x else x;
                const abs_y = if (is_relative) cur_y + y else y;
                try commands.append(allocator, .{ .smooth_quad = .{ .x = abs_x, .y = abs_y } });
                cur_x = abs_x;
                cur_y = abs_y;
            },
            'A' => {
                const rx = iter.next() orelse break;
                const ry = iter.next() orelse break;
                const angle = iter.next() orelse break;
                const large_arc_val = iter.next() orelse break;
                const sweep_val = iter.next() orelse break;
                const x = iter.next() orelse break;
                const y = iter.next() orelse break;
                const abs_x = if (is_relative) cur_x + x else x;
                const abs_y = if (is_relative) cur_y + y else y;
                try commands.append(allocator, .{ .arc_to = .{
                    .rx = rx,
                    .ry = ry,
                    .angle = angle,
                    .large_arc = large_arc_val != 0,
                    .sweep = sweep_val != 0,
                    .x = abs_x,
                    .y = abs_y,
                } });
                cur_x = abs_x;
                cur_y = abs_y;
            },
            // 'Z' is handled at letter detection and takes no parameters, so
            // characters that land here after a close-path are invalid and
            // fall through to the unknown-command skip (a dedicated no-op arm
            // would leave `pos` unadvanced and loop forever).
            else => {
                // Unknown command, skip to next letter
                while (pos < str.len and !((str[pos] >= 'A' and str[pos] <= 'Z') or (str[pos] >= 'a' and str[pos] <= 'z'))) {
                    pos += 1;
                }
                continue;
            },
        }

        pos = iter.pos;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple SVG" {
    const allocator = std.testing.allocator;

    const svg_data =
        \\<svg width="100" height="100">
        \\  <rect x="10" y="10" width="80" height="80" fill="red" />
        \\</svg>
    ;

    const svg = try Svg.fromMemory(allocator, svg_data);
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    try std.testing.expectEqual(@as(f64, 100), svg.width);
    try std.testing.expectEqual(@as(f64, 100), svg.height);
    try std.testing.expectEqual(@as(usize, 1), svg.elements.items.len);

    const rect = svg.elements.items[0].rect;
    try std.testing.expectEqual(@as(f64, 10), rect.x);
    try std.testing.expectEqual(@as(f64, 10), rect.y);
    try std.testing.expectEqual(@as(f64, 80), rect.width);
    try std.testing.expectEqual(@as(f64, 80), rect.height);
    try std.testing.expectEqual(@as(u8, 255), rect.style.fill.?.r);
}

test "parse color" {
    // Hex colors
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parseColor("#ff0000").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parseColor("#f00").?);

    // Named colors
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parseColor("red").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 255 }, parseColor("blue").?);

    // rgb()
    try std.testing.expectEqual(Color{ .r = 128, .g = 64, .b = 32 }, parseColor("rgb(128, 64, 32)").?);

    // none
    try std.testing.expect(parseColor("none").?.isNone());
}

test "parse transform" {
    // translate
    const t1 = parseTransform("translate(10, 20)");
    try std.testing.expectEqual(@as(f64, 10), t1.e);
    try std.testing.expectEqual(@as(f64, 20), t1.f);

    // scale
    const t2 = parseTransform("scale(2, 3)");
    try std.testing.expectEqual(@as(f64, 2), t2.a);
    try std.testing.expectEqual(@as(f64, 3), t2.d);

    // Combined
    const t3 = parseTransform("translate(10, 0) scale(2)");
    try std.testing.expectEqual(@as(f64, 2), t3.a);
    try std.testing.expectEqual(@as(f64, 10), t3.e);
}

test "parse path data" {
    const allocator = std.testing.allocator;
    var commands = std.ArrayListUnmanaged(PathCommand).empty;
    defer commands.deinit(allocator);

    try parsePathData(allocator, "M 0 0 L 10 10 Z", &commands);

    try std.testing.expectEqual(@as(usize, 3), commands.items.len);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 0, .y = 0 } }, commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 10, .y = 10 } }, commands.items[1]);
    try std.testing.expectEqual(PathCommand.close_path, commands.items[2]);
}

test "parse path data with garbage after close-path terminates" {
    // Regression: a non-letter after Z/z left the cursor unadvanced and
    // looped forever.
    const allocator = std.testing.allocator;
    var commands = std.ArrayListUnmanaged(PathCommand).empty;
    defer commands.deinit(allocator);

    try parsePathData(allocator, "M 0 0 z 5 7 L 1 2", &commands);

    try std.testing.expectEqual(@as(usize, 3), commands.items.len);
    try std.testing.expectEqual(PathCommand.close_path, commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 1, .y = 2 } }, commands.items[2]);
}

test "generate PDF content" {
    const allocator = std.testing.allocator;

    const svg_data =
        \\<svg width="100" height="100">
        \\  <rect x="10" y="10" width="30" height="20" fill="blue" />
        \\</svg>
    ;

    const svg = try Svg.fromMemory(allocator, svg_data);
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    const content = try svg.toPdfContent(allocator);
    defer allocator.free(content);

    // Should contain coordinate flip and rectangle commands
    try std.testing.expect(std.mem.indexOf(u8, content, "1 0 0 -1 0 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "re") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "f") != null);
}

test "percentage root dimensions fall back to viewBox" {
    const allocator = std.testing.allocator;

    const svg_data =
        \\<svg width="100%" height="100%" viewBox="0 0 865 182">
        \\  <rect x="10" y="10" width="30" height="20" fill="blue" />
        \\</svg>
    ;

    const svg = try Svg.fromMemory(allocator, svg_data);
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    // "100%" must not parse as 100 points; intrinsic size comes from viewBox
    try std.testing.expectEqual(@as(f64, 865), svg.width);
    try std.testing.expectEqual(@as(f64, 182), svg.height);
}

test "parse defs and use" {
    const allocator = std.testing.allocator;

    const svg_data =
        \\<svg width="100" height="100" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\  <defs>
        \\    <path id="myPath" d="M0 0 L10 10" stroke="black" />
        \\    <rect id="myRect" width="20" height="20" fill="blue" />
        \\  </defs>
        \\  <use xlink:href="#myPath" transform="translate(10, 10)" />
        \\  <use xlink:href="#myRect" x="50" y="50" />
        \\</svg>
    ;

    const svg = try Svg.fromMemory(allocator, svg_data);
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    // Defs should have 2 elements
    try std.testing.expectEqual(@as(usize, 2), svg.defs.count());

    // Elements (from use) should have 2 elements
    try std.testing.expectEqual(@as(usize, 2), svg.elements.items.len);

    // First element should be a path with transform applied
    const path_elem = svg.elements.items[0];
    try std.testing.expect(path_elem == .path);
    try std.testing.expectEqual(@as(f64, 10), path_elem.path.transform.e); // translate x
    try std.testing.expectEqual(@as(f64, 10), path_elem.path.transform.f); // translate y

    // Second element should be a rect with x,y offset as transform
    const rect_elem = svg.elements.items[1];
    try std.testing.expect(rect_elem == .rect);
    try std.testing.expectEqual(@as(f64, 50), rect_elem.rect.transform.e); // translate x from use x
    try std.testing.expectEqual(@as(f64, 50), rect_elem.rect.transform.f); // translate y from use y
}

test "use-defs.svg element counts" {
    const allocator = std.testing.allocator;

    const svg = try Svg.fromFile(std.testing.io, allocator, "test/images/use-defs.svg");
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    // 4 defs: box, tri, arrow-r, arrow-l (all paths)
    try std.testing.expectEqual(@as(usize, 4), svg.defs.count());

    // 9 elements from use: 3 boxes + 3 triangles + 3 arrows
    try std.testing.expectEqual(@as(usize, 9), svg.elements.items.len);

    // All elements should be paths
    for (svg.elements.items) |elem| {
        try std.testing.expect(elem == .path);
    }
}

test "use element clones paths properly" {
    const allocator = std.testing.allocator;

    // Simple SVG with a path in defs and a use referencing it
    const svg_data =
        \\<svg width="100" height="100">
        \\  <defs>
        \\    <path id="arrow" d="M0 0 L10 0 L7 3 M10 0 L7 -3" stroke="black" fill="none" />
        \\  </defs>
        \\  <use href="#arrow" />
        \\</svg>
    ;

    const svg = try Svg.fromMemory(allocator, svg_data);
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    // Should have 1 def and 1 element (from use)
    try std.testing.expectEqual(@as(usize, 1), svg.defs.count());
    try std.testing.expectEqual(@as(usize, 1), svg.elements.items.len);

    // The element should be a path with the same commands
    const elem = svg.elements.items[0];
    try std.testing.expect(elem == .path);
    try std.testing.expect(elem.path.commands.items.len > 0);
}

test "parse MathJax equation SVG with xlink:href" {
    const allocator = std.testing.allocator;

    // Load the equation.svg file which uses xlink:href in <use> elements
    const svg = try Svg.fromFile(std.testing.io, allocator, "test/images/equation.svg");
    defer {
        svg.deinit();
        allocator.destroy(svg);
    }

    // The SVG has 11 path definitions in <defs> (style element is skipped)
    try std.testing.expectEqual(@as(usize, 11), svg.defs.count());

    // Many <use> elements reference those paths + 2 rects for fraction lines
    try std.testing.expect(svg.elements.items.len > 0);

    // Count paths and rects (should have paths from use + rect for fraction lines)
    var path_count: usize = 0;
    var rect_count: usize = 0;
    for (svg.elements.items) |elem| {
        switch (elem) {
            .path => path_count += 1,
            .rect => rect_count += 1,
            else => {},
        }
    }
    try std.testing.expect(path_count > 10); // Multiple use references to paths
    try std.testing.expectEqual(@as(usize, 2), rect_count); // 2 fraction line rects

    // Generate PDF content to verify rendering works
    const content = try svg.toPdfContent(allocator);
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
}
