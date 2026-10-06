# Changelog

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
