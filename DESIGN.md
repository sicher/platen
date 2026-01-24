# PDF rendering library

## Architecture

### Modules
- `zpdf.zig` - Main library facade, re-exports from document.zig
- `document.zig` - Document struct, text/graphics rendering, PDF output
- `objects.zig` - PDF object types (Dict, Array, Value, Ref, Name)
- `fonts.zig` - Standard PDF fonts (Base 14)
- `metrics.zig` - Font metrics, text measurement, spacing
- `writer.zig` - PDF serialization (header, objects, xref, trailer)
- `ttf.zig` - TrueType/OpenType font parser
- `embedded.zig` - Font embedding, subsetting, CID fonts
- `opentype.zig` - OpenType GSUB/GPOS (ligatures, kerning, marks)
- `ttf_subset.zig` - TTF subsetting helpers
- `cff_subset.zig` - CFF subsetting helpers
- `images.zig` - JPEG/PNG parsing and embedding
- `svg.zig` - SVG parsing and Form XObject generation
- `xml.zig` - Minimal XML parser for SVG
- `path.zig` - Path builder API
- `gradient.zig` - Linear/radial gradient support
- `color.zig` - Color types (grayscale, RGB, CMYK)
- `layout.zig` - Layout types (Point, TextBox, Margins, Padding)
- `zlib.zig` - FlateDecode compression via C zlib
- `cli.zig` - Command line tool

### PDF Structure
Objects are numbered sequentially starting at 1:
- Object 1: Catalog (root)
- Object 2: Pages (page tree root)
- Object 3 to 3+N: Font objects (one per used font)
- After fonts: Pages (2 objects each: page dict + content stream)

### Text Rendering
Uses PDF content stream operators:
- `BT` / `ET` - Begin/End text block
- `Tf` - Set font and size (e.g., `/F1 12 Tf`)
- `Td` - Move text position
- `Tj` - Show text string

### Standard Fonts (Base 14)
PDF viewers must have these fonts built-in:
- Helvetica (4 styles: normal, bold, oblique, bold-oblique)
- Times (4 styles: roman, bold, italic, bold-italic)
- Courier (4 styles: normal, bold, oblique, bold-oblique)
- Symbol
- ZapfDingbats

Fonts are referenced as `/F1`, `/F2`, etc. in content streams and defined
in the page's Resources dictionary.

### Font Metrics
Character widths for all 14 Base fonts are stored in `src/metrics.zig`.
Values are in 1000ths of an em (standard Adobe AFM format).

**Text measurement:**
```zig
doc.setFont(.helvetica, 12);
const m = doc.measureText("Hello");
// m.width = text width in points
// m.height = line height in points (font_size * line_height factor)
```

**Spacing configuration:**
```zig
doc.setCharSpacing(2.0);   // Extra 2pt between characters
doc.setLineHeight(1.5);    // 150% line height (vs default 1.2)
```

Character spacing uses PDF's `Tc` operator in the content stream.

### TrueType Font Embedding

Enables custom fonts beyond Base 14, including Unicode support.

**TTF tables parsed:**
- `head` - font header (units per em, bounds)
- `hhea` - horizontal metrics header (ascent, descent, line gap)
- `hmtx` - glyph widths (for text measurement)
- `cmap` - Unicode → glyph ID mapping (format 4 and 12)
- `maxp` - number of glyphs
- `name` - font family and style names

**API usage:**
```zig
// Load a TTF font
const font = try doc.loadFont("MyFont.ttf");

// Use it for text
try doc.setEmbeddedFont(font, 14);
try doc.textAt(50, 50, "Hello with custom font!");

// Mix with standard fonts
try doc.setFont(.helvetica, 12);
try doc.textAt(50, 70, "Back to Helvetica");
```

**PDF structures generated:**

Each embedded font creates 3 PDF objects:

1. **Font dictionary** - defines the font resource
```
<< /Type /Font
   /Subtype /TrueType
   /BaseFont /MyFont
   /FirstChar 0
   /LastChar 255
   /Widths [...]         % 256 widths for WinAnsi chars
   /FontDescriptor 5 0 R
   /Encoding /WinAnsiEncoding
>>
```

