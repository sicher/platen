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
re-run). SVG fill/stroke and `Color.hex` parse through it. Next for ochre
in platen: the 148 named constants and `fromName`, then perceptual
gradients via `ochre.ramp(...).stops()`. Found: DESIGN/README list SVG
gradients, but platen has no `linearGradient`/`stop-color` code; the
`examples/showcase_*.pdf` files are still from 0.12.0.

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

## What We Did (Session 2026-10-06 #28 - releases, devkit, spans)
- **Releases 0.10.0, 0.10.1, 0.11.0.** Adopted the devkit main/dev model;
  version single-sourced from build.zig.zon (build option -> version.zig).
- **devkit** (separate repo, pushed 6fe0aba): opt-in `CHANGELOG=` -
  `release` requires and dates `## Unreleased`, `publish` uses it as the
  release text (assets optional). Opt-in, so other repos are unaffected.
- **Package size:** `.paths` in build.zig.zon + `.gitattributes`
  export-ignore: dependents fetch 0.4 MB (was 45) and cache 1.8 MB.
- **CI first ran** (platen's workflow had never been pushed): runner
  lacked poppler/qpdf -> installed; workflow prints `--summary all`.
- **Test infrastructure:** the comparator compared fonts only when both
  pages had some and read qpdf failures as "no fonts" - fixed, with its
  own tests; test/ fixtures and comparator scripts are declared inputs of
  the test run, so a changed reference re-runs (a corrupted one used to
  pass from cache).
- **StyledText spans:** fields are optional overrides of the base style
  (writeBlock/writeStyled ignored the base color/decoration - fixed), and
  spans take bold/italic, resolved through the font family, with widths
  measured per span.
- **Benchmarks re-measured** (M1 Pro, medians of 3): 70 ms / 54 ms for
  110 pages; invoices 2,060 / 3,350 shared / 9,500 at 8 threads / ~17,700
  at 8 threads shared (README said ~19,000).

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
