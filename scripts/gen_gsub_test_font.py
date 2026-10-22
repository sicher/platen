#!/usr/bin/env python3
"""
Synthetic GSUB test font (test/fonts/gsub/GsubTest.ttf) for the HarfBuzz
differential test (scripts/gen_shaping_reference.py).

Real fonts use only some lookup types and formats; this one has each,
behind its own stylistic set, so the shaping reference exercises every
path of src/gsub.zig against HarfBuzz:

  ss01  single (formats 1 and 2), alternate (first alternate)
  ss02  multiple substitution, including deletion
  ss03  ligatures: component order, IgnoreMarks with marks in between
  ss04  ligature under MarkAttachmentType (only TOP marks block it)
  ss05  ligature under UseMarkFilteringSet
  ss06  ligature of marks under IgnoreBaseGlyphs
  ss07  chain context whose nested multiple substitution grows the
        buffer before a later record applies
  ss08  chain context whose nested ligature consumes a later position
  ss09  reverse chaining single substitution (right to left)
  ss10  extension lookups (type 7)
  ss11  context substitution format 1 (glyph sequences)
  ss12  context substitution format 2 (classes)
  ss13  context substitution format 3 (coverages)
  ss14  chain context formats 1 and 2 (built by hand; feaLib picks)
  clig  contextual ligature (on by default, as in HarfBuzz)

Glyph outlines are empty: shaping only looks at glyph IDs.

Run with: .venv/bin/python scripts/gen_gsub_test_font.py
"""

from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.otlLib import builder as otl
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables import otTables as ot

OUT = Path("test/fonts/gsub/GsubTest.ttf")

LETTERS = [chr(c) for c in range(ord("a"), ord("z") + 1)]
MARKS = {"gravecomb": 0x0300, "acutecomb": 0x0301, "dotbelowcomb": 0x0323, "ogonekcomb": 0x0328}
EXTRA = ["a.alt", "b.alt1", "b.alt2", "c.one", "c.two", "c.three", "f_i", "f_f", "f_f_i",
         "acute_grave", "x.one", "x.two", "y.alt", "p_q", "r.alt", "d.alt", "h.alt",
         "k.alt", "m.alt", "n.alt", "s.alt", "t.alt", "u.alt", "v.alt", "o_w"]

FEA = """
languagesystem DFLT dflt;
languagesystem latn dflt;

@TOP = [acutecomb gravecomb];
@BOTTOM = [dotbelowcomb ogonekcomb];
markClass [acutecomb gravecomb] <anchor 0 0> @MC_TOP;
markClass [dotbelowcomb ogonekcomb] <anchor 0 0> @MC_BOTTOM;
@FILTER = [dotbelowcomb];

table GDEF {
    GlyphClassDef [a b c d e f g h i j k l m n o p q r s t u v w x y z a.alt b.alt1 b.alt2
                   c.one c.two c.three x.one x.two y.alt r.alt d.alt h.alt k.alt m.alt n.alt
                   s.alt t.alt u.alt v.alt], [f_i f_f f_f_i p_q o_w], [acutecomb gravecomb
                   dotbelowcomb ogonekcomb acute_grave], ;
} GDEF;

feature ss01 {
    sub a by a.alt;
    sub [k m n] by [k.alt m.alt n.alt];
    sub b from [b.alt1 b.alt2];
} ss01;

feature ss02 {
    sub c by c.one c.two c.three;
    sub g by NULL;
} ss02;

feature ss03 {
    lookupflag IgnoreMarks;
    sub f f i by f_f_i;
    sub f f by f_f;
    sub f i by f_i;
} ss03;

lookup ATTACH {
    lookupflag MarkAttachmentType @TOP;
    sub f i by f_i;
} ATTACH;
feature ss04 { lookup ATTACH; } ss04;

lookup FILTERED {
    lookupflag UseMarkFilteringSet @FILTER;
    sub f i by f_i;
} FILTERED;
feature ss05 { lookup FILTERED; } ss05;

lookup MARKLIG {
    lookupflag IgnoreBaseGlyphs;
    sub acutecomb gravecomb by acute_grave;
} MARKLIG;
feature ss06 { lookup MARKLIG; } ss06;

lookup GROW { sub x by x.one x.two; } GROW;
lookup YALT { sub y by y.alt; } YALT;
feature ss07 {
    sub x' lookup GROW y' lookup YALT;
} ss07;

lookup PQ { sub p q by p_q; } PQ;
lookup RALT { sub r by r.alt; } RALT;
feature ss08 {
    sub p' lookup PQ q' r' lookup RALT;
} ss08;

feature ss09 {
    rsub d' e by d.alt;
    rsub d' d.alt by d.alt;
} ss09;

lookup EXT useExtension { sub h by h.alt; } EXT;
lookup EXTLIG useExtension { sub f i by f_i; } EXTLIG;
feature ss10 { lookup EXT; lookup EXTLIG; } ss10;

lookup OW { sub o w by o_w; } OW;
feature clig { sub z o' lookup OW w'; } clig;
"""


