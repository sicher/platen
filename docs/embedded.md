# embedded

Embedded Font Support

Handles TrueType font embedding in PDF documents.
Supports two encoding modes:
- WinAnsiEncoding (Windows-1252): Simple single-byte text, 256 character limit
- Identity-H (CID): Full Unicode support via 2-byte glyph IDs

## Imports

```zig
pub const opentype = @import("opentype.zig");
```

## Enums

### `FontEncoding`

Font encoding mode for PDF embedding

```zig
pub const FontEncoding = enum {
    /// WinAnsiEncoding - single byte, 256 chars max (legacy mode)
    win_ansi,
    /// Identity-H - 2-byte glyph IDs, full Unicode (CID font)
    identity,
}
```

| Variant | Description |
|---------|-------------|
| `identity` | Identity-H - 2-byte glyph IDs, full Unicode (CID font) |
| `win_ansi` | WinAnsiEncoding - single byte, 256 chars max (legacy mode) |

## Structs

### `EmbeddedFont`

Embedded TrueType font for PDF

```zig
pub const EmbeddedFont = struct {
    name: []const u8, // PostScript name for PDF
    data: []const u8, // Raw TTF data (for FontFile2)
    font: ttf.Font, // Parsed font
    widths: [256]u16, // Widths in 1/1000 em for WinAnsi chars
    allocator: std.mem.Allocator,
    owns_data: bool, // Whether we own the TTF data

    // Metrics scaled to 1000 units (PDF standard)
    ascent: i16,
    descent: i16,
    cap_height: i16,
    bbox: [4]i16, // [x_min, y_min, x_max, y_max]
    italic_angle: i16,
    stem_v: u16,
    flags: FontFlags,

    // Encoding mode
    encoding: FontEncoding = .win_ansi,

    // Subsetting support (WinAnsi mode)
    used_chars: [256]bool = [_]bool{false} ** 256, // Track which WinAnsi chars are used
    subset_data: ?[]const u8 = null, // Generated subset TTF (lazily created)

    // CID mode: track Unicode codepoint → glyph ID mappings
    // Key: Unicode codepoint, Value: original glyph ID from font
    cid_used_glyphs: std.AutoArrayHashMapUnmanaged(u21, u16) = .{},
    cid_glyph_widths: std.AutoArrayHashMapUnmanaged(u16, u16) = .{}, // GID → width in 1/1000 em

    // Glyph → codepoint mapping for ToUnicode (handles calt contextual variants)
    // Key: glyph ID, Value: Unicode codepoint that produced this glyph
    // Needed because calt can produce different glyphs for the same codepoint in different contexts
    glyph_to_codepoint: std.AutoArrayHashMapUnmanaged(u16, u21) = .{},

    // Glyph ID remapping for compact CFF subsets (original GID → new compact GID)
    // Only populated for CFF fonts with subsetting enabled
    gid_remap: std.AutoArrayHashMapUnmanaged(u16, u16) = .{},

    // OpenType feature support
    ot_features: ?*opentype.OpenTypeFeatures = null,
    feature_flags: opentype.FeatureFlags = .{}, // liga=on, kern=on by default

    // Cached flags for fast render-time checks (set by initOpenTypeFeatures)
    has_kern_data: bool = false, // True if font has ANY kerning pairs
    has_mark_data: bool = false, // True if font has ANY mark positioning

    // Ligature glyph → original codepoints mapping for ToUnicode CMap
    // Key: ligature glyph ID (original), Value: array of codepoints that form it
    ligature_codepoints: std.AutoArrayHashMapUnmanaged(u16, []const u21) = .{},

    // Scratch buffers for shaping (reused across calls to avoid allocations)
    scratch_codepoints: std.ArrayListUnmanaged(u21) = .{},
    scratch_glyphs: std.ArrayListUnmanaged(u16) = .{}
}
```

#### `countUsedChars`

Get the number of used characters (WinAnsi mode)

```zig
pub fn countUsedChars(self: *const EmbeddedFont) usize
```

#### `countUsedGlyphs`

Count used glyphs in CID mode

```zig
pub fn countUsedGlyphs(self: *const EmbeddedFont) usize
```

#### `deinit`

```zig
pub fn deinit(self: *EmbeddedFont) void
```