2. **FontDescriptor** - font metrics for PDF viewer
```
<< /Type /FontDescriptor
   /FontName /MyFont
   /Flags 32              % nonsymbolic (or 33 for fixed-pitch)
   /FontBBox [...]        % scaled to 1000 units
   /ItalicAngle 0
   /Ascent 900
   /Descent -200
   /CapHeight 630
   /StemV 80
   /FontFile2 6 0 R       % ref to embedded TTF stream
>>
```

3. **FontFile2 stream** - raw TTF data
```
<< /Length 85000
   /Length1 85000         % original TTF size
>>
stream
[raw TTF bytes]
endstream
```

**WinAnsiEncoding (Windows-1252):**
- Characters 0-127: ASCII
- Characters 128-159: Special (Euro, smart quotes, em dash, etc.)
- Characters 160-255: Latin-1 Supplement

**Font resource naming:**
- Standard fonts: F1-F14 (Helvetica, Times, Courier, etc.)
- Embedded fonts: E1, E2, E3, etc.

**Current features:**
- Font subsetting: only used glyphs embedded (~50% file size reduction)
- WinAnsiEncoding for single-byte text mapping
- ToUnicode CMap: enables copy/paste and text extraction

**Current limitations:**
- WinAnsiEncoding mode for simple text (use CID mode for full Unicode)

**Subsetting implementation** (`createSubsetTTF` in embedded.zig):
- Tracks used chars via `used_chars[256]` bitmap
- Collects unique glyph IDs from original font's cmap
- Rebuilds: glyf, loca, hmtx, cmap (format 0), maxp, hhea
- Copies: head, name, post tables
- Generates valid TrueType that parses correctly

**ToUnicode CMap** (`generateToUnicodeCMap` in embedded.zig):
- Maps WinAnsi byte values (0x00-0xFF) to Unicode codepoints
- Enables text extraction and copy/paste in PDF viewers
- Only includes mappings for used characters
- Format: single-byte codespace, bfchar entries

**Implemented features:**
1. FlateDecode compression for all streams (via bundled C zlib)
2. CIDFont (Type0) support for full Unicode text (CJK, emoji, etc.)
3. OpenType CFF font support (CIDFontType0C)
4. OpenType GSUB/GPOS (ligatures, kerning, mark positioning)

### Memory Management
Uses `ArrayListUnmanaged` throughout - allocator passed to each operation.
`Document.output()` returns owned memory that caller must free.

### Testing Strategy
Semantic comparison: verifies visual output matches regardless of internal PDF structure.

**Reference generation** (using fpdf2):
```bash
python scripts/gen_references.py  # Auto-installs fpdf2 in .venv/
```

**Semantic comparison** compares:
- Text content (exact match)
- Text positions (within 1.0pt tolerance)
- Page dimensions

**Does NOT compare:**
- Internal object IDs/ordering
- PDF version
- Metadata
- Exact coordinate values (allows different coordinate systems)

**CLI commands:**
- `zpdf check-refs` - Run semantic comparison, generate HTML report

**Test cases (23 integration tests):**
- `minimal` - Empty page
- `hello_world` - Single text
- `multi_font` - Multiple font families
- `all_fonts` - All 14 standard fonts
- `multi_page` - Multi-page document
- `embedded_fonts` - TrueType font embedding
- `cid_fonts` - CID/Unicode fonts (TTF + OTF)
- `inter_fonts` - OpenType features (liga, kern, mark, calt, dlig, etc.)
- `gentium_diacritics` - Mark positioning showcase
- `opentype_features` - OpenType feature comparison
- `text_flow` - TextBox, word wrapping, padding
- `justify` - Justified text alignment
- `optimal_breaks` - Knuth-Plass line breaking
- `colored_text` - Text colors (grayscale, RGB, CMYK)
- `shapes` - Drawing primitives (line, rect, circle, ellipse, polygon)
- `images` - JPEG and PNG embedding
- `svg` - SVG embedding (basic shapes, tiger.svg)
- `svg_text` - SVG text elements
- `svg_use_defs` - SVG `<use>` and `<defs>` elements
- `svg_equation` - MathJax equation rendering
- `paths` - Path API (moveTo, lineTo, curveTo, closePath)
- `gradients` - Linear and radial gradients
- `landscape` - Page sizes and orientations (A4, Letter, landscape, custom)

