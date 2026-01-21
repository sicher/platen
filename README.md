# zpdf

A fast PDF rendering library for Zig, inspired by [fpdf2](https://github.com/py-pdf/fpdf2).

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

// Write wrapped text (returns overflow if text doesn't fit)
const result = try doc.writeParagraph(&region, text, .{
    .alignment = .justify,
    .first_indent = 20,
});

if (result.overflow) |remaining| {
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
    _ = try doc.writeParagraph(&region, text, .{});
}
```

### Drawing Shapes

```zig
try doc.addPage();

// Set colors
doc.setDrawColor(zpdf.Color.fromRgb(0, 0, 0));      // black stroke
doc.setFillColor(zpdf.Color.fromRgb(0.9, 0.9, 0.9)); // light gray fill

// Line
try doc.drawLine(50, 100, 200, 100);

// Rectangle (stroke, fill, or fill_stroke)
try doc.drawRect(50, 120, 100, 50, .fill_stroke);

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
linear.addStop(0.0, zpdf.Color.fromRgb(1, 0, 0));     // red
linear.addStop(1.0, zpdf.Color.fromRgb(0, 0, 1));     // blue
try doc.drawLinearGradient(&linear, 50, 50, 200, 100);

// Radial gradient
var radial = zpdf.RadialGradient.init(100, 100, 50);  // center, radius
radial.addStop(0.0, zpdf.Color.fromRgb(1, 1, 0));     // yellow center
radial.addStop(1.0, zpdf.Color.fromRgb(1, 0, 0));     // red edge
try doc.drawRadialGradient(&radial, 50, 200, 100, 100);
```

### Multi-Page Documents

```zig
try doc.addPage();
try doc.writeAt(50, 50, "Page 1");

try doc.addPage();
try doc.writeAt(50, 50, "Page 2");

try doc.addPage(.{ .width = 842, .height = 595 });  // landscape A4
try doc.writeAt(50, 50, "Page 3 (landscape)");
```

## API Reference

### Document

| Method | Description |
|--------|-------------|
| `init(allocator)` | Create new document |
| `deinit()` | Free resources |
| `addPage()` | Add A4 page |
| `addPage(size)` | Add page with custom size |
| `output()` | Generate PDF bytes |
| `setFont(font, size)` | Set standard font |
| `setEmbeddedFont(font, size)` | Set custom font |
| `loadFont(path)` | Load TTF/OTF font |
| `loadImage(path)` | Load JPEG/PNG image |
| `loadSvg(path)` | Load SVG file |

### Text

| Method | Description |
|--------|-------------|
| `write(str)` | Write at cursor |
| `writeAt(x, y, str)` | Write at position |
| `writeLine(&region, str, opts)` | Single line in region |
| `writeParagraph(&region, str, opts)` | Wrapped text |
| `writeFlow(str, opts)` | Auto-paginating text |
| `measureWrappedText(str, opts)` | Measure without rendering |
| `getTextWidth(str)` | Measure text width |

### Graphics

| Method | Description |
|--------|-------------|
| `drawLine(x1, y1, x2, y2)` | Draw line |
| `drawRect(x, y, w, h, style)` | Draw rectangle |
| `drawCircle(x, y, r, style)` | Draw circle |
| `drawEllipse(x, y, w, h, style)` | Draw ellipse |
| `drawPolygon(points, style)` | Draw polygon |
| `drawPath(&path, style)` | Draw custom path |
| `drawImage(img, x, y, w, h)` | Draw image |
| `drawSvg(svg, x, y, w, h)` | Draw SVG |
| `drawLinearGradient(...)` | Draw linear gradient |
| `drawRadialGradient(...)` | Draw radial gradient |

### Styling

| Method | Description |
|--------|-------------|
| `setDrawColor(color)` | Stroke color |
| `setFillColor(color)` | Fill color |
| `setTextColor(color)` | Text color |
| `setLineWidth(width)` | Line thickness |
| `setLineCap(cap)` | Line end style |
| `setLineJoin(join)` | Line corner style |
| `setDashPattern(dash, gap, phase)` | Dashed lines |

## Requirements

- Zig 0.15+
- No external dependencies (zlib bundled)

## License

MIT
