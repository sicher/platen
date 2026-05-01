# ZAPDF Performance Report

## Executive Summary

Performance profiling on 2026-01-20 achieved **6x speedup** for OpenType text shaping and **75% overall improvement** for a 100-page PDF generation benchmark.

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| OpenType heavy (100 pages) | 1244ms | 204ms | **6x faster** |
| PDF output (100 pages) | 680ms | 277ms | **59% faster** |
| Page rendering (100 pages) | 553ms | 153ms | **72% faster (3.6x)** |
| Total time (100 pages) | ~2600ms | ~660ms | **75% faster (4x)** |

## Benchmark Configuration

- **Pages**: 100 (divided into 4 sections of 25 pages each)
- **Fonts**: Inter (OpenType-heavy), Charter (simple), Gentium (Unicode)
- **Build**: Debug mode (to make bottlenecks visible)
- **Hardware**: Apple Silicon (fast machine)

## Current Performance Breakdown

Debug build, 100 pages, 3-iteration average (2026-05-01):

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

For comparison, ReleaseFast (with `smp_allocator`) on the same workload runs
the full benchmark in ~57ms — see README.md.

### PDF Output Breakdown

```
Subset generation:   1ms   (0%)
Page rendering:    166ms  (52%)
Font writing:        9ms   (3%)
Page writing:      141ms  (45%)
Finish (xref):       0ms   (0%)
--------------------------
TOTAL:             317ms
```

## Optimizations Implemented

### 1. Fast-Path First Coverage Check (opentype.zig:246)

**Problem**: Chain context matching checked backtrack glyphs before the first input glyph, wasting cycles on rules that couldn't possibly match.

**Solution**: Check first input coverage immediately - this rejects most non-matches before expensive backtrack/lookahead checks.

**Impact**: 2x speedup for calt processing

```zig
// FAST PATH: Check FIRST input coverage immediately
if (self.input_coverages[0].getCoverageIndex(glyphs[pos]) == null) return null;
```

### 2. Pre-allocated ArrayLists (opentype.zig)

**Problem**: ArrayList grew incrementally with each glyph append, causing multiple reallocations.

**Solution**: Use `ensureTotalCapacity` + `appendAssumeCapacity` pattern.

**Impact**: Eliminated per-glyph reallocation overhead

### 3. Scratch Buffers in OpenTypeFeatures (opentype.zig:605-608)

**Problem**: Each feature application (calt, liga, dlig, etc.) allocated a new array, then freed the old one.

**Solution**: Added three reusable scratch buffers (`scratch_a`, `scratch_b`, `scratch_c`) that ping-pong during feature application.

**Impact**: Reduced allocations from ~10 per shaping call to ~1 (final result only)

### 4. Scratch Buffers in EmbeddedFont (embedded.zig:178-180)

**Problem**: `markUnicodeCharsUsed` created new ArrayLists for codepoints and glyphs on every call.

**Solution**: Added `scratch_codepoints` and `scratch_glyphs` buffers that are cleared and reused.

**Impact**: 40% speedup for "no features" baseline case

### 5. O(1) Glyph Lookup (embedded.zig:506)

**Problem**: Ligature tracking iterated entire hashmap to check if glyph already mapped.

**Solution**: Use existing `glyph_to_codepoint.contains()` for O(1) lookup.

**Impact**: Eliminated O(n) iteration per ligature

### 6. Fast Soft-Hyphen Check (zapdf.zig:1037-1041)

**Problem**: `stripSoftHyphens` scanned byte-by-byte even when no soft-hyphens present.

**Solution**: Use `std.mem.indexOf` for fast pattern search first.

**Impact**: Minor improvement (~1%)

### 7. Early Exit from Kerning/Mark Check (zapdf.zig:666-684)

**Problem**: The kerning/mark detection loop checked ALL glyph pairs even after finding one with kerning.

**Solution**: Exit the loop as soon as both has_kerning and has_marks are determined.

**Impact**: ~22% faster page rendering for text with kerning

### 8. Cached Font Feature Flags (embedded.zig:174-176)

**Problem**: Each text command checked if the font has kerning/marks, even though this is constant per font.

**Solution**: Added `has_kern_data` and `has_mark_data` flags set once during font initialization.

**Impact**: Skip kerning check loop entirely for fonts without GPOS kerning data

### 9. Fast Hex Conversion (zapdf.zig:32-41)

**Problem**: Each glyph ID was converted to hex using `std.fmt.bufPrint`, which has parsing overhead.

**Solution**: Use a simple lookup table for hex character conversion.

**Impact**: ~8% faster page rendering

### 10. Lazy Kerning Cache (opentype.zig:589-590, 1911-1929)

**Problem**: Each glyph pair kerning lookup did O(n) coverage check + pair search, called ~250,000 times for 100 pages.

