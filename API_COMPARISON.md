# zpdf vs fpdf2 API Comparison

Comprehensive comparison identifying functional gaps between zpdf (Zig) and fpdf2 (Python).

## Legend
- ✅ = Fully implemented in zpdf
- ⚠️ = Partially implemented
- ❌ = Not implemented (functional gap)

---

## 1. Document Setup & Metadata

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Page creation | `add_page()` | ✅ `addPage()` | |
| Page sizes (A3-A5, Letter, Legal, Tabloid) | ✅ | ✅ | |
| Custom page sizes | tuple `(w, h)` | ✅ `PageSize{.width, .height}` | |
| Landscape orientation | `orientation="landscape"` | ✅ `PageSize.landscape()` | |
| Per-page orientation | `add_page(orientation=)` | ✅ `addPageWithSize()` | |
| Document title | `set_title()` | ✅ `setMetadata()` | |
| Document author | `set_author()` | ✅ `setMetadata()` | |
| Document subject | `set_subject()` | ✅ `setMetadata()` | |
| Document keywords | `set_keywords()` | ✅ `setMetadata()` | |
| Document creator | `set_creator()` | ✅ `setMetadata()` | |
| Document producer | `set_producer()` | ✅ `setMetadata()` | zpdf default |
| Creation date | `set_creation_date()` | ✅ `setMetadata()` | auto-generated if not set |
| **XMP metadata** | `set_xmp_metadata()` | ❌ | **GAP** |
| **Document language** | `set_lang()` | ❌ | **GAP** |

---

## 2. Page Layout & Margins

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Set margins | `set_margins()` | ✅ `setMargins()` | |
| Left margin | `set_left_margin()` | ✅ via `Margins` struct | |
| Top margin | `set_top_margin()` | ✅ via `Margins` struct | |
| Right margin | `set_right_margin()` | ✅ via `Margins` struct | |
| Get page region | - | ✅ `getPageRegion()` | zpdf feature |
| **Auto page break** | `set_auto_page_break()` | ❌ | **GAP** - zpdf has manual `writeFlow` |
| **Page background** | `set_page_background()` | ❌ | **GAP** |
| **Alias for total pages** | `alias_nb_pages()` | ❌ | **GAP** - "{nb}" placeholder |
| Page number | `page_no()` | ✅ `pageNo()` | |
| **Page labels** | `set_page_label()`, `get_page_label()` | ❌ | **GAP** |

---

## 3. Cursor & Positioning

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Set position | `set_xy()` | ✅ `setXY()` | |
| Set X | `set_x()` | ✅ `setX()` | |
| Set Y | `set_y()` | ✅ `setY()` | |
| Get X | `get_x()` | ✅ `getX()` | |
| Get Y | `get_y()` | ✅ `getY()` | |
| **Line break (Ln)** | `ln()` | ❌ | **GAP** - manual Y adjustment |

---

## 4. Fonts

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Standard fonts (Base 14) | ✅ | ✅ | |
| TrueType embedding | `add_font()` | ✅ `loadFont()` | |
| OpenType (CFF) embedding | ✅ | ✅ | CID fonts |
| Font subsetting | ✅ auto | ✅ auto | |
| Set font | `set_font()` | ✅ `setFont()` / `setEmbeddedFont()` | |
| Unicode support | ✅ | ✅ | via CID fonts |
| Ligatures (liga) | ✅ via text shaping | ✅ | |
| Kerning (kern) | ✅ via text shaping | ✅ | |
| Contextual alternates (calt) | ✅ | ✅ | |
| Mark positioning (mark/mkmk) | ✅ | ✅ | |
| Discretionary ligatures (dlig) | ⚠️ | ✅ | |
| Tabular/proportional nums | ⚠️ | ✅ | tnum/pnum |
| Fractions (frac) | ⚠️ | ✅ | |
| Slashed zero | ⚠️ | ✅ | |
| Stylistic sets (ss01-08) | ⚠️ | ⚠️ ss01 only | |
| **Font stretching** | `set_stretching()` | ❌ | **GAP** |
| **Character spacing** | `set_char_spacing()` | ✅ `setCharSpacing()` | |
| **Underline style** | ✅ via markdown/style | ❌ | **GAP** |
| **Strikethrough** | ✅ via markdown | ❌ | **GAP** |

---

