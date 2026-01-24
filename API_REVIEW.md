# zpdf API Quality Review

This document identifies quality improvements for the user-facing API.

## Measurement Methods Overview

The library provides several methods for measuring text and fonts. Here's a complete inventory:

### Text Width Measurement

| Method | Returns | Use Case |
|--------|---------|----------|
| `getTextWidth(str)` | `f64` | **Primary method.** Measures text width in points using current font. Handles soft-hyphens (excludes them from width). Works with both standard and embedded fonts. |
| `measureText(str)` | `TextMetrics` | Returns width, height, and char_count. Height is font_size × line_height_factor. |

~~`measureTextWidth(str)`~~ - **REMOVED** (was duplicate of `getTextWidth`)

### Wrapped Text Measurement

| Method | Returns | Use Case |
|--------|---------|----------|
| `write(region, str, .{ .measure_only = true })` | `WriteResult` | Measures layout without rendering. Side-effect free (cursor unchanged). |
| `writeStyled(region, text, .{ .measure_only = true })` | `WriteResult` | Measures styled text layout without rendering. Side-effect free. |

~~`measureWrappedText(str, MeasureOptions)`~~ - **REMOVED** (use `write/writeStyled` with `measure_only` instead)

**WriteOptions:**
```zig
pub const WriteOptions = struct {
    measure_only: bool = false,        // If true, measure without rendering (side-effect free)
    wrap: bool = true,                 // Wrap text to next line
    valign: VAlign = .top,             // Vertical alignment
    break_on_hyphens: bool = true,     // Break at regular hyphens
};
```

**ParagraphOptions (for writeStyled):**
```zig
pub const ParagraphOptions = struct {
    measure_only: bool = false,        // If true, measure without rendering (side-effect free)
    alignment: Align = .left,          // Horizontal alignment
    valign: VAlign = .top,             // Vertical alignment
    break_on_hyphens: bool = true,     // Break at regular hyphens
    line_breaking: LineBreaking = .greedy,
};
```

**WriteResult:**
```zig
pub const WriteResult = struct {
    lines_written: usize,    // Number of lines rendered
    overflow: ?[]const u8,   // Text that didn't fit, or null
    rect: Rect,              // Bounding rectangle of rendered text
};
```

**Usage pattern for measurement:**
```zig
var region = doc.getPageRegion();
const result = try doc.write(&region, text, .{ .measure_only = true });
// Cursor is unchanged - measure_only is side-effect free
// result.lines_written = number of lines
// Calculate height: lines_written * doc.getLineHeightPts()

// Render directly (no reset needed)
_ = try doc.write(&region, text, .{});
```

### Font Metrics

| Method | Returns | Use Case |
|--------|---------|----------|
| `getFontMetrics()` | `FontMetrics` | Get detailed font metrics (ascender, descender, cap height, x-height) scaled to current font size. |
| `getFontStyle()` | `FontStyle` | Get current font info for external measurement (used internally by measureText). |
| `getLineHeightPts()` | `f64` | Get computed line height in points (font_size × line_height_multiplier). |

**FontMetrics:**
```zig
pub const FontMetrics = struct {
    ascender: f64,      // Top of tallest letter (positive)
    descender: f64,     // Bottom of descenders (negative)
    cap_height: f64,    // Height of capitals
    x_height: f64,      // Height of lowercase 'x'
    y_max: f64,         // Highest point of any glyph
    font_size: f64,     // Size these are scaled to
    units_per_em: u16,  // Original font units

    pub fn lineHeight(self) f64;  // ascender - descender
};
```

**TextMetrics:**
```zig
pub const TextMetrics = struct {
    width: f64,       // Text width in points
    height: f64,      // Height (font_size × line_height)
    char_count: usize, // Character count
};
```

### Word Breaking Helpers