## Text API

Naming convention: `write*` for text, `draw*` for graphics (future).

### Functions

| Function | Purpose |
|----------|---------|
| `write(str)` | Write at cursor position |
| `writeAt(x, y, str)` | Write at specific position |
| `writeStyled(&region, *StyledText, opts)` | Styled text in region, returns overflow |
| `write(&region, str, .{ .measure_only = true })` | Measure layout without rendering |

### Text Measurement

Use `write()` or `writeStyled()` with `.measure_only = true` to measure text layout without rendering.
Measurement is side-effect free - cursor position is unchanged. Uses the same code path as rendering.

```zig
var region = zpdf.Region{
    .x = 50, .y = 100,
    .width = 200, .height = 10000,
    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
};

// Measure (cursor unchanged after this call)
const result = try doc.write(&region, text, .{ .measure_only = true });

// Calculate height from lines_written
const line_height = doc.getLineHeightPts();
const content_height = @as(f64, @floatFromInt(result.lines_written)) * line_height;
const box_height = content_height + 16; // + padding

// Render (no reset needed - measure_only is side-effect free)
if (box_height <= region.remainingHeight()) {
    _ = try doc.write(&region, text, .{});
}
```

### Margins and Page TextBox

```zig
// Set document margins (optional - defaults to 72pt / 1 inch)
doc.setMargins(.{ .left = 72, .right = 72, .top = 72, .bottom = 72 });

// Get text box for current page (respects margins)
var box = doc.getPageTextBox();
// → TextBox{ .x = 72, .y = 72, .width = 468, .height = 648, ... }
```

Margins don't magically affect `writeAt()` - they only define what `getPageTextBox()` returns.

### Document Metadata

Set document properties like title, author, and subject via the Info dictionary:

```zig
doc.setMetadata(.{
    .title = "Annual Report 2026",
    .author = "Finance Department",
    .subject = "Q4 Financial Results",
    .keywords = "finance, report, 2026",
    .creator = "MyApp v1.0",    // Application that created the content
    .producer = "zpdf",         // Default - PDF producer
    .creation_date = "D:20260121120000",  // Optional - auto-generated if null
});
```

All fields are optional. Only non-null fields are written to the PDF Info dictionary.
The PDF trailer includes `/Info` reference when any metadata is set.

### Core Types

```zig
/// Color (RGB for now, color spaces TBD)
const Color = struct {
    r: f64,  // 0.0 - 1.0
    g: f64,
    b: f64,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    // TODO: CMYK, grayscale, spot colors
};

/// Border specification
const Border = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub const none = Border{};
    pub const all = Border{ .top = true, .bottom = true, .left = true, .right = true };
};

/// Padding (inner content inset)
const Padding = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,
};

/// Measured dimensions of text
const TextMetrics = struct {
    width: f64,      // in points
    height: f64,     // in points (line height)
    lines: usize,    // number of lines (for wrapped text)
};

/// 2D point
const Point = struct {
    x: f64,
    y: f64,
};

/// A rectangular area for content placement with cursor tracking
const TextBox = struct {
    // Geometry
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    // Cursor state
    cursor_y: f64 = 0,   // current vertical position within content area

    // Content inset
    padding: Padding = .{},

    // Visual styling (separate from text content)
    border: Border = .{},
    fill: ?Color = null,

    /// Space remaining in content area
    pub fn remainingHeight(self: TextBox) f64;

    /// Usable width inside padding
    pub fn contentWidth(self: TextBox) f64;

    /// Check if text metrics fit in remaining space
    pub fn fits(self: TextBox, m: TextMetrics) bool;
};

/// Result of writeStyled
const WriteResult = struct {
    lines_written: usize,       // number of lines rendered
    overflow: ?[]const u8,      // text that didn't fit (null if all fit)
};

/// Horizontal text alignment
const Align = enum { left, center, right, justify };

/// Vertical text alignment within line height
const VAlign = enum {
    top,     // baseline at content_y + font_size (simple)
    middle,  // baseline centered, fpdf2 compatible
    bottom,  // baseline at content_y + line_height
};

/// Line breaking algorithm
const LineBreaking = enum {
    greedy,   // Fill each line as much as possible (fast, default)
    optimal,  // Knuth-Plass: minimize total badness across all lines
};

/// Options for writeStyled (wrapped text)
const ParagraphOptions = struct {
    alignment: Align = .left,
    valign: VAlign = .top,
    break_on_hyphens: bool = true,    // Break at regular hyphens (false for fpdf2 compat)
    line_breaking: LineBreaking = .greedy,  // Algorithm for line breaks
};

/// Options for writeFlow (convenience auto-page)
const FlowOptions = struct {
    alignment: Align = .left,
    valign: VAlign = .top,
};
```

