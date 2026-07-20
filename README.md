<p align="center">
  <img src="platen.svg" alt="platen" width="480">
</p>

A fast, self-contained PDF generation library written in Zig. Supports text layout, TrueType/OpenType font embedding, color emoji fonts, images, vector graphics, and PDF/A archival output. Pure Zig — no dependencies at all.

## Features

- **Text rendering** with standard PDF fonts (Helvetica, Times, Courier, Symbol, ZapfDingbats)
- **TrueType/OpenType font embedding** with automatic subsetting
- **Full Unicode support** via CID fonts (CJK, emoji, etc.)
- **OpenType features**: ligatures, kerning, mark positioning, stylistic sets, character variants, and more
- **Color fonts**: COLR v0/v1 (layered, gradients, sweep gradients), sbix/CBDT/EBDT bitmap strikes, and OT-SVG — full color emoji support
- **Text flow**: word wrapping, justified text, Knuth-Plass optimal line breaking
- **Graphics**: lines, rectangles, circles, ellipses, polygons
- **Path API**: moveTo, lineTo, curveTo, quadTo for custom shapes
- **Images**: JPEG and PNG embedding (with alpha channel support)
- **SVG embedding**: shapes, paths, text, gradients, transforms, `<use>`/`<defs>`
- **Gradients**: linear and radial
- **Transparency**: fill/stroke opacity for shapes and fill opacity for text
- **Document metadata**: title, author, subject, keywords
- **Links**: internal (TOC navigation) and external (URLs)
- **PDF/A conformance**: PDF/A-1b and PDF/A-2b archival formats (VeraPDF validated)
- **Compression**: FlateDecode for smaller file sizes

## Performance

Two benchmarks on Apple Silicon (release build), measuring different workloads: one large document, and many small documents.

### One large document

110 pages in five 20-page sections — simple text, OpenType shaping (ligatures/kerning), Unicode with diacritics, justified text flow, vector graphics (~1500 shapes/page) — plus 10 pages of color emoji. [See the generated document](examples/benchmark_110pages.pdf) (621 KB). Run it with `zig build perf -Doptimize=ReleaseFast`.

| Operation | Time |
|-----------|------|
| Font loading | <1ms |
| Simple text | 2ms |
| OpenType shaping | 12ms |
| Unicode/marks | 6ms |
| Text flow | 2ms |
| Drawing shapes | 13ms |
| Color emoji | 4ms |
| PDF output | 33ms |
| **Total** | **74ms** (~1500 pages/sec) |

Setting `doc.compress_threads = 8` compresses streams (page contents, font subsets) on worker threads during `output()`: PDF output drops to 19ms and the total to ~59ms on the same hardware, with byte-identical output. Requires a thread-safe allocator.

### Many small documents (invoice throughput)

1000 unique single-page A4 invoices, generated one complete PDF at a time (single-threaded): 3-10 line items each, embedded Inter regular + bold with full OpenType shaping, the platen wordmark as vector SVG, per-document font subsetting. [See a generated sample](examples/benchmark_invoice.pdf). Run it with `zig build bench-invoice -Doptimize=ReleaseFast`.

| Mode | Latency | Throughput |
|------|---------|------------|
| Uncompressed, 1 thread | 0.50ms | ~2000 PDFs/sec |
| Uncompressed, 8 threads | 0.11ms | ~9100 PDFs/sec |
| Compressed (level 1), 1 thread | 0.94ms | ~1060 PDFs/sec |

Every document pays the full stateless cost: fonts are re-parsed, shaped, and subset per PDF, and the SVG is re-parsed per PDF — there is no cross-document caching.

Because documents share no state, they can be rendered concurrently without locking — one `Document` per thread scales close to linearly across cores (`--threads=N` in the benchmark). A single `Document` is not thread-safe; keep each document on one thread.

See [PERFORMANCE.md](PERFORMANCE.md) for optimization details.

## Quick Start

