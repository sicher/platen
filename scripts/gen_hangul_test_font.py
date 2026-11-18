#!/usr/bin/env python3
"""
Synthetic Hangul test font (test/fonts/hangul/HangulTest.ttf) for the
HarfBuzz differential test of the Hangul shaper (src/hangul.zig, cases in
scripts/gen_shaping_reference.py).

Real Korean fonts on macOS have precomposed syllables but no jamo
features; this one exercises every path of HarfBuzz's Hangul shaper:

  - conjoining jamo: modern L (U+1100..1112, without U+1103), V
    (U+1161..1175) and T (U+11A8..11C2), Old Hangul L U+1113 and
    U+A960, V U+1176 and U+D7B0, T U+11C3 and U+D7CB;
  - some precomposed syllables, not others: 가 각 하 한 나 다 present,
    낙 닥 글 absent, so composing, decomposing (a syllable the font lacks,
    an LV before a T it cannot take) and the normalizer's LV + T
    decomposition (닥: no glyph for its L) all happen;
  - ljmo, vjmo, tjmo (only under the 'hang' script): single substitutions
    to .ljmo/.vjmo/.tjmo forms with their own advances, and an ljmo
    contextual one (U+1113 before U+D7B0); a global ccmp ligature of
    Old Hangul V U+1176 + T U+11C3 (formed before vjmo/tjmo, for its
    source text);
  - tone marks U+302E (spacing) and U+302F (zero advance), a dotted
    circle U+25CC;
  - 'calt' a -> a.calt under both scripts (the Hangul shaper turns it
    off); a combining acute with an advance and GDEF mark class (the
    Hangul shaper zeroes no marks);
  - kerning: 가 가 under 'hang', a a under DFLT, to check the language
    system.

Glyph outlines are empty: shaping only looks at glyph IDs and advances.

Run with: .venv/bin/python scripts/gen_hangul_test_font.py
"""

from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

OUT = Path("test/fonts/hangul/HangulTest.ttf")

L = [c for c in range(0x1100, 0x1113) if c != 0x1103] + [0x1113, 0xA960]
V = list(range(0x1161, 0x1176)) + [0x1176, 0xD7B0]
T = list(range(0x11A8, 0x11C3)) + [0x11C3, 0xD7CB]
SYLLABLES = [0xAC00, 0xAC01, 0xD558, 0xD55C, 0xB098, 0xB2E4]  # 가 각 하 한 나 다
OTHER = {0x20: 300, 0x61: 520, 0x0301: 260, 0x302E: 200, 0x302F: 0, 0x25CC: 700}


def name(cp):
    return f"uni{cp:04X}" if cp <= 0xFFFF else f"u{cp:05X}"


def main():
    cmap = {}
    advances = {".notdef": 500}
    for cp, adv in OTHER.items():
        cmap[cp] = name(cp)
        advances[name(cp)] = adv
    for i, cp in enumerate(L):
        cmap[cp] = name(cp)
        advances[name(cp)] = 600 + i
        advances[name(cp) + ".ljmo"] = 450 + i
    for i, cp in enumerate(V):
        cmap[cp] = name(cp)
        advances[name(cp)] = 400 + i
        advances[name(cp) + ".vjmo"] = 0
    for i, cp in enumerate(T):
        cmap[cp] = name(cp)
        advances[name(cp)] = 380 + i
        advances[name(cp) + ".tjmo"] = 30 + i
    for i, cp in enumerate(SYLLABLES):
        cmap[cp] = name(cp)
        advances[name(cp)] = 1000 + i
    advances["uni0061.calt"] = 530
    advances["uni1113.ljmo2"] = 470
    advances["uni1176_uni11C3"] = 640

    order = [".notdef"] + sorted(n for n in advances if n != ".notdef")
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({g: empty for g in order})
    fb.setupHorizontalMetrics({g: (advances[g], 0) for g in order})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupNameTable({"familyName": "Hangul Test", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=880, usWinDescent=120)
    fb.setupPost()

    def subs(cps, suffix):
        return "\n".join(f"    sub {name(c)} by {name(c)}.{suffix};" for c in cps)

    fea = f"""
languagesystem DFLT dflt;
languagesystem hang dflt;

table GDEF {{
    GlyphClassDef , , [uni0301], ;
}} GDEF;

feature ccmp {{
    script hang;
    sub uni1176 uni11C3 by uni1176_uni11C3;
}} ccmp;

feature ljmo {{
    script hang;
    sub uni1113' uniD7B0 by uni1113.ljmo2;
{subs(L, "ljmo")}
}} ljmo;

feature vjmo {{
    script hang;
{subs(V, "vjmo")}
}} vjmo;

feature tjmo {{
    script hang;
{subs(T, "tjmo")}
}} tjmo;

feature calt {{
    script DFLT;
    sub uni0061 by uni0061.calt;
    script hang;
    sub uni0061 by uni0061.calt;
}} calt;

feature kern {{
    script DFLT;
    pos uni0061 uni0061 -20;
    script hang;
    pos uniAC00 uniAC00 -50;
}} kern;
"""
    addOpenTypeFeaturesFromString(fb.font, fea)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(OUT)
    print(f"{OUT}: {len(order)} glyphs")


if __name__ == "__main__":
    main()
