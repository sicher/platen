# platen Context

## Current Focus
**0.13.0 released (2026-10-22)**: complete GSUB engine checked against
HarfBuzz (ccmp/locl/rlig/clig on by default), default ignorables,
variation sequences, COLRv1 gradient alpha, continuing styled text,
Unicode composition, pixel check for platen-made references, and a batch
of write()/decoration fixes.
Tags on main, CHANGELOG.md, forge releases with notes. 1.0.0 still held by
user decision. Zig **0.17**, zero dependencies, 569 tests, silent clean
runs; PDF/A output veraPDF-validated locally (the test skips in CI).
Since 0.13.0 on dev: ochre (color parsing) vendored in `src/ochre/` by
`scripts/vendor-ochre vX.Y.Z` (never edit those files; update ochre and
re-run). SVG fill/stroke and `Color.hex` parse through it; `fromName`'s
table is built from the 148 constants, checked against ochre's. Next for
ochre in platen: perceptual gradients via `ochre.ramp(...).stops()`. The
`examples/showcase_*.pdf` files are still from 0.12.0.
**SVG gradients (sessions #33-34)**: steps 1-4 committed (7bf8e25: parse,
`url()` paint + fallback, shading patterns, units/gradientTransform/focal);
step 5 `href` inheritance committed 2026-11-18. Next: 6 stop-opacity,
7 reflect/repeat; open question for the user: follow resvg's fallback on
degenerate gradients? (TODO.md).