```zig
const std = @import("std");
const platen = @import("platen");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Create document. `init.io` is used for any file I/O the document
    // performs (loadFont/loadImage/loadSvg). In tests, pass `std.testing.io`.
    var doc = platen.Document.init(allocator, init.io);
    defer doc.deinit();

    // Add a page and write text
    try doc.addPage(.{});
    const style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 24 };
    _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello, World!", style);

    // Save to file
    const pdf_data = try doc.output();
    defer allocator.free(pdf_data);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "hello.pdf", .data = pdf_data });
}
```

## Coordinates & anchoring

All coordinates are in points (1/72 inch) with the origin at the **top-left**
of the page, y growing downward. Anchoring differs by content type,
following typographic convention:

- **Text** (`writeAt`): `y` is the **baseline** of the text.
- **Shapes and images** (`drawRect`, `drawImage`, `drawSvg`, ...): `rect.y`
  is the **top edge**.
- **Regions** (`write`, `writeLine`, `writeStyled`): `y` is the top of the
  region; the baseline of the first line is placed from font metrics
  according to `valign`.

## Installation

Add platen as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .platen = .{
        .url = "https://codeberg.org/sicher/platen/archive/main.tar.gz",
        .hash = "...",
    },
},
```

Versioned release tags will return with 1.0.0; until then, track `main`.

Then in your `build.zig`:

```zig
const platen_dep = b.dependency("platen", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("platen", platen_dep.module("platen"));
```

Or clone and build directly:

```bash
git clone https://codeberg.org/sicher/platen.git
cd platen
zig build        # Build CLI tool
zig build test   # Run tests
```

## Usage Examples

### Text with Multiple Fonts

```zig
try doc.addPage(.{});

const title = platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true };
const body = platen.TextStyle{ .font = platen.Font.times, .size = 12 };
const code = platen.TextStyle{ .font = platen.Font.courier, .size = 10 };

_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Title", title);
_ = try doc.writeAt(.{ .x = 50, .y = 80 }, "Body text in Times Roman", body);
_ = try doc.writeAt(.{ .x = 50, .y = 100 }, "Monospace code", code);
```

### Custom Fonts (TrueType/OpenType)

```zig
// Load a TTF or OTF font (default: identity/Unicode encoding)
const font = try doc.loadFont("fonts/MyFont.ttf", .identity);

// Or specify encoding explicitly
const latin_font = try doc.loadFont("fonts/Latin.ttf", .win_ansi);

try doc.addPage(.{});
const style = platen.TextStyle{ .font = font, .size = 14 };
_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Custom font with Unicode: 日本語 🎉", style);
```

### Font Families (Bold/Italic Variants)

```zig
// Load a font family with all variants
const gentium = try doc.loadFontFamily(.{
    .regular = "fonts/Gentium-Regular.ttf",
    .bold = "fonts/Gentium-Bold.ttf",
    .italic = "fonts/Gentium-Italic.ttf",
    .bold_italic = "fonts/Gentium-BoldItalic.ttf",
});

try doc.addPage(.{});

// Use bold/italic flags - library selects correct variant automatically
const body = platen.TextStyle{ .font = gentium, .size = 12 };
const emphasis = platen.TextStyle{ .font = gentium, .size = 12, .italic = true };
const strong = platen.TextStyle{ .font = gentium, .size = 12, .bold = true };
const strong_emphasis = platen.TextStyle{ .font = gentium, .size = 12, .bold = true, .italic = true };

_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Regular text", body);
_ = try doc.writeAt(.{ .x = 50, .y = 70 }, "Italic text", emphasis);
_ = try doc.writeAt(.{ .x = 50, .y = 90 }, "Bold text", strong);
_ = try doc.writeAt(.{ .x = 50, .y = 110 }, "Bold italic text", strong_emphasis);
```

### Text Flow with Word Wrapping

```zig
try doc.addPage(.{});

// Define a region for text
var region = platen.Region{
    .x = 72,
    .y = 72,
    .width = 468,  // page width minus margins
    .height = 700,
};