#### `fromFile`

Load and parse a TTF font from file

```zig
pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !*EmbeddedFont
```

#### `fromParsed`

Create from already-parsed font

```zig
pub fn fromParsed(
        allocator: std.mem.Allocator,
        font: ttf.Font,
        data: []const u8,
        owns_data: bool,
    ) !*EmbeddedFont
```

#### `generateCIDToUnicodeCMap`

Generate ToUnicode CMap for CID mode (2-byte glyph IDs → Unicode)
Includes ligature glyph → component codepoints mappings for proper text extraction

```zig
pub fn generateCIDToUnicodeCMap(self: *const EmbeddedFont) ![]const u8
```

#### `generateSubset`

Generate subset font data containing only used glyphs

```zig
pub fn generateSubset(self: *EmbeddedFont) !void
```

#### `generateToUnicodeCMap`

Generate ToUnicode CMap for PDF text extraction/copy-paste
Maps WinAnsi byte values to Unicode codepoints

```zig
pub fn generateToUnicodeCMap(self: *const EmbeddedFont) ![]const u8
```

#### `generateWidthArray`

Generate /W array for CID font (per-glyph widths)
Format: [gid [w1 w2 ...] gid [w1 w2 ...] ...]

```zig
pub fn generateWidthArray(self: *const EmbeddedFont) ![]const u8
```

#### `getCharWidth`

Get character width for a byte value (WinAnsi encoded)

```zig
pub fn getCharWidth(self: *const EmbeddedFont, char: u8) u16
```

#### `getCodepointWidth`

Get width for a Unicode codepoint (CID mode), in 1/1000 em
Returns 0 if codepoint not found in font

```zig
pub fn getCodepointWidth(self: *const EmbeddedFont, codepoint: u21) u16
```

#### `getDefaultWidth`

Get default width for CID font (most common width, or 0)

```zig
pub fn getDefaultWidth(self: *const EmbeddedFont) u16
```

#### `getFontData`

Get font data for PDF embedding (subset if available, else full)
For CFF fonts, returns just the CFF table data (not the full OTF wrapper)

```zig
pub fn getFontData(self: *EmbeddedFont) []const u8
```

#### `getGlyphIdForCodepoint`

Get glyph ID for a Unicode codepoint (CID mode)
Returns remapped GID if subsetting with remapping is enabled, otherwise original GID
Returns 0 (notdef) if codepoint not found

```zig
pub fn getGlyphIdForCodepoint(self: *const EmbeddedFont, codepoint: u21) u16
```

#### `getGlyphWidth`

Get width for a glyph ID (CID mode), in 1/1000 em

```zig
pub fn getGlyphWidth(self: *const EmbeddedFont, gid: u16) u16
```

#### `getGlyphsForText`

Get glyph sequence for text with ligature substitution applied
Returns allocated slice that caller must free

```zig
pub fn getGlyphsForText(self: *EmbeddedFont, text: []const u8) ![]u16
```

#### `getKerning`

Get kerning value between two glyphs (in font units)

```zig
pub fn getKerning(self: *EmbeddedFont, glyph1: u16, glyph2: u16) i16
```

#### `getMarkOffset`

Get mark positioning offset for a mark glyph following a base glyph
Returns (dx, dy) in font units (design units), or null if no positioning applies

```zig
pub fn getMarkOffset(self: *EmbeddedFont, base_glyph: u16, mark_glyph: u16) ?opentype.MarkOffset
```

#### `initOpenTypeFeatures`

Initialize OpenType features (GSUB/GPOS) if not already done

```zig
pub fn initOpenTypeFeatures(self: *EmbeddedFont) !void
```

#### `markCharsUsed`

Mark characters as used (call this when text is written)

```zig
pub fn markCharsUsed(self: *EmbeddedFont, text: []const u8) void
```

#### `markUnicodeCharsUsed`

Mark Unicode codepoints as used (CID mode)
Parses UTF-8 text and records Unicode→GlyphID mappings
Applies ligature substitution if enabled
Mark Unicode characters as used for subsetting and return the computed glyph sequence.
Returns the final glyph sequence (caller owns the memory) for caching.
Mark unicode chars as used for subsetting and return glyph IDs.
output_allocator: allocator for the returned glyph slice (if null, uses self.allocator)

