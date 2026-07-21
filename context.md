# platen Context

## Current Focus
**Feature-complete at 0.9.0, deliberately held pre-1.0** (user decision
2026-07-21): main carries everything on TODO.md's road-to-1.0 plus the
FontFace model, ownership guards, and API audit. The 1.0.0 tag waits on
the user's call - ceremony when ready: bump build.zig.zon + version.zig,
tag, push tag, restore README tarball install URL.
Zig 0.16, zero dependencies, 426 tests, benchmarks verified 2026-07-21.

## What's Next
- Tag 1.0.0 when the user says so (see above).
- Post-1.0 roadmap lives in TODO.md (encryption, bidi/CJK, text render
  modes, Form XObject stamps, parallel page rendering, document.zig
  split). DESIGN.md records the declined generational-handles idea.


## What We Did (Session 2026-07-21 #26b — merge, API audit round 2, docs)
- Merged foreign-font-guard + fontface-api stack to main (023720f);
  branches deleted. New workflow proven twice: branch -> /code-review
  ultra -> fix findings -> merge (both reviews caught real bugs:
  scratch_c clone sharing; entry-normalization gaps).
- **API audit fixes**: Svg.toPdfContent takes *const Svg (opacity states
  are a caller-owned render output; fixed a thread race for shared
  transparent SVGs; constness compiler-enforced). Image/Svg deinit
  destroy self (single-call cleanup matching FontFace).
  Image.fromMemory(alloc, bytes) borrows, no bool. setFontFeature
  deleted.
- Safety boundary documented honestly (README + DESIGN): Foreign* guards
  catch logic errors on live memory; dangling pointers are UB before any
  check (Zig raw-pointer rules); generational handles considered and
  declined.
- README API reference split: document-owned method tables vs a
  Caller-owned assets section (flushed out stale rows).
- All benchmark claims re-verified on merged main (2,022 / 3,260 /
  9,198 / 18,555 PDFs/sec; 110-page 79ms / 56ms threaded).
- Version held at 0.9.0 by user decision.


## What We Did (Session 2026-07-21 #26 — FontFace API, ownership guards)
- **Font taxonomy collapsed to three public concepts** (user-driven
  redesign): standard fonts (Font.helvetica), FontFace (one parsed file,
  caller-owned+shareable, replaces SharedFont), FontFamily (faces with
  bold/italic resolution). Faces go straight into TextStyle
  (.face / .family) - no per-document load call; Document normalizes at
  entry points into private clones (face_instances map). loadShared* gone.
  Font union variant `family` (standard enum) renamed `standard`.
- FontFace two-phase life cycle: setFeature/warmup during configuration,
  frozen at first use (error.FaceFrozen) - enforced, not documented.
- measureStyled is now fallible (!TextMetrics) - may instantiate a clone.
- **Ownership rule enforced uniformly** (branch foreign-font-guard,
  stacked): doc-obtained assets error in other docs (ForeignFont/
  ForeignImage/ForeignSvg via document_owned marker); caller-created
  assets shareable.
- Bench --shared: 3,178/sec 1t, 18,962/sec 8t, unshared 2,058/sec.

## What We Did (Session 2026-07-21 #25 — SharedFont / cross-document caching)
- **SharedFont API** (branch shared-assets, for ultra review before merge):
  parse font once (incl. all OT lookups eagerly), documents clone cheaply
  with borrow flags; loadSharedFont/loadSharedFontFamily; byte-identical
  output (regression-tested). Bench --shared: 1t 2020 -> 3135/sec,
  8t 9100 -> **18,962/sec** (beats SlothPDF's own M4 number on an M1 Pro).
- **Watch item RESOLVED**: the "unreproducible" byte-identity flake was
  /CreationDate straddling a second boundary between two output() calls;
  byte-identity tests now pin metadata.creation_date.
- Ultrareview of already-merged main isn't possible (empty diff vs
  origin/main; force-push rollback blocked by permissions — by design).
  New work now flows branch -> /code-review ultra -> merge.