const text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit...";
const style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 11 };

// Incremental text with word wrapping (cursor advances on same line)
const result = try doc.write(&region, text, style, .{});

if (result.overflow) |_| {
    // Handle text that didn't fit
    try doc.addPage(.{});
    // ... continue with remaining text
}

// Block-based text with alignment (cursor moves to next line)
_ = try doc.writeLine(&region, "Centered heading", style, .{ .alignment = .center });
_ = try doc.writeLine(&region, "Right-aligned text", style, .{ .alignment = .right });

// Styled text for mixed formatting within a paragraph
var st = doc.createStyledText();
defer st.deinit();
try st.append("Normal text ", .{});
try st.append("bold text ", .{ .bold = true });
try st.append("colored text", .{ .color = platen.Color.blue });

_ = try doc.writeStyled(&region, &st, style, .{ .alignment = .justify });
```

#### Optical Top Alignment

The default `.top` vertical alignment uses **cap-height optical alignment** — capital letters touch the top edge of the region, using real font metrics from the OS/2 table. This produces tighter, more visually precise layouts than the traditional half-leading approach.

```zig
// Default: cap-height aligned (capitals touch top edge)
_ = try doc.write(&region, text, style, .{ .valign = .top });

// Ascender aligned (b, d, l tops touch top edge)
_ = try doc.write(&region, text, style, .{ .valign = .top_ascent });

// Legacy half-leading (includes line-height whitespace above glyphs)
_ = try doc.write(&region, text, style, .{ .valign = .top_leading });
```

### Measure Text Before Rendering

Use `write()` or `writeStyled()` with `.measure_only = true` to measure without rendering.
Measurement is side-effect free - the region's cursor is unchanged after the call.

```zig
var region = platen.Region{
    .x = 50,
    .y = 100,
    .width = 200,
    .height = 10000, // Large height for measurement
    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
};

// Define text style
const style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 11 };
const line_height = style.size * 1.2;  // Default line height multiplier

// Measure plain text (cursor unchanged after this call)
const result = try doc.write(&region, text, style, .{ .measure_only = true });

// Or measure styled text
var styled = doc.createStyledText();
try styled.append("Hello ", .{});
try styled.append("World", .{ .color = platen.Color.blue });
const styled_result = try doc.writeStyled(&region, &styled, style, .{ .measure_only = true });

// Calculate height from lines_written
const content_height = @as(f64, @floatFromInt(result.lines_written)) * line_height;
const box_height = content_height + 16; // Add padding

// Render (no need to reset cursor - measure_only didn't change it)
if (box_height <= region.remainingHeight()) {
    _ = try doc.write(&region, text, style, .{});
}
```

### Colors

```zig
// Named color presets
const color1 = platen.Color.red;
const color2 = platen.Color.navy;
const color3 = platen.Color.coral;

// From RGB (0-255 range) - the common case
const color4 = platen.Color.rgb(128, 64, 192);

// From RGB floats (0.0-1.0 range)
const color5 = platen.Color.rgbf(0.5, 0.25, 0.75);

// From hex string
const color6 = platen.Color.hex("#FF6600").?;
const color7 = platen.Color.hex("F60").?;  // short form

// Greyscale (0 = black, 1 = white)
const color8 = platen.Color.greyscale(0.5);

// CMYK for print
const color9 = platen.Color.cmyk(1, 0, 0, 0);  // cyan
```

Available presets: `black`, `white`, `red`, `green`, `blue`, `cyan`, `magenta`, `yellow`, `orange`, `pink`, `purple`, `brown`, `navy`, `teal`, `coral`, `salmon`, `gold`, `silver`, `maroon`, `olive`, `lime`, `indigo`, `violet`, `turquoise`, `skyblue`, `forestgreen`, and many more.

### Drawing Shapes

```zig
try doc.addPage(.{});

