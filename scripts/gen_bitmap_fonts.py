#!/usr/bin/env python3
"""Generate bitmap color-emoji fixture fonts:

  test/fonts/bitmap/SbixTest.ttf  — sbix ('png ' records, one 64ppem strike)
  test/fonts/bitmap/CbdtTest.ttf  — CBDT/CBLC (glyph format 17, index format 1)

Both share the same two 64x64 PNG glyphs (upem 1000, advance 1000):

  A: quadrants — top-left red, top-right green, bottom-left blue,
     bottom-right yellow (any flip/rotation is visible immediately).
  B: solid teal, right half at alpha 128 (exercises the PNG SMask path).
     Placed with a nonzero offset: sbix originOffset (8, -8) px,
     CBDT bearingX=4, bearingY=60.

Run from the repo root: .venv/bin/python scripts/gen_bitmap_fonts.py
"""

import io
from pathlib import Path

from PIL import Image
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable

OUT_DIR = Path(__file__).parent.parent / "test" / "fonts" / "bitmap"
UPEM = 1000
PPEM = 64
SIZE = 64


def png_a():
    img = Image.new("RGBA", (SIZE, SIZE))
    half = SIZE // 2
    for x in range(SIZE):
        for y in range(SIZE):
            if y < half:
                c = (255, 0, 0, 255) if x < half else (0, 128, 0, 255)
            else:
                c = (0, 0, 255, 255) if x < half else (255, 200, 0, 255)
            img.putpixel((x, y), c)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def png_b():
    img = Image.new("RGBA", (SIZE, SIZE))
    for x in range(SIZE):
        for y in range(SIZE):
            a = 255 if x < SIZE // 2 else 128
            img.putpixel((x, y), (0, 150, 136, a))  # teal
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def base_font():
    fb = FontBuilder(UPEM, isTTF=True)
    glyph_order = [".notdef", "A", "B"]
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({ord("A"): "A", ord("B"): "B"})
    pen = TTGlyphPen(None)  # empty outlines; bitmaps carry the artwork
    fb.setupGlyf({name: pen.glyph() for name in glyph_order})
    fb.setupHorizontalMetrics({name: (1000, 0) for name in glyph_order})
    fb.setupHorizontalHeader(ascent=900, descent=-100)
    fb.setupOS2(sTypoAscender=900, sTypoDescender=-100, usWinAscent=900, usWinDescent=100)
    fb.setupPost()
    return fb


def build_sbix(png_by_name):
    fb = base_font()
    fb.setupNameTable({"familyName": "SbixTest", "styleName": "Regular"})
    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1
    from fontTools.ttLib.tables.sbixStrike import Strike
    from fontTools.ttLib.tables.sbixGlyph import Glyph

    strike = Strike(ppem=PPEM, resolution=72)
    strike.glyphs["A"] = Glyph(
        glyphName="A", graphicType="png ", originOffsetX=0, originOffsetY=0,
        imageData=png_by_name["A"],
    )
    strike.glyphs["B"] = Glyph(
        glyphName="B", graphicType="png ", originOffsetX=8, originOffsetY=-8,
        imageData=png_by_name["B"],
    )
    sbix.strikes = {PPEM: strike}
    fb.font["sbix"] = sbix
    out = OUT_DIR / "SbixTest.ttf"
    fb.save(str(out))
    print(f"Wrote {out}")


