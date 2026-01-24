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

```zig
const metrics = doc.measureWrappedText(text, .{
    .width = 200,
    .first_indent = 20,
});

// metrics.height     - total height needed
// metrics.line_count - number of lines
// metrics.max_line_width - widest line

if (metrics.fitsInHeight(region.remainingHeight())) {
    var st = doc.createStyledText();
    defer st.deinit();
    try st.append(text, .{});
    _ = try doc.writeStyled(&region, &st, .{});
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

// Set drawing style (stroke color, fill color, line width, etc.)
doc.setDrawStyle(.{
    .stroke_color = zpdf.Color.black,
    .fill_color = zpdf.Color.lightgray,
    .line_width = 1.5,
});

// Line
try doc.drawLine(50, 100, 200, 100);

// Rectangle (stroke, fill, or fill_stroke)
try doc.drawRect(50, 120, 100, 50, .fill_stroke);

// Rounded rectangle
try doc.drawRoundedRect(50, 180, 100, 50, 10, .fill_stroke);

// Circle
try doc.drawCircle(200, 200, 30, .fill);

// Polygon
const points = [_]zpdf.Point{
    .{ .x = 300, .y = 150 },
    .{ .x = 350, .y = 200 },
    .{ .x = 250, .y = 200 },
};
try doc.drawPolygon(&points, .fill_stroke);
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

try doc.drawPath(&path, .fill_stroke);
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
// Linear gradient
var linear = zpdf.LinearGradient.init(0, 0, 200, 0);  // left to right
linear.addStop(0.0, zpdf.Color.rgb(255, 0, 0));       // red
linear.addStop(1.0, zpdf.Color.rgb(0, 0, 255));       // blue
try doc.drawLinearGradient(&linear, 50, 50, 200, 100);

// Radial gradient
var radial = zpdf.RadialGradient.init(100, 100, 50);  // center, radius
radial.addStop(0.0, zpdf.Color.rgb(255, 255, 0));     // yellow center
radial.addStop(1.0, zpdf.Color.rgb(255, 0, 0));       // red edge
try doc.drawRadialGradient(&radial, 50, 200, 100, 100);
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

### Core

| Method | Description |
|--------|-------------|
| `deinit()` | Free all document resources |
| `init(allocator) -> Document` | Create a new PDF document |
| `output() -> []u8` | Generate PDF output |

### Document

| Method | Description |
|--------|-------------|
| `addPage()` | Add a new page using the current page size (set via setPageSize, default A4) |
| `getPageRegion() -> Region` | Returns a region for the current page respecting document margins |
| `pageNo() -> usize` | Get current page number (1-based) |
| `setMargins(Margins)` | Set document margins |
| `setMetadata(DocumentMetadata)` | Set document metadata (title, author, subject, etc.) |
| `setPageSize(PageSize)` | Set the page size for subsequent addPage() calls |

### Fonts

| Method | Description |
|--------|-------------|
| `getFontMetrics() -> FontMetrics` | Get font metrics for the current font, scaled to the current font size |
| `getTextStyle() -> TextStyle` | Get current text style for measurement |
| `loadFont(str) -> *EmbeddedFont` | Load a TrueType font from file |
| `setEmbeddedFont(*EmbeddedFont, f64)` | Set an embedded font as current |
| `setFeature(Feature, bool)` | Set OpenType feature for all embedded fonts |
| `setFont(StandardFont, f64)` | Set the current font and size (standard font) |
| `setFontFeature(*EmbeddedFont, Feature, bool)` | Set OpenType feature for a specific embedded font |

### Text

| Method | Description |
|--------|-------------|
| `drawRegion(Region)` | Draws a region's border and fill (without text) |
| `getTextWidth(str) -> f64` | Measures text width using current font (standard or embedded) |
| `measureText(str) -> TextMetrics` | Measure text dimensions without rendering |
| `measureTextWidth(str) -> f64` | Measure text width in points |
| `measureWrappedText(str, MeasureOptions) -> WrappedTextMetrics` | Measures how wrapped text would be laid out without rendering |
| `write(*Region, str, WriteOptions) -> WriteResult` | Writes flowing text into a region with word wrapping |
| `writeAt(f64, f64, str) -> Rect` | Writes text at the specified position |
| `writeFlow(str, FlowOptions) -> usize` | Write text with automatic pagination |
| `writeStyled(*Region, *StyledText, ParagraphOptions) -> WriteResult` | Writes styled text into a region with word wrapping |

### Text Styling

| Method | Description |
|--------|-------------|
| `getLineHeightPts() -> f64` | Get current line height in points |
| `setCharSpacing(f64)` | Set character spacing (extra space between characters, in points) |
| `setLineHeight(f64)` | Set line height (as multiple of font size, e.g. 1.2 = 120%) |
| `setTextColor(Color)` | Set text color |
| `setTextStyle(TextStyleOptions)` | Set text style (color and decoration) |

### Cursor Position

| Method | Description |
|--------|-------------|
| `getPosition() -> Point` | Get cursor position (in points from top-left) |
| `setPosition(Point)` | Set cursor position (in points from top-left) |

### Navigation

| Method | Description |
|--------|-------------|
| `addExternalLink(Rect, str)` | Add an external link (clickable area that opens a URL) |
| `addLink(Rect, Destination)` | Add an internal link (clickable area that jumps to another page position) |
| `addOutlineItem(str, Destination, ?*Outline) -> *Outline` | Adds an outline item to the document (shown in PDF viewer's table of contents) |
| `currentDestination() -> ?Destination` | Get a destination for the current cursor position |
| `setPageLabel(usize, PageLabel)` | Sets a page label range starting at the specified page index |

### Images & SVG

| Method | Description |
|--------|-------------|
| `drawImage(*Image, f64, f64, f64, f64)` | Draw an image at the specified position |
| `drawSvg(*Svg, f64, f64, f64, f64)` | Draw an SVG at the specified position |
| `loadImage(str) -> *Image` | Load an image from file (JPEG or PNG) |
| `loadSvg(str) -> *Svg` | Load an SVG from file |

### Graphics

| Method | Description |
|--------|-------------|
| `createPath() -> Path` | Create a new path builder |
| `drawCircle(f64, f64, f64, DrawStyle)` | Draw a circle (special case of ellipse) |
| `drawEllipse(f64, f64, f64, f64, DrawStyle)` | Draw an ellipse using 4 cubic Bezier curves |
| `drawLine(f64, f64, f64, f64)` | Draw a line between two points |
| `drawPath(*Path, DrawStyle)` | Draw a path with the specified style |
| `drawPolygon([]const Point, DrawStyle)` | Draw a closed polygon |
| `drawRect(f64, f64, f64, f64, DrawStyle)` | Draw a rectangle |
| `drawRoundedRect(f64, f64, f64, f64, f64, DrawStyle)` | Draw a rectangle with rounded corners |
| `setDrawStyle(DrawStyleOptions)` | Set drawing style (stroke/fill colors, line width, cap, join, dash pattern) |

### Gradients

| Method | Description |
|--------|-------------|
| `addLinearGradient(LinearGradient) -> usize` | Add a linear gradient to the document and return its index |
| `addRadialGradient(RadialGradient) -> usize` | Add a radial gradient to the document and return its index |
| `fillRectGradient(f64, f64, f64, f64, usize)` | Fill a rectangle with a gradient |


## Requirements

- Zig 0.15+
- No external dependencies (zlib bundled)

## License

MIT
