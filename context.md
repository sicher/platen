# platen Context

## Current Focus
**0.11.0 released (2026-10-06)** - after 0.10.0 and 0.10.1 the same day.
Tags on main, CHANGELOG.md, forge releases with notes. 1.0.0 still held by
user decision. Zig **0.17**, zero dependencies, 535 tests, silent clean
runs; PDF/A output veraPDF-validated locally (the test skips in CI).

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

## What We Did (Session 2026-10-15 #30 - dates and file IDs)
- PDF/A dates: one clock reading per `output()` (`OutputDates`); explicit
  /Info dates converted to ISO 8601 for XMP; invalid explicit date under
  PDF/A -> `error.InvalidDate`. Had broken `devkit promote` (veraPDF 6.7.3).
- File IDs (trailer /ID, XMP Document/InstanceID as v4 UUIDs) now come
  from `doc.rng` (`FileIds`), not the clock. Decision: rng + explicit
  dates = byte-reproducible PDF/A and encrypted output; no clock override.
- Both promoted and pushed (main 59e86e2, still 0.11.0). Repo description
  set on the forge.
- Open: reference comparator can't detect blank glyphs (needs a render
  check); kerning API for fdxview not started (not urgent).

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

## What We Did (Session 2026-10-04/05 #27 - Zig 0.17, hardening, PngSuite)
- Zig 0.17 migration; README compile-checked.
- Number contract (error.InvalidNumber, ±1e6) at every Document entry.
- Parser overflow audit (~50 sites) + fuzzing; CFF desubroutinization
  bounded; PNG: CRC, tRNS, 16-bit alpha, Adam7 (all 161 PngSuite images
  match PngSuite's pixel truth); PDF/A: FontNotEmbedded, image rules,
  veraPDF found a 0.17 date regression and missing link /F flags.
- Bugs found on the way: >32 images/fonts broke PDFs; writeDict failed on
  large dicts; SVG wrote "inf".

### Decisions (2026-10-05/06)
- Invalid input is an error, never a silent clamp/conversion.
- fpdf2 is not a pixel authority for PNG; PngSuite's own pixels are.
- Reviews: user compares reference/actual PDFs visually; keep reference
  PDFs self-explaining (marks, legends).
- Releases: devkit model, notes required; veraPDF not on CI.

## Older sessions (pruned 2026-10-06)
Sessions #1-#26b (2026-01 .. 2026-07-21): bootstrap, text/graphics/
images/SVG, OpenType shaping, color fonts, PDF/A, fuzzing, the
zapdf->platen rename, invoice benchmark and perf work, parallel
compression, transforms, API audits, SharedFont -> FontFace with
ownership guards (Foreign* errors). Details in git history and DESIGN.md.
