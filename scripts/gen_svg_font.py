#!/usr/bin/env python3
"""Generate test/fonts/svg/SvgTest.ttf — an OT-SVG test font exercising the
supported path AND every fallback path of zapdf's SVG-table handling.

Glyphs (upem 1000, each with a real square outline for the mono fallback):
  A (gid 1): supported — solid-fill SVG document.
  B (gid 2): fill-opacity 0.5 → transparency → mono-outline fallback.
  C (gid 3): gzip-compressed document → fallback.
  D (gid 4), E (gid 5): one document covering gids 4-5 → multi-glyph
      fallback.

Run from the repo root: .venv/bin/python scripts/gen_svg_font.py
"""

import gzip
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable

OUT = Path(__file__).parent.parent / "test" / "fonts" / "svg" / "SvgTest.ttf"
UPEM = 1000


def square_glyph():
    pen = TTGlyphPen(None)
    pen.moveTo((0, 0))
    pen.lineTo((900, 0))
    pen.lineTo((900, 900))
    pen.lineTo((0, 900))
    pen.closePath()
    return pen.glyph()


def doc(gid, extra=""):
    # OT-SVG glyph space is y-down: the square sits above the baseline at
    # negative y.
    return (
        f'<svg id="glyph{gid}" xmlns="http://www.w3.org/2000/svg">'
        f'<path d="M0 0L900 0L900 -900L0 -900Z" fill="#c90900"{extra}/></svg>'
    )


def main():
    fb = FontBuilder(UPEM, isTTF=True)
    glyph_order = [".notdef", "A", "B", "C", "D", "E"]
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({ord(g): g for g in glyph_order if len(g) == 1})
    fb.setupGlyf({name: square_glyph() for name in glyph_order})
    fb.setupHorizontalMetrics({name: (1000, 0) for name in glyph_order})
    fb.setupHorizontalHeader(ascent=900, descent=-100)
    fb.setupNameTable({"familyName": "SvgTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=900, sTypoDescender=-100, usWinAscent=900, usWinDescent=100)
    fb.setupPost()

    svg = newTable("SVG ")
    svg.docList = [
        (doc(1), 1, 1),
        (doc(2, ' fill-opacity="0.5"'), 2, 2),
        (gzip.compress(doc(3).encode()), 3, 3),  # raw bytes: fontTools must not re-encode
        (doc(4), 4, 5),
    ]
    fb.font["SVG "] = svg

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(OUT))
    print(f"Wrote {OUT}")

    # Verify round-trip. Note: fontTools transparently gunzips documents on
    # load, so check the raw table bytes for the gzip magic instead.
    from fontTools.ttLib import TTFont

    f = TTFont(OUT)
    entries = f["SVG "].docList
    assert len(entries) == 4
    assert b"\x1f\x8b\x08" in OUT.read_bytes(), "gzip doc was re-encoded"
    print("verify OK:", [(e.startGlyphID, e.endGlyphID, len(e.data)) for e in entries])


if __name__ == "__main__":
    main()
