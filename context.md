# platen Context

## Current Focus
**Hardening pass done (session #27, 2026-10-04/05); nothing pushed yet.**
Main is at 0.9.0, held pre-1.0 by user decision (1.0 ceremony: bump
build.zig.zon + version.zig, tag, push tag, restore README tarball URL).
Zig **0.17**, zero dependencies, 503 tests, silent clean runs; PDF/A
output veraPDF-validated in the suite.

## What's Next
- **Push** - check the CI runner (`zig-arm64`, `.forgejo/workflows`) has
  Zig 0.17 first; the code no longer builds with 0.16.
- Longer fuzz runs: `--fuzz` works again with 0.17's stock runner (needs
  `mkdir -p .zig-cache/tmp` after a cache wipe - Zig fuzzer bug).
- TODO.md: opt-in 16-bit -> 8-bit downsampling flag for PDF/A-1b; the
  post-1.0 roadmap (bidi/CJK, Tr modes, Form XObjects, parallel pages,
  document.zig split).

## What We Did (Session 2026-10-04/05 #27 - Zig 0.17, hardening, PngSuite)
- **Tooling**: setup-tools clones devkit/simgrep/zigmap into .tools/;
  README compile-checked (7 broken examples fixed); dead `zig build docs`
  step and stale scripts/update_api_docs.py removed.
- **Zig 0.17 migration**: `**` -> @splat / testing.repeat, @typeInfo
  struct-of-arrays, addPassthruArgs, vendored test runner deleted.
- **Number contract** (user decisions: error not clamp, +-1e6,
  error.InvalidNumber): every Document entry point validates via
  validate.zig before mutating (fuzzer found drawCircle panic).
- **Parser overflow audit** (fuzzer + static audit, ~50 sites): offsets
  widen to usize at the read (ttf, opentype, COLR/sbix/CBLC/SVG table,
  ttf_subset, cff_subset), PNG/JPEG header checks and allocation bound,
  font metrics validated at load (unitsPerEm 16..16384), subsetting
  (loca, glyph sets, CFF INDEX via CFFIndex, off-by-one in CFF offSize
  that real fonts could hit). Dead subsetters deleted.
- **Bugs found on the way**: >32 images/fonts/SVGs/ExtGStates (or >16
  shadings) broke PDFs (fixed resource-name tables); Writer.writeDict
  failed on large dicts; SVG wrote "inf" into content (bounded parse +
  composeTransform) and leaked elements.
- **PngSuite** (test/images/pngsuite): reference PDF vs fpdf2 for visual
  review (checkerboard backgrounds, red frames on fpdf2's 17 known-wrong
  cells) + pixel truth from PngSuite's own JSON. PNG now: CRC checks,
  tRNS color keys, 16-bit alpha, Adam7 - all 161 valid images match truth.
- **PDF/A-1b images**: soft masks -> TransparencyNotAllowed, 16-bit ->
  BitDepthNotAllowed (no silent conversion, user decision).
- **veraPDF** (now installed, in the suite; skips if absent) found: every
  PDF/A file failed since the 0.17 migration (signed year printed "+2026"
  - fixed, all width-formatted ints audited); links lacked /F 4; standard
  fonts silently produced non-embedded "PDF/A" (now FontNotEmbedded).
- **Tests**: compare_pdfs.py --compare-images (pixel-exact via pdfimages;
  before, no test looked at image content); test runs are silent; weak
  tests that only printed now assert.

### Decisions (2026-10-05)
- Invalid input is an error, never a silent clamp/conversion.
- fpdf2 is not a pixel authority for PNG (16-bit gray, tRNS); PngSuite's
  own pixels are. Known-wrong/pending lists are enforced both ways.
- Reviews: user compares reference/actual PDFs visually; keep reference
  PDFs self-explaining (marks, legends).

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


## Older sessions (pruned 2026-10-05)
Sessions #1-#25 (2026-01 .. 2026-07-21): bootstrap, text/graphics/
images/SVG, OpenType shaping, COLR/bitmap/OT-SVG color fonts, PDF/A,
fuzzing, zapdf->platen rename, std.compress.flate, invoice benchmark and
perf (1,039 -> ~2,000 PDFs/sec), parallel compression, transforms,
API consistency/renames, SharedFont -> FontFace. Details in git history
and DESIGN.md.
