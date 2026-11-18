#!/usr/bin/env python3
"""
Indic character categories and positions (src/indic_data.zig) for the
Indic shaper (src/indic.zig), derived exactly as HarfBuzz's
gen-indic-table.py derives them (HarfBuzz 12.3.0): UCD
IndicSyllabicCategory and IndicPositionalCategory, limited to HarfBuzz's
blocks, mapped to its categories, with its overrides and position rules.
Khmer and Myanmar have shapers of their own and are left out.

The UCD files are those of Python's unicodedata version, cached in
.tools/ucd/<ver>/ (scripts/gen_unicode_props.py fetches the same way).

Run with: .venv/bin/python scripts/gen_indic_table.py
"""

import unicodedata
import urllib.request
from pathlib import Path

OUT = Path("src/indic_data.zig")
VERSION = unicodedata.unidata_version
CACHE = Path(".tools/ucd") / VERSION
FILES = ["IndicSyllabicCategory.txt", "IndicPositionalCategory.txt", "Blocks.txt"]

ALLOWED_SINGLES = [0x00A0, 0x25CC]
ALLOWED_BLOCKS = [
    "Basic Latin", "Latin-1 Supplement", "Devanagari", "Bengali", "Gurmukhi",
    "Gujarati", "Oriya", "Tamil", "Telugu", "Kannada", "Malayalam",
    "Vedic Extensions", "General Punctuation", "Superscripts and Subscripts",
    "Devanagari Extended",
]

CATEGORIES = ["X", "C", "V", "N", "H", "ZWNJ", "ZWJ", "M", "SM", "A", "VD", "PLACEHOLDER",
              "DOTTEDCIRCLE", "RS", "MPst", "Repha", "Ra", "CM", "Symbol", "CS", "SMPst"]
# Zig enum names (VD is A in the machine)
CAT_NAME = {"X": "x", "C": "c", "V": "v", "N": "n", "H": "h", "ZWNJ": "zwnj", "ZWJ": "zwj",
            "M": "m", "SM": "sm", "A": "a", "VD": "a", "PLACEHOLDER": "placeholder",
            "DOTTEDCIRCLE": "dotted_circle", "RS": "rs", "MPst": "m_pst", "Repha": "repha",
            "Ra": "ra", "CM": "cm", "Symbol": "symbol", "CS": "cs", "SMPst": "sm_pst"}
POS_NAME = {"END": "end", "BASE_C": "base_c", "ABOVE_C": "above_c", "BELOW_C": "below_c",
            "POST_C": "post_c", "PRE_C": "pre_c", "PRE_M": "pre_m", "AFTER_MAIN": "after_main",
            "AFTER_SUB": "after_sub", "BEFORE_SUB": "before_sub", "AFTER_POST": "after_post",
            "SMVD": "smvd"}

