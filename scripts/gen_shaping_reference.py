#!/usr/bin/env python3
"""
HarfBuzz shaping reference (test/shaping/harfbuzz.txt) for the GSUB
differential test in src/shaping_test.zig.

Each case shapes a text with HarfBuzz under the same feature set platen
uses, and records the glyph IDs. platen must produce the same glyphs:
GSUB lookups of every type, applied in lookup order, with lookup flags.
Only glyph IDs are compared (substitution), not positions.

HarfBuzz runs with script Zyyy, so it selects the DFLT script like platen
(no script itemization), left-to-right, and removes default ignorables
(as platen does).

File format:
    font <path>
    features <+feat|-feat>...      toggles relative to platen's defaults
    <text>\t<gid> <gid> ...         one shaped text per line

Positions (test/shaping/harfbuzz_positions.txt, src/shaping.zig's
shapeText): for the POSITION_CASES fonts, each text's whole glyph run as
hb-shape --no-glyph-names prints it: gid=cluster@x_offset,y_offset+x_advance
joined by "|" (the @ part only when an offset is nonzero), in font units,
clusters as UTF-8 byte offsets at HarfBuzz's default cluster level. Known
differences are listed, with their reason, in test/shaping/position_gaps.txt.

Run with: .venv/bin/python scripts/gen_shaping_reference.py
"""

from pathlib import Path

import uharfbuzz as hb

OUT = Path("test/shaping/harfbuzz.txt")
OUT_POSITIONS = Path("test/shaping/harfbuzz_positions.txt")

# Features platen enables by default (opentype.Feature.defaultEnabled)
PLATEN_DEFAULTS = {"ccmp", "locl", "rlig", "liga", "clig", "calt", "kern", "mark", "mkmk",
                   "curs", "dist", "abvm", "blwm"}
# Features HarfBuzz enables by default for horizontal text; the ones platen
# does not are switched off so both apply the same lookups
HB_DEFAULTS = {"rvrn", "ccmp", "locl", "rlig", "abvm", "blwm", "mark", "mkmk",
               "calt", "clig", "curs", "dist", "kern", "liga", "rclt"}

LATIN = [
    "The quick brown fox jumps over the lazy dog.",
    "office affluent final flow fjord",
    "Hamburgefonstiv 0123456789",
    "1/2 3/4 10/20 2024-10-22 12:30",
    "-> <- <-> => <= == != >= ... :: www",
    "a-b a+b x*y [x] (y) {z}",
    "résumé café naïve über piñata",
    "ı í ï ị́ j́ į́ i̇́",
    "į́ i̇̀ ị́ é̂ à́̂",
    "Á Ë Õ ñ ç ǧ",
    "ﬁ ﬂ Æ œ ß ẞ Ð þ",
    # Default ignorables: removed after shaping, skipped while matching
    # (ZWJ; ZWNJ only in context), so f<ZWJ>i still ligates and f<ZWNJ>i
    # does not
    "co\u00ADop a\u200Bb f\u200Di f\u200Ci \u2060x\uFEFF -\u200D>",
]

# Synthetic font with every lookup type (scripts/gen_gsub_test_font.py):
# one stylistic set per scenario
GSUB_TEST = "test/fonts/gsub/GsubTest.ttf"
GSUB_SCENARIOS = {
    "ss01": ["a b k m n l", "ab kmn"],
    "ss02": ["c g cg gc", "gcg ccc"],
    "ss03": ["fi ffi ff fffi", "f\u0301i f\u0301f\u0300i f\u0323fi"],
    "ss04": ["f\u0323i f\u0301i f\u0323\u0301i f\u0328i"],
    "ss05": ["f\u0323i f\u0328i f\u0301i f\u0323\u0323i"],
    "ss06": ["a\u0301b\u0300 \u0301\u0300 a\u0301\u0300 a\u0301bb\u0300"],
    "ss07": ["xy xxy x y xyxy"],
    "ss08": ["pqr pq pqrr qr pr"],
    "ss09": ["ddde de dd e dde"],
    "ss10": ["h fi hfi"],
    "ss11": ["st su sv ts"],
    "ss12": ["su tv sv uv ts"],
    "ss13": ["sus tvs sv usv"],
    "ss14": ["tsu uvt tsv tsut uvtt"],
}
# Default-on features of the test font: (tag, texts), checked with the
# feature on (default) and off
GSUB_DEFAULT_SCENARIOS = [("clig", ["zow ow zo w zzoww"])]
# Variation sequences (cmap format 14): a listed pair takes its glyph
# before GSUB (a non-default one, or the base's own) and consumes the
# selector; an unlisted one keeps both, and the selector is removed
UVS_TEXTS = ["a\uFE00 b\uFE00 c\uFE01 d\U000E0100 a\uFE01 c\uFE00 d\uFE00 e\uFE00",
             "f\uFE00i f\uFE01i a\uFE00\uFE00 \uFE00a"]