**Solution**: Added `kern_cache` hash map with lazy population. First lookup does full search and caches result; subsequent lookups are O(1).

**Impact**: **61% faster page rendering (2.5x speedup)** - the same glyph pairs are reused across text commands, so cache hit rate is very high after first pass.

### 11. Chain Context Rule Index (opentype.zig:637-640, 773-818)

**Problem**: For each glyph position, all 65 chain context rules were checked. Most glyphs don't match any rule, making this O(glyphs × rules) per text string.

**Solution**: Build index mapping glyph_id → list of applicable rules. At parse time, enumerate each rule's first input coverage and index by glyph. At runtime, lookup applicable rules by current glyph (O(1)) and only check those.

**Impact**: **51% faster OpenType shaping (2x speedup)** - most glyphs have 0 applicable rules, so the check is skipped entirely. Only special glyphs (-, >, /, etc.) have rules to check.

### 12. Arena Allocator per Page (zapdf.zig:278-295)

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

### 13. Cmap Cache and ASCII Lookup Table (ttf.zig:27-33, 86-134)

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

### 14. Hmtx Cache and ASCII Width Table (ttf.zig, embedded.zig)

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

### 15. Fast Float Formatting (format.zig)

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

## Shaping Microbenchmark Results

Per-call timing for 5000 iterations:

| Test Case | Time/call | Notes |
|-----------|-----------|-------|
| No features | 0.030ms | Baseline - ASCII cache hit |
| Liga only | 0.028ms | Fast - Charter has no GSUB |
| Calt only | 0.067ms | 65 chain rules in Inter (indexed) |
| Simple ASCII | 0.053ms | With calt+liga enabled |
| All features | 0.088ms | dlig, clig, frac enabled too |

## Remaining Bottlenecks

### 1. PDF Output (312ms, 37% of total)

Well-optimized. Breakdown:
- Page rendering: 166ms (52%) - kerning cached, hex optimized
- Page writing: 141ms (45%) - zlib compression
- Font writing: 9ms (3%) - font subsetting + embedding

### 2. OpenType Shaping (198ms, 23% of total)

Now well-optimized with chain context rule index and cmap cache. Remaining costs:
- Ligature application (still O(n) per ligature table)
- Feature flag checks
- Non-ASCII cmap binary search

### 3. Drawing Shapes (117ms, 14% of total)

~1500 vector shapes per page × 20 pages. Float formatting already optimized
(see "Fast Float Formatting" above). Remaining cost is mostly path command
emission and graphics state changes.

### 4. Simple Text (45ms, 5% of total)

Uses Charter font with no GSUB. Now fast with ASCII cache - cost is mostly:
- UTF-8 decode (minimal)
- Command struct building

## Suggested Future Optimizations

### Medium Impact

1. **Avoid Text Copy When Possible**
   - If text doesn't contain soft-hyphens, store reference instead of copy
   - Requires lifetime management changes

2. **Batch Text Commands**
   - Combine multiple `writeAt` calls into single command when possible
   - Reduces per-call overhead

3. **Lower Compression Level**
   - Use zlib level 1 instead of 6 for faster compression
   - Trade ~1% file size increase for ~3x compression speedup

## Comparison: Text Shaping vs Line Breaking

Interesting observation: **Optimal line breaking (Knuth-Plass) is faster than text shaping**.

| Operation | Time | Calls | Per-call |
|-----------|------|-------|----------|
| Text flow (optimal breaking) | 46ms | 50 paragraphs | 0.92ms |
| OpenType heavy (shaping) | 198ms | 1250 lines | 0.16ms |

Text flow uses Charter font which has **no GSUB table** - it skips shaping entirely. The line breaking algorithm itself is very efficient.

## Test Commands

```bash
# Run performance test
zig build perf -- --pages=100 --iterations=3

# Run with output file
zig build perf -- --pages=100 --output=test.pdf

# Quick test (fewer pages)
zig build perf -- --pages=10 --iterations=1
```

## Files Modified

- `src/ttf.zig` - Cmap subtable cache, ASCII glyph lookup table
- `src/opentype.zig` - Scratch buffers, fast-path matching, pre-allocation, kerning cache, calt rule index
- `src/embedded.zig` - Scratch buffers, O(1) lookup, cached kern/mark flags, output allocator parameter
- `src/zapdf.zig` - Fast soft-hyphen check, early exit kerning check, fast hex conversion, output timing instrumentation, page arena allocator
- `src/format.zig` - Fast float formatting with digit pair lookup table
- `src/graphics.zig` - Uses fast formatting for path generation
- `src/document.zig` - Uses fast formatting for drawing operations
- `src/perf_test.zig` - Performance test suite with microbenchmarks, output timing breakdown display, drawing benchmark
