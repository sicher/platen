# document

Document struct for zpdf - PDF document creation and management.

This module contains the core Document type that handles page management,
text rendering, font handling, and PDF output generation.

## Imports

```zig
pub const Writer = @import("writer.zig").Writer;
pub const color = @import("color.zig");
pub const embedded = @import("embedded.zig");
pub const fonts = @import("fonts.zig");
pub const layout = @import("layout.zig");
pub const metrics = @import("metrics.zig");
pub const objects = @import("objects.zig");
pub const ttf = @import("ttf.zig");
pub const zlib = @import("zlib.zig");
```

## Structs

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
    /// Text color (default black).
    text_color: Color = Color.black,
    /// Fill color for shapes (default black).
    fill_color: Color = Color.black,
    /// Stroke/draw color for lines and borders (default black).
    draw_color: Color = Color.black,
    /// Line width for strokes in points (default 0.567pt = 0.2mm, fpdf2 default).
    line_width: f64 = 0.567,
    /// Dash pattern for stroked lines.
    dash_pattern: layout.DashPattern = .{},
    /// Line cap style (fpdf2 default is square/projecting).
    line_cap: layout.LineCap = .square,
    /// Line join style.
    line_join: layout.LineJoin = .miter,
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

#### `drawCircle`

Draw a circle (special case of ellipse).
Parameters match fpdf2: (x, y) is the CENTER of the circle, radius is the circle radius.
Coordinates are from top-left origin.

```zig
pub fn drawCircle(self: *Document, x: f64, y: f64, radius: f64, style: DrawStyle) !void
```

#### `drawEllipse`

Draw an ellipse using 4 cubic Bezier curves.
Parameters match fpdf2: (x, y) is upper-left of bounding box, (w, h) is full width/height.
Coordinates are from top-left origin.

```zig
pub fn drawEllipse(self: *Document, x: f64, y: f64, w: f64, h: f64, style: DrawStyle) !void
```

#### `drawLine`

Draw a line between two points.
Coordinates are from top-left origin.

```zig
pub fn drawLine(self: *Document, x1: f64, y1: f64, x2: f64, y2: f64) !void
```

#### `drawPolygon`

Draw a closed polygon.
Coordinates are from top-left origin.

```zig
pub fn drawPolygon(self: *Document, points: []const Point, style: DrawStyle) !void
```

#### `drawRect`

Draw a rectangle.
Coordinates are from top-left origin.

```zig
pub fn drawRect(self: *Document, x: f64, y: f64, w: f64, h: f64, style: DrawStyle) !void
```

#### `drawRegion`

Draws a region's border and fill (without text).

```zig
pub fn drawRegion(self: *Document, region: Region) !void
```

#### `findHyphenBreak`

Find a regular hyphen break point in a word that fits within max_width.
Regular hyphens stay visible; we break AFTER the hyphen (e.g., "state-" / "of-the-art").
Returns the byte position after the hyphen where to split.

```zig
pub fn findHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize
```

#### `findSoftHyphenBreak`

Find a soft-hyphen break point in a word that fits within max_width.
Soft-hyphen (U+00AD, 0xC2 0xAD in UTF-8) marks optional break points.
Returns the byte position where to break (soft-hyphen will be replaced with visible hyphen).

```zig
pub fn findSoftHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize
```

#### `getFontMetrics`

Get font metrics for the current font, scaled to the current font size.
Returns metrics in points at the current font size.

```zig
pub fn getFontMetrics(self: *Document) FontMetrics
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

Generate PDF output

```zig
pub fn output(self: *Document) ![]u8
```

#### `renderPageCommands`

Render deferred commands to page content bytes
Called after subsetting so glyph IDs are properly remapped

```zig
pub fn renderPageCommands(self: *Document, page: *Page) !void
```

#### `setCharSpacing`

Set character spacing (extra space between characters, in points)

```zig
pub fn setCharSpacing(self: *Document, spacing: f64) void
```

#### `setDashPattern`

Set dash pattern for stroked lines.

```zig
pub fn setDashPattern(self: *Document, dash: f64, gap: f64, phase: f64) void
```

#### `setDrawColor`

Set draw/stroke color (for lines and borders).

```zig
pub fn setDrawColor(self: *Document, c: Color) void
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

#### `setFillColor`

Set fill color (for shapes and backgrounds).

```zig
pub fn setFillColor(self: *Document, c: Color) void
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

#### `setLineCap`

Set line cap style.

```zig
pub fn setLineCap(self: *Document, cap: LineCap) void
```

#### `setLineHeight`

Set line height (as multiple of font size, e.g. 1.2 = 120%)

```zig
pub fn setLineHeight(self: *Document, height: f64) void
```

#### `setLineJoin`

Set line join style.

```zig
pub fn setLineJoin(self: *Document, join: LineJoin) void
```

#### `setLineWidth`

Set line width for strokes (in points).

```zig
pub fn setLineWidth(self: *Document, width: f64) void
```

#### `setMargins`

Set document margins.

```zig
pub fn setMargins(self: *Document, m: Margins) void
```

#### `setSolidLine`

Reset to solid line (no dashing).

```zig
pub fn setSolidLine(self: *Document) void
```

#### `setTextColor`

Set text color.

```zig
pub fn setTextColor(self: *Document, c: Color) void
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

Write text with automatic pagination.
Creates new pages as needed to fit all text.

```zig
pub fn writeFlow(self: *Document, text: []const u8, opts: FlowOptions) !usize
```

#### `writeLine`

Writes a single line of text into a region.
Does not wrap text. Advances the region cursor by one line height.

```zig
pub fn writeLine(self: *Document, region: *Region, str: []const u8, opts: LineOptions) !WriteResult
```

#### `writeParagraph`

Writes wrapped text into a region.
Supports word wrapping, soft-hyphen breaking, and optional hyphenated word breaking.

```zig
pub fn writeParagraph(self: *Document, region: *Region, str: []const u8, opts: ParagraphOptions) !WriteResult
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

### `Align`

```zig
pub const Align = layout.Align;
```

### `Border`

```zig
pub const Border = layout.Border;
```

### `Color`

```zig
pub const Color = color.Color;
```

### `DashPattern`

```zig
pub const DashPattern = layout.DashPattern;
```

### `DrawStyle`

```zig
pub const DrawStyle = layout.DrawStyle;
```

### `EmbeddedFont`

```zig
pub const EmbeddedFont = embedded.EmbeddedFont;
```

### `FlowOptions`

```zig
pub const FlowOptions = layout.FlowOptions;
```

### `Font`

```zig
pub const Font = fonts.Font;
```

### `FontMetrics`

```zig
pub const FontMetrics = metrics.FontMetrics;
```

### `LineBreaking`

```zig
pub const LineBreaking = layout.LineBreaking;
```

### `LineCap`

```zig
pub const LineCap = layout.LineCap;
```

### `LineJoin`

```zig
pub const LineJoin = layout.LineJoin;
```

### `LineOptions`

```zig
pub const LineOptions = layout.LineOptions;
```

### `Margins`

```zig
pub const Margins = layout.Margins;
```

### `Padding`

```zig
pub const Padding = layout.Padding;
```

### `PageSize`

```zig
pub const PageSize = layout.PageSize;
```

### `ParagraphOptions`

```zig
pub const ParagraphOptions = layout.ParagraphOptions;
```

### `Region`

```zig
pub const Region = layout.Region;
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

### `VAlign`

```zig
pub const VAlign = layout.VAlign;
```

### `WriteResult`

```zig
pub const WriteResult = layout.WriteResult;
```

### `opentype`

```zig
pub const opentype = embedded.opentype;
```

