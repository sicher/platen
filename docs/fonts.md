# fonts

PDF Standard Fonts (Base 14)

PDF viewers are required to have these 14 fonts available.
They don't need to be embedded in the PDF.

## Enums

### `Family`

Standard PDF font families

```zig
pub const Family = enum {
    helvetica,
    times,
    courier,
    symbol,
    zapf_dingbats,
}
```

### `StandardFont`

Standard font identifier

```zig
pub const StandardFont = enum {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    symbol,
    zapf_dingbats
}
```

#### `fromFamilyStyle`

Get a standard font from family and style

```zig
pub fn fromFamilyStyle(family: Family, style: Style) StandardFont
```

#### `pdfName`

Get the PDF name for this font

```zig
pub fn pdfName(self: StandardFont) []const u8
```

### `Style`

Font style

```zig
pub const Style = enum {
    normal,
    bold,
    italic,
    bold_italic,
}
```

## Structs

### `Font`

Font instance with size

```zig
pub const Font = struct {
    standard: StandardFont,
    size: f64
}
```

#### `init`

```zig
pub fn init(standard: StandardFont, size: f64) Font
```

