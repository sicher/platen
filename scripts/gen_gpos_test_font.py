#!/usr/bin/env python3
"""
Synthetic GPOS test font (test/fonts/gpos/GposTest.ttf) for the HarfBuzz
differential test of positions (scripts/gen_shaping_reference.py,
test/shaping/harfbuzz_positions.txt).

Real fonts use only some lookup types, formats and flags; this one has
each, behind its own stylistic set, so the reference exercises every path
of src/gpos.zig against HarfBuzz:

  ss01  single positioning, formats 1 and 2 (YAdvance ignored horizontally)
  ss02  pair positioning format 1, with a value for the second glyph
  ss03  pair positioning format 2 (classes)
  ss04  pair under IgnoreMarks (kerns across a mark)
  ss05  pair under UseMarkFilteringSet (only filtered marks are skipped)
  ss06  cursive attachment, left to right
  ss07  mark-to-base
  ss08  mark-to-ligature (a GSUB liga ligature, marks per component)
  ss09  mark-to-mark
  ss10  chained context positioning, with backtrack and lookahead
  ss11  extension lookups (type 9)
  ss12  pair under MarkAttachmentType (only marks of the class block)
  ss13  mark-to-base after a multiple substitution: the mark goes on the
        first glyph of the sequence
  ss14  cursive attachment with the RightToLeft flag

Marks have an advance (300), which the default shaper zeroes (GDEF class
mark). Glyph outlines are empty: positioning only uses metrics and anchors.

Run with: .venv/bin/python scripts/gen_gpos_test_font.py
"""

from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables import otTables as ot
from fontTools.ttLib.tables.otBase import ValueRecord

OUT = Path("test/fonts/gpos/GposTest.ttf")

LETTERS = [chr(c) for c in range(ord("a"), ord("z") + 1)]
MARKS = {"gravecomb": 0x0300, "acutecomb": 0x0301, "dotbelowcomb": 0x0323, "ogonekcomb": 0x0328}
EXTRA = ["p_q", "c.one", "c.two"]

FEA = """
languagesystem DFLT dflt;
languagesystem latn dflt;

@TOPMARKS = [acutecomb gravecomb];
@FILTER = [dotbelowcomb];
markClass [acutecomb gravecomb] <anchor 150 500> @TOP;
markClass [dotbelowcomb ogonekcomb] <anchor 150 0> @BOTTOM;

table GDEF {
    GlyphClassDef [a b c d e f g h i j k l m n o p q r s t u v w x y z c.one c.two],
                  [p_q], [acutecomb gravecomb dotbelowcomb ogonekcomb], ;
} GDEF;

feature liga { sub p q by p_q; } liga;

feature ss01 {
    pos a <10 20 30 40>;
    pos b <0 0 -50 0>;
    pos d <5 -15 25 0>;
} ss01;

feature ss02 {
    pos e f -40;
    pos g <0 0 -30 0> h <10 5 20 0>;
} ss02;

@L = [i j];
@R = [k l];
feature ss03 { pos @L @R -60; } ss03;

lookup KERN_IGNORE {
    lookupflag IgnoreMarks;
    pos m n -100;
} KERN_IGNORE;
feature ss04 { lookup KERN_IGNORE; } ss04;

lookup KERN_FILTER {
    lookupflag UseMarkFilteringSet @FILTER;
    pos o r -70;
} KERN_FILTER;
feature ss05 { lookup KERN_FILTER; } ss05;

feature ss06 {
    pos cursive s <anchor NULL> <anchor 450 100>;
    pos cursive t <anchor 30 0> <anchor 470 -80>;
    pos cursive u <anchor 50 40> <anchor NULL>;
} ss06;

feature ss07 {
    pos base [v w x] <anchor 250 700> mark @TOP <anchor 250 -50> mark @BOTTOM;
} ss07;

feature ss08 {
    pos ligature p_q <anchor 200 700> mark @TOP <anchor 200 -60> mark @BOTTOM
        ligComponent <anchor 700 750> mark @TOP <anchor 700 -40> mark @BOTTOM;
} ss08;

feature ss09 {
    pos base [v w x] <anchor 250 700> mark @TOP;
    pos mark [acutecomb gravecomb] <anchor 150 900> mark @TOP;
} ss09;

lookup NUDGE { pos k <0 0 77 0>; } NUDGE;
lookup LIFT { pos l <0 120 0 0>; } LIFT;
feature ss10 {
    pos y k' lookup NUDGE l' lookup LIFT z;
    pos k' lookup NUDGE y;
} ss10;

lookup EXT useExtension { pos z y -77; } EXT;
lookup EXT_SINGLE useExtension { pos a <0 0 11 0>; } EXT_SINGLE;
feature ss11 { lookup EXT; lookup EXT_SINGLE; } ss11;

lookup KERN_ATTACH {
    lookupflag MarkAttachmentType @TOPMARKS;
    pos a b -90;
} KERN_ATTACH;
feature ss12 { lookup KERN_ATTACH; } ss12;

feature ss13 {
    sub c by c.one c.two;
    pos base c.one <anchor 200 650> mark @TOP <anchor 200 -30> mark @BOTTOM;
} ss13;

lookup CURSIVE_RTL {
    lookupflag RightToLeft;
    pos cursive s <anchor NULL> <anchor 450 100>;
    pos cursive t <anchor 30 0> <anchor 470 -80>;
    pos cursive u <anchor 50 40> <anchor NULL>;
} CURSIVE_RTL;
feature ss14 { lookup CURSIVE_RTL; } ss14;
"""


def build_font():
    order = [".notdef", "space"] + LETTERS + list(MARKS) + EXTRA
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {0x20: "space"}
    cmap.update({ord(c): c for c in LETTERS})
    cmap.update({cp: name for name, cp in MARKS.items()})
    fb.setupCharacterMap(cmap)
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({g: empty for g in order})
    widths = {g: 500 for g in order}
    widths.update({g: 300 for g in MARKS})
    widths.update({"p_q": 1000, "c.one": 400, "c.two": 400, "space": 250})
    fb.setupHorizontalMetrics({g: (w, 0) for g, w in widths.items()})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "GposTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    addOpenTypeFeaturesFromString(fb.font, FEA)
    merge_single_pos(fb.font)
    return fb.font


def merge_single_pos(font):
    """ss01 as feaLib builds it is one format 1 subtable per glyph; keep a's
    (format 1) and merge b and d into one format 2 subtable, so both
    formats are covered."""
    gpos = font["GPOS"].table
    ss01 = next(r for r in gpos.FeatureList.FeatureRecord if r.FeatureTag == "ss01")
    lookup = gpos.LookupList.Lookup[ss01.Feature.LookupListIndex[0]]
    subs = lookup.SubTable
    by_glyph = {st.Coverage.glyphs[0]: st for st in subs}
    rest = [g for g in ("b", "d") if g in by_glyph]
    merged = ot.SinglePos()
    merged.Format = 2
    merged.Coverage = ot.Coverage()
    merged.Coverage.glyphs = sorted(rest, key=font.getGlyphID)
    merged.ValueFormat = 0x7
    merged.Value = []
    for g in merged.Coverage.glyphs:
        v = ValueRecord(0x7)
        src = by_glyph[g].Value
        for name in ("XPlacement", "YPlacement", "XAdvance"):
            setattr(v, name, getattr(src, name, 0) or 0)
        merged.Value.append(v)
    merged.ValueCount = len(merged.Value)
    lookup.SubTable = [by_glyph["a"], merged]
    lookup.SubTableCount = 2


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    build_font().save(OUT)
    print(f"{OUT}")


if __name__ == "__main__":
    main()