| Method | Returns | Use Case |
|--------|---------|----------|
| `findSoftHyphenBreak(word, max_width)` | `?usize` | Find best soft-hyphen (U+00AD) break point that fits within width. Returns byte position. |
| `findHyphenBreak(word, max_width)` | `?usize` | Find best regular hyphen break point (for compound words like "state-of-the-art"). |

These are used internally by `write`/`writeStyled`.

### Internal/Callback

| Method | Returns | Use Case |
|--------|---------|----------|
| `styledTextMeasure(text, style, ctx)` | `f64` | Callback adapter for StyledText.prepare(). Not typically called directly by users. |

### Measurement API Changes (COMPLETED)

The following changes have been implemented:

1. ✅ **Removed `measureTextWidth`** - use `getTextWidth` only
2. ✅ **Removed `measureWrappedText`** - use `write/writeStyled(.measure_only=true)` instead
   - Eliminated ~150 lines of duplicated line-breaking code
   - Guarantees measurement matches actual rendering
   - `measure_only` is side-effect free (cursor unchanged)
3. ✅ **Removed `MeasureOptions`** - no longer needed
4. ✅ **Removed `WrappedTextMetrics`** - `WriteResult` provides equivalent info
5. ✅ **Added `measure_only` to `writeStyled`** - consistent with `write`
6. ✅ **Made `measure_only` side-effect free** - no need to reset cursor after measuring

## 1. Missing Getters (Asymmetric API)

Several setters lack corresponding getters, making it difficult to read back current state:

| Setter | Missing Getter | Notes |
|--------|----------------|-------|
| `setTextColor(Color)` | `getTextColor()` | Need to read current text color |
| `setCharSpacing(f64)` | `getCharSpacing()` | Need to read current spacing |
| `setLineHeight(f64)` | `getLineHeight()` | Currently only `getLineHeightPts()` exists (computed value) |
| `setMargins(Margins)` | `getMargins()` | Need to read document margins |
| `setPageSize(PageSize)` | `getPageSize()` | Need to read current page size setting |
| `setDrawStyle(DrawStyleOptions)` | `getDrawStyle()` | Need to read current draw style |
| `setMetadata(DocumentMetadata)` | `getMetadata()` | Need to read document metadata |

**Recommendation**: Add getters for all setters to enable symmetric read/write access.

## 2. Naming Inconsistencies

### Duplicate Functionality
- ✅ **RESOLVED**: `measureTextWidth` removed, `getTextWidth` is the single method for text width

### Naming Mismatches
| Current | Issue | Suggested |
|---------|-------|-----------|
| `getLineHeightPts()` | Returns computed pts, but `setLineHeight()` takes multiplier | Add `getLineHeight()` for multiplier, keep `getLineHeightPts()` for computed |
| `fillRectGradient()` | Doesn't match `drawRect()` pattern | `drawRectGradient()` or integrate into `drawRect()` |
| `pageNo()` | Inconsistent with other getters | `getPageNumber()` or `currentPageNumber()` |

### Inconsistent Prefixes
Some methods use `get`/`set` prefix, others don't:
- `pageNo()` vs `getPosition()`
- `currentDestination()` vs `getPageRegion()`

**Recommendation**: Standardize on `get`/`set` prefix for all state access.

## 3. Missing Convenience Methods

### Load from Memory
Currently only file paths are supported:
```zig
// Current API (file only)
const font = try doc.loadFont("path/to/font.ttf");
const image = try doc.loadImage("path/to/image.png");
const svg = try doc.loadSvg("path/to/icon.svg");

// Missing (from memory)
const font = try doc.loadFontFromBytes(font_data);
const image = try doc.loadImageFromBytes(png_data);
const svg = try doc.loadSvgFromString(svg_string);
```

**Recommendation**: Add `*FromBytes()` / `*FromString()` variants for all load methods.

### Document Queries
```zig
// Missing methods
doc.getPageCount() -> usize        // Total number of pages
doc.getCurrentPageIndex() -> usize // 0-based current page index
doc.getCurrentFont() -> ?FontInfo  // Current font name and size
doc.getFontSize() -> f64           // Current font size
```

