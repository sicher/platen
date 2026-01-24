# zpdf

A fast PDF rendering library for Zig.

## Features

- **Text rendering** with standard PDF fonts (Helvetica, Times, Courier, Symbol, ZapfDingbats)
- **TrueType/OpenType font embedding** with automatic subsetting
- **Full Unicode support** via CID fonts (CJK, emoji, etc.)
- **OpenType features**: ligatures, kerning, mark positioning (diacritics)
- **Text flow**: word wrapping, justified text, Knuth-Plass optimal line breaking
- **Graphics**: lines, rectangles, circles, ellipses, polygons
- **Path API**: moveTo, lineTo, curveTo, quadTo for custom shapes
- **Images**: JPEG and PNG embedding (with alpha channel support)
- **SVG embedding**: shapes, paths, text, gradients, transforms, `<use>`/`<defs>`
- **Gradients**: linear and radial
- **Document metadata**: title, author, subject, keywords
- **Links**: internal (TOC navigation) and external (URLs)
- **Compression**: FlateDecode for smaller file sizes

## Quick Start

```zig
const std = @import("std");
const zpdf = @import("zpdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create document
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    // Add a page and write text
    try doc.addPage();
    try doc.setFont(.helvetica, 24);
    try doc.writeAt(50, 50, "Hello, World!");

    // Save to file
    const pdf_data = try doc.output();
    defer allocator.free(pdf_data);

    const file = try std.fs.cwd().createFile("hello.pdf", .{});
    defer file.close();
    try file.writeAll(pdf_data);
}
```

## Installation

Add zpdf as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .zpdf = .{
        .url = "https://codeberg.org/sicher/zpdf/archive/main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zpdf_dep = b.dependency("zpdf", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zpdf", zpdf_dep.module("zpdf"));
```

Or clone and build directly:

```bash
git clone https://codeberg.org/sicher/zpdf.git
cd zpdf
zig build        # Build CLI tool
zig build test   # Run tests
```

## Usage Examples

### Text with Multiple Fonts

```zig
try doc.addPage();

try doc.setFont(.helvetica_bold, 16);
try doc.writeAt(50, 50, "Title");

try doc.setFont(.times_roman, 12);
try doc.writeAt(50, 80, "Body text in Times Roman");

try doc.setFont(.courier, 10);
try doc.writeAt(50, 100, "Monospace code");
```

### Custom Fonts (TrueType/OpenType)

```zig
// Load a TTF or OTF font
const font = try doc.loadFont("fonts/MyFont.ttf");

// For full Unicode support (recommended)
font.encoding = .identity;

try doc.addPage();
try doc.setEmbeddedFont(font, 14);
try doc.writeAt(50, 50, "Custom font with Unicode: ");
```

### Text Flow with Word Wrapping

```zig
try doc.addPage();
try doc.setFont(.helvetica, 11);

// Define a region for text
var region = zpdf.Region{
    .x = 72,
    .y = 72,
    .width = 468,  // page width minus margins
    .height = 700,
};

const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit...";

// Create styled text and write with word wrapping
var st = doc.createStyledText();
defer st.deinit();
try st.append(text, .{});

const result = try doc.writeStyled(&region, &st, .{
    .alignment = .justify,
});

if (result.overflow) |_| {
    // Handle text that didn't fit
    try doc.addPage();
    // ... continue with remaining text
}
```

### Measure Text Before Rendering

Use `write()` or `writeStyled()` with `.measure_only = true` to measure without rendering.
Measurement is side-effect free - the region's cursor is unchanged after the call.

```zig
var region = zpdf.Region{
    .x = 50,
    .y = 100,
    .width = 200,
    .height = 10000, // Large height for measurement
    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
};

// Measure plain text (cursor unchanged after this call)
const result = try doc.write(&region, text, .{ .measure_only = true });

// Or measure styled text
var styled = doc.createStyledText();
try styled.append("Hello ", .{});
try styled.append("World", .{ .color = zpdf.Color.blue });
const styled_result = try doc.writeStyled(&region, &styled, .{ .measure_only = true });

