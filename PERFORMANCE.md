# PLATEN Performance Report

## Executive Summary (current, 2026-07-21)

Apple M1 Pro, ReleaseFast, `smp_allocator`.

**Many small documents** (invoice benchmark: unique single-page A4
invoices, Inter family with full OpenType shaping, vector SVG logo,
per-document subsetting):

| Mode | Throughput |
|------|------------|
| 1 thread | ~2,000 PDFs/sec |
| 1 thread, shared assets (FontFace/Svg) | ~3,200 PDFs/sec |
| 8 threads, shared assets | **~18,600 PDFs/sec** |

**One large document** (110 pages: shaping-heavy text, Unicode,
justified flow, ~1500 vector shapes/page, color emoji):

| Mode | Total | PDF output phase |
|------|-------|------------------|
| 1 thread | ~74-80ms (~1,500 pages/sec) | ~34ms |
| `compress_threads = 8` | ~56ms | ~18ms |

Key facts that keep these numbers honest:
- Measurement runs the same shaping pipeline as rendering (measure ==
  render, byte-stable layout).
- Shared assets produce byte-identical output to per-document parsing.
- Parallel stream compression is byte-identical to single-threaded.
- Documents share nothing: one document per thread needs no locking.

## Running the Benchmarks

```bash
# Invoice throughput (many small documents)
zig build bench-invoice -Doptimize=ReleaseFast -- [--count=N] [--threads=N] [--shared] [--compress=N]

# 110-page document (one large document)
zig build perf -Doptimize=ReleaseFast -- [--pages=N] [--iterations=N] [--threads=N] [--output=PATH]
```

---

# Optimization History

## 2026-07 Round (invoice benchmark, concurrency, caching)

Profile-guided work on the invoice benchmark (`zig build bench-invoice`:
1000 unique single-page A4 invoices, Inter family, SVG logo, unique data
per render, single-threaded unless noted). Apple M1 Pro, ReleaseFast.

| Stage | Invoice throughput |
|-------|--------------------|
| Baseline (2026-07-20) | 1,039 PDFs/sec |
| + featureIndex + kern cache + image level | 1,602 PDFs/sec |
| + SVG logo (was PNG) + writeAt single-shaping | ~2,000 PDFs/sec |
| + shared assets (`--shared`) | ~3,200 PDFs/sec |
| 8 threads, shared assets | ~18,600 PDFs/sec |

### Hot-path fixes

1. **FeatureFlags.featureIndex** (opentype.zig) — was an unrolled linear
   compare chain over ~150 OpenType feature enum values, called up to
   119x per shaped string via the ss01-ss20/cv01-cv99 loops: **33% of
   total runtime**. Now a comptime-sorted table + binary search, plus
   contiguous range scans (`anyEnabledInRange`) for the ss/cv blocks and
   cheap `items.len` checks ordered before flag lookups.
2. **Kerning cache** (opentype.zig) — `AutoHashMap(u32, i16)` replaced
   by a direct-mapped 4096-slot array (Knuth multiplicative hash,
   collisions overwrite). Removes wyhash + probing from the per-glyph-
   pair path in both measurement and rendering.
3. **writeAt shapes once** (document.zig) — writeTextStyled returns the
   width computed from its own shaped glyph run (`glyphSequenceWidth`);
   writeAt no longer re-measures for its returned Rect, and anchored
   text (.center/.right) shifts the deferred command instead of
   measure-then-write. This paid for shaped measurement (measurement now
   runs the full GSUB pipeline, so measure == render) at net-zero cost.
4. **Image compression floor** (document.zig) — image pixel streams
   compress at `@max(6, compression_level)`: compressed once at load,
   they dominate file size, so fast levels are a bad trade there.

### Concurrency

5. **Concurrent documents** — `last_output_timing` moved from a global
   into Document (was a data race); one-Document-per-thread is a
   documented guarantee. 8 threads: ~9,200 PDFs/sec unshared.
6. **Parallel stream compression** — `doc.compress_threads = N`
   compresses page-content and font-subset streams on a worker pool
   during output(); byte-identical output (regression-tested). 110-page
   benchmark: PDF output 34ms -> 18ms, total ~79ms -> ~56ms.

### Cross-document caching (FontFace / caller-owned assets)

7. **FontFace** parses a font once — ttf tables, metrics, and all
   OpenType lookups eagerly — and documents clone it cheaply on first
   use (shared immutable tables, fresh per-document mutable state). The
   single-thread win is mostly the per-document GSUB/GPOS parse
   (text+layout 0.28ms -> 0.16ms); font/logo load phases drop to ~0.
   Caller-owned Image/Svg give the same amortization for raster/vector
   assets. Output stays byte-identical to per-document parsing.
