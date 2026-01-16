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

### TrueType Font Embedding (Planned)

Enables custom fonts beyond Base 14, including Unicode support.

**TTF tables to parse:**
- `head` - font header (units per em, bounds)
- `hhea` - horizontal metrics header
- `hmtx` - glyph widths (for text measurement)
- `cmap` - Unicode → glyph ID mapping
- `glyf` - glyph outlines (for subsetting)
- `loca` - glyph locations in glyf table
- `maxp` - number of glyphs

**PDF structures needed:**
```
% Font dictionary
<< /Type /Font
   /Subtype /TrueType
   /BaseFont /MyFont
   /FirstChar 0
   /LastChar 255
   /Widths [...]
   /FontDescriptor 5 0 R
   /Encoding /WinAnsiEncoding  % or /Identity-H for Unicode
>>

% Font descriptor
<< /Type /FontDescriptor
   /FontName /MyFont
   /Flags 32
   /FontBBox [...]
   /ItalicAngle 0
   /Ascent 900
   /Descent -200
   /CapHeight 700
   /StemV 80
   /FontFile2 6 0 R  % embedded TTF stream
>>
```

**Implementation phases:**
1. TTF parser - read tables, extract metrics
2. Full embedding - embed entire font (simple, larger files)
3. Subsetting - include only used glyphs (complex, smaller files)
4. Unicode support - ToUnicode CMap for copy/paste

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
- Text positions (within 5pt tolerance)
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

## Flow & Region API (Planned)

A measure-first approach for layout control. Users can query dimensions before rendering,
avoiding backtracking loops.

### Core Types

```zig
/// Measured dimensions of text
const TextMetrics = struct {
    width: f64,      // in points
    height: f64,     // in points (line height)
    lines: usize,    // number of lines (for wrapped text)
};

/// A rectangular area for content placement
const Region = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    cursor_y: f64,   // current vertical position within region

    /// Space remaining before region is full
    fn remainingHeight(self: Region) f64;

    /// Check if text metrics fit in remaining space
    fn fits(self: Region, metrics: TextMetrics) bool;
};

/// Result of writeFitting - what was written and what overflowed
const WriteResult = struct {
    written: []const u8,    // text that was rendered
    overflow: ?[]const u8,  // text that didn't fit (null if all fit)
};
```

### Core Primitives

```zig
/// Measure text without rendering (cheap - font metric lookup)
fn measureText(doc: *Document, text: []const u8) TextMetrics;

/// Measure wrapped text within a width constraint
fn measureWrappedText(doc: *Document, text: []const u8, max_width: f64) TextMetrics;

/// Write text that fits, return overflow
fn writeFitting(doc: *Document, region: *Region, text: []const u8) WriteResult;
```

### Usage Patterns

**Simple flow (single pass):**
```zig
var region = Region{ .x = 50, .y = 50, .width = 500, .height = 700 };
var text = content;
while (text.len > 0) {
    const result = doc.writeFitting(&region, text);
    text = result.overflow orelse break;
    // Start new page/column
    doc.addPage();
    region = Region{ ... };
}
```

**Balanced columns (two pass):**
```zig
// Pass 1: measure total
const metrics = doc.measureWrappedText(content, column_width);
const per_column = metrics.height / num_columns;

// Pass 2: render with split points
// ...
```

**Screenplay with sentence breaks:**
```zig
while (remaining.len > 0) {
    const sentence = extractNextSentence(remaining);
    const metrics = doc.measureText(sentence);

    if (region.fits(metrics)) {
        doc.write(&region, sentence);
        remaining = remaining[sentence.len..];
    } else {
        // New page with CONT'D header
        doc.addPage();
        region = newDialogRegion();
        doc.write(&region, character ++ " (CONT'D)");
    }
}
```

### Design Principles

1. **Measure is cheap** - Font metric lookups, no PDF writing
2. **No backtracking** - Measure → decide → render (never undo)
3. **User controls flow** - Library provides primitives, user code handles breaks
4. **Single source of truth** - Positions come from regions, not separate state

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