## 5. Text Rendering

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Simple text at position | `text()` | ✅ `writeAt()` | |
| Write text (flowing) | `write()` | ✅ `write()` | |
| Cell | `cell()` | ⚠️ | `Region` with `border`/`fill` + `writeLine` |
| Multi-cell | `multi_cell()` | ✅ | `Region` with `border`/`fill` + `writeParagraph` |
| Word wrapping | ✅ | ✅ | |
| Character wrapping | `wrapmode="CHAR"` | ✅ | fallback for long words |
| Text alignment (L/C/R/J) | ✅ | ✅ | |
| Vertical alignment | ✅ | ✅ | top/middle/bottom |
| Soft hyphen support | ✅ | ✅ | U+00AD |
| Regular hyphen breaking | - | ✅ `break_on_hyphens` | zpdf feature |
| First line indent | ✅ | ✅ | |
| Optimal line breaking | - | ✅ Knuth-Plass | zpdf feature |
| Text width measurement | `get_string_width()` | ✅ `getTextWidth()` | |
| Wrapped text measurement | - | ✅ `measureWrappedText()` | zpdf feature |
| Line height control | ✅ | ✅ `setLineHeight()` | |
| **HTML rendering** | `write_html()` | ❌ | **GAP** |
| **Markdown in cells** | ✅ bold/italic/strike/underline | ❌ | **GAP** |

---

## 6. Text Regions & Flow

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Page region | - | ✅ `getPageRegion()` | |
| Custom regions | - | ✅ `Region` struct | |
| Region with padding | - | ✅ `Padding` | |
| Region with border | - | ✅ `Border` | |
| Region fill | - | ✅ fill color | |
| Write to region | `text_columns()` | ✅ `writeParagraph()` | |
| Overflow handling | ✅ | ✅ `WriteResult.overflow` | |
| Auto pagination | ✅ | ✅ `writeFlow()` | |
| **Multi-column layout** | `text_columns()` | ❌ | **GAP** - manual only |
| **Shaped regions** | ✅ circle/polygon | ❌ | **GAP** |
| **Header/footer callbacks** | `header()`, `footer()` | ❌ | **GAP** |

---

## 7. Colors

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| RGB colors | ✅ | ✅ | |
| Grayscale | ✅ | ✅ | |
| CMYK colors | ✅ | ✅ | |
| Set text color | `set_text_color()` | ✅ `setTextColor()` | |
| Set fill color | `set_fill_color()` | ✅ `setFillColor()` | |
| Set draw color | `set_draw_color()` | ✅ `setDrawColor()` | |
| Named colors | ✅ `DeviceRGB` presets | ✅ black/white/red/green/blue | |
| **Color names (CSS)** | ✅ many | ⚠️ limited | zpdf has basic presets |

---

## 8. Graphics - Lines & Shapes

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Line | `line()` | ✅ `drawLine()` | |
| Rectangle | `rect()` | ✅ `drawRect()` | |
| Circle | `circle()` | ✅ `drawCircle()` | |
| Ellipse | `ellipse()` | ✅ `drawEllipse()` | |
| Polygon | `polygon()` | ✅ `drawPolygon()` | |
| **Polyline** | `polyline()` | ❌ | **GAP** - use Path |
| Rounded rectangle | `rect(round_corners=)` | ✅ `drawRoundedRect()` | |
| **Regular polygon** | `regular_polygon()` | ❌ | **GAP** - use drawPolygon manually |
| **Star** | `star()` | ❌ | **GAP** |
| **Arc** | `arc()` | ❌ | **GAP** |
| **Solid arc (pie)** | `solid_arc()` | ❌ | **GAP** |
| **Bezier curves** | `bezier()` | ✅ via Path API | Path.curveTo/quadTo |
| Line width | `set_line_width()` | ✅ `setLineWidth()` | |
| Dash pattern | `set_dash_pattern()` | ✅ `setDashPattern()` | |
| Line cap | ✅ | ✅ `setLineCap()` | |
| Line join | ✅ | ✅ `setLineJoin()` | |
| Fill/stroke styles | ✅ | ✅ `DrawStyle` | |

---