8. `FontFace.warmup(text)` optionally pre-fills the kerning cache that
   clones inherit (~0.06ms/doc saved on cold kern lookups).

### Measurement instrumentation

The invoice benchmark prints a per-phase breakdown (font load, logo,
text+layout, output) and supports `--threads=N` / `--shared` /
`--compress=N`. Current single-thread shared breakdown: ~0.001ms fonts,
~0.000ms logo, ~0.16ms text+layout, ~0.15ms output.

### Remaining known costs (by design or future work)

- Per-document work that caching cannot remove: shaping, subsetting,
  content generation, serialization (~0.31ms/invoice shared).
- Parallel page rendering inside one document needs per-thread or
  frozen font caches first (kern cache and glyph tracking mutate
  EmbeddedFont during render) — see TODO.md.


## 2026-01 Round (shaping and output, 6x on debug builds)

Profiling on 2026-01-20 achieved **6x speedup** for OpenType text shaping and **75% overall improvement** for a 100-page PDF generation benchmark.

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| OpenType heavy (100 pages) | 1244ms | 204ms | **6x faster** |
| PDF output (100 pages) | 680ms | 277ms | **59% faster** |
| Page rendering (100 pages) | 553ms | 153ms | **72% faster (3.6x)** |
| Total time (100 pages) | ~2600ms | ~660ms | **75% faster (4x)** |

Configuration: 100 pages in 4 sections; Inter/Charter/Gentium; Debug
build (to make bottlenecks visible); Apple Silicon.

### Debug-build breakdown (2026-05-01, historical)

```
Font loading:      1ms   (0%)
Simple text:      45ms   (5%)
OpenType heavy:  198ms  (23%)
Unicode/marks:   128ms  (15%)
Text flow:        46ms   (5%)
Drawing shapes:  117ms  (14%)
PDF output:      312ms  (37%)
--------------------------
TOTAL:           849ms
```

(Compression moved from C zlib to `std.compress.flate` in 2026-07;
historical sections below that mention zlib predate that switch.)

### 2026-01 optimizations implemented

#### 1. Fast-Path First Coverage Check (opentype.zig:246)

**Problem**: Chain context matching checked backtrack glyphs before the first input glyph, wasting cycles on rules that couldn't possibly match.

**Solution**: Check first input coverage immediately - this rejects most non-matches before expensive backtrack/lookahead checks.

**Impact**: 2x speedup for calt processing

```zig
// FAST PATH: Check FIRST input coverage immediately
if (self.input_coverages[0].getCoverageIndex(glyphs[pos]) == null) return null;
```

#### 2. Pre-allocated ArrayLists (opentype.zig)

**Problem**: ArrayList grew incrementally with each glyph append, causing multiple reallocations.

**Solution**: Use `ensureTotalCapacity` + `appendAssumeCapacity` pattern.

**Impact**: Eliminated per-glyph reallocation overhead

#### 3. Scratch Buffers in OpenTypeFeatures (opentype.zig:605-608)

**Problem**: Each feature application (calt, liga, dlig, etc.) allocated a new array, then freed the old one.

**Solution**: Added three reusable scratch buffers (`scratch_a`, `scratch_b`, `scratch_c`) that ping-pong during feature application.

**Impact**: Reduced allocations from ~10 per shaping call to ~1 (final result only)

#### 4. Scratch Buffers in EmbeddedFont (embedded.zig:178-180)

**Problem**: `markUnicodeCharsUsed` created new ArrayLists for codepoints and glyphs on every call.

**Solution**: Added `scratch_codepoints` and `scratch_glyphs` buffers that are cleared and reused.

**Impact**: 40% speedup for "no features" baseline case

#### 5. O(1) Glyph Lookup (embedded.zig:506)

**Problem**: Ligature tracking iterated entire hashmap to check if glyph already mapped.

**Solution**: Use existing `glyph_to_codepoint.contains()` for O(1) lookup.

**Impact**: Eliminated O(n) iteration per ligature

#### 6. Fast Soft-Hyphen Check (platen.zig:1037-1041)

**Problem**: `stripSoftHyphens` scanned byte-by-byte even when no soft-hyphens present.

**Solution**: Use `std.mem.indexOf` for fast pattern search first.

**Impact**: Minor improvement (~1%)

#### 7. Early Exit from Kerning/Mark Check (platen.zig:666-684)