ALL_SCENARIO_TEXTS = [t for texts in GSUB_SCENARIOS.values() for t in texts] + \
    [t for _, texts in GSUB_DEFAULT_SCENARIOS for t in texts] + UVS_TEXTS

EMOJI = [
    "\U0001F600 \U0001F44D\U0001F3FD \U0001F1F8\U0001F1EA \U0001F1FA\U0001F1F8",
    "\U0001F468\u200D\U0001F469\u200D\U0001F467 \U0001F9D1\U0001F3FF\u200D\U0001F4BB",
    "\U0001F3F3\uFE0F\u200D\U0001F308 \u2764\uFE0F \u263A\uFE0E",
    "1\uFE0F\u20E3 #\uFE0F\u20E3 \U0001F9D1\U0001F3FF\u200D\U0001F4BB\uFE0F",
]

CASES = [
    # No GSUB: ignorables are removed on the unshaped path too
    ("test/fonts/Charter/Charter Regular.ttf", [], LATIN),
    ("test/fonts/Noto Emoji/NotoEmoji-Regular.ttf", [], EMOJI),
    ("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf", [], EMOJI),
    (GSUB_TEST, [], ALL_SCENARIO_TEXTS),
    *[(GSUB_TEST, ["+" + tag], texts) for tag, texts in GSUB_SCENARIOS.items()],
    *[(GSUB_TEST, ["-" + tag], texts) for tag, texts in GSUB_DEFAULT_SCENARIOS],
    (GSUB_TEST, ["+" + tag for tag in GSUB_SCENARIOS], ALL_SCENARIO_TEXTS),
    ("test/fonts/Inter/Inter-Regular.otf", [], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["+dlig"], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["+tnum", "+zero", "+case"], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["+frac"], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["+ss01", "+cv01", "+cv05"], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["-calt", "-liga"], LATIN),
    ("test/fonts/Inter/Inter-Bold.ttf", [], LATIN),
    ("test/fonts/Satoshi/Satoshi-Regular.otf", [], LATIN),
    ("test/fonts/Satoshi/Satoshi-Regular.otf", ["+dlig", "+frac"], LATIN),
    ("test/fonts/Gentium/Gentium-Regular.ttf", [], LATIN),
    ("test/fonts/Gentium/Gentium-Regular.ttf", ["+frac"], LATIN),
    ("test/fonts/Gentium/Gentium-Regular.ttf", ["+ss01", "+cv13", "+cv43"], LATIN),
    ("test/fonts/Gentium/Gentium-Italic.ttf", [], LATIN),
    ("test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf", [], LATIN),
    ("test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf", ["+ss01"], LATIN),
]


# Contextual kerning (Gentium: V/Y beside quotes and periods), more pairs
KERNING = [
    "AV To Ty Yo WA LT P. F, V. Y, \"V\" 'Y' \u201cY\u201d \u2018V\u2019 Y\u2019s",
    "\u2c71 \u2c73 \u01b4 \u02bbY Vo Va \u0423\u0430 \u0413\u043e",
]
# Arabic, shaped left to right without the Arabic shaper (as HarfBuzz with
# script Zyyy): lam-alef ligatures take marks per component (mark-to-ligature)
ARABIC = [
    "\u0628\u0650\u0633\u0652\u0645\u0650 \u0627\u0644\u0644\u0651\u064e\u0647\u0650",
    "\u0644\u0627 \u0644\u064e\u0627 \u0644\u0627\u064b \u0644\u0651\u064e\u0627\u0650",
]

