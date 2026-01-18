# PDF rendering library

## Architecture

### Modules
- `zpdf.zig` - Main library entry, Document API
- `objects.zig` - PDF object types (Dict, Array, Value, Ref, Name)
- `fonts.zig` - Standard PDF fonts (Base 14)
- `metrics.zig` - Font metrics, text measurement, spacing
- `writer.zig` - PDF serialization (header, objects, xref, trailer)
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
- No stream compression (Zig 0.15 std.compress.flate has incomplete implementation)
- WinAnsiEncoding only (no full Unicode/CJK support yet)

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

**Future enhancements:**
1. FlateDecode compression for FontFile2 stream (when Zig std lib ready or via C zlib)
2. CIDFont (Type0) support for full Unicode text (CJK, emoji, etc.)
3. OpenType CFF font support

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

**Test cases:**
- `minimal.pdf` - Empty page
- `hello_world.pdf` - Single text
- `multi_font.pdf` - Multiple font families
- `all_fonts.pdf` - All 14 standard fonts
- `multi_page.pdf` - Multi-page document

## Text API

Naming convention: `write*` for text, `draw*` for graphics (future).

### Functions

| Function | Purpose |
|----------|---------|
| `write(str)` | Write at cursor position |
| `writeAt(x, y, str)` | Write at specific position |
| `writeLine(&region, opts)` | Single line in region, no wrap, advances cursor |
| `writeParagraph(&region, opts)` | Wrapped text in region, returns overflow |
| `writeFlow(str, opts)` | Convenience: auto-adds pages on overflow |

### Margins and Page Regions

```zig
// Set document margins (optional - defaults to 72pt / 1 inch)
doc.setMargins(.{ .left = 72, .right = 72, .top = 72, .bottom = 72 });

// Get region for current page (respects margins)
var region = doc.getPageRegion();
// → Region{ .x = 72, .y = 72, .width = 468, .height = 648, ... }
```

Margins don't magically affect `writeAt()` - they only define what `getPageRegion()` returns.

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

/// A rectangular area for content placement
const Region = struct {
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
    pub fn remainingHeight(self: Region) f64;

    /// Usable width inside padding
    pub fn contentWidth(self: Region) f64;

    /// Check if text metrics fit in remaining space
    pub fn fits(self: Region, m: TextMetrics) bool;
};

/// Result of writeLine/writeParagraph
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

/// Options for writeLine (single line, no wrap)
const LineOptions = struct {
    alignment: Align = .left,
    valign: VAlign = .top,
};

/// Line breaking algorithm
const LineBreaking = enum {
    greedy,   // Fill each line as much as possible (fast, default)
    optimal,  // Knuth-Plass: minimize total badness across all lines
};

/// Options for writeParagraph (wrapped text)
const ParagraphOptions = struct {
    alignment: Align = .left,
    valign: VAlign = .top,
    first_indent: f64 = 0,
    break_on_hyphens: bool = true,    // Break at regular hyphens (false for fpdf2 compat)
    line_breaking: LineBreaking = .greedy,  // Algorithm for line breaks
};

/// Options for writeFlow (convenience auto-page)
const FlowOptions = struct {
    alignment: Align = .left,
    first_indent: f64 = 0,
};
```

### Function Signatures

```zig
fn write(self: *Document, text: []const u8) !void
fn writeAt(self: *Document, x: f64, y: f64, text: []const u8) !void
fn writeLine(self: *Document, region: *Region, text: []const u8, opts: LineOptions) !WriteResult
fn writeParagraph(self: *Document, region: *Region, text: []const u8, opts: ParagraphOptions) !WriteResult
fn writeFlow(self: *Document, text: []const u8, opts: FlowOptions) !void

/// Draw region's border/fill (without text)
fn drawRegion(self: *Document, region: *const Region) !void
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
    .first_indent = 20,  // paragraph indent
});
```

**Manual region control:**
```zig
var region = doc.getPageRegion();
var remaining: ?[]const u8 = text;

while (remaining) |txt| {
    const result = try doc.writeParagraph(&region, .{ .text = txt });
    remaining = result.overflow;
    if (remaining != null) {
        try doc.addPage(.a4);
        region = doc.getPageRegion();
    }
}
```

**Multi-column layout:**
```zig
var left = Region{ .x = 50, .y = 50, .width = 230, .height = 700 };
var right = Region{ .x = 310, .y = 50, .width = 230, .height = 700 };

var remaining: ?[]const u8 = text;
for ([_]*Region{ &left, &right }) |region| {
    if (remaining) |txt| {
        const result = try doc.writeParagraph(region, .{ .text = txt });
        remaining = result.overflow;
    }
}
// remaining still has text? Add page, repeat...
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
_ = try doc.writeParagraph(&region, text, .{ .valign = .middle });
```

### Design Principles

1. **Measure is cheap** - Font metric lookups, no PDF writing
2. **No backtracking** - Measure → decide → render (never undo)
3. **User controls flow** - Library provides primitives, user handles page/column breaks
4. **Explicit regions** - Margins don't magically affect positioning; ask for `getPageRegion()`
5. **Single source of truth** - When using regions, the region's cursor is authoritative; don't mix with `setXY()`
6. **Layered API** - Simple (`writeFlow`) to powerful (`writeParagraph` + manual regions)
7. **Explicit over magic** - VAlign provides control; no hidden adjustments

## Graphics Support (Planned)

### Image Embedding
| Format | Implementation | Use Case |
|--------|---------------|----------|
| JPEG | Embed raw bytes, DCTDecode filter | Photos |
| PNG | Decode, FlateDecode, alpha as soft mask | Screenshots, diagrams |
| PDF | Parse & embed as Form XObject | Vector figures, graphs |

**PDF embedding** is the key feature for technical documents:
- Figures from matplotlib, R, gnuplot export as PDF
- Diagrams from Illustrator, Inkscape export as PDF
- Preserves vectors, fonts, colors perfectly
- Scalable and repositionable

```zig
const fig = try doc.loadPdf("plot.pdf");
doc.drawPdf(fig, x, y, .{ .scale = 0.5 });
```

### Drawing Primitives
PDF content stream operators for programmatic drawing:

**Shapes:**
- `line(x1, y1, x2, y2)` - single line
- `rect(x, y, w, h, mode)` - rectangle (stroke/fill/both)
- `circle(cx, cy, r, mode)` - circle
- `ellipse(cx, cy, rx, ry, mode)` - ellipse

**Path API:**
```zig
doc.path()
   .moveTo(x, y)
   .lineTo(x2, y2)
   .curveTo(cp1x, cp1y, cp2x, cp2y, x3, y3)  // cubic Bézier
   .closePath()
   .stroke();  // or .fill() or .fillStroke()
```

**Styling:**
```zig
doc.setStrokeColor(r, g, b);
doc.setFillColor(r, g, b);
doc.setLineWidth(1.5);
doc.setLineCap(.round);
doc.setLineJoin(.miter);
doc.setDash(&.{4, 2}, 0);  // dash pattern
```

## Zig 0.15 Compatibility Notes

The project targets Zig 0.15 which has significant API changes from earlier versions:

- **I/O**: Uses new buffered `File.Reader` and `File.Writer` with explicit buffer parameters
- **ArrayListUnmanaged**: Allocator passed to each method, not stored
- **XML**: No `std.xml` - we implement our own simple XML parser if needed
- **ZIP**: `std.zip` exists but with lower-level API; MXL support pending

