# layout

Layout types for zpdf - regions, alignment, margins, and page sizes.

## Enums

### `Align`

Horizontal text alignment.

```zig
pub const Align = enum {
    left,
    center,
    right,
    justify,
}
```

### `DrawStyle`

Drawing style for shapes.

```zig
pub const DrawStyle = enum {
    /// Only stroke the outline (S operator).
    stroke,
    /// Only fill the interior (f operator).
    fill,
    /// Fill and stroke (B operator).
    fill_stroke,
}
```

| Variant | Description |
|---------|-------------|
| `fill` | Only fill the interior (f operator). |
| `fill_stroke` | Fill and stroke (B operator). |
| `stroke` | Only stroke the outline (S operator). |

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

### `LineCap`

Line cap style (PDF J operator).

```zig
pub const LineCap = enum(u8) {
    /// Butt cap: line ends at endpoint.
    butt = 0,
    /// Round cap: semicircle at endpoint.
    round = 1,
    /// Square cap: half-width square at endpoint.
    square = 2,
}
```

### `LineJoin`

Line join style (PDF j operator).

```zig
pub const LineJoin = enum(u8) {
    /// Miter join: sharp corner.
    miter = 0,
    /// Round join: circular arc at corner.
    round = 1,
    /// Bevel join: diagonal cut at corner.
    bevel = 2,
}
```

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

### `DashPattern`

Dash pattern for stroked lines (PDF d operator).

```zig
pub const DashPattern = struct {
    /// Length of dash in points (0 = solid line).
    dash: f64 = 0,
    /// Length of gap in points.
    gap: f64 = 0,
    /// Phase offset in points.
    phase: f64 = 0,

    /// Solid line (no dashing).
    pub const solid = DashPattern{};
}
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

## Constants

### `Color`

```zig
pub const Color = color.Color;
```

### `TextMetrics`

```zig
pub const TextMetrics = metrics.TextMetrics;
```

