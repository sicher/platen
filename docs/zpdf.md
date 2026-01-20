# zpdf

zpdf - Fast PDF rendering library for Zig

A library for creating PDF documents, based on fpdf2.

## Imports

```zig
pub const Writer = @import("writer.zig").Writer;
pub const color = @import("color.zig");
pub const document = @import("document.zig");
pub const embedded = @import("embedded.zig");
pub const fonts = @import("fonts.zig");
pub const integration_tests = @import("integration_tests.zig");
pub const layout = @import("layout.zig");
pub const metrics = @import("metrics.zig");
pub const objects = @import("objects.zig");
pub const testing = @import("testing.zig");
pub const ttf = @import("ttf.zig");
pub const zlib = @import("zlib.zig");
```

## Constants

### `Align`

```zig
pub const Align = document.Align;
```

### `Border`

```zig
pub const Border = document.Border;
```

### `Color`

```zig
pub const Color = document.Color;
```

### `DashPattern`

```zig
pub const DashPattern = document.DashPattern;
```

### `Document`

```zig
pub const Document = document.Document;
```

### `DrawStyle`

```zig
pub const DrawStyle = document.DrawStyle;
```

### `EmbeddedFont`

```zig
pub const EmbeddedFont = document.EmbeddedFont;
```

### `FlowOptions`

```zig
pub const FlowOptions = document.FlowOptions;
```

### `Font`

```zig
pub const Font = document.Font;
```

### `FontHandle`

```zig
pub const FontHandle = document.FontHandle;
```

### `FontMetrics`

```zig
pub const FontMetrics = document.FontMetrics;
```

### `LineBreaking`

```zig
pub const LineBreaking = document.LineBreaking;
```

### `LineCap`

```zig
pub const LineCap = document.LineCap;
```

### `LineJoin`

```zig
pub const LineJoin = document.LineJoin;
```

### `LineOptions`

```zig
pub const LineOptions = document.LineOptions;
```

### `Margins`

```zig
pub const Margins = document.Margins;
```

### `Padding`

```zig
pub const Padding = document.Padding;
```

### `PageSize`

```zig
pub const PageSize = document.PageSize;
```

### `ParagraphOptions`

```zig
pub const ParagraphOptions = document.ParagraphOptions;
```

### `Point`

```zig
pub const Point = document.Document.Point;
```

### `Region`

```zig
pub const Region = document.Region;
```

### `StandardFont`

```zig
pub const StandardFont = document.StandardFont;
```

### `TextMetrics`

```zig
pub const TextMetrics = document.TextMetrics;
```

### `TextStyle`

```zig
pub const TextStyle = document.TextStyle;
```

### `VAlign`

```zig
pub const VAlign = document.VAlign;
```

### `WriteResult`

```zig
pub const WriteResult = document.WriteResult;
```

### `opentype`

```zig
pub const opentype = document.opentype;
```

### `pt_per_cm`

Points per centimeter.

```zig
pub const pt_per_cm = 72.0 / 2.54;
```

### `pt_per_inch`

Points per inch.

```zig
pub const pt_per_inch = 72.0;
```

### `pt_per_mm`

Points per millimeter.

```zig
pub const pt_per_mm = 72.0 / 25.4;
```

### `version`

```zig
pub const version = "0.1.0";
```

## Functions

### `cm`

Converts centimeters to points.

```zig
pub fn cm(n: f64) f64
```

### `inches`

Converts inches to points.

```zig
pub fn inches(n: f64) f64
```

### `mm`

Converts millimeters to points.

```zig
pub fn mm(n: f64) f64
```

