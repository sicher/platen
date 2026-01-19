# metrics

Font Metrics for PDF Base 14 Fonts

Character widths are in 1000ths of an em (1 em = font size).
To get actual width in points: width * font_size / 1000

## Structs

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

