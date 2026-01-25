# zpdf API Quality Review

This document identifies quality improvements for the user-facing API.

## Measurement Methods Overview

The library provides several methods for measuring text and fonts. Here's a complete inventory:

### Text Width Measurement

Use `write()` or `writeStyled()` with `.measure_only = true` to measure text:

```zig
var region = doc.getPageRegion().?;
const result = try doc.write(&region, text, style, .{ .measure_only = true });
// result.rect gives bounding box, result.lines_written gives line count
```

Internal text width measurement (`getTextWidthStyled`) is not exposed - use the layout APIs instead.

### Wrapped Text Measurement

| Method | Returns | Use Case |
|--------|---------|----------|
| `write(region, str, style, .{ .measure_only = true })` | `WriteResult` | Measures layout without rendering. Side-effect free. |
| `writeStyled(region, text, style, .{ .measure_only = true })` | `WriteResult` | Measures styled text layout without rendering. Side-effect free. |

All write methods take explicit `TextStyle` parameter.

**WriteOptions:**
```zig
pub const WriteOptions = struct {
    measure_only: bool = false,        // If true, measure without rendering (side-effect free)
    wrap: bool = true,                 // Wrap text to next line
    valign: VAlign = .top,             // Vertical alignment
    break_on_hyphens: bool = true,     // Break at regular hyphens
    line_height: f64 = 1.2,            // Line height multiplier
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
    line_height: f64 = 1.2,            // Line height multiplier
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
var region = doc.getPageRegion().?;
const style = TextStyle{ .font = Font.helvetica, .size = 11 };
const result = try doc.write(&region, text, style, .{ .measure_only = true });
// result.lines_written = number of lines
// Calculate height: lines_written * style.size * 1.2

// Render directly
_ = try doc.write(&region, text, style, .{});
```

### Font Metrics

| Method | Returns | Use Case |
|--------|---------|----------|
| `getFontMetricsStyled(style)` | `FontMetrics` | Get detailed font metrics (ascender, descender, cap height, x-height) scaled to the specified style's font size. |

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
| `findSoftHyphenBreakStyled(word, max_width, style)` | `?usize` | Find best soft-hyphen (U+00AD) break point that fits within width. Returns byte position. |
| `findHyphenBreakStyled(word, max_width, style)` | `?usize` | Find best regular hyphen break point (for compound words like "state-of-the-art"). |

These are used internally by `write`/`writeStyled` and require explicit `TextStyle`.

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

### Graphics API Changes (COMPLETED)

The following changes have been implemented:

1. ✅ **Removed `setDrawStyle()`** - stateful approach replaced by explicit styles
2. ✅ **Added `StrokeStyle`** - stroke settings (color, width, cap, join, dash)
3. ✅ **Added `FillStyle`** - fill settings (color)
4. ✅ **Added `ShapeStyle`** - combined optional stroke + optional fill
5. ✅ **Updated drawing methods to use `Rect`/`Point` types** - cleaner API
6. ✅ **Removed deprecated types** - `DrawStyle`, `DrawStyleOptions`, `GraphicsState`

### Font API Changes (COMPLETED)

The following changes have been implemented:

1. ✅ **Added `Font` union type** - unifies standard and embedded fonts
   ```zig
   pub const Font = union(enum) {
       family: FontFamily,     // helvetica, times, courier
       symbol,
       zapf_dingbats,
       embedded: *EmbeddedFont,
   };
   ```
2. ✅ **Added `FontFamily` enum** - `.helvetica`, `.times`, `.courier`
3. ✅ **Added `Font` convenience constants** - `Font.helvetica`, `Font.times`, `Font.courier`
4. ✅ **Added `TextStyle` struct** - complete text style with font, size, bold, italic, color, decoration
5. ✅ **Updated `loadFont()`** - returns `Font`, takes optional encoding parameter
   ```zig
   // Old
   const font = try doc.loadFont("path.ttf");
   font.encoding = .identity;

   // New (null = identity/Unicode, the default)
   const font = try doc.loadFont("path.ttf", null);
   const latin = try doc.loadFont("latin.ttf", .win_ansi);
   ```
