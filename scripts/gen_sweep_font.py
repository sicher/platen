#!/usr/bin/env python3
"""Generate test/fonts/sweep/SweepTest.ttf — a minimal COLR v1 test font
whose glyphs are painted with PaintSweepGradient (which no vendored real
font uses). Used by the sweep-gradient unit and integration tests.

Glyphs (upem 1000, each a 900x900 square):
  A (gid 1): full-circle sweep 0°..360°, red -> blue, pad.
  B (gid 2): partial sweep 0°..90°, red -> blue, pad
             (tests the extend behavior outside the angular range).
  C (gid 3): partial sweep 110°..230°, red -> blue, pad — the spec's example
             arc; angles below 110° must get the offset-0 color (red) and
             angles above 230° the offset-1 color (blue), locking in the
             absolute [0°, 360°) sampling domain.

CPAL palette 0: [0] = red (255,0,0), [1] = blue (0,0,255).

Run from the repo root: .venv/bin/python scripts/gen_sweep_font.py
"""

from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.colorLib.builder import buildCOLR, buildCPAL

OUT = Path(__file__).parent.parent / "test" / "fonts" / "sweep" / "SweepTest.ttf"
UPEM = 1000


def square_glyph():
    pen = TTGlyphPen(None)
    pen.moveTo((0, 0))
    pen.lineTo((900, 0))
    pen.lineTo((900, 900))
    pen.lineTo((0, 900))
    pen.closePath()
    return pen.glyph()


def sweep(start_angle, end_angle):
    return {
        "Format": 10,  # PaintGlyph (clip to the outline)
        "Glyph": None,  # filled in per glyph
        "Paint": {
            "Format": 8,  # PaintSweepGradient
            "ColorLine": {
                "ColorStop": [(0.0, 0), (1.0, 1)],  # red -> blue
                "Extend": "pad",
            },
            "centerX": 450,
            "centerY": 450,
            "startAngle": start_angle,
            "endAngle": end_angle,
        },
    }


def main():
    fb = FontBuilder(UPEM, isTTF=True)
    glyph_order = [".notdef", "A", "B", "C"]
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({ord("A"): "A", ord("B"): "B", ord("C"): "C"})
    fb.setupGlyf({name: square_glyph() for name in glyph_order})
    fb.setupHorizontalMetrics({name: (1000, 0) for name in glyph_order})
    fb.setupHorizontalHeader(ascent=900, descent=-100)
    fb.setupNameTable({"familyName": "SweepTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=900, sTypoDescender=-100, usWinAscent=900, usWinDescent=100)
    fb.setupPost()

    paint_a = sweep(0, 360)
    paint_a["Glyph"] = "A"
    paint_b = sweep(0, 90)
    paint_b["Glyph"] = "B"
    paint_c = sweep(110, 230)
    paint_c["Glyph"] = "C"
    fb.font["COLR"] = buildCOLR({"A": paint_a, "B": paint_b, "C": paint_c})
    fb.font["CPAL"] = buildCPAL([[(1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0)]])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(OUT))
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