// Calculate height from lines_written
const line_height = doc.getLineHeightPts();
const content_height = @as(f64, @floatFromInt(result.lines_written)) * line_height;
const box_height = content_height + 16; // Add padding

// Render (no need to reset cursor - measure_only didn't change it)
if (box_height <= region.remainingHeight()) {
    _ = try doc.write(&region, text, .{});
}
```

### Colors

```zig
// Named color presets
const color1 = zpdf.Color.red;
const color2 = zpdf.Color.navy;
const color3 = zpdf.Color.coral;

// From RGB (0-255 range) - the common case
const color4 = zpdf.Color.rgb(128, 64, 192);

// From RGB floats (0.0-1.0 range)
const color5 = zpdf.Color.rgbf(0.5, 0.25, 0.75);

// From hex string
const color6 = zpdf.Color.hex("#FF6600").?;
const color7 = zpdf.Color.hex("F60").?;  // short form

// Greyscale (0 = black, 1 = white)
const color8 = zpdf.Color.greyscale(0.5);

// CMYK for print
const color9 = zpdf.Color.cmyk(1, 0, 0, 0);  // cyan
```

Available presets: `black`, `white`, `red`, `green`, `blue`, `cyan`, `magenta`, `yellow`, `orange`, `pink`, `purple`, `brown`, `navy`, `teal`, `coral`, `salmon`, `gold`, `silver`, `maroon`, `olive`, `lime`, `indigo`, `violet`, `turquoise`, `skyblue`, `forestgreen`, and many more.

### Drawing Shapes

```zig
try doc.addPage();

// Line with explicit style
try doc.drawLine(
    .{ .x = 50, .y = 100 },
    .{ .x = 200, .y = 100 },
    .{ .color = zpdf.Color.black, .width = 1.5 },
);

// Rectangle with stroke and fill
try doc.drawRect(
    .{ .x = 50, .y = 120, .width = 100, .height = 50 },
    .{
        .stroke = .{ .color = zpdf.Color.black },
        .fill = .{ .color = zpdf.Color.lightgray },
    },
);

// Rounded rectangle (stroke only)
try doc.drawRoundedRect(
    .{ .x = 50, .y = 180, .width = 100, .height = 50 },
    10,  // corner radius
    .{ .stroke = .{ .color = zpdf.Color.blue, .width = 2 } },
);

// Circle (fill only)
try doc.drawCircle(.{ .x = 200, .y = 200 }, 30, .{ .fill = .{ .color = zpdf.Color.red } });

// Polygon
const points = [_]zpdf.Point{
    .{ .x = 300, .y = 150 },
    .{ .x = 350, .y = 200 },
    .{ .x = 250, .y = 200 },
};
try doc.drawPolygon(&points, .{ .stroke = .{}, .fill = .{} });
```

### Path API

```zig
// Create a custom path
var path = doc.createPath();
defer path.deinit();

try path.moveTo(100, 100);
try path.lineTo(200, 100);
try path.curveTo(250, 100, 250, 200, 200, 200);  // cubic bezier
try path.lineTo(100, 200);
try path.closePath();

try doc.drawPath(&path, .{
    .stroke = .{ .color = zpdf.Color.blue },
    .fill = .{ .color = zpdf.Color.lightblue },
});
```

### Images

```zig
// Load JPEG or PNG
const img = try doc.loadImage("photo.jpg");

try doc.addPage();

// Draw at position with explicit size
try doc.drawImage(img, 50, 50, 200, 150);

// Auto aspect ratio (specify 0 for width or height)
try doc.drawImage(img, 50, 250, 200, 0);  // width=200, height auto
```

### SVG Embedding

```zig
// Load SVG file
const svg = try doc.loadSvg("diagram.svg");

try doc.addPage();

// Draw at position (original size if w=0, h=0)
try doc.drawSvg(svg, 50, 50, 0, 0);

// Scaled
try doc.drawSvg(svg, 300, 50, 150, 150);
```

### Gradients

```zig
// Define color stops
const stops = [_]zpdf.ColorStop{
    .{ .offset = 0.0, .color = zpdf.Color.red },
    .{ .offset = 1.0, .color = zpdf.Color.blue },
};