category_map = {
    "Other": "X", "Avagraha": "Symbol", "Bindu": "SM", "Brahmi_Joining_Number": "PLACEHOLDER",
    "Cantillation_Mark": "A", "Consonant": "C", "Consonant_Dead": "C", "Consonant_Final": "CM",
    "Consonant_Head_Letter": "C", "Consonant_Initial_Postfixed": "C", "Consonant_Killer": "M",
    "Consonant_Medial": "CM", "Consonant_Placeholder": "PLACEHOLDER",
    "Consonant_Preceding_Repha": "Repha", "Consonant_Prefixed": "X",
    "Consonant_Subjoined": "CM", "Consonant_Succeeding_Repha": "CM",
    "Consonant_With_Stacker": "CS", "Gemination_Mark": "SM", "Invisible_Stacker": "H",
    "Joiner": "ZWJ", "Modifying_Letter": "X", "Non_Joiner": "ZWNJ", "Nukta": "N",
    "Number": "PLACEHOLDER", "Number_Joiner": "PLACEHOLDER", "Pure_Killer": "M",
    "Register_Shifter": "RS", "Syllable_Modifier": "SM", "Tone_Letter": "X", "Tone_Mark": "N",
    "Virama": "H", "Visarga": "SM", "Vowel": "V", "Vowel_Dependent": "M",
    "Vowel_Independent": "V",
}
position_map = {
    "Not_Applicable": "END", "Left": "PRE_C", "Top": "ABOVE_C", "Bottom": "BELOW_C",
    "Right": "POST_C", "Bottom_And_Right": "POST_C", "Left_And_Right": "POST_C",
    "Top_And_Bottom": "BELOW_C", "Top_And_Bottom_And_Left": "BELOW_C",
    "Top_And_Bottom_And_Right": "POST_C", "Top_And_Left": "ABOVE_C",
    "Top_And_Left_And_Right": "POST_C", "Top_And_Right": "POST_C",
    "Overstruck": "AFTER_MAIN", "Visual_order_left": "PRE_M",
}
category_overrides = {
    0x2015: "PLACEHOLDER", 0x2022: "PLACEHOLDER", 0x25FB: "PLACEHOLDER",
    0x25FC: "PLACEHOLDER", 0x25FD: "PLACEHOLDER", 0x25FE: "PLACEHOLDER",
    0x0930: "Ra", 0x09B0: "Ra", 0x09F0: "Ra", 0x0A30: "Ra", 0x0AB0: "Ra", 0x0B30: "Ra",
    0x0BB0: "Ra", 0x0C30: "Ra", 0x0CB0: "Ra", 0x0D30: "Ra",
    0x0953: "SM", 0x0954: "SM",
    0x0A40: "MPst",
    0x0A72: "C", 0x0A73: "C", 0x1CF5: "C", 0x1CF6: "C",
    0x1CE2: "A", 0x1CE3: "A", 0x1CE4: "A", 0x1CE5: "A", 0x1CE6: "A", 0x1CE7: "A",
    0x1CE8: "A", 0x1CED: "A",
    0xA8F2: "Symbol", 0xA8F3: "Symbol", 0xA8F4: "Symbol", 0xA8F5: "Symbol",
    0xA8F6: "Symbol", 0xA8F7: "Symbol", 0x1CE9: "Symbol", 0x1CEA: "Symbol",
    0x1CEB: "Symbol", 0x1CEC: "Symbol", 0x1CEE: "Symbol", 0x1CEF: "Symbol",
    0x1CF0: "Symbol", 0x1CF1: "Symbol",
    0x0A51: "M",
    0x11301: "SM", 0x11302: "SM", 0x11303: "SM", 0x1133B: "N", 0x1133C: "N",
    0x0AFB: "N", 0x0B55: "N",
    0x09FC: "PLACEHOLDER", 0x0C80: "PLACEHOLDER", 0x0D04: "PLACEHOLDER",
    0x25CC: "DOTTEDCIRCLE",
}
position_overrides = {0x0A51: "BELOW_C", 0x0B01: "BEFORE_SUB"}


def matra_pos_right(u, block):
    if block == "Telugu":
        return "BEFORE_SUB" if u <= 0x0C42 else "AFTER_SUB"
    if block == "Kannada":
        return "BEFORE_SUB" if u < 0x0CC3 or u > 0x0CD6 else "AFTER_SUB"
    return {"Devanagari": "AFTER_SUB", "Bengali": "AFTER_POST", "Gurmukhi": "AFTER_POST",
            "Gujarati": "AFTER_POST", "Oriya": "AFTER_POST", "Tamil": "AFTER_POST",
            "Malayalam": "AFTER_POST"}.get(block, "AFTER_SUB")


def matra_pos_top(block):
    return {"Devanagari": "AFTER_SUB", "Gurmukhi": "AFTER_POST", "Gujarati": "AFTER_SUB",
            "Oriya": "AFTER_MAIN", "Tamil": "AFTER_SUB", "Telugu": "BEFORE_SUB",
            "Kannada": "BEFORE_SUB"}.get(block, "AFTER_SUB")


