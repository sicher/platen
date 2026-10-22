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

Run with: .venv/bin/python scripts/gen_shaping_reference.py
"""

from pathlib import Path

import uharfbuzz as hb

OUT = Path("test/shaping/harfbuzz.txt")

# Features platen enables by default (opentype.Feature.defaultEnabled)
PLATEN_DEFAULTS = {"ccmp", "locl", "rlig", "liga", "calt", "kern", "mark", "mkmk"}
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
ALL_SCENARIO_TEXTS = [t for texts in GSUB_SCENARIOS.values() for t in texts]

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


def main():
    lines = []
    for path, toggles, texts in CASES:
        font = hb.Font(hb.Face(Path(path).read_bytes()))
        features = hb_features(toggles)
        lines.append(f"font {path}")
        lines.append("features " + " ".join(toggles))
        for text in texts:
            assert "\t" not in text and "\n" not in text
            gids = shape(font, text, features)
            lines.append(text + "\t" + " ".join(map(str, gids)))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n")
    print(f"{OUT}: {len(CASES)} cases")


if __name__ == "__main__":
    main()
