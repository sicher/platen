# TODO — road to 1.0.0

The v1.0.0 tag has been removed; it goes back when this list is in good
shape. Items come from the 2026-07-20 API review and performance sessions.

## Correctness traps (fix before 1.0.0) — ALL DONE (session #24)

- [x] **Cross-document asset sharing double-frees.** `Image.fromMemory` is
  public and `drawImage`/`drawSvg` auto-register foreign assets, but
  `Document.deinit` unconditionally destroys everything registered. Sharing
  one decoded asset across documents (the natural high-throughput pattern)
  crashes on the second deinit. Fix: per-asset `owned` flag on registration,
  or reject foreign assets explicitly. This is also the prerequisite for the
  shared pre-parsed asset API below.
- [x] **`.bold = true` on a single `.embedded` font silently renders
  regular.** `resolveEmbeddedFont` honors bold/italic only for
  `.embedded_family` (missing variant errors with `FontVariantNotLoaded`);
  for `.embedded` the flags are ignored with no signal. Error, or document
  "families only" on `TextStyle.bold`/`.italic`.
- [x] **`Document.setFeature` only affects fonts loaded before the call.**
  Reads as document-wide policy but loops over currently loaded fonts. Store
  overrides and apply to future loads, or rename/document as
  "set on all currently loaded fonts".
- [x] **Embedded-font measurement ignores `char_spacing`** (standard fonts
  include it). Needs shaped glyph count, not byte count.
- [x] **Measurement ignores GSUB ligatures** while rendering applies them, so
  ligature-bearing strings measure slightly wide. Same family as the
  kerning-order bug fixed in session #23. Fixing shifts layout for every
  ligature-bearing string — regenerate fpdf2 references.

## API consistency — ALL DONE (session #24)

- [x] **Unify `FromMemory` lifetime contracts.** `loadFontFromMemory` and
  `loadImageFromMemory` borrow (caller keeps bytes alive);
  `loadSvgFromMemory` fully copies but doesn't say so. Pick one story,
  document all three.
- [x] **`loadFont(path, encoding: ?FontEncoding)`:** `null` means
  `.identity`, so the optional just creates two spellings of the default
  (tests use both). Make it non-optional with a documented default.
- [x] **Document anchoring conventions prominently:** text `y` = baseline,
  shapes/images `rect.y` = top edge. Correct, but only stated in a code
  comment inside `writeAt`.
- [x] **`compression_level: i32`** silently maps out-of-range values to
  level 1. Tighten the domain (enum or clamp with documentation).

## Ergonomics / design decisions (breaking — decide before 1.0.0) — ALL DONE (session #24)

- [x] **`writeLine` wraps into multiple lines** despite the name (doc says
  "block-based"). Consider `writeBlock`/`writeAligned`, or lead the docs
  with "wraps".
- [x] **Rework `writeAt`** in one pass (re-measuring for the returned Rect
  is already fixed - writeAt now computes width from its own shaped run):
  point-anchored alignment
  (`anchor: left/center/right` — today right-aligning needs measure +
  subtract, shaping twice; see `writeRight` in `src/invoice_bench.zig`),
  make the Rect honest (uses `y - size`
  "approximate ascender" while exact `FontMetrics` exists).
- [x] **`Color.rgb(0-255)` vs `rgbf(0-1)` vs `greyscale(0-1)`** — mixed
  scales; fine but easy to trip on. At minimum cross-reference in doc
  comments.

## Hygiene — ALL DONE (session #24)

- [x] **Stop exporting test infrastructure:** `platen.testing` and
  `platen.integration_tests` ship in the root namespace. Use a separate
  test-root file for the build's test step.
- [x] **De-`pub` internal machinery on Document:** `renderPageCommands`
  (internal phase of `output()`, used by one test) and `styledTextMeasure`
  (`*anyopaque` callback).

## Missing features — worth doing before 1.0.0 — ALL DONE (session #24)

- [x] **Transforms & rotation.** No way to rotate or transform content — no
  `cm` exposure, no graphics-state save/restore, no page `/Rotate`. Blocks
  watermarks, rotated labels, vertical captions. A small transform API
  (save/restore + translate/rotate/scale, applying to draw* and text) rounds
  out the 2D API and shapes how the graphics API should look — better
  decided before 1.0 than bolted on after.
- [x] **Clipping paths.** Path API exists but there is no public clip
  (`W n`); the only use is internal to gradient fills. Natural companion to
  the transform work above — one "graphics state" feature.
- [x] **Honest Unicode limitations note.** README says "Full Unicode
  support"; codepoint coverage via CID is real, but: RTL scripts render in
  wrong visual order (no bidi, no `init`/`medi`/`fina` joining — the Noto
  Sans Arabic font in test/fonts is referenced by nothing), and CJK text
  won't wrap in flowed text (line breaking is space-based). Either scope the
  claim in README or add a Limitations section. The features themselves are
  post-1.0 (below).
- [x] **Decide the encryption stance.** No RC4/AES support at all. API-wise
  additive (fields on Document), so implementation can land in 1.x — but
  1.0 should consciously say "not yet" rather than be silent. std.crypto
  has AES if/when we do it.

## Missing features — post-1.0 roadmap

- [ ] Bidi + joining-script shaping (Arabic, Hebrew): UAX #9 reordering,
  isol/init/medi/fina GSUB features. Large; needs script itemization.
- [ ] CJK-aware line breaking (break opportunities without spaces; kinsoku
  rules eventually).
- [ ] Text rendering modes (`Tr`): outlined/stroked text, invisible text
  (OCR overlays). Tiny and additive.