# Synthetic font with every GPOS lookup type and flag
# (scripts/gen_gpos_test_font.py): one stylistic set per scenario
GPOS_TEST = "test/fonts/gpos/GposTest.ttf"
GPOS_SCENARIOS = {
    "ss01": ["a b d ab bd", "aaa dbd"],
    "ss02": ["ef efe gh ghgh hg", "eef ggh"],
    "ss03": ["ik jl il jk ki", "iik kl"],
    "ss04": ["mn m\u0301n m\u0301\u0323n nm"],
    "ss05": ["or o\u0323r o\u0301r o\u0323\u0323r"],
    "ss06": ["stu st tu sttu", "s t u ustts"],
    "ss07": ["v\u0301 w\u0323 x\u0301\u0323 v\u0301\u0300", "\u0301 a\u0301 vv\u0328"],
    "ss08": ["pq p\u0301q q\u0301 p\u0301q\u0301 pq\u0323", "p\u0323q\u0300 pq\u0301\u0300"],
    "ss09": ["v\u0301\u0300 w\u0300\u0301\u0301 x\u0323\u0301\u0300", "\u0301\u0300 a\u0301\u0300"],
    "ss10": ["ykl ykz yklz ky kly", "yklzky k"],
    "ss11": ["zy a za azya"],
    "ss12": ["ab a\u0301b a\u0323b a\u0323\u0301b"],
    "ss13": ["c c\u0301 c\u0323 cc\u0301\u0323"],
    "ss14": ["stu st tu sttu", "s t u ustts"],
}
GPOS_ALL_TEXTS = [t for texts in GPOS_SCENARIOS.values() for t in texts]

# Fonts with GPOS (kerning, mark attachment). Fonts without one get
# HarfBuzz's fallback mark positioning, which platen does not do yet.
POSITION_CASES = [
    ("test/fonts/Inter/Inter-Regular.otf", [], LATIN + KERNING),
    ("test/fonts/Inter/Inter-Regular.otf", ["-kern"], LATIN),
    ("test/fonts/Inter/Inter-Regular.otf", ["+frac", "+dlig"], LATIN),
    ("test/fonts/Inter/Inter-Bold.ttf", [], LATIN),
    ("test/fonts/Satoshi/Satoshi-Regular.otf", [], LATIN),
    ("test/fonts/Gentium/Gentium-Regular.ttf", [], LATIN + KERNING),
    ("test/fonts/Gentium/Gentium-Regular.ttf", ["-mark", "-mkmk"], LATIN),
    ("test/fonts/Gentium/Gentium-Regular.ttf", ["-kern"], KERNING),
    ("test/fonts/Gentium/Gentium-Italic.ttf", [], LATIN + KERNING),
    ("test/fonts/Noto Sans Arabic/NotoSansArabic-Regular.ttf", [], ARABIC),
    ("test/fonts/Noto Sans Arabic/NotoSansArabic-Regular.ttf", ["-mark"], ARABIC),
    (GPOS_TEST, [], GPOS_ALL_TEXTS),
    *[(GPOS_TEST, ["+" + tag], texts) for tag, texts in GPOS_SCENARIOS.items()],
    (GPOS_TEST, ["+" + tag for tag in GPOS_SCENARIOS if tag != "ss14"], GPOS_ALL_TEXTS),
]


def hb_features(toggles):
    on = set(PLATEN_DEFAULTS)
    for t in toggles:
        (on.add if t[0] == "+" else on.discard)(t[1:])
    feats = {f: False for f in HB_DEFAULTS - on}
    feats.update({f: True for f in on})
    return feats


def shape(font, text, features):
    buf = hb.Buffer()
    buf.add_str(text)
    buf.direction = "ltr"
    buf.script = "Zyyy"
    buf.language = "en"
    # platen drops default ignorables (U+FE0F, ZWJ, soft hyphen...) that
    # survive shaping instead of drawing them as zero-width glyphs
    buf.flags = hb.BufferFlags.REMOVE_DEFAULT_IGNORABLES
    hb.shape(font, buf, features)
    return [info.codepoint for info in buf.glyph_infos]


def shape_positions(font, text, features):
    buf = hb.Buffer()
    buf.add_utf8(text.encode("utf-8"))
    buf.direction = "ltr"
    buf.script = "Zyyy"
    buf.language = "en"
    buf.flags = hb.BufferFlags.REMOVE_DEFAULT_IGNORABLES
    hb.shape(font, buf, features)
    parts = []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        g = f"{info.codepoint}={info.cluster}"
        if pos.x_offset or pos.y_offset:
            g += f"@{pos.x_offset},{pos.y_offset}"
        parts.append(g + f"+{pos.x_advance}")
    return "|".join(parts)


def write_cases(out, cases, shape_text):
    lines = []
    for path, toggles, texts in cases:
        font = hb.Font(hb.Face(Path(path).read_bytes()))
        features = hb_features(toggles)
        lines.append(f"font {path}")
        lines.append("features " + " ".join(toggles))
        for text in texts:
            assert "\t" not in text and "\n" not in text
            lines.append(text + "\t" + shape_text(font, text, features))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print(f"{out}: {len(cases)} cases")


def main():
    write_cases(OUT, CASES, lambda font, text, features: " ".join(map(str, shape(font, text, features))))
    write_cases(OUT_POSITIONS, POSITION_CASES, shape_positions)


if __name__ == "__main__":
    main()