```zig
pub fn markUnicodeCharsUsed(self: *EmbeddedFont, text: []const u8, output_allocator: ?std.mem.Allocator) ![]u16
```

#### `measureTextWidth`

Get text width in points

```zig
pub fn measureTextWidth(self: *const EmbeddedFont, text: []const u8, size: f64) f64
```

#### `setFeature`

Set OpenType feature flag

```zig
pub fn setFeature(self: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void
```

### `FontFlags`

Font flags for FontDescriptor

```zig
pub const FontFlags = packed struct(u32) {
    fixed_pitch: bool = false, // Bit 0: All glyphs have same width
    serif: bool = false, // Bit 1: Serifs present
    symbolic: bool = false, // Bit 2: Non-standard character set
    script: bool = false, // Bit 3: Script/cursive font
    _reserved4: bool = false,
    nonsymbolic: bool = true, // Bit 5: Uses standard Latin encoding
    italic: bool = false, // Bit 6: Italic or oblique
    _reserved7_15: u9 = 0,
    all_cap: bool = false, // Bit 16: No lowercase
    small_cap: bool = false, // Bit 17: Lowercase are small caps
    _reserved18_31: u14 = 0
}
```

#### `toInt`

```zig
pub fn toInt(self: FontFlags) u32
```

## Constants

### `win_ansi_to_unicode`

WinAnsiEncoding (Windows-1252) to Unicode mapping.
Maps byte values 0-255 to Unicode codepoints.
Values 0x00-0x7F are identical to ASCII.
Values 0x80-0x9F contain special characters (not defined in Latin-1).
Values 0xA0-0xFF are Latin-1 Supplement.

```zig
pub const win_ansi_to_unicode: [256]u21 = blk: {
    var map: [256]u21 = undefined;

    // 0x00-0x7F: ASCII (identical)
    for (0..128) |i| {
        map[i] = @intCast(i);
    }

    // 0x80-0x9F: Windows-1252 specific characters
    map[0x80] = 0x20AC; // Euro sign
    map[0x81] = 0xFFFD; // Undefined (use replacement char)
    map[0x82] = 0x201A; // Single low-9 quotation mark
    map[0x83] = 0x0192; // Latin small letter f with hook
    map[0x84] = 0x201E; // Double low-9 quotation mark
    map[0x85] = 0x2026; // Horizontal ellipsis
    map[0x86] = 0x2020; // Dagger
    map[0x87] = 0x2021; // Double dagger
    map[0x88] = 0x02C6; // Modifier letter circumflex accent
    map[0x89] = 0x2030; // Per mille sign
    map[0x8A] = 0x0160; // Latin capital letter S with caron
    map[0x8B] = 0x2039; // Single left-pointing angle quotation mark
    map[0x8C] = 0x0152; // Latin capital ligature OE
    map[0x8D] = 0xFFFD; // Undefined
    map[0x8E] = 0x017D; // Latin capital letter Z with caron
    map[0x8F] = 0xFFFD; // Undefined
    map[0x90] = 0xFFFD; // Undefined
    map[0x91] = 0x2018; // Left single quotation mark
    map[0x92] = 0x2019; // Right single quotation mark
    map[0x93] = 0x201C; // Left double quotation mark
    map[0x94] = 0x201D; // Right double quotation mark
    map[0x95] = 0x2022; // Bullet
    map[0x96] = 0x2013; // En dash
    map[0x97] = 0x2014; // Em dash
    map[0x98] = 0x02DC; // Small tilde
    map[0x99] = 0x2122; // Trade mark sign
    map[0x9A] = 0x0161; // Latin small letter s with caron
    map[0x9B] = 0x203A; // Single right-pointing angle quotation mark
    map[0x9C] = 0x0153; // Latin small ligature oe
    map[0x9D] = 0xFFFD; // Undefined
    map[0x9E] = 0x017E; // Latin small letter z with caron
    map[0x9F] = 0x0178; // Latin capital letter Y with diaeresis

    // 0xA0-0xFF: Latin-1 Supplement (identical to Unicode)
    for (0xA0..256) |i| {
        map[i] = @intCast(i);
    }

    break :blk map;
};
```

