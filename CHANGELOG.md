# Changelog

## Unreleased

### Added

- **Every face of an installed family:** `platen.listSystemFontFaces(io,
  allocator, family, opts)` returns each face whose typographic family
  matches, whatever its weight or width (Light, Condensed, Black...), with its
  names, OS/2 weight and width, italic flag, file and face index, so the
  caller picks the face itself. `FamilyFace.load` reads its standalone sfnt
  bytes when needed. Matching, folders and tie-breaks between copies of a face
  are `findSystemFont`'s. CLI: `find-font <family> --all`.
- **Shaping without a document, and drawing glyphs by ID:**
  `platen.shapeText(allocator, &face, text, .{ .features = ... })` turns
  text into glyph IDs with advances, offsets (font units) and clusters (byte
  offsets into the text), reading the `FontFace` only (no Document, no I/O,
  any thread). `doc.drawGlyphs(text, glyphs, style)` draws glyphs by ID, each
  at its own position, and maps each to its cluster's text in ToUnicode, so a
  ligature or conjunct copies out as its characters. For layout engines that
  place every glyph themselves. Positioning is a GPOS engine run the way
  HarfBuzz's default shaper does: every lookup type (single, pair, cursive,
  mark-to-base, -ligature and -mark, contexts, extensions) in lookup order
  with lookup flags, `curs`, `dist`, `abvm` and `blwm` on by default, the
  `kern` table where GPOS has no kerning, marks zeroed by GDEF class and
  attachments propagated. Glyphs, clusters and positions are checked against
  HarfBuzz (test/shaping/harfbuzz_positions.txt, with a synthetic font
  holding every lookup type and flag). No script-specific shaping yet (Indic,
  Arabic, bidi). CLI: `shape-text <font>` (HarfBuzz's serialization),
  `glyphs <out.pdf> <font>`.
- **SVG gradients**: `<linearGradient>` and `<radialGradient>` fill and stroke
  shapes, paths and text through `url(#id)`, with an optional fallback color
  (`url(#g) red`). Both `gradientUnits` (`objectBoundingBox`, the default, and
  `userSpaceOnUse` with percentages of the viewport), `gradientTransform`, a
  radial focal point (`fx`, `fy`; outside the circle it draws a cone, as in
  SVG 2), and stops given as attributes or in `style`, at percentages, out of
  order or at one offset (a hard edge). Where SVG says a gradient paints a
  solid color (one stop; equal end points or zero radius: the last stop) or
  nothing (no stops; a missing reference without a fallback; a box without
  width or height, e.g. a horizontal line's), so does platen. Each is a PDF
  shading pattern in the SVG's form; colors are checked against resvg. Not yet:
  `href` between gradients, `stop-opacity`, and `spreadMethod` `reflect` and
  `repeat` (drawn as `pad`).
- **Fallback fonts**: `TextStyle.fallback` lists fonts for the characters
  `font` has no glyph for; each character is drawn in the first font that has
  it, combining marks staying with their base. Bold and italic use each
  fallback's own variant, and are synthesized where it has none (stroked
  outline, slanted text matrix, at FreeType's strengths). With
  `fallback_advance = .monospace` a fallback character takes the width of a
  space in `font`, centered (shrunk to fit when wider, as a CJK ideograph
  is): monospaced text, e.g. a screenplay in Courier with Cyrillic from
  another font, stays on its columns. Measurement,
  wrapping, anchoring and decorations follow the runs.
- **A font's own style and embedding permission**: `ttf.Font.style` (OS/2
  fsSelection, else head.macStyle) and `ttf.Font.fs_type` with `mayEmbed()`
  (false for Restricted License and Bitmap Embedding Only), so a caller
  picking system fonts can skip what may not be embedded. `platen font-info`
  prints both.
- **`platen fallback <out> <font> [--fallback FONT]... [--monospace]`**: writes
  stdin lines with fallback fonts and prints their widths.
- **`platen svg <in.svg> [out.pdf]`**: renders an SVG on a page of its own size
  (1 px = 1 pt).

### Changed

- **Color parsing is ochre's**: platen vendors
  [ochre](https://git.urverk.org/urverk/ochre) (color math and CSS color
  parsing, MIT) in `src/ochre/`, copied by `scripts/vendor-ochre vX.Y.Z` and
  compiled as its own module. platen still has no dependencies. SVG `fill` and
  `stroke` and `Color.hex` parse through it.
- **SVG colors read all of CSS Color 4**: `hsl()`, `oklab()`, `oklch()`, the
  modern `rgb(r g b / a)` syntax, `#RGBA` and `#RRGGBBAA`, and names in any
  case. Out-of-range values are clipped, as browsers do, and now rounded rather
  than truncated: `rgb(50%, 10%, 0%)` is 128, 26, 0 (it was 127, 25, 0). A
  color's alpha still counts only as `none` at 0, as for `rgba()` before.
- **`Color.hex` also reads the alpha forms** (`#RRGGBBAA`, `#RGBA`) when opaque,
  and returns null for a translucent one: a `Color` has no alpha to keep.

### Fixed

- **Characters a font lacks precomposed now draw from their parts**, as
  HarfBuzz does: "é" in a font with "e" and U+0301 but no "é" is decomposed
  (canonically, step by step, singletons and Indic nukta forms too) instead
  of drawn as .notdef. A missing space character (en, em, thin, hair,
  narrow no-break, figure, punctuation, ideographic...) takes the space
  glyph, and U+2011 the hyphen U+2010; shapeText gives such spaces
  HarfBuzz's widths (an en space half an em, a thin space a fifth).
- **Marks typed out of canonical order** (an acute before a dot below) are
  put in order before shaping, as HarfBuzz does, so they compose and attach
  the same either way.
- **A coverage table claiming more than 10,922 ranges (32,767 glyphs)
  crashed shaping** with an integer overflow; it is now bounded by the
  table's data like any other.
- **Fonts without GDEF classes** take nonspacing marks (Mn) for marks, as
  HarfBuzz does, rather than characters with a combining class.
- **Text made only of ligatures was embedded unsubset**: a font whose drawn
  text was all multi-character glyphs ("ffi" alone) looked unused to the
  subsetter, so the whole font file went into the PDF (Gentium: 971 KB).
- **A face platen cannot embed loaded anyway** and failed at output with
  `MissingTable`: outlines only in a table platen does not read (Apple's
  `hvgl`, as in PingFang UI). Loading now refuses it with
  `error.UnsupportedOutlines`, so a caller can pick another face.
- **Embedded text measured narrower than it was drawn**: measurement
  truncated each glyph's advance to 1/1000 em while the PDF's width arrays
  round it, so a Courier Prime character (599.6) measured 0.012 pt short at
  12 pt; anchored and aligned text drifted by that per character. Both now
  round the same way.
- **SVG gradient paint was black**: `fill="url(#g)"` counted as an unknown
  color, so the shape took its parent's fill, black by default, though the
  documentation listed gradients as supported.
- **SVG `<line>` and `<polyline>` with `stroke="none"` were stroked** (in the
  current stroke color), and without a stroke their path was left unpainted
  and open; it is now ended with `n`.
- An OT-SVG color glyph that uses a gradient now falls back to the plain
  outline, as one using transparency does (it was drawn black).
- **`Color.fromName("lightgoldenrodyellow")` was null**: the hand-written
  lookup table had lost it, though the constant was there. The table is now
  built at compile time from the constants, and a test checks all 148 against
  CSS Color 4 through ochre.

## 0.13.0 — 2026-10-22

### Added

- **Continuing styled text across regions:** `WriteResult.resume_at` (a
  `TextPosition`: word index plus byte offset, where writing stopped) and
  `ParagraphOptions.start`. Call `writeStyled` again with the same
  `StyledText` and `start = resume_at` to continue in the next column or page with
  every span and style intact. Before, the only continuation was
  `overflow`, which for styled text holds just the rest of one span -
  later spans were silently lost.
- `platen.Path`: the path builder type returned by `doc.createPath()` is
  now exported, so helpers can take a `*platen.Path`.
- **Complete GSUB:** every lookup type - single, multiple, alternate,
  ligature, context (formats 1-3), chained context (formats 1-3),
  extension, reverse chained - with lookup flags (ignore base glyphs /
  ligatures / marks, mark attachment classes, mark filtering sets, via
  GDEF), applied in lookup-list order over the whole run as HarfBuzz does,
  for any feature. Before, only single, ligature and chained context
  format 3 lookups were read, each wired to a few features. New default
  features, as in HarfBuzz: `ccmp`, `locl`, `rlig`, `clig` (turn off with
  `setFeature`). `ccmp` gives dotless i/j under accents (Gentium, Inter:
  `j́`, `ị́`, Lithuanian `į́`) and joins emoji ZWJ sequences, skin tones
  and flags into one glyph (Noto Color Emoji).
- **Default ignorables are removed:** U+FE0F/U+FE0E, ZWJ, ZWNJ, zero-width
  space, soft hyphen, word joiner, BOM and the other Default_Ignorable code
  points no longer draw (U+FE0F was .notdef in Noto Color Emoji, a soft
  hyphen passed to `writeAt` a visible hyphen) and add no width. During
  GSUB they are skipped where HarfBuzz skips them - ZWJ always, ZWNJ only
  in context - so keycaps (`1️⃣`), `❤️` and `🏳️‍🌈` join, `f`+ZWJ+`i` still
  ligates and ZWNJ still blocks ligatures. Their code points stay out of
  extracted text.
- **Variation sequences** (cmap format 14): a character followed by a
  variation selector draws as the glyph the font lists for the pair - CJK
  ideograph variants, text-style emoji with U+FE0E in Noto Emoji - as
  HarfBuzz does; unlisted selectors are dropped as before. `font-info`
  shows whether a font has them.
- CLI `shape <font> [+feat|-feat]...`: glyph IDs for each stdin line, as
  rendering shapes it.

### Fixed

- **Shaping differed from HarfBuzz** (found by the new differential
  test): Inter's `<->` became `<-` plus `>`, `case` together with `tnum`
  gave tabular but not case forms (features ran in a fixed order, not the
  font's lookup order), and Satoshi's `frac` gave no numerators or
  denominators.
- **CFF fonts lost contextual alternates:** a subset of a `.otf` font kept
  only the first glyph drawn for each character, so a contextual variant
  of a character already drawn plainly (Inter's raised hyphen in `A-B`
  after `a-b`) rendered as .notdef. Every drawn glyph is kept now, as for
  TrueType.
- **Translucent color-font gradients painted opaque:** COLRv1 gradient
  stops carry an alpha, which was dropped, so overlays meant to fade out
  covered the glyph - Noto's rainbow flag 🏳️‍🌈 came out grey, and about
  2,000 Noto Color Emoji glyphs had such gradients. Stop alpha is now
  drawn through a soft mask (or `/ca` when it is constant).
- **A color glyph without an outline painted the whole page:** Bungee
  Spice's space is a color glyph whose clip glyph has no contours; the
  empty clip was written as `W n` with no path, which sets no clip, so its
  gradient covered the page from that point on. Such paints are now
  skipped (an empty clip shows nothing).
- **Underlines and strikethroughs ran into the space a line wraps at**
  (`write()`): the line was drawn with its trailing space, and the
  decoration with it. The space now hangs past the line end, as in CSS,
  also when it ends one write() call and the next call's first word
  wraps; spaces inside the line stay decorated.
- **`write()` lost text before a double space:** line batching reset
  the line at every space it skipped, so `write("aa  bb")` drew only
  "bb" (at aa's place), and a call starting with a space mid-line lost
  it (`" over"` after `"jumps"` gave "jumpsover"). Spaces inside a line
  are kept as typed now.
- **SVG hairlines were rounded:** stroke widths were written with two
  decimals in SVG units (the tiger's 0.172 became 0.17); now four.
- **Bitmap-only fonts had an empty `FontBBox`:** an OTB pixel font's head
  box is 0 wide, so every glyph fell outside its Type3 font's box
  (poppler warned on each). Such fonts now get `[0 0 0 0]`, which tells
  viewers to make no assumptions about glyph sizes.
- **Color emoji ligatures extracted as U+FFFD:** the Type3 ToUnicode of
  a color font mapped only single code points, so a joined emoji (ZWJ
  family, flag, keycap) copied as a replacement character. It maps to the
  whole sequence now.
- **Text extraction of substituted glyphs:** ToUnicode now follows the
  shaped glyphs' clusters - a ligature maps to its characters, a glyph a
  multiple substitution produced to its own character of the
  decomposition - instead of re-guessing ligatures after shaping.
- **Words wider than the line lost their end at a region boundary:** a
  word broken over lines (soft hyphens, regular hyphens, or between
  characters) that reached the bottom of the region was cut off and
  layout went on with the next word. Writing now stops mid-word and
  `resume_at` carries the byte offset, so the next region continues the
  word (lines are the unit, as in TeX and CSS fragmentation). Pieces are
  measured in the span's own style (bold words were broken with regular
  widths).
- **Knuth-Plass put a too-wide word on one endless line:** with
  `.line_breaking = .optimal`, a word wider than the line made every
  break infeasible and the whole paragraph came out as a single line
  running past the region. Such a word now gets a line of its own and is
  broken into pieces, as with greedy breaking.
- **`measure_only` drew broken words:** measuring a paragraph containing
  a word wider than the line drew that word's pieces on the page.
- **Combining marks compose to the font's precomposed glyphs:** a base
  followed by combining marks (e.g. `i` + U+0308) was drawn as separate
  glyphs positioned by GPOS - or simply overprinted in fonts without mark
  positioning - giving a dotted i under a diaeresis. Like HarfBuzz,
  shaping now composes the sequence into the precomposed character
  (U+00EF) when the font has a glyph for it; otherwise it stays
  decomposed. Measurement and rendering share the decoding, and the
  ToUnicode text of such a glyph is the sequence as typed.
- **Unused fonts were embedded whole:** a font loaded into a document but
  never drawn with (only measured, or not used at all) has no glyphs to
  subset, so `output()` wrote the complete original font file as orphan
  objects - 25 MB for Noto Color Emoji. Only fonts some page draws with
  are written now.
- **Justified text in embedded Unicode fonts:** lines set in a single
  style were justified only through the PDF `Tw` operator, which applies
  to the single-byte code 32 and never to 2-byte Identity-H codes (nor to
  color-font runs), so those lines came out ragged in every
  `.identity` font. The extra word space is now emitted after each space
  glyph as a `TJ` adjustment (or `Tm` offset in the mark-positioning
  path), and `Tw` is 0 for these runs (poppler applies it to the 2-byte
  code 0x0020 anyway, e.g. a ligature subset to CID 32). New fpdf2
  reference `justify_embedded`.
- **`char_spacing` in runs with combining marks:** runs with GPOS mark
  positioning place every glyph with `Tm`, so `Tc` never applied and the
  text came out unspaced while `measureStyled` included the spacing. The
  spacing is now added per glyph in that path.
- **`char_spacing` leaked into later text:** a run with non-zero
  `char_spacing` set the PDF `Tc` operator but never reset it, and `Tc`
  survives `ET`, so every later text run on the page was letter-spaced
  too, while layout measured it without the spacing (overlapping spans,
  text overrunning its region). The run now resets `Tc` before `ET`.
- **Gradient stops are copied:** `addLinearGradient`/`addRadialGradient`
  kept a pointer to the caller's `stops` slice until `output()`; stops in
  a stack frame that had returned were read after free (garbage colors or
  a panic). The document now keeps its own copy.

### Internal

- GSUB differential test: `test/shaping/harfbuzz.txt` holds HarfBuzz's
  glyphs for Latin, diacritic, default-ignorable and emoji texts in Inter,
  Satoshi, Gentium, Bungee, Charter and Noto Emoji under several feature
  sets (HarfBuzz removing default ignorables, as platen does), plus a synthetic font
  with one scenario per lookup type and flag
  (`scripts/gen_gsub_test_font.py`); `scripts/gen_shaping_reference.py`
  regenerates it.
- `zig build test -Dtest-filter=NAME` runs only matching tests.
- The 19 references platen generates itself (color fonts, SVG,
  decorations, line breaking, transforms, diacritics) are now also
  compared rendered, pixel for pixel (`compare_pdfs.py --compare-render`,
  poppler): the text-and-position comparison missed drawing changes.
  Seven had drifted - three from bugs fixed here (`color_v1_gradient` had
  the page-filling space baked in), the rest from intended changes
  (`svg_embedding` predated per-path stroke widths: its tiger had 3x
  thick whisker outlines).

## 0.12.0 — 2026-10-17

### Added

- **Font collections (.ttc/.otc):** `doc.loadFontFromCollection(data,
  index, encoding)` loads one face of a collection (the Document keeps its
  own copy). `platen.extractFace` rebuilds face N as a standalone font
  (tables byte-identical, 4-byte aligned, checksums kept);
  `platen.listFaces` / `font_collection.describeFace` give each face's
  family, subfamily, PostScript name, weight, width and bold/italic.
  A plain .ttf/.otf counts as a one-face collection.
- **System font lookup:** `platen.findSystemFont(io, allocator, family,
  .{ .bold, .italic }, opts)` and `platen.findSystemFontFamily` search the
  platform font folders recursively and return caller-owned standalone
  sfnt bytes (extracted from collections) with family, subfamily,
  PostScript name, path and face index; `FoundFamily.memoryOptions()`
  feeds `loadFontFamilyFromMemory`. Matching uses the name table
  (typographic family, case-insensitive) and the subfamily; the per-user
  folders come from `opts.home`, so the library stays stateless.
- CLI: `font-faces`, `extract-face`, `find-font`.
- **Legacy `kern` table kerning:** fonts that kern only through a TrueType
  `kern` table (format 0; Microsoft and Apple layouts) are now kerned in
  rendering and in `measureStyled`; before, only GPOS kerning was read and
  such fonts (e.g. Bitstream Vera) came out unkerned.
  GPOS kerning still wins when present, as in HarfBuzz.

### Fixed

- `.win_ansi` TrueType fonts dropped composite glyphs: the WinAnsi
  subsetter copied a composite (e.g. Inter's i, j, colon = base + dot)
  without its components and kept the original component IDs, so those
  characters rendered blank. Components are now included and remapped, as
  the `.identity` path already did.
- PDF/A dates: `/Info` and XMP each read the clock, so a second boundary
  between them made `CreationDate` and `xmp:CreateDate` differ and
  veraPDF failed the file (6.7.3). `output()` now reads the clock once.
  Explicit `metadata.creation_date`/`mod_date` reached `/Info` only, so
  PDF/A with explicit dates was never compliant; they are now converted
  to ISO 8601 for XMP (same precision and time zone). Under PDF/A an
  explicit date that is not a valid PDF date fails with
  `error.InvalidDate`.
- File IDs came from the millisecond clock: the trailer `/ID` (PDF/A and
  encrypted output) and the XMP `DocumentID`/`InstanceID` (one shared,
  non-UUID string). Outputs in the same millisecond, e.g. concurrent
  documents, got identical IDs, and `doc.rng` did not make output
  reproducible as documented. All three now come from `doc.rng` (default:
  system CSPRNG); the XMP IDs are distinct version-4 UUIDs. With `doc.rng`
  set and explicit dates, PDF/A and encrypted output is byte-identical.

## 0.11.0 — 2026-10-06

### Added

- **Bold and italic per span:** `StyledText` spans take `.bold` and
  `.italic` (`st.append("word", .{ .bold = true })`), resolved through the
  base font's family like `TextStyle.bold`/`.italic`; widths use each
  span's variant, so wrapping and justification stay exact. A variant the
  family lacks is `error.FontVariantNotLoaded`, before anything is drawn.

### Fixed

- `writeBlock`, and `writeStyled` with plain spans, ignored the base
  style's `color` and `decoration` (text came out black, without
  underline). `TextStyleOptions` fields are now optional overrides: `null`
  inherits from the base style. Existing calls such as
  `.{ .color = platen.Color.blue }` compile unchanged.

### Internal

- The PDF comparator behind the reference tests compares fonts whenever
  either page has any (a page that lost all its fonts used to pass) and
  treats qpdf failures as errors; it has its own tests in the suite.
- `zig build test` re-runs when a reference PDF, fixture or comparator
  script changes (they are declared inputs); before, a regenerated or even
  corrupted reference could be served a cached pass.

## 0.10.1 — 2026-10-06

### Fixed

- **Package size:** dependents fetch ~0.4 MB instead of 45 MB and cache
  ~1.8 MB instead of ~100 MB. `build.zig.zon` `.paths` lists only the
  library (build files, `src/`, README, LICENSE, CHANGELOG), and
  `.gitattributes` keeps tests, fixtures, examples and dev scripts out of
  the forge's source archives. Clones are unchanged. The package hash
  differs from 0.10.0.

### Internal

- CI prints the test summary, so runs show test counts and skips.

## 0.10.0 — 2026-10-06

First tagged release; earlier history is in git. **Requires Zig 0.17.**

### Behavior changes — callers may need to adapt

Invalid input is now an error, never silently clamped or converted.

- **Numbers:** every `Document` drawing/text/layout call rejects NaN,
  infinities and magnitudes above `platen.max_value` (1,000,000) with
  `error.InvalidNumber`, before changing the document. (A huge
  `drawCircle` radius used to crash.)
- **Fonts:** `unitsPerEm` outside 16–16,384, or metrics that do not fit
  once scaled, are `error.InvalidFont` at load. Glyph IDs a font does not
  have are left out of subsets (they render as .notdef).
- **SVG:** numbers that are not finite or exceed ±1e9 are invalid (treated
  like any unparseable value); transforms that compose past that bound are
  `error.InvalidSvg`.
- **CFF fonts:** subroutine nesting over 10, expanded glyphs over 65,535
  bytes, or runaway expansion are `error.InvalidCFF` when subsetting.
- **PNG:** chunk CRCs are verified (`error.PngChecksumMismatch`); bit depths
  invalid for the color type, zero sizes, and sizes the data cannot hold
  are rejected before any allocation.
- **PDF/A:** standard (non-embedded) fonts, and SVGs containing `<text>`,
  are `error.FontNotEmbedded` at every level. Under PDF/A-1b, images with
  transparency are `error.TransparencyNotAllowed` and 16-bit images
  `error.BitDepthNotAllowed` (downsample, or use PDF/A-2b).
- **API types:** `opentype.MarkOffset` fields are `i32`;
  `CoverageTable.getGlyphCount` returns `usize` and `getGlyphAt` takes one.
- Link annotations carry `/F 4` (print), as PDF/A requires.
- The `zig build docs` step (broken since the generated docs were
  removed) is gone.

### Added

- PNG: Adam7 interlacing, 16-bit images with alpha (16-bit soft mask),
  and `tRNS` color-key transparency on grayscale and RGB images. All 161
  valid PngSuite images now decode to PngSuite's own expected pixels.

### Fixed

- Documents with more than 32 images, embedded fonts, SVGs or opacity
  states (or more than 16 gradients) produced broken PDFs: resource names
  collided.
- `output()` could fail with `WriteFailed` on large page dictionaries.
- Crashes on hostile input, found by fuzzing and an audit of ~50 sites:
  integer overflows and out-of-bounds reads in the TrueType, OpenType
  (GSUB/GPOS), COLR, sbix, CBLC and SVG-table parsers, the PNG/JPEG
  decoders and the TrueType/CFF subsetters.
- CFF offset sizes were off by one: a 255-byte (or 65,535-byte) item
  crashed subsetting — reachable with ordinary fonts.
- SVG: non-finite numbers were written into the PDF as `inf`; elements
  leaked on errors, in `<defs>` without an id, and on duplicate ids.
- PDF/A output failed veraPDF: invalid dates (a Zig 0.17 formatting
  change), link annotations without the print flag, and standard fonts.
- README examples that no longer compiled.

### Internal

- Zig 0.17 migration; the version is single-sourced from `build.zig.zon`.
- Tests: exact pixel comparison of images (none before), PngSuite against
  its own pixel truth, veraPDF validation of PDF/A output, and silent
  passing runs. 508 tests.
- Releases follow the urverk devkit main/dev model (`.devkit.conf`).