6. ✅ **Updated `setEmbeddedFont()`** - accepts `Font` type (validates it's embedded)

### Text Method API Changes (COMPLETED)

The following changes have been implemented:

1. ✅ **Updated `writeAt()`** - takes `Point` and `TextStyle` instead of separate x,y and document state
   ```zig
   // Old
   try doc.setFont(.helvetica, 12);
   _ = try doc.writeAt(50, 50, "Hello");

   // New
   const style = TextStyle{ .font = Font.helvetica, .size = 12 };
   _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello", style);
   ```
2. ✅ **Updated `write()`** - takes `TextStyle` parameter for explicit styling
   ```zig
   // Old
   try doc.setFont(.helvetica, 11);
   _ = try doc.write(&region, text, .{});

   // New
   const style = TextStyle{ .font = Font.helvetica, .size = 11 };
   _ = try doc.write(&region, text, style, .{});
   ```
3. ✅ **Added `line_height` to `WriteOptions`** - line height multiplier (default 1.2)
4. ✅ **Added `getFontMetricsStyled()`** - get font metrics for a specific TextStyle
5. ✅ **Text measurement via `write/writeStyled` with `.measure_only = true`**
6. ✅ **Updated `writeStyled()`** - takes `TextStyle` parameter for explicit styling
   ```zig
   // Old
   try doc.setFont(.helvetica, 12);
   _ = try doc.writeStyled(&region, &st, .{ .alignment = .justify });

   // New
   const style = TextStyle{ .font = Font.helvetica, .size = 12 };
   _ = try doc.writeStyled(&region, &st, style, .{ .alignment = .justify });
   ```
7. ✅ **Added `line_height` to `ParagraphOptions`** - line height multiplier (default 1.2)

### Stateful Text API Removal (COMPLETED)

The following stateful methods have been removed in favor of explicit `TextStyle` parameters:

1. ✅ **Removed `setFont()`** - use `TextStyle{ .font = Font.helvetica, .size = 12 }` instead
2. ✅ **Removed `setEmbeddedFont()`** - use `TextStyle{ .font = embedded_font, .size = 12 }` instead
3. ✅ **Removed `setTextColor()`** - use `TextStyle{ .color = Color.blue }` instead
4. ✅ **Removed `setTextStyle()`** - use `TextStyle{ .decoration = .underline }` instead
5. ✅ **Removed `setCharSpacing()`** - not commonly needed, can be added back if required
6. ✅ **Removed `setLineHeight()`** - use `WriteOptions{ .line_height = 1.5 }` instead
7. ✅ **Removed `getLineHeightPts()`** - calculate as `style.size * line_height_multiplier`
8. ✅ **Removed `getFontMetrics()`** - use `getFontMetricsStyled(style)` instead
9. ✅ **Removed `getTextWidth()`** - use `write/writeStyled` with `.measure_only = true`
10. ✅ **Removed `measureText()`** - use `write(..., .{ .measure_only = true })` instead
11. ✅ **Removed `setPosition()`/`getPosition()`** - use explicit coordinates with `writeAt()`
12. ✅ **Removed `currentDestination()`** - use `destination(y)` with explicit y position
13. ✅ **Removed `current_font`, `font_size`, `text_color`, etc.** - all state is now explicit
14. ✅ **Removed `setPageSize()`** - use `addPage(.{ .size = ... })` instead
15. ✅ **Removed `setMargins()`** - use `addPage(.{ .margins = ... })` instead
16. ✅ **Added `selectPage(index)`** - switch current page for content operations
17. ✅ **Added `insertPage(index, opts)`** - insert page at position (for TOC workflows)
18. ✅ **Added `pageCount()`** - get total number of pages

**New usage pattern:**
```zig
// Stroke only (default width 0.567pt, square cap)
try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 50 }, .{ .stroke = .{} });

// Fill only
try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 50 }, .{ .fill = .{ .color = Color.blue } });

// Stroke and fill
try doc.drawRect(rect, .{ .stroke = .{ .width = 2, .color = Color.black }, .fill = .{ .color = Color.yellow } });

// Line with custom style
try doc.drawLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .width = 1.5, .dash = .{ .dash = 5, .gap = 3 } });
```

## 1. Missing Getters (Asymmetric API)

Most stateful setters have been removed in favor of explicit parameters. Remaining setters:

| Setter | Missing Getter | Notes |
|--------|----------------|-------|
| `setMetadata(DocumentMetadata)` | `getMetadata()` | Need to read document metadata |

**Removed setters** (now use explicit parameters):
- ~~`setFont()`~~ - use `TextStyle` parameter
- ~~`setTextColor()`~~ - use `TextStyle.color`
- ~~`setLineHeight()`~~ - use `WriteOptions.line_height`
- ~~`setDrawStyle()`~~ - use `ShapeStyle` parameter
- ~~`setPageSize()`~~ - use `addPage(.{ .size = ... })`
- ~~`setMargins()`~~ - use `addPage(.{ .margins = ... })`

**Recommendation**: Add getter for `setMetadata()`.

## 2. Naming Inconsistencies

### Resolved Issues
- ✅ `measureTextWidth` removed - use `write/writeStyled` with `.measure_only = true`
- ✅ `getLineHeightPts()` removed - use `style.size * line_height_multiplier`
- ✅ `pageNo()` renamed to `getPageIndex()` for consistency

### Remaining Naming Issues
| Current | Issue | Suggested |
|---------|-------|-----------|
| `fillRectGradient()` | Doesn't match `drawRect()` pattern | `drawRectGradient()` or integrate into `drawRect()` |

### Naming Conventions
Method naming is now consistent:
- `get*` for queries: `getPageIndex()`, `getPageRegion()`, `getFontMetricsStyled()`
- `destination(y)` returns a `Destination` struct (not a getter pattern)

## 3. Missing Convenience Methods

### Load from Memory
Currently only file paths are supported:
```zig
// Current API (file only)
const font = try doc.loadFont("path/to/font.ttf", null);
const image = try doc.loadImage("path/to/image.png");
const svg = try doc.loadSvg("path/to/icon.svg");

// Missing (from memory)
const font = try doc.loadFontFromBytes(font_data, null);
const image = try doc.loadImageFromBytes(png_data);
const svg = try doc.loadSvgFromString(svg_string);
```

**Recommendation**: Add `*FromBytes()` / `*FromString()` variants for all load methods.

### Document Queries
```zig
// Available methods
doc.pageCount() -> usize           // ✅ Total number of pages
doc.getPageIndex() -> usize        // ✅ 0-based current page index
// Font queries not needed - TextStyle is explicit per-call
```

## 4. Parameter Inconsistencies

### Drawing Method Signatures (UPDATED)
All drawing methods now use explicit style parameters with `Rect`/`Point` types:
```zig
// Line takes explicit StrokeStyle:
drawLine(p1: Point, p2: Point, style: StrokeStyle)

// Shapes take ShapeStyle (optional stroke + optional fill):
drawRect(rect: Rect, style: ShapeStyle)
drawRoundedRect(rect: Rect, radius: f64, style: ShapeStyle)
drawCircle(center: Point, radius: f64, style: ShapeStyle)
drawEllipse(rect: Rect, style: ShapeStyle)
drawPolygon(points: []const Point, style: ShapeStyle)
drawPath(path: *const Path, style: ShapeStyle)

// Gradients:
fillRectGradient(rect: Rect, gradient_idx: usize)
```

✅ **COMPLETED**: Explicit styles replace stateful `setDrawStyle()`

### Position Parameters
All methods now use Point/Rect types for geometric parameters:
```zig
// Drawing uses Point/Rect:
drawLine(p1: Point, p2: Point, style)      // Point structs
drawRect(rect: Rect, style)                 // Rect struct
drawCircle(center: Point, radius, style)    // Point + scalar

// Text uses Point:
writeAt(pos: Point, str, style)             // Point struct + TextStyle
drawImage(img, x, y, w, h)                  // Separate coordinates (could use Rect)
```

**Note**: `drawImage` still uses separate x,y,w,h coordinates.

## 5. API Friction

### Gradients Require Two Steps
```zig
// Current: two-step process
const grad = LinearGradient{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0, .stops = &stops };
const idx = try doc.addLinearGradient(grad);
try doc.fillRectGradient(.{ .x = 50, .y = 50, .width = 100, .height = 50 }, idx);

// Shapes are single step with explicit style
try doc.drawRect(.{ .x = 50, .y = 50, .width = 100, .height = 50 }, .{ .fill = .{ .color = Color.blue } });
```

**Recommendation**: Add convenience methods:
```zig
try doc.drawLinearGradient(grad, rect);
try doc.drawRadialGradient(grad, rect);
```

### Method Chaining - Not Applicable
With explicit `TextStyle` parameters, method chaining is no longer relevant:
```zig
// All styling is explicit per-call
const style = TextStyle{ .font = Font.helvetica, .size = 12, .color = Color.blue };
_ = try doc.writeAt(.{ .x = 50, .y = 50 }, "Hello", style);
```

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
- `WriteOptions`, `ParagraphOptions` fields not documented in README
- OpenType features list incomplete in README

## Priority Recommendations

### Completed ✅
- ~~Remove duplicate `measureTextWidth()`~~ - use `write/writeStyled` with `.measure_only = true`
- ~~Remove `measureWrappedText()`~~ - use `write/writeStyled(.measure_only=true)`
- ~~Refactor graphics API~~ - explicit `ShapeStyle` replaces stateful `setDrawStyle()`
- ~~Remove stateful text API~~ - all methods now take explicit `TextStyle`
- ~~Add page navigation~~ - `pageCount()`, `getPageIndex()`, `selectPage()`, `insertPage()`
- ~~Standardize getter naming~~ - `getPageIndex()`, `getPageRegion()`, `getFontMetricsStyled()`

### High Priority (API completeness)
1. Add `loadFontFromBytes()`, `loadImageFromBytes()`, `loadSvgFromString()`
2. Add `getMetadata()` to match `setMetadata()`

### Medium Priority (Consistency)
3. Rename `fillRectGradient()` to `drawRectGradient()`

### Low Priority (Nice to have)
4. Add `saveState()` / `restoreState()`
5. Add convenience gradient drawing methods
6. Add clipping API
7. Add transform API

## Summary

The API is functional and covers the core PDF generation needs well. Recent improvements:
- ✅ **Measurement API**: Unified via `measure_only` flag, side-effect free
- ✅ **Graphics API**: Explicit styles replace stateful `setDrawStyle()`
- ✅ **Font API**: Unified `Font` type, `loadFont()` returns `Font` with optional encoding
- ✅ **Text API**: `writeAt()`, `write()`, `writeStyled()` take explicit `TextStyle` parameter
- ✅ **Stateful API Removal**: Removed all stateful font/text methods (`setFont`, `setTextColor`, etc.)

The API is now fully explicit - all text styling is done via `TextStyle` parameters passed to each method call. This eliminates hidden state and makes code easier to reason about.

Remaining issues:
- **Missing `getMetadata()`**: `setMetadata()` has no corresponding getter
- **Missing memory loading**: Can only load resources from files
- **Two-step gradients**: More friction than necessary

The API is clean and explicit. Remaining items are convenience features.
