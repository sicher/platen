# zpdf Context

## Current Focus
Compact subsetting working for both TTF and CFF with comprehensive test coverage. CFF desubroutinization complete; String INDEX subsetting deferred due to macOS rendering issues.

## TODO
- [ ] CFF String INDEX and Global Subrs subsetting (further size reduction)
- [ ] OpenType feature support (GSUB/GPOS parsing, feature activation API, glyph substitution)

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
- Test count: 63 test functions (26 embedded, 27 zpdf, 2 ttf, 8 integration)
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
  - fpdf2 inter_fonts: 95KB, zpdf: 446KB (4.7x larger)
  - CFF: fpdf2 ~6-7KB each, zpdf ~60-70KB (String INDEX + Global Subrs not subsetted)
  - TTF: fpdf2 ~12-41KB, zpdf ~30-60KB (sparse tables due to preserved glyph IDs)
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
- Added `zpdf embed-test [font] [output]` CLI command
- Tested with Courier Prime (monospace) and Charter (proportional)
- Added qpdf-based structural comparison (like fpdf2's assert_pdf_equal)
- Updated testing.zig with CompareMode (structural/semantic/auto)
- CLI: `zpdf check-refs --structural` or `--semantic`
- Structural = qpdf QDF normalization, good for regression testing
- Semantic = pdftotext text+positions, good for cross-implementation comparison
- All 5 reference tests still pass

## What We Did (Session 2026-01-16 #4)
- Created TTF parser (`src/ttf.zig`) - parses TrueType and OpenType fonts
- Parses tables: head, hhea, hmtx, maxp, cmap, name
- Supports cmap format 4 (BMP) and format 12 (full Unicode)
- Added `zpdf font-info` CLI command to inspect fonts
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
- `src/zpdf.zig` - Main library, Document struct, text rendering, font embedding
- `src/embedded.zig` - EmbeddedFont type, WinAnsiEncoding, font embedding logic
- `src/fonts.zig` - Standard PDF fonts (Base 14)
- `src/metrics.zig` - Font metrics, TextMetrics, TextStyle, measureText
- `src/ttf.zig` - TrueType/OpenType font parser
- `src/testing.zig` - PDF comparison utilities (calls Python comparator)
- `src/objects.zig` - PDF object types
- `src/writer.zig` - PDF serialization
- `src/cli.zig` - Command line tool (font-info, embed-test, check-refs, etc.)
- `scripts/gen_references.py` - Generate baseline PDFs using fpdf2
- `scripts/compare_pdfs.py` - Semantic PDF comparison
- `test/reference/` - Reference PDFs (generated by fpdf2)
- `test/fonts/` - Test fonts (Courier Prime, Charter, Satoshi, Inter)

## Open Issues
- Font embedding uses uncompressed streams (FlateDecode blocked by Zig 0.15 std lib bugs)

## Next Steps

### Priority 1: Graphics Import
5. **JPEG embedding** - trivial, embed raw bytes with DCTDecode
6. **PNG embedding** - decode, handle alpha as soft mask
7. **PDF embedding** - parse external PDF, embed as Form XObject

### Priority 3: Flow/Region API
8. Implement Region type and writeFitting
9. Implement measureWrappedText (word wrap measurement)

### Priority 4: Drawing Primitives
10. Basic shapes: line, rect, circle, ellipse, polygon
11. Path API: moveTo, lineTo, curveTo, closePath, stroke, fill
12. Styling: stroke/fill color, line width, dash patterns

### Priority 5: Housekeeping
13. Stream compression (FlateDecode) for smaller PDFs
