//! Layout types for zpdf - content areas, alignment, margins, and page sizes.

const color = @import("color.zig");
const metrics = @import("metrics.zig");
const embedded = @import("embedded.zig");
const fonts = @import("fonts.zig");

pub const Color = color.Color;
pub const TextMetrics = metrics.TextMetrics;
pub const EmbeddedFont = embedded.EmbeddedFont;
pub const FontEncoding = embedded.FontEncoding;
pub const StandardFont = fonts.StandardFont;
pub const FontFamily = fonts.Family;

// ============================================================================
// Font and Text Style Types
// ============================================================================

/// A family of embedded fonts with regular, bold, italic, and bold-italic variants.
/// Use `Document.loadFontFamily()` to create one.
pub const EmbeddedFontFamily = struct {
    regular: *EmbeddedFont,
    bold: ?*EmbeddedFont = null,
    italic: ?*EmbeddedFont = null,
    bold_italic: ?*EmbeddedFont = null,

    /// Resolve to the correct variant based on bold/italic flags.
    /// Returns error if requested variant is not available.
    pub fn resolve(self: *const EmbeddedFontFamily, is_bold: bool, is_italic: bool) error{FontVariantNotLoaded}!*EmbeddedFont {
        if (is_bold and is_italic) {
            return self.bold_italic orelse return error.FontVariantNotLoaded;
        }
        if (is_bold) {
            return self.bold orelse return error.FontVariantNotLoaded;
        }
        if (is_italic) {
            return self.italic orelse return error.FontVariantNotLoaded;
        }
        return self.regular;
    }
};

/// Reference to a font (standard family, special font, or embedded).
pub const Font = union(enum) {
    family: FontFamily,
    symbol,
    zapf_dingbats,
    embedded: *EmbeddedFont,
    embedded_family: *EmbeddedFontFamily,

    // Convenience constants for standard font families
    pub const helvetica = Font{ .family = .helvetica };
    pub const times = Font{ .family = .times };
    pub const courier = Font{ .family = .courier };

    /// Resolve to StandardFont (for standard fonts only).
    /// Returns null for embedded fonts.
    pub fn toStandardFont(self: Font, bold: bool, italic: bool) ?StandardFont {
        return switch (self) {
            .family => |fam| fonts.StandardFont.fromFamilyStyle(fam, if (bold and italic)
                .bold_italic
            else if (bold)
                .bold
            else if (italic)
                .italic
            else
                .normal),
            .symbol => .symbol,
            .zapf_dingbats => .zapf_dingbats,
            .embedded, .embedded_family => null,
        };
    }
};

/// Complete text style (font, size, weight, color, decoration).
pub const TextStyle = struct {
    font: Font,
    size: f64,
    bold: bool = false,
    italic: bool = false,
    color: Color = Color.black,
    decoration: TextDecoration = .none,
    /// Extra space between characters in points (0 = normal).
    char_spacing: f64 = 0,

    /// Get the resolved StandardFont if this is a standard font.
    pub fn standardFont(self: TextStyle) ?StandardFont {
        return self.font.toStandardFont(self.bold, self.italic);
    }

    /// Get the embedded font, resolving family variants based on bold/italic.
    /// Returns null for standard fonts.
    /// Returns error.FontVariantNotLoaded if a family variant is requested but not loaded.
    pub fn resolveEmbeddedFont(self: TextStyle) error{FontVariantNotLoaded}!?*EmbeddedFont {
        return switch (self.font) {
            .embedded => |emb| emb,
            .embedded_family => |fam| try fam.resolve(self.bold, self.italic),
            else => null,
        };
    }

    /// Get the embedded font if this is a single embedded font (not a family).
    /// For families, use resolveEmbeddedFont() instead.
    pub fn embeddedFont(self: TextStyle) ?*EmbeddedFont {
        return switch (self.font) {
            .embedded => |emb| emb,
            else => null,
        };
    }
};

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

/// Text decoration options.
pub const TextDecoration = struct {
    /// Draw underline below text baseline.
    underline: bool = false,
    /// Draw strikethrough line through text.
    strikethrough: bool = false,

    pub const none = TextDecoration{};
};

/// Options for text styling (color, decoration).
/// Use with setTextStyle() to configure text appearance.
pub const TextStyleOptions = struct {
    /// Text color.
    color: Color = Color.black,
    /// Text decoration (underline, strikethrough).
    decoration: TextDecoration = .none,
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
    width: f64 = 0,
    height: f64 = 0,
};

/// Internal link destination (page position).
pub const Destination = struct {
    /// Page index (0-based).
    page_index: usize,
    /// Y position on page (from top).
    y: f64,
};

/// Styled text container with cursor tracking for text flow.
pub const Region = struct {
    /// Left edge x coordinate.
    x: f64,
    /// Top edge y coordinate (from page top).
    y: f64,
    /// Content area width.
    width: f64,
    /// Content area height.
    height: f64,
    /// Current cursor x position within content area (relative to left padding).
    cursor_x: f64 = 0,
    /// Current cursor y position within content area (relative to top padding).
    cursor_y: f64 = 0,
    /// Inner padding (content inset from edges).
    padding: Padding = .{},
    /// Border styling.
    border: Border = .{},
    /// Background fill color.
    fill: ?Color = null,

    /// Returns remaining height in content area.
    pub fn remainingHeight(self: Region) f64 {
        return self.height - self.padding.top - self.padding.bottom - self.cursor_y;
    }

    /// Returns remaining width on current line.
    pub fn remainingWidth(self: Region) f64 {
        return self.contentWidth() - self.cursor_x;
    }

    /// Resets cursor to origin (0, 0). Useful after measure pass.
    pub fn reset(self: *Region) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    /// Returns usable width inside padding.
    pub fn contentWidth(self: Region) f64 {
        return self.width - self.padding.left - self.padding.right;
    }

    /// Returns true if the given metrics fit in remaining space.
    pub fn fits(self: Region, m: TextMetrics) bool {
        return m.height <= self.remainingHeight();
    }

    /// Returns the bounds as a Rect.
    pub fn toRect(self: Region) Rect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
    }

    /// Advances cursor to next line.
    pub fn newLine(self: *Region, line_height: f64) void {
        self.cursor_x = 0;
        self.cursor_y += line_height;
    }
};