// Linear gradient (from point to point)
const linear = zpdf.LinearGradient{
    .x0 = 50, .y0 = 50,    // start point
    .x1 = 250, .y1 = 50,   // end point
    .stops = &stops,
};
const linear_idx = try doc.addLinearGradient(linear);
try doc.fillRectGradient(50, 50, 200, 100, linear_idx);

// Radial gradient (from inner circle to outer circle)
const radial_stops = [_]zpdf.ColorStop{
    .{ .offset = 0.0, .color = zpdf.Color.yellow },
    .{ .offset = 1.0, .color = zpdf.Color.red },
};
const radial = zpdf.RadialGradient{
    .x0 = 150, .y0 = 250, .r0 = 0,    // inner circle (center, radius 0)
    .x1 = 150, .y1 = 250, .r1 = 50,   // outer circle (same center, radius 50)
    .stops = &radial_stops,
};
const radial_idx = try doc.addRadialGradient(radial);
try doc.fillRectGradient(100, 200, 100, 100, radial_idx);
```

### Page Sizes

```zig
// Available sizes: A3, A4, A5, Letter, Legal, Tabloid
// Default is A4

// Set page size for subsequent pages
doc.setPageSize(zpdf.PageSize.Letter);

try doc.addPage();  // Letter
try doc.addPage();  // Letter

// Change to a different size
doc.setPageSize(zpdf.PageSize.A4);
try doc.addPage();  // A4

// Landscape orientation
doc.setPageSize(zpdf.PageSize.Letter.landscape());
try doc.addPage();

// Custom size
doc.setPageSize(.{ .width = 500, .height = 700 });
try doc.addPage();
```

### Document Metadata

```zig
// Set document properties (all fields optional)
doc.setMetadata(.{
    .title = "Annual Report 2026",
    .author = "Finance Department",
    .subject = "Q4 Financial Results",
    .keywords = "finance, report, 2026, quarterly",
    .creator = "MyApp v1.0",
    // .producer defaults to "zpdf"
    // .creation_date and .mod_date auto-generated if not set
});
```

### Links

```zig
try doc.addPage();
try doc.setFont(.helvetica, 12);

// Write text and get its bounding rectangle
const rect = try doc.writeAt(50, 50, "Click here for Zig documentation");

// Add external link (URL)
try doc.addExternalLink(rect, "https://ziglang.org/documentation/");

// Internal links for TOC navigation
try doc.setFont(.helvetica_bold, 16);
_ = try doc.writeAt(50, 100, "Chapter 1: Introduction");
const chapter1_dest = doc.currentDestination();  // save this location