### Function Signatures

```zig
fn write(self: *Document, text: []const u8) !void
fn writeAt(self: *Document, x: f64, y: f64, text: []const u8) !void
fn writeStyled(self: *Document, box: *Region, text: *StyledText, opts: ParagraphOptions) !WriteResult
fn writeFlow(self: *Document, text: []const u8, opts: FlowOptions) !void

/// Draw text box's border/fill (without text)
fn drawTextBox(self: *Document, box: *const TextBox) !void
```

### Usage Patterns

**Simplest case - dump text into PDF:**
```zig
var doc = try zpdf.Document.init(allocator);
try doc.setFont(.helvetica, 12);
try doc.addPage(.a4);

// Auto-adds pages as needed
try doc.writeFlow(long_body_text, .{});

try doc.save("output.pdf");
```

**With options:**
```zig
try doc.writeFlow(long_body_text, .{
    .alignment = .justify,
});
```

**Manual text box control:**
```zig
var box = doc.getPageTextBox();
var st = doc.createStyledText();
defer st.deinit();
try st.append(text, .{});

const result = try doc.writeStyled(&box, &st, .{});
if (result.overflow != null) {
    try doc.addPage(null);
    box = doc.getPageTextBox();
    // continue with remaining text...
}
```

**Multi-column layout:**
```zig
var left = TextBox{ .x = 50, .y = 50, .width = 230, .height = 700 };
var right = TextBox{ .x = 310, .y = 50, .width = 230, .height = 700 };

var st = doc.createStyledText();
defer st.deinit();
try st.append(text, .{});

for ([_]*TextBox{ &left, &right }) |box| {
    const result = try doc.writeStyled(box, &st, .{});
    if (result.overflow == null) break;
}
// result.overflow still has text? Add page, repeat...
```

### Baseline Positioning (VAlign)

Vertical alignment controls where text sits within each line cell:

```zig
// valign: .top (default) - simple formula, baseline at content_y + font_size
baseline = content_y + cursor_y + font_size

// valign: .middle - fpdf2 compatible, text centered in line height
baseline = content_y + cursor_y + font_size - leading/2

// valign: .bottom - baseline at bottom of line height
baseline = content_y + cursor_y + line_height
```

**fpdf2 compatibility**: Use `.valign = .middle` to match fpdf2's `cell()` and `multi_cell()`:

```zig
var st = doc.createStyledText();
defer st.deinit();
try st.append(text, .{});
_ = try doc.writeStyled(&region, &st, .{ .valign = .middle });
```

### Design Principles

1. **Measure is cheap** - Font metric lookups, no PDF writing
2. **No backtracking** - Measure → decide → render (never undo)
3. **User controls flow** - Library provides primitives, user handles page/column breaks
4. **Explicit text boxes** - Margins don't magically affect positioning; ask for `getPageTextBox()`
5. **Single source of truth** - When using text boxes, the box's cursor is authoritative; don't mix with `setPosition()`
6. **Layered API** - Simple (`writeFlow`) to powerful (`writeStyled` + manual text boxes)
7. **Explicit over magic** - VAlign provides control; no hidden adjustments