## 4. Parameter Inconsistencies

### Drawing Method Signatures
```zig
// No style parameter:
drawLine(x1, y1, x2, y2)

// Has style parameter:
drawRect(x, y, w, h, style)
drawCircle(x, y, radius, style)
drawEllipse(x, y, w, h, style)
drawPolygon(points, style)
drawPath(path, style)

// Different naming:
fillRectGradient(x, y, w, h, gradient_idx)
```

**Recommendation**:
- Add optional style to `drawLine()` or document why it only strokes
- Rename `fillRectGradient()` to `drawRectGradient()` for consistency

### Position Parameters
Some methods take separate x, y; others take Point:
```zig
writeAt(x, y, str)        // Separate coordinates
setPosition(Point)        // Point struct
drawImage(img, x, y, w, h) // Separate coordinates
```

**Recommendation**: Accept both forms via overloading or keep consistent (separate coordinates for drawing, Point for cursor).

## 5. API Friction

### Gradients Require Two Steps
```zig
// Current: two-step process
const grad = LinearGradient{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0, .stops = &stops };
const idx = try doc.addLinearGradient(grad);
try doc.fillRectGradient(50, 50, 100, 50, idx);

// Shapes are single step
try doc.drawRect(50, 50, 100, 50, .fill);
```

**Recommendation**: Add convenience methods:
```zig
try doc.drawLinearGradient(grad, x, y, w, h);
try doc.drawRadialGradient(grad, x, y, w, h);
```

### No Method Chaining
Current API doesn't support fluent style:
```zig
// Current
try doc.setFont(.helvetica, 12);
doc.setTextColor(Color.blue);
_ = try doc.writeAt(50, 50, "Hello");

// Could be (if methods returned *Document)
_ = try doc.setFont(.helvetica, 12)
          .setTextColor(Color.blue)
          .writeAt(50, 50, "Hello");
```

**Recommendation**: Consider returning `*Document` from setters for optional chaining (low priority).

## 6. Missing Features

### Graphics State Stack
```zig
// Missing - standard PDF/Canvas feature
try doc.saveState();      // Push graphics state
// ... modify colors, transforms, etc.
try doc.restoreState();   // Pop to previous state
```

### Clipping
```zig
// Missing
try doc.setClipRect(x, y, w, h);
try doc.setClipPath(path);
try doc.resetClip();
```

### Additional Shapes
```zig
// Missing
try doc.drawArc(cx, cy, radius, start_angle, end_angle, style);
```

### Transforms
```zig
// Missing (or not exposed)
try doc.translate(dx, dy);
try doc.rotate(angle);
try doc.scale(sx, sy);
```

## 7. Documentation Gaps

- No doc comments on many public types in `zpdf.zig` re-exports
- `WriteOptions`, `ParagraphOptions`, `MeasureOptions` fields not documented in README
- OpenType features list incomplete in README

## Priority Recommendations

### High Priority (API completeness)
1. Add missing getters for all setters
2. Add `loadFontFromBytes()`, `loadImageFromBytes()`, `loadSvgFromString()`
3. Remove duplicate `getTextWidth()` (keep `measureTextWidth()`)

### Medium Priority (Consistency)
4. Rename `fillRectGradient()` to `drawRectGradient()`
5. Add `getPageCount()`, `getCurrentPageIndex()`
6. Standardize getter naming (`pageNo()` → `getPageNumber()`)

### Low Priority (Nice to have)
7. Add `saveState()` / `restoreState()`
8. Add convenience gradient drawing methods
9. Add clipping API
10. Add transform API

## Summary

The API is functional and covers the core PDF generation needs well. The main issues are:
- **Asymmetric access**: Many setters lack getters
- **Naming inconsistencies**: Mixed conventions for similar operations
- **Missing memory loading**: Can only load resources from files
- **Two-step gradients**: More friction than necessary

Addressing the high-priority items would significantly improve the API ergonomics without breaking changes.
