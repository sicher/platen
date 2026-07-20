# platen Context

## Current Focus
**Renamed zapdf → platen** (session #22). Library is feature complete (v1.0.0), Zig 0.16.
**COLR color fonts: v0, v1 (incl. sweep gradients) all supported** - see sessions below.

## What's Next
- **User actions pending for rename:** rename repo on Codeberg (sicher/zapdf →
  sicher/platen; old URL auto-redirects), optionally rename the local project
  directory (~/Documents/projects/zapdf → platen). In-repo URLs already point
  at sicher/platen. Absolute paths in .claude/settings.local.json still say
  /projects/zapdf on purpose — update them if/when the directory is renamed.
- Future enhancements (if needed):
  - Blend modes (Normal, Multiply, Screen, etc.) — partially used by COLR composite paints
  - Additional PDF/A levels (2a, 3a for tagged PDF)
  - OT-SVG: gzipped/multi-glyph docs, gradients/transparency in glyph docs

## What We Did (Session 2026-07-20 #22 — rename zapdf → platen)
- **Library renamed to platen** (letterpress plate; picked for no name
  collisions — zapdf clashed with Zig's zap framework and the zpdf extractor;
  vellum/quire taken). Tagline carries "fast": "platen — fast, stateless PDF
  generation for Zig".
- Mechanics: src/zapdf.zig → src/platen.zig; module/exe names, imports, docs,
  scripts, CLI strings all renamed; build.zig.zon .name = .platen with new
  fingerprint 0x84c0b5791b44e68e (fingerprint is derived from package name).
- version.zig name → "platen", so PDF /Producer is now "platen 1.0.0" —
  CLI outputs are deliberately NOT byte-identical to pre-rename ones.
- test/reference/pixel_font.pdf regenerated: its page content literally
  renders the library name ("zapdf!" → "platen!"); it's one of the
  self-generated references (fpdf2 can't emit EBDT pixel fonts).
- Verified: 400/400 tests, check-refs 46/46, CLI smoke PDF has
  /Producer (platen 1.0.0).

## What We Did (Session 2026-07-20 #21 — perf touches + fixture, backlog 4-5)
- **Backlog 4 done** (0dd0e5f): writeStreamCompressed skips zlib below 64
  bytes (CLI outputs stay byte-identical — tiny streams never compressed in
  practice); binary search in svg_table.docForGlyph + Cbdt.glyphBitmap
  subtable scan (spec-sorted); svg_table entry count clamped like the rest;
  perf_test.zig "Color emoji" section (COLR v1 layout; emission cost shows
  in PDF output timing).
- Verified: 400 tests, check-refs 46/46, 11 CLI PDFs byte-identical,
  `zig build perf -Doptimize=ReleaseFast` runs the new section (~3ms/10pg).
- **Backlog 5 done** (5297817): colr.zig InterpFixture dedupes the 6-way
  repeated interp-test setup (font load + COLR/CPAL/glyf parse + arena/
  resources/writer); interp() built after placement (self-referential
  pointers). −107 net lines. Remaining simgrep clone (glyf X/Y coordinate
  readers) is deliberate format-parallel code.

## What We Did (Session 2026-07-19/20 #20 — fuzz color-font parsers, 4 bugs fixed)
- **Backlog 3 done** (734bc9a): 4 new `--fuzz` targets in fuzz_tests.zig
  (COLR/CPAL + PaintInterp.render, CBDT/EBDT via one target, sbix, OT-SVG;
  corpus seeds = real tables extracted via ttf.Font.getTable, framed for
  Smith) + 4 deterministic mutation tests (seeded bit flips/stomps/
  truncations of fixture tables) that run on every `zig build test`.
- **Bugs the mutation tests found (all hostile-font DoS/crash class):**
  colr.zig u32 overflow in baseGlyphPaint binary search (counts now clamped
  to table size at parse; usize index math; + per-render ops_budget 65536 —
  depth limit alone allowed combinatorial ColrLayers/ColrGlyph blowup);
  bitmap_glyphs.zig unclamped CBLC subtable/format-4/5/sbix strike counts
  (multi-billion-iteration scans); xml.zig OOB slice after unterminated
  attribute quote; svg.zig infinite loop on non-letter after Z in path data
  (the 'Z' switch arm never advanced pos). Regression tests for xml/svg.
- Verified: 400 tests pass, CLI outputs byte-identical, check-refs 46/46,
  10-min coverage-guided `--fuzz` run clean (only known infra teardown
  panics "failed to open coverage file" after SIGINT — not our code).

## What We Did (Session 2026-07-19 #19 — refactors: color_fonts.zig, output() phases)
- **Backlog 1 done** (b88edb7): color-font subsystem → src/color_fonts.zig
  (ColorFontPlan + 13 fns as free fns taking *Document; reserveIds moved too;
  renderColorText lost unused self; getEmbeddedFontIndex now pub).
- **Backlog 2 done**: Document.output() 1090 → 35 lines. New `OutputIds`
  struct (all reserved IDs + deinit) + per-phase methods: reserveObjectIds,
  writeCatalog, writePagesRoot, writePdfaObjects, writeStandardFonts,
  subsetFontsAndRenderPages, writeEmbeddedFonts, writeImages, writeSvgs,
  writePages (returns next free id), writeInfoDict, writeOutlines,
  writePageLabels, finishDocument.
- **Byte-identical verified**: 11 CLI-generated PDFs before/after refactor,
  compared with timestamp fields normalized (scratchpad normpdf.py); all 390
  tests + check-refs 46/46 pass.
- Note: `zig build test` prints a spurious "failed command ... --listen=-"
  stderr line even on success (exit 0; pre-existing, custom runner fuzz probe).

## What We Did (Session 2026-07-19 #18 — codebase audit + fixes)
- **Audit pass** (refactoring / test gaps / latent bugs / perf) — one review
  agent + inline verification. Findings ranked and largely worked off:
- **Bug fixed: Type3 code 32 / word spacing** (commit 4b7b722): PDF Tw adds
  advance to every single-byte code 32 → the 32nd color glyph mis-spaced.
  Codes now skip 32 (254/subfont, Encoding restart "33 /g33", zero Widths
  placeholder). Renders pixel-identical; pixel_font/color_split refs
  refreshed. Also alpha_scale defer in renderMasked.
- **Bug fixed: SVG transparency check was dead** (215ad52): opacity states
  only populate during toPdfContent — check moved after rendering (was
  letting /GS refs leak into CharProcs).
- **Coverage added** (215ad52): byte-blob tests (TableBuilder) for CBDT
  index formats 3/4/5 + image formats 6/7/19; sbix 'dupe' (fixture glyph C);
  SvgTest fixture (scripts/gen_svg_font.py) for gzip/multi-glyph/transparency
  fallbacks (note: fontTools gunzips docList on load — pass gzip as raw
  bytes, verify magic in raw file); multi-page /Tc resources test.
- **Consolidation** (70f7aff): BE readers → binary.zig (colr re-exports;
  ttf/opentype keep unchecked ones deliberately); writeF64_2/3 → comptime
  writeF64N; zlib.compress → delegate; walkFrom/walkAllOff → SegEmitter
  (trailing close-quad was dead code; new all-off-curve test).
- Audit notes: kerning/cmap already cached (O(1)); simgrep clone clusters in
  cli/tests deemed acceptable; pdfa.zig XMP repetition intentional.
- **All 390 tests pass** (381 at session start).

## What We Did (Session 2026-07-18 #17 — real CBDT, indexed PNG, pixel fonts)
- **Vendored a real bitmap font**: `NotoColorEmoji-CBDT-subset.ttf` (27KB) —
  Google's Noto CBDT build cut to 12 emoji with `fontTools.subset`
  (`--unicodes=U+2601,U+2764,U+2B50,U+1F308,U+1F355,U+1F389,U+1F39B,U+1F422,
  U+1F44D,U+1F600,U+1F680,U+1F984 --name-IDs='*'`). Added to `color_bitmap`
  integration test; all 12 render + extract. (Researched: no small real color
  bitmap fonts exist — they're all multi-MB emoji sets; subsetting is what
  harfbuzz/fontTools test suites do too.)
- **Indexed PNG support in images.zig** (Noto CBDT strikes are palette PNGs):
  PLTE + tRNS → 8-bit RGB + SMask alpha, index depths 1/2/4/8
  (`expandIndexedPng`); unit test with a hand-built 2-bit palette PNG.
- **Glyf-less fonts load now**: `EmbeddedFont.synthetic_loca` (all-zero) +
  empty glyf in `SubsetTables` when the font has only bitmap tables.
- **Pixel font (OTB / EBDT+EBLC 1-bit) support** — user-requested:
  - `bitmap_glyphs.zig`: `BitmapGlyph.pixels` is now a union (png | mono);
    `Cbdt` (same parser handles EBLC — identical layout) gained `bit_depth`;
    mono image formats 1/2 (small metrics, byte/bit-aligned), 5 (index
    metrics, bit-aligned), 6/7 (big metrics); composite formats 8/9 skipped.
    `packMonoRows` repacks bit-aligned rows to byte-aligned for PDF.
  - `embedded.zig`: EBDT probed only when glyf is missing **or zero-length**
    (Cozette OTB has a 0-byte glyf; outline+strike CJK fonts keep outlines).
  - `document.zig`: `PlanImage` union (color `*Image` | mask rows); pixel
    glyphs emit `d1` CharProcs + 1-bit ImageMask (`/Decode [1 0]`, EBDT bit
    1 = ink) → **painted in the current text color** (d1 contract holds:
    ImageMask makes no color marks).
  - Vendored **Cozette OTB** (MIT, 182KB, 13ppem strike, upem 2048,
    zero-length glyf, hmtx-driven advances). Ground truth for 'A' (gid 66,
    7x13, bearing (0,10), bit-aligned format 2/5) from fontTools.
  - Tests: parser + packMonoRows unit tests, document test (exact d1 metrics
    `1024 0 0.00 -472.62 1102.77 1575.38 d1`), `pixel_font` reference
    integration test. Validated visually (crisp pixels, colorization works).
- **All 378 tests pass** (was 374).
- **OT-SVG color font support**:
  - `src/svg_table.zig`: 'SVG ' table parser (doc list → per-glyph document;
    gzipped or multi-glyph-range docs → null → mono-outline fallback).
  - `embedded.zig`: lazy `svgInfo()`/`isSvgGlyph`; source priority per font is
    **COLR > SVG > bitmap**.
  - `document.zig`: `renderSvgGlyphCharProc` — doc → `svg.Svg.fromMemory` →
    `toPdfContent` → `d0` CharProc. Key insight: OT-SVG docs declare no
    size/viewBox, so svg.zig's flip is exactly `1 0 0 -1 0 0` (y-down glyph
    space → y-up). Docs with transparency/text → `error.NotAColorGlyph`,
    which `ensureColorGlyph` now catches to leave the glyph un-coded (mono
    outline fallback) instead of aborting output.
  - Tests: svg_table unit test, document test (flip matrix + both Bungee
    fills), `color_svg` reference integration test mirroring `color_v0` —
    the SVG and COLRv0 builds render **98.7% pixel-identical** (rest = title
    text). **All 381 tests pass.**
- Bump library version to reflect 0.16 API breakage (Document.init/fromFile signatures).
- Update README to mention Zig 0.16 requirement.
- Remove the temporary `zig-pkg/` directory if it shouldn't be tracked (was created during the dependency hash refresh).
- `zig-out/bin/zpdf` is a stale binary from an old build (build.zig only produces `platen` now) — safe to delete.

## What We Did (Session 2026-07-12 #16 — COLR: gradient tests, sweep, subfont split, composite fixes)
- **BungeeSpice COLR v1 gradient tests** (vendored font, non-emoji):
  - `colr.zig` unit test: renders 'A' (gid 2) → 2 axial shadings, ground truth
    from fontTools (3-point (0,0)/(0,900)/(100,0) → axial `/Coords [0 0 0 900]`,
    gold↔dark-red stops), clips, no solid fills.
  - `color_v1_gradient` reference integration test (`generateColorV1GradientPdf`,
    platen-generated reference, excluded in `gen_references.py`). Verified visually.
- **PaintSweepGradient support** (`renderSweep` in `colr.zig`) — PDF has no conic
  shading, so: 120-wedge flat-colored triangle fan in the glyph clip.
  - **Spec essentials** (verified against the OT COLR spec): angles are biased
    F2Dot14 (`degrees = (value+1)×180`), CCW from +x axis; the sampling domain
    is the **absolute [0°,360°)** (NOT relative to startAngle — first version had
    this bug); `t = (θ−start)/(end−start)` (signed span handles start>end
    inversion), then extend pad/repeat/reflect (`sweepExtendT`), then piecewise
    lerp of the color line (`sampleColorLine`). Stop alpha ignored (same as
    linear/radial path).
  - AA seam fixes: wedges overlap the previous by 0.3°; apex pushed 4 font units
    past the center (kills the white pinhole where 120 apexes converge).
    Validated at 600 dpi with pymupdf.
- **SweepTest fixture font** (`test/fonts/sweep/SweepTest.ttf`, rebuild with
  `scripts/gen_sweep_font.py` via .venv fontTools): squares with red→blue sweeps —
  'A' 0..360°, 'B' 0..90° pad, 'C' 110..230° pad (the spec's example; locks in the
  absolute sampling domain: 37 pure-red + 43 pure-blue wedges of 120).
- Tests: sweep unit tests (fixture render + helper edge cases) + `color_sweep`
  reference integration test.
- Note: 3°-wedge midpoints are at 1.5°+3k — assertions on sampled colors must use
  those exact t values (e.g. t=43.5/90 → "0.517 0.000 0.483 rg").
- **>255 color glyphs → multiple Type3 subfonts** (was: fall back to mono).
  `ColorFontPlan` stores unbounded 1-based ordinals; `slotFor(gid)` → subfont
  `(ord-1)/255` + code `(ord-1)%255+1`. Names: `/Tc{n}`, `/Tc{n}s1`, …; per-
  subfont font dict + ToUnicode (CharProcs one contiguous block, shared
  Resources). `renderColorText` segments runs by subfont. Tests: document_test
  (300 Noto emoji → /Tc1 + /Tc1s1) + `color_split` reference integration test.
- **Two composite bugs found & fixed while validating `color_split`** (visible
  as a giant black rectangle over the page):
  - `blendModeName` was shifted by 4: per the OT spec (verified against
    fontTools `CompositeMode`), Porter-Duff is 0..12 and blends are
    SCREEN=13 … MULTIPLY=23 (after EXCLUSION!), HSL 24..27.
  - Porter-Duff modes were all approximated as source-over, so Noto's
    SRC_IN(source=artwork, backdrop=unclipped black solid α=0.7) — used by
    316 paints (🎛🎟🎫 etc.) — painted the backdrop as a huge black rect.
    Now: CLEAR/SRC/DEST/DEST_OVER exact by paint order; IN/OUT with a solid
    mask branch → `renderMasked` (content at mask alpha via `/ca` ExtGState +
    `alpha_scale` threaded into solid fills); plus a `clip_depth == 0` guard
    that skips any unbounded solid/gradient/sweep fill (ClipBox unimplemented).
  - `color_emoji` reference unaffected (byte-identical modulo timestamps).
- **Bitmap emoji (CBDT/CBLC + sbix) support**:
  - `src/bitmap_glyphs.zig`: parses sbix (largest strike, 'png '/'dupe'
    records, originOffset) and CBDT/CBLC (index formats 1–5, image formats
    17/18/19) → `BitmapGlyph{png, bearing_x, bottom_y, w, h}` (slices into
    font data). `BitmapInfo` union fronts both.
  - `embedded.zig`: lazy `bitmapInfo()` (null when COLR present — vector wins),
    `isBitmapGlyph`.
  - `document.zig`: `renderBitmapGlyphCharProc` — PNG → `Image.fromMemory`
    (borrowed slice) → plan.images; CharProc = `wx 0 d0 q W 0 0 H x y cm
    /Im{k} Do Q` in font units (scale upem/ppem); image XObjects (+SMask for
    alpha) written per plan (`writePlanImage`), `/XObject` in Type3 Resources.
  - Fixtures: `test/fonts/bitmap/{SbixTest,CbdtTest}.ttf` from
    `scripts/gen_bitmap_fonts.py` (PIL PNGs: quadrant square for orientation,
    alpha half for SMask; CBDT built via TTX import). Unit tests
    (bitmap_glyphs.zig registered in platen.zig test block), document tests
    (exact `cm` placement values), `color_bitmap` reference integration test.
    Validated visually (orientation, alpha, offsets all correct).
- **All 374 tests pass** (was 359 at session start).

## What We Did (Session 2026-07-08/09 #14 — COLR color emoji)
- **Wired COLR v1 / CPAL color fonts into PDF output as Type3 color fonts.**
  Builds on `src/colr.zig` (committed earlier: CPAL/COLR/glyf parsers + `PaintInterp`
  that renders a glyph's paint graph to PDF operators — solids, axial/radial
  shadings, clips, transforms, blend-mode ExtGStates).
- **`src/embedded.zig`**: lazy `colorInfo()` (probes COLR/CPAL/glyf/loca/head),
  `isColorGlyph(gid)`, `glyphAdvanceFontUnits(gid)`. `ColorInfo` slices point into
  the font `data` (nothing to free).
- **`src/document.zig`**:
  - `ColorFontPlan` (output-scoped, one heap-allocated plan per color font):
    ordered color gids → 1-based PDF codes, CharProc content, advance widths (font
    units), page-usage set, a shared `colr.ColorResources` (shadings/ExtGStates).
  - `buildColorFontPlans()` pre-pass runs at the top of `output()` before object-ID
    reservation; scans every page's text commands (uses `t.cached_glyphs`).
    **Skipped entirely when `conformance != .none`** (color glyphs fall back to the
    mono CID outline under PDF/A).
  - Reserves 1 font-dict + N CharProc-stream object IDs per plan.
  - `writeColorFont()` emits the Type3 font: FontMatrix `[1/upem …]` (full precision
    via allocPrint — **NOT `Value.real`, which only prints 3 decimals**), FontBBox
    from head, CharProcs/Encoding(Differences)/Widths(font units)/Resources built as
    literal strings in an arena. CharProc = `wx 0 d0` + paint ops.
  - `renderColorText()` (content emission) segments a color-font run into maximal
    same-kind sub-runs: color → `/Tc{n}` Type3 + 1-byte codes, mono → `/E{n}` CID +
    2-byte gids. Both share the text position; advances agree (Type3 Widths×FontMatrix
    == CID `/W`). No kerning/marks in mixed runs (emoji don't kern).
  - Per-page `/Font` resources gain `/Tc{n}` for plans whose `pages` set contains the page.
- **ToUnicode on the Type3 font**: single-byte CMap mapping each color code →
  its Unicode codepoint (astral → UTF-16 surrogate pair), via
  `buildColorFontToUnicode` + a reserved `tounicode_id` per plan. Makes emoji
  text-extractable/copy-pasteable (`pdftotext` now yields the real emoji, not raw
  byte codes) and lets the semantic reference comparison see real content.
- **Tests**:
  - `src/document_test.zig` (unit): Type3 structure + FontMatrix precision +
    gradient shading; mixed color/mono segmentation; PDF/A skip; empty-plan guard.
    Set `doc.compression_level = 0` when asserting on content-stream operators
    (streams compress once they exceed a small size).
  - `src/integration_tests.zig` (reference): `color_emoji` case +
    `generateColorEmojiPdf` + `test "integration: color_emoji PDF"`. **Reference is
    platen-generated** (`test/reference/color_emoji.pdf`) — fpdf2 can't emit COLR, so
    it's added to `EXCLUDED_TESTS` in `gen_references.py` (like svg_equation/
    inter_fonts). To regenerate: run tests → copy `test/output/color_emoji_actual.pdf`
    → `test/reference/color_emoji.pdf`.

## What We Did (Session 2026-07-12 #15 — COLR v0 support)
- **Added COLR v0 support** (flat layered solid colors) alongside v1. User vendored
  **Bungee Color** (`test/fonts/Bungee Color/`, SIL OFL 1.1) — a Latin display font
  with COLR/CPAL v0, plus a v0-SVG variant and a `BungeeSpice-Regular-COLRv1.ttf`.
- **`src/colr.zig`**:
  - `Colr` now carries `version` + v0 fields (`base_glyph_records`,
    `num_base_glyph_records`, `layer_records`, `num_layer_records`); `parse` reads the
    v0 header for all versions and the v1 list only when `version >= 1`.
  - `v0BaseGlyph(gid)` (binary search of 6-byte records → `{first,num}`),
    `v0Layer(index)` (4-byte record → `{gid,palette}`), `isColorGlyph(gid)` (v0 OR v1).
  - `PaintInterp.render` dispatches: v1 paint graph first, else `renderV0` (fills each
    layer outline with a solid palette color). Refactored `beginSolid`/`endSolid` to
    share `beginSolidColor(palette,alpha)`/`endSolidColor` (used by both v1 PaintSolid
    and v0 layers) — no duplication.
  - `embedded.zig` `isColorGlyph` delegates to `colr.isColorGlyph`.
  - **No document.zig changes needed** — the Type3 emission path is version-agnostic
    (it just calls `interp.render(gid)`).
- **Tests**: 2 `colr.zig` unit tests (v0 parse + render, ground-truth from fontTools:
  glyph 'A' = gid 2 → layers (2, palette 0 dark red) + (1062 'A.inline', palette 1
  salmon)); 1 `document_test.zig` Type3-emission test; 1 `color_v0` reference
  integration test (`generateColorV0Pdf`, Bungee, platen-generated reference).
  Validated visually (dark-red BUNGEE with salmon inline). All 359 tests pass.
- Note: FontMatrix for upem 1000 prints as `0.0010000000` (`{d:.10}`), not `0.001`.
- **CLI**: new `color-test [ttf] [out]` command + `generateColorTestPdf`.
- **Validated visually**: rendered with pymupdf — cloud, grinning face (radial
  gradient), party popper, rocket, heart, star, rainbow, etc. all correct in color.
- All 353 unit tests pass. (Note: `zig build test`'s trailing "failed command" is a
  **pre-existing** fuzz-phase issue in the vendored runner — reproduces on clean tree;
  run the test binary directly to see "All 353 tests passed".)

## What We Did (Session 2026-05-01 #13)
- **Migrated from Zig 0.15 to 0.16**. All 336 unit tests + 38 integration reference tests pass.
- **API breaking changes for users**:
  - `Document.init(allocator)` → `Document.init(allocator, io)` (`io: std.Io`).
  - `ttf.Font.fromFile(allocator, path)` → `(io, allocator, path)`.
  - `images.Image.fromFile(allocator, path)` → `(io, allocator, path)`.
  - `svg.Svg.fromFile(allocator, path)` → `(io, allocator, path)`.
  - `embedded.EmbeddedFont.fromFile(allocator, path)` → `(io, allocator, path)`.
  - `testing.compareWithReference*` and `comparePdfs*` now take `io: std.Io` first.
- **Internal upstream-API migrations**:
  - `std.heap.GeneralPurposeAllocator(.{}){}` → `std.heap.DebugAllocator(.{}) = .init`.
  - `std.ArrayListUnmanaged(T){}` / `= .{}` → `.empty` (and same for HashMap variants).
  - `std.io.fixedBufferStream(buf)` → `std.Io.Writer.fixed(buf)`; `.writer()` removed (pass `&w`); `.getWritten()` → `.buffered()`; `.pos` → `.end`.
  - Custom `format(writer: anytype) @TypeOf(writer).Error!void` → `format(writer: *std.Io.Writer) std.Io.Writer.Error!void` in `objects.zig`.
  - `std.fs.cwd()` / `std.fs.File` removed → `std.Io.Dir.cwd()` / `std.Io.File` (everything takes `io`).
  - `std.process.argsAlloc` → `init.minimal.args.toSlice(arena)` (main signature now `pub fn main(init: std.process.Init) !void`).
  - `std.process.Child.run` API changed → `std.process.run(allocator, io, .{ .argv = ... })`.
  - `std.time.milliTimestamp()` / `std.time.timestamp()` removed — replaced with `pdf_output.milliTimestamp()` helper using `std.c.clock_gettime(.REALTIME, ...)`.
  - `std.meta.intToEnum` → `std.enums.fromInt`.
  - `std.mem.trimLeft` → `std.mem.trimStart`.
- **`app_io` pattern**: `cli.zig`, `perf_test.zig`, and `integration_tests.zig` declare a `pub var app_io: std.Io` (defaulting to `std.testing.io` in test builds for `integration_tests.zig`). `cli.zig` sets `platen.integration_tests.app_io = init.io` so the CLI's `check-refs` command shares the same generators as the test suite.
- **stdout in CLI**: now buffered through `std.Io.File.stdout().writer(io, &buf)`; flushed in a `defer`.
- **zlib dep**: bumped manifest hash from 1.3.1 to 1.3.2 to match what the registry now serves.

## What We Did (Session 2026-02-10 #12)
- **Renamed project from zpdf to platen**:
  - Renamed `src/zpdf.zig` → `src/platen.zig`
  - Updated package name, module imports, executable names (`platen`, `platen-perf`)
  - Updated all documentation, tests, CLI help text, build config (21 files, 906 replacements)
  - Updated `build.zig.zon` fingerprint (required after name change)
  - Updated remote URL to `codeberg.org/sicher/platen.git`
- **Updated README description** for search discoverability
- Commits: 52027e7, 19938ee

## What We Did (Session 2026-02-10 #11)
- **Added optical top alignment** (VAlign):
  - `.top` now uses cap-height from font metrics (optical alignment)
  - `.top_ascent` aligns to ascender line
  - `.top_leading` preserves legacy half-leading behavior
  - Extracted `valignBaseline()` helper in document.zig
  - All existing tests pinned to `.top_leading` to match fpdf2 references
- **Added integration test** `optical_align` with reference PDF
  - 5x3 grid: 5 fonts x 3 alignment modes
  - Size comparison section (10pt-40pt)
- **Added CLI command** `optical-test` for visual inspection
- **Investigated fpdf2 positioning**: uses `0.5h + 0.3*fontSize` heuristic (no font metrics)
- **Updated README** with optical alignment docs
- Commits: 75b047e

## What We Did (Session 2026-01-26 #10)
- **Simplified StyledText API**:
  - Removed `appendOwned()` - wasn't used internally, added unnecessary complexity
  - Removed `owned_text` field from StyledText struct
  - Users use `append()` which stores references (typically string literals)
  - Updated README to reflect simplified API
- Commits: 3194f3e

## What We Did (Session 2026-01-26 #9)
- **Added OpenType character variants cv01-cv99**
- **Fixed FeatureFlags comptime limit** with custom bitset
- **Updated inter_fonts integration test** with cv01-cv13 showcase
- **Updated README** with complete OpenType features list
- Commits: 8dc0cc3

## What We Did (Session 2026-01-26 #8)
- **Released v1.0.0** - Feature complete milestone
  - Added `src/version.zig` with version constants
  - PDF producer now shows "platen 1.0.0"
  - Git tag: `v1.0.0`

- **Consolidated duplicate code** (41 lines saved):
  - `format.zig`: Extracted `writeUnsignedInt` helper (42 lines saved)
    - Eliminates 25-line duplication across writeF64_2, writeF64_3, writeInt
  - `pdf_output.zig`: Extracted `DateTime` struct for timestamp extraction
    - Consolidates duplicate code in formatPdfDate/formatIsoDate
  - Committed: 60e54c9

## What We Did (Session 2026-01-26 #7)
- **Removed dead code** (~223 lines across 4 files):
  - `page.zig`: writeLineTo, writeMoveTo, writeRect (~20 lines)
  - `format.zig`: writeHexBracket4 (~6 lines)
  - `metrics.zig`: charWidth (~4 lines)
  - Committed: bf72bd5

- **Consolidated Courier font width tables** (76 lines saved):
  - Courier is monospace: all widths are 600
  - Replaced 4 identical 18-line tables with comptime: `const courier_widths = [1]u16{600} ** 256;`
  - Grouped switch arm for all Courier variants
  - metrics.zig: 492 → 416 lines
  - Committed: b5b1133

- **Created binary.zig helpers** (68 call sites converted):
  - New `src/binary.zig` with appendBE16, appendBE32, appendBEi16, appendBEi32
  - Reduces verbose pattern: `try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, val)));`
  - To concise: `try binary.appendBE16(&list, allocator, val);`
  - 40% line width reduction at call sites
  - Files converted: ttf_subset.zig (34), embedded.zig (28), cff_subset.zig (5)
  - Zero performance impact (functions inline completely)
  - Committed: 82a6459

- **Files added/modified**:
  - `src/binary.zig` - **NEW**: Big-endian serialization helpers (50 lines)
  - `src/ttf_subset.zig` - Added binary import, converted 34 sites
  - `src/embedded.zig` - Added binary import, converted 28 sites
  - `src/cff_subset.zig` - Added binary import, converted 5 sites
  - `src/metrics.zig` - Courier table consolidation
  - `src/page.zig` - Dead code removal
  - `src/format.zig` - Dead code removal

## What We Did (Session 2026-01-26 #6)
- **Refactored FeatureFlags to use EnumArray**:
  - Replaced 14 bool fields with `EnumArray(Feature, bool)`
  - Added `FeatureFlags.init()`, `isEnabled()`, `set()` methods
  - Replaced `fromTag()` 14-line switch with `std.meta.intToEnum`
  - Added `Feature.defaultEnabled()` to centralize defaults
  - Simplified `setFeature()` from 14-line switch to 1 line
  - Renamed `.case` to `.case_` to avoid Zig keyword conflict

- **Removed dead code** (~57 lines):
  - `applyDlig()` - only `applyDligInto()` was used
  - `applyClig()` - never called
  - `applyHlig()` - never called
  - `applySingleSubstFeature()` - never called

- **Consolidated single-subst switch arms** (~70 lines saved):
  - Combined `.tnum, .pnum, .zero, .case_, .ss01` cases into grouped arms
  - Applied pattern in 3 locations: `applyLookupRefAt`, `applyCalt`, `applyChainContext`

- **Total reduction**: opentype.zig 3271 → 3144 lines (-127 lines, -3.9%)

- **Performance**: No impact (verified with perf tests)

- **Files modified**:
  - `src/opentype.zig`: Main refactoring
  - `src/embedded.zig`: Updated FeatureFlags usage
  - `src/text_render.zig`: Updated flag access
  - `src/perf_test.zig`: Updated flag setting
  - `src/integration_tests.zig`: Updated `.case` → `.case_`

## What We Did (Session 2026-01-26 #5)
- **Fixed VeraPDF PDF/A validation issues**:
  1. **OS/2 table missing** - Added OS/2 table to TTF subset output
  2. **Post table version 2.0 truncated** - Changed to version 3.0 (no glyph names)
  3. **XMP dates missing** - Added xmp:CreateDate and xmp:ModifyDate in ISO 8601 format

- **Files modified**:
  - `src/ttf_subset.zig`: Added OS/2 to TTFTables, post v3.0
  - `src/embedded.zig`: Pass OS/2 table to assembleTTF()
  - `src/pdf_output.zig`: Added formatIsoDate() for XMP
  - `src/document.zig`: Pass dates to XMP metadata
  - `src/pdfa.zig`: Removed pdfa_3b conformance
  - `src/integration_tests.zig`: Added pdfa_2b test
  - `README.md`: Added PDF/A documentation

- **Validation results** (VeraPDF + online validator):
  - PDF/A-1b: 129/129 rules, 995/995 checks
  - PDF/A-2b: 144/144 rules, 766/766 checks

- **Root cause**: Post table v2.0 expects glyph names beyond 32-byte header;
  v3.0 means "no glyph names" and requires only 32 bytes

## What We Did (Session 2026-01-26 #4)
- **Added PDF/A conformance support** (`src/pdfa.zig`, `src/document.zig`):
  - New `Conformance` enum: `.none`, `.pdfa_1b`, `.pdfa_2b`
  - Early validation: transparency (opacity < 1.0) rejected for PDF/A-1b
  - XMP metadata generation with PDF/A identification
  - OutputIntent with embedded sRGB ICC profile
  - Document ID in trailer (required for PDF/A)
  - MarkInfo dictionary in catalog

- **API usage**:
  ```zig
  var doc = Document.init(allocator);
  doc.setConformance(.pdfa_1b);  // Enable PDF/A-1b mode

  // Transparency rejected for PDF/A-1b
  try doc.drawRect(rect, .{ .fill = .{ .opacity = 0.5 }});
  // Returns error.TransparencyNotAllowed

  // PDF/A-2b allows transparency
  doc.setConformance(.pdfa_2b);
  try doc.drawRect(rect, .{ .fill = .{ .opacity = 0.5 }});  // OK
  ```

- **Files added/modified**:
  - `src/pdfa.zig` - **NEW**: Conformance enum, validation, XMP generation
  - `src/data/sRGB2014.icc` - **NEW**: Embedded ICC profile (~3KB)
  - `src/data/sRGB2014.icc.LICENSE` - **NEW**: License for ICC profile
  - `src/document.zig` - conformance field, validation in writeOpacityRef(), PDF/A output
  - `src/writer.zig` - Added optional `id` field to trailer
  - `src/platen.zig` - Re-export Conformance, ConformanceError
  - `src/document_test.zig` - PDF/A tests
  - `src/cli.zig` - `pdfa-test` command

- **CLI command**: `platen pdfa-test [out]` - generates PDF/A-1b test document

- **Verification with VeraPDF**: All rules pass (fixed in Session #5)

- **Integration test** (`src/integration_tests.zig`, `scripts/gen_references.py`):
  - `gen_pdfa()` in Python - generates fpdf2 reference PDF with PDF/A output intent
  - `generatePdfaPdf()` in Zig - generates platen PDF with full PDF/A-1b conformance
  - platen output includes additional structures (XMP, MarkInfo) beyond fpdf2

## What We Did (Session 2026-01-26 #3)
- **Added opacity support to graphics API** (`src/layout.zig`, `src/graphics.zig`, `src/document.zig`):
  - Added `opacity` field to `StrokeStyle` and `FillStyle` (0.0-1.0, default 1.0)
  - Added `OpacityState` type to `layout.zig` (shared between page and SVG)
  - Added `getShapeOpacity()` and `writeExtGStateRef()` helpers to `graphics.zig`
  - Updated `Page` struct with `opacity_states` tracking and deduplication
  - Updated all draw methods: `drawLine`, `drawRect`, `drawRoundedRect`, `drawEllipse`, `drawCircle`, `drawPolygon`, `drawPath`
  - Added ExtGState resource building in page output

- **API usage**:
  ```zig
  // Fill with 50% opacity
  try doc.drawRect(rect, .{ .fill = .{ .color = Color.red, .opacity = 0.5 }});

  // Stroke with 70% opacity
  try doc.drawLine(p1, p2, .{ .color = Color.blue, .opacity = 0.7 });

  // Both fill and stroke opacity
  try doc.drawRoundedRect(rect, 10, .{
      .fill = .{ .opacity = 0.6 },
      .stroke = .{ .opacity = 0.8, .width = 2 },
  });
  ```

- **Added tests** (`src/document_test.zig`):
  - `test "drawRect with fill opacity"` - verifies ExtGState/ca
  - `test "drawRect with stroke opacity"` - verifies ExtGState/CA
  - `test "drawRect with both fill and stroke opacity"`
  - `test "drawRect fully opaque has no ExtGState"` - no overhead for opaque
  - `test "drawLine with opacity"`
  - `test "drawEllipse with opacity"`
  - `test "opacity state deduplication"` - same opacity reuses GS

- **Added CLI command** (`src/cli.zig`):
  - `platen opacity-test [out]` - generates visual test PDF

- **Added integration test** (`src/integration_tests.zig`, `scripts/gen_references.py`):
  - `gen_opacity()` in Python - generates fpdf2 reference PDF with opacity
  - `generateOpacityPdf()` in Zig - generates platen PDF matching the reference
  - Tests overlapping transparent shapes, different opacity levels, stroke opacity

- **Fixed off-by-one bug in ExtGState references** (`src/graphics.zig`):
  - Bug: `writeExtGStateRef()` wrote `/GS0 gs` but resources defined `GS1, GS2, ...`
  - Resource names are 1-indexed (index 0 → "GS1"), content stream was 0-indexed
  - Fix: Added `+ 1` to index in `writeExtGStateRef()`
  - Caught by comparing fpdf2 reference vs platen output in integration test

## What We Did (Session 2026-01-26 #2)
- **Fixed gentium_family PDF size issue** (`src/ttf_subset.zig`, `src/embedded.zig`):
  - Added `buildMinimalNameTable()` - extracts only essential name IDs (1,2,4,6)
  - Reduces font name tables from ~17KB to ~150 bytes each
  - Result: gentium_family.pdf now 35KB smaller than fpdf2 (was 15KB larger)

- **Optimized PDF output compression** (`src/writer.zig`, `src/document.zig`):
  - Added `compression_level` field to Document (default 1 for speed)
  - Users can set `doc.compression_level = 6` for smaller files
  - Page writing: 45ms → 11ms (4x faster)

- **Fast formatting in PDF dictionaries**:
  - `src/gradient.zig` - All shading/gradient dicts use fast formatting
  - `src/objects.zig` - Value.real(), Value.int(), Ref.format() use fast formatting
  - `src/document.zig` - Inline shading dicts use fast formatting

- **Performance results** (release mode, 100 pages):
  - PDF output: 61ms → 26ms (57% faster)
  - Total: 101ms → 62ms (39% faster, ~1600 pages/sec)
  - Trade-off: PDF size 437KB → 517KB with level 1 compression

- **Analyzed resource lookups** - O(n) linear search for fonts/images is fine
  for typical documents (<20 fonts, <100 images). Not worth HashMap overhead.

## What We Did (Session 2026-01-26 #1)
- **Created fast float formatting module** (`src/format.zig`):
  - `writeF64_2()`, `writeF64_3()` - 11-14x faster than std.fmt.bufPrint
  - `writeCoord2()`, `writeCoord2Suffix()`, `writeCubic()` - coordinate helpers
  - `writeHex4()`, `writeCMapEntry()` - fast hex formatting for fonts

- **Added drawing-intensive benchmark to perf_test.zig**:
  - Tests rectangles, lines, ellipses, circles, rounded rects, polygons
  - 20 pages × ~1500 shapes = 30,000 shapes per run

## What We Did (Session 2026-01-25 #6)
- **Added memory loading functions**:
  - `loadFontFromMemory(data, encoding)` - load font from buffer
  - `loadFontFamilyFromMemory(opts)` - load font family from buffers
  - `loadImageFromMemory(data)` - load JPEG/PNG from buffer
  - `loadSvgFromMemory(data)` - load SVG from buffer
  - Added tests for all memory loading functions

- **Changed drawImage/drawSvg to take Rect**:
  - More consistent with other shape drawing functions
  - `drawImage(*Image, Rect)` instead of `drawImage(*Image, x, y, w, h)`
  - `drawSvg(*Svg, Rect)` instead of `drawSvg(*Svg, x, y, w, h)`
  - Rect.width and Rect.height now default to 0 for auto-scaling
  - Updated all call sites and README

## What We Did (Session 2026-01-25 #5)
- **Optimized write() with line-batching** - 2x speedup for rendering:
  - Buffer words per line, render as single string (1 allocation per line vs N)
  - Fixed double `findHyphenBreakStyled` call
  - Fixed duplicate `getTextWidthStyled(prefix)` measurement
  - Root cause: `stripSoftHyphens` was allocating per word
  - write() is now faster than writeStyled() for typical paragraphs
  - measure_only path unchanged (still 4.8x faster than writeStyled)

## What We Did (Session 2026-01-25 #4)
- **Renamed pageNo() to getPageIndex()** - returns 0-based index for consistency

- **Cleaned up API_REVIEW.md** - removed outdated references, updated for current API

- **Removed dead code** - non-styled break helpers that called non-existent getTextWidth()

- **Made internal APIs private**:
  - `getTextWidthStyled()` - use `write/writeStyled(.measure_only=true)` instead
  - `findHyphenBreakStyled()`, `findSoftHyphenBreakStyled()` - internal line-breaking
  - Moved related tests to document.zig as inline tests

- **Refactored text_flow integration test**:
  - Uses `writeStyled()` with alignment instead of manual width calculation
  - Updated Python reference generator to use `cell()` with alignment

- **Performance benchmark (bench_write.zig)**:
  - Created benchmark to compare write() vs writeStyled()
  - Identified per-word allocation as bottleneck (fixed in session #5)

- **Added writeLine() for block-based text with alignment**:
  - Clear separation: `write()` = incremental (cursor_x advances), `writeLine()` = block-based (cursor to next line)
  - `writeLine()` supports alignment (left, center, right, justify)
  - Added `LineOptions` struct with alignment, valign, line_height, break_on_hyphens
  - Use case: table cells, headers, any text that needs alignment

- **Refactored Outline to builder pattern (like Path)**:
  - New `Outline` builder struct with `add()` and `addChild()` methods
  - Renamed old `Outline` to `OutlineItem` (individual entry)
  - New API: `doc.createOutline()` → build → `doc.setOutline(&outline)`
  - Cleaner than old `addOutlineItem(title, dest, parent)` pattern

- **Added integration test for insertPage()**:
  - Tests building pages in reverse order with `insertPage(0)`
  - Verifies output matches normal `addPage()` order

## What We Did (Session 2026-01-25 #3)
- **Added per-page size/margins and page navigation API**:
  - New `PageOptions` struct with `size` and `margins` fields
  - `addPage(PageOptions)` - add page with explicit size/margins
  - `insertPage(index, PageOptions)` - insert page at position (for TOC)
  - `selectPage(index)` - switch current page for content operations
  - `pageCount()` - get total number of pages
  - `getPageRegion()` now returns `?Region` using current page's margins
  - Added `current_page` tracking to Document struct

- **Removed stateful page setters**:
  - `setPageSize()` - pass size in PageOptions instead
  - `setMargins()` - pass margins in PageOptions instead
  - `doc.page_size` field - now per-page in Page struct
  - `doc.margins` field - now per-page in Page struct

- **Design rationale**: Enables workflows like:
  - TOC insertion at beginning after content is laid out
  - "Page X of Y" footers where total is unknown until end
  - Different margins per page (title page vs content)

## What We Did (Session 2026-01-25 #2)
- **COMPLETED stateful text API removal**:
  - Removed all stateful fields from Document struct (`current_font`, `current_embedded`, `font_size`, `x`, `y`, `char_spacing`, `line_height`, `text_color`, `text_decoration`)
  - Removed stateful setters: `setFont`, `setEmbeddedFont`, `setCharSpacing`, `setLineHeight`, `setTextColor`, `setTextStyle`
  - Removed stateful getters: `getLineHeightPts`, `getFontStyle`, `getCurrentTextStyle`, `getFontMetrics` (stateful version)
  - Removed: `measureText`, `setPosition`, `getPosition`, `getTextWidth` (stateful version)
  - Updated `currentDestination()` → `destination(y)` taking explicit y position
  - Updated `addPage()` to not reset x/y position (no longer tracked)

- **Updated test files**:
  - Removed stateful API tests from document_test.zig
  - Updated integration_tests.zig: generateOpenTypeFeaturessPdf, generateKerningPdf, font metrics test
  - All tests pass

- **Updated documentation**:
  - README.md: Updated `currentDestination()` example to `destination(y)`, updated API table
  - API_REVIEW.md: Updated Font Metrics table, added `currentDestination` removal to list

## What We Did (Session 2026-01-25)
- **Completed cli.zig explicit style migration**:
  - Removed all 33 `setFont` calls
  - Removed all `setEmbeddedFont` calls
  - All functions now use explicit TextStyle constants

- **Completed perf_test.zig explicit style migration**:
  - Removed 6 redundant `setEmbeddedFont` calls
  - Added missing base style parameter to `writeStyled` calls

- **Updated document_test.zig**:
  - Removed 4 redundant `setEmbeddedFont` calls
  - 1 remaining `setFont` is for testing stateful `getLineHeightPts()` method

- **Partial progress on integration_tests.zig**:
  - Removed all 17 `setFont` calls
  - Fully converted: generateCIDFontsPdf, generateInterFontsPdf, generateStyledTextPdf, generateValignPdf
  - 175 usages remain (mainly in generateGentiumDiacriticsPdf, generateOpenTypeFeaturessPdf)

- **Pattern for conversion**:
  ```zig
  // Before:
  try doc.setEmbeddedFont(font, 12);
  _ = try doc.writeAt(..., doc.getCurrentTextStyle());

  // After:
  const style_12 = platen.TextStyle{ .font = font, .size = 12 };
  _ = try doc.writeAt(..., style_12);
  ```

## What We Did (Session 2026-01-24 #7)
- **Removed dead/internal stateful text methods**:
  - `writeStyledGreedyFast` (dead code, never called)
  - `writeAtCursor`, `writeWithWordSpacing`, `writeAtStateful`, `writeLineInternal`
  - `countStyledLines` (stateful version, replaced by `countStyledLinesStyled`)

- **Fixed font tracking for explicit style API**:
  - `writeTextStyled` now properly registers fonts in `doc.used_fonts`
  - `writeWithWordSpacingStyled` also updated for font tracking
  - Tests using explicit styles now correctly include fonts in PDF output

- **Added `measureStyled` method**:
  - New styled version of `measureText` that takes explicit `TextStyle`
  - Returns `TextMetrics` (width, height, char_count)

- **Started test updates for explicit style API**:
  - Updated hyphen break tests to use `findHyphenBreakStyled`/`findSoftHyphenBreakStyled`
  - Updated font metrics tests to use `getFontMetricsStyled`
  - Updated text width tests to use `getTextWidthStyled`
  - Removed redundant `setFont` calls where explicit styles are used

- **Remaining work**:
  - ~50 more tests in document_test.zig still use `setFont`
  - integration_tests.zig, cli.zig, perf_test.zig need updates
  - Once tests updated, remove stateful API methods and fields

## What We Did (Session 2026-01-24 #6)
- **Updated documentation**:
  - README.md: Updated Graphics types section (StrokeStyle, FillStyle, ShapeStyle, Point, Rect)
  - API_REVIEW.md: Added Graphics API Changes section, updated method signatures, marked completed items

## What We Did (Session 2026-01-24 #5)
- **Removed deprecated stateful graphics API**:
  - Removed `setDrawStyle()` method
  - Removed `DrawStyle`, `DrawStyleOptions`, `GraphicsState` types
  - Removed document fields: `line_width`, `line_cap`, `line_join`, `dash_pattern`, `draw_color`, `fill_color`

- **Implemented explicit graphics API**:
  - New `StrokeStyle` struct with color, width (default 0.567), cap (default .square), join, dash
  - New `FillStyle` struct with color
  - New `ShapeStyle` combining optional stroke and fill
  - Style passed directly to draw methods (not stateful)

- **Updated all drawing methods to use Rect/Point types**:
  - `drawRect(rect: Rect, style: ShapeStyle)`
  - `drawRoundedRect(rect: Rect, radius, style: ShapeStyle)`
  - `drawLine(p1: Point, p2: Point, style: StrokeStyle)`
  - `drawCircle(center: Point, radius, style: ShapeStyle)`
  - `drawEllipse(rect: Rect, style: ShapeStyle)`
  - `drawPolygon(points, style: ShapeStyle)`
  - `drawPath(path, style: ShapeStyle)`
  - `fillRectGradient(rect: Rect, gradient_idx)`

- **Example usage**:
  ```zig
  // Stroke only (default 0.567pt width, square cap)
  try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{ .stroke = .{} });

  // Fill only with color
  try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{ .fill = .{ .color = Color.blue } });

  // Fill and stroke with custom settings
  try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 80 }, .{
      .fill = .{ .color = Color.rgb(255, 200, 200) },
      .stroke = .{ .color = Color.red, .width = 2 },
  });

  // Line with style
  try doc.drawLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .color = Color.blue, .width = 2 });
  ```

## What We Did (Session 2026-01-24 #4)
- Discussed graphics API design - decided on explicit/stateless approach
- Researched modern graphics APIs (Vulkan, Metal, WebGPU favor stateless)
- Discovered opacity gap (only SVG/PNG have opacity support)

## What We Did (Session 2026-01-24 #3)
- **Removed redundant measurement APIs**:
  - Removed `measureWrappedText()` (~150 lines) - duplicated `write()` logic
  - Removed `measureTextWidth()` - duplicate of `getTextWidth()`
  - Removed `MeasureOptions` and `WrappedTextMetrics` types
  - Updated platen.zig exports

- **Added `measure_only` to `writeStyled()`** for consistency with `write()`

- **Made `measure_only` side-effect free**:
  - Cursor position is now restored after measurement
  - No need to call `region.reset()` after measuring
  - Result still contains accurate `lines_written`, `rect`, and `overflow`

- **New measurement pattern** using `write(.measure_only=true)`:
  ```zig
  const result = try doc.write(&region, text, .{ .measure_only = true });
  // Cursor unchanged - measurement is side-effect free
  const content_height = @as(f64, @floatFromInt(result.lines_written)) * doc.getLineHeightPts();
  ```
  - Uses same code path as actual rendering (guaranteed accuracy)
  - Use `result.lines_written * line_height` for height calculation

- **Updated documentation**: README.md, DESIGN.md, API_COMPARISON.md, API_REVIEW.md

## What We Did (Session 2026-01-24 #2)
- **Removed writeParagraph** in favor of writeStyled API
- **Fixed spacing bug in writeStyled**:
  - Root cause: measureTextWidth didn't include kerning, but rendering did
  - Word positions drifted as kerning adjustments accumulated
  - Fix: Added kerning to measureTextWidth for identity encoding
- **Fixed file size bloat**: Added fast path for single-style lines in renderStyledLine
- **Optimized measureTextWidth performance** (recovered 14% regression from kerning fix):
  - Added hmtx_data cache to Font struct (avoids O(n) table search per glyph)
  - Added ascii_widths[128] cache for O(1) width lookup of common characters
  - Single-pass width+kerning calculation
  - Result: 823ms → 704ms (simple text back to 39ms baseline)

## What We Did (Session 2026-01-24)
- **Fixed measureTextWidth for identity encoding**:
  - Bug: measureTextWidth used byte-indexed WinAnsi width table for ALL text
  - For identity encoding, UTF-8 bytes were being looked up in WinAnsi table
  - Vietnamese characters like "Ớờ" measured as 29pt (wrong) instead of ~10pt (correct)
  - Fix: Decode UTF-8 and use actual glyph widths for identity encoding

- **CSS-style vertical alignment improvements**:
  - Changed .top valign to use half-leading calculation: `(line_height + ascender - descender) / 2`
  - Changed .middle valign to use cap_height for centering visual text mass
  - Added y_max field to FontMetrics for bounding box info
  - Get CapHeight from OS/2 table when available

- **Changed default font encoding to identity**:
  - Identity encoding preserves composite glyphs and supports full Unicode
  - Better default for modern text rendering

- **Migrated integration tests from writeParagraph to writeStyled**:
  - Created writeText helper for plain text via writeStyled
  - Updated reference PDFs for new valign calculation

## What We Did (Session 2026-01-23 #2)
- **Implemented `StyledText` builder API for styled paragraphs**:
  - New `src/styled_text.zig` with `StyledText` and `Span` types
  - Builder pattern mirroring existing `Path` API
  - `append(text, style)` and `appendOwned(text, style)` methods
  - Preprocessing for Knuth-Plass via `prepare()` method
  - Word boundary detection across styled spans
  - `measureWord()` helper for multi-span word width calculation

- **Document integration**:
  - `createStyledText()` - factory method
  - `writeStyled(region, text, opts)` - renders styled text with word wrap
  - `styledTextMeasure()` - callback for preprocessing
  - `renderStyledLine()` - uses `writeAt()` for each styled segment
  - `computeStyledOptimalBreaks()` - Knuth-Plass for styled text
  - `getStyledTextFromWord()` - extracts word text across spans

- **Features**:
  - Inline color changes (red, blue, green, etc.)
  - Text decorations (underline, strikethrough)
  - Combined styles (color + decoration)
  - Word wrapping across multiple lines
  - Justified/centered alignment
  - Optimal line breaking (Knuth-Plass)

- **Added 5 unit tests** in document_test.zig
- **Added integration test** `styled_text` with 7 demonstration sections
- **Exports**: `StyledText`, `Span` exported via platen.zig
- 288 tests pass

## What We Did (Session 2026-01-23)
- **Added `write(region, text)` API for chunked wrapped text**:
  - Enables inline style changes within flowing, wrapped text
  - `TextBox` now tracks `cursor_x` and `cursor_y`
  - Added `TextBox.newLine(line_height)` helper
  - Added `TextBox.remainingWidth()` helper
  - Renamed old `write(str)` to private `writeAtCursor()`

- **Public API now**:
  - `writeAt(x, y, text)` - absolute positioning, no wrap
  - `writeLine(region, text, opts)` - single line, no wrap
  - `write(region, text)` - **NEW** - flowing text with wrap, tracks cursor

- **Usage example**:
  ```zig
  var region = platen.TextBox{ .x = 50, .y = 100, .width = 300, .height = 200 };
  doc.setTextStyle(.{});
  _ = try doc.write(&region, "Normal text ");
  doc.setTextStyle(.{ .color = platen.Color.red });
  _ = try doc.write(&region, "red text ");
  doc.setTextStyle(.{ .decoration = .{ .underline = true } });
  _ = try doc.write(&region, "underlined.");
  ```

- **Updated text_style integration test** to use new `write()` API
- Added 5 unit tests for `write()` and `TextBox.newLine()`
- 274 tests pass

## What We Did (Session 2026-01-22 #4) [COMPLETE]
- **Implemented text decorations (underline, strikethrough)**:
  - **Font metrics parsing**:
    - Added `PostTable` and `Os2Table` to `ttf.zig` for underline/strikethrough metrics
    - Parse POST table for `underline_position`, `underline_thickness`
    - Parse OS/2 table for `strikeout_position`, `strikeout_size`
  - **EmbeddedFont metrics**: Added decoration fields, scaled to 1000 units
  - **Standard fonts**: Added decoration defaults to `StandardFontMetrics` (-100, 50, 250, 50)
  - **Layout types**:
    - `TextDecoration` struct with `underline`, `strikethrough` bools
    - `TextStyleOptions` struct with `color` and `decoration` (parallels `DrawStyleOptions`)
  - **Document API**:
    - Added `text_decoration` state field
    - Added `setTextStyle(TextStyleOptions)` method (sets color + decoration)
    - `TextCommand` stores decoration state and text width
    - `drawTextDecorations()` renders PDF rectangles after text
  - **Rendering**: Decorations drawn as filled rectangles outside BT/ET blocks
- **Added 6 unit tests** for decorations (using setTextStyle)
- **Added integration test** `text_decorations` with fpdf2 reference
- **Exports**: `TextDecoration`, `TextStyleOptions` exported via platen.zig
- **Updated API docs**: 54 methods (added setTextStyle)
- All tests pass

## What We Did (Session 2026-01-22 #3) [COMPLETE]
- **Renamed Bookmark → Outline** (matches PDF spec terminology):
  - `Bookmark` struct → `Outline`
  - `addBookmark()` → `addOutlineItem()`
  - Integration test renamed from `bookmarks` to `outlines`
- **Updated API_COMPARISON.md** to reflect low-level PDF focus:
  - Marked as "Not planned": Tables, Auto page break, Header/footer callbacks, HTML rendering, Multi-column layout
  - Reorganized priorities: Arc/pie shapes, Blend modes, Clipping paths, Annotations, Encryption
- **Simplified addPage API**: `addPage()` and `addPageWithSize()` → unified `addPage(size: ?PageSize)`
- **Fixed bugs**: Y coordinate conversion in `currentDestination()`, missing sibling links for top-level outlines

**Also in this session:**
- **Implemented PDF document outline for navigation**:
  - Added `Outline` struct to `layout.zig` with title, dest, parent, sibling/child links
  - Added `addOutlineItem(title, dest, parent)` method returning `*Outline` for nesting
  - Outlines stored in `Document.outlines` array, cleaned up in `deinit()`
  - PDF output generates /Outlines dict and outline item objects
  - /Dest uses [page_ref /XYZ left top zoom] format
  - Sibling links (/Next, /Prev) and child links (/First, /Last) generated from parent pointers
  - /Count field shows number of children (positive = expanded)
- **Implemented page labels for custom page numbering**:
  - Added `PageLabelStyle` enum: decimal, roman_lower, roman_upper, alpha_lower, alpha_upper, none
  - Added `PageLabel` struct with style, prefix, start fields
  - Added `setPageLabel(page_index, label)` method for label ranges
  - PDF output generates /PageLabels dict with /Nums number tree
  - Supports /S (style), /P (prefix), /St (start) entries
- **Updated exports**: Outline, PageLabelStyle, PageLabel exported via platen.zig
- **Added 11 unit tests** for outlines and page labels:
  - Basic and nested outline items, PDF output verification
  - PageLabelStyle.pdfCode(), setPageLabel basic usage
  - PDF output with various page label options (prefix, start number)
  - Verification that catalog doesn't include outlines/page labels when not set
- **Added integration test** `outlines`:
  - 7-page document with front matter (roman), body (decimal), appendix (alpha+prefix)
  - Nested outline (chapters with sections)
  - fpdf2 reference generated with matching structure
- All 260 tests pass (249 unit + 11 new + 25 integration)
- Updated API docs (54 methods)

## What We Did (Session 2026-01-22 #2) [COMPLETE]
- **API cleanup and documentation**:
  - Created `scripts/update_api_docs.py` - extracts API from doc comments, updates README
  - Updated README.md with complete API reference (52 methods in 10 categories)
  - Updated API_COMPARISON.md with link support as ✅
  - Added API Design Guidelines section to DESIGN.md
- **Unified `Point` type**:
  - Added `Point` to `layout.zig` as single source of truth
  - Updated `path.zig` and `svg.zig` to use `layout.Point`
  - Removed duplicate `Point` definitions
- **Simplified cursor API** (5 methods → 2):
  - Removed: `setXY`, `setX`, `setY`, `getX`, `getY`
  - Added: `setPosition(Point)`, `getPosition() -> Point`
- **Page index API**: `getPageIndex()` for 0-based index, `pageCount()` for total
- **Updated DESIGN.md** with all Region → TextBox, setXY → setPosition changes
- **Future consideration**: Replace `first_indent` option with general cursor advancement on TextBox

## What We Did (Session 2026-01-22 #1) [COMPLETE]
- **Implemented link support for TOC generation**:
  - Added `Rect` type for simple bounding boxes (x, y, width, height)
  - Added `Destination` type for internal link targets (page_index, y)
  - Renamed `Region` → `TextBox` (styled text container)
  - Renamed `getPageRegion()` → `getPageTextBox()`
  - Renamed `drawRegion()` → `drawTextBox()`
  - `writeAt()` now returns `Rect` for clickable area
  - `WriteResult` now includes `rect` field
  - Added `currentDestination()` method
  - Added `addLink(rect, dest)` for internal links (TOC navigation)
  - Added `addExternalLink(rect, url)` for external URL links
  - PDF output includes `/Annots` array with link annotations
  - Added links integration test
- **Fixed bugs**:
  - colored_text: `Color.green` → `Color.lime` (CSS green is 0,128,0)
  - shapes: Reference updated with correct 0.567pt default line width
  - svg_text: SVG now supports all 148 CSS colors
- **Unified CSS/SVG color handling**:
  - Added `Color.fromName()` with `StaticStringMap` for O(1) lookup of 148 colors
  - Added `Color.toRgb255()` for SVG conversion
  - SVG parser now uses shared color definitions from color.zig

**Decision:** PDF embedding scrapped - SVG already covers vector figure embedding from matplotlib, Inkscape, Illustrator, R/ggplot2.

## What We Did (Session 2026-01-21 #56) [COMPLETE]
- **Implemented quick wins from API gap analysis**:
  - **getPageIndex()**: Returns current page index (0-based)
  - **drawRoundedRect()**: Rounded rectangles using Bezier curves (KAPPA constant)
    - Parameters: x, y, width, height, corner_radius, style
    - Handles small radii (clamps to half min dimension)
- **Added unit tests**: 1 for getPageIndex/pageCount, 3 for rounded rectangles
- **Updated integration test**: Added rounded rectangles to shapes test
- **Regenerated fpdf2 reference**: Updated gen_references.py with round_corners=True
- **Updated documentation**: README (example + API table), API_COMPARISON.md
- All 249 unit tests + 23 integration tests pass

## What We Did (Session 2026-01-21 #55) [COMPLETE]
- **Created API_COMPARISON.md**: Comprehensive comparison of platen vs fpdf2 APIs
  - Identified all functional gaps organized by category
  - Prioritized gaps: High (metadata, links, tables), Medium (annotations, shapes), Lower (encryption, PDF/A)
  - Noted platen advantages: Knuth-Plass line breaking, measureWrappedText, more OpenType features
- **Implemented document metadata (Info dictionary)**:
  - Added `DocumentMetadata` struct with optional fields: title, author, subject, keywords, creator, producer, creation_date, mod_date
  - Added `metadata` field to Document struct
  - Added `setMetadata()` method to set all metadata at once (Zig-idiomatic struct-based API)
  - Updated `Writer.finish()` to accept `FinishOptions` with optional `info_ref`
  - Info dictionary written to PDF only when metadata fields are set
  - Auto-generates CreationDate and ModDate (UTC) when not explicitly set
  - Date format: `D:YYYYMMDDHHmmSSZ` (PDF standard)
  - Fixed PDF string escaping in `objects.zig` (was TODO) - now properly escapes `\`, `(`, `)`
- **Added CLI `metadata-test` command** for generating demo PDF with metadata
- **Added 7 unit tests for metadata**:
  - `DocumentMetadata.hasAnyField()` behavior
  - `setMetadata()` stores values correctly
  - Metadata written to PDF Info dictionary
  - Special characters escaped
  - No Info dict when metadata empty
- All 246 unit tests + 23 integration tests pass

## What We Did (Session 2026-01-21 #54) [COMPLETE]
- **Added page size API**:
  - New PageSize constants: A3, A5, Legal, Tabloid (already had A4, Letter)
  - `PageSize.landscape()` method to swap width/height
  - `setDefaultPageSize(size)` - set default for subsequent addPage() calls
  - `addPage(size)` - add page with specific size (null uses default)
  - Page struct now stores its own size for per-page MediaBox
- **Added 3 unit tests**: landscape, setDefaultPageSize, addPage with size
- **Added landscape integration test**: A4/Letter portrait/landscape, custom size
- **Created README.md**: full documentation with examples for all features
- All 239 unit tests + 23 integration tests pass

## What We Did (Session 2026-01-21 #53) [COMPLETE]
- **Implemented `measureWrappedText`** - measure text layout without rendering:
  - Added `WrappedTextMetrics` struct to `layout.zig`: height, line_count, max_line_width
  - Added `MeasureOptions` struct: width, first_indent, break_on_hyphens, line_breaking
  - Added `measureWrappedText()` to Document - uses same algorithm as `writeParagraph`
  - `fitsInHeight()` helper method for checking if text fits in available space
  - Exported types in `platen.zig`
- **Added 7 unit tests** for measureWrappedText:
  - Basic usage, multiple lines, empty text
  - Verifies line count matches `writeParagraph`
  - First indent reduces first line width
  - `fitsInHeight` helper
  - Newlines force line breaks
- **Updated documentation**:
  - DESIGN.md: Updated Path API as complete, added Text Measurement section
  - context.md: Marked all planned features complete
- All 235 unit tests pass

## What We Did (Session 2026-01-21 #52) [COMPLETE]
- **Implemented SVG `<use>` and `<defs>` support**:
  - Added to `src/svg.zig`:
    - `defs: StringHashMapUnmanaged(SvgElement)` - stores defined elements by ID
    - `SvgElement.clone()` - deep copy for elements with allocated memory
    - `storeElement()` - helper to store in defs or elements list
    - `parseUse()` - parses `<use>` elements with href/xlink:href
    - `applyTransformAndStyle()` - applies inherited transform and style to cloned elements
    - All shape parse functions now accept optional defs parameter for ID extraction
  - Parser now tracks `defs_depth` to handle `<defs>` blocks
  - Skips `<style>` elements (CSS not supported)
- **Added integration tests**:
  - `svg_use_defs`: use-defs.svg with directional shapes (boxes, triangles, arrows)
  - `svg_equation`: MathJax quadratic formula (reference bootstrapped from platen)
- **Added unit tests**:
  - `test "parse defs and use"` - basic defs/use parsing
  - `test "use element clones paths properly"` - verifies deep cloning
  - `test "parse MathJax equation SVG with xlink:href"` - real-world MathJax test
  - `test "use-defs.svg element counts"` - validates all elements parsed
- **Fixed transform order bug**: `<use x=".." y=".." transform="..">` now correctly applies translate(x,y) before the transform attribute (outer to inner)
- All 228 unit tests + 22 integration tests pass

## What We Did (Session 2026-01-21 #51) [COMPLETE]
- **Implemented SVG text element support**:
  - Added to `src/xml.zig`:
    - `getTextContent()` method to extract text between tags
  - Added to `src/svg.zig`:
    - `FontFamily` enum (serif, sans_serif, monospace)
    - `FontWeight` enum (normal, bold)
    - `FontStyle` enum (normal, italic, oblique)
    - `TextAnchor` enum (start, middle, end)
    - `UsedFont` struct with `toPdfName()` mapping to PDF Type1 fonts
    - `text` variant in `SvgElement` union with all text properties
    - `parseText()` function for text element parsing
    - `renderText()` function generating PDF text operators (BT, Tf, Td, Tj, ET)
    - `used_fonts` tracking for unique fonts used in SVG
  - Updated `src/document.zig`:
    - Added font resources to Form XObjects when SVG contains text
    - Uses static font name array (F1-F16) to avoid buffer overwrite bug
    - Inline font dictionaries reference standard Type1 fonts
- **Added svg_text integration test**:
  - Created `test/images/text-sample.svg` with various font styles
  - Added `gen_svg_text()` to `scripts/gen_references.py`
  - Added `generateSvgTextPdf` test in `integration_tests.zig`
- **Added --skip-fonts option** for semantic comparison:
  - `scripts/compare_pdfs.py`: Added `--skip-fonts` flag
  - `src/testing.zig`: Added `SemanticOptions` struct with `skip_fonts` field
  - `src/integration_tests.zig`: Test cases can specify `skip_fonts = true`
  - `src/cli.zig`: CLI supports skip_fonts for check-refs
  - Needed because platen uses inline font dicts in Form XObjects while fpdf2 uses object references
- All 20 integration tests pass (including svg and svg_text)

## What We Did (Session 2026-01-21 #50) [COMPLETE]
- **Fixed SVG style inheritance bug** - tiger.svg was rendering all black:
  - Changed Style field defaults from `Color.black` to `null` (meaning "unspecified")
  - Added getter methods: `getFill()`, `getStroke()`, `getStrokeWidth()`, etc.
  - Fixed merge logic so child elements properly inherit from parents
  - Child explicit values override parent; unspecified values inherit
- **Added opacity/transparency support**:
  - New Style fields: `opacity`, `fill_opacity`, `stroke_opacity` (all optional f64)
  - Parse `opacity`, `fill-opacity`, `stroke-opacity` attributes
  - Parse `rgba(r, g, b, a)` color format
  - `getFillOpacity()` and `getStrokeOpacity()` compute effective opacity (base * specific)
  - `hasTransparency()` method to check if style uses transparency
- **PDF ExtGState generation for transparency**:
  - Added `OpacityState` struct tracking unique (fill_op, stroke_op) pairs
  - SVG tracks opacity states during `toPdfContent()` via `getOrAddOpacityState()`
  - Form XObjects include `/Resources << /ExtGState << /GS1 << /ca X /CA Y >> >> >>`
  - Content stream emits `gs /GSn` operators when opacity < 1.0
  - Fixed use-after-free bug: write stream inside if block before defer cleanup
- Created `test/images/opacity_test.svg` with:
  - Overlapping semi-transparent circles (red, green, blue at 50%)
  - Rectangle with different fill/stroke opacity
  - Rectangle with overall `opacity` attribute
  - RGBA color example

## What We Did (Session 2026-01-21 #49) [COMPLETE]
- **Implemented SVG embedding as Form XObjects**:
  - Created `src/xml.zig` (~280 lines):
    - Minimal XML pull-parser for SVG parsing
    - `XmlParser` struct with `nextElement()` method
    - `Element` struct with tag, attributes, is_self_closing, is_end_tag
    - `AttributeIterator` for parsing attribute name/value pairs
    - Handles comments, XML declarations, DOCTYPE (skips them)
  - Created `src/svg.zig` (~1660 lines):
    - `Svg` struct with width, height, viewBox, elements list
    - `SvgElement` union: rect, circle, ellipse, line, polyline, polygon, path, group
    - Basic shapes: rect (with rounded corners), circle, ellipse, line
    - Polygon/polyline: parses points attribute
    - Path: full d-attribute parsing (M, L, H, V, C, S, Q, T, A, Z commands)
    - Arc-to-bezier conversion for SVG A command (no PDF equivalent)
    - Color parsing: hex (#RGB, #RRGGBB), rgb(), named colors (20+ colors)
    - Style parsing: fill, stroke, stroke-width, stroke-linecap, stroke-linejoin
    - Transform parsing: translate, scale, rotate, skewX, skewY, matrix
    - `toPdfContent()`: converts SVG to PDF drawing operators
    - Coordinate flip: SVG Y-down to PDF Y-up via `1 0 0 -1 0 height cm`
    - ViewBox support with proper scaling
  - Updated `src/document.zig`:
    - Added `loaded_svgs` list to Document
    - Added `used_svgs` list to Page
    - Added `loadSvg(path)` method - loads and parses SVG file
    - Added `drawSvg(svg, x, y, w, h)` method - draws SVG with scaling
    - Auto aspect ratio: if w=0 or h=0, calculates from SVG dimensions
    - PDF content: uses `q cm /SvN Do Q` operators for SVG placement
  - Updated `output()` in document.zig:
    - Reserve object IDs for SVGs (1 per SVG)
    - Write Form XObjects with proper dictionaries:
      - `/Type /XObject`, `/Subtype /Form`
      - `/BBox [0 0 width height]`
      - `/Filter /FlateDecode`, compressed content stream
    - Add XObject resources to page resource dictionaries
  - Re-exported types in `platen.zig`: `Svg`, `svg`, `xml` modules
- **Added integration test** (`generateSvgPdf` in `integration_tests.zig`):
  - Tests basic shapes, paths, colors, transforms
  - Tests auto aspect ratio calculation
  - Includes tiger.svg complex test (730 lines)
- Created test SVG files: `test/images/test.svg` (basic shapes), using existing `tiger.svg`
- All 211 tests pass (13 new XML/SVG tests + 1 integration test)

## What We Did (Session 2026-01-20 #48) [COMPLETE]
- **Implemented image embedding** (JPEG and PNG with alpha channel support):
  - Created `src/images.zig` (~625 lines):
    - `Image` struct with format, dimensions, color space, data, alpha_data
    - `ImageFormat` enum (jpeg, png)
    - `ColorSpace` enum (device_rgb, device_gray, device_cmyk)
    - JPEG parser: extracts dimensions from SOF markers, embeds raw DCT data
    - PNG parser: extracts IHDR, collects IDAT chunks, decompresses, unfilters, separates alpha
    - PNG filter support: None, Sub, Up, Average, Paeth predictor
  - Updated `document.zig`:
    - Added `loaded_images` list to Document
    - Added `used_images` list to Page (tracks images per page for resources)
    - Added `loadImage(path)` method - loads and parses image file
    - Added `drawImage(image, x, y, w, h)` method - draws image with scaling
    - Auto aspect ratio: if w=0 or h=0, calculates from image dimensions
    - PDF content: uses `q cm /ImN Do Q` operators for image placement
  - Updated `output()` in document.zig:
    - Reserve object IDs for images (1 per image, +1 for SMask if PNG with alpha)
    - Write image XObjects with proper dictionaries:
      - JPEG: `/Filter /DCTDecode`, raw JPEG data
      - PNG: `/Filter /FlateDecode`, re-compressed pixel data
      - PNG with alpha: separate SMask XObject for transparency
    - Add XObject resources to page resource dictionaries
  - Re-exported types in `platen.zig`: `Image`, `ImageFormat`, `ImageColorSpace`
- **Added fpdf2 reference generator** (`gen_images()` in `gen_references.py`):
  - Page 1: JPEG and PNG images at fixed sizes
  - Page 2: Aspect ratio tests (width-only, height-only specified)
- **Added integration test** (`generateImagesPdf` in `integration_tests.zig`):
  - Tests both JPEG and PNG image embedding
  - Tests auto aspect ratio calculation
  - Compares against fpdf2 reference
- All 197 tests pass (196 + 1 new integration test)

## What We Did (Session 2026-01-20 #47) [COMPLETE]
- **Fixed drawCircle coordinate handling** in `document.zig`:
  - fpdf2's `circle(x, y, r)` takes CENTER coordinates, not bounding box
  - platen's `drawCircle` was incorrectly passing (x, y) directly to `drawEllipse` which expects bounding box coordinates
  - Fix: Convert center to bounding box in drawCircle: `drawEllipse(x - radius, y - radius, diameter, diameter, style)`
  - Updated comment to correctly document that (x, y) is the CENTER of the circle
- **Fixed default line cap** to match fpdf2:
  - fpdf2 uses `2 J` (projecting square cap) as default, not butt cap
  - Changed `line_cap` default from `.butt` (0) to `.square` (2) in Document struct
  - Updated unit test to expect `.square` as default
- All 195 tests pass, semantic comparison passes for all PDFs including shapes

## What We Did (Session 2026-01-20 #46) [COMPLETE]
- **Implemented graphics primitives** in `document.zig`:
  - Added types to `layout.zig`: `DrawStyle` (stroke/fill/fill_stroke), `LineCap` (butt/round/square), `LineJoin` (miter/round/bevel), `DashPattern`
  - Added state fields to Document: `line_width`, `dash_pattern`, `line_cap`, `line_join`
  - Added setter methods: `setLineWidth()`, `setDashPattern()`, `setSolidLine()`, `setLineCap()`, `setLineJoin()`
  - Added shape drawing methods: `drawLine()`, `drawRect()`, `drawCircle()`, `drawEllipse()`, `drawPolygon()`
  - Ellipse uses 4 cubic Bezier curves (KAPPA = 0.5522847498)
  - Polygon supports arbitrary point arrays
  - All methods use `q`/`Q` graphics state save/restore
  - Re-exported new types in `platen.zig`
- **Added unit tests** for graphics primitives in `document_test.zig`:
  - Tests for all shape methods (drawLine, drawRect, drawCircle, drawEllipse, drawPolygon)
  - Tests for state setters (setLineWidth, setDashPattern, setLineCap, setLineJoin)
  - Tests verify valid PDF output (content is compressed, so checking structure not raw operators)
- **Added fpdf2 reference generator** (`gen_shapes()` in `gen_references.py`):
  - Lines (solid, thick, colored, dashed)
  - Rectangles (stroke, fill, fill_stroke)
  - Circles and ellipses with various styles
  - Polygons (triangle, square, pentagon)
- **Added integration test** (`generateShapesPdf` in `integration_tests.zig`):
  - Matches fpdf2 reference layout
  - 16 integration tests now pass (including new shapes test)
- All 195 tests pass

## What We Did (Session 2026-01-20 #45) [COMPLETE]
- **Fixed refactoring regressions** - 3 failing tests (`all_fonts`, `justify`, `optimal_breaks`):
  - Word spacing (`Tw`): Now always emitted (PDF state persists across text blocks)
  - Standard fonts: Removed incorrect `WinAnsiEncoding` (Symbol/ZapfDingbats use special encodings)
  - Greedy line breaking: Restored original word-by-word algorithm in `writeParagraph`
  - Optimal line breaking: Restored original DP algorithm in `computeOptimalBreaks`
  - `drawRegion`: Added `q`/`Q` graphics state, line width `0.567 w`, black stroke
  - `renderPageCommands`: Added `0 g` for black text in BT blocks
  - Font subsetting: Restored missing `generateSubset()` call in `output()`
  - Added `subset_ms` timing field to `OutputTiming`
- All 171 tests pass, PDF output matches reference files exactly

## What We Did (Session 2026-01-20 #44) [COMPLETE]
- **Major platen.zig refactoring** (3415 → ~3800 lines across 5 modules):
  - Created `document.zig` (~2000 lines): Document struct + internal types (Page, ContentWriter, etc.)
  - Created `document_test.zig` (1403 lines): All Document tests moved here
  - Created `color.zig` (159 lines): Color types
  - Created `layout.zig` (147 lines): Layout types (Region, Margins, etc.)
  - Updated `platen.zig` (100 lines): Now a thin facade that re-exports from document.zig
  - Made `findSoftHyphenBreak`, `findHyphenBreak`, `renderPageCommands` public for testing
- **Fixed memory leak in Document.output()**: Added `defer w.deinit()` for Writer cleanup

## What We Did (Session 2026-01-20 #43) [COMPLETE]
- **Conducted Text API gap analysis** - wrote TEXT_API_REPORT.md
- **Implemented Color support**:
  - Created `color.zig` module with tagged union `Color` type
  - Supports grayscale (g/G), RGB (rg/RG), and CMYK (k/K) color spaces
  - Added `setTextColor()`, `setFillColor()`, `setDrawColor()` to Document
  - Text color emitted in PDF content stream per text command
  - Updated `drawRegion()` to use new Color API
  - Helper functions: `Color.grayscale()`, `Color.fromRgb()`, `Color.fromRgb255()`, `Color.fromCmyk()`
- **Implemented Font Metrics API**:
  - Added `FontMetrics` struct with ascender, descender, cap_height, x_height, font_size, units_per_em
  - Added `getFontMetrics()` to Document - returns metrics scaled to current font size
  - Standard fonts use hardcoded AFM-derived values (Helvetica, Times, Courier families)
  - Embedded fonts use actual metrics from TTF/OTF file
- **Refactored platen.zig** (3615 → 3415 lines, -200):
  - Created `layout.zig` (147 lines): Border, Align, VAlign, Margins, Padding, Region, PageSize, *Options
  - Moved `FontMetrics`, `StandardFontMetrics`, `getStandardFontMetrics` to `metrics.zig`
  - platen.zig now re-exports layout types for API compatibility
- **Added tests** for all new APIs (color stored in commands, font metrics scaling)
- All 171 tests pass

## What We Did (Session 2026-01-20 #42) [COMPLETE]
- **Added ASCII fast path for UTF-8 decoding - ~1% improvement**:
  - Skip `utf8ByteSequenceLength` and `utf8Decode` for bytes < 128
  - Byte value equals codepoint directly for ASCII
  - Updated both `markUnicodeCharsUsed` and `getGlyphsForText` loops
- **Performance results**:
  - Total: 660ms → 654ms
  - Combined with cmap cache: pure ASCII text now has minimal overhead
- All 156 tests pass

## What We Did (Session 2026-01-20 #41) [COMPLETE]
- **Implemented cmap cache and ASCII lookup table - 12% overall improvement**:
  - Added `cmap_subtable_offset` and `cmap_format` fields to Font struct (ttf.zig:27-29)
  - Added `ascii_glyphs[128]` lookup table for O(1) ASCII character lookup (ttf.zig:31-33)
  - Added `initCmapCache()` function called during font parse (ttf.zig:86-134)
  - Updated `getGlyphId()` to use ASCII cache first, then cached subtable (ttf.zig:216-237)
- **Performance results**:
  - Total: 752ms → 660ms (12% faster)
  - Simple text: 73ms → 39ms (47% faster)
  - Text flow: 54ms → 33ms (39% faster)
  - "No features" microbenchmark: 0.050ms → 0.030ms (40% faster)
- **Updated PERFORMANCE.md** with optimization #13 details
- All 156 tests pass

## What We Did (Session 2026-01-20 #40) [COMPLETE]
- **Implemented arena allocator per page - ~4% overall improvement**:
  - Added `arena` field to `Page` struct (platen.zig:280)
  - Updated `Page.init()` to take backing allocator
  - Added `pageAllocator()` method for page-local allocations
  - All per-command allocations (text_data, cached_glyphs, raw content) now use page arena
  - Batch-freed when page is destroyed via `arena.deinit()`
- **Modified `markUnicodeCharsUsed` signature** (embedded.zig:378):
  - Added optional `output_allocator` parameter
  - Allows caller to control where glyph arrays are allocated
  - Internal scratch buffers still use font's allocator
- **Performance results**:
  - Total: 784ms → 752ms (~4% faster)
  - Simplified memory management (removed individual errdefers)
- **Updated PERFORMANCE.md** with optimization #12 details
- All 156 tests pass

## What We Did (Session 2026-01-20 #39) [COMPLETE]
- **Implemented chain context rule index - 51% faster OpenType shaping**:
  - Added `calt_rule_index` hash map to OpenTypeFeatures (opentype.zig:637-640)
  - Maps glyph_id → list of rule indices that can match at that glyph
  - Built at parse time by enumerating each rule's first input coverage
  - At runtime, lookup applicable rules by current glyph (O(1)) instead of checking all 65 rules
- **Added CoverageTable iteration methods** (opentype.zig:136-191):
  - `getGlyphCount()` - total glyphs in coverage
  - `getGlyphAt(index)` - get glyph at given coverage index
  - Supports both Format 1 (list) and Format 2 (ranges)
- **Performance results**:
  - OpenType heavy: 487ms → 236ms (51% faster, 2x speedup)
  - Unicode/marks: 174ms → 115ms (34% faster)
  - Total: 1097ms → 784ms (29% faster)
  - Overall from start: 2600ms → 784ms (70% faster, 3.3x speedup)
- **Updated PERFORMANCE.md** with new findings
- All 156 tests pass

## What We Did (Session 2026-01-20 #38) [COMPLETE]
- **Implemented lazy kerning cache - 61% faster page rendering**:
  - Added `kern_cache` hash map to OpenTypeFeatures (opentype.zig:589-590)
  - Key: `(glyph1 << 16) | glyph2`, Value: kern adjustment (i16)
  - Lazy population: first lookup does full search and caches; subsequent lookups are O(1)
  - High cache hit rate due to repeated glyph pairs across text commands
- **Performance results**:
  - Page rendering: 395ms → 154ms (61% faster, 2.5x speedup)
  - PDF output: 518ms → 277ms (47% faster)
  - Total: 1336ms → 1097ms (18% faster)
  - Overall from start: 2600ms → 1097ms (58% faster)
- **Updated PERFORMANCE.md** with new findings
- All 156 tests pass

## What We Did (Session 2026-01-20 #37) [COMPLETE]
- **Profiled and optimized PDF output - 24% faster**:
  - Added timing instrumentation to `output()` function (subset, render, font_write, page_write, finish)
  - Added timing breakdown display to perf_test
  - **Key finding**: Page rendering was 553ms (81% of output), not compression!
- **Optimizations implemented**:
  1. **Early exit from kerning/mark check loop** (platen.zig:666-684) - exit once both flags determined
  2. **Cached `has_kern_data`/`has_mark_data` flags** (embedded.zig:174-176) - skip check loop for fonts without GPOS data
  3. **Fast hex conversion** (platen.zig:32-41) - lookup table instead of `std.fmt.bufPrint`
- **Performance results**:
  - Page rendering: 553ms → 395ms (28% faster)
  - PDF output: 680ms → 518ms (24% faster)
  - Total: ~1480ms → ~1336ms (10% faster)
- **Updated PERFORMANCE.md** with new findings and output breakdown
- All 156 tests pass

## What We Did (Session 2026-01-20 #36) [COMPLETE]
- **Performance optimization - 2.5x speedup for text shaping**:
  - Created `src/perf_test.zig` - comprehensive performance test suite
  - Added shaping microbenchmark to isolate OpenType costs
  - OpenType heavy: 1244ms → 484ms (2.5x faster)
  - Total 100-page PDF: ~2600ms → ~1480ms (43% faster)
- **Key optimizations**:
  1. Fast-path first coverage check in `ChainContextSubstF3.match()` - check first input glyph before backtrack/lookahead
  2. Pre-allocated ArrayLists with `ensureTotalCapacity` + `appendAssumeCapacity`
  3. Scratch buffers in `OpenTypeFeatures` (scratch_a, scratch_b, scratch_c) - ping-pong buffers for feature application
  4. Scratch buffers in `EmbeddedFont` (scratch_codepoints, scratch_glyphs) - reused across shaping calls
  5. O(1) glyph lookup replacing O(n) hashmap iteration in `applyGSUBAndTrack`
  6. Fast soft-hyphen check using `std.mem.indexOf`
- **Created PERFORMANCE.md** - detailed performance report with findings and suggestions
- **Remaining bottlenecks identified**:
  - PDF output: 666ms (45%) - needs profiling
  - Per-call allocation overhead in writeAt: ~0.20ms
  - Chain context rule iteration (65 rules in Inter)
- All 156 tests pass

## What We Did (Session 2026-01-20 #35) [COMPLETE]
- **Improved inter_fonts test layout**:
  - Two-column layout with OFF/ON column headers (x=80 and x=330)
  - All OFF examples aligned left, all ON examples aligned right
  - Consistent spacing between feature rows
- **Improved feature examples**:
  - calt: Arrow ligatures (-> => <- <=>) showing contextual substitution
  - case: A@B (C) 3 + 9 = 12 * 1 showing case-sensitive punctuation adjustment
  - Added stacked marks row (ẳ ế ộ ỗ) for mark-to-mark demo (ON side only)

## What We Did (Session 2026-01-20 #34) [COMPLETE]
- **Fixed zero/case/ss01 features not being applied**:
  - Root cause 1: parseGSUB didn't call parseGSUBFeature for zero, case, ss01
  - Root cause 2: embedded.zig needs_ot check didn't include new features
  - Root cause 3: has_gsub checks didn't trigger applyGSUBWithFlags for new features
  - Added all new features to needs_ot and has_gsub checks in embedded.zig
- **Added OpenType figure/number features to inter_fonts test**:
  - dlig: Added chain context support for f/t variants (ff fi ffi ft tt tf rf rt vf wt), interrobangs (!? → ‽)
  - tnum/pnum: Tabular vs proportional figures side-by-side comparison
  - frac: Fractions feature with fraction slash (1⁄2 3⁄4 5⁄8 7⁄16)
  - zero: Slashed zero for distinguishing 0 from O
  - case: Case-sensitive forms for punctuation with uppercase (A@B 3+9≈12*1)
  - ss01: Stylistic Set 1 with alternate digits (3 4 6 9 a g)
- **Refactored OpenType parsing**:
  - Created `applySingleSubstFeature` helper for tnum/pnum/zero/case/ss01
  - Created `applyChainContext` helper for frac and dlig chain context rules
  - Added dedicated `*_lookups` storage for each feature
  - Proper nested lookup dispatch in chain context for all new features

## What We Did (Session 2026-01-20 #33) [COMPLETE]
- **Fixed calt (contextual alternates) bug at scale**:
  - Root cause 1: same codepoint can produce different glyphs in different contexts
  - Added `glyph_to_codepoint` map to track ALL glyphs for ToUnicode (not just first per codepoint)
  - Root cause 2: chain context rules referenced nested lookups that weren't being parsed
  - Added post-processing in `parseGSUBFeature` to parse nested lookups from chain context rules
  - Now correctly handles `<-` → arrowleft (nested ligature lookup from chain context)
- **Enabled calt by default**: `FeatureFlags.calt = true` in opentype.zig
- **Updated inter_fonts test**: Added calt ON/OFF comparison (-> => <- <=> 3*9 12:34 3–8 +8+x)
- All 156 tests pass

## What We Did (Session 2026-01-19 #32) [COMPLETE]
- **Added static HTML API documentation build step**:
  - `zig build docs` generates markdown via zigmarkdoc, converts to static HTML
  - Docs output to `docs/` directory (viewable without server)
  - Dark mode support, navigation bar, syntax highlighting
  - Installed zigmarkdoc tool in `tools/zigmarkdoc/`
  - Scripts: `scripts/gen_docs.sh`, `scripts/md_to_html.py`
- **Added `getCodepointWidth(u21)` to EmbeddedFont**:
  - Unicode-aware character width for CID mode
  - Complements existing `getCharWidth(u8)` for WinAnsi mode
- All 156 tests pass

## What We Did (Session 2026-01-19 #31) [COMPLETE]
- **Fixed Gentium diacritics PDF Y coordinate issue**:
  - PDF was rendering bottom-up because test used wrong coordinate convention
  - Changed from `y = 780; y -= ...` to `y = 32; y += ...` to match platen's top-origin system
- **Enhanced Gentium diacritics reference with uppercase/lowercase pairs**:
  - All examples now show Aa, Ee, Oo pairs (e.g., Aa Ee Oo with diacritics)
  - Descriptions moved to word-wrapped regions on right side using `writeParagraph`
  - Fixed baseline alignment with `desc_offset` adjustment
- **Fixed Vietnamese horn characters**: Changed to precomposed Oo Uu (horn doesn't combine well)
- Added `test "integration: gentium_diacritics PDF"` test declaration
- All 157 tests pass

## What We Did (Session 2026-01-19 #30) [COMPLETE]
- **Fixed mark positioning to use Tm absolute coordinates (like LibreOffice)**:
  - Changed from relative Td positioning to absolute "1 0 0 1 x y Tm" for each glyph
  - Each glyph now gets explicit absolute coordinates instead of relying on PDF auto-advance
  - Fixed stacked Vietnamese diacritics (mark-to-mark) by tracking prev_x/prev_y between marks
- **Fixed mark detection for multiple marks on same base**:
  - Detection loop now checks mark-to-base fallback when mark-to-mark fails
  - Example: s + cedilla (below) + acute (above) - both attach to 's', not to each other
  - Rendering correctly uses base coordinates for both marks
- **Added "Below+Above" showcase to inter_fonts test**:
  - Demonstrates marks both above and below base character: ş́ ç̂ ţ̃
  - Note: Inter font only has proper cedilla anchors for s/c/t/S/C/T (ogonek/dot-below anchors place marks above baseline)
- **Added comprehensive Gentium diacritics reference PDF**:
  - New integration test: `gentium_diacritics` with Gentium-Regular/Bold/Italic
  - Gentium has 4 mark-base + 2 mark-mark lookups with extensive diacritic coverage
  - Showcases: combining marks (above/below), stacked Vietnamese, above+below combos, precomposed Vietnamese, Latin Extended (ogonek/cedilla/caron), multiple diacritics stress test
  - Sample text in Vietnamese, Polish, Turkish, French
- All 156 tests pass

## What We Did (Session 2026-01-18 #29) [COMPLETE]
- **Fixed mark/mkmk positioning causing overlapping characters**:
  - `getGlyphWidth()` was returning 0 for glyphs not in CID width cache (like combining marks)
  - Added fallback to get width directly from font's hmtx table with proper scaling
  - Mark positioning now correctly places diacritics (À É Õ Ñ render correctly)
- All 154 tests pass

## What We Did (Session 2026-01-18 #28) [COMPLETE]
- **Fixed GPOS Extension Positioning (Type 9) parsing**:
  - Inter font uses Type 9 extension lookups to wrap Type 2 kerning data
  - Added handling for lookup type 9 in `parseGPOSLookup()` which unwraps to actual lookup types
  - Kerning now works for Inter font: AV=-140, AW=-116, To=-160, Wa=-104
  - Kerning lookups increased from 6 to 10 with correct data
- **Condensed inter_fonts.pdf to single page with feature placeholders**:
  - Working: kern (OFF/ON), mark/mkmk (OFF/ON/Stacked)
  - TODO placeholders: calt, dlig, tnum/pnum, frac, zero, case, ss01-08
  - Unicode coverage: Latin, Greek, Cyrillic, Punctuation, Currency, Math, Arrows, Symbols, Figures, ASCII
- All 154 tests pass

## What We Did (Session 2026-01-18 #27) [COMPLETE]
- **Investigated calt integration test failure**:
  - Inter font has NO `liga` feature - arrow ligatures (`<=>` → `⇔`) are in `calt` via Type 4 lookups
  - **Bug discovered**: calt chain context has a bug at scale (unit tests pass, integration fails with bizarre substitutions)
  - calt disabled by default until bug is diagnosed
- **Cleaned up reference PDFs**: Removed `inter_opentype_features*.pdf`, `scripts/gen_inter_features.py`, `inter-features` CLI
- **Enhanced inter_fonts.pdf**: Added kerning and mark positioning OFF/ON demonstrations

## What We Did (Session 2026-01-18 #26) [COMPLETE]
- **Added dlig/clig/hlig support with separate lookup arrays**:
  - Added `dlig_lookups`, `clig_lookups`, `hlig_lookups`, `calt_liga_lookups` arrays
  - Modified `parseLigatureSubtable()` to return `?LigatureSubst` instead of appending directly
  - `parseGSUBLookup()` now stores ligature lookups in the appropriate array based on feature
  - Expanded `GSUBLookupRef` union to include `liga`, `dlig`, `clig`, `hlig`, `calt_liga` variants
  - Updated `applyCalt()` nested lookup dispatch to handle all ligature ref types
  - Added `applyFeatureLigatures()` generic function and `applyDlig/Clig/Hlig` convenience wrappers
  - Added `applyGSUBWithFlags()` that applies all enabled GSUB features based on `FeatureFlags`
  - Updated `embedded.zig` to use `applyGSUBWithFlags()` with feature flags
  - Removed dead `applyLigaturesAndTrack()` function
  - Inter font: 0 liga lookups, 1 dlig lookup, arrow ligatures in calt_liga_lookups
- All 152 tests pass

## Remaining Work
- None - all planned features complete

## What We Did (Session 2026-01-18 #25) [COMPLETE]
- **Implemented mark positioning in PDF rendering**:
  - Modified `renderCIDTextWithKerning()` to detect mark glyphs and apply positioning
  - Added `renderWithMarkPositioning()` for glyph-by-glyph rendering with Td offsets
  - Mark offsets converted from design units to PDF points using font_size/units_per_em
- **Added mark-test CLI command and Inter mark positioning test**
- Arrow ligatures in Inter are from calt (Type 4 lookups), not liga
- All tests pass

## What We Did (Session 2026-01-18 #24) [COMPLETE]
- **Fixed slice invalidation bug in GSUB parsing**:
  - Changed `LigatureSet` and `LigatureSubst` from slice-based to index-based storage
  - Prevents dangling pointers when ArrayLists reallocate during `parseAllGSUBLookups`
  - Updated `findLigature()` signature to take arrays as parameters
  - Fixed all call sites: `applyLigatures`, `applyCalt`, `applyLigaturesAndTrack`, tests
- **Fixed calt applying wrong substitutions**:
  - Issue: Chain context lookups from ALL features were being parsed, not just calt
  - Solution: Filter Type 6 parsing to only calt feature
  - Also removed dlig/clig/hlig parsing (disabled by default, was mixing into liga_lookups)
- **Disabled calt by default** (`calt: bool = false` in FeatureFlags):
  - Chain context matching still has issues with Inter font
  - Arrow ligatures (`->` → arrow) not working yet
- **Fixed ToUnicode conflict for characters with both direct glyph and ligature**:
  - Issue: Inter has `⇔` as both a direct glyph (U+21D4) AND a `<=>` ligature
  - When both appear in text, duplicate ToUnicode mappings caused extraction issues
  - Solution: Skip adding ligature mapping if glyph already mapped to single codepoint
- **Integrated calt into text tracking pipeline**:
  - Added `applyGSUBAndTrack()` in embedded.zig to track calt + liga substitutions
  - Updated `markUnicodeCharsUsed()` to use new combined tracking
- **Updated Inter reference PDF** to match our liga behavior:
  - Inter's liga feature includes `<=>` → ⇔ ligature
  - fpdf2 doesn't apply this, we do (more correct OpenType behavior)
- All 151 tests pass

## What We Did (Session 2026-01-18 #23-24) [COMPLETE]
- **Implemented OpenType feature parsing for calt, mark, mkmk**:
  - Added Feature enum values: `calt`, `mark`, `mkmk`
  - Added FeatureFlags fields: `calt=true`, `mark=true`, `mkmk=true` (defaults)
- **GSUB Type 1 (Single Substitution)** parsing:
  - `SingleSubst` struct with Format 1 (delta) and Format 2 (direct mapping)
  - `parseSingleSubtable()` in OpenTypeFeatures
  - Unit test for delta and direct substitution
- **GSUB Type 6 Format 3 (Chaining Context)** parsing:
  - `ChainContextSubstF3` struct with backtrack/input/lookahead coverages
  - `SubstLookupRecord` for nested lookup invocation
  - `parseChainContextSubtable()` handles Format 3
  - `match()` method for rule matching at position
  - Unit test for chain context matching
- **GPOS Type 4 (Mark-to-Base)** parsing:
  - `Anchor`, `MarkRecord`, `MarkBasePos` structs
  - `parseMarkBaseSubtable()` parses mark/base coverage and anchor arrays
  - `getAttachment()` returns `MarkOffset` (dx, dy)
- **GPOS Type 6 (Mark-to-Mark)** parsing:
  - `MarkMarkPos` struct similar to MarkBasePos
  - `parseMarkMarkSubtable()` for combining marks
- **Updated parseGSUB/parseGPOS** to use new dispatch-based lookup parsing:
  - `parseGSUBLookup()` dispatches Type 1, 4, 6
  - `parseGPOSLookup()` dispatches Type 2, 4, 6
  - Removed redundant `parseLigatureLookup()`, `parseKernLookup()`
- **Added lookup index tracking for nested lookup dispatch**:
  - `GSUBLookupRef` union type to reference lookups by type and index
  - `gsub_lookup_map` maps lookup index -> lookup reference
  - Enables chain context rules to invoke nested substitutions
- **Implemented calt application methods**:
  - `applyCalt()`: Iterates glyphs, matches chain context rules, applies nested lookups
  - `applyGSUB()`: Combines calt + liga in proper order
  - `getMarkOffset()`: Returns mark positioning offset for base/mark glyph pair
  - Added `MarkOffset` named type for offset values
- **Integrated into text rendering pipeline**:
  - `EmbeddedFont.getGlyphsForText()`: Now uses `applyGSUB` when both calt and liga enabled
  - `EmbeddedFont.getMarkOffset()`: Exposes mark positioning to rendering layer
- **Test results with Inter-Regular.ttf**:
  - GSUB: 70 chaining context lookups, 1 ligature lookup, 4 lookup map entries
  - GPOS: 6 kerning, 5 mark-to-base, 1 mark-to-mark
- All 150 tests pass

## What We Did (Session 2026-01-18 #21-22) [COMPLETE]
- **Implemented Knuth-Plass optimal line breaking** for `writeParagraph`:
  - Added `LineBreaking` enum (`.greedy`, `.optimal`) in `ParagraphOptions`
  - `computeOptimalBreaks()`: DP minimizing total slack² across all lines
  - `writeParagraphOptimal()`: renders using pre-computed break points
  - Fixed floating-point tolerance in greedy (79.2 + 21.6 > 100.8)
  - Fixed paragraph break detection: scan past spaces to find newlines
- **Algorithm**: O(n*w), forced breaks respected, last lines left-aligned
- **Integration test**: Side-by-side greedy vs optimal columns with Lorem Ipsum
- All 144 tests pass

## What We Did (Session 2026-01-18 #20) [COMPLETE]
- **Implemented justify alignment** for `writeParagraph`:
  - Added `word_spacing` field to `TextCommand` struct
  - Created `writeWithWordSpacing()` internal function for justified text
  - Modified `writeLineInternal()` to calculate word spacing: `(available_width - text_width) / space_count`
  - Emit PDF `Tw` (word spacing) operator in `renderPageCommands()`
  - Always emit `Tw` to reset state between text blocks (PDF state persists)
  - Last line of paragraph uses left-alignment (standard typography)
- **Added justify integration test** with longer paragraphs:
  - Long paragraph (451pt) - 7 justified lines + 1 left-aligned last line
  - Narrow column (200pt) - demonstrates visible word spacing
  - Comparison section showing left vs justified with same text
- Updated `gen_references.py` with matching fpdf2 justify test
- All 141 tests pass

## Tools
- **Zig tools** (in `tools/`): `simgrep`, `zigmap`
- **Python venv** (`.venv/bin/`):
  - `fpdf2` 2.8.5 - reference implementation for generating test PDFs
  - `fonttools`/`ttx`/`pyftsubset` - font inspection and subsetting
  - `PyMuPDF` - PDF parsing and validation
  - `uharfbuzz` - text shaping reference
  - `pillow` - image handling

## What We Did (Session 2026-01-18 #19) [COMPLETE]
- **Fixed soft-hyphen recursive breaking**: Column width was 24pt but "com-" is 24.4pt
  - Changed soft-hyphen demo from 24pt to 26pt column
  - Changed regular hyphen demo from 35pt to 100pt (fpdf2 was doing char-level wrap at 35pt)
- **Added character-level wrapping**: Last resort for long words without break points
  - New `findCharacterBreak()` function respects UTF-8 boundaries
  - Integrated as fallback after hyphen and soft-hyphen breaks fail
  - Added "Character Wrap (50pt column)" demo showing "supercalifragilisticexpialidocious"
- **Fixed overflow test**: Changed from 451pt to 150pt width so text actually overflows
  - Now shows 2 lines fit, overflow content displayed separately
- **Fixed rect border/fill covering text**: Graphics state not isolated
  - Added `q` (save) and `Q` (restore) operators around fill/border drawing
  - Fill color no longer affects subsequent text rendering
- **Fixed border thickness**: PDF default 1pt vs fpdf2 default 0.567pt (0.2mm)
  - Added `0.567 w` line width command before border drawing
- **Fixed Y position differences**: Sections using default valign=.top vs fpdf2's middle positioning
  - Added explicit `valign = .middle` to character wrap and overflow sections
- Added unit test for character-level wrapping
- All 140 tests pass

## What We Did (Session 2026-01-18 #18) [COMPLETE]
- **Fixed soft-hyphen rendering**: Soft-hyphens were being rendered as visible characters
  - Added `stripSoftHyphens()` helper to remove U+00AD from text
  - Updated `write()` to strip soft-hyphens before storing (they're invisible)
  - Updated `getTextWidth()` to exclude soft-hyphens from width measurements
  - Added `containsSoftHyphens()` for fast path optimization
- Soft-hyphens now behave correctly:
  - Invisible in normal text (stripped before output)
  - Excluded from width calculations
  - Only appear as visible hyphens when used as break points
- **Added `break_on_hyphens` option to `ParagraphOptions`**:
  - Default `true`: Break after regular hyphens in compound words (e.g., "state-" / "of-the-art")
  - Set `false` for fpdf2 compatibility (only soft-hyphens break)
  - Added `findHyphenBreak()` helper to find break points at regular hyphens
  - Hyphen breaks tried before soft-hyphen breaks as fallback
- Updated integration test to use `break_on_hyphens: false` for fpdf2 matching
- **Added comprehensive unit tests** (18 new tests, 138 total):
  - `findHyphenBreak` and `findSoftHyphenBreak` function tests
  - Soft-hyphen stripping from output and width calculations
  - `writeParagraph` hyphen breaking (enabled/disabled)
  - First line indent, overflow handling, newline line breaks
  - `writeLine` overflow behavior
  - Region padding effects on content area
  - `writeFlow` empty text and margin handling
  - VAlign positioning tests (top, middle, bottom)
- Fixed `writeLineInternal` to check remaining height and return overflow
- All 138 tests pass

## What We Did (Session 2026-01-18 #17) [COMPLETE]
- **Added VAlign (vertical alignment)**:
  - New `VAlign` enum: `.top`, `.middle`, `.bottom`
  - `.top` (default): baseline = content_y + cursor_y + font_size (simple)
  - `.middle`: baseline = content_y + cursor_y + font_size - leading/2 (fpdf2 compatible)
  - `.bottom`: baseline = content_y + cursor_y + line_height
  - Added `valign` field to `LineOptions`, `ParagraphOptions`, `FlowOptions`
- **Added Region padding support**:
  - New `Padding` struct with zero defaults (left, right, top, bottom)
  - Region now has `padding` field for content inset
  - `remainingHeight()` accounts for vertical padding
  - New `contentWidth()` method returns width inside padding
- **Word wrapping behavior (matches fpdf2)**:
  - Regular hyphens (`-`): words stay together (no breaking)
  - Soft-hyphens (`U+00AD`): break points, replaced with visible hyphen
  - Added `findSoftHyphenBreak()` helper for soft-hyphen detection
- **Enhanced text_flow integration test**:
  - Uses `valign: .middle` for fpdf2 compatibility
  - Tests that hyphenated words like "state-of-the-art" stay together
  - Added overflow test with small region
- All 120 tests pass with 1.0pt tolerance

## What We Did (Session 2026-01-18 #16) [COMPLETE]
- Implemented Text Flow API (regions, margins, word wrapping)
  - **New types** in `platen.zig`:
    - `Color` - RGB color (black, white, red, green, blue presets)
    - `Border` - Per-side border control (`.none`, `.all` presets)
    - `Align` - Text alignment (left, center, right, justify)
    - `Margins` - Document margins (default 72pt = 1 inch)
    - `Region` - Rectangular area with cursor tracking and styling
    - `WriteResult` - Result with lines_written and overflow
    - `LineOptions`, `ParagraphOptions`, `FlowOptions` - Options structs
  - **Unit conversion helpers**:
    - Constants: `pt_per_inch` (72), `pt_per_mm`, `pt_per_cm`
    - Functions: `inches(n)`, `mm(n)`, `cm(n)`
  - **New Document methods**:
    - `setMargins(Margins)` - Set document margins
    - `getPageRegion()` - Get region respecting margins
    - `getTextWidth(str)` - Measure with current font (standard or embedded)
    - `writeLine(&region, text, opts)` - Single line into region
    - `writeParagraph(&region, text, opts)` - Word-wrapped text with overflow
    - `writeFlow(text, opts)` - Auto-pagination convenience
    - `drawRegion(&region)` - Draw region border/fill
  - **Renamed** for consistency:
    - `text()` → `write()`
    - `textAt()` → `writeAt()`
- Updated DESIGN.md with full Text API documentation
- Added 9 new unit tests (unit conversions, regions, wrapping, overflow, pagination)
- Added text_flow integration test (compares against fpdf2 reference)
- All 120 tests pass with 1.0pt tolerance (10 integration tests)

## What We Did (Session 2026-01-18 #15) [COMPLETE]
- Fixed integration test consistency for opentype_features test
  - Root issue: fpdf2's tnum/pnum/zero features not implemented in platen, causing position diffs
  - Fix: Use shaped_text() with liga+kern only for sections platen can handle
  - Disabled kerning for Inter fonts in test (fpdf2 uses text() for those sections)
  - All positions now match within 1pt tolerance
- Regenerated all reference PDFs with consistent shaping
- Total: 110 tests pass, 9 integration tests pass

## What We Did (Session 2026-01-18 #14) [COMPLETE]
- Fixed critical CFF charset SID remapping bug
  - **Symptom**: PDFs with ligatures rendered garbled text (all characters wrong)
  - **Root cause**: When subsetting CFF String INDEX, custom SIDs (≥ 391) were remapped
    to new indices, but the charset still referenced OLD SIDs from the original font
  - **Example**: Ligature glyph "ffi" had original SID 520, String INDEX subset remapped
    it to SID 391, but charset still wrote 520 → fonttools/PDF viewers couldn't find string
  - **Fix**: In `createSubsetCFF_Compact()`, remap charset SIDs using `sid_remap` when
    string subsetting is enabled (line 2239-2242 in embedded.zig)
  - **Verification**: fonttools now parses all subset CFF fonts without errors
- Debug approach:
  1. Used fonttools to detect `IndexError: list index out of range` in charset parsing
  2. Manual CFF structure analysis found max SID 521 but only 8 custom strings (391-398)
  3. Traced to charset SID writing not using the remap table
- All 110 tests pass, all 9 integration tests pass
- PDFs render correctly in Preview/qpdf

## What We Did (Session 2026-01-18 #13) [COMPLETE]
- Implemented OpenType GSUB (ligatures) and GPOS (kerning) support
  - Created `src/opentype.zig` module (~1000 lines)
    - Feature enum: `liga`, `kern`, `clig`, `dlig`, `hlig`
    - `CoverageTable`: formats 1 (glyph list) and 2 (range-based)
    - `LigatureSubst`: GSUB Lookup Type 4 (ligature substitution)
    - `ClassDef`: class definition tables for GPOS
    - `PairPosLookup`: GPOS Lookup Type 2 formats 1 and 2 (kerning)
    - `OpenTypeFeatures` struct: lazy parsing, stores lookup tables
  - Updated `embedded.zig`:
    - Added `ot_features: ?*OpenTypeFeatures` for lazy feature loading
    - Added `feature_flags: FeatureFlags` (liga=on, kern=on by default)
    - Added `ligature_codepoints` map for ToUnicode CMap support
    - `initOpenTypeFeatures()`: parses GSUB/GPOS tables on first use
    - `setFeature()`: enable/disable specific features
    - `markUnicodeCharsUsed()`: applies ligatures during glyph tracking
    - `getGlyphsForText()`: returns substituted glyph sequence
    - `getKerning()`: returns kerning value between glyph pair
    - Updated `generateCIDToUnicodeCMap()`: handles ligature → multi-codepoint mapping
  - Updated `platen.zig`:
    - Added `doc.setFeature(feature, enabled)` API
    - Added `doc.setFontFeature(font, feature, enabled)` for per-font control
    - `renderCIDTextWithKerning()`: uses TJ operator with kerning adjustments
    - Re-exported `opentype` module
- Test results:
  - 107 tests pass (7 new OpenType tests)
  - Integration tests pass with increased tolerance (5pt vs 1pt) to accommodate kerning
- Key design decisions:
  - Lazy parsing: GSUB/GPOS only parsed when features first used
  - Simple script selection: defaults to DFLT/latn scripts
  - Focus on common features: `liga` and `kern` implemented
  - Kerning uses TJ operator: `[<glyph> kern <glyph>...] TJ`
- Font-specific notes:
  - Charter: has GPOS kerning, no GSUB (kerning applied, no ligatures)
  - Inter: has `kern` and `dlig` (discretionary ligatures), no `liga`
    - Future work: support `dlig`, `calt` for Inter's features

## TODO
- [x] Support additional GSUB features (dlig, calt for fonts like Inter) - DONE
- [x] GPOS mark positioning (mark, mkmk features) - DONE
- [x] Justify alignment (word spacing adjustments in writeParagraph) - DONE
- [x] Apply calt substitutions (chain context -> nested lookup dispatch) - DONE
- [ ] Apply mark positioning offsets in PDF output (Td/Tm operators)
- [ ] Parse ALL GSUB lookups (not just feature-referenced) for complete nested lookup support

## What We Did (Session 2026-01-18 #12) [COMPLETE]
- Implemented PDF stream compression using zlib (FlateDecode filter)
  - Created `zlib.zig` module with `compress()`, `compressLevel()`, `decompress()` functions
  - Uses C zlib via @cImport (reliable, well-tested implementation)
  - zlib dependency bundled via `build.zig.zon` (allyourcodebase/zlib) - no system deps needed
- Updated `writer.zig`:
  - Added `writeStreamCompressed()` function
  - Automatically adds `/Filter /FlateDecode` when compression saves space
  - Falls back to uncompressed if compression doesn't help
- Updated `platen.zig` to use compression for:
  - Font streams (CFF and TTF data)
  - ToUnicode CMap streams
  - Page content streams
- Size comparison results (platen vs fpdf2):
  - inter_fonts: 77KB vs 95KB (**-18.8%**)
  - cid_fonts: 28KB vs 32KB (**-10.6%**)
  - all_fonts: 2.2KB vs 2.8KB (**-22.7%**)
  - hello_world: 614B vs 977B (**-37.2%**)
- All 96 tests pass, all 8 integration tests pass
- PDFs validated with qpdf, text extraction works correctly

## What We Did (Session 2026-01-18 #11) [COMPLETE]
- Implemented CFF String INDEX subsetting with SID remapping
  - New functions in `cff_subset.zig`:
    - `collectTopDictSIDs()`: extracts SIDs from Top DICT (operators 0-4, 12 0/21/22/30)
    - `buildSubsetStringIndex()`: builds subset String INDEX with SID remapping
    - `buildUpdatedTopDictWithSIDRemap()`: Top DICT builder with SID remapping
    - `remapSID()`: remaps custom SIDs (>= 391), standard SIDs pass through
    - `STANDARD_STRING_COUNT = 391`: CFF spec constant
- Fixed critical bug: FontMatrix real numbers were being corrupted
  - Root cause: `buildUpdatedTopDictWithSIDRemap` used `-1` sentinel for real numbers, then incorrectly encoded it as an integer
  - Real numbers use special CFF encoding (byte 30 + nibble-encoded digits)
  - Fix: track operand byte ranges and copy verbatim for non-SID operators
- Size improvements:
  - CFF subset: **33KB → 3.3KB** (10x improvement!)
  - Test font: 99.3% reduction from original 460KB
  - String INDEX: 29KB → 112 bytes (only font name, copyright, version)
- Key insight: Inter font charset uses only standard SIDs (< 391) for glyph names
  - Standard glyph names (space, A, B, etc.) are built into CFF spec
  - Only Top DICT strings (font name, copyright, version) use custom SIDs
  - No charset SID remapping needed for this font
- Added unit tests:
  - `remapSID standard SIDs unchanged`
  - `buildSubsetStringIndex basic`
  - `buildSubsetStringIndex empty when only standard SIDs`
  - `collectTopDictSIDs basic`
- All 93 tests pass, all 8 integration tests pass
- PDFs render correctly in Poppler/Preview

## What We Did (Session 2026-01-17 #10) [COMPLETE]
- Refactored embedded.zig to reduce code duplication and improve organization
  - Created `ttf_subset.zig` (397 lines): TTF subsetting helpers
    - `buildHmtxForGlyphs()`: builds hmtx table for glyph list
    - `buildMinimalCmap()`: minimal cmap for CID mode
    - `assembleTTF()`: assembles final TTF from tables
    - `getCompositeComponents()`, `rewriteCompositeGlyphIDs()`
    - Common utilities: `readU16`, `readI16`, `readU32`, `padTo4`, `writeTableEntry`
  - Created `cff_subset.zig` (622 lines): CFF subsetting helpers
    - `CFFIndex` struct and `parseCFFIndex()`
    - DICT parsing: `parseCFFTopDictForCharStrings()`, `parseCFFTopDictForPrivate()`
    - `getCharsetSID()`, `buildUpdatedTopDict()`, `buildPrivateDictWithoutSubrs()`
    - `desubroutinizeCharString()`, `getSubrBias()`, `encodeCFFInt()`
  - Updated `embedded.zig`: 3416 → 2749 lines (20% reduction)
    - Imports helper functions from new modules
    - Removed ~660 lines of duplicate code
- All tests pass (including new tests in subsetting modules)
- File organization:
  - `embedded.zig`: EmbeddedFont struct and public API
  - `ttf_subset.zig`: TTF subsetting utilities
  - `cff_subset.zig`: CFF subsetting utilities

## What We Did (Session 2026-01-17 #9)
- Added comprehensive unit tests for new subsetting functionality
  - `getSubrBias()`: boundary tests at 1240, 33900 thresholds
  - `parseCFFIndex()`: empty, single, multiple entry tests
  - `desubroutinizeCharString()`: subr inlining, return stripping, operand removal
  - `buildPrivateDictWithoutSubrs()`: Subrs operator stripping
  - `rewriteCompositeGlyphIDs()`: single/multiple components, various flag combinations
  - Compact TTF subsetting: valid output, glyph ID remapping, size reduction
  - CFF subsetting: valid output, desubroutinization, glyph remapping
- Added CID font integration tests (TTF/OTF with identity encoding, mixed fonts)
- Fixed bugs found during testing:
  - `desubroutinizeCharString()` now removes operand bytes when inlining callsubr/callgsubr
  - `desubroutinizeCharString()` only adds endchar at depth 0 (not in subroutines)
- Test count: 63 test functions (26 embedded, 27 platen, 2 ttf, 8 integration)
- All tests pass

## What We Did (Session 2026-01-17 #8)
- Implemented compact TTF subsetting with glyph ID remapping
  - Added `createSubsetTTF_Compact` function in embedded.zig
  - Builds sorted glyph_list and gid_remap (same pattern as CFF compact)
  - Creates compact glyf/loca/hmtx tables with only used glyphs
  - Added `rewriteCompositeGlyphIDs()` to update component references in composite glyphs
- Updated `generateSubset` to use compact TTF for CID (identity) mode
- Implemented CFF desubroutinization
  - Added `desubroutinizeCharString()` to inline callsubr/callgsubr operators
  - Parses CharString Type 2 bytecode, tracks operand stack for subr indices
  - Handles subroutine biasing (107/1131/32768 depending on count)
  - Removes Global/Local Subrs from output CFF
  - Added `buildPrivateDictWithoutSubrs()` to strip Subrs operator
- CFF font size reduced: ~60KB → ~33KB per font (with full String INDEX)
- File sizes:
  - inter_fonts: 446KB → 241KB (46% reduction)
  - TTF fonts: ~9-11KB each (compact, remapped)
  - CFF fonts: ~33KB each (desubroutinized, still full String INDEX)
  - fpdf2 reference: 95KB total (~4-8KB per font)
- Attempted String INDEX subsetting but had rendering issues
  - SID remapping logic appeared correct but caused macOS rendering failures
  - Deferred for now; full String INDEX works correctly
- All 8 integration tests pass

## What We Did (Session 2026-01-17 #7)
- Implemented compact CFF subsetting with glyph ID remapping
  - Lazy content generation: store commands during text(), render after subsetting
  - Added `gid_remap` hash map for original GID → new compact GID mapping
  - CharStrings INDEX contains only used glyphs (not sparse)
  - 87% size reduction (460KB → 58KB for Inter OTF)
- Fixed macOS Preview/CoreGraphics rendering issues
  - Must preserve original charset SIDs (macOS uses SIDs for glyph lookup)
  - Added `getCharsetSID()` to extract original SID for each glyph
  - Must remove Encoding operator from Top DICT (old offset becomes invalid)
- Analyzed subsetting size differences vs fpdf2
  - fpdf2 inter_fonts: 95KB, platen: 446KB (4.7x larger)
  - CFF: fpdf2 ~6-7KB each, platen ~60-70KB (String INDEX + Global Subrs not subsetted)
  - TTF: fpdf2 ~12-41KB, platen ~30-60KB (sparse tables due to preserved glyph IDs)
  - To match fpdf2: need TTF glyph ID remapping + CFF String/Subrs subsetting

## What We Did (Session 2026-01-17 #6)
- Implemented CFF subsetting for OTF fonts
  - Previous attempt failed due to sparse CharStrings with empty `endchar` placeholders
  - Root cause: empty charstrings caused garbled rendering
  - Solution: copy ALL original CharStrings up to max_gid (no sparse data)
  - Also fixed charset size calculation to match new glyph count
- CFF subsetting now preserves glyph IDs for Identity CID-to-GID mapping
  - Includes all charstrings from 0 to max_gid
  - Truncates charset to match new glyph count
  - Preserves Global/Local Subrs unchanged
- Size reduction: ~31% for typical text (460KB → 317KB for Inter OTF)
  - Less optimal than TTF subsetting due to preserved glyph ID range
  - For better reduction, would need glyph ID remapping (complex)
- Added `cff-test` CLI command for testing CFF subsetting
- All integration tests pass

## What We Did (Session 2026-01-17 #5)
- Fixed composite glyph handling in CID-aware TTF subsetting
  - Composite glyphs (like 'i', 'j') reference other glyphs (e.g., glyph 2705 for dot)
  - Added `getCompositeComponents()` to recursively find all referenced glyphs
  - Fixes missing characters that were cut off by max_gid
- Attempted CFF subsetting but reverted
  - CharStrings copy correctly, Global/Local Subrs included
  - Rendering still fails - likely due to subroutine biasing or other CFF complexity
  - Disabled for now; OTF fonts embed full CFF table (~600KB each)
- All 8 integration tests pass

## What We Did (Session 2026-01-17 #4 continued)
- Implemented CID-aware TTF subsetting (`createSubsetTTF_CID`)
  - Preserves original glyph IDs (no remapping) for Identity CID-to-GID mapping
  - Creates sparse loca/hmtx tables with entries for all glyphs 0..max_gid
  - Only includes actual glyph data for used glyphs
  - File size reduced from 3.5MB to 1.9MB for Inter fonts test

## What We Did (Session 2026-01-17 #4)
- Implemented CID fonts (Type0/CIDFontType2) for full Unicode support
  - Added `FontEncoding` enum (`.win_ansi`, `.identity`)
  - Added CID tracking: `cid_used_glyphs`, `cid_glyph_widths` hash maps
  - Added `markUnicodeCharsUsed()`, `generateCIDToUnicodeCMap()`, `generateWidthArray()`
  - Type0 font structure with Identity-H encoding, CIDSystemInfo
  - Hex string output `<XXXX>` for glyph IDs in CID mode
- Implemented OTF (CFF) font support
  - Added `isCFF()` and `isTrueType()` methods to ttf.zig
  - CFF fonts use CIDFontType0 + FontFile3 with Subtype CIDFontType0C
  - Extract CFF table data (not full OTF wrapper) for embedding
- Fixed font name decoding (UTF-16BE)
  - `decodeFontName()` was returning dangling pointer to stack array
  - Fixed with static buffer
- Fixed searchRange overflow in cmap generation for small segment counts
- Added Inter font integration test (TTF and OTF variants)
- Skip subsetting for CID mode (glyph ID remapping breaks Identity mapping)
- 8 integration tests now pass

## What We Did (Session 2026-01-17 #3)
- Fixed extended Latin character rendering in subset fonts
  - Root cause: subset cmap only had Format 0 (MacRoman), but PDF viewers with WinAnsiEncoding need Format 4 (Windows Unicode BMP)
  - Added Format 4 cmap generation to `createSubsetTTF()` in embedded.zig
  - Now generates both Format 0 and Format 4 cmap tables
- Added comprehensive Unicode symbol coverage to embedded fonts test
  - More Latin: Ññ Øø ß Ææ Ðð Þþ ¿¡
  - Currency/Math: £ ¥ ¢ ƒ ± × ÷ ° ² ³ ¹ ¼ ½ ¾ µ
  - Symbols: § ¶ † ‡ • ¦ ¬ · ª º
- Fixed font metric rounding to match fpdf2
  - Was using truncation (`@intFromFloat`), now uses rounding (`@round`)
  - Fixes 1-unit width difference in monospace fonts (599 vs 600)
- Investigated VeraPDF for PDF validation
  - Useful for PDF/A conformance but wouldn't catch cmap format issues
  - Visual/pixel comparison would be needed for rendering correctness

## What We Did (Session 2026-01-17 #2)
- Implemented ToUnicode CMap for embedded fonts
  - Added `generateToUnicodeCMap()` in embedded.zig
  - Creates CMap stream mapping WinAnsi bytes → Unicode codepoints
  - Format: single-byte codespace `<00> <FF>`, bfchar entries `<XX> <XXXX>`
- Updated embedded font structure: now 4 objects per font (was 3)
  - Font dict, FontDescriptor, FontFile2, ToUnicode stream
  - Fixed resource dict object ID calculation (`idx * 4`)
- Result: copy/paste and text extraction now work correctly
- Created integration test suite
  - New `src/integration_tests.zig` with shared test cases
  - 6 integration tests: minimal, hello_world, multi_font, all_fonts, multi_page, embedded_fonts
  - Tests generate PDFs and compare against reference files
  - CLI now imports shared test cases (removed code duplication)
  - Tests run automatically with `zig build test`
- All 56 tests pass (46 unit + 6 integration + 4 testing utilities)

## What We Did (Session 2026-01-17)
- Implemented TrueType font subsetting
  - Added `used_chars` tracking in EmbeddedFont
  - `markCharsUsed()` called when text is written with embedded fonts
  - `generateSubset()` creates minimal TTF with only used glyphs
  - `getFontData()` returns subset if available, else original
- Subset TTF generation:
  - Builds new glyf/loca tables with only needed glyphs
  - Creates format 0 cmap (256-byte lookup for WinAnsi)
  - Generates new hmtx, maxp, hhea tables
  - Copies head, name, post tables
- Results: ~48% file size reduction (51KB vs 99KB for test case)
- All 6 reference tests still pass
- Added unit tests for subsetting
- Investigated stream compression (std.compress.flate)
  - Zig 0.15.2's Compress struct has incomplete implementation (@panic("TODO"))
  - Simple/HuffmanEncoder available but has internal bugs
  - Deferred compression until std lib stabilizes or use C zlib

## What We Did (Session 2026-01-16 #6)
- Fixed dangling pointer bug in embedded font resource names
  - Stack buffer `name_buf` went out of scope but Dict still held reference
  - Added static `embedded_font_names` array with "E1"-"E32" string literals
  - Added `embeddedFontResourceName(idx)` function
- Implemented PDF string escaping for special characters
  - Added `ContentWriter.appendEscaped()` method
  - Escapes `\`, `(`, `)` as required by PDF spec
  - Removed TODO `escapePdfString` function
- Fixed embedded_fonts test paragraph line breaks to match fpdf2
- Added font set comparison to semantic PDF comparison
  - Uses qpdf JSON to extract fonts per page
  - Compares normalized font names (removes subset prefix, "Regular" suffix)
  - Catches bugs where wrong font is used or font is missing
- Fixed embedded font BaseFont naming
  - Was using family name (e.g., "Courier"), now uses PostScript name (e.g., "CourierPrime-Bold")
  - Added `ttf.Font.getPostScriptName()` and `getFullName()` methods
- All 6 reference tests pass including embedded_fonts with font verification
- All unit tests pass

## What We Did (Session 2026-01-16 #5)
- Implemented TrueType font embedding in PDFs
- Created `src/embedded.zig` - EmbeddedFont type, WinAnsiEncoding, FontFlags
- Added `Document.loadFont(path)` - loads TTF from file
- Added `Document.setEmbeddedFont(font, size)` - use embedded font for text
- Full PDF output with embedded fonts: Font dict, FontDescriptor, FontFile2 stream
- Widths array generated from TTF cmap/hmtx tables, scaled to 1000 units
- Added extensive tests (13 new tests) for font embedding
- Added `platen embed-test [font] [output]` CLI command
- Tested with Courier Prime (monospace) and Charter (proportional)
- Added qpdf-based structural comparison (like fpdf2's assert_pdf_equal)
- Updated testing.zig with CompareMode (structural/semantic/auto)
- CLI: `platen check-refs --structural` or `--semantic`
- Structural = qpdf QDF normalization, good for regression testing
- Semantic = pdftotext text+positions, good for cross-implementation comparison
- All 5 reference tests still pass

## What We Did (Session 2026-01-16 #4)
- Created TTF parser (`src/ttf.zig`) - parses TrueType and OpenType fonts
- Parses tables: head, hhea, hmtx, maxp, cmap, name
- Supports cmap format 4 (BMP) and format 12 (full Unicode)
- Added `platen font-info` CLI command to inspect fonts
- Tested with all test fonts: Courier Prime, Charter, Satoshi, Inter Variable
- Updated test report to show both expected/actual PDFs side-by-side
- Report uses relative paths, PDFs copied to output folder

## What We Did (Session 2026-01-16 #3)
- Added font metrics for all 14 Base fonts (from fpdf2/Adobe AFM)
- Created `src/metrics.zig` with TextMetrics, TextStyle types
- Added character spacing (char_spacing) and line height (line_height) configuration
- Implemented Document.measureText() and Document.measureTextWidth()
- Added PDF Tc operator for character spacing in text output
- All reference tests still pass

## What We Did (Session 2026-01-16 #2)
- Designed Flow/Region API for layout control
- Chose measure-first approach over checkpoint/restore (avoids infinite loops)
- Core primitives: measureText, measureWrappedText, writeFitting
- Region type tracks position within a bounded area
- User code controls flow decisions (page breaks, columns, etc.)
- Added API design to DESIGN.md

## What We Did (Session 2026-01-16)
- Implemented semantic PDF comparison (text + positions, not structure)
- Created `scripts/compare_pdfs.py` - extracts text with bounding boxes via pdftotext
- Created `scripts/gen_references.py` - generates baselines using fpdf2 (auto-installs in .venv/)
- Reference PDFs now generated by fpdf2 (known-good implementation)
- Comparison tolerates 5pt position difference, different coordinate systems
- All 5 test cases pass semantic comparison

## What We Did (Session 2026-01-15)
- Investigated fpdf2 testing approach: qpdf-based structural comparison
- Created `testing.zig` module with PDF comparison utilities
- Installed qpdf for PDF normalization
- Added CLI commands: `gen-refs`, `check-refs`
- Created 5 reference test cases: minimal, hello_world, multi_font, all_fonts, multi_page
- Reference PDFs stored in `test/reference/`

## What We Did (Session 2026-01-14 #2)
- Added text rendering with PDF content stream operators (BT, ET, Tf, Td, Tj)
- Implemented all 14 standard PDF fonts (Helvetica, Times, Courier, Symbol, ZapfDingbats)
- Created `fonts.zig` module with StandardFont enum and font utilities
- Added Document methods: setFont, setXY, text, textAt, getX, getY
- Font objects written to PDF with proper resource references in pages
- CLI `text` command generates PDFs with multiple fonts/styles
- Ported tests from fpdf2: page format, positioning, error handling, font tests

## Files of Interest
- `src/platen.zig` - Main library facade, re-exports from document.zig
- `src/document.zig` - Document struct, text rendering, image/SVG drawing, PDF output
- `src/images.zig` - JPEG/PNG parsing and image handling
- `src/svg.zig` - SVG parsing and Form XObject generation
- `src/xml.zig` - Minimal XML parser for SVG
- `src/embedded.zig` - EmbeddedFont type, WinAnsiEncoding, font embedding logic
- `src/opentype.zig` - OpenType GSUB/GPOS parsing for ligatures and kerning
- `src/ttf_subset.zig` - TTF subsetting helpers (hmtx, cmap, assembly, composite glyphs)
- `src/cff_subset.zig` - CFF subsetting helpers (INDEX parsing, DICT building, desubroutinization)
- `src/fonts.zig` - Standard PDF fonts (Base 14)
- `src/metrics.zig` - Font metrics, TextMetrics, TextStyle, measureText
- `src/ttf.zig` - TrueType/OpenType font parser
- `src/zlib.zig` - FlateDecode compression using C zlib
- `src/testing.zig` - PDF comparison utilities (calls Python comparator)
- `src/objects.zig` - PDF object types
- `src/writer.zig` - PDF serialization
- `src/cli.zig` - Command line tool (font-info, embed-test, check-refs, etc.)
- `scripts/gen_references.py` - Generate baseline PDFs using fpdf2
- `scripts/compare_pdfs.py` - Semantic PDF comparison
- `test/reference/` - Reference PDFs (generated by fpdf2)
- `test/fonts/` - Test fonts (Courier Prime, Charter, Satoshi, Inter)

## Open Issues
- None currently

## Completed Features

### Graphics
- ✓ JPEG/PNG embedding with alpha support
- ✓ SVG embedding (shapes, paths, text, gradients, use/defs)
- ✓ Basic shapes: line, rect, circle, ellipse, polygon
- ✓ Path API: moveTo, lineTo, curveTo, quadTo, closePath
- ✓ Gradients: linear and radial
- ✓ Styling: colors, line width, dash patterns, caps, joins

### Text
- ✓ Standard fonts (Base 14)
- ✓ TrueType/OpenType font embedding with subsetting
- ✓ CID fonts for full Unicode support
- ✓ OpenType features: liga, kern, mark, mkmk, calt, dlig, tnum, pnum, frac, zero, case, ss01
- ✓ Text flow: regions, word wrapping, justify, optimal line breaking

### Navigation
- ✓ Document outline: addOutlineItem() with nesting support
- ✓ Page labels: setPageLabel() with styles (decimal, roman, alpha), prefix, start number
- ✓ Internal links: addLink() for TOC-style navigation
- ✓ External links: addExternalLink() for URLs

### Possible Future Enhancements
- PDF embedding (parse external PDF, embed as Form XObject)
- Hyphenation dictionary support