def matra_pos_bottom(block):
    return {"Devanagari": "AFTER_SUB", "Bengali": "AFTER_SUB", "Gurmukhi": "AFTER_POST",
            "Gujarati": "AFTER_POST", "Oriya": "AFTER_SUB", "Tamil": "AFTER_POST",
            "Telugu": "BEFORE_SUB", "Kannada": "BEFORE_SUB", "Malayalam": "AFTER_POST"}.get(block, "AFTER_SUB")


def indic_matra_position(u, pos, block):
    if pos == "PRE_C":
        return "PRE_M"
    if pos == "POST_C":
        return matra_pos_right(u, block)
    if pos == "ABOVE_C":
        return matra_pos_top(block)
    if pos == "BELOW_C":
        return matra_pos_bottom(block)
    raise AssertionError(pos)


def ucd_file(name):
    path = CACHE / name
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        url = f"https://www.unicode.org/Public/{VERSION}/ucd/{name}"
        with urllib.request.urlopen(url) as r:
            path.write_bytes(r.read())
    return path.read_text(encoding="utf-8")


def parse(text):
    data = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0]
        fields = [x.strip() for x in line.split(";")]
        if len(fields) == 1:
            continue
        lo, _, hi = fields[0].partition("..")
        for u in range(int(lo, 16), int(hi or lo, 16) + 1):
            data[u] = fields[1]
    return data


def main():
    unicode_data = [parse(ucd_file(f)) for f in FILES]
    defaults = ("Other", "Not_Applicable", "No_Block")
    combined = {}
    for i, d in enumerate(unicode_data):
        for u, v in d.items():
            if i == 2 and u not in combined:
                continue
            if u not in combined:
                combined[u] = list(defaults)
            combined[u][i] = v
    combined = {k: v for k, v in combined.items() if k in ALLOWED_SINGLES or v[2] in ALLOWED_BLOCKS}

    defaults = (category_map[defaults[0]], position_map[defaults[1]], defaults[2])
    data = {}
    for k, (cat, pos, block) in combined.items():
        cat = category_map[cat]
        if cat == "SM" and pos == "Not_Applicable":
            cat = "SMPst"
        data[k] = (cat, position_map[pos], block)
    for k, new_cat in category_overrides.items():
        _, pos, _ = data.get(k, defaults)
        data[k] = (new_cat, pos, unicode_data[2].get(k, "No_Block"))
    for k, (cat, pos, block) in data.items():
        if cat not in ("CM", "SM", "RS", "H", "M", "MPst"):
            data[k] = (cat, "END", block)
    for k, (cat, pos, block) in data.items():
        if cat in ("C", "CS", "Ra", "CM", "V", "PLACEHOLDER", "DOTTEDCIRCLE"):
            pos = "BASE_C"
        elif cat in ("M", "MPst"):
            pos = indic_matra_position(k, pos, block)
        elif cat in ("SM", "SMPst", "VD", "A", "Symbol"):
            pos = "SMVD"
        data[k] = (cat, pos, block)
    for k, new_pos in position_overrides.items():
        cat, _, _ = data.get(k, defaults)
        data[k] = (cat, new_pos, unicode_data[2].get(k, "No_Block"))

    rows = [(u, c, p) for u, (c, p, _) in sorted(data.items()) if (c, p) != ("X", "END")]
    lines = [
        f"//! Generated by scripts/gen_indic_table.py from Unicode {VERSION} (as HarfBuzz",
        "//! 12.3.0's gen-indic-table.py). Do not edit.",
        "",
        'const indic = @import("indic.zig");',
        "",
        "pub const Entry = struct { cp: u21, category: indic.Category, position: indic.Position };",
        "",
        "/// Characters with an Indic category or position, sorted; all others are",
        "/// category x, position end.",
        "pub const entries = [_]Entry{",
    ]
    for u, c, p in rows:
        lines.append(f"    .{{ .cp = 0x{u:04X}, .category = .{CAT_NAME[c]}, .position = .{POS_NAME[p]} }},")
    lines += ["};", ""]
    OUT.write_text("\n".join(lines))
    print(f"{OUT}: {len(rows)} entries")


if __name__ == "__main__":
    main()