// Line with explicit style
try doc.drawLine(
    .{ .x = 50, .y = 100 },
    .{ .x = 200, .y = 100 },
    .{ .color = platen.Color.black, .width = 1.5 },
);

// Rectangle with stroke and fill
try doc.drawRect(
    .{ .x = 50, .y = 120, .width = 100, .height = 50 },
    .{
        .stroke = .{ .color = platen.Color.black },
        .fill = .{ .color = platen.Color.lightgray },
    },
);

// Rounded rectangle (stroke only)
try doc.drawRoundedRect(
    .{ .x = 50, .y = 180, .width = 100, .height = 50 },
    10,  // corner radius
    .{ .stroke = .{ .color = platen.Color.blue, .width = 2 } },
);

// Circle (fill only)
try doc.drawCircle(.{ .x = 200, .y = 200 }, 30, .{ .fill = .{ .color = platen.Color.red } });

// Polygon
const points = [_]platen.Point{
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

try path.moveTo(.{ .x = 100, .y = 100 });
try path.lineTo(.{ .x = 200, .y = 100 });
try path.curveTo(
    .{ .x = 250, .y = 100 },  // control point 1
    .{ .x = 250, .y = 200 },  // control point 2
    .{ .x = 200, .y = 200 },  // end point
);
try path.lineTo(.{ .x = 100, .y = 200 });
try path.closePath();

try doc.drawPath(&path, .{
    .stroke = .{ .color = platen.Color.blue },
    .fill = .{ .color = platen.Color.lightblue },
});
```

### Images

```zig
// Load JPEG or PNG
const img = try doc.loadImage("photo.jpg");

try doc.addPage(.{});

// Draw at position with explicit size
try doc.drawImage(img, .{ .x = 50, .y = 50, .width = 200, .height = 150 });

// Auto aspect ratio (omit width or height for auto-scale)
try doc.drawImage(img, .{ .x = 50, .y = 250, .width = 200 });  // height auto
```

### SVG Embedding

```zig
// Load SVG file
const svg = try doc.loadSvg("diagram.svg");

try doc.addPage(.{});

// Draw at original size (omit width/height)
try doc.drawSvg(svg, .{ .x = 50, .y = 50 });

// Scaled
try doc.drawSvg(svg, .{ .x = 300, .y = 50, .width = 150, .height = 150 });
```

### Gradients

```zig
// Define color stops
const stops = [_]platen.ColorStop{
    .{ .offset = 0.0, .color = platen.Color.red },
    .{ .offset = 1.0, .color = platen.Color.blue },
};

// Linear gradient (from point to point)
const linear = platen.LinearGradient{
    .x0 = 50, .y0 = 50,    // start point
    .x1 = 250, .y1 = 50,   // end point
    .stops = &stops,
};
const linear_idx = try doc.addLinearGradient(linear);
try doc.fillRectGradient(50, 50, 200, 100, linear_idx);

// Radial gradient (from inner circle to outer circle)
const radial_stops = [_]platen.ColorStop{
    .{ .offset = 0.0, .color = platen.Color.yellow },
    .{ .offset = 1.0, .color = platen.Color.red },
};
const radial = platen.RadialGradient{
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
// Default is A4 with 72pt margins

// Add page with defaults (A4, 72pt margins)
try doc.addPage(.{});

// Add page with specific size
try doc.addPage(.{ .size = platen.PageSize.Letter });

// Add page with size and custom margins
try doc.addPage(.{
    .size = platen.PageSize.A4,
    .margins = .{ .left = 50, .right = 50, .top = 72, .bottom = 72 },
});

// Landscape orientation
try doc.addPage(.{ .size = platen.PageSize.Letter.landscape() });

// Custom size
try doc.addPage(.{ .size = .{ .width = 500, .height = 700 } });

// Page navigation (for TOC, footers, etc.)
const total = doc.pageCount();
doc.selectPage(0);  // go back to first page
try doc.insertPage(0, .{});  // insert page at beginning
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
    // .producer defaults to "platen"
    // .creation_date and .mod_date auto-generated if not set
});
```

### Links

```zig
try doc.addPage(.{});