**Shaping for courier (session #35, pushed)**: courier (FD13 clone, peer
session) asked for (1) every face of a family, (2a) pure shaping, (2c)
glyphs by ID, (2b) Devanagari. Done: 16fab28 `listSystemFontFaces`,
047c70f `shapeText` + `drawGlyphs` (HarfBuzz-checked; DESIGN "Pure
shaping"); then (local until pushed) 2f3f44d GPOS engine, 1be2e09
normalization (decompose, space fallback), 23d7421 fallback mark
positioning - shapeText now matches HarfBuzz's default shaper on every
reference (352 runs, GposTest.ttf synthetic font); 341807b Devanagari
Indic shaper (port of HarfBuzz 12.3.0; source in .tools/ref, fetched by
the user); 56e0353 CID-keyed CFF subsetting (reveal's Hangul bug);
d97192c per-glyph source text (ShapedGlyph.text_start/end,
PlacedGlyph.source -> exact ToUnicode, courier's copy bug); 6995400
`.monospace` on UAX #29 grapheme clusters, shaped, 1-2 cells
(TextStyle.fallback_cells override for reveal). All pushed; courier and
reveal notified. Then b0d4e28 fallback_max_em (reveal, 0.88 in use);
b6f5d7a write()/measure on the shaping engine (shapeRun,
renderShapedRun; 11 platen references regenerated after checking each
diff: same glyphs, TJ adjustments < 1/1000 em); 6c612ee caches (GPOS
pair records, word widths, glyphs_done/cps_done): perf +4% total vs
before (Unicode/marks +27% is GPOS mark work the old path skipped);
43b6fdc perf_test --only=SECTION. 2026-11-18: c4050c1 system font
lookup reads the name tables of non-ASCII file names (Hiragino); 0d893a1
Hangul shaper (hangul.zig, HarfBuzz-checked: synthetic HangulTest.ttf +
Apple SD Gothic Neo, 0 differences); 59c1bd0 GposKerning (courier: GPOS
pair kerning without shaping, HarfBuzz-checked); 393982c old glyph path
removed (-1650 lines; text sections 5-10% faster; copy text keeps a cmap-14
selector - user's choice; FontFace.warmup now a no-op). All pushed. Next:
synthetic Indic font for CI; Latin langsys (latn before DFLT, TODO); maybe
ActualText for logical-order copy text if courier/reveal ask.
Note: `-Dtest-filter` skips document.zig's own tests (passes silently).

**Branch model (devkit): work on `dev`.** `main` moves only via
`.tools/devkit/devkit release X.Y.Z` (merge dev, date the notes, set the
version in build.zig.zon, test, tag) or `devkit promote` (run on main); then push main
and the tag, wait for CI, `devkit publish` (on main), and `devkit
sync-dev` on dev. Never commit to main directly (config bootstrap for
.devkit.conf is the one exception devkit's README prescribes).

**Release notes are required:** write them under `## Unreleased` in
CHANGELOG.md on dev as work lands; `devkit release` refuses without them.

## What's Next
- TODO.md roadmap: text render modes (`Tr`), Form XObject stamps, the
  opt-in 16-bit -> 8-bit flag for PDF/A-1b, splitting document.zig
  (~4,400 lines), parallel page rendering, metadata encryption; post-1.0:
  bidi/joining scripts, CJK line breaking, PDF/A-2a/3a, forms/signatures.
- Fuzzing: run with its own cache dir - `zig build --cache-dir <dir> test
  --fuzz -Doptimize=ReleaseSafe` - concurrent builds in the shared cache
  delete its tmp/ and kill the run; the `zig build` web server stays
  alive after a failure, so stop it. Last 1-hour run: no crashes.
- CI: Forgejo Actions on runner label zig-arm64 (shared with lamp, whose
  long jobs can hold the queue). API: `/api/v1/repos/urverk/platen/
  actions/runs` (+ `/{id}/logs` as zip), token URVERK_TOKEN or keychain
  `urverk-token`. No re-run API: re-run in the web UI. Runner has
  poppler + qpdf; veraPDF stays off it (user decision).
- Runner Zig cache grows unbounded (Zig never evicts). Decided: keep CI
  warm (cache is content-keyed; cold runs add nothing); later, pin
  ZIG_LOCAL/GLOBAL_CACHE_DIR on the runner host + a scheduled wipe when
  idle. Deferred by the user.
- Other urverk projects need the 0.17 migration: DESIGN.md "Zig
  Compatibility Notes" is the checklist (watch the signed `{d:` `+`).

## What We Did (Session 2026-11-16 #35 - courier: faces, shapeText, drawGlyphs)
- `system_fonts.listFamily` (one walker shared with find), CLI `find-font --all`.
- `shapeText`: decode.zig (offsets), local GSUB Shaper, HarfBuzz clusters
  (unicode_props, generated from UCD 16), positions = write()'s algorithm.
  Gaps vs HarfBuzz: no GPOS engine (lookup flags, GDEF mark zeroing,
  fallback marks) - position_gaps.txt.
- `drawGlyphs` + `.glyphs` page command; ToUnicode per cluster.
- Fixed: ligature-only fonts embedded whole (607d9da); fresh clone failed
  the svg probe test once (c6eb1c0, test/output missing).
- Gotcha: `zig fmt src/*.zig` rewrites other files (0.17 builtins, HEAD's
  unformatted lines) - format only the files you changed.
- Gotcha: a passing `zig build test` is cached by binary hash; after
  regenerating only reference files, run the test binary directly. A
  filter matching nothing still reports "1 test" (the root test block).
- Gotcha: `zig build test` does not rebuild zig-out/bin/platen - run
  `zig build` before CLI comparisons (stale-binary false alarms).
- Scratch HarfBuzz compare: hbcmp.py <font> <texts> [guess|deva] and
  hbtrace.py (message-func stage dump) in the session scratchpad; morx fonts
  must be compared without morx (fontTools del t['morx']).
- Mutating GSUB/GPOS/GDEF found a u16 overflow in CoverageTable (fixed);
  keep that test at 96 rounds (5000 for a one-off probe).

## What We Did (Session 2026-11-07 #34 - SVG gradient href)
- `resolveHrefs` after parsing: Chrome's rule (first in chain wins, stops from
  the first with any, borrowed), capped at 32 hops (ends cycles too).
- resvg 0.5 is wrong on three href cases (inherited gradientTransform, linear
  coords through a radial, hangs on chain-into-cycle): unit tests only; case
  `10_href.svg` probes the rest (128 probes now); reference PDF has 10 pages.
- Found: resvg uses the fallback color for stopless / zero-box gradients,
  paints last stop for r<0, ignores a singular transform - platen differs.

## What We Did (Session 2026-11-03 #33 - SVG gradients 1-4)
- Found the docs claimed SVG gradients that did not exist (`url(#g)` was an
  unknown color: black). Plan agreed with the user: 1 parse, 2 url() +
  fallback, 3 render, 4 units/transform/focal; then 5 href, 6 stop-opacity,
  7 reflect/repeat.
- New `src/svg_gradient.zig` (types, parsers, `prepare`, `writePattern`) and
  `src/svg_path.zig` (path walk into a sink, arcs, tight `Bounds`; renderPath
  refactored onto it, output byte-identical). `Style.fill/stroke` are `Paint`.
  `toPdfContent` gained a `patterns` out-list (document writes `/Pattern`,
  color_fonts rejects glyphs needing it). Design notes in DESIGN.md "SVG
  gradients".
- **Oracle decision (user)**: resvg (`resvg-py` installed in .venv) at probe
  points, +-3 levels, probes only where 5x5 spread <= 24 (generator enforces);
  plus exact pixel check vs platen-made `test/reference/svg_gradients.pdf`.
  fpdf2 and MuPDF cannot render SVG gradients. Near a radial focal point
  pdftoppm/MuPDF approximate (resvg verified exact by hand); MuPDF has a
  seam on the focal-center axis.
- CLI: `platen svg <in.svg> [out.pdf]`. Fixed on the way: line/polyline with
  `stroke="none"` were stroked. Found (TODO.md): polyline never filled,
  S-after-Q reflection, 2-decimal path coordinates, document gradients assume
  stops at 0 and 1.

## What We Did (Session 2026-10-22 #32 - GSUB engine)
- **New `src/gsub.zig`** replaces the per-feature GSUB code in
  opentype.zig (-1,800 lines there): every lookup type and format, lookup
  flags via GDEF, HarfBuzz order and context semantics, clusters.
  `ccmp`, `locl`, `rlig`, `clig` on by default (HarfBuzz's defaults;
  clig by user decision).
- **Differential test against HarfBuzz** (shaping_test.zig + committed
  reference + synthetic GsubTest.ttf). It found old-engine bugs: Inter
  `<->`, `case`+`tnum`, Satoshi `frac`; and a mark-ligature case that
  needed HarfBuzz's lig_id/lig_comp bookkeeping.
- **CFF subsets dropped contextual variants** (glyph drawn as .notdef) -
  fixed with a failing test first.
- **ToUnicode from clusters**; multi-glyph clusters map glyph by glyph
  when the decomposition fits (test: ccmp text extracts as typed, NFD for
  precomposed input that ccmp splits).
- **Default ignorables** (U+FE0F, ZWJ, soft hyphen...) skipped in
  matching and removed after shaping, HarfBuzz as oracle; color-font
  ToUnicode now maps emoji ligatures to their sequence (was U+FFFD).
- **Performance:** first version was 25% slower in the shared-face
  invoice bench (more work: ccmp now runs). Profiled with `sample`; fixes
  in DESIGN.md "GSUB engine". Now on par (shared, 8 threads) and +20%
  plain. Tools added: `-Dtest-filter`, CLI `shape`.
- **COLRv1 gradient stop alpha:** constant -> `/ca`, varying -> a
  luminosity soft mask (gray copy of the shading in a form XObject,
  `/Gm{n}`). Fixed the grey rainbow flag; ~2,000 Noto glyphs affected.
  Checked by eye (no COLRv1 reference renderer in .venv).
- **Pixel check for platen-generated references** (`--compare-render`).
  It found: `color_v1_gradient` reference broken (empty-outline clip
  filled the page - fixed); `text_style` decorations changed by the
  2026-01 line batching (f8663cb) - mid-line spaces decorated is CSS, the
  wrap space was not (fixed); pixel_font FontBBox empty (fixed).
  `clig` on by default. cmap format 14 variation sequences (GsubTest
  entries + HarfBuzz reference).
- Pixel check covers all 19 platen-made references (any test without an
  fpdf2 generator in gen_references.py, not just EXCLUDED_TESTS). A
  drifted reference is looked at before regenerating - svg_embedding's
  had wrong stroke widths. gentium_diacritics gained a composition /
  dotless i/j section (decomposed vs precomposed, ccmp, Inter).
- Fixed: a write() call's decorated trailing space now hangs when the
  next write() wraps at once (`Document.hanging_space`); SVG stroke
  widths keep four decimals.
- Fixed: write() dropped the words before a double space (and a call's
  leading space mid-line) since f8663cb; found by text_style's new
  decoration variations (space inside / outside the decorated text).
- Next: TODO.md roadmap (Tr, Form XObject stamps, split document.zig).

## What We Did (Session 2026-10-21 #31 - showcase, text flow, composition)
- README gallery: `zig build showcase` (src/showcase.zig) writes one PDF
  per page (examples/showcase_*.pdf); `scripts/render-readme-images`
  rasterizes them + the invoice into docs/images. Gallery images link to
  the PDFs (Forgejo renders them). HTML <a href> in README is NOT
  rewritten by Forgejo (404) - use Markdown links inside table cells
  (blank line after <td>). Check rendering via POST /api/v1/markdown.
- Building the showcase found and fixed (each with a failing test first):
  justified CID text ragged (Tw ignored for Identity-H), Tc leaking into
  later runs, gradient stops borrowed, unused fonts embedded whole (25 MB),
  char_spacing ignored in the Tm mark path, Tw on CID runs splitting
  ligatures at CID 0x0020 in poppler, measure_only drawing broken words.
- `platen.Path` exported.
- Unicode composition before shaping (HarfBuzz-style), `naïve` etc.
- `writeStyled` continuation: `resume_at` / `ParagraphOptions.start`
  (`TextPosition { word, offset }`), mid-word for broken words.
- Decisions: continuation as one struct (user); lines are the unit, a
  region may end mid-word (TeX/CSS model, not "move the whole word");
  `overflow` kept unchanged; ToUnicode of composed glyphs = typed text.

## What We Did (Session 2026-10-15 #30 - dates and file IDs)
- PDF/A dates: one clock reading per `output()` (`OutputDates`); explicit
  /Info dates converted to ISO 8601 for XMP; invalid explicit date under
  PDF/A -> `error.InvalidDate`. Had broken `devkit promote` (veraPDF 6.7.3).
- File IDs (trailer /ID, XMP Document/InstanceID as v4 UUIDs) now come
  from `doc.rng` (`FileIds`), not the clock. Decision: rng + explicit
  dates = byte-reproducible PDF/A and encrypted output; no clock override.
- Legacy `kern` table (`kern_table.zig`, format 0, MS + Apple headers),
  used only when GPOS has no kern lookups (HarfBuzz rule). Tested with
  Charter-derived fixtures (scripts/gen_kern_fonts.py) and the unmodified
  Bitstream Vera Sans 1.10; `font-info` shows kerning sources.
- Kerning API for fdxview: dropped. `measureStyled` already measures
  exactly what renders; fdxview should use it instead of parsing `kern`.
- devkit: releasing right after a promote amended the pushed promote
  merge (non-FF). Already fixed upstream (devkit 5ca517b, 2026-10-06);
  our .tools/devkit clone was stale. `git -C .tools/devkit pull` before
  releasing.
- Open: reference comparator can't detect blank glyphs (needs a render
  check).

## What We Did (Session 2026-10-13 #29 - font collections, system fonts)
- **Requested by fdxview** (a peer session; fdxview uses platen as a path
  dependency): .ttc/.otc support (`font_collection.zig`) and system font
  lookup (`system_fonts.zig`) that returns standalone sfnt bytes;
  `Document.loadFontFromCollection`; CLI font-faces/extract-face/
  find-font. Commit 13b2ec4 on dev (not pushed); API sent to fdxview,
  which will drop its own src/sysfonts.zig. See DESIGN.md.
- **Fixed** (47b4a06): `.win_ansi` TrueType subsets dropped composite
  glyphs (Inter i/j/:/; came out blank).
- **Open:** the reference comparator never caught that bug. The semantic
  mode (pdftotext) can't see blank glyphs, so a render/pixel check is
  needed. Kerning (kern format 0 / GPOS pairs) exposed for measuring is
  fdxview's "nice to have", not started.

## Older sessions (pruned 2026-10-22)
Session #27 (2026-10-04/05): Zig 0.17 migration, number contract
(error.InvalidNumber), parser overflow audit + fuzzing, PngSuite pixel
truth, veraPDF fixes. Decisions then: invalid input is an error, never a
silent clamp; PngSuite (not fpdf2) is the pixel authority for PNG; user
reviews reference/actual PDFs visually, so keep references
self-explaining; releases via devkit with notes, veraPDF not on CI.
Sessions #1-#26b (2026-01 .. 2026-07-21): bootstrap, text/graphics/
images/SVG, OpenType shaping, color fonts, PDF/A, fuzzing, the
zapdf->platen rename, invoice benchmark and perf work, parallel
compression, transforms, API audits, SharedFont -> FontFace with
ownership guards (Foreign* errors). Details in git history and DESIGN.md.
