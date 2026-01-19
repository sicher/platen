# zpdf

zpdf - Fast PDF rendering library for Zig

A library for creating PDF documents, based on fpdf2.

## Imports

```zig
pub const Writer = @import("writer.zig").Writer;
pub const embedded = @import("embedded.zig");
pub const fonts = @import("fonts.zig");
pub const integration_tests = @import("integration_tests.zig");
pub const metrics = @import("metrics.zig");
pub const objects = @import("objects.zig");
pub const testing = @import("testing.zig");
pub const ttf = @import("ttf.zig");
pub const zlib = @import("zlib.zig");
```

## Enums

### `Align`

Text alignment.
Horizontal text alignment.

```zig
pub const Align = enum {
    left,
    center,
    right,
    justify,
}
```

### `LineBreaking`

Line breaking algorithm for paragraph layout.

```zig
pub const LineBreaking = enum {
    /// Greedy algorithm: fill each line as much as possible before moving to next.
    /// Fast but can produce uneven line lengths.
    greedy,
    /// Knuth-Plass optimal algorithm: minimize total "badness" across all lines.
    /// Considers entire paragraph to produce more balanced line lengths.
    optimal,
}
```

| Variant | Description |
|---------|-------------|
| `greedy` | Greedy algorithm: fill each line as much as possible before moving to next.
Fast but can produce uneven line lengths. |
| `optimal` | Knuth-Plass optimal algorithm: minimize total "badness" across all lines.
Considers entire paragraph to produce more balanced line lengths. |

### `VAlign`

Vertical text alignment within line height.

```zig
pub const VAlign = enum {
    /// Baseline at content_y + font_size (simple, no leading adjustment).
    top,
    /// Baseline centered: content_y + font_size - leading/2 (fpdf2 compatible).
    middle,
    /// Baseline at content_y + line_height (text sits on bottom edge).
    bottom,
}
```

| Variant | Description |
|---------|-------------|
| `bottom` | Baseline at content_y + line_height (text sits on bottom edge). |
| `middle` | Baseline centered: content_y + font_size - leading/2 (fpdf2 compatible). |
| `top` | Baseline at content_y + font_size (simple, no leading adjustment). |

## Structs

### `Border`

Border specification for regions.

```zig
pub const Border = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub const none = Border{};
    pub const all = Border{ .top = true, .bottom = true, .left = true, .right = true };
}
```

### `Color`

RGB color. Values are 0.0 to 1.0.

```zig
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };
    // TODO: CMYK, grayscale, spot colors
}
```

### `Document`

PDF Document

```zig
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,
    /// Document margins.
    margins: Margins = .{},
    // Text state
    current_font: ?StandardFont = null,
    current_embedded: ?*EmbeddedFont = null,
    font_size: f64 = 12,
    x: f64 = 0,
    y: f64 = 0,
    /// Extra space between characters (in points). Can be negative.
    char_spacing: f64 = 0,
    /// Line height as multiple of font size. Default 1.2 (20% leading).
    line_height: f64 = 1.2,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .{},
    // Track all embedded fonts
    embedded_fonts: std.ArrayListUnmanaged(*EmbeddedFont) = .{}
}
```

#### `addPage`

Add a new page

```zig
pub fn addPage(self: *Document) !void
```

#### `deinit`

```zig
pub fn deinit(self: *Document) void
```

#### `drawRegion`

Draws a region's border and fill (without text).

```zig
pub fn drawRegion(self: *Document, region: *const Region) !void
```

#### `getLineHeightPts`

Get current line height in points

```zig
pub fn getLineHeightPts(self: *Document) f64
```

#### `getPageRegion`

Returns a region for the current page respecting document margins.

```zig
pub fn getPageRegion(self: *Document) Region
```

#### `getTextStyle`

Get current text style for measurement

```zig
pub fn getTextStyle(self: *Document) TextStyle
```

#### `getTextWidth`

Measures text width using current font (standard or embedded).
Soft-hyphens (U+00AD) are excluded from measurement as they're invisible.

```zig
pub fn getTextWidth(self: *Document, str: []const u8) f64
```

#### `getX`

Get current X position

```zig
pub fn getX(self: *Document) f64
```

#### `getY`

Get current Y position (from top)

```zig
pub fn getY(self: *Document) f64
```

#### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Document
```

#### `loadFont`

Load a TrueType font from file

```zig
pub fn loadFont(self: *Document, path: []const u8) !*EmbeddedFont
```

#### `measureText`

Measure text dimensions without rendering

```zig
pub fn measureText(self: *Document, text_str: []const u8) TextMetrics
```

#### `measureTextWidth`

Measure text width in points

```zig
pub fn measureTextWidth(self: *Document, text_str: []const u8) f64
```

#### `output`

Output the PDF document as bytes
Caller owns the returned memory and must free it with the document's allocator

```zig
pub fn output(self: *Document) ![]u8
```

#### `setCharSpacing`

Set character spacing (extra space between characters, in points)

```zig
pub fn setCharSpacing(self: *Document, spacing: f64) void
```

#### `setEmbeddedFont`

Set an embedded font as current

```zig
pub fn setEmbeddedFont(self: *Document, font: *EmbeddedFont, size: f64) !void
```

#### `setFeature`

Set OpenType feature for all embedded fonts
Example: doc.setFeature(.liga, false) to disable ligatures

```zig
pub fn setFeature(self: *Document, feature: opentype.Feature, enabled: bool) void
```

#### `setFont`

Set the current font and size (standard font)

```zig
pub fn setFont(self: *Document, font: StandardFont, size: f64) !void
```

#### `setFontFeature`

Set OpenType feature for a specific embedded font

```zig
pub fn setFontFeature(self: *Document, font: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void
```

#### `setLineHeight`

Set line height (as multiple of font size, e.g. 1.2 = 120%)

```zig
pub fn setLineHeight(self: *Document, height: f64) void
```

#### `setMargins`

Set document margins.

```zig
pub fn setMargins(self: *Document, m: Margins) void
```

#### `setX`

Set X position

```zig
pub fn setX(self: *Document, x: f64) void
```

#### `setXY`

Set current position (in points from top-left)

```zig
pub fn setXY(self: *Document, x: f64, y: f64) void
```

#### `setY`

Set Y position (from top)

```zig
pub fn setY(self: *Document, y: f64) void
```

#### `write`

Writes text at the current cursor position.

```zig
pub fn write(self: *Document, str: []const u8) !void
```

#### `writeAt`

Writes text at the specified position.

```zig
pub fn writeAt(self: *Document, x: f64, y: f64, str: []const u8) !void
```

#### `writeFlow`

Writes text flowing across pages automatically.
Adds new pages as needed when text overflows.

```zig
pub fn writeFlow(self: *Document, str: []const u8, opts: FlowOptions) !void
```

#### `writeLine`

Writes a single line of text into a region.
Does not wrap text. Advances the region cursor by one line height.

```zig
pub fn writeLine(self: *Document, region: *Region, str: []const u8, opts: LineOptions) !WriteResult
```

#### `writeParagraph`

Writes wrapped text into a region.
Returns overflow text if it doesn't fit in the remaining region height.

```zig
pub fn writeParagraph(self: *Document, region: *Region, str: []const u8, opts: ParagraphOptions) !WriteResult
```

### `FlowOptions`

Options for writeFlow (auto-pagination).

```zig
pub const FlowOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
    /// First line indent in points.
    first_indent: f64 = 0,
}
```

### `LineOptions`

Options for writeLine (single line, no wrap).

```zig
pub const LineOptions = struct {
    /// Horizontal text alignment.
    alignment: Align = .left,
    /// Vertical text alignment within line height.
    valign: VAlign = .top,
}
```

### `Margins`

Document margins in points.

```zig
pub const Margins = struct {
    left: f64 = 72,
    right: f64 = 72,
    top: f64 = 72,
    bottom: f64 = 72,
}
```

### `Padding`

Region padding in points (defaults to zero).

```zig
pub const Padding = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,
}
```

### `PageSize`

Page size in points (1 point = 1/72 inch)

```zig
pub const PageSize = struct {
    width: f64,
    height: f64,

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
}
```

### `ParagraphOptions`

Options for writeParagraph (wrapped text).

```zig
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
}
```

### `Region`

Rectangular area for content placement with cursor tracking.

```zig
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
    fill: ?Color = null
}
```

#### `contentWidth`

Returns usable width inside padding.

```zig
pub fn contentWidth(self: Region) f64
```

#### `fits`

Returns true if the given metrics fit in remaining space.

```zig
pub fn fits(self: Region, m: TextMetrics) bool
```

#### `remainingHeight`

Returns remaining height in content area.

```zig
pub fn remainingHeight(self: Region) f64
```

### `WriteResult`

Result of writeLine or writeParagraph.

```zig
pub const WriteResult = struct {
    /// Number of lines rendered.
    lines_written: usize,
    /// Text that didn't fit, or null if all text was written.
    overflow: ?[]const u8,
}
```

## Unions

### `FontHandle`

Handle to a loaded font (either standard or embedded)

```zig
pub const FontHandle = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont
}
```

#### `name`

```zig
pub fn name(self: FontHandle) []const u8
```

## Constants

### `EmbeddedFont`

```zig
pub const EmbeddedFont = embedded.EmbeddedFont;
```

### `Font`

```zig
pub const Font = fonts.Font;
```

### `StandardFont`

```zig
pub const StandardFont = fonts.StandardFont;
```

### `TextMetrics`

```zig
pub const TextMetrics = metrics.TextMetrics;
```

### `TextStyle`

```zig
pub const TextStyle = metrics.TextStyle;
```

### `opentype`

```zig
pub const opentype = embedded.opentype;
```

### `pt_per_cm`

Points per centimeter.

```zig
pub const pt_per_cm = 72.0 / 2.54;
```

### `pt_per_inch`

Points per inch.

```zig
pub const pt_per_inch = 72.0;
```

### `pt_per_mm`

Points per millimeter.

```zig
pub const pt_per_mm = 72.0 / 25.4;
```

### `version`

```zig
pub const version = "0.1.0";
```

## Functions

### `cm`

Converts centimeters to points.

```zig
pub fn cm(n: f64) f64
```

### `inches`

Converts inches to points.

```zig
pub fn inches(n: f64) f64
```

### `mm`

Converts millimeters to points.

```zig
pub fn mm(n: f64) f64
```

