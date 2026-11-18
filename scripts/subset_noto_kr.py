#!/usr/bin/env python3
"""
A small Noto Sans KR for the showcase's scripts page (src/showcase.zig):
test/fonts/Noto Sans KR/NotoSansKR-Regular-subset.otf.

The full font (4.6 MB, CID-keyed CFF) comes from
https://github.com/notofonts/noto-cjk (Sans/SubsetOTF/KR), SIL OFL 1.1
without Reserved Font Names, so a subset may keep its name. Kept: the
Hangul syllables of TEXT, every conjoining jamo (modern and Old Hangul,
with the features that compose them), compatibility jamo, tone marks,
the dotted circle, Basic Latin and some punctuation; all OpenType layout
features; CID-keyed CFF stays CID-keyed.

Run with: .venv/bin/python -I scripts/subset_noto_kr.py <NotoSansKR-Regular.otf>
"""

import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

OUT = Path("test/fonts/Noto Sans KR/NotoSansKR-Regular-subset.otf")

# Text set in Hangul syllables (showcase, tests): a pangram, a greeting,
# the jamo composition demo's syllables
TEXT = "다람쥐 헌 쳇바퀴에 타고파 안녕하세요 한글 한국어 서연 대본 있어요"

RANGES = [
    (0x0020, 0x007E),  # Basic Latin
    (0x1100, 0x11FF),  # Hangul Jamo
    (0x3130, 0x318F),  # Hangul Compatibility Jamo
    (0xA960, 0xA97F),  # Hangul Jamo Extended-A
    (0xD7B0, 0xD7FF),  # Hangul Jamo Extended-B
    (0x302E, 0x302F),  # Hangul tone marks
]
EXTRA = [0x25CC, 0x2014, 0x2026, 0x00B7, 0x2192]  # dotted circle, em dash, ellipsis, middle dot, arrow


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    font = TTFont(sys.argv[1])
    cmap = font.getBestCmap()
    unicodes = {cp for lo, hi in RANGES for cp in range(lo, hi + 1)}
    unicodes |= set(EXTRA)
    unicodes |= {ord(c) for c in TEXT if not c.isspace()}
    missing = sorted(cp for cp in unicodes if cp not in cmap and cp > 0x7E and not 0x1100 <= cp <= 0xD7FF)
    if missing:
        sys.exit("not in the font: " + " ".join(f"U+{cp:04X}" for cp in missing))

    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.glyph_names = False
    sub = subset.Subsetter(options)
    sub.populate(unicodes=sorted(cp for cp in unicodes if cp in cmap))
    sub.subset(font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(OUT)
    print(f"{OUT}: {len(font.getGlyphOrder())} glyphs, {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
