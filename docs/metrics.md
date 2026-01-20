# metrics

Font Metrics for PDF Base 14 Fonts

Character widths are in 1000ths of an em (1 em = font size).
To get actual width in points: width * font_size / 1000

## Structs

### `FontMetrics`

Font metrics scaled to a specific font size (in points).
All values are in points at the given font size.

```zig
pub const FontMetrics = struct {
    /// Distance from baseline to top of tallest glyph (positive, in points)
    ascender: f64,
    /// Distance from baseline to bottom of lowest glyph (negative, in points)
    descender: f64,
    /// Height of capital letters (in points)
    cap_height: f64,
    /// Height of lowercase 'x' (in points, estimated if not available)
    x_height: f64,
    /// The font size these metrics are scaled to
    font_size: f64,
    /// Units per em in the original font (useful for advanced calculations)
    units_per_em: u16
}
```

#### `lineHeight`

Total line height from ascender to descender

```zig
pub fn lineHeight(self: FontMetrics) f64
```

### `StandardFontMetrics`

Standard font metrics in 1000 units per em (PDF standard)
These are typical values for the Adobe base 14 fonts

```zig
pub const StandardFontMetrics = struct {
    ascender: i16,
    descender: i16,
    cap_height: i16,
    x_height: i16,
}
```

### `TextMetrics`

Text measurement result

```zig
pub const TextMetrics = struct {
    width: f64, // in points
    height: f64, // in points (based on font size * line_height_factor)
    char_count: usize,
}
```

### `TextStyle`

Text style with spacing overrides

```zig
pub const TextStyle = struct {
    font: fonts.StandardFont = .helvetica,
    size: f64 = 12.0,
    /// Extra space between characters (in points). Can be negative.
    char_spacing: f64 = 0.0,
    /// Line height as multiple of font size. Default 1.2 (20% leading).
    line_height: f64 = 1.2
}
```

#### `lineHeightPts`

Calculate line height in points

```zig
pub fn lineHeightPts(self: TextStyle) f64
```

## Functions

### `charWidth`

Get character width for a font (in 1000ths of an em)

```zig
pub fn charWidth(font: fonts.StandardFont, char: u8) u16
```

### `getStandardFontMetrics`

Get metrics for standard fonts (in 1000 units)

```zig
pub fn getStandardFontMetrics(font: fonts.StandardFont) StandardFontMetrics
```

### `measureText`

Measure text and return full metrics

```zig
pub fn measureText(text: []const u8, style: TextStyle) TextMetrics
```

### `measureTextWidth`

Measure text width in points

```zig
pub fn measureTextWidth(text: []const u8, style: TextStyle) f64
```

