#!/usr/bin/env python3
"""
Legacy 'kern' table test fonts, derived from Charter Regular (TrueType).

HarfBuzz measures Charter's GPOS kerning for every pair of printable ASCII
glyphs; the non-zero pairs become a format 0 'kern' table (version 0, the
Microsoft layout):

  test/fonts/kern/CharterKern.ttf      GPOS removed, kern added. Kerns
                                       exactly like Charter Regular, but
                                       only through the legacy table.
  test/fonts/kern/CharterKernGpos.ttf  GPOS kept, kern added with every
                                       value set to -300 (deliberately
                                       wrong): GPOS kerning must win.

Also writes test/reference/charter_kern_pairs.tsv (left, right, value in
font units) so the Zig parser is checked pair by pair, and
test/reference/vera_kern_pairs.tsv: every pair of the unmodified
Bitstream Vera Sans 1.10 'kern' table (no GPOS), as fontTools reads it.

Run with: .venv/bin/python scripts/gen_kern_fonts.py
"""

from pathlib import Path

import uharfbuzz as hb
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0

SRC = Path("test/fonts/Charter/Charter Regular.ttf")
OUT_DIR = Path("test/fonts/kern")
PAIRS_TSV = Path("test/reference/charter_kern_pairs.tsv")
VERA = Path("test/fonts/Bitstream Vera/Vera.ttf")
VERA_TSV = Path("test/reference/vera_kern_pairs.tsv")
WRONG_VALUE = -300


def gpos_pairs(path):
    """{(left glyph name, right glyph name): kern} from HarfBuzz, kern only."""
    blob = hb.Blob.from_file_path(str(path))
    face = hb.Face(blob)
    font = hb.Font(face)
    tt = TTFont(str(path))
    cmap = tt.getBestCmap()
    hmtx = tt["hmtx"]
    chars = [c for c in map(chr, range(0x21, 0x7F)) if ord(c) in cmap]
    pairs = {}
    for a in chars:
        for b in chars:
            buf = hb.Buffer()
            buf.add_str(a + b)
            buf.guess_segment_properties()
            hb.shape(font, buf, {"kern": True, "liga": False, "calt": False, "clig": False})
            left, right = cmap[ord(a)], cmap[ord(b)]
            # Total advance change: HarfBuzz splits a legacy 'kern' value
            # between both glyphs (GPOS puts it all on the first one)
            advance = sum(p.x_advance for p in buf.glyph_positions)
            kern = advance - hmtx[left][0] - hmtx[right][0]
            if kern != 0:
                pairs[(left, right)] = kern
    return pairs


def with_kern(pairs, drop_gpos, name_suffix):
    font = TTFont(str(SRC), recalcTimestamp=False)  # reproducible bytes
    if drop_gpos:
        del font["GPOS"]
    kern = newTable("kern")
    kern.version = 0
    sub = KernTable_format_0()
    sub.version = 0
    sub.format = 0
    sub.coverage = 1  # horizontal
    sub.tupleIndex = None
    sub.kernTable = dict(pairs)
    kern.kernTables = [sub]
    font["kern"] = kern
    family = "Charter " + name_suffix
    ps = family.replace(" ", "") + "-Regular"
    names = {1: family, 3: ps, 4: family + " Regular", 6: ps, 16: family}
    for rec in font["name"].names:
        if rec.nameID in names:
            rec.string = names[rec.nameID]
    return font


def main():
    pairs = gpos_pairs(SRC)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with_kern(pairs, True, "Kern").save(str(OUT_DIR / "CharterKern.ttf"))
    wrong = {k: WRONG_VALUE for k in pairs}
    with_kern(wrong, False, "Kern Gpos").save(str(OUT_DIR / "CharterKernGpos.ttf"))

    # Pairs by glyph ID, as the Zig parser sees them
    order = TTFont(str(OUT_DIR / "CharterKern.ttf")).getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    lines = sorted(f"{gid[a]}\t{gid[b]}\t{v}" for (a, b), v in pairs.items())
    PAIRS_TSV.write_text("\n".join(lines) + "\n")
    print(f"{len(pairs)} pairs -> {OUT_DIR}/, {PAIRS_TSV}")

    vera = TTFont(str(VERA))
    gid = {n: i for i, n in enumerate(vera.getGlyphOrder())}
    table = vera["kern"].kernTables[0].kernTable
    lines = sorted(f"{gid[a]}\t{gid[b]}\t{v}" for (a, b), v in table.items())
    VERA_TSV.write_text("\n".join(lines) + "\n")
    # HarfBuzz (the fpdf2 reference shaper) must kern Vera the same way
    mismatches = sum(1 for k, v in gpos_pairs(VERA).items() if table.get(k) != v)
    print(f"{len(table)} Vera pairs -> {VERA_TSV} (HarfBuzz mismatches: {mismatches})")


if __name__ == "__main__":
    main()