## 9. Path Drawing

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Create path | `new_path()` / `drawing_context()` | ✅ `createPath()` | |
| Move to | ✅ | ✅ `moveTo()` | |
| Line to | ✅ | ✅ `lineTo()` | |
| Cubic bezier | ✅ | ✅ `curveTo()` | |
| Quadratic bezier | ✅ | ✅ `quadTo()` | |
| Close path | ✅ | ✅ `closePath()` | |
| Draw path | `draw_path()` | ✅ `drawPath()` | |
| **Glyph paths** | `glyph_drawing_context()` | ❌ | **GAP** |

---

## 10. Gradients & Patterns

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Linear gradient | ✅ | ✅ | |
| Radial gradient | ✅ | ✅ | |
| Gradient color stops | ✅ | ✅ | |
| Fill rect with gradient | ✅ | ✅ `fillRectGradient()` | |
| **Pattern fills** | ✅ | ❌ | **GAP** |
| **Blend modes** | ✅ (15 modes) | ❌ | **GAP** |

---

## 11. Images

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| JPEG embedding | ✅ | ✅ | |
| PNG embedding | ✅ | ✅ | |
| PNG alpha/transparency | ✅ SMask | ✅ SMask | |
| Load from file | `image()` | ✅ `loadImage()` | |
| Draw image | ✅ | ✅ `drawImage()` | |
| Auto aspect ratio | ✅ | ✅ | w=0 or h=0 |
| ICC profiles | ✅ | ✅ | |
| Image caching/reuse | ✅ | ⚠️ manual | |
| **Load from URL** | ✅ | ❌ | **GAP** |
| **Load from bytes/PIL** | ✅ | ✅ `fromMemory()` | |
| **TIFF support** | ✅ | ❌ | **GAP** |
| **GIF support** | ✅ via Pillow | ❌ | **GAP** |
| **BMP support** | ✅ via Pillow | ❌ | **GAP** |
| **Image clipping** | ✅ rect/round/ellipse | ❌ | **GAP** |
| **Alt text** | ✅ | ❌ | **GAP** - accessibility |

---

## 12. SVG Support

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Basic shapes | ✅ | ✅ | rect, circle, ellipse, line |
| Path element | ✅ | ✅ | full d-attribute |
| Polyline/polygon | ✅ | ✅ | |
| Text element | ✅ | ✅ | |
| Transforms | ✅ | ✅ | translate, scale, rotate, skew, matrix |
| Fill/stroke styles | ✅ | ✅ | |
| Opacity/transparency | ✅ | ✅ | |
| use/defs elements | ✅ | ✅ | |
| ViewBox support | ✅ | ✅ | |
| **Gradients in SVG** | ✅ | ⚠️ | Limited support |
| **Filters** | ❌ | ❌ | Neither supports |
| **CSS styling** | ⚠️ | ❌ | **GAP** |

---

## 13. Links & Navigation

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **External hyperlinks** | ✅ | ❌ | **GAP** |
| **Internal links** | `add_link()`, `set_link()` | ❌ | **GAP** |
| **Link in cell** | ✅ | ❌ | **GAP** |
| **Link region** | `link()` | ❌ | **GAP** |
| **File links** | ✅ | ❌ | **GAP** |

---

## 14. Document Outline & TOC

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Bookmarks/outline** | `start_section()` | ❌ | **GAP** |
| **Nested sections** | ✅ levels | ❌ | **GAP** |
| **Table of contents** | `insert_toc_placeholder()` | ❌ | **GAP** |
| **Auto TOC from HTML** | ✅ `<toc>` | ❌ | **GAP** |

---

## 15. Annotations

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Text annotation (popup)** | `text_annotation()` | ❌ | **GAP** |
| **Free text annotation** | ✅ | ❌ | **GAP** |
| **Highlight** | `highlight()` | ❌ | **GAP** |
| **Underline annotation** | ✅ | ❌ | **GAP** |
| **Strikeout annotation** | ✅ | ❌ | **GAP** |
| **Ink annotation** | ✅ | ❌ | **GAP** |
| **File attachment** | ✅ | ❌ | **GAP** |

---

## 16. Security & Encryption

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Password protection** | ✅ owner/user | ❌ | **GAP** |
| **Permission flags** | ✅ print/modify/copy/etc | ❌ | **GAP** |
| **RC4 encryption** | ✅ | ❌ | **GAP** |
| **AES-128 encryption** | ✅ | ❌ | **GAP** |
| **AES-256 encryption** | ✅ | ❌ | **GAP** |
| **Digital signatures** | ✅ | ❌ | **GAP** |