- [ ] Reusable Form XObjects ("stamps") for user content — currently only
  used internally for SVG embedding. Big win for batch documents with
  repeated headers; pairs with the shared-asset API.
- [ ] Encrypt metadata strings too (StrF=AESV3): needs the file key
  threaded through objects.zig string serialization.
- [ ] Interactive forms (AcroForm), digital signatures, file attachments —
  each large and additive; explicitly out of 1.0 scope.
- [ ] Tables stay out of scope: platen is a low-level library; regions +
  writeBlock compose into tables (see invoice benchmark).

## Watch items

- [x] **RESOLVED: the "unreproduced" byte-identity flake was /CreationDate.**
  The test compares two output() calls; when they straddle a second
  boundary the auto-generated timestamp differs. Both byte-identity tests
  now pin metadata.creation_date. (Found while byte-comparing SharedFont
  output, 2026-07-20.)

## Performance (post-review follow-ups, optional for 1.0.0)

- [x] **Shared pre-parsed asset API** — fonts/images reusable across
  Documents (caller-owned cache; library stays stateless). Closes most of
  the remaining per-document cost in the invoice benchmark
  (per-doc font parse + GSUB/GPOS parse + image decode ≈ 0.25ms of 0.50ms).
  Depends on the double-free fix above.
- [ ] **Parallel page rendering in `output()`** — pages look independent but
  rendering mutates shared `EmbeddedFont` state (kern cache, glyph
  tracking); needs per-thread or frozen font caches first. Payoff ~10-15ms
  on the 110-page bench after parallel stream compression (done).

## Open after session #27 (2026-10-06)

- [x] **Comparator font check had silent gaps** (fixed 2026-10-06). A
  missing qpdf already failed loudly; the real gaps: fonts were compared
  only when BOTH pages had some (a page that lost all its fonts passed),
  and a qpdf failure on a file became "no fonts". Both are now
  differences/errors; scripts/test_compare_pdfs.py covers them and runs in
  `zig build test`. The scripts are declared inputs of the test run step,
  so editing them re-runs the tests. Since 2026-10-06 so are all files
  under test/ (except test/output): a changed reference or fixture
  re-runs the suite instead of serving a cached pass.
- [x] **StyledText: bold/italic per span** (done 2026-10-06): optional
  TextStyleOptions.bold/.italic, inheriting like color/decoration.
- [x] **Benchmarks re-measured** (2026-10-06, M1 Pro, medians of 3): all
  modes match or beat July except 8 threads + shared assets, ~17,700/s
  (runs 16-18k) vs the README's old ~19,000 - partly background load;
  the README now states what was measured.
- [x] **veraPDF stays off the CI runner** (user decision 2026-10-06): the
  PDF/A test skips in CI and runs locally where veraPDF is installed.
- [x] **"Test gaps" closed by analysis** (2026-10-06): both paths are
  unreachable through the public API, so a test would only exercise
  hand-set internal state. embedded.zig getLocaOffset(gid + 1): every
  subsetter drops gid >= numGlyphs (<= 65535) first, so gid + 1 <= 0xFFFF;
  the usize widening stays as defense (the shared function and the
  ttf_subset/colr sites are tested with 0xFFFF). WinAnsi format-0 cmap
  guard: WinAnsi text only reaches markCharsUsed (cid_used_glyphs is
  identity-only), so the subset is <= 253 glyphs.

## Found by the README showcase (2026-10-21)

Building `src/showcase.zig` (real pages, inspected as rendered images)
found three bugs, fixed the same day (CHANGELOG Unreleased): justified
CID text ragged (Tw ignored for Identity-H), `char_spacing` Tc leaking
into later runs, gradient stops borrowed instead of copied. Still open:

- [ ] **`i` + combining mark keeps the dot.** "nai\u{0308}ve" in Gentium
  draws the diaeresis over a dotted i; HarfBuzz (fpdf2 reference) composes
  to the precomposed ï. Missing canonical composition when the font has
  the precomposed glyph, and/or `ccmp` i -> dotless ı before above-marks.
  Also makes pdftotext split the word (the mark's box sits higher). Add an
  fpdf2 reference case once fixed (removed from `justify_embedded`).
- [ ] **`writeStyled` overflow drops later spans.**
  `StyledText.getTextFromWord` returns the rest of ONE span, so
  `WriteResult.overflow` silently loses every following span (and all
  styling). Needs an API decision: a continuation (word index / resumable
  StyledText) instead of `[]const u8`. Breaking - decide before 1.0.0.
- [ ] **`platen.Path` is not exported** from the root module (only
  `document.Path`), so users can't name the type returned by
  `createPath()` in their own helpers (showcase uses `anytype`).
- [ ] **`char_spacing` ignored in the mark-positioning path.**
  `renderWithMarkPositioning` places every glyph with `Tm`, so Tc never
  applies, while measurement includes it. Add it to `abs_x` per glyph
  (like word spacing after spaces).

## Code health

- [ ] **Split document.zig** (4200+ lines): output phase, text layout, and
  graphics could be separate files per the token-efficiency guideline of
  keeping sources small. Mechanical but churny — do it in a quiet moment,
  not alongside feature work.

## Feature backlog (unchanged from earlier sessions)

- [ ] Blend modes (Normal, Multiply, Screen, etc.) — partially used by COLR
  composite paints
- [ ] Additional PDF/A levels (2a, 3a for tagged PDF)
- [ ] Opt-in automatic downsampling of 16-bit images to 8-bit under
  PDF/A-1b (a Document flag; today drawImage returns
  error.BitDepthNotAllowed and the caller converts - user decision
  2026-10-05: no silent conversion by default)
- [ ] OT-SVG: gzipped/multi-glyph docs, gradients/transparency in glyph docs
