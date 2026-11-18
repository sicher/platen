#!/usr/bin/env python3
"""
HarfBuzz shaping reference (test/shaping/harfbuzz.txt) for the GSUB
differential test in src/shaping_test.zig.

Each case shapes a text with HarfBuzz under the same feature set platen
uses, and records the glyph IDs. platen must produce the same glyphs:
GSUB lookups of every type, applied in lookup order, with lookup flags.
Only glyph IDs are compared (substitution), not positions.

HarfBuzz runs with the script platen picks (`platen_script`: the first
character of a script, if Latin, Devanagari or Hangul, else Common), so
both select the same language system and shaper; left-to-right, removing
default ignorables (as platen does).

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
                   "curs", "dist", "abvm", "blwm", "rclt"}
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

# Normalization: characters a font lacks decompose into ones it has; a
# missing space takes the space glyph at its own width; U+2011 takes U+2010
NORMALIZE = [
    "r\u00e9sum\u00e9 caf\u00e9 \u00e0 \u1ea1 \u0105 \u1e17 \u212b \u01d8",
    "v\u00e9 w\u00e0 x\u1ea1\u0301 \u0119\u0301",
    "a\u2002b\u2003c\u2009d\u200ae\u202ff\u2007g\u2008h\u205fi\u3000j\u00a0k\u2011l\u2004m\u2005n\u2006o",
]

# Marks of other scripts, for fallback positioning (recategorized classes:
# Hebrew points, Arabic harakat, Thai and Lao vowels, double diacritics)
FALLBACK_MARKS = [
    "\u05e9\u05c1\u05b8 \u05dc\u05d5\u05b9 \u05d1\u05bc\u05b0 \u05d3\u05b7\u05bf \u05e9\u05c2\u05b6",
    "\u0628\u0650 \u0633\u0652 \u0644\u0651\u064e \u0647\u064d \u0627\u064b",
    "\u0e01\u0e31\u0e49 \u0e19\u0e38\u0e48 \u0e1b\u0e3a \u0e81\u0eb4\u0ec8 \u0e94\u0ebc",
    "a\u035cb o\u035dx e\u0360a i\u0361j a\u0301\u0300\u0323\u0328",
]

# Devanagari, shaped by the Indic shaper (script guessed from the text, as
# platen's shapeText does): courier's cases, conjuncts, reph, half and below
# forms, nukta, joiners, vowel constraints, broken clusters; then seeded
# random strings of Devanagari letters, signs, joiners and neighbors
DEVANAGARI = ['नमस्ते', 'कि', 'क्ष', 'हैं', 'किि', 'धर्म', 'र्क', 'स्ति', 'क्षि', 'द्ध ह्य ट्र क्र त्र श्र', 'क़ ज़ फ़ ड़', 'अ आ इ ई उ ऊ ऋ ए ऐ ओ औ', 'कँ कं कः', 'ि', '्क', 'अा', 'क्\u200dष', 'क्\u200cष', 'र्\u200dय', 'हिन्दी', 'प्रार्थना', 'कार्यक्रम', 'विश्वविद्यालय', 'स्त्र क्त्व ष्ट्र न्त्र द्व द्य ह्म ह्न ञ्ज ङ्क क्ष्म ज्ञ', 'र्कि र्की र्के र्कं धर्मों पूर्ण सूर्य वर्ष तर्क', 'प्र क्र ग्र ट्र द्र श्र प्रि क्रि ट्रि', 'स्कि स्ति न्दि न्ति ग्वि', 'क़ि ड़ि ज़्य फ़्र', 'क्\u200d द्\u200dव र्\u200d र्\u200cय क\u200d्ष ्\u200c क्\u200c', 'र्इ र्इक', 'ॐ ऽ । ॥ ०१२३ क॒ क॑ क्॑', 'हँसी कहाँ मैं हैं नहीं', 'अंतर्राष्ट्रीय प्रौद्योगिकी द्वितीय स्वास्थ्य श्रृंखला उज्ज्वल महत्त्वपूर्ण', 'ऱ्य ळ ऴ कॅ कॉ', 'ाक ् ँ क्\u200d\u200d ःक', 'Hindi हिन्दी 123 क,ख.', 'आ ई ऊ ॠ ॡ ऌ', 'क्र्य र्त्स्न्य']


def random_devanagari(seed, count):
    import random
    rng = random.Random(seed)
    pool = ([chr(c) for c in range(0x0900, 0x0980)] + [chr(c) for c in range(0x1CD0, 0x1CFA)] +
            [chr(c) for c in range(0xA8E0, 0xA900)] + ["\u094d"] * 25 + ["\u0930"] * 10 + ["\u093c"] * 5 +
            ["\u200d", "\u200c"] * 4 + ["\u093f"] * 8 + [" "] * 4 + ["\u25cc", "1", "a", "-", "\u00a0", "\u2010"])
    out = []
    while len(out) < count:
        t = "".join(rng.choice(pool) for _ in range(rng.randint(1, 12))).strip()
        if t and t not in out:
            out.append(t)
    return out


DEVANAGARI_TEXTS = DEVANAGARI + random_devanagari(2026, 500)

# Hangul, shaped by the Hangul shaper (script guessed from the text):
# conjoining jamo composed into syllables or given ljmo/vjmo/tjmo, syllables
# decomposed, LV + T, Old Hangul, tone marks (moved before their syllable,
# or with a dotted circle), marks, joiners; then seeded random strings of
# jamo, syllables (in the test font and not), tone marks and neighbors
HANGUL = ["가 각 하 한 나 다", "낙 닥 글", "\u1100\u1161", "\u1100\u1161\u11a8", "\u1102\u1161\u11a8",
          "\u1112\u1161\u11ab\u1100\u1173\u11af", "한글", "가\u11a8", "나\u11a8", "다\u11a8", "가\u11c3",
          "\u1113\u1161\u11ab", "\u1113\ud7b0", "\u1113\ud7b0\ud7cb", "\ua960\u1176\u11c3", "\u1100\u1176\u11c3",
          "\u1100\u1161\u302e", "\u1100\u1161\u302f", "한\u302e", "한\u302f", "\u302e", "\u302f가", " \u302e",
          "a\u302f", "\u1102\u1161\u11a8\u302e", "가\u0301", "\u1100\u1161\u0301", "가\u0301\u302e",
          "\u1100\u1161\u11a8\u302e\u0301", "가 a aa 가가", "aa 가가", "\u1103\u1161", "\u1100\u1177",
          "\u3131\u314f", "\u1100\u200d\u1161", "\u1100\u1161\u200d\u11a8", "\u1100\u1100\u1161", "글\u302e",
          "닥\u302e", "\u1100\u1161\u11a8\u11a8", "\u1160\u11a8", "\u115f\u1161", "Wr Ja 한글 abc"]


def random_hangul(seed, count):
    import random
    rng = random.Random(seed)
    jamo_l = [chr(c) for c in list(range(0x1100, 0x1114)) + [0xA960, 0xA961, 0x115F]]
    jamo_v = [chr(c) for c in list(range(0x1160, 0x1178)) + [0xD7B0, 0xD7B1]]
    jamo_t = [chr(c) for c in list(range(0x11A8, 0x11C5)) + [0xD7CB, 0xD7CC]]
    syllables = [chr(c) for c in [0xAC00, 0xAC01, 0xD558, 0xD55C, 0xB098, 0xB099, 0xB2E4, 0xB2E5, 0xAE00, 0xAE01]]
    pool = (jamo_l * 3 + jamo_v * 3 + jamo_t * 2 + syllables * 2 + ["\u302e", "\u302f"] * 6 + ["\u0301"] * 3 +
            [" ", "a", "\u25cc", "\u200d", "\u200c", "\u3131"])
    out = []
    while len(out) < count:
        t = "".join(rng.choice(pool) for _ in range(rng.randint(1, 10))).strip()
        if t and t not in out:
            out.append(t)
    return out


HANGUL_TEXTS = HANGUL + random_hangul(2026, 500)
# Synthetic font with jamo features (scripts/gen_hangul_test_font.py)
HANGUL_TEST = "test/fonts/hangul/HangulTest.ttf"
# Synthetic font whose latn and DFLT language systems differ
SCRIPT_TEST = "test/fonts/script/ScriptTest.ttf"
SCRIPT_TEXTS = ["ab", "bb", "11", "a11", "11 a", ". bb", "1 1 b", "aaa bb 11", "\u0301a", "a\u0301b"]

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

# Fonts with GPOS (kerning, mark attachment), and without (marks placed by
# HarfBuzz's fallback positioning, from glyph extents)
POSITION_CASES = [
    ("test/fonts/Courier Prime/Courier Prime.ttf", [], LATIN + NORMALIZE + FALLBACK_MARKS),
    ("test/fonts/Charter/Charter Regular.ttf", [], LATIN + NORMALIZE + FALLBACK_MARKS),
    ("test/fonts/Noto Emoji/NotoEmoji-Regular.ttf", [], EMOJI + FALLBACK_MARKS),
    (GSUB_TEST, [], ALL_SCENARIO_TEXTS + NORMALIZE + FALLBACK_MARKS),
    (GSUB_TEST, ["+ss03", "+ss04", "+ss05", "+ss06"], ALL_SCENARIO_TEXTS),
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
    (GPOS_TEST, [], GPOS_ALL_TEXTS + NORMALIZE),
    (GPOS_TEST, ["+ss07", "+ss09"], NORMALIZE),
    ("test/fonts/Inter/Inter-Regular.otf", [], NORMALIZE),
    ("test/fonts/Gentium/Gentium-Regular.ttf", [], NORMALIZE),
    *[(GPOS_TEST, ["+" + tag], texts) for tag, texts in GPOS_SCENARIOS.items()],
    (GPOS_TEST, ["+" + tag for tag in GPOS_SCENARIOS if tag != "ss14"], GPOS_ALL_TEXTS),
    # macOS system fonts ("path#face"; skipped where not installed). Sangam
    # MN also has an AAT 'morx' table, which HarfBuzz prefers to GSUB:
    # platen has no AAT, so HarfBuzz shapes it with 'morx' removed.
    ("/System/Library/Fonts/Kohinoor.ttc#4", [], DEVANAGARI_TEXTS),
    ("/System/Library/Fonts/Kohinoor.ttc#0", [], DEVANAGARI_TEXTS),
    ("/System/Library/Fonts/Supplemental/Devanagari Sangam MN.ttc#0", [], DEVANAGARI_TEXTS),
    (HANGUL_TEST, [], HANGUL_TEXTS),
    (HANGUL_TEST, ["-kern"], HANGUL),
    # Apple SD Gothic Neo Regular and Thin: precomposed syllables, no jamo
    # features; GPOS kerning under 'hang'
    ("/System/Library/Fonts/AppleSDGothicNeo.ttc#0", [], HANGUL_TEXTS),
    ("/System/Library/Fonts/AppleSDGothicNeo.ttc#10", [], HANGUL),
    # latn and DFLT differ (scripts/gen_script_test_font.py): Latin text
    # takes latn, text without a script character DFLT
    (SCRIPT_TEST, [], SCRIPT_TEXTS),
    (SCRIPT_TEST, ["-calt"], SCRIPT_TEXTS),
]


def platen_script(text):
    """The script platen shapes `text` in (shaping.textScript): its first
    character of a real script, if that is Latin, Devanagari or Hangul;
    else Common (DFLT). HarfBuzz gets it set, so both pick the same
    language system and shaper."""
    from fontTools import unicodedata
    for ch in text:
        sc = unicodedata.script(ch)
        if sc in ("Zyyy", "Zinh", "Zzzz"):
            continue
        return sc if sc in ("Latn", "Deva", "Hang") else "Zyyy"
    return "Zyyy"


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
    buf.script = platen_script(text)
    buf.language = "en"
    # platen drops default ignorables (U+FE0F, ZWJ, soft hyphen...) that
    # survive shaping instead of drawing them as zero-width glyphs
    buf.flags = hb.BufferFlags.REMOVE_DEFAULT_IGNORABLES
    hb.shape(font, buf, features)
    return [info.codepoint for info in buf.glyph_infos]


def shape_positions(font, text, features):
    buf = hb.Buffer()
    buf.add_utf8(text.encode("utf-8"))
    buf.script = platen_script(text)
    buf.direction = "ltr"
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


def load_font(spec):
    """hb.Font for "path" or "path#face"; None if the file is missing.
    An AAT 'morx' table is dropped (platen shapes with GSUB)."""
    path, _, index = spec.partition("#")
    if not Path(path).exists():
        return None
    data = Path(path).read_bytes()
    from fontTools.ttLib import TTFont
    import io
    tt = TTFont(io.BytesIO(data), fontNumber=int(index or 0))
    if "morx" in tt:
        del tt["morx"]
        out = io.BytesIO()
        tt.save(out)
        return hb.Font(hb.Face(out.getvalue()))
    return hb.Font(hb.Face(data, int(index or 0)))


def write_cases(out, cases, shape_text):
    lines = []
    for path, toggles, texts in cases:
        font = load_font(path)
        if font is None:
            # Keep the file stable: an earlier reference's entries stay
            print(f"skipped (not installed): {path}")
            continue
        features = hb_features(toggles)
        lines.append(f"font {path}")
        lines.append("features " + " ".join(toggles))
        for text in texts:
            assert "\t" not in text and "\n" not in text
            lines.append(text + "\t" + shape_text(font, text, features, path))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print(f"{out}: {len(cases)} cases")


def main():
    write_cases(OUT, CASES, lambda font, text, features, path: " ".join(map(str, shape(font, text, features))))
    write_cases(OUT_POSITIONS, POSITION_CASES,
                lambda font, text, features, path: shape_positions(font, text, features))


if __name__ == "__main__":
    main()