const body = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
const heading = platen.TextStyle{ .font = platen.Font.helvetica, .size = 16, .bold = true };

// Write text and get its bounding rectangle
const rect = try doc.writeAt(.{ .x = 50, .y = 50 }, "Click here for Zig documentation", body);

// Add external link (URL)
try doc.addExternalLink(rect, "https://ziglang.org/documentation/");

// Internal links for TOC navigation
const ch1_result = try doc.writeAt(.{ .x = 50, .y = 100 }, "Chapter 1: Introduction", heading);
const chapter1_dest = doc.destination(ch1_result.y).?;  // save this location

// Later, create a link to that chapter
try doc.addPage(.{});
const toc_rect = try doc.writeAt(.{ .x = 50, .y = 50 }, "Go to Chapter 1", body);
try doc.addLink(toc_rect, chapter1_dest);
```

### Table of Contents (Outline)

```zig
// Create outline builder
var outline = doc.createOutline();

// Add top-level items
const ch1 = try outline.add("Chapter 1: Introduction", doc.destination(0).?);
const ch2 = try outline.add("Chapter 2: Details", doc.destination(100).?);

// Add nested items
_ = try outline.addChild(ch1, "Section 1.1: Background", doc.destination(50).?);
_ = try outline.addChild(ch1, "Section 1.2: Overview", doc.destination(75).?);

// Set the outline on the document
doc.setOutline(&outline);
```

### PDF/A Archival Format

```zig
var doc = platen.Document.init(allocator, init.io);
defer doc.deinit();

// Enable PDF/A-1b conformance (archival format)
doc.setConformance(.pdfa_1b);

// Set required metadata
doc.setMetadata(.{
    .title = "Archival Document",
    .author = "Organization Name",
});

// Add content as usual
try doc.addPage(.{});
const style = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "This document conforms to PDF/A-1b.", style);

