#!/usr/bin/env python3
"""
Unicode character properties for shaping (src/unicode_props_data.zig),
used by src/unicode_props.zig.

  mark       General_Category Mn, Mc or Me (Python's unicodedata)
  nonspacing General_Category Mn: what HarfBuzz takes for a mark glyph in
             a font without GDEF glyph classes
  letter     General_Category L* (the first letter of a script picks the
             shaper, as HarfBuzz's guess_segment_properties)
  non_word   General_Category Cc, Z*, P*, S*, N*: what does not continue a
             word for the Indic 'init' feature (HarfBuzz's FORMAT..
             NON_SPACING_MARK range is everything else)
  ext_pict   Extended_Pictographic (UCD emoji/emoji-data.txt)
  grapheme   Grapheme_Cluster_Break (low 4 bits) and Indic_Conjunct_Break
             (bits 4-5) for UAX #29 extended grapheme clusters (UCD
             auxiliary/GraphemeBreakProperty.txt, DerivedCoreProperties.txt);
             test/unicode/GraphemeBreakTest.txt is UCD's conformance test
  wide       East_Asian_Width W or F: two cells on a monospaced grid
             (`.monospace` fallback; UCD EastAsianWidth.txt)
  strong_script, devanagari_script
             characters of a real script (not Common, Inherited or
             unassigned), and those of Devanagari (UCD Scripts.txt): the
             first of them picks the shaper, as guess_segment_properties
  decompositions
             every canonical single-step decomposition (cp -> a, b; b = 0
             for a singleton), for decomposing characters a font lacks as
             HarfBuzz's normalization does; Hangul is algorithmic, not listed

Grapheme clusters are formed as HarfBuzz does (hb_set_unicode_props):
marks continue a cluster, and so does an Extended_Pictographic character
after ZWJ.

The UCD files come from unicode.org for the version Python's unicodedata
implements (so all properties agree) and are cached in .tools/ucd/<ver>/;
only the generated Zig file is checked in.

Run with: .venv/bin/python scripts/gen_unicode_props.py
"""

import sys
import unicodedata
import urllib.request
from pathlib import Path

OUT = Path("src/unicode_props_data.zig")
VERSION = unicodedata.unidata_version
CACHE = Path(".tools/ucd") / VERSION
FILES = {
    "emoji-data.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/emoji/emoji-data.txt",
    "Scripts.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/Scripts.txt",
    "GraphemeBreakProperty.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/auxiliary/GraphemeBreakProperty.txt",
    "DerivedCoreProperties.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/DerivedCoreProperties.txt",
    "GraphemeBreakTest.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/auxiliary/GraphemeBreakTest.txt",
    "EastAsianWidth.txt": f"https://www.unicode.org/Public/{VERSION}/ucd/EastAsianWidth.txt",
}
GCB = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend",
       "SpacingMark", "L", "V", "T", "LV", "LVT"]
INCB = ["None", "Linker", "Consonant", "Extend"]
TEST_COPY = Path("test/unicode/GraphemeBreakTest.txt")


def ucd_file(name):
    path = CACHE / name
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(FILES[name]) as r:
            path.write_bytes(r.read())
    return path.read_text(encoding="utf-8")


def ranges(cps):
    out = []
    for cp in sorted(cps):
        if out and out[-1][1] == cp - 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def property_cps(text, prop):
    cps = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        field, name = [f.strip() for f in line.split(";")[:2]]
        if name != prop:
            continue
        lo, _, hi = field.partition("..")
        cps.update(range(int(lo, 16), int(hi or lo, 16) + 1))
    return cps


def emit(name, doc, rs):
    lines = [f"/// {doc}", f"pub const {name} = [_][2]u21{{"]
    for lo, hi in rs:
        lines.append(f"    .{{ 0x{lo:04X}, 0x{hi:04X} }},")
    lines.append("};")
    return "\n".join(lines)