---

## 17. Barcodes

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Code 39** | ✅ native | ❌ | **GAP** |
| **Interleaved 2 of 5** | ✅ native | ❌ | **GAP** |
| **Code 128** | ✅ via library | ❌ | **GAP** |
| **QR Code** | ✅ via library | ❌ | **GAP** |
| **PDF-417** | ✅ via library | ❌ | **GAP** |
| **DataMatrix** | ✅ via library | ❌ | **GAP** |

---

## 18. Tables

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Table API** | `table()` context manager | ❌ | **GAP** |
| **Cell borders** | ✅ | ❌ | **GAP** |
| **Column/row spanning** | ✅ | ❌ | **GAP** |
| **Header rows** | ✅ | ❌ | **GAP** |
| **Auto page break in table** | ✅ | ❌ | **GAP** |
| **Images in cells** | ✅ | ❌ | **GAP** |
| **Pandas integration** | ✅ | N/A | Python-specific |

---

## 19. Display & Viewer Settings

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **Zoom mode** | `set_display_mode()` | ❌ | **GAP** |
| **Page layout** | single/continuous/two-column | ❌ | **GAP** |
| **Viewer preferences** | hide toolbar, etc | ❌ | **GAP** |
| **Presentation mode** | ✅ transitions | ❌ | **GAP** |
| **Named actions** | NextPage/PrevPage/etc | ❌ | **GAP** |

---

## 20. Compression

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| Stream compression | ✅ FlateDecode | ✅ FlateDecode | |
| Toggle compression | `set_compression()` | ⚠️ auto | zpdf auto-compresses |
| Image filter config | `set_image_filter()` | ⚠️ | JPEG stays DCT, PNG recompresses |

---

## 21. PDF Standards

| Feature | fpdf2 | zpdf | Notes |
|---------|-------|------|-------|
| **PDF/A-1 compliance** | ✅ | ❌ | **GAP** |
| **PDF/A-2 compliance** | ✅ | ❌ | **GAP** |
| **PDF/A-3 compliance** | ✅ | ❌ | **GAP** |
| **Output intents** | `add_output_intent()` | ❌ | **GAP** |

---

## Summary of Gaps

### High Priority (Common Features)
1. **Links** - hyperlinks (external URLs, internal page links)
2. **Table API** - structured table creation
3. **Document outline/bookmarks** - navigation structure
4. **Auto page break** - automatic page breaks with callbacks
5. **Header/footer callbacks** - repeated content per page

### Medium Priority (Useful Features)
6. **Annotations** - text annotations, highlights, attachments
7. **Arc/pie shapes** - charts and diagrams
8. **Multi-column text** - magazine/newspaper layouts
9. **HTML rendering** - `write_html()` subset
10. **Underline/strikethrough** - text decoration
11. **Image clipping** - circular avatars, etc.

### Lower Priority (Specialized)
12. **Encryption** - password protection, permissions
13. **PDF/A compliance** - archival standards
14. **Barcodes** - Code39, QR, etc. (can use external libs + image)
15. **Digital signatures** - document signing
16. **Display/viewer settings** - zoom, layout preferences
17. **Presentation mode** - slide transitions
18. **Pattern fills** - repeated patterns
23. **Blend modes** - image compositing

### zpdf Advantages (Features NOT in fpdf2)
1. **Knuth-Plass optimal line breaking** - better paragraph layout
2. **Wrapped text measurement** - `measureWrappedText()` before rendering
3. **More OpenType features** - tnum/pnum, frac, zero, dlig exposed
4. **Break on hyphens option** - control regular hyphen breaking
5. **Region-based layout** - explicit region model with overflow

---

## Recommended Implementation Order

### Phase 1: Links & Navigation
1. External hyperlinks
2. Internal links (page references)
3. Document outline/bookmarks

### Phase 2: Page Flow
4. Auto page break with margin
5. Header/footer callbacks

### Phase 3: Enhanced Text
6. Underline/strikethrough text styles

### Phase 4: Tables
7. Basic table API
8. Column spanning
9. Row spanning
10. Header row repetition

### Phase 5: Additional Graphics
11. Arc and solid_arc
12. Regular polygon helper
13. Polyline

### Phase 6: Advanced Features
14. Text annotations
15. Highlight annotations
16. File attachments
17. Encryption (basic)