/// Result of writeStyled.
pub const WriteResult = struct {
    /// Number of lines rendered.
    lines_written: usize,
    /// Text that didn't fit, or null if all text was written.
    overflow: ?[]const u8,
    /// Bounding rectangle of the rendered text.
    rect: Rect,
};

/// Options for write() (flowing text with cursor tracking).
pub const WriteOptions = struct {
    /// If true, only measure text without rendering. Cursor is still updated.
    measure_only: bool = false,
    /// If true, wrap text to next line when it doesn't fit.
    /// If false, text stays on one line.
    wrap: bool = true,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// Allow breaking after regular hyphens in compound words (e.g., "state-of-the-art").
    break_on_hyphens: bool = true,
    /// Line height multiplier (1.2 = default, 1.0 = single spacing, 1.5 = 150%, etc.).
    line_height: f64 = 1.2,
};

/// Options for writeLine (block-based text with alignment).
pub const LineOptions = struct {
    /// If true, only measure text without rendering.
    measure_only: bool = false,
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// Allow breaking after regular hyphens in compound words.
    break_on_hyphens: bool = true,
    /// Line height multiplier.
    line_height: f64 = 1.2,
};

/// Options for writeStyled (wrapped text with alignment).
pub const ParagraphOptions = struct {
    /// If true, only measure text without rendering. Cursor is still updated.
    measure_only: bool = false,
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// Allow breaking after regular hyphens in compound words (e.g., "state-of-the-art").
    /// Default true. Set false for fpdf2 compatibility (only soft-hyphens break).
    break_on_hyphens: bool = true,
    /// Line breaking algorithm. Greedy is fast, optimal (Knuth-Plass) produces better results.
    line_breaking: LineBreaking = .greedy,
    /// Line height multiplier (1.2 = default, 1.0 = single spacing, 1.5 = 150%, etc.).
    line_height: f64 = 1.2,
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

/// Options for creating a new page.
pub const PageOptions = struct {
    size: PageSize = PageSize.A4,
    margins: Margins = .{},
};

// ============================================================================
// Navigation Types
// ============================================================================

/// Individual outline entry (bookmark) in the document outline.
pub const OutlineItem = struct {
    /// Displayed title in the outline panel.
    title: []const u8,
    /// Target destination (page and position).
    dest: Destination,
    /// Parent outline item (null for top-level).
    parent: ?*OutlineItem = null,

    // Internal fields - populated during output
    /// First child outline item.
    first_child: ?*OutlineItem = null,
    /// Last child outline item.
    last_child: ?*OutlineItem = null,
    /// Previous sibling.
    prev: ?*OutlineItem = null,
    /// Next sibling.
    next: ?*OutlineItem = null,
    /// Number of children (negative if closed).
    count: i32 = 0,
    /// Object ID assigned during output.
    object_id: u32 = 0,
};

/// Page label numbering style (PDF /S entry).
pub const PageLabelStyle = enum {
    /// D: Decimal (1, 2, 3, ...).
    decimal,
    /// r: Lowercase Roman (i, ii, iii, ...).
    roman_lower,
    /// R: Uppercase Roman (I, II, III, ...).
    roman_upper,
    /// a: Lowercase letters (a, b, c, ..., aa, ab, ...).
    alpha_lower,
    /// A: Uppercase letters (A, B, C, ..., AA, AB, ...).
    alpha_upper,
    /// No style - prefix only.
    none,

    /// Returns the PDF style code.
    pub fn pdfCode(self: PageLabelStyle) ?[]const u8 {
        return switch (self) {
            .decimal => "D",
            .roman_lower => "r",
            .roman_upper => "R",
            .alpha_lower => "a",
            .alpha_upper => "A",
            .none => null,
        };
    }
};

/// Page label specification for custom page numbering.
pub const PageLabel = struct {
    /// Numbering style.
    style: PageLabelStyle = .decimal,
    /// Optional prefix (e.g., "App-").
    prefix: ?[]const u8 = null,
    /// Starting number (default 1).
    start: u32 = 1,
};

// ============================================================================
// Graphics Types
// ============================================================================

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

/// Style for stroking (outlining) shapes.
pub const StrokeStyle = struct {
    /// Stroke color.
    color: Color = Color.black,
    /// Line width in points (0.567 = 0.2mm, matching fpdf2 default).
    width: f64 = 0.567,
    /// Line cap style (how line ends are drawn).
    cap: LineCap = .square,
    /// Line join style (how corners are drawn).
    join: LineJoin = .miter,
    /// Dash pattern (solid by default).
    dash: DashPattern = .solid,
};

/// Style for filling shapes.
pub const FillStyle = struct {
    /// Fill color.
    color: Color = Color.black,
};

/// Combined style for drawing shapes.
/// Set stroke and/or fill to control rendering.
/// If both are null, defaults to stroke with black color.
pub const ShapeStyle = struct {
    /// Stroke style, or null for no stroke.
    stroke: ?StrokeStyle = null,
    /// Fill style, or null for no fill.
    fill: ?FillStyle = null,
};