// Later, create a link to that chapter
try doc.addPage();
try doc.setFont(.helvetica, 12);
const toc_rect = try doc.writeAt(50, 50, "Go to Chapter 1");
try doc.addLink(toc_rect, chapter1_dest);
```

## API Reference

### Document Lifecycle

| Method | Description |
|--------|-------------|
| `Document.init(allocator)` | Create a new PDF document |
| `deinit()` | Free all document resources |
| `output() -> []u8` | Generate PDF output as bytes |

### Pages & Layout

| Method | Description |
|--------|-------------|
| `addPage()` | Add a new page (uses current page size, default A4) |
| `setPageSize(PageSize)` | Set page size for subsequent pages |
| `setMargins(Margins)` | Set document margins |
| `getPageRegion() -> Region` | Get drawable region respecting margins |
| `pageNo() -> usize` | Get current page number (1-based) |
| `setMetadata(DocumentMetadata)` | Set title, author, subject, keywords, etc. |

### Fonts

| Method | Description |
|--------|-------------|
| `setFont(StandardFont, size)` | Set standard font (Helvetica, Times, Courier, etc.) |
| `loadFont(path) -> *EmbeddedFont` | Load TTF/OTF font from file |
| `setEmbeddedFont(*EmbeddedFont, size)` | Set embedded font as current |
| `setFeature(Feature, bool)` | Enable/disable OpenType feature globally |
| `setFontFeature(*EmbeddedFont, Feature, bool)` | Enable/disable feature for specific font |
| `getFontMetrics() -> FontMetrics` | Get metrics (ascender, descender, etc.) for current font |
| `getFontStyle() -> FontStyle` | Get current font style info |

### Text Output

| Method | Description |
|--------|-------------|
| `writeAt(x, y, str) -> Rect` | Write text at position, returns bounding rect |
| `write(*Region, str, WriteOptions) -> WriteResult` | Write with word wrapping into region |
| `writeStyled(*Region, *StyledText, ParagraphOptions) -> WriteResult` | Write styled text with wrapping |
| `createStyledText() -> StyledText` | Create styled text builder for mixed formatting |

### Text Measurement

| Method | Description |
|--------|-------------|
| `getTextWidth(str) -> f64` | Measure text width in points |
| `measureText(str) -> TextMetrics` | Get width and height |
| `write(*Region, str, .{ .measure_only = true })` | Measure plain text layout without rendering |
| `writeStyled(*Region, *StyledText, .{ .measure_only = true })` | Measure styled text layout without rendering |

### Text Styling

| Method | Description |
|--------|-------------|
| `setTextColor(Color)` | Set text color |
| `setTextStyle(TextStyleOptions)` | Set color and decoration (underline, strikethrough) |
| `setCharSpacing(f64)` | Set extra space between characters (points) |
| `setLineHeight(f64)` | Set line height multiplier (e.g., 1.2 = 120%) |
| `getLineHeightPts() -> f64` | Get current line height in points |

### Cursor & Position

| Method | Description |
|--------|-------------|
| `setPosition(Point)` | Set cursor position (top-left origin) |
| `getPosition() -> Point` | Get cursor position |

### Navigation & Links

| Method | Description |
|--------|-------------|
| `currentDestination() -> ?Destination` | Get destination for current position |
| `addLink(Rect, Destination)` | Add internal link (jumps to page/position) |
| `addExternalLink(Rect, url)` | Add external link (opens URL) |
| `addOutlineItem(title, Destination, ?parent) -> *Outline` | Add to table of contents |
| `setPageLabel(page_index, PageLabel)` | Set page numbering style |

### Images & SVG

| Method | Description |
|--------|-------------|
| `loadImage(path) -> *Image` | Load JPEG or PNG image |
| `drawImage(*Image, x, y, w, h)` | Draw image (use 0 for w or h to auto-scale) |
| `loadSvg(path) -> *Svg` | Load SVG file |
| `drawSvg(*Svg, x, y, w, h)` | Draw SVG (use 0, 0 for original size) |

### Drawing Shapes

| Method | Description |
|--------|-------------|
| `drawLine(Point, Point, StrokeStyle)` | Draw a line |
| `drawRect(Rect, ShapeStyle)` | Draw rectangle |
| `drawRoundedRect(Rect, radius, ShapeStyle)` | Draw rounded rectangle |
| `drawCircle(Point, radius, ShapeStyle)` | Draw circle (center + radius) |
| `drawEllipse(Rect, ShapeStyle)` | Draw ellipse (bounding box) |
| `drawPolygon([]Point, ShapeStyle)` | Draw closed polygon |
| `drawRegion(Region)` | Draw region border and background |

**Style types:**
- `StrokeStyle` - color, width, cap, join, dash
- `FillStyle` - color
- `ShapeStyle` - optional stroke + optional fill

### Path API

| Method | Description |
|--------|-------------|
| `createPath() -> Path` | Create path builder |
| `drawPath(*Path, ShapeStyle)` | Render path |

**Path methods:**
| Method | Description |
|--------|-------------|
| `moveTo(x, y)` | Move without drawing |
| `lineTo(x, y)` | Line to point |
| `curveTo(x1, y1, x2, y2, x, y)` | Cubic Bezier curve |
| `quadTo(x1, y1, x, y)` | Quadratic Bezier curve |
| `closePath()` | Close subpath |
| `deinit()` | Free path resources |

### Gradients

| Method | Description |
|--------|-------------|
| `addLinearGradient(LinearGradient) -> usize` | Register linear gradient |
| `addRadialGradient(RadialGradient) -> usize` | Register radial gradient |
| `fillRectGradient(x, y, w, h, gradient_idx)` | Fill rect with gradient |

### StyledText Builder

Create with `doc.createStyledText()`, then:

| Method | Description |
|--------|-------------|
| `append(text, TextStyleOptions)` | Add text span with style |
| `appendOwned(text, TextStyleOptions)` | Add text span (takes ownership) |
| `isEmpty() -> bool` | Check if empty |
| `totalLength() -> usize` | Get total text length |
| `deinit()` | Free resources |

### Unit Conversions

All measurements in zpdf are in points (1 pt = 1/72 inch).

```zig
const x = zpdf.inches(1.5);  // 108 points
const y = zpdf.mm(25.4);     // 72 points (1 inch)
const z = zpdf.cm(2.54);     // 72 points (1 inch)

