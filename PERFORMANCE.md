# ZPDF Performance Report

## Executive Summary

Performance profiling on 2026-01-20 achieved **5.3x speedup** for OpenType text shaping and **70% overall improvement** for a 100-page PDF generation benchmark.

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| OpenType heavy (100 pages) | 1244ms | 235ms | **5.3x faster** |
| PDF output (100 pages) | 680ms | 274ms | **60% faster** |
| Page rendering (100 pages) | 553ms | 151ms | **73% faster (3.7x)** |
| Total time (100 pages) | ~2600ms | ~752ms | **71% faster (3.5x)** |

## Benchmark Configuration

- **Pages**: 100 (divided into 4 sections of 25 pages each)
- **Fonts**: Inter (OpenType-heavy), Charter (simple), Gentium (Unicode)
- **Build**: Debug mode (to make bottlenecks visible)
- **Hardware**: Apple Silicon (fast machine)

## Current Performance Breakdown

```
Font loading:      2ms   (0%)
Simple text:      73ms  (10%)
OpenType heavy:  235ms  (31%)
Unicode/marks:   113ms  (15%)
Text flow:        54ms   (7%)
PDF output:      274ms  (36%)
--------------------------
TOTAL:           752ms
```

### PDF Output Breakdown

```
Subset generation:   7ms   (3%)
Page rendering:    151ms  (55%)
Font writing:       18ms   (7%)
Page writing:       97ms  (35%)
Finish (xref):       0ms   (0%)
--------------------------
TOTAL:             274ms
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

### 6. Fast Soft-Hyphen Check (zpdf.zig:1037-1041)

**Problem**: `stripSoftHyphens` scanned byte-by-byte even when no soft-hyphens present.

**Solution**: Use `std.mem.indexOf` for fast pattern search first.

**Impact**: Minor improvement (~1%)

### 7. Early Exit from Kerning/Mark Check (zpdf.zig:666-684)

**Problem**: The kerning/mark detection loop checked ALL glyph pairs even after finding one with kerning.

**Solution**: Exit the loop as soon as both has_kerning and has_marks are determined.

**Impact**: ~22% faster page rendering for text with kerning

### 8. Cached Font Feature Flags (embedded.zig:174-176)

**Problem**: Each text command checked if the font has kerning/marks, even though this is constant per font.

**Solution**: Added `has_kern_data` and `has_mark_data` flags set once during font initialization.

**Impact**: Skip kerning check loop entirely for fonts without GPOS kerning data

### 9. Fast Hex Conversion (zpdf.zig:32-41)

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

### 12. Arena Allocator per Page (zpdf.zig:278-295)

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

## Shaping Microbenchmark Results

Per-call timing for 5000 iterations:

| Test Case | Time/call | Notes |
|-----------|-----------|-------|
| No features | 0.050ms | Baseline - UTF-8 decode + glyph lookup |
| Liga only | 0.045ms | Fast - Charter has no GSUB |
| Calt only | 0.065ms | 65 chain rules in Inter (indexed) |
| Simple ASCII | 0.062ms | With calt+liga enabled |
| All features | 0.088ms | dlig, clig, frac enabled too |

## Remaining Bottlenecks

### 1. PDF Output (274ms, 36% of total)

Well-optimized. Breakdown:
- Page rendering: 151ms (55%) - kerning cached, hex optimized
- Page writing: 97ms (35%) - zlib compression
- Font writing: 18ms (7%) - font subsetting + embedding

### 2. OpenType Shaping (235ms, 31% of total)

Now well-optimized with chain context rule index. Remaining costs:
- UTF-8 decode + cmap lookup
- Ligature application (still O(n) per ligature table)
- Feature flag checks

### 3. Simple Text (73ms, 10% of total)

Uses Charter font with no GSUB. Cost is mostly:
- UTF-8 decode + cmap lookup
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

### Low Impact

4. **SIMD Glyph Mapping**
   - Vectorize cmap lookups for ASCII range
   - Most benefit for simple ASCII text

## Comparison: Text Shaping vs Line Breaking

Interesting observation: **Optimal line breaking (Knuth-Plass) is faster than text shaping**.

| Operation | Time | Calls | Per-call |
|-----------|------|-------|----------|
| Text flow (optimal breaking) | 54ms | 50 paragraphs | 1.1ms |
| OpenType heavy (shaping) | 235ms | 1250 lines | 0.19ms |

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

- `src/opentype.zig` - Scratch buffers, fast-path matching, pre-allocation, kerning cache, calt rule index
- `src/embedded.zig` - Scratch buffers, O(1) lookup, cached kern/mark flags, output allocator parameter
- `src/zpdf.zig` - Fast soft-hyphen check, early exit kerning check, fast hex conversion, output timing instrumentation, page arena allocator
- `src/perf_test.zig` - Performance test suite with microbenchmarks, output timing breakdown display