**Problem**: The kerning/mark detection loop checked ALL glyph pairs even after finding one with kerning.

**Solution**: Exit the loop as soon as both has_kerning and has_marks are determined.

**Impact**: ~22% faster page rendering for text with kerning

#### 8. Cached Font Feature Flags (embedded.zig:174-176)

**Problem**: Each text command checked if the font has kerning/marks, even though this is constant per font.

**Solution**: Added `has_kern_data` and `has_mark_data` flags set once during font initialization.

**Impact**: Skip kerning check loop entirely for fonts without GPOS kerning data

#### 9. Fast Hex Conversion (platen.zig:32-41)

**Problem**: Each glyph ID was converted to hex using `std.fmt.bufPrint`, which has parsing overhead.

**Solution**: Use a simple lookup table for hex character conversion.

**Impact**: ~8% faster page rendering

#### 10. Lazy Kerning Cache (opentype.zig:589-590, 1911-1929)

**Problem**: Each glyph pair kerning lookup did O(n) coverage check + pair search, called ~250,000 times for 100 pages.

**Solution**: Added `kern_cache` hash map with lazy population. First lookup does full search and caches result; subsequent lookups are O(1).

**Impact**: **61% faster page rendering (2.5x speedup)** - the same glyph pairs are reused across text commands, so cache hit rate is very high after first pass.

#### 11. Chain Context Rule Index (opentype.zig:637-640, 773-818)

**Problem**: For each glyph position, all 65 chain context rules were checked. Most glyphs don't match any rule, making this O(glyphs × rules) per text string.

**Solution**: Build index mapping glyph_id → list of applicable rules. At parse time, enumerate each rule's first input coverage and index by glyph. At runtime, lookup applicable rules by current glyph (O(1)) and only check those.

**Impact**: **51% faster OpenType shaping (2x speedup)** - most glyphs have 0 applicable rules, so the check is skipped entirely. Only special glyphs (-, >, /, etc.) have rules to check.

#### 12. Arena Allocator per Page (platen.zig:278-295)

**Problem**: Each text command allocated `text_data` and `cached_glyphs` individually. These were freed one by one when the page was destroyed.

**Solution**: Added `ArenaAllocator` to `Page` struct. All per-command allocations (text copies, glyph arrays, raw content) use the page arena and are batch-freed when the page is destroyed.

**Impact**: ~4% overall improvement (784ms → 752ms). Also simplifies memory management by removing individual errdefer cleanup.

```zig
const Page = struct {
    arena: std.heap.ArenaAllocator,
    // ...
    fn pageAllocator(self: *Page) std.mem.Allocator {
        return self.arena.allocator();
    }
};
```

#### 13. Cmap Cache and ASCII Lookup Table (ttf.zig:27-33, 86-134)

**Problem**: Every `getGlyphId()` call searched through cmap subtables to find the best one, then did a binary search. This happened for every single character.

**Solution**: Cache the best cmap subtable offset/format once during font parse. Additionally, pre-populate a 128-entry ASCII glyph lookup table for O(1) access to the most common characters.

**Impact**: **12% overall improvement** (752ms → 660ms). Simple text 47% faster, text flow 39% faster.

```zig
// Cached cmap lookup (set once during parse)
cmap_subtable_offset: u32 = 0,
cmap_format: u16 = 0,

// ASCII glyph cache for O(1) lookup
ascii_glyphs: [128]u16 = [_]u16{0} ** 128,
has_ascii_cache: bool = false,
```

#### 14. Hmtx Cache and ASCII Width Table (ttf.zig, embedded.zig)

**Problem**: After adding kerning to `measureTextWidth` for correct text positioning, performance regressed 25% (660ms → 823ms). Each `getGlyphWidth()` call did an O(n) table search via `getTable("hmtx")`.

**Solution**: Cache the hmtx table pointer during font parse. Additionally, pre-populate a 128-entry ASCII width lookup table for O(1) width access. Refactored `measureTextWidth` to use caches and single-pass width+kerning calculation.

**Impact**: **14% improvement** (823ms → 704ms). Simple text recovered to original 39ms baseline.

```zig
// Cached hmtx table pointer
hmtx_data: ?[]const u8 = null,

// ASCII width cache for O(1) lookup (in font units)
ascii_widths: [128]u16 = [_]u16{0} ** 128,
has_ascii_widths: bool = false,
```

#### 15. Fast Float Formatting (format.zig)

**Problem**: PDF coordinate output uses `std.fmt.bufPrint("{d:.2}", .{val})` extensively. Profiling showed this is slow due to parsing overhead.

