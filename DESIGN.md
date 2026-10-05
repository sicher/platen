# PDF rendering library

## Architecture

### Modules
- `platen.zig` - Main library facade, re-exports from document.zig
- `version.zig` - Version constants (version, name, full)
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
- `binary.zig` - Big-endian serialization helpers for font table construction
- `images.zig` - JPEG/PNG parsing and embedding
- `svg.zig` - SVG parsing and Form XObject generation
- `xml.zig` - Minimal XML parser for SVG
- `path.zig` - Path builder API
- `gradient.zig` - Linear/radial gradient support
- `color.zig` - Color types (grayscale, RGB, CMYK)
- `layout.zig` - Layout types (Point, TextBox, Margins, Padding)
- `zlib.zig` - FlateDecode compression via std.compress.flate (zlib container)
- `pdfa.zig` - PDF/A conformance (validation, XMP metadata, ICC profile)
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
1. FlateDecode compression for all streams (via std.compress.flate)
2. CIDFont (Type0) support for full Unicode text (CJK, emoji, etc.)
3. OpenType CFF font support (CIDFontType0C)
4. OpenType GSUB/GPOS (ligatures, kerning, mark positioning)
5. COLR v1 / CPAL color fonts → PDF Type3 color fonts (color emoji)

### Color Fonts (COLR/CPAL, OT-SVG and CBDT/sbix → Type3)
Color glyphs (e.g. Noto Color Emoji, Bungee Color) are rendered as **PDF Type3
color fonts**, one per color font used in the document. Both **COLR v0** (flat
layered solid colors) and **COLR v1** (the paint graph) are supported; the
renderer prefers the v1 paint for a glyph and falls back to v0 layer records.
**OT-SVG** color fonts are supported via `src/svg_table.zig` (the 'SVG '
document list; single-glyph uncompressed documents only — gzipped and
multi-glyph docs fall back to the mono outline) rendered through the
existing `svg.zig` SVG→PDF-ops parser into `d0` CharProcs; OT-SVG's y-down
glyph space maps exactly to svg.zig's `1 0 0 -1 0 0` flip since the docs
declare no size/viewBox. Documents using transparency or text fall back to
the mono outline (Type3 shared resources can't carry per-glyph /GS state).
Source priority per font: COLR > SVG > bitmap.
**Bitmap emoji** (CBDT/CBLC and sbix PNG strikes) are also supported: when a
font has neither COLR nor SVG, `src/bitmap_glyphs.zig` extracts
the largest strike's PNG per glyph (CBDT image formats 17/18/19, index formats
1–5; sbix 'png ' + 'dupe' records), each becomes an image XObject (+ SMask for
alpha, via the images.zig PNG pipeline), and the CharProc places it with a
`cm`/`Do` scaled by upem/ppem (`renderBitmapGlyphCharProc`; `/Im{n}` under the
Type3 Resources /XObject). **Pixel fonts** (OTB: EBDT/EBLC 1-bit strikes,
e.g. Cozette) reuse the same parser (EBLC == CBLC layout; image formats
1/2/5/6/7, bit- or byte-aligned rows repacked via `packMonoRows`) but emit
each glyph as a 1-bit **ImageMask** (`/Decode [1 0]`, EBDT bit 1 = ink) with
a `d1` CharProc, so pixel glyphs are painted in the current text color.
EBDT is only used when the font has no real outlines (glyf missing or
zero-length) — outline+strike CJK fonts keep their scalable outlines.
Bitmap-only fonts without glyf get a synthesized all-empty loca so the CID
companion font still embeds.

