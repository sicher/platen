//! Layout types for zpdf - content areas, alignment, margins, and page sizes.

const color = @import("color.zig");
const metrics = @import("metrics.zig");

pub const Color = color.Color;
pub const TextMetrics = metrics.TextMetrics;

/// Border specification for regions.
pub const Border = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub const none = Border{};
    pub const all = Border{ .top = true, .bottom = true, .left = true, .right = true };
};

/// Horizontal text alignment.
pub const Align = enum {
    left,
    center,
    right,
    justify,
};

/// Vertical text alignment within line height.
pub const VAlign = enum {
    /// Baseline at content_y + font_size (simple, no leading adjustment).
    top,
    /// Baseline centered: content_y + font_size - leading/2 (fpdf2 compatible).
    middle,
    /// Baseline at content_y + line_height (text sits on bottom edge).
    bottom,
};

/// Line breaking algorithm for paragraph layout.
pub const LineBreaking = enum {
    /// Greedy algorithm: fill each line as much as possible before moving to next.
    /// Fast but can produce uneven line lengths.
    greedy,
    /// Knuth-Plass optimal algorithm: minimize total "badness" across all lines.
    /// Considers entire paragraph to produce more balanced line lengths.
    optimal,
};

/// Document margins in points.
pub const Margins = struct {
    left: f64 = 72,
    right: f64 = 72,
    top: f64 = 72,
    bottom: f64 = 72,
};

/// Content area padding in points (defaults to zero).
pub const Padding = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,
};

/// A 2D point (x, y coordinates).
pub const Point = struct {
    x: f64,
    y: f64,
};

/// Simple rectangle (bounding box).
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// Internal link destination (page position).
pub const Destination = struct {
    /// Page index (0-based).
    page_index: usize,
    /// Y position on page (from top).
    y: f64,
};

/// Styled text container with cursor tracking for text flow.
pub const TextBox = struct {
    /// Left edge x coordinate.
    x: f64,
    /// Top edge y coordinate (from page top).
    y: f64,
    /// Content area width.
    width: f64,
    /// Content area height.
    height: f64,
    /// Current cursor y position within content area (relative to top padding).
    cursor_y: f64 = 0,
    /// Inner padding (content inset from edges).
    padding: Padding = .{},
    /// Border styling.
    border: Border = .{},
    /// Background fill color.
    fill: ?Color = null,

    /// Returns remaining height in content area.
    pub fn remainingHeight(self: TextBox) f64 {
        return self.height - self.padding.top - self.padding.bottom - self.cursor_y;
    }

    /// Returns usable width inside padding.
    pub fn contentWidth(self: TextBox) f64 {
        return self.width - self.padding.left - self.padding.right;
    }

    /// Returns true if the given metrics fit in remaining space.
    pub fn fits(self: TextBox, m: TextMetrics) bool {
        return m.height <= self.remainingHeight();
    }

    /// Returns the bounds as a Rect.
    pub fn toRect(self: TextBox) Rect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
    }
};

/// Result of writeLine or writeParagraph.
pub const WriteResult = struct {
    /// Number of lines rendered.
    lines_written: usize,
    /// Text that didn't fit, or null if all text was written.
    overflow: ?[]const u8,
    /// Bounding rectangle of the rendered text.
    rect: Rect,
};

/// Result of measuring wrapped text without rendering.
pub const WrappedTextMetrics = struct {
    /// Total height needed (line_count * line_height).
    height: f64,
    /// Number of lines the text would occupy.
    line_count: usize,
    /// Width of the widest line (useful for centering blocks).
    max_line_width: f64,

    /// Check if text would fit in given height.
    pub fn fitsInHeight(self: WrappedTextMetrics, available_height: f64) bool {
        return self.height <= available_height;
    }
};

/// Options for measureWrappedText.
pub const MeasureOptions = struct {
    /// Available width for text wrapping (required).
    width: f64,
    /// First line indent in points.
    first_indent: f64 = 0,
    /// Allow breaking after regular hyphens in compound words.
    break_on_hyphens: bool = true,
    /// Line breaking algorithm.
    line_breaking: LineBreaking = .greedy,
};

/// Options for writeLine (single line, no wrap).
pub const LineOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
};

/// Options for writeParagraph (wrapped text).
pub const ParagraphOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// First line indent in points.
    first_indent: f64 = 0,
    /// Allow breaking after regular hyphens in compound words (e.g., "state-of-the-art").
    /// Default true. Set false for fpdf2 compatibility (only soft-hyphens break).
    break_on_hyphens: bool = true,
    /// Line breaking algorithm. Greedy is fast, optimal (Knuth-Plass) produces better results.
    line_breaking: LineBreaking = .greedy,
};

/// Options for writeFlow (auto-pagination).
pub const FlowOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// First line indent in points.
    first_indent: f64 = 0,
};

/// Page size in points (1 point = 1/72 inch)
pub const PageSize = struct {
    width: f64,
    height: f64,

    // ISO A series
    pub const A3 = PageSize{ .width = 841.89, .height = 1190.55 };
    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const A5 = PageSize{ .width = 419.53, .height = 595.28 };

    // US sizes
    pub const Letter = PageSize{ .width = 612, .height = 792 };
    pub const Legal = PageSize{ .width = 612, .height = 1008 };
    pub const Tabloid = PageSize{ .width = 792, .height = 1224 };

    /// Return landscape orientation (swap width and height)
    pub fn landscape(self: PageSize) PageSize {
        return .{ .width = self.height, .height = self.width };
    }
};

// ============================================================================
// Graphics Types
// ============================================================================

/// Drawing style for shapes.
pub const DrawStyle = enum {
    /// Only stroke the outline (S operator).
    stroke,
    /// Only fill the interior (f operator).
    fill,
    /// Fill and stroke (B operator).
    fill_stroke,
};

/// Line cap style (PDF J operator).
pub const LineCap = enum(u8) {
    /// Butt cap: line ends at endpoint.
    butt = 0,
    /// Round cap: semicircle at endpoint.
    round = 1,
    /// Square cap: half-width square at endpoint.
    square = 2,
};

/// Line join style (PDF j operator).
pub const LineJoin = enum(u8) {
    /// Miter join: sharp corner.
    miter = 0,
    /// Round join: circular arc at corner.
    round = 1,
    /// Bevel join: diagonal cut at corner.
    bevel = 2,
};

/// Dash pattern for stroked lines (PDF d operator).
pub const DashPattern = struct {
    /// Length of dash in points (0 = solid line).
    dash: f64 = 0,
    /// Length of gap in points.
    gap: f64 = 0,
    /// Phase offset in points.
    phase: f64 = 0,

    /// Solid line (no dashing).
    pub const solid = DashPattern{};
};

/// Options for configuring drawing style (lines and fills).
pub const DrawStyleOptions = struct {
    /// Line width in points.
    line_width: f64 = 0.567,
    /// Line cap style.
    line_cap: LineCap = .square,
    /// Line join style.
    line_join: LineJoin = .miter,
    /// Dash pattern for stroked lines.
    dash_pattern: DashPattern = .solid,
    /// Stroke (outline) color.
    stroke_color: Color = Color.black,
    /// Fill color.
    fill_color: Color = Color.black,
};