// Output includes XMP metadata, ICC color profile, and PDF/A identification
const pdf_data = try doc.output();
```

Available conformance levels:
- `.pdfa_1b` - PDF/A-1b (ISO 19005-1): No transparency, all fonts embedded
- `.pdfa_2b` - PDF/A-2b (ISO 19005-2): Allows transparency, JPEG2000, layers

Note: PDF/A-1b rejects transparency (opacity < 1.0) with `error.TransparencyNotAllowed`.

## API Reference

### Document Lifecycle

| Method | Description |
|--------|-------------|
| `Document.init(allocator, io)` | Create a new PDF document. `io` is `std.Io` (use `init.io` from main, or `std.testing.io` in tests) |
| `deinit()` | Free all document resources |
| `output() -> []u8` | Generate PDF output as bytes |

### Pages & Layout

| Method | Description |
|--------|-------------|
| `addPage(PageOptions)` | Add a new page with size and margins |
| `insertPage(index, PageOptions)` | Insert page at index (shifts others) |
| `selectPage(index)` | Select page for subsequent operations |
| `pageCount() -> usize` | Get total number of pages |
| `getPageRegion() -> ?Region` | Get drawable region for current page |
| `getPageIndex() -> usize` | Get current page index (0-based) |
| `setMetadata(DocumentMetadata)` | Set title, author, subject, keywords, etc. |

### Fonts

| Method | Description |
|--------|-------------|
| `loadFont(path, encoding) -> Font` | Load TTF/OTF font from file (.identity = Unicode, .win_ansi = legacy) |
| `loadFontFromMemory(data, ?encoding) -> Font` | Load TTF/OTF font from memory buffer |
| `loadFontFamily(FontFamilyOptions) -> Font` | Load font family from files |
| `loadFontFamilyFromMemory(FontFamilyMemoryOptions) -> Font` | Load font family from memory buffers |
| `setFontFeature(*EmbeddedFont, Feature, bool)` | Enable/disable OpenType feature for specific font |
| `getFontMetricsStyled(TextStyle) -> FontMetrics` | Get metrics (ascender, descender, etc.) for a style |

### Text Output

| Method | Description |
|--------|-------------|
| `writeAt(Point, str, TextStyle) -> Rect` | Write text at absolute position |
| `write(*Region, str, TextStyle, WriteOptions) -> WriteResult` | Incremental write with word wrapping (cursor advances) |
| `writeLine(*Region, str, TextStyle, LineOptions) -> WriteResult` | Block-based write with alignment (cursor to next line) |
| `writeStyled(*Region, *StyledText, TextStyle, ParagraphOptions) -> WriteResult` | Write styled text with wrapping and alignment |
| `createStyledText() -> StyledText` | Create builder for mixed formatting (bold, colors, etc.) |

### Text Measurement

| Method | Description |
|--------|-------------|
| `write(*Region, str, style, .{ .measure_only = true })` | Measure layout without rendering (cursor unchanged) |
| `writeLine(*Region, str, style, .{ .measure_only = true })` | Measure aligned layout without rendering |
| `writeStyled(*Region, *StyledText, style, .{ .measure_only = true })` | Measure styled layout without rendering |

### Text Styling

Text styling is done via `TextStyle` struct passed to text methods:

```zig
const style = platen.TextStyle{
    .font = platen.Font.helvetica,  // or .times, .courier, or embedded font
    .size = 12,
    .bold = true,
    .italic = false,
    .color = platen.Color.navy,
    .decoration = .underline,
    .opacity = 0.5,                // fill alpha: 0.0 transparent .. 1.0 opaque
};
```

`opacity` (default `1.0`) applies a non-stroking alpha to the glyphs and their
decorations, using the same transparency mechanism as shapes. Values below `1.0`
require transparency support and are rejected by PDF/A-1b
(`error.TransparencyNotAllowed`).

For mixed styles within a paragraph, use `StyledText`:

```zig
var st = doc.createStyledText();
try st.append("Normal ", .{});
try st.append("bold ", .{ .bold = true });
try st.append("red", .{ .color = platen.Color.red });
```

### Navigation & Links

| Method | Description |
|--------|-------------|
| `destination(y) -> ?Destination` | Get destination at y position on current page |
| `addLink(Rect, Destination)` | Add internal link (jumps to page/position) |
| `addExternalLink(Rect, url)` | Add external link (opens URL) |
| `createOutline() -> Outline` | Create outline builder for table of contents |
| `setOutline(*Outline)` | Set the document outline (takes ownership) |
| `setPageLabel(page_index, PageLabel)` | Set page numbering style |

### Images & SVG

| Method | Description |
|--------|-------------|
| `loadImage(path) -> *Image` | Load JPEG or PNG image from file |
| `loadImageFromMemory(data) -> *Image` | Load JPEG or PNG image from memory buffer |
| `drawImage(*Image, Rect)` | Draw image (omit width/height for auto-scale) |
| `loadSvg(path) -> *Svg` | Load SVG from file |
| `loadSvgFromMemory(data) -> *Svg` | Load SVG from memory buffer |
| `drawSvg(*Svg, Rect)` | Draw SVG (omit width/height for original size) |

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
| `moveTo(Point)` | Move without drawing |
| `lineTo(Point)` | Line to point |
| `curveTo(cp1, cp2, end)` | Cubic Bezier curve (3 Points) |
| `quadTo(cp, end)` | Quadratic Bezier curve (2 Points) |
| `closePath()` | Close subpath |
| `deinit()` | Free path resources |

### Gradients

| Method | Description |
|--------|-------------|
| `addLinearGradient(LinearGradient) -> usize` | Register linear gradient |
| `addRadialGradient(RadialGradient) -> usize` | Register radial gradient |
| `fillRectGradient(Rect, gradient_idx)` | Fill rect with gradient |

### StyledText Builder

Create with `doc.createStyledText()`, then:

| Method | Description |
|--------|-------------|
| `append(text, TextStyleOptions)` | Add text span with style |
| `isEmpty() -> bool` | Check if empty |
| `totalLength() -> usize` | Get total text length |
| `deinit()` | Free resources |

### Unit Conversions

All measurements in platen are in points (1 pt = 1/72 inch).

```zig
const x = platen.inches(1.5);  // 108 points
const y = platen.mm(25.4);     // 72 points (1 inch)
const z = platen.cm(2.54);     // 72 points (1 inch)