def glyph_order():
    return [".notdef", "space"] + LETTERS + list(MARKS) + EXTRA


def build_font():
    order = glyph_order()
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {0x20: "space"}
    cmap.update({ord(c): c for c in LETTERS})
    cmap.update({cp: name for name, cp in MARKS.items()})
    fb.setupCharacterMap(cmap)
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({g: empty for g in order})
    fb.setupHorizontalMetrics({g: (0 if g in MARKS else 500, 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "GsubTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    font = fb.font
    addOpenTypeFeaturesFromString(font, FEA)
    add_context_lookups(font)
    return font


def lookup_record(seq, lookup_index):
    r = ot.SubstLookupRecord()
    r.SequenceIndex = seq
    r.LookupListIndex = lookup_index
    return r


def add_lookup(gsub, lookup_type, subtables):
    lookup = ot.Lookup()
    lookup.LookupType = lookup_type
    lookup.LookupFlag = 0
    lookup.SubTable = subtables
    lookup.SubTableCount = len(subtables)
    gsub.LookupList.Lookup.append(lookup)
    gsub.LookupList.LookupCount = len(gsub.LookupList.Lookup)
    return len(gsub.LookupList.Lookup) - 1


def add_feature(gsub, tag, lookup_indices):
    rec = ot.FeatureRecord()
    rec.FeatureTag = tag
    rec.Feature = ot.Feature()
    rec.Feature.LookupListIndex = lookup_indices
    rec.Feature.LookupCount = len(lookup_indices)
    gsub.FeatureList.FeatureRecord.append(rec)
    gsub.FeatureList.FeatureCount = len(gsub.FeatureList.FeatureRecord)
    index = gsub.FeatureList.FeatureCount - 1
    for srec in gsub.ScriptList.ScriptRecord:
        ls = srec.Script.DefaultLangSys
        ls.FeatureIndex.append(index)
        ls.FeatureCount = len(ls.FeatureIndex)


def class_def(mapping):
    cd = ot.ClassDef()
    cd.classDefs = dict(mapping)
    return cd


def add_context_lookups(font):
    """Context (type 5) formats 1-3 and chain context (type 6) formats 1-2,
    which feaLib does not let a feature file choose."""
    gsub = font["GSUB"].table
    single = add_lookup(gsub, 1, [otl.buildSingleSubstSubtable(
        {"s": "s.alt", "t": "t.alt", "u": "u.alt", "v": "v.alt"})])

    # ss11: format 1, "s t" -> s.alt t, and "s u" -> s u.alt
    st = ot.ContextSubst()
    st.Format = 1
    st.Coverage = otl.buildCoverage(["s"], font.getReverseGlyphMap())
    rs = ot.SubRuleSet()
    rules = []
    for second, seq in (("t", 0), ("u", 1)):
        r = ot.SubRule()
        r.Input = [second]
        r.GlyphCount = 2
        r.SubstLookupRecord = [lookup_record(seq, single)]
        r.SubstCount = 1
        rules.append(r)
    rs.SubRule = rules
    rs.SubRuleCount = len(rules)
    st.SubRuleSet = [rs]
    st.SubRuleSetCount = 1
    add_feature(gsub, "ss11", [add_lookup(gsub, 5, [st])])

    # ss12: format 2, class 1 = [s t], class 2 = [u v]: "1 2" -> both alt
    st = ot.ContextSubst()
    st.Format = 2
    st.Coverage = otl.buildCoverage(["s", "t"], font.getReverseGlyphMap())
    st.ClassDef = class_def({"s": 1, "t": 1, "u": 2, "v": 2})
    r = ot.SubClassRule()
    r.Class = [2]
    r.GlyphCount = 2
    r.SubstLookupRecord = [lookup_record(0, single), lookup_record(1, single)]
    r.SubstCount = 2
    cs = ot.SubClassSet()
    cs.SubClassRule = [r]
    cs.SubClassRuleCount = 1
    st.SubClassSet = [None, cs]
    st.SubClassSetCount = 2
    add_feature(gsub, "ss12", [add_lookup(gsub, 5, [st])])

    # ss13: format 3, [s t] [u v] [s] -> middle alt
    st = ot.ContextSubst()
    st.Format = 3
    rgm = font.getReverseGlyphMap()
    st.Coverage = [otl.buildCoverage(g, rgm) for g in (["s", "t"], ["u", "v"], ["s"])]
    st.GlyphCount = 3
    st.SubstLookupRecord = [lookup_record(1, single)]
    st.SubstCount = 1
    add_feature(gsub, "ss13", [add_lookup(gsub, 5, [st])])

    # ss14: chain format 1 (backtrack t, input s, lookahead u) and chain
    # format 2 (class backtrack [u], input [v], lookahead [t])
    c1 = ot.ChainContextSubst()
    c1.Format = 1
    c1.Coverage = otl.buildCoverage(["s"], rgm)
    r = ot.ChainSubRule()
    r.Backtrack = ["t"]
    r.BacktrackGlyphCount = 1
    r.Input = []
    r.InputGlyphCount = 1
    r.LookAhead = ["u"]
    r.LookAheadGlyphCount = 1
    r.SubstLookupRecord = [lookup_record(0, single)]
    r.SubstCount = 1
    rs = ot.ChainSubRuleSet()
    rs.ChainSubRule = [r]
    rs.ChainSubRuleCount = 1
    c1.ChainSubRuleSet = [rs]
    c1.ChainSubRuleSetCount = 1

    c2 = ot.ChainContextSubst()
    c2.Format = 2
    c2.Coverage = otl.buildCoverage(["v"], rgm)
    c2.BacktrackClassDef = class_def({"u": 1})
    c2.InputClassDef = class_def({"v": 1})
    c2.LookAheadClassDef = class_def({"t": 1})
    r = ot.ChainSubClassRule()
    r.Backtrack = [1]
    r.BacktrackGlyphCount = 1
    r.Input = []
    r.InputGlyphCount = 1
    r.LookAhead = [1]
    r.LookAheadGlyphCount = 1
    r.SubstLookupRecord = [lookup_record(0, single)]
    r.SubstCount = 1
    cs = ot.ChainSubClassSet()
    cs.ChainSubClassRule = [r]
    cs.ChainSubClassRuleCount = 1
    c2.ChainSubClassSet = [None, cs]
    c2.ChainSubClassSetCount = 2
    add_feature(gsub, "ss14", [add_lookup(gsub, 6, [c1, c2])])

    # Feature records must be sorted by tag
    order = sorted(range(len(gsub.FeatureList.FeatureRecord)),
                   key=lambda i: gsub.FeatureList.FeatureRecord[i].FeatureTag)
    remap = {old: new for new, old in enumerate(order)}
    gsub.FeatureList.FeatureRecord = [gsub.FeatureList.FeatureRecord[i] for i in order]
    for srec in gsub.ScriptList.ScriptRecord:
        ls = srec.Script.DefaultLangSys
        ls.FeatureIndex = sorted(remap[i] for i in ls.FeatureIndex)


def main():
    font = build_font()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(OUT)
    # Report what was built, so a feaLib change that picks other formats
    # shows up here
    gsub = font["GSUB"].table
    kinds = []
    for lookup in gsub.LookupList.Lookup:
        for st in lookup.SubTable:
            t, fmt = lookup.LookupType, getattr(st, "Format", None)
            if t == 7:
                t, fmt = st.ExtensionLookupType, getattr(st.ExtSubTable, "Format", None)
            kinds.append((t, fmt))
    print(f"{OUT}: lookup (type, format): {sorted(set(kinds))}")


if __name__ == "__main__":
    main()