CBDT_TTX = """<?xml version="1.0" encoding="UTF-8"?>
<ttFont>
  <CBDT>
    <header version="3.0"/>
    <strikedata index="0">
      <cbdt_bitmap_format_17 name="A">
        <SmallGlyphMetrics>
          <height value="64"/>
          <width value="64"/>
          <BearingX value="0"/>
          <BearingY value="64"/>
          <Advance value="64"/>
        </SmallGlyphMetrics>
        <rawimagedata>
          {png_a}
        </rawimagedata>
      </cbdt_bitmap_format_17>
      <cbdt_bitmap_format_17 name="B">
        <SmallGlyphMetrics>
          <height value="64"/>
          <width value="64"/>
          <BearingX value="4"/>
          <BearingY value="60"/>
          <Advance value="64"/>
        </SmallGlyphMetrics>
        <rawimagedata>
          {png_b}
        </rawimagedata>
      </cbdt_bitmap_format_17>
    </strikedata>
  </CBDT>
  <CBLC>
    <header version="3.0"/>
    <strike index="0">
      <bitmapSizeTable>
        <sbitLineMetrics direction="hori">
          <ascender value="57"/>
          <descender value="-7"/>
          <widthMax value="64"/>
          <caretSlopeNumerator value="0"/>
          <caretSlopeDenominator value="0"/>
          <caretOffset value="0"/>
          <minOriginSB value="0"/>
          <minAdvanceSB value="0"/>
          <maxBeforeBL value="0"/>
          <minAfterBL value="0"/>
          <pad1 value="0"/>
          <pad2 value="0"/>
        </sbitLineMetrics>
        <sbitLineMetrics direction="vert">
          <ascender value="0"/>
          <descender value="0"/>
          <widthMax value="0"/>
          <caretSlopeNumerator value="0"/>
          <caretSlopeDenominator value="0"/>
          <caretOffset value="0"/>
          <minOriginSB value="0"/>
          <minAdvanceSB value="0"/>
          <maxBeforeBL value="0"/>
          <minAfterBL value="0"/>
          <pad1 value="0"/>
          <pad2 value="0"/>
        </sbitLineMetrics>
        <colorRef value="0"/>
        <startGlyphIndex value="1"/>
        <endGlyphIndex value="2"/>
        <ppemX value="64"/>
        <ppemY value="64"/>
        <bitDepth value="32"/>
        <flags value="1"/>
      </bitmapSizeTable>
      <eblc_index_sub_table_1 imageFormat="17" firstGlyphIndex="1" lastGlyphIndex="2">
        <glyphLoc id="1" name="A"/>
        <glyphLoc id="2" name="B"/>
      </eblc_index_sub_table_1>
    </strike>
  </CBLC>
</ttFont>
"""


def hexdump(data):
    return "\n          ".join(
        data[i : i + 32].hex() for i in range(0, len(data), 32)
    )


def build_cbdt(png_by_name):
    fb = base_font()
    fb.setupNameTable({"familyName": "CbdtTest", "styleName": "Regular"})
    ttx = CBDT_TTX.format(png_a=hexdump(png_by_name["A"]), png_b=hexdump(png_by_name["B"]))
    ttx_path = OUT_DIR / "_cbdt_tables.ttx"
    ttx_path.write_text(ttx)
    fb.font.importXML(str(ttx_path))
    ttx_path.unlink()
    out = OUT_DIR / "CbdtTest.ttf"
    fb.save(str(out))
    print(f"Wrote {out}")


def verify():
    from fontTools.ttLib import TTFont

    f = TTFont(OUT_DIR / "SbixTest.ttf")
    strike = f["sbix"].strikes[PPEM]
    assert strike.glyphs["A"].graphicType == "png "
    assert strike.glyphs["B"].originOffsetX == 8
    assert strike.glyphs["B"].originOffsetY == -8
    print("sbix verify OK:", {n: len(g.imageData) for n, g in strike.glyphs.items() if g.imageData})

    f = TTFont(OUT_DIR / "CbdtTest.ttf")
    data = f["CBDT"].strikeData[0]
    assert data["A"].metrics.height == 64 and data["A"].metrics.BearingY == 64
    assert data["B"].metrics.BearingX == 4 and data["B"].metrics.BearingY == 60
    size = f["CBLC"].strikes[0].bitmapSizeTable
    assert size.ppemX == 64 and size.bitDepth == 32
    print("CBDT verify OK:", {n: len(g.imageData) for n, g in data.items()})


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    pngs = {"A": png_a(), "B": png_b()}
    build_sbix(pngs)
    build_cbdt(pngs)
    verify()


if __name__ == "__main__":
    main()