- **`src/colr.zig`** parses CPAL (palettes), COLR v0 (base-glyph + layer records)
  and COLR v1 (base-glyph paint graphs + layer list), and glyf/loca outlines. `PaintInterp` walks a base glyph's paint
  graph and emits PDF drawing operators in glyph space (font units, y-up):
  solids (`rg`/`f`), axial/radial gradients (as `/Shading` + `sh`, three-point
  linear reduced to a two-point axial), sweep gradients (PDF has no conic
  shading — approximated as a 120-wedge flat-colored triangle fan over the
  absolute [0°,360°) domain, angles biased `(F2Dot14 + 1) × 180°`, extend
  pad/repeat/reflect applied to `t`; wedges overlap 0.3° and the apex is pushed
  4 units past the center to hide AA seams), glyph-outline clips (`W n`), affine
  transforms (`cm`), and composites. Alpha < 1 wraps in a `/ca` ExtGState.
  Composite handling: blend modes 13..27 map to PDF `/BM` names (spec enum:
  SCREEN=13 … MULTIPLY=23, HSL modes 24..27); Porter-Duff CLEAR/SRC/DEST/
  DEST_OVER are exact by paint order; SRC_IN/OUT & DEST_IN/OUT with a solid
  mask branch reduce to "content at mask alpha" (`renderMasked`, threads an
  `alpha_scale` into solid fills so their own `/ca` composes); ATOP/XOR/PLUS
  fall back to source-over. Unbounded fills (solid/gradient/sweep with no
  enclosing PaintGlyph clip, `clip_depth == 0`) are skipped — ClipBox is not
  implemented, and e.g. Noto's SRC_IN backdrop solids would otherwise cover
  the page. Shadings/ExtGStates accumulate in a shared `ColorResources`.
- **`src/document.zig`** owns the emission (see `ColorFontPlan`, `buildColorFontPlans`,
  `writeColorFont`, `renderColorText`):
  - Pre-pass over page text (before object-ID reservation) collects the color gids
    each font uses, assigns 1-based ordinals, and renders one CharProc per glyph
    (`wx 0 d0` + paint ops). Every 255 ordinals open a new Type3 **subfont**
    (`/Tc{n}`, then `/Tc{n}s1`, `/Tc{n}s2`, …): ordinal → subfont `(ord-1)/255`
    + single-byte code `(ord-1)%255+1` (`slotFor`). Each subfont gets its own
    font dict + ToUnicode; CharProc streams are one contiguous object block;
    all subfonts share the plan's Resources.
  - Type3 font dict: `FontMatrix [1/upem …]` (full precision — do **not** use
    `Value.real`, which truncates to 3 decimals), `FontBBox` from head, `Encoding`
    Differences `/g1…/gN`, `Widths` in font units, `Resources` with the plan's
    `/Sh{n}` shadings and `/Ga{n}` ExtGStates.
  - Content emission segments a run into color (`/Tc{n}` Type3, 1-byte codes) and
    mono (`/E{n}` CID, 2-byte gids) sub-runs sharing one text position; advances
    agree because Type3 `Widths`×`FontMatrix` == the CID `/W` value. Kerning/marks
    are not applied inside a color-containing run.
  - The Type3 font carries a `/ToUnicode` CMap (single-byte codespace, astral
    codepoints as UTF-16 surrogate pairs) so emoji are text-extractable/copyable.
