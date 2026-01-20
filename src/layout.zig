//! Layout types for zpdf - regions, alignment, margins, and page sizes.

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

/// Region padding in points (defaults to zero).
pub const Padding = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,
};

/// Rectangular area for content placement with cursor tracking.
pub const Region = struct {
    /// Left edge x coordinate.
    x: f64,
    /// Top edge y coordinate (from page top).
    y: f64,
    /// Region width.
    width: f64,
    /// Region height.
    height: f64,
    /// Current cursor y position within content area (relative to top padding).
    cursor_y: f64 = 0,
    /// Inner padding (content inset from region edges).
    padding: Padding = .{},
    /// Border styling.
    border: Border = .{},
    /// Background fill color.
    fill: ?Color = null,

    /// Returns remaining height in content area.
    pub fn remainingHeight(self: Region) f64 {
        return self.height - self.padding.top - self.padding.bottom - self.cursor_y;
    }

    /// Returns usable width inside padding.
    pub fn contentWidth(self: Region) f64 {
        return self.width - self.padding.left - self.padding.right;
    }

    /// Returns true if the given metrics fit in remaining space.
    pub fn fits(self: Region, m: TextMetrics) bool {
        return m.height <= self.remainingHeight();
    }
};

/// Result of writeLine or writeParagraph.
pub const WriteResult = struct {
    /// Number of lines rendered.
    lines_written: usize,
    /// Text that didn't fit, or null if all text was written.
    overflow: ?[]const u8,
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

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
};