## Graphics Support

### Image Embedding

```zig
// Load and draw images
const img = try doc.loadImage("photo.jpg");  // or .png
try doc.drawImage(img, x, y, width, height);

// Auto aspect ratio (specify 0 for width or height)
try doc.drawImage(img, x, y, 200, 0);  // width=200, height auto
```

| Format | Implementation | Use Case |
|--------|---------------|----------|
| JPEG | Embed raw bytes, DCTDecode filter | Photos |
| PNG | Decode, FlateDecode, alpha as SMask | Screenshots, diagrams |

### SVG Embedding

```zig
// Load and draw SVG as Form XObject
const svg = try doc.loadSvg("diagram.svg");
try doc.drawSvg(svg, x, y, width, height);
```

**Supported SVG features:**
- Basic shapes: rect, circle, ellipse, line, polyline, polygon
- Paths: full d-attribute (M, L, H, V, C, S, Q, T, A, Z commands)
- Text elements with font families (serif, sans-serif, monospace)
- Transforms: translate, scale, rotate, skewX, skewY, matrix
- Styling: fill, stroke, stroke-width, opacity, stroke-linecap/linejoin
- Colors: hex (#RGB, #RRGGBB), rgb(), rgba(), named colors
- Gradients: linearGradient, radialGradient with stops
- Reuse: `<defs>` and `<use>` elements with href/xlink:href

**Use cases:** matplotlib, Inkscape, Illustrator, R/ggplot2, MathJax equations.

### Drawing Primitives

```zig
// Lines
try doc.drawLine(x1, y1, x2, y2);

// Shapes (stroke, fill, or fill_stroke)
try doc.drawRect(x, y, w, h, .fill_stroke);
try doc.drawCircle(cx, cy, radius, .fill);
try doc.drawEllipse(x, y, w, h, .stroke);
try doc.drawPolygon(&points, .fill_stroke);
```

### Path API

```zig
// Create path with builder pattern
var path = doc.createPath();
defer path.deinit();

try path.moveTo(100, 100);
try path.lineTo(200, 100);
try path.curveTo(250, 100, 250, 200, 200, 200);  // cubic Bézier
try path.quadTo(150, 250, 100, 200);              // quadratic Bézier
try path.closePath();

try doc.drawPath(&path, .fill_stroke);
```

### Gradients

```zig
// Linear gradient
var gradient = zpdf.LinearGradient.init(x1, y1, x2, y2);
gradient.addStop(0.0, zpdf.Color.fromRgb(1, 0, 0));  // red at start
gradient.addStop(1.0, zpdf.Color.fromRgb(0, 0, 1));  // blue at end
try doc.drawLinearGradient(&gradient, x, y, w, h);

// Radial gradient
var radial = zpdf.RadialGradient.init(cx, cy, r);
try doc.drawRadialGradient(&radial, x, y, w, h);
```

### Styling

```zig
doc.setDrawColor(zpdf.Color.fromRgb(0, 0, 0));
doc.setFillColor(zpdf.Color.fromRgb(0.9, 0.9, 0.9));
doc.setLineWidth(1.5);
doc.setLineCap(.round);    // .butt, .round, .square
doc.setLineJoin(.miter);   // .miter, .round, .bevel
doc.setDashPattern(4, 2, 0);  // dash, gap, phase
doc.setSolidLine();           // reset to solid
```

## Navigation

### Document Outline

The outline appears in the PDF viewer's table of contents sidebar:

```zig
// Create a destination at current position
const dest = doc.currentDestination().?;

// Top-level outline item
const ch1 = try doc.addOutlineItem("Chapter 1", dest, null);

// Nested items (children of ch1)
try doc.addPage(null);
_ = try doc.addOutlineItem("Section 1.1", doc.currentDestination().?, ch1);
_ = try doc.addOutlineItem("Section 1.2", doc.currentDestination().?, ch1);

// Another top-level item
try doc.addPage(null);
_ = try doc.addOutlineItem("Chapter 2", doc.currentDestination().?, null);
```

Outline items can be nested to any depth. The parent pointer creates the tree structure.

### Page Labels

Custom page numbering displayed in the viewer's page indicator:

```zig
// Roman numerals for front matter (pages 0-3)
try doc.setPageLabel(0, .{ .style = .roman_lower });  // i, ii, iii, iv...

// Arabic numerals starting at 1 (page 4 onwards)
try doc.setPageLabel(4, .{ .style = .decimal, .start = 1 });  // 1, 2, 3...

// Appendix pages with prefix
try doc.setPageLabel(104, .{ .style = .alpha_upper, .prefix = "App-" });  // App-A, App-B...
```

Available styles: `.decimal` (1,2,3), `.roman_lower` (i,ii,iii), `.roman_upper` (I,II,III),
`.alpha_lower` (a,b,c), `.alpha_upper` (A,B,C), `.none` (prefix only).

### Links

Internal links for TOC-style navigation and external URLs:

```zig
// Create destination at chapter heading
const chapter_dest = doc.currentDestination().?;

// Later, create clickable text that jumps to chapter
const rect = try doc.writeAt(72, 100, "Go to Chapter 1");
try doc.addLink(rect, chapter_dest);

// External URL link
const url_rect = try doc.writeAt(72, 120, "Visit website");
try doc.addExternalLink(url_rect, "https://example.com");
```

## API Design Guidelines

Principles for zpdf's public API:

### 1. Unify common types
Define shared types once in `layout.zig` and re-export everywhere:
- `Point` - 2D coordinates (x, y)
- `Rect` - bounding box (x, y, width, height)
- `TextBox` - styled text container with cursor tracking

Avoid duplicate definitions in different modules.

### 2. Prefer structs over multiple parameters
Use `Point` instead of separate `x, y` parameters where it makes sense:
```zig
// Preferred
doc.setPosition(Point{ .x = 100, .y = 200 });
const pos = doc.getPosition();

// Avoid proliferating separate x/y methods
// (removed: setX, setY, getX, getY, setXY)
```

Exception: Drawing APIs like `writeAt(x, y, text)` keep separate params for convenience.

### 3. Eliminate redundant methods
If two methods differ only by a constant offset, keep one:
- `pageNo()` returns page count (1, 2, 3...)
- Removed `currentPageIndex()` since it's just `pageNo() - 1`

### 4. Composable primitives over special options
Prefer general mechanisms that compose well:
- **Future**: Replace `first_indent` option with cursor advancement on TextBox
- General `cursor_x` movement is more flexible than a specific indent option
- Works for: first-line indent, bullet offsets, nested blocks, hanging indents

### 5. Naming conventions
- `write*` - text output (write, writeAt, writeStyled, writeFlow)
- `draw*` - graphics (drawLine, drawRect, drawCircle, drawPath, drawImage, drawSvg)
- `load*` - load external resources (loadFont, loadImage, loadSvg)
- `set*` / `get*` - state configuration
- `measure*` - measurement without rendering
- Avoid "region" in variable names - use "textbox" or "box"

### 6. Options structs with defaults
Use structs with sensible defaults for optional parameters:
```zig
var st = doc.createStyledText();
defer st.deinit();
try st.append(text, .{});
_ = try doc.writeStyled(&box, &st, .{});  // all defaults
_ = try doc.writeStyled(&box, &st, .{ .alignment = .justify });
```

## Zig 0.15 Compatibility Notes

The project targets Zig 0.15 which has significant API changes from earlier versions:

- **I/O**: Uses new buffered `File.Reader` and `File.Writer` with explicit buffer parameters
- **ArrayListUnmanaged**: Allocator passed to each method, not stored
- **XML**: No `std.xml` - we implement our own simple XML parser if needed
- **ZIP**: `std.zip` exists but with lower-level API; MXL support pending