- **Testing**: unit tests in `colr.zig` (v0 + v1 parse/render, gradients, sweep
  wedge fan) and `document_test.zig` (Type3 structure, FontMatrix precision,
  segmentation, PDF/A skip), plus reference integration tests: `color_emoji`
  (v1, Noto Color Emoji), `color_v0` (Bungee Color, OFL), `color_v1_gradient`
  (Bungee Spice, v1 linear gradients on a Latin font), `color_sweep`
  (SweepTest, a generated fixture — rebuild with `scripts/gen_sweep_font.py`),
  `color_split` (300 Noto emoji across two Type3 subfonts), `color_bitmap`
  (SbixTest/CbdtTest fixtures — rebuild with `scripts/gen_bitmap_fonts.py` —
  plus a real 12-emoji fontTools subset of Google's Noto CBDT build),
  `pixel_font` (Cozette OTB, MIT) and `color_svg` (Bungee Color SVG,
  mirroring color_v0 so the OT-SVG and COLR v0 builds of the same design
  can be compared — they render 98.7% pixel-identical, differing only in
  the title text).
  fpdf2 cannot emit COLR, so these references are **generated by platen** and
  manually maintained (listed in `EXCLUDED_TESTS` in `gen_references.py`);
  regenerate by copying `test/output/<name>_actual.pdf` after a test run.
- **Known limits**: color/bitmap Type3 output is disabled entirely under
  PDF/A (`conformance != .none`); COLR ClipBox/variations (var_* deltas)
  ignored; OT-SVG docs must be uncompressed, single-glyph, and free of
  transparency/text/gradients (else mono-outline fallback); bitmap strikes
  must be PNG or 1-bit mono (no JPEG/TIFF sbix, no 2/4/8-bit grayscale
  EBDT, no EBDT composite formats 8/9).

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
- `platen check-refs` - Run semantic comparison, generate HTML report

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

### Fuzzing (fuzz_tests.zig)

Two layers, both seeded with real tables/files from test fixtures:
- **Coverage-guided targets** (`zig build test --fuzz`): TTF, PNG/JPEG, SVG,
  COLR/CPAL + paint interpreter, CBDT/CBLC (also covers EBDT/EBLC), sbix,
  OT-SVG table, and a Smith-driven Document API sequence. Under a plain
  `zig build test` each target runs once per corpus seed as a smoke test.
  Note: interrupting `--fuzz` can print infra panics from Zig's fuzzer
  teardown ("failed to open coverage file"); these are not findings.
- **Deterministic mutation tests**: seeded bit flips/byte stomps/truncations
  of the fixture tables run on every `zig build test`, so parser-robustness
  regressions fail CI-style rather than only under `--fuzz`.

Hardening invariants the fuzzers enforce (added after real findings):
- **Number validation at the Document boundary** (validate.zig): every f64
  a caller passes to a fallible entry point must be finite and within
  ±`max_value` (1e6), else `error.InvalidNumber` before any mutation.
  Error, not clamp (user decision 2026-10-05): a moved coordinate is a
  wrong document. The limit is what keeps format.writeF64N (u64 integer
  part) and the fixed content-stream buffers safe - including derived
  values such as scaleAt's center*(1-s) products (<= 1e12). `check()`
  walks struct/union/optional/array fields at comptime, so new style
  fields are covered automatically; slices (polygon points, path
  commands, StyledText spans, gradient stops) are checked explicitly.
  Public entry points that delegate must not re-validate derived values
  (drawCircle -> private emitEllipse, not drawEllipse).
  `invalid_number_test.zig` runs every entry point against NaN/inf/1e300
  and asserts the document is unchanged.
- Color-font table parsers (colr, bitmap_glyphs, svg_table) use the
  bounds-checked readers in binary.zig and **clamp every record count at
  parse time** to what physically fits in the table — a malformed count
  must never drive a lookup loop or its offset arithmetic.
- `colr.PaintInterp` bounds work per render with `ops_budget` (65536 paint
  visits) in addition to the recursion depth cap: depth alone lets cyclic
  ColrLayers/ColrGlyph graphs expand combinatorially.
- **Offsets and lengths read from files widen to usize at the read**
  (`const off: usize = readU16(...)`), never added in their on-disk
  u16/u32 width: `u16 + u16` overflows (panic in safe builds, wrong
  bounds in release). Bounds checks use the subtraction form
  (`off > len or n > len - off`) when operands may be full-width.
  Values that must narrow (glyph IDs) go through std.math.cast and an
  out-of-range result means "absent", not a crash. (2026-10-05 audit:
  ~45 sites across the parsers.)
- Any parser loop over hostile input must provably advance its cursor
  (regression tests: xml.zig unterminated attribute quote, svg.zig
  path-data garbage after Z).

## Text API

Naming convention: `write*` for text, `draw*` for graphics (future).

### Functions

| Function | Purpose |
|----------|---------|
| `write(str)` | Write at cursor position |
| `writeAt(x, y, str)` | Write at specific position |
| `writeStyled(&region, *StyledText, opts)` | Styled text in region, returns overflow |
| `write(&region, str, .{ .measure_only = true })` | Measure layout without rendering |

### Text Opacity

`TextStyle.opacity` (0.0–1.0, default 1.0) sets the fill (non-stroking) alpha for
glyphs and their decorations. Non-opaque text is emitted as a text object wrapped in
`q /GSn gs BT … ET Q`, where `/GSn` is a per-page ExtGState with `ca N` — the same
opacity-state registry used by shapes, so identical alphas dedup to one resource.
The alpha is applied at render time (`renderPageCommands`), which runs before page
resources are built, so the registered state is picked up automatically. PDF/A-1b
rejects `opacity < 1.0` with `error.TransparencyNotAllowed` at write time.

```zig
const style = TextStyle{ .font = Font.helvetica, .size = 24, .opacity = 0.5 };
_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Semi-transparent", style);
```

### Text Measurement

Use `write()` or `writeStyled()` with `.measure_only = true` to measure text layout without rendering.
Measurement is side-effect free - cursor position is unchanged. Uses the same code path as rendering.

```zig
var region = platen.Region{
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
    .producer = "platen",         // Default - PDF producer
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
    top,          // optical: baseline at content_y + cap_height (default)
    top_ascent,   // optical: baseline at content_y + ascender
    top_leading,  // legacy: baseline at content_y + (line_height + asc - desc) / 2
    middle,       // baseline centered, fpdf2 compatible
    bottom,       // baseline at content_y + line_height
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
// `io` is required for any file I/O the document performs
// (loadFont/loadImage/loadSvg). Pass `init.io` from main, or
// `std.testing.io` from tests.
var doc = platen.Document.init(allocator, io);
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

Vertical alignment controls where text sits within each line cell. Uses real font metrics
from the OS/2 table (cap_height, ascender, descender) for precise optical alignment.

```zig
// valign: .top (default) - optical cap-height alignment
baseline = content_y + cap_height   // capitals touch top edge

// valign: .top_ascent - optical ascender alignment
baseline = content_y + ascender     // ascender line touches top edge

// valign: .top_leading - legacy half-leading
baseline = content_y + (line_height + ascender - descender) / 2

// valign: .middle - text centered in line height
baseline = content_y + line_height/2 + ascender/2

// valign: .bottom - baseline at bottom of line height
baseline = content_y + line_height
```

**Note**: fpdf2 uses a fixed heuristic (`0.5*h + 0.3*fontSize`) that doesn't read font metrics.
The `.top_leading` mode is closest to fpdf2 behavior but still differs slightly because it
uses real ascender/descender values.

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
// Lines with stroke style
try doc.drawLine(p1, p2, .{ .color = Color.blue, .width = 2 });

// Shapes with fill, stroke, or both
try doc.drawRect(rect, .{ .fill = .{ .color = Color.red } });
try doc.drawCircle(center, radius, .{ .stroke = .{ .width = 1.5 } });
try doc.drawEllipse(rect, .{ .fill = .{}, .stroke = .{} });  // both
try doc.drawPolygon(&points, .{ .fill = .{ .color = Color.green } });

// Opacity support (0.0-1.0, uses PDF ExtGState)
try doc.drawRect(rect, .{
    .fill = .{ .color = Color.red, .opacity = 0.5 },
    .stroke = .{ .color = Color.black, .opacity = 0.8 },
});
```

Opacity states are deduplicated per-page: shapes and text that request the same
`(fill, stroke)` alpha pair share a single `/GSn` ExtGState resource. Text opacity
(`TextStyle.opacity`) reuses the exact same registry (see Text API).

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
var gradient = platen.LinearGradient.init(x1, y1, x2, y2);
gradient.addStop(0.0, platen.Color.fromRgb(1, 0, 0));  // red at start
gradient.addStop(1.0, platen.Color.fromRgb(0, 0, 1));  // blue at end
try doc.drawLinearGradient(&gradient, x, y, w, h);

// Radial gradient
var radial = platen.RadialGradient.init(cx, cy, r);
try doc.drawRadialGradient(&radial, x, y, w, h);
```

### Styling

Shape styles are passed directly to draw methods:

```zig
// StrokeStyle options
.stroke = .{
    .color = Color.black,       // default
    .width = 0.567,             // default (1px at 72dpi)
    .cap = .square,             // .butt, .round, .square
    .join = .miter,             // .miter, .round, .bevel
    .dash = .{ .dash = 4, .gap = 2, .phase = 0 },
    .opacity = 1.0,             // 0.0-1.0
}

// FillStyle options
.fill = .{
    .color = Color.black,       // default
    .opacity = 1.0,             // 0.0-1.0
}
```

### Graphics state: transforms & clipping (session #24)

`pushState`/`popState` (PDF `q`/`Q`), `translate`, `rotateAt(center,
degrees)`, `scaleAt(center, sx, sy)`, `clipRect`, `clipPath` (`W n`).

Design points:
- **User-space semantics**: y-down, top-left origin, positive rotation =
  clockwise — CSS/Canvas conventions. Each user-space affine T is
  conjugated with the page y-flip F into the PDF `cm` matrix: M = F·T·F
  (F is self-inverse). One derivation in `Document.applyTransform`
  instead of hand-tuned signs per operation; conjugation composes
  correctly across sequential transforms because F·F = I.
- **Deferred raw commands**: transforms/clips append `.raw` content
  commands, so they interleave with text/shape commands in emission
  order and apply to every content type.
- **Balance enforcement**: `Page.state_depth` tracks push/pop;
  `popState` underflow and unbalanced state at `output()` are errors
  (`error.UnbalancedGraphicsState`).
- Page-level `/Rotate` is separate: `PageOptions.rotation` (viewer
  rotation, no coordinate change).

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

## PDF/A Conformance

PDF/A is the ISO standard for long-term archival of electronic documents.

### Supported Levels

```zig
pub const Conformance = enum {
    none,      // Default - no restrictions
    pdfa_1b,   // PDF 1.4, no transparency, all fonts embedded
    pdfa_2b,   // PDF 1.7, transparency allowed
    pdfa_3b,   // PDF 1.7, embedded files allowed
};
```

### Usage

```zig
var doc = Document.init(allocator, io);
doc.setConformance(.pdfa_1b);  // Enable PDF/A-1b

// For full compliance, use embedded fonts
const font = try doc.loadFont("path/to/font.ttf", null);
const style = TextStyle{ .font = font, .size = 12 };
_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello", style);

// Transparency rejected for PDF/A-1b
try doc.drawRect(rect, .{ .fill = .{ .opacity = 0.5 }});
// Returns error.TransparencyNotAllowed
```

### PDF/A Output Structures

When conformance != `.none`, the output includes:

1. **XMP Metadata stream** - XML with Dublin Core, PDF/A identification (`pdfaid:part`, `pdfaid:conformance`)
2. **OutputIntent dictionary** - References ICC profile, `S=GTS_PDFA1`
3. **ICC Profile stream** - Embedded sRGB IEC61966-2.1 (~3KB)
4. **MarkInfo dictionary** - `/Marked false` in catalog
5. **Document ID** - Hex string in trailer

### Validation

Use VeraPDF for validation:
```bash
platen pdfa-test output.pdf
verapdf --flavour 1b output.pdf
```

### Known Limitations

- **Standard fonts**: PDF/A requires embedded fonts. Using standard fonts (Helvetica, etc.) will fail VeraPDF validation. Use `loadFont()` for compliance.
- **CID fonts**: VeraPDF shows validation warnings for CID font embedding that may require further investigation.

## Performance & Concurrency (sessions #23/#24)

### Measurement invariant
`measureStyled`/`measureTextWidthSpaced` must agree with what rendering
draws. Three rules keep it true:
- Measurement runs the same GSUB pipeline as rendering when
  substitutions are active (`hasActiveGsub`), then sums final glyph
  advances + kerning + char_spacing per rendered glyph (Tc semantics).
- OT tables parse lazily, but measurement triggers the parse too
  (`anyShapingFeatureEnabled`) so pre-render measurements don't miss
  kerning.
- `writeAt` never measures separately: `writeTextStyled` returns the
  width computed from its own shaped run, and anchoring (.center/.right)
  shifts the just-appended deferred command. Every string is shaped
  exactly once.

### Concurrency model
- **Documents share nothing** — one Document per thread renders
  concurrently without locking (documented guarantee; ~4.7x on 8-core
  M1 Pro). A single Document is not thread-safe.
- `doc.compress_threads = N`: `output()` compresses page-content and
  font-subset streams on a worker pool. The writer consults a
  pointer-keyed map of precompressed results and falls back inline on
  any miss; output bytes are identical regardless of thread count
  (regression-tested). Requires a thread-safe allocator.

### Hot-path notes (invoice benchmark, session #23)
- `FeatureFlags.featureIndex`: comptime-sorted table + binary search
  (a linear scan over ~150 features was 33% of runtime).
- Kerning cache: direct-mapped 4096-slot array in OpenTypeFeatures
  (collisions overwrite; correctness unaffected).
- Image pixel streams always compress at level >= 6
  (`imageCompressionLevel`): compressed once at load, dominate file
  size — fast levels are a bad trade there.

### FontFace (sessions #25/#26)
`FontFace.fromMemory/fromFile` parses a font once — ttf tables, metrics,
and **all** OpenType lookups eagerly (`parseGSUB` → `parseAllGSUBLookups`,
so nothing parses lazily later). Faces go directly into styles
(`Font{ .face = &f }`, `Font{ .family = ... }`); the Document normalizes
such styles at its public entry points (writeTextStyled, measureStyled,
getTextWidthStyled, getFontMetricsStyled) into a per-document
`EmbeddedFont` clone held in `face_instances`, so internal layout/render
layers only ever see `.embedded`. The clone is a struct copy sharing the
immutable parsed tables while all mutable state is fresh and owned (glyph
tracking maps, subset data, scratch buffers, OT scratch/kern-cache).
Borrow flags (`EmbeddedFont.borrowed`, `OpenTypeFeatures.borrowed_tables`)
make deinit skip shared memory. Two-phase life cycle: configuration
(setFeature/warmup) until the first instantiation freezes the face
(`error.FaceFrozen` afterwards - flag changes wouldn't propagate and
warmup would race with cloning). Safe across threads because clones never
write to shared structures; contract: face output is byte-identical to
per-document parsing (regression-tested).

Two prerequisites make this sound — if either changes, revisit:
- `ttf.Font` mutates only during parse (cmap offsets, ascii caches).
- GSUB/GPOS parse everything eagerly; shaping only reads lookup tables.

### Svg render-time constness (session #26 audit)
`Svg.toPdfContent` takes `*const Svg`: opacity pairs discovered during
rendering land in a caller-owned output list (the document builds the
/GS{n} ExtGState resources from it), instead of mutating the Svg. This
makes shared SVGs genuinely thread-safe - previously any SVG with
opacity < 1.0 appended to itself during output(), a data race for
cross-thread sharing that single-threaded dedupe masked. The transparency
signal color-font code relies on is now the returned list's length.
Constness is compiler-enforced; no test can regress it silently.

### Asset cleanup
Image.deinit and Svg.deinit destroy the struct too (single call, matching
FontFace.deinit). Image.fromMemory takes (alloc, bytes) and always
borrows; ownership transfer lives on the internal fromMemoryLevel.

### Asset ownership
Uniform rule, enforced at use time: assets obtained from a Document
(loadFont/loadImage/loadSvg) are document-owned - using them in another
document errors (ForeignFont at write time; ForeignImage/ForeignSvg at
draw time, via the `document_owned` marker). Assets the caller creates
(FontFace.fromMemory/fromFile, Image.fromMemory, Svg.fromMemory) are caller-owned and
shareable. Rationale: fonts mutate (subset state - silent blank output +
cross-doc pollution before the guard); images/SVGs are immutable but
die with their owning document (dangling data at output time).
Scope: these are logic-error guards that require live memory - a
dangling pointer (owner already deinitialized) is UB before any check
runs, like any freed pointer in Zig. Structural prevention would need
document-scoped generational handles instead of pointers; judged not
worth the ergonomics cost.

`loaded_images`/`loaded_svgs` carry lockstep `*_owned` bools: documents
destroy only assets they created (loadImage*/loadSvg*). Assets
registered via drawImage/drawSvg are caller-owned, enabling one decoded
Image/Svg to be shared across many documents. Fonts remain per-document
(subsetting mutates them); a shared pre-parsed font API is future work
(TODO.md).

## Encryption (session #27)

AES-256 only, security-handler revision 6 (PDF 2.0) - no RC4/AES-128
legacy handlers. R6 uses one 32-byte file key for the whole document (no
per-object key derivation), so the writer hook is minimal: `Writer`
holds an optional `Encryptor`, and `writeStream`/`writeStreamPicking`
emit `IV ++ AES-256-CBC(PKCS#7)` in place of the raw body.

- `src/encrypt.zig` is self-contained: Algorithm 2.B (the iterated
  SHA-256/384/512 + AES-128 password hash), Algorithms 8/9/10 (U/UE/O/OE
  /Perms), the content Encryptor, and a SystemCsprng seeded from
  `std.c.arc4random_buf`.
- Determinism: encryption needs randomness (IVs, salts, file key, /ID),
  which collides with byte-identical guarantees. `Document.rng` is an
  injectable `std.Random` (defaults to the system CSPRNG); tests seed it.
  Unencrypted output is unchanged - the encryptor is null by default and
  byte-identity tests still pass.
- Scope: `/StmF /StdCF` (AESV3) encrypts streams; `/StrF /Identity`
  leaves strings cleartext. Strings serialize deep in Dict/Value.format
  with no encryptor in scope; encrypting them would need threading the
  key through objects.zig. Content streams carry all page text, fonts,
  and images, so the document body is protected; metadata strings are
  not. Full string encryption is a possible follow-up.
- Cost: the R6 KDF is ~5ms/document by design (password hardening) and
  runs per document (unique salts); content encryption is ~8us/stream.
  Interop is verified in the test suite: an integration test runs qpdf
  (an independent reader) on encrypted output - correct password decrypts
  and reports R=6, wrong password is rejected - skipping when qpdf is
  absent, like the reference-comparison tests.
- PDF/A forbids encryption: `output()` returns
  `error.EncryptionNotAllowedInPdfA`.

## API Design Guidelines

Principles for platen's public API:

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
- `getPageIndex()` returns 0-based page index
- `pageCount()` returns total page count

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

## Zig Compatibility Notes

The project targets Zig 0.17 (migrated from 0.16 on 2026-10-05). Key things to remember when extending the code:

- **0.17: no `**` operator.** Array repetition is gone. Use `@splat(v)` against a typed result (`x: [256]bool = @splat(false)`, or `@as([8]u8, @splat(0))` inside `++`). For comptime string repetition in tests use `testing.repeat(s, n)`.
- **0.17: `@typeInfo` enums are struct-of-arrays.** `.@"enum".fields` became parallel `field_names` / `field_values` slices.
- **0.17: build args.** `b.args` is gone; forward `zig build <step> -- ...` with `run.addPassthruArgs()`.
- **0.17: stock test runner.** The vendored `scripts/test_runner.zig` (a 0.16 `--fuzz` compile workaround) was deleted; upstream carries the fix.

- **`std.Io`-driven file I/O**. There is no implicit "current process" I/O in 0.16. `Document` carries an `io: std.Io` and threads it through `loadFont`, `loadImage`, `loadSvg`. Free functions that touch the filesystem (e.g. `ttf.Font.fromFile`, `Image.fromFile`, `Svg.fromFile`, `EmbeddedFont.fromFile`) take `io` as the first parameter. CLI / perf / integration entry points hold a module-level `app_io` that is initialised from `init.io` (or `std.testing.io` in test builds).
- **Writer interface**: `std.Io.Writer.fixed(buf)` for fixed-buffer writing; pass `&w` (a `*std.Io.Writer`) — there is no `.writer()` accessor. `w.buffered()` returns the slice written so far, `w.end` is the cursor. For dynamic buffers use `std.Io.Writer.Allocating`.
- **ArrayList / HashMap empty values**: declare with `.empty` rather than `{}` / `.{}`. The unified `ArrayList` is unmanaged by default; `ArrayListUnmanaged(T)` is now an alias.
- **Allocator**: `std.heap.GeneralPurposeAllocator` is renamed to `std.heap.DebugAllocator`; initialize with `var gpa: std.heap.DebugAllocator(.{}) = .init;`.
- **`main` signature**: `pub fn main(init: std.process.Init) !void`. Args via `init.minimal.args.toSlice(arena)`; default GPA via `init.gpa`; `std.Io` via `init.io`.
- **Time**: `std.time.timestamp` / `milliTimestamp` are gone. `pdf_output.milliTimestamp()` wraps `std.c.clock_gettime(.REALTIME, ...)` for our timing helpers.
- **Subprocess**: `std.process.Child.run` was replaced by `std.process.run(allocator, io, .{ .argv = ... })`.
- **Misc renames**: `std.meta.intToEnum` → `std.enums.fromInt`; `std.mem.trimLeft` → `std.mem.trimStart`.
- **XML**: No `std.xml` - we implement our own simple XML parser if needed.
- **ZIP**: `std.zip` exists but with lower-level API; MXL support pending.

