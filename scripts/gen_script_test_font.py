#!/usr/bin/env python3
"""
Synthetic script-selection test font (test/fonts/script/ScriptTest.ttf)
for the HarfBuzz differential test (scripts/gen_shaping_reference.py).

Its 'latn' and 'DFLT' language systems differ, so the reference shows
which one shaping picked:

  calt   a -> a.latn under latn, a -> a.dflt under DFLT
  kern   b b -30 under latn, -10 under DFLT; 1 1 -20 under DFLT only

HarfBuzz tries a script's own tag first (Latin text: latn, then DFLT),
and DFLT for text with no script character ("11"); platen must agree.

Glyph outlines are empty: shaping only looks at glyph IDs and advances.

Run with: .venv/bin/python scripts/gen_script_test_font.py
"""

from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

OUT = Path("test/fonts/script/ScriptTest.ttf")

GLYPHS = {".notdef": 500, "space": 250, "period": 200, "one": 500, "a": 520, "b": 540,
          "a.latn": 600, "a.dflt": 640}
CMAP = {0x20: "space", 0x2E: "period", 0x31: "one", 0x61: "a", 0x62: "b"}

FEA = """
languagesystem DFLT dflt;
languagesystem latn dflt;

feature calt {
    script DFLT;
    sub a by a.dflt;
    script latn;
    sub a by a.latn;
} calt;

feature kern {
    script DFLT;
    pos b b -10;
    pos one one -20;
    script latn;
    pos b b -30;
} kern;
"""


def main():
    order = list(GLYPHS)
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(CMAP)
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({g: empty for g in order})
    fb.setupHorizontalMetrics({g: (w, 0) for g, w in GLYPHS.items()})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupNameTable({"familyName": "Script Test", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=880, usWinDescent=120)
    fb.setupPost()
    addOpenTypeFeaturesFromString(fb.font, FEA)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(OUT)
    print(f"{OUT}: {len(order)} glyphs")


if __name__ == "__main__":
    main()