// Constants
zpdf.pt_per_inch  // 72.0
zpdf.pt_per_mm    // 2.834...
zpdf.pt_per_cm    // 28.34...
```

### Types Reference

**Page & Layout:**
- `PageSize` - Predefined sizes: `.A3`, `.A4`, `.A5`, `.Letter`, `.Legal`, `.Tabloid` (use `.landscape()` for landscape)
- `Region` - Drawable area with position, size, and remaining height tracking
- `Rect` - Simple rectangle (x, y, width, height)
- `Point` - 2D point (x, y)
- `Margins` / `Padding` - Edge spacing (top, right, bottom, left)

**Text:**
- `Align` - Horizontal: `.left`, `.center`, `.right`, `.justify`
- `VAlign` - Vertical: `.top`, `.middle`, `.bottom`
- `TextDecoration` - `.none`, `.underline`, `.strikethrough`, `.underline_strikethrough`
- `LineBreaking` - `.greedy` (fast) or `.optimal` (Knuth-Plass for justified text)
- `WriteOptions` / `ParagraphOptions` - Text layout options
- `WriteResult` - Result with lines_written, overflow text, and bounding rect
- `TextMetrics` / `FontMetrics` - Measurement results

**Fonts:**
- `StandardFont` - `.helvetica`, `.helvetica_bold`, `.helvetica_italic`, `.helvetica_bold_italic`, `.times_roman`, `.times_bold`, `.times_italic`, `.times_bold_italic`, `.courier`, `.courier_bold`, `.courier_italic`, `.courier_bold_italic`, `.symbol`, `.zapfdingbats`
- `EmbeddedFont` - Loaded TTF/OTF font (set `.encoding = .identity` for Unicode)

**Graphics:**
- `StrokeStyle` - Stroke settings (color, width, cap, join, dash)
- `FillStyle` - Fill settings (color)
- `ShapeStyle` - Combined stroke and/or fill (`.{ .stroke = .{} }`, `.{ .fill = .{} }`, `.{ .stroke = .{}, .fill = .{} }`)
- `LineCap` - `.butt`, `.round`, `.square`
- `LineJoin` - `.miter`, `.round`, `.bevel`
- `DashPattern` - Line dash pattern (dash, gap, phase)
- `Point` - 2D point (x, y coordinates)
- `Rect` - Rectangle (x, y, width, height)
- `Color` - RGB/CMYK/grayscale color (see Colors section)

**Gradients:**
- `LinearGradient` - Axial gradient between two points
- `RadialGradient` - Circular gradient between two circles
- `ColorStop` - Color at position (offset 0.0-1.0, color)

**Navigation:**
- `Destination` - Page location for internal links
- `Outline` - Table of contents entry
- `PageLabel` / `PageLabelStyle` - Page numbering (roman, arabic, etc.)

**OpenType Features:**
```zig
// Available via zpdf.opentype.Feature
.kern    // Kerning
.liga    // Standard ligatures (fi, fl, etc.)
.calt    // Contextual alternates
.smcp    // Small caps
.onum    // Old-style numerals
.lnum    // Lining numerals
.tnum    // Tabular numerals
.pnum    // Proportional numerals
// ... and more
```

## Requirements

- Zig 0.15+
- No external dependencies (zlib bundled)

## License

MIT