// Constants
platen.pt_per_inch  // 72.0
platen.pt_per_mm    // 2.834...
platen.pt_per_cm    // 28.34...
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
- `VAlign` - Vertical: `.top` (optical cap-height), `.top_ascent`, `.top_leading`, `.middle`, `.bottom`
- `TextDecoration` - `.none`, `.underline`, `.strikethrough`, `.underline_strikethrough`
- `LineBreaking` - `.greedy` (fast) or `.optimal` (Knuth-Plass for justified text)
- `WriteOptions` / `LineOptions` / `ParagraphOptions` - Text layout options
- `WriteResult` - Result with lines_written, overflow text, and bounding rect
- `TextMetrics` / `FontMetrics` - Measurement results

**Fonts:**
- `Font` - Union type: `.family` (FontFamily), `.symbol`, `.zapf_dingbats`, `.embedded` (*EmbeddedFont), `.embedded_family` (*EmbeddedFontFamily)
- `Font.helvetica`, `Font.times`, `Font.courier` - Convenience constants for standard font families
- `FontFamily` - `.helvetica`, `.times`, `.courier` (resolved to bold/italic via TextStyle)
- `StandardFont` - `.helvetica`, `.helvetica_bold`, `.helvetica_italic`, `.helvetica_bold_italic`, `.times_roman`, `.times_bold`, `.times_italic`, `.times_bold_italic`, `.courier`, `.courier_bold`, `.courier_italic`, `.courier_bold_italic`, `.symbol`, `.zapfdingbats`
- `EmbeddedFont` - Loaded TTF/OTF font
- `EmbeddedFontFamily` - Font family with regular/bold/italic/bold-italic variants (from `loadFontFamily`)
- `TextStyle` - Complete text style (font, size, bold, italic, color, decoration)

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
- `Outline` - Table of contents builder (add(), addChild())
- `OutlineItem` - Individual outline entry
- `PageLabel` / `PageLabelStyle` - Page numbering (roman, arabic, etc.)

**OpenType Features:**

GSUB (Glyph Substitution):
- `liga` - Standard ligatures (fi, fl, ff, etc.) - *enabled by default*
- `clig` - Contextual ligatures
- `dlig` - Discretionary ligatures
- `hlig` - Historical ligatures
- `calt` - Contextual alternates (e.g., -> to arrow) - *enabled by default*
- `tnum` - Tabular figures (monospaced numbers)
- `pnum` - Proportional figures
- `frac` - Fractions (1/2 to ½)
- `zero` - Slashed zero
- `case` - Case-sensitive forms
- `ss01`-`ss20` - Stylistic sets 1-20
- `cv01`-`cv99` - Character variants 1-99

GPOS (Glyph Positioning):
- `kern` - Kerning - *enabled by default*
- `mark` - Mark positioning (diacritics on base glyphs) - *enabled by default*
- `mkmk` - Mark-to-mark positioning (stacked diacritics) - *enabled by default*

```zig
// Enable/disable features on embedded fonts
const font = try doc.loadFont("fonts/Inter.ttf", .identity);
font.embedded.setFeature(.dlig, true);   // Enable discretionary ligatures
font.embedded.setFeature(.ss01, true);   // Enable stylistic set 1
font.embedded.setFeature(.cv11, true);   // Enable character variant 11
font.embedded.setFeature(.liga, false);  // Disable standard ligatures
```

## Requirements

- Zig 0.16+
- No dependencies — compression uses `std.compress.flate`

## License

MIT
