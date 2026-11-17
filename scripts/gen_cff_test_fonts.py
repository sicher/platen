#!/usr/bin/env python3
"""
CFF test fonts for subsetting (test/fonts/cff/): the same outlines as a
name-keyed font (NameKeyed.otf) and as a CID-keyed one (CidKeyed.otf), so a
PDF drawn with either must render identically.

The CID-keyed font is the case Apple SD Gothic Neo is (reveal's Hangul bug):
ROS Adobe-Identity-0, CIDs that are NOT the glyph IDs (glyph g has CID
10 + 2g), and two Font DICTs (FDArray) whose Private DICTs have local
subroutines that draw different shapes; FDSelect alternates between them.
A subset that keeps the old charset, copies FDSelect/FDArray or
desubroutinizes with the wrong local subrs draws wrong glyphs.

Glyph outlines call local subroutines (and one a global one), so the
subsetter's desubroutinization is exercised too.

Run with: .venv/bin/python scripts/gen_cff_test_fonts.py
"""

from pathlib import Path

from fontTools.cffLib import FDArrayIndex, FDSelect, FontDict, PrivateDict, SubrsIndex
from fontTools.fontBuilder import FontBuilder
from fontTools.misc.psCharStrings import T2CharString

OUT_DIR = Path("test/fonts/cff")
LETTERS = "ABCDEFGH"
BIAS = 107  # subroutine bias for fewer than 1240 subroutines


def subr(program, private=None, global_subrs=None):
    return T2CharString(program=program, private=private, globalSubrs=global_subrs)


def glyph_program(i):
    """Glyph i: a move, then local subroutine 0 of its Font DICT (a box in
    one, a triangle in the other), then a mark that differs per glyph."""
    x = 60 + 20 * i
    prog = [500, x, 100, "rmoveto", 0 - BIAS, "callsubr"]
    # A distinct bar per glyph, so glyphs of one Font DICT differ too
    prog += [0, 40 * (i + 1), "rmoveto", 200, 0, "rlineto", 0, 30, "rlineto", -200, 0, "rlineto"]
    if i == 3:
        prog += [0 - BIAS, "callgsubr"]
    prog += ["endchar"]
    return prog


BOX = [300, 0, "rlineto", 0, 300, "rlineto", -300, 0, "rlineto", "return"]
TRIANGLE = [300, 0, "rlineto", -150, 300, "rlineto", "return"]
GLOBAL = [0, -60, "rmoveto", 60, 0, "rlineto", 0, 30, "rlineto", "return"]


def build_name_keyed():
    order = [".notdef", "space"] + list(LETTERS)
    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x20: "space", **{ord(c): c for c in LETTERS}})
    # Outlines desubroutinized by hand: the box or triangle inline
    charstrings = {".notdef": subr(["endchar"]), "space": subr(["endchar"])}
    for i, c in enumerate(LETTERS):
        body = (BOX if i % 2 == 0 else TRIANGLE)[:-1]
        prog = [500, 60 + 20 * i, 100, "rmoveto"] + body
        prog += [0, 40 * (i + 1), "rmoveto", 200, 0, "rlineto", 0, 30, "rlineto", -200, 0, "rlineto"]
        if i == 3:
            prog += GLOBAL[:-1]
        charstrings[c] = subr(prog + ["endchar"])
    fb.setupCFF("NameKeyedTest", {"FullName": "NameKeyedTest"}, charstrings, {})
    fb.setupHorizontalMetrics({g: (600 if g != ".notdef" else 500, 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "NameKeyedTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    return fb.font


def build_cid_keyed():
    order = [".notdef", "space"] + list(LETTERS)
    cid_names = [".notdef"] + [f"cid{10 + 2 * g:05d}" for g in range(1, len(order))]
    rename = dict(zip(order, cid_names))

    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x20: "space", **{ord(c): c for c in LETTERS}})
    placeholder = {g: subr(["endchar"]) for g in order}
    fb.setupCFF("CidKeyedTest", {"FullName": "CidKeyedTest"}, placeholder, {})
    fb.setupHorizontalMetrics({g: (600 if g != ".notdef" else 500, 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "CidKeyedTest", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    font = fb.font

    cff = font["CFF "].cff
    top = cff[cff.fontNames[0]]
    global_subrs = cff.GlobalSubrs
    global_subrs.append(subr(GLOBAL))

    # Two Font DICTs, each with its own Private DICT and local subroutines
    fdarray = FDArrayIndex()
    for name, body in (("Box", BOX), ("Triangle", TRIANGLE)):
        fd = FontDict()
        fd.setCFF2(False)
        fd.FontName = f"CidKeyedTest-{name}"
        priv = PrivateDict()
        priv.Subrs = SubrsIndex()
        priv.Subrs.append(subr(body))
        fd.Private = priv
        fdarray.append(fd)
    top.FDArray = fdarray
    top.ROS = ("Adobe", "Identity", 0)
    top.CIDCount = 10 + 2 * len(order)
    select = FDSelect()
    select.format = 3
    # .notdef and space in FD 0; letters alternate box (0) / triangle (1)
    select.gidArray = [0, 0] + [i % 2 for i in range(len(LETTERS))]
    top.FDSelect = select
    if hasattr(top, "Private"):
        del top.Private

    charstrings = top.CharStrings
    new = {}
    for g, name in enumerate(order):
        fd = fdarray[select.gidArray[g]]
        if name in LETTERS:
            prog = glyph_program(LETTERS.index(name))
        else:
            prog = ["endchar"]
        new[rename[name]] = subr(prog, fd.Private, global_subrs)
    charstrings.charStrings = {rename[name]: new[rename[name]] for name in order}
    top.charset = cid_names

    # Glyph names in the other tables follow the CID names
    font.setGlyphOrder(cid_names)
    for table in font["cmap"].tables:
        table.cmap = {u: rename[n] for u, n in table.cmap.items()}
    font["hmtx"].metrics = {rename[n]: m for n, m in font["hmtx"].metrics.items()}
    font["post"].formatType = 3.0
    return font


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    build_name_keyed().save(OUT_DIR / "NameKeyed.otf")
    build_cid_keyed().save(OUT_DIR / "CidKeyed.otf")
    print(OUT_DIR / "NameKeyed.otf", OUT_DIR / "CidKeyed.otf")


if __name__ == "__main__":
    main()