def main():
    marks = {cp for cp in range(sys.maxunicode + 1) if unicodedata.category(chr(cp)) in ("Mn", "Mc", "Me")}
    nonspacing = {cp for cp in marks if unicodedata.category(chr(cp)) == "Mn"}
    letters = set()
    non_word = set()
    for cp in range(sys.maxunicode + 1):
        cat = unicodedata.category(chr(cp))
        if cat[0] == "L":
            letters.add(cp)
        elif cat == "Cc" or cat[0] in "ZPSN":
            non_word.add(cp)
    decomps = []
    for cp in range(sys.maxunicode + 1):
        if 0xAC00 <= cp <= 0xD7A3:
            continue  # Hangul syllables: algorithmic
        d = unicodedata.decomposition(chr(cp))
        if not d or d.startswith("<"):
            continue
        parts = [int(x, 16) for x in d.split()]
        assert len(parts) in (1, 2), hex(cp)
        decomps.append((cp, parts[0], parts[1] if len(parts) == 2 else 0))
    ext_pict = property_cps(ucd_file("emoji-data.txt"), "Extended_Pictographic")
    scripts = {}
    for line in ucd_file("Scripts.txt").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        field, name = [f.strip() for f in line.split(";")[:2]]
        lo, _, hi = field.partition("..")
        for u in range(int(lo, 16), int(hi or lo, 16) + 1):
            scripts[u] = name
    strong = {u for u, sc in scripts.items() if sc not in ("Common", "Inherited")}
    gcb = {}
    for line in ucd_file("GraphemeBreakProperty.txt").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        field, name = [f.strip() for f in line.split(";")[:2]]
        lo, _, hi = field.partition("..")
        for u in range(int(lo, 16), int(hi or lo, 16) + 1):
            gcb[u] = GCB.index(name)
    for line in ucd_file("DerivedCoreProperties.txt").splitlines():
        line = line.split("#", 1)[0].strip()
        fields = [f.strip() for f in line.split(";")]
        if len(fields) < 3 or fields[1] != "InCB":
            continue
        lo, _, hi = fields[0].partition("..")
        for u in range(int(lo, 16), int(hi or lo, 16) + 1):
            gcb[u] = gcb.get(u, 0) | (INCB.index(fields[2]) << 4)
    grapheme = []
    for u in sorted(gcb):
        if grapheme and grapheme[-1][1] == u - 1 and grapheme[-1][2] == gcb[u]:
            grapheme[-1][1] = u
        else:
            grapheme.append([u, u, gcb[u]])
    wide = set()
    for line in ucd_file("EastAsianWidth.txt").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        field, value = [f.strip() for f in line.split(";")[:2]]
        if value not in ("W", "F"):
            continue
        lo, _, hi = field.partition("..")
        wide.update(range(int(lo, 16), int(hi or lo, 16) + 1))
    TEST_COPY.parent.mkdir(parents=True, exist_ok=True)
    TEST_COPY.write_text(ucd_file("GraphemeBreakTest.txt"), encoding="utf-8")
    devanagari = {u for u, sc in scripts.items() if sc == "Devanagari"}
    parts = [
        f"//! Generated by scripts/gen_unicode_props.py from Unicode {VERSION}. Do not edit.",
        "",
        emit("mark_ranges", "General_Category Mn, Mc or Me (sorted, inclusive).", ranges(marks)),
        "",
        emit("nonspacing_mark_ranges", "General_Category Mn (sorted, inclusive).", ranges(nonspacing)),
        "",
        "/// Canonical single-step decompositions: code point, first, second (0 for",
        "/// a singleton), sorted by code point.",
        "pub const decompositions = [_][3]u21{",
        *[f"    .{{ 0x{c:04X}, 0x{a:04X}, 0x{b:04X} }}," for c, a, b in decomps],
        "};",
        "",
        emit("letter_ranges", "General_Category L* (sorted, inclusive).", ranges(letters)),
        "",
        emit("non_word_ranges", "General_Category Cc, Z*, P*, S*, N* (sorted, inclusive).", ranges(non_word)),
        "",
        "/// Grapheme_Cluster_Break | Indic_Conjunct_Break << 4 per range (sorted,",
        "/// inclusive); unlisted: Other, None.",
        "pub const grapheme_ranges = [_][3]u21{",
        *[f"    .{{ 0x{lo:04X}, 0x{hi:04X}, {v} }}," for lo, hi, v in grapheme],
        "};",
        "",
        emit("wide_ranges", "East_Asian_Width W or F (sorted, inclusive).", ranges(wide)),
        "",
        emit("strong_script_ranges", "Script not Common or Inherited (sorted, inclusive).", ranges(strong)),
        "",
        emit("devanagari_script_ranges", "Script=Devanagari (sorted, inclusive).", ranges(devanagari)),
        "",
        emit("ext_pict_ranges", "Extended_Pictographic (sorted, inclusive).", ranges(ext_pict)),
        "",
    ]
    OUT.write_text("\n".join(parts))
    print(f"{OUT}: {len(ranges(marks))} mark ranges, {len(ranges(ext_pict))} Extended_Pictographic ranges")


if __name__ == "__main__":
    main()