**Solution**: Created specialized float-to-string functions using precomputed digit pair lookup table.

**Impact**: **2x speedup for drawing operations** (28ms → 14ms for 30,000 shapes)

```zig
// Precomputed digit pairs for fast conversion
const digit_pairs = init: {
    var table: [100][2]u8 = undefined;
    for (0..100) |n| {
        table[n][0] = @intCast(n / 10 + '0');
        table[n][1] = @intCast(n % 10 + '0');
    }
    break :init table;
};

// 14x faster than std.fmt.bufPrint("{d:.2}")
pub fn writeF64_2(buf: []u8, val: f64) []u8 { ... }
```

Microbenchmark (per-call):
- `std.fmt.bufPrint("{d:.2}")`: 46.2 ns
- `format.writeF64_2`: 3.4 ns (14x faster)

Drawing benchmark (debug mode, 20 pages × ~1500 shapes = 30,000 shapes):
| Metric | Before | After | Speedup |
|--------|--------|-------|---------|
| Drawing shapes | 163ms | 88ms | **1.85x** |
| Per-shape | 5.4μs | 2.9μs | 1.85x |

### Shaping microbenchmark (2026-01)

Per-call timing for 5000 iterations:

| Test Case | Time/call | Notes |
|-----------|-----------|-------|
| No features | 0.030ms | Baseline - ASCII cache hit |
| Liga only | 0.028ms | Fast - Charter has no GSUB |
| Calt only | 0.067ms | 65 chain rules in Inter (indexed) |
| Simple ASCII | 0.053ms | With calt+liga enabled |
| All features | 0.088ms | dlig, clig, frac enabled too |

### Remaining bottlenecks as of 2026-01 (annotated)

#### 1. PDF Output (312ms, 37% of total)

Well-optimized. Breakdown:
- Page rendering: 166ms (52%) - kerning cached, hex optimized
- Page writing: 141ms (45%) - zlib compression
- Font writing: 9ms (3%) - font subsetting + embedding

#### 2. OpenType Shaping (198ms, 23% of total)

Now well-optimized with chain context rule index and cmap cache. Remaining costs:
- Ligature application (still O(n) per ligature table)
- Feature flag checks — **resolved 2026-07**: featureIndex was a linear
  scan costing 33% of invoice-benchmark runtime; see the 2026-07 round.
- Non-ASCII cmap binary search

#### 3. Drawing Shapes (117ms, 14% of total)

~1500 vector shapes per page × 20 pages. Float formatting already optimized
(see "Fast Float Formatting" above). Remaining cost is mostly path command
emission and graphics state changes.

#### 4. Simple Text (45ms, 5% of total)

Uses Charter font with no GSUB. Now fast with ASCII cache - cost is mostly:
- UTF-8 decode (minimal)
- Command struct building

### Future optimizations suggested in 2026-01 (annotated)

### Medium Impact

1. **Avoid Text Copy When Possible**
   - If text doesn't contain soft-hyphens, store reference instead of copy
   - Requires lifetime management changes

2. **Batch Text Commands**
   - Combine multiple `writeAt` calls into single command when possible
   - Reduces per-call overhead

3. **Lower Compression Level** — **done**: default compression_level
   is 1 (images keep a floor of 6; see the 2026-07 round).

### Text shaping vs line breaking (2026-01)

Interesting observation: **Optimal line breaking (Knuth-Plass) is faster than text shaping**.

| Operation | Time | Calls | Per-call |
|-----------|------|-------|----------|
| Text flow (optimal breaking) | 46ms | 50 paragraphs | 0.92ms |
| OpenType heavy (shaping) | 198ms | 1250 lines | 0.16ms |

Text flow uses Charter font which has **no GSUB table** - it skips shaping entirely. The line breaking algorithm itself is very efficient.

### Files modified in the 2026-01 round

- `src/ttf.zig` - Cmap subtable cache, ASCII glyph lookup table
- `src/opentype.zig` - Scratch buffers, fast-path matching, pre-allocation, kerning cache, calt rule index
- `src/embedded.zig` - Scratch buffers, O(1) lookup, cached kern/mark flags, output allocator parameter
- `src/platen.zig` - Fast soft-hyphen check, early exit kerning check, fast hex conversion, output timing instrumentation, page arena allocator
- `src/format.zig` - Fast float formatting with digit pair lookup table
- `src/graphics.zig` - Uses fast formatting for path generation
- `src/document.zig` - Uses fast formatting for drawing operations
- `src/perf_test.zig` - Performance test suite with microbenchmarks, output timing breakdown display, drawing benchmark
