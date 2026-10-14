#!/usr/bin/env python3
"""
Reference face list for font_collection.zig, read with fontTools.

Writes test/reference/inter_ttc_faces.tsv: one line per face of
test/fonts/Inter/Inter.ttc with index, family (name ID 16, else 1),
subfamily (17, else 2), PostScript name (6), OS/2 usWeightClass and
usWidthClass, and the OS/2 fsSelection BOLD and ITALIC bits.

Run with: .venv/bin/python scripts/gen_ttc_reference.py
"""

from pathlib import Path

from fontTools.ttLib import TTCollection

SRC = Path("test/fonts/Inter/Inter.ttc")
OUT = Path("test/reference/inter_ttc_faces.tsv")


def name(font, *ids):
    for i in ids:
        n = font["name"].getName(i, 3, 1, 0x409)
        if n is not None:
            return n.toUnicode()
    return ""


def main():
    lines = []
    for i, font in enumerate(TTCollection(str(SRC))):
        os2 = font["OS/2"]
        lines.append("\t".join([
            str(i),
            name(font, 16, 1),
            name(font, 17, 2),
            name(font, 6),
            str(os2.usWeightClass),
            str(os2.usWidthClass),
            str(int(bool(os2.fsSelection & (1 << 5)))),
            str(int(bool(os2.fsSelection & 1))),
        ]))
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT} ({len(lines)} faces)")


if __name__ == "__main__":
    main()