## What We Did (Session 2026-07-20 #24b — API consistency, breaking names, transforms)
- **API consistency**: loadFont takes FontEncoding directly (was optional,
  null = .identity; 126 sites migrated); FromMemory lifetime contracts
  documented (fonts/images BORROW, SVG COPIES); README "Coordinates &
  anchoring" section; zlib.compressLevel clamps 1-9.
- **Breaking renames (user-approved)**: writeLine -> writeBlock
  (LineOptions -> BlockOptions); writeAt gained WriteAtOptions with
  anchor (.left/.center/.right — shifts the deferred command using the
  shaped width, so anchored text shapes once); writeAt Rect now uses real
  font metrics (baseline - ascender, ascender-to-descender height).
- **Hygiene**: platen.testing/integration_tests no longer exported (CLI
  imports library source relatively); renderPageCommands +
  styledTextMeasure private again.
- **Transforms & clipping**: pushState/popState, translate, rotateAt
  (clockwise-positive, CSS convention), scaleAt, clipRect/clipPath,
  PageOptions.rotation (/Rotate). User-space affine conjugated with
  y-flip into cm; balance validated. "transforms" integration test with
  platen-generated reference, visually verified.
- **README**: Limitations section (no bidi/joining, no CJK wrap, no
  encryption yet, no interactive features); Unicode claim scoped.
- TODO.md road-to-1.0: all sections complete except optional perf
  follow-ups. 416 tests pass. Watch item: one unreproduced failure of the
  parallel-compression byte-identity test (details in TODO.md).

## What We Did (Session 2026-07-20 #23/#24 — benchmarks, perf, pre-1.0 hardening)
- **Invoice benchmark** (`zig build bench-invoice`, src/invoice_bench.zig):
  1000 unique A4 invoices, Inter family + platen.svg wordmark, mirrors the
  SlothPDF benchmark (their 17k/sec claim reproduced at ~10k/sec on this
  M1 Pro, but they skip shaping/subsetting and their images silently drop
  after the first render). examples/benchmark_invoice.pdf +
  benchmark_110pages.pdf linked from README.
- **Perf: 1,039 -> ~1,950 PDFs/sec single-thread** (uncompressed invoice):
  featureIndex linear scan -> comptime-sorted binary search + range scans
  (was 33% of runtime!), len-first ss/cv checks, direct-mapped kern cache
  (4096 slots) replacing AutoHashMap.
- **Concurrency**: last_output_timing global -> Document field (was a data
  race); --threads=N in invoice bench: 9,087 PDFs/sec at 8 threads.
  Parallel stream compression in output() via doc.compress_threads
  (page contents + font subsets on a worker pool, byte-identical output,
  110-page PDF output 34 -> 19ms).
- **Bug fixes**: measureStyled returned Helvetica metrics for embedded fonts
  (7% off); lazy GPOS parse made pre-render measurements miss kerning
  (visible as one differing Tw on page 60 of the 110-page bench); SVG root
  width="100%" parsed as 100pt instead of falling back to viewBox.
- **Correctness traps (TODO.md) all fixed**: asset ownership bits enable
  cross-document Image/Svg sharing (no more double-free); bold/italic on a
  single .embedded font errors (FontVariantNotLoaded); setFeature records
  overrides and applies to later loads; measurement now runs the same GSUB
  pipeline as rendering (ligatures) and includes char_spacing. writeAt now
  shapes once (writeTextStyled returns the shaped width) - correct
  measurement landed perf-neutral.
- Right-aligned block added to the justify integration test (platen +
  fpdf2 reference regenerated).
- Image streams compress at @max(6, compression_level) again (level-1
  experiment grew the images test PDF 1.6%).
- **v1.0.0 tag removed by user**; version rolled to 0.9.0, README installs
  from main, TODO.md is the road-to-1.0 list. 409 tests pass.

## Older sessions (pruned 2026-07-21)
Sessions #1-#22c (2026-01 .. 2026-07-20): project bootstrap, text/
graphics/images/SVG, OpenType shaping, COLR v0/v1 + bitmap + OT-SVG
color fonts, PDF/A, fuzzing, the zapdf->platen rename, and the C-zlib ->
std.compress.flate switch. Details live in git history and DESIGN.md.
