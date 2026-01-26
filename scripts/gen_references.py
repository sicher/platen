#!/usr/bin/env python3
"""
Generate reference PDFs using fpdf2.

These serve as the baseline for testing zpdf output.
Run with: python scripts/gen_references.py

Options:
  --test NAME    Generate only the specified test
  --all          Generate all tests, including excluded ones

Will auto-create .venv and install fpdf2 if needed.

Note: Some tests are excluded from automatic generation because fpdf2
cannot correctly generate them (e.g., inter_fonts has ligatures that
fpdf2 doesn't apply). These references must be manually maintained.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Tests excluded from automatic generation because fpdf2 can't generate
# correct references. These must be manually maintained from zpdf output.
EXCLUDED_TESTS = {
    "inter_fonts",  # fpdf2 doesn't apply Inter's <=> → ⇔ ligature
    "text_style",   # Uses zpdf's write() API for inline-styled flowing text
    "auto_height",  # zpdf positions text one line_height below padding; fpdf2 differs
}

SCRIPT_DIR = Path(__file__).parent
REPO_DIR = SCRIPT_DIR.parent
VENV_DIR = REPO_DIR / ".venv"
VENV_PYTHON = VENV_DIR / "bin" / "python"


def ensure_venv():
    """Ensure we're running in the local venv with fpdf2 installed."""
    # Check if already in venv
    if sys.prefix == str(VENV_DIR):
        return  # Already in venv

    # Create venv if needed
    if not VENV_DIR.exists():
        print(f"Creating virtualenv at {VENV_DIR}...")
        subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], check=True)

    # Install fpdf2 if needed
    pip = VENV_DIR / "bin" / "pip"
    result = subprocess.run(
        [str(pip), "show", "fpdf2"],
        capture_output=True,
    )
    if result.returncode != 0:
        print("Installing fpdf2...")
        subprocess.run([str(pip), "install", "fpdf2"], check=True)

    # Re-exec with venv python
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON)] + sys.argv)


ensure_venv()

from fpdf import FPDF

OUTPUT_DIR = Path("test/reference")


def make_pdf():
    """Create PDF with points as unit and zero margins for absolute positioning."""
    pdf = FPDF(unit="pt", format="A4")
    pdf.set_margins(0, 0, 0)
    pdf.set_auto_page_break(False)
    pdf.c_margin = 0  # Remove cell margin so write()/cell() position like text()
    return pdf


def shaped_text(pdf, x, y, text, h=None):
    """Write text at position with text shaping (kerning, ligatures).

    fpdf2's text() doesn't apply shaping, but write() does.
    This helper positions text at (x, y) using write() for proper shaping.
    """
    if h is None:
        h = pdf.font_size
    pdf.set_xy(x, y - h * 0.8)  # Adjust for baseline
    pdf.write(h=h, text=text)


def gen_minimal():
    """Empty page - minimal valid PDF."""
    pdf = make_pdf()
    pdf.add_page()
    pdf.output(OUTPUT_DIR / "minimal.pdf")
    print("  minimal.pdf")


def gen_hello_world():
    """Single text string."""
    pdf = make_pdf()
    pdf.add_page()
    pdf.set_font("Helvetica", size=24)
    pdf.text(50, 50, "Hello, World!")
    pdf.output(OUTPUT_DIR / "hello_world.pdf")
    print("  hello_world.pdf")


def gen_multi_font():
    """Multiple font families."""
    pdf = make_pdf()
    pdf.add_page()

    pdf.set_font("Helvetica", size=12)
    pdf.text(50, 50, "Helvetica Normal")

    pdf.set_font("Helvetica", style="B", size=12)
    pdf.text(50, 70, "Helvetica Bold")

    pdf.set_font("Times", size=12)
    pdf.text(50, 90, "Times Roman")

    pdf.set_font("Courier", size=12)
    pdf.text(50, 110, "Courier")

    pdf.output(OUTPUT_DIR / "multi_font.pdf")
    print("  multi_font.pdf")


def gen_all_fonts():
    """All 14 standard PDF fonts."""
    pdf = make_pdf()
    pdf.add_page()

    fonts = [
        ("Helvetica", ""),
        ("Helvetica", "B"),
        ("Helvetica", "I"),
        ("Helvetica", "BI"),
        ("Times", ""),
        ("Times", "B"),
        ("Times", "I"),
        ("Times", "BI"),
        ("Courier", ""),
        ("Courier", "B"),
        ("Courier", "I"),
        ("Courier", "BI"),
        ("Symbol", ""),
        ("ZapfDingbats", ""),
    ]

    font_names = [
        "Helvetica",
        "Helvetica-Bold",
        "Helvetica-Oblique",
        "Helvetica-BoldOblique",
        "Times-Roman",
        "Times-Bold",
        "Times-Italic",
        "Times-BoldItalic",
        "Courier",
        "Courier-Bold",
        "Courier-Oblique",
        "Courier-BoldOblique",
        "Symbol",
        "ZapfDingbats",
    ]

    y = 30
    for (family, style), name in zip(fonts, font_names):
        pdf.set_font(family, style=style, size=10)
        pdf.text(50, y, name)
        y += 15

    pdf.output(OUTPUT_DIR / "all_fonts.pdf")
    print("  all_fonts.pdf")


def gen_multi_page():
    """Multi-page document."""
    pdf = make_pdf()

    pdf.add_page()
    pdf.set_font("Helvetica", size=24)
    pdf.text(50, 50, "Page 1")

    pdf.add_page()
    pdf.text(50, 50, "Page 2")

    pdf.add_page()
    pdf.text(50, 50, "Page 3")

    pdf.output(OUTPUT_DIR / "multi_page.pdf")
    print("  multi_page.pdf")


def gen_insert_page():
    """Reference for insertPage test - same output as multi_page, tests zpdf's insertPage."""
    pdf = make_pdf()

    pdf.add_page()
    pdf.set_font("Helvetica", size=24)
    pdf.text(50, 50, "Page 1")

    pdf.add_page()
    pdf.text(50, 50, "Page 2")

    pdf.add_page()
    pdf.text(50, 50, "Page 3")

    pdf.output(OUTPUT_DIR / "insert_page.pdf")
    print("  insert_page.pdf")


def gen_embedded_fonts():
    """PDF with embedded TTF fonts - dense one-pager."""
    pdf = make_pdf()

    # Font paths
    fonts_dir = Path("test/fonts")

    # Add Courier Prime family
    courier_dir = fonts_dir / "Courier Prime"
    pdf.add_font("CourierPrime", "", str(courier_dir / "Courier Prime.ttf"))
    pdf.add_font("CourierPrime", "B", str(courier_dir / "Courier Prime Bold.ttf"))
    pdf.add_font("CourierPrime", "I", str(courier_dir / "Courier Prime Italic.ttf"))
    pdf.add_font("CourierPrime", "BI", str(courier_dir / "Courier Prime Bold Italic.ttf"))

    # Add Charter family
    charter_dir = fonts_dir / "Charter"
    pdf.add_font("Charter", "", str(charter_dir / "Charter Regular.ttf"))
    pdf.add_font("Charter", "B", str(charter_dir / "Charter Bold.ttf"))
    pdf.add_font("Charter", "I", str(charter_dir / "Charter Italic.ttf"))
    pdf.add_font("Charter", "BI", str(charter_dir / "Charter Bold Italic.ttf"))

    pdf.add_page()
    y = 50

    # Large title
    pdf.set_font("Charter", "B", size=36)
    pdf.text(50, y, "Embedded Fonts")
    y += 50

    # Courier Prime - all styles
    pdf.set_font("CourierPrime", "", size=12)
    pdf.text(50, y, "Courier Prime Regular: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("CourierPrime", "B", size=12)
    pdf.text(50, y, "Courier Prime Bold: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("CourierPrime", "I", size=12)
    pdf.text(50, y, "Courier Prime Italic: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("CourierPrime", "BI", size=12)
    pdf.text(50, y, "Courier Prime Bold Italic: ABCabc 0123456789")
    y += 24

    # Charter - all styles
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Charter Regular: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("Charter", "B", size=12)
    pdf.text(50, y, "Charter Bold: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("Charter", "I", size=12)
    pdf.text(50, y, "Charter Italic: The quick brown fox jumps over the lazy dog.")
    y += 16
    pdf.set_font("Charter", "BI", size=12)
    pdf.text(50, y, "Charter Bold Italic: ABCabc 0123456789")
    y += 24

    # Unicode - Latin Extended (WinAnsi compatible)
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Extended Latin: \u00c0\u00c1\u00c2\u00c3\u00c4\u00c5\u00c6\u00c7\u00c8\u00c9\u00ca\u00cb \u00e0\u00e1\u00e2\u00e3\u00e4\u00e5\u00e6\u00e7\u00e8\u00e9\u00ea\u00eb")
    y += 16
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "More Latin: \u00d1\u00f1 \u00d8\u00f8 \u00df \u00c6\u00e6 \u00d0\u00f0 \u00de\u00fe \u00bf\u00a1")
    y += 16
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Currency: \u00a3 \u00a5 \u00a2 \u0192 | Math: \u00b1 \u00d7 \u00f7 \u00b0 \u00b2 \u00b3 \u00b9 \u00bc \u00bd \u00be \u00b5")
    y += 16
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Punctuation: \u2018single\u2019 \u201cdouble\u201d \u2013 \u2014 \u2026 \u00ab\u00bb \u00a9 \u00ae \u2122")
    y += 16
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Symbols: \u00a7 \u00b6 \u2020 \u2021 \u2022 \u00a6 \u00ac \u00b7 \u00aa \u00ba")
    y += 24

    # Mixed standard and embedded
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, y, "Helvetica (standard): ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    y += 16
    pdf.set_font("CourierPrime", "", size=12)
    pdf.text(50, y, "Courier Prime (embedded): ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    y += 24

    # Large sizes
    pdf.set_font("Charter", "B", size=24)
    pdf.text(50, y, "24pt Charter Bold")
    y += 32
    pdf.set_font("CourierPrime", "", size=18)
    pdf.text(50, y, "18pt Courier Prime Regular")
    y += 28

    # Character set
    pdf.set_font("CourierPrime", "", size=10)
    pdf.text(50, y, "!\"#$%&'()*+,-./0123456789:;<=>?@[\\]^_`{|}~")

    pdf.output(OUTPUT_DIR / "embedded_fonts.pdf")
    print("  embedded_fonts.pdf")


def gen_cid_fonts():
    """PDF with CID fonts (Identity-H encoding) for full Unicode support.

    Note: This test focuses on CID encoding and Unicode support, not OpenType features.
    We use text() instead of shaped_text() for consistent positioning with zpdf.
    """
    pdf = make_pdf()

    # Font paths
    fonts_dir = Path("test/fonts")

    # Add fonts - fpdf2 uses CID/Identity-H internally for TTF fonts
    charter_dir = fonts_dir / "Charter"
    pdf.add_font("Charter", "", str(charter_dir / "Charter Regular.ttf"))
    pdf.add_font("Charter", "B", str(charter_dir / "Charter Bold.ttf"))

    courier_dir = fonts_dir / "Courier Prime"
    pdf.add_font("CourierPrime", "", str(courier_dir / "Courier Prime.ttf"))

    pdf.add_page()
    y = 50

    # Title (using CID font)
    pdf.set_font("Charter", "", size=24)
    pdf.text(50, y, "CID Font Test (Identity-H Encoding)")
    y += 40

    # Basic ASCII text
    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "ASCII: The quick brown fox jumps over the lazy dog.")
    y += 20

    # UTF-8 encoded Unicode characters (Latin Extended)
    pdf.text(50, y, "Latin Extended: ÀÁÂÃÄÅÆÇÈÉÊË àáâãäåæçèéêë")
    y += 20

    # More Latin characters
    pdf.text(50, y, "More Latin: Ññ Øø ß Ææ Ðð Þþ ¿¡ Œœ")
    y += 20

    # Currency and math symbols (only those in Charter)
    pdf.text(50, y, "Symbols: £ ¥ ¢ ± × ÷ ° ² ³ ¹ ¼ ½ ¾")
    y += 20

    # Punctuation (only those in Charter)
    pdf.text(50, y, "Punctuation: \u2018single\u2019 \u201cdouble\u201d \u2013 \u2014 \u2026 \u00ab \u00bb \u00a9 \u00ae")
    y += 20

    # Mixed with Courier Prime
    pdf.set_font("CourierPrime", "", size=12)
    pdf.text(50, y, "Courier (CID): ABCDabcd 0123456789 £¥")
    y += 24

    # Compare with WinAnsi mode equivalent
    pdf.set_font("Charter", "B", size=12)
    pdf.text(50, y, "WinAnsi comparison: The quick brown fox")
    y += 20

    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "CID comparison: The quick brown fox")

    pdf.output(OUTPUT_DIR / "cid_fonts.pdf")
    print("  cid_fonts.pdf")


def gen_inter_fonts():
    """Dense one-pager showcasing Inter font in TTF and OTF formats with OpenType features."""
    pdf = make_pdf()

    fonts_dir = Path("test/fonts/Inter")

    # Add Inter TTF versions
    pdf.add_font("InterTTF", "", str(fonts_dir / "Inter-Regular.ttf"))
    pdf.add_font("InterTTF", "B", str(fonts_dir / "Inter-Bold.ttf"))
    pdf.add_font("InterTTF", "I", str(fonts_dir / "Inter-Italic.ttf"))
    pdf.add_font("InterTTF", "BI", str(fonts_dir / "Inter-BoldItalic.ttf"))

    # Add Inter OTF versions (CFF outlines)
    pdf.add_font("InterOTF", "", str(fonts_dir / "Inter-Regular.otf"))
    pdf.add_font("InterOTF", "B", str(fonts_dir / "Inter-Bold.otf"))
    pdf.add_font("InterOTF", "I", str(fonts_dir / "Inter-Italic.otf"))
    pdf.add_font("InterOTF", "BI", str(fonts_dir / "Inter-BoldItalic.otf"))

    pdf.add_page()
    y = 30

    # Title
    pdf.set_font("InterTTF", "B", size=24)
    pdf.text(50, y, "Inter Font Showcase")
    y += 20
    pdf.set_font("InterTTF", "", size=8)
    pdf.text(50, y, "TTF (TrueType) and OTF (CFF) versions with OpenType features")
    y += 20

    # === TTF Section ===
    pdf.set_font("InterTTF", "B", size=14)
    pdf.text(50, y, "TrueType (.ttf)")
    y += 16

    pdf.set_font("InterTTF", "", size=10)
    pdf.text(50, y, "Regular: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterTTF", "B", size=10)
    pdf.text(50, y, "Bold: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterTTF", "I", size=10)
    pdf.text(50, y, "Italic: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterTTF", "BI", size=10)
    pdf.text(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 16

    # === OTF Section ===
    pdf.set_font("InterOTF", "B", size=14)
    pdf.text(50, y, "OpenType/CFF (.otf)")
    y += 16

    pdf.set_font("InterOTF", "", size=10)
    pdf.text(50, y, "Regular: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterOTF", "B", size=10)
    pdf.text(50, y, "Bold: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterOTF", "I", size=10)
    pdf.text(50, y, "Italic: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 12
    pdf.set_font("InterOTF", "BI", size=10)
    pdf.text(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog. 0123456789")
    y += 18

    # === Unicode Coverage ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "Unicode Coverage")
    y += 14

    pdf.set_font("InterTTF", "", size=9)
    pdf.text(50, y, "Latin Extended: \u00c0\u00c1\u00c2\u00c3\u00c4\u00c5\u00c6\u00c7\u00c8\u00c9\u00ca\u00cb\u00cc\u00cd\u00ce\u00cf \u00e0\u00e1\u00e2\u00e3\u00e4\u00e5\u00e6\u00e7\u00e8\u00e9\u00ea\u00eb\u00ec\u00ed\u00ee\u00ef")
    y += 11
    pdf.text(50, y, "More Latin: \u00d0\u00d1\u00d2\u00d3\u00d4\u00d5\u00d6\u00d8\u00d9\u00da\u00db\u00dc\u00dd\u00de\u00df \u00f0\u00f1\u00f2\u00f3\u00f4\u00f5\u00f6\u00f8\u00f9\u00fa\u00fb\u00fc\u00fd\u00fe\u00ff")
    y += 11
    pdf.text(50, y, "Latin Extended-A: \u0100\u0101\u0102\u0103\u0104\u0105\u0106\u0107\u0108\u0109\u010a\u010b\u010c\u010d\u010e\u010f\u0110\u0111\u0112\u0113\u0114\u0115")
    y += 11
    pdf.text(50, y, "Latin Extended-B: \u0152\u0153\u0160\u0161\u0178\u017d\u017e\u0192")
    y += 11
    pdf.text(50, y, "Greek: \u0391\u0392\u0393\u0394\u0395\u0396\u0397\u0398\u0399 \u03b1\u03b2\u03b3\u03b4\u03b5\u03b6\u03b7\u03b8\u03b9")
    y += 11
    pdf.text(50, y, "Cyrillic: \u0410\u0411\u0412\u0413\u0414\u0415\u0416\u0417\u0418 \u0430\u0431\u0432\u0433\u0434\u0435\u0436\u0437\u0438")
    y += 13

    # === Punctuation & Symbols ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "Punctuation & Symbols")
    y += 14

    pdf.set_font("InterTTF", "", size=9)
    pdf.text(50, y, "Quotes: \u2018single\u2019 \u201cdouble\u201d \u00ab guillemets \u00bb \u2039single\u203a")
    y += 11
    pdf.text(50, y, "Dashes: hyphen- en\u2013dash em\u2014dash horizontal\u2015bar")
    y += 11
    pdf.text(50, y, "Currency: $ \u00a2 \u00a3 \u00a5 \u20ac \u20a3 \u20a4 \u20b9 \u20bd")
    y += 11
    pdf.text(50, y, "Math: + \u2212 \u00d7 \u00f7 = \u2260 < > \u2264 \u2265 \u00b1 \u221e \u2248")
    y += 11
    pdf.text(50, y, "Arrows: \u2190 \u2191 \u2192 \u2193 \u2194 \u2195 \u21d0 \u21d2 \u21d4")
    y += 11
    pdf.text(50, y, "Misc: \u00a9 \u00ae \u2122 \u00b0 \u00a7 \u00b6 \u2020 \u2021 \u2022 \u2026 \u00a6")
    y += 13

    # === Numbers & Figures ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "Numbers & Figures")
    y += 14

    pdf.set_font("InterTTF", "", size=9)
    pdf.text(50, y, "Lining figures: 0123456789 (default)")
    y += 11
    pdf.text(50, y, "Fractions: \u00bc \u00bd \u00be \u2153 \u2154 \u215b \u215c \u215d \u215e")
    y += 11
    pdf.text(50, y, "Superscript: \u00b9 \u00b2 \u00b3 \u2074 \u2075 \u2076 \u2077 \u2078 \u2079 \u2070")
    y += 11
    pdf.text(50, y, "Subscript: \u2080 \u2081 \u2082 \u2083 \u2084 \u2085 \u2086 \u2087 \u2088 \u2089")
    y += 11
    pdf.text(50, y, "Ordinals: 1\u00aa 2\u00ba 1st 2nd 3rd")
    y += 13

    # === OpenType Features (documented) ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "OpenType Features Available")
    y += 14

    pdf.set_font("InterTTF", "", size=8)
    pdf.text(50, y, "GSUB: aalt calt case ccmp cv01-cv14 dlig dnom frac locl numr ordn pnum salt sinf ss01-ss08 subs sups tnum zero")
    y += 10
    pdf.text(50, y, "GPOS: cpsp kern mark mkmk")
    y += 12

    # Feature examples (pre-composed where possible)
    pdf.set_font("InterTTF", "", size=9)
    pdf.text(50, y, "zero: Slashed zero 0 vs O (cv feature)")
    y += 11
    pdf.text(50, y, "tnum: Tabular 1111 vs pnum: Proportional 1111")
    y += 11
    pdf.text(50, y, "case: H\u00b7I vs H\u2022I (case-sensitive punctuation)")
    y += 11
    pdf.text(50, y, "frac: 1/2 1/4 3/4 (fraction feature)")
    y += 13

    # === ASCII Range ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "ASCII Character Set")
    y += 14

    pdf.set_font("InterTTF", "", size=8)
    pdf.text(50, y, "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`")
    y += 10
    pdf.text(50, y, "abcdefghijklmnopqrstuvwxyz{|}~")
    y += 13

    # === Size Comparison ===
    pdf.set_font("InterTTF", "B", size=12)
    pdf.text(50, y, "Size Comparison (TTF vs OTF)")
    y += 14

    pdf.set_font("InterTTF", "", size=18)
    pdf.text(50, y, "Inter TTF 18pt")
    pdf.set_font("InterOTF", "", size=18)
    pdf.text(250, y, "Inter OTF 18pt")
    y += 22

    pdf.set_font("InterTTF", "B", size=18)
    pdf.text(50, y, "Inter TTF Bold")
    pdf.set_font("InterOTF", "B", size=18)
    pdf.text(250, y, "Inter OTF Bold")

    pdf.output(OUTPUT_DIR / "inter_fonts.pdf")
    print("  inter_fonts.pdf")


def gen_opentype_features():
    """Dense one-pager showcasing OpenType ligatures, kerning, and numeric features.

    Note: fpdf2 text shaping only works with write()/multi_cell(), not text().
    We use write() with set_xy() for positioned text with shaping.
    """
    pdf = make_pdf()

    fonts_dir = Path("test/fonts")

    # Satoshi has liga (fi, fl, ff, ffi, ffl, f_t), kern, tnum, pnum
    satoshi_dir = fonts_dir / "Satoshi"
    pdf.add_font("Satoshi", "", str(satoshi_dir / "Satoshi-Regular.otf"))
    pdf.add_font("Satoshi", "B", str(satoshi_dir / "Satoshi-Bold.otf"))
    pdf.add_font("Satoshi", "I", str(satoshi_dir / "Satoshi-Italic.otf"))

    # Charter has kern but no liga
    charter_dir = fonts_dir / "Charter"
    pdf.add_font("Charter", "", str(charter_dir / "Charter Regular.ttf"))
    pdf.add_font("Charter", "B", str(charter_dir / "Charter Bold.ttf"))

    # Inter has tnum, pnum, zero, many cv features
    inter_dir = fonts_dir / "Inter"
    pdf.add_font("Inter", "", str(inter_dir / "Inter-Regular.ttf"))
    pdf.add_font("Inter", "B", str(inter_dir / "Inter-Bold.ttf"))

    pdf.add_page()
    y = 25

    # Title - enable text shaping with ligatures and kerning
    pdf.set_text_shaping(True, features={"liga": True, "kern": True})
    pdf.set_font("Satoshi", "B", size=20)
    shaped_text(pdf, 50, y, "OpenType Features Showcase")
    y += 16
    pdf.set_font("Satoshi", "", size=7)
    shaped_text(pdf, 50, y, "Ligatures (liga), Kerning (kern), Tabular Figures (tnum), and more")
    y += 12

    # === Ligatures Section ===
    pdf.set_font("Satoshi", "B", size=11)
    shaped_text(pdf, 50, y, "Standard Ligatures (liga)")
    y += 11

    pdf.set_font("Satoshi", "", size=9)
    shaped_text(pdf, 50, y, "Satoshi: fi fl ff ffi ffl ligatures enabled")
    y += 10

    # Words with ligatures - compact layout
    pdf.set_font("Satoshi", "", size=10)
    shaped_text(pdf, 50, y, "office efficient waffle difficult affidavit affluent")
    y += 12
    shaped_text(pdf, 50, y, "find five flow flag coffee effect staff differ suffix")
    y += 12
    shaped_text(pdf, 50, y, "after soft gift lift draft shift swift left craft")
    y += 14

    # === Kerning Section ===
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Kerning (kern)")
    y += 11

    pdf.set_font("Charter", "", size=10)
    pdf.set_text_shaping(True, features={"kern": True})
    shaped_text(pdf, 50, y, "AV AWAY AVATAR To Today We Weather LT AT TA VA WA Yo")
    y += 12
    shaped_text(pdf, 50, y, "Typography: proper letter spacing for readability")
    y += 14

    # === Tabular Figures ===
    # Note: tnum/pnum features not implemented in zpdf, so we just show the text with liga+kern
    pdf.set_text_shaping(True, features={"liga": True, "kern": True})
    pdf.set_font("Satoshi", "B", size=11)
    shaped_text(pdf, 50, y, "Tabular vs Proportional Figures (tnum/pnum)")
    y += 11

    pdf.set_font("Satoshi", "", size=9)
    shaped_text(pdf, 50, y, "Numbers align in columns when using tabular figures:")
    y += 10

    # Show tnum vs pnum side by side (zpdf doesn't implement tnum/pnum, so just use liga+kern)
    pdf.set_font("Satoshi", "", size=10)
    shaped_text(pdf, 50, y, "tnum: 1111  0000  1234")
    shaped_text(pdf, 200, y, "1,234.56")
    y += 11
    shaped_text(pdf, 50, y, "tnum: 9999  1010  5678")
    shaped_text(pdf, 200, y, "9,876.54")
    y += 12

    shaped_text(pdf, 50, y, "pnum: 1111  0000  1234")
    shaped_text(pdf, 200, y, "1,234.56")
    y += 11
    shaped_text(pdf, 50, y, "pnum: 9999  1010  5678")
    shaped_text(pdf, 200, y, "9,876.54")
    y += 14

    # === Inter stylistic features ===
    # Note: zero/tnum features not yet implemented in zpdf, so use text() for comparison
    pdf.set_font("Inter", "B", size=11)
    pdf.text(50, y, "Inter: Character Variants & Stylistic Sets")
    y += 11

    pdf.set_font("Inter", "", size=9)
    # Default (no shaping - zpdf doesn't implement these features yet)
    pdf.text(50, y, "Default: 0123456789 Il1| agy")
    y += 10

    # Slashed zero (zero feature) - using text() since zpdf doesn't implement zero
    pdf.text(50, y, "zero feature: 0123456789 (slashed zero)")
    y += 10

    # Tabular with slashed zero - using text() since zpdf doesn't implement tnum/zero
    pdf.text(50, y, "tnum+zero: 0123456789 (tabular + slashed)")
    y += 12

    # === Combined features paragraph ===
    pdf.set_text_shaping(True, features={"liga": True, "kern": True})
    pdf.set_font("Satoshi", "B", size=11)
    shaped_text(pdf, 50, y, "Paragraph with Multiple Features:")
    y += 11

    pdf.set_font("Satoshi", "", size=8)
    shaped_text(pdf, 50, y, "The efficient office staff finished 5,432 affidavits in 2024. Officials offered")
    y += 9
    shaped_text(pdf, 50, y, "to fix afflicted files worth $1,234,567.89. The coffee effect was sufficient after fifty")
    y += 9
    shaped_text(pdf, 50, y, "efforts. Different offices refined workflow: Task A=1111, B=2222, C=3333.")
    y += 12

    # === Bold/Italic with ligatures ===
    pdf.set_font("Satoshi", "B", size=10)
    shaped_text(pdf, 50, y, "Styles: Bold: office efficient waffle")
    y += 11
    pdf.set_font("Satoshi", "I", size=10)
    shaped_text(pdf, 50, y, "Styles: Italic: office efficient waffle")
    y += 12

    # Footer note
    pdf.set_font("Satoshi", "", size=6)
    shaped_text(pdf, 50, y, "Features: liga=ligatures, kern=kerning, tnum=tabular figures, pnum=proportional figures, zero=slashed zero")

    pdf.output(OUTPUT_DIR / "opentype_features.pdf")
    print("  opentype_features.pdf")


def gen_text_flow():
    """Text Flow API test - regions, margins, writeStyled."""
    pdf = make_pdf()
    pdf.set_margins(72, 72, 72)  # 1 inch margins
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(72, 72, "Text Flow API Test")

    # Calculate region (page width - margins)
    region_x = 72
    region_width = 595.28 - 72 - 72  # A4 width - margins
    y = 112  # Start below title

    # Test lines with different alignments
    pdf.set_font("Helvetica", "", size=12)

    # Left aligned (default) - use cell for consistency with other alignments
    pdf.set_xy(region_x, y)
    pdf.cell(region_width, 14.4, "Left aligned line (default)", align="L")
    y += 14.4  # line height = font_size * 1.2

    # Center aligned - use cell with alignment
    pdf.set_xy(region_x, y)
    pdf.cell(region_width, 14.4, "Center aligned line", align="C")
    y += 14.4

    # Right aligned - use cell with alignment
    pdf.set_xy(region_x, y)
    pdf.cell(region_width, 14.4, "Right aligned line", align="R")
    y += 14.4

    # Spacing
    y += 12

    # Word Wrapping Test header
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Word Wrapping Test:")
    y += 14.4

    # Word wrapping paragraph using multi_cell
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y)
    paragraph1 = ("This is a test paragraph that demonstrates word wrapping. "
                  "The text should automatically wrap to fit within the region width. "
                  "Long words like supercalifragilisticexpialidocious should also be handled.")
    pdf.multi_cell(w=region_width, h=11 * 1.2, text=paragraph1, align="L")
    y = pdf.get_y() + 12

    # Demo 1: Regular hyphens - compound words stay together (100pt column)
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Regular Hyphens (100pt column):")
    y += 14.4

    # At 11pt: "Look:" ~22pt, "state-of-the-art" ~86pt
    # "Look: state-of-the-art" ~111pt > 100pt, so word wraps to next line
    # With break_on_hyphens=false, the compound word stays intact
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y)
    paragraph2a = "Look: state-of-the-art works."
    pdf.multi_cell(w=100, h=11 * 1.2, text=paragraph2a, align="L")
    y = pdf.get_y() + 12

    # Demo 2: Soft-hyphens - word breaks at soft-hyphen point (26pt column)
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Soft-Hyphens (26pt column):")
    y += 14.4

    # At 11pt: "in-" ~12.8pt, "com-" ~24.4pt, both fit in 26pt
    # Word breaks recursively at soft-hyphen points
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y)
    paragraph2b = "in\u00adcom\u00adpre\u00adhen\u00adsi\u00adble"
    pdf.multi_cell(w=26, h=11 * 1.2, text=paragraph2b, align="L")
    y = pdf.get_y() + 12

    # Demo 3: Character wrap - long word without soft-hyphens in narrow column
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Character Wrap (50pt column):")
    y += 14.4

    # "supercalifragilisticexpialidocious" is ~155pt at 11pt, won't fit in 50pt
    # Without soft-hyphens, it overflows the line (character-level handling)
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y)
    pdf.multi_cell(w=50, h=11 * 1.2, text="supercalifragilisticexpialidocious", align="L")
    y = pdf.get_y() + 12

    # Centered Paragraph header
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Centered Paragraph:")
    y += 14.4

    # Centered paragraph
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y)
    paragraph3 = ("This paragraph is center aligned. Each line of text "
                  "will be centered within the region width.")
    pdf.multi_cell(w=region_width, h=11 * 1.2, text=paragraph3, align="C")
    y = pdf.get_y() + 12

    # Overflow Test header - 150pt width forces more wrapping
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Overflow Test (150pt wide, 30pt tall):")
    y += 14.4

    # 150pt width forces more line wraps; 30pt height fits ~2 lines at 13.2pt each
    pdf.set_font("Helvetica", "", size=11)
    overflow_text = ("Line one fits here. Line two fits here. "
                     "Line three overflows. Line four overflows.")
    line_height = 11 * 1.2
    lines_that_fit = int(30 / line_height)  # 2 lines
    col_width = 150
    words = overflow_text.split()
    current_line = ""
    lines_output = 0
    overflow_words = []

    for i, word in enumerate(words):
        test_line = current_line + (" " if current_line else "") + word
        if pdf.get_string_width(test_line) <= col_width:
            current_line = test_line
        else:
            if lines_output < lines_that_fit:
                pdf.set_xy(region_x, y + lines_output * line_height)
                pdf.cell(w=col_width, h=line_height, text=current_line, align="L")
                lines_output += 1
                current_line = word
            else:
                overflow_words = words[i-1:]
                break

    # Handle last line
    if current_line and lines_output < lines_that_fit:
        pdf.set_xy(region_x, y + lines_output * line_height)
        pdf.cell(w=col_width, h=line_height, text=current_line, align="L")
        lines_output += 1
    elif current_line:
        if not overflow_words:
            overflow_words = [current_line]

    y += lines_output * line_height + 12

    # Show what overflowed
    pdf.set_font("Helvetica", "B", size=10)
    pdf.text(region_x, y, "Overflow content:")
    y += 12
    pdf.set_font("Helvetica", "", size=10)
    if overflow_words:
        overflow_content = " ".join(overflow_words)[:60]  # Truncate for display
        pdf.text(region_x, y, overflow_content)
    else:
        pdf.text(region_x, y, "(no overflow)")
    y += 16

    # Region with Border header
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(region_x, y, "Region with Border:")
    y += 14.4

    # Draw bordered region with fill
    box_height = 60
    pdf.set_fill_color(242, 242, 242)  # Light gray (0.95 * 255)
    pdf.rect(region_x, y, region_width, box_height, style="FD")

    # Text inside box
    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(region_x, y + 5)
    pdf.multi_cell(w=region_width, h=11 * 1.2,
                   text="This text is inside a bordered region with a light gray background fill.",
                   align="L")

    pdf.output(OUTPUT_DIR / "text_flow.pdf")
    print("  text_flow.pdf")


def gen_colored_text():
    """Test colored text using various color spaces."""
    pdf = make_pdf()
    pdf.add_page()

    y = 50

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, y, "Colored Text Test")
    y += 30

    # Black text (default)
    pdf.set_font("Helvetica", "", size=12)
    pdf.set_text_color(0, 0, 0)  # Black
    pdf.text(50, y, "Black text (default)")
    y += 20

    # Red text
    pdf.set_text_color(255, 0, 0)  # Red
    pdf.text(50, y, "Red text (RGB: 255, 0, 0)")
    y += 20

    # Green text
    pdf.set_text_color(0, 255, 0)  # Green
    pdf.text(50, y, "Green text (RGB: 0, 255, 0)")
    y += 20

    # Blue text
    pdf.set_text_color(0, 0, 255)  # Blue
    pdf.text(50, y, "Blue text (RGB: 0, 0, 255)")
    y += 20

    # Gray text (using grayscale)
    pdf.set_text_color(128)  # 50% gray
    pdf.text(50, y, "Gray text (50% gray)")
    y += 20

    # Custom color (orange)
    pdf.set_text_color(255, 165, 0)  # Orange
    pdf.text(50, y, "Orange text (RGB: 255, 165, 0)")
    y += 20

    # Back to black
    pdf.set_text_color(0, 0, 0)
    pdf.text(50, y, "Back to black text")
    y += 30

    # Multiple colors on same line (using multiple text() calls)
    pdf.set_font("Helvetica", "B", size=12)
    pdf.set_text_color(0, 0, 0)
    pdf.text(50, y, "Mixed colors: ")
    pdf.set_text_color(255, 0, 0)
    pdf.text(145, y, "Red ")
    pdf.set_text_color(0, 255, 0)
    pdf.text(175, y, "Green ")
    pdf.set_text_color(0, 0, 255)
    pdf.text(220, y, "Blue")

    pdf.output(OUTPUT_DIR / "colored_text.pdf")
    print("  colored_text.pdf")


def gen_justify():
    """Test justified text alignment."""
    pdf = make_pdf()
    pdf.add_page()

    y = 50

    # Title
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, y, "Justified Text Alignment")
    y += 24

    # Standard paragraph width (451 pts = page width - 72pt margins each side)
    region_width = 451

    # Test 1: Long justified paragraph (multiple lines)
    pdf.set_font("Helvetica", "B", size=11)
    pdf.text(50, y, "Long Justified Paragraph:")
    y += 14.4

    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(50, y)
    text1 = ("Typography is the art and technique of arranging type to make written "
             "language legible, readable, and appealing when displayed. The arrangement "
             "of type involves selecting typefaces, point sizes, line lengths, line spacing, "
             "and letter spacing, as well as adjusting the space between pairs of letters. "
             "Justified text creates clean edges on both sides of a text block, which many "
             "readers find visually appealing. However, it can create uneven spacing between "
             "words, especially in narrow columns. The last line is typically left-aligned.")
    pdf.multi_cell(w=region_width, h=11 * 1.2, text=text1, align="J")
    y = pdf.get_y() + 16

    # Test 2: Narrow column justified (more lines)
    pdf.set_font("Helvetica", "B", size=11)
    pdf.text(50, y, "Narrow Column (200pt):")
    y += 14.4

    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(50, y)
    text2 = ("In narrow columns, justified text requires more word spacing adjustment. "
             "Each line must stretch to fill the available width, which can create "
             "noticeable gaps between words. Good typography balances readability with "
             "visual appeal. The spacing should be even across the paragraph.")
    pdf.multi_cell(w=200, h=11 * 1.2, text=text2, align="J")
    y = pdf.get_y() + 16

    # Test 3: Compare left vs justify with same long text
    compare_text = ("The quick brown fox jumps over the lazy dog. Pack my box with five "
                    "dozen liquor jugs. How vexingly quick daft zebras jump. The five boxing "
                    "wizards jump quickly. Sphinx of black quartz, judge my vow.")

    pdf.set_font("Helvetica", "B", size=11)
    pdf.text(50, y, "Comparison - Left Aligned:")
    y += 14.4

    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(50, y)
    pdf.multi_cell(w=300, h=11 * 1.2, text=compare_text, align="L")
    y = pdf.get_y() + 12

    pdf.set_font("Helvetica", "B", size=11)
    pdf.text(50, y, "Comparison - Justified:")
    y += 14.4

    pdf.set_font("Helvetica", "", size=11)
    pdf.set_xy(50, y)
    pdf.multi_cell(w=300, h=11 * 1.2, text=compare_text, align="J")

    pdf.output(OUTPUT_DIR / "justify.pdf")
    print("  justify.pdf")


def gen_shapes():
    """Test graphics primitives: lines, rectangles, circles, ellipses, polygons."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Graphics Primitives Test")

    y = 60

    # === Lines ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Lines:")
    y += 15

    # Simple line
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)
    pdf.line(50, y, 150, y)
    y += 10

    # Thick line
    pdf.set_line_width(3)
    pdf.line(50, y, 150, y)
    y += 10

    # Colored line
    pdf.set_draw_color(255, 0, 0)  # Red
    pdf.set_line_width(2)
    pdf.line(50, y, 150, y)
    y += 10

    # Dashed line
    pdf.set_draw_color(0, 0, 255)  # Blue
    pdf.set_dash_pattern(dash=5, gap=3)
    pdf.line(50, y, 150, y)
    pdf.set_dash_pattern()  # Reset to solid
    y += 20

    # Reset colors
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)

    # === Rectangles ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Rectangles:")
    y += 15

    # Stroke only
    pdf.rect(50, y, 60, 30, style="D")  # D = Draw (stroke)

    # Fill only
    pdf.set_fill_color(200, 200, 255)  # Light blue
    pdf.rect(130, y, 60, 30, style="F")  # F = Fill

    # Fill and stroke
    pdf.set_fill_color(255, 200, 200)  # Light red
    pdf.set_draw_color(255, 0, 0)  # Red border
    pdf.set_line_width(2)
    pdf.rect(210, y, 60, 30, style="FD")  # FD = Fill + Draw
    y += 45

    # Reset
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)

    # === Rounded Rectangles ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Rounded Rectangles:")
    y += 15

    # Small radius
    pdf.rect(50, y, 60, 30, style="D", round_corners=True, corner_radius=5)

    # Medium radius
    pdf.set_fill_color(255, 230, 200)  # Light orange
    pdf.rect(130, y, 60, 30, style="F", round_corners=True, corner_radius=10)

    # Large radius (pill shape) - use 14 not 15 to avoid fpdf2 edge case bug
    pdf.set_fill_color(200, 230, 255)  # Light blue
    pdf.set_draw_color(0, 0, 255)  # Blue
    pdf.set_line_width(2)
    pdf.rect(210, y, 80, 30, style="FD", round_corners=True, corner_radius=14)
    y += 45

    # Reset
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)

    # === Circles ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Circles:")
    y += 15

    # Stroke circle
    pdf.circle(80, y + 25, 25, style="D")

    # Filled circle
    pdf.set_fill_color(200, 255, 200)  # Light green
    pdf.circle(160, y + 25, 25, style="F")

    # Fill and stroke
    pdf.set_fill_color(255, 255, 200)  # Light yellow
    pdf.set_draw_color(0, 128, 0)  # Dark green
    pdf.set_line_width(2)
    pdf.circle(240, y + 25, 25, style="FD")
    y += 65

    # Reset
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)

    # === Ellipses ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Ellipses:")
    y += 15

    # Horizontal ellipse
    pdf.ellipse(80, y + 20, 40, 20, style="D")

    # Vertical ellipse
    pdf.set_fill_color(255, 200, 255)  # Light magenta
    pdf.ellipse(180, y + 20, 20, 30, style="FD")

    # Large ellipse
    pdf.set_fill_color(200, 255, 255)  # Light cyan
    pdf.ellipse(280, y + 20, 50, 20, style="F")
    y += 55

    # === Polygons ===
    pdf.set_font("Helvetica", "B", size=12)
    pdf.text(50, y, "Polygons:")
    y += 15

    # Triangle
    pdf.set_draw_color(0, 0, 0)
    pdf.polygon([(80, y), (50, y + 40), (110, y + 40)], style="D")

    # Square
    pdf.set_fill_color(255, 220, 180)  # Light orange
    pdf.polygon([(140, y), (180, y), (180, y + 40), (140, y + 40)], style="F")

    # Pentagon
    import math
    cx, cy, r = 250, y + 20, 25
    pentagon = []
    for i in range(5):
        angle = math.pi / 2 + i * 2 * math.pi / 5  # Start from top
        px = cx + r * math.cos(angle)
        py = cy - r * math.sin(angle)  # Flip Y for PDF coords
        pentagon.append((px, py))
    pdf.set_fill_color(220, 220, 255)  # Light purple
    pdf.set_draw_color(100, 100, 200)
    pdf.set_line_width(2)
    pdf.polygon(pentagon, style="FD")

    pdf.output(OUTPUT_DIR / "shapes.pdf")
    print("  shapes.pdf")


def gen_images():
    """Test image embedding: JPEG and PNG with various sizes and positions."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Image Embedding Test")

    # Left column: JPEG
    pdf.set_font("Helvetica", "B", size=10)
    pdf.text(50, 50, "JPEG (100x140):")
    pdf.image("test/images/madonna_and_child_1939.1.256.jpg", x=50, y=55, w=100, h=140)

    pdf.text(50, 210, "JPEG w=80 (h auto):")
    pdf.image("test/images/madonna_and_child_1939.1.256.jpg", x=50, y=215, w=80)

    # Right column: PNG with alpha
    pdf.text(200, 50, "PNG with alpha (80x120):")
    pdf.image("test/images/robot.png", x=200, y=55, w=80, h=120)

    pdf.text(200, 190, "PNG h=100 (w auto):")
    pdf.image("test/images/robot.png", x=200, y=195, h=100)

    pdf.output(OUTPUT_DIR / "images.pdf")
    print("  images.pdf")


def gen_svg():
    """Test SVG embedding as Form XObjects."""
    from fpdf.svg import SVGImage
    import os

    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "SVG Embedding Test")

    # Row 1: Test SVG samples
    pdf.set_font("Helvetica", "B", size=10)
    pdf.text(50, 50, "Original (200x200):")
    pdf.image("test/images/test.svg", x=50, y=55, w=200, h=200)

    pdf.text(280, 50, "Scaled (100x100):")
    pdf.image("test/images/test.svg", x=280, y=55, w=100, h=100)

    pdf.text(420, 50, "Width=80:")
    pdf.image("test/images/test.svg", x=420, y=55, w=80)

    # Row 2: Tiger SVG
    if os.path.exists("test/images/tiger.svg"):
        pdf.text(50, 280, "Tiger SVG (400x400):")
        # Center on page: (595 - 400) / 2 = 97.5
        pdf.image("test/images/tiger.svg", x=97, y=295, w=400, h=400)

    # Note: opacity_test.svg not included - fpdf2 doesn't support rgba colors

    pdf.output(OUTPUT_DIR / "svg.pdf")
    print("  svg.pdf")


def gen_svg_text():
    """Test SVG text elements with various fonts and styles."""
    import os

    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "SVG Text Test")

    # Full-size text SVG
    pdf.set_font("Helvetica", "B", size=10)
    pdf.text(50, 60, "Text SVG (400x300):")
    pdf.image("test/images/text-sample.svg", x=50, y=75, w=400, h=300)

    # Scaled version
    pdf.text(50, 400, "Scaled (200x150):")
    pdf.image("test/images/text-sample.svg", x=50, y=415, w=200, h=150)

    pdf.output(OUTPUT_DIR / "svg_text.pdf")
    print("  svg_text.pdf")


def gen_svg_use_defs():
    """Test SVG <use> and <defs> elements."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "SVG Use/Defs Test")

    # Use/Defs test SVG
    pdf.set_font("Helvetica", "B", size=10)
    pdf.text(50, 60, "Reusable symbols via <use> and <defs>:")
    pdf.image("test/images/use-defs.svg", x=50, y=75, w=300, h=200)

    pdf.output(OUTPUT_DIR / "svg_use_defs.pdf")
    print("  svg_use_defs.pdf")


def gen_paths():
    """Test path API: moveTo, lineTo, curveTo using fpdf2 drawing module."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Path API Test")

    y = 70

    # Triangle using polygon (equivalent to moveTo/lineTo/close)
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Triangle (moveTo, lineTo, closePath):")
    y += 15

    pdf.set_draw_color(0, 0, 255)
    pdf.set_fill_color(200, 200, 255)
    pdf.set_line_width(2)
    pdf.polygon([(100, y), (180, y), (140, y + 60)], style="FD")
    y += 80

    # Bezier curve using pdf.bezier()
    pdf.set_font("Helvetica", "", size=10)
    pdf.set_draw_color(0, 0, 0)
    pdf.text(50, y, "Cubic Bezier curve (curveTo):")
    y += 15

    pdf.set_draw_color(255, 0, 0)
    pdf.set_fill_color(255, 200, 200)
    pdf.set_line_width(2)
    # Simple bezier shape - a curve and its mirror
    pdf.bezier([(50, y + 50), (100, y), (200, y), (250, y + 50)], style="D")
    y += 70

    # Heart shape using bezier
    pdf.set_font("Helvetica", "", size=10)
    pdf.set_draw_color(0, 0, 0)
    pdf.text(50, y, "Heart shape (bezier curves):")
    y += 15

    pdf.set_draw_color(200, 0, 0)
    pdf.set_fill_color(255, 0, 0)
    pdf.set_line_width(1)
    # Left half of heart
    hx, hy = 140, y + 30
    pdf.bezier([(hx, hy), (hx - 30, hy - 30), (hx - 50, hy + 10), (hx, hy + 50)], style="F")
    # Right half of heart
    pdf.bezier([(hx, hy), (hx + 30, hy - 30), (hx + 50, hy + 10), (hx, hy + 50)], style="F")
    y += 95  # Extra spacing to avoid overlap with zigzag label

    # Stroke only path (zigzag) using polygon with style="D"
    pdf.set_font("Helvetica", "", size=10)
    pdf.set_draw_color(0, 0, 0)
    pdf.text(50, y, "Stroke only (zigzag):")
    y += 15

    pdf.set_draw_color(0, 128, 0)
    pdf.set_line_width(3)
    points = [(50, y)]
    for i in range(8):
        px = 50 + (i + 1) * 25
        py = y + 30 if i % 2 == 0 else y
        points.append((px, py))
    # Use polyline for open path (no closing)
    pdf.polyline(points, style="D")

    pdf.output(OUTPUT_DIR / "paths.pdf")
    print("  paths.pdf")


def gen_landscape():
    """Test page sizes and orientations."""
    # Page 1: A4 portrait (default)
    pdf = FPDF(unit="pt", format="A4")
    pdf.set_margins(0, 0, 0)
    pdf.set_auto_page_break(False)
    pdf.add_page()
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 50, "Page 1: A4 Portrait (595 x 842)")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, f"Width: {pdf.w:.2f} pt")
    pdf.text(50, 100, f"Height: {pdf.h:.2f} pt")

    # Page 2: A4 landscape
    pdf.add_page(orientation="L")
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 50, "Page 2: A4 Landscape (842 x 595)")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, f"Width: {pdf.w:.2f} pt")
    pdf.text(50, 100, f"Height: {pdf.h:.2f} pt")

    # Page 3: Letter portrait
    pdf.add_page(orientation="P", format="Letter")
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 50, "Page 3: Letter Portrait (612 x 792)")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, f"Width: {pdf.w:.2f} pt")
    pdf.text(50, 100, f"Height: {pdf.h:.2f} pt")

    # Page 4: Letter landscape
    pdf.add_page(orientation="L", format="Letter")
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 50, "Page 4: Letter Landscape (792 x 612)")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, f"Width: {pdf.w:.2f} pt")
    pdf.text(50, 100, f"Height: {pdf.h:.2f} pt")

    # Page 5: Custom size
    pdf.add_page(orientation="P", format=(400, 300))
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 50, "Page 5: Custom (400 x 300)")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, f"Width: {pdf.w:.2f} pt")
    pdf.text(50, 100, f"Height: {pdf.h:.2f} pt")

    pdf.output(OUTPUT_DIR / "landscape.pdf")
    print("  landscape.pdf")


def gen_gradients():
    """Test gradient API: linear and radial gradients."""
    from fpdf.pattern import LinearGradient, RadialGradient

    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Gradient Test")

    y = 70

    # Linear gradient horizontal
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Linear gradient (horizontal):")
    y += 15

    grad1 = LinearGradient(50, y, 250, y, colors=["#FF0000", "#0000FF"])
    with pdf.use_pattern(grad1):
        pdf.rect(50, y, 200, 50, style="F")
    y += 70

    # Linear gradient vertical
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Linear gradient (vertical):")
    y += 15

    grad2 = LinearGradient(50, y, 50, y + 50, colors=["#FFFF00", "#008000"])
    with pdf.use_pattern(grad2):
        pdf.rect(50, y, 200, 50, style="F")
    y += 70

    # Linear gradient 3 colors
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Linear gradient (3 colors):")
    y += 15

    grad3 = LinearGradient(50, y, 250, y, colors=["#FF0000", "#FFFFFF", "#0000FF"])
    with pdf.use_pattern(grad3):
        pdf.rect(50, y, 200, 50, style="F")
    y += 70

    # Radial gradient
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Radial gradient:")
    y += 15

    grad4 = RadialGradient(150, y + 40, 0, 150, y + 40, 60, colors=["#FFFFFF", "#000080"])
    with pdf.use_pattern(grad4):
        pdf.rect(50, y, 200, 80, style="F")

    pdf.output(OUTPUT_DIR / "gradients.pdf")
    print("  gradients.pdf")


def gen_opacity():
    """Test opacity/transparency API: fill and stroke alpha."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Opacity Test")

    y = 70

    # Fill opacity - overlapping rectangles
    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Fill opacity (overlapping rectangles):")
    y += 20

    # First rect - solid red
    pdf.set_fill_color(255, 0, 0)
    pdf.rect(50, y, 120, 80, style="F")

    # Second rect - blue with 50% opacity
    with pdf.local_context(fill_opacity=0.5):
        pdf.set_fill_color(0, 0, 255)
        pdf.rect(90, y + 20, 120, 80, style="F")

    # Third rect - green with 50% opacity
    with pdf.local_context(fill_opacity=0.5):
        pdf.set_fill_color(0, 200, 0)
        pdf.rect(130, y + 40, 120, 80, style="F")
    y += 150

    # Different opacity levels
    pdf.text(50, y, "Fill opacity levels (100%, 75%, 50%, 25%):")
    y += 20

    opacities = [1.0, 0.75, 0.5, 0.25]
    for i, op in enumerate(opacities):
        with pdf.local_context(fill_opacity=op):
            pdf.set_fill_color(0, 100, 200)
            pdf.rect(50 + i * 55, y, 50, 50, style="F")
    y += 80

    # Stroke opacity
    pdf.text(50, y, "Stroke opacity (overlapping lines):")
    y += 20

    # Solid red line
    pdf.set_draw_color(255, 0, 0)
    pdf.set_line_width(8)
    pdf.line(50, y, 250, y + 60)

    # Blue line with 50% stroke opacity
    with pdf.local_context(stroke_opacity=0.5):
        pdf.set_draw_color(0, 0, 255)
        pdf.set_line_width(8)
        pdf.line(50, y + 60, 250, y)
    y += 90

    # Combined fill and stroke opacity
    pdf.text(50, y, "Combined fill + stroke opacity:")
    y += 20

    # Rounded rect with fill opacity 0.6, stroke opacity 0.8
    with pdf.local_context(fill_opacity=0.6, stroke_opacity=0.8):
        pdf.set_fill_color(255, 200, 0)
        pdf.set_draw_color(100, 0, 100)
        pdf.set_line_width(4)
        pdf.rect(50, y, 100, 60, style="FD", round_corners=True, corner_radius=10)

    # Semi-transparent circle
    with pdf.local_context(fill_opacity=0.4):
        pdf.set_fill_color(0, 180, 180)
        pdf.set_draw_color(0, 0, 0)
        pdf.set_line_width(2)
        pdf.circle(250, y + 30, 35, style="FD")
    y += 100

    # Ellipse with opacity
    pdf.text(50, y, "Ellipse with opacity:")
    y += 20

    with pdf.local_context(fill_opacity=0.7):
        pdf.set_fill_color(200, 100, 50)
        pdf.ellipse(50, y, 120, 60, style="F")

    pdf.output(OUTPUT_DIR / "opacity.pdf")
    print("  opacity.pdf")


def gen_colors():
    """Generate color swatches reference with all 148 CSS named colors."""
    from fpdf import FPDF

    # Use pt units to match zpdf coordinates
    pdf = FPDF(unit="pt", format="A4")
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, 25, "CSS Named Colors")

    # All 148 CSS named colors (excluding aliases: grey variants, aqua, fuchsia)
    colors = [
        # Blacks and Grays (12)
        ("black", (0, 0, 0)),
        ("white", (255, 255, 255)),
        ("gray", (128, 128, 128)),
        ("silver", (192, 192, 192)),
        ("darkgray", (169, 169, 169)),
        ("dimgray", (105, 105, 105)),
        ("lightgray", (211, 211, 211)),
        ("gainsboro", (220, 220, 220)),
        ("whitesmoke", (245, 245, 245)),
        ("slategray", (112, 128, 144)),
        ("lightslategray", (119, 136, 153)),
        ("darkslategray", (47, 79, 79)),
        # Reds (7)
        ("red", (255, 0, 0)),
        ("darkred", (139, 0, 0)),
        ("firebrick", (178, 34, 34)),
        ("indianred", (205, 92, 92)),
        ("lightcoral", (240, 128, 128)),
        ("crimson", (220, 20, 60)),
        ("maroon", (128, 0, 0)),
        # Pinks (6)
        ("pink", (255, 192, 203)),
        ("lightpink", (255, 182, 193)),
        ("hotpink", (255, 105, 180)),
        ("deeppink", (255, 20, 147)),
        ("palevioletred", (219, 112, 147)),
        ("mediumvioletred", (199, 21, 133)),
        # Oranges (5)
        ("orange", (255, 165, 0)),
        ("darkorange", (255, 140, 0)),
        ("orangered", (255, 69, 0)),
        ("tomato", (255, 99, 71)),
        ("coral", (255, 127, 80)),
        # Yellows (11)
        ("yellow", (255, 255, 0)),
        ("lightyellow", (255, 255, 224)),
        ("lemonchiffon", (255, 250, 205)),
        ("lightgoldenrodyellow", (250, 250, 210)),
        ("papayawhip", (255, 239, 213)),
        ("moccasin", (255, 228, 181)),
        ("peachpuff", (255, 218, 185)),
        ("palegoldenrod", (238, 232, 170)),
        ("khaki", (240, 230, 140)),
        ("darkkhaki", (189, 183, 107)),
        ("gold", (255, 215, 0)),
        # Browns (11)
        ("brown", (165, 42, 42)),
        ("saddlebrown", (139, 69, 19)),
        ("sienna", (160, 82, 45)),
        ("chocolate", (210, 105, 30)),
        ("peru", (205, 133, 63)),
        ("sandybrown", (244, 164, 96)),
        ("burlywood", (222, 184, 135)),
        ("tan", (210, 180, 140)),
        ("rosybrown", (188, 143, 143)),
        ("goldenrod", (218, 165, 32)),
        ("darkgoldenrod", (184, 134, 11)),
        # Greens (21)
        ("green", (0, 128, 0)),
        ("lime", (0, 255, 0)),
        ("limegreen", (50, 205, 50)),
        ("lightgreen", (144, 238, 144)),
        ("palegreen", (152, 251, 152)),
        ("darkgreen", (0, 100, 0)),
        ("forestgreen", (34, 139, 34)),
        ("seagreen", (46, 139, 87)),
        ("mediumseagreen", (60, 179, 113)),
        ("springgreen", (0, 255, 127)),
        ("mediumspringgreen", (0, 250, 154)),
        ("mediumaquamarine", (102, 205, 170)),
        ("aquamarine", (127, 255, 212)),
        ("darkseagreen", (143, 188, 143)),
        ("yellowgreen", (154, 205, 50)),
        ("greenyellow", (173, 255, 47)),
        ("chartreuse", (127, 255, 0)),
        ("lawngreen", (124, 252, 0)),
        ("olive", (128, 128, 0)),
        ("olivedrab", (107, 142, 35)),
        ("darkolivegreen", (85, 107, 47)),
        # Cyans (10)
        ("cyan", (0, 255, 255)),
        ("lightcyan", (224, 255, 255)),
        ("paleturquoise", (175, 238, 238)),
        ("turquoise", (64, 224, 208)),
        ("mediumturquoise", (72, 209, 204)),
        ("darkturquoise", (0, 206, 209)),
        ("darkcyan", (0, 139, 139)),
        ("teal", (0, 128, 128)),
        ("lightseagreen", (32, 178, 170)),
        ("cadetblue", (95, 158, 160)),
        # Blues (16)
        ("blue", (0, 0, 255)),
        ("navy", (0, 0, 128)),
        ("darkblue", (0, 0, 139)),
        ("mediumblue", (0, 0, 205)),
        ("midnightblue", (25, 25, 112)),
        ("royalblue", (65, 105, 225)),
        ("steelblue", (70, 130, 180)),
        ("dodgerblue", (30, 144, 255)),
        ("deepskyblue", (0, 191, 255)),
        ("cornflowerblue", (100, 149, 237)),
        ("skyblue", (135, 206, 235)),
        ("lightskyblue", (135, 206, 250)),
        ("lightblue", (173, 216, 230)),
        ("lightsteelblue", (176, 196, 222)),
        ("powderblue", (176, 224, 230)),
        ("aliceblue", (240, 248, 255)),
        # Purples (18)
        ("purple", (128, 0, 128)),
        ("magenta", (255, 0, 255)),
        ("darkmagenta", (139, 0, 139)),
        ("indigo", (75, 0, 130)),
        ("darkslateblue", (72, 61, 139)),
        ("slateblue", (106, 90, 205)),
        ("mediumslateblue", (123, 104, 238)),
        ("mediumpurple", (147, 112, 219)),
        ("blueviolet", (138, 43, 226)),
        ("darkviolet", (148, 0, 211)),
        ("darkorchid", (153, 50, 204)),
        ("mediumorchid", (186, 85, 211)),
        ("orchid", (218, 112, 214)),
        ("violet", (238, 130, 238)),
        ("plum", (221, 160, 221)),
        ("thistle", (216, 191, 216)),
        ("lavender", (230, 230, 250)),
        ("rebeccapurple", (102, 51, 153)),
        # Whites and off-whites (19)
        ("snow", (255, 250, 250)),
        ("honeydew", (240, 255, 240)),
        ("mintcream", (245, 255, 250)),
        ("azure", (240, 255, 255)),
        ("ghostwhite", (248, 248, 255)),
        ("floralwhite", (255, 250, 240)),
        ("ivory", (255, 255, 240)),
        ("beige", (245, 245, 220)),
        ("linen", (250, 240, 230)),
        ("oldlace", (253, 245, 230)),
        ("antiquewhite", (250, 235, 215)),
        ("bisque", (255, 228, 196)),
        ("blanchedalmond", (255, 235, 205)),
        ("navajowhite", (255, 222, 173)),
        ("wheat", (245, 222, 179)),
        ("cornsilk", (255, 248, 220)),
        ("seashell", (255, 245, 238)),
        ("lavenderblush", (255, 240, 245)),
        ("mistyrose", (255, 228, 225)),
        # Salmons (3)
        ("salmon", (250, 128, 114)),
        ("lightsalmon", (255, 160, 122)),
        ("darksalmon", (233, 150, 122)),
    ]

    # Layout: 8 columns to fit all colors on one page
    swatch_w = 65
    swatch_h = 18
    cols = 8
    start_x = 20
    start_y = 45
    gap_x = 6
    gap_y = 14

    pdf.set_font("Helvetica", size=5)
    pdf.set_line_width(0.25)

    for i, (name, rgb) in enumerate(colors):
        col = i % cols
        row = i // cols
        x = start_x + col * (swatch_w + gap_x)
        y = start_y + row * (swatch_h + gap_y)

        # Draw swatch
        pdf.set_fill_color(*rgb)
        pdf.set_draw_color(0, 0, 0)
        pdf.rect(x, y, swatch_w, swatch_h, style="FD")

        # Draw label below swatch (offset by font size since PDF text uses baseline)
        pdf.text(x + 1, y + swatch_h + 6, name)

    pdf.output(OUTPUT_DIR / "colors.pdf")
    print("  colors.pdf")


def gen_outlines():
    """Document outline (table of contents) and page labels.

    Creates a document structure with:
    - Front matter pages with roman numeral labels (i, ii)
    - Body pages with decimal labels (1, 2, 3)
    - Nested bookmark hierarchy
    """
    pdf = make_pdf()

    # Page 1: Title (front matter - roman numeral i)
    pdf.add_page()
    pdf.set_page_label(label_style="r")  # lowercase roman
    pdf.start_section("Title Page", level=0)
    pdf.set_font("Helvetica", "B", size=24)
    pdf.text(200, 300, "My Document")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(220, 350, "A Sample Book")

    # Page 2: Preface (front matter - roman numeral ii)
    pdf.add_page()
    pdf.start_section("Preface", level=0)
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 50, "Preface")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "This is the preface of the document.")

    # Page 3: Chapter 1 (body - decimal 1)
    pdf.add_page()
    pdf.set_page_label(label_style="D", label_start=1)  # decimal starting at 1
    pdf.start_section("Chapter 1: Introduction", level=0)
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 50, "Chapter 1: Introduction")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "Welcome to the introduction chapter.")

    # Page 4: Section 1.1 (body - decimal 2)
    pdf.add_page()
    pdf.start_section("Section 1.1: Background", level=1)
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, 50, "Section 1.1: Background")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "Some background information.")

    # Page 5: Section 1.2 (body - decimal 3)
    pdf.add_page()
    pdf.start_section("Section 1.2: Overview", level=1)
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, 50, "Section 1.2: Overview")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "An overview of the topic.")

    # Page 6: Chapter 2 (body - decimal 4)
    pdf.add_page()
    pdf.start_section("Chapter 2: Details", level=0)
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 50, "Chapter 2: Details")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "This chapter contains detailed information.")

    # Page 7: Appendix A (appendix - A-1)
    pdf.add_page()
    pdf.set_page_label(label_style="A", label_prefix="A-", label_start=1)  # A-1, A-2, ...
    pdf.start_section("Appendix A: References", level=0)
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 50, "Appendix A: References")
    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, 80, "List of references.")

    pdf.output(OUTPUT_DIR / "outlines.pdf")
    print("  outlines.pdf")


def gen_text_decorations():
    """Text decorations: underline and strikethrough."""
    pdf = make_pdf()
    pdf.add_page()

    y = 50
    line_height = 30

    # Title
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, y, "Text Decorations Test")
    y += 40

    # Normal text (no decoration)
    pdf.set_font("Helvetica", "", size=14)
    pdf.text(50, y, "Normal text (no decoration)")
    y += line_height

    # Underlined text
    pdf.set_font("Helvetica", "U", size=14)
    pdf.text(50, y, "Underlined text")
    y += line_height

    # Strikethrough text
    pdf.set_font("Helvetica", "S", size=14)
    pdf.text(50, y, "Strikethrough text")
    y += line_height

    # Both underline and strikethrough
    pdf.set_font("Helvetica", "US", size=14)
    pdf.text(50, y, "Both underline and strikethrough")
    y += 50

    # Different font sizes
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, y, "Different font sizes:")
    y += 25

    pdf.set_font("Helvetica", "U", size=10)
    pdf.text(50, y, "10pt underlined")
    y += 20

    pdf.set_font("Helvetica", "U", size=14)
    pdf.text(50, y, "14pt underlined")
    y += 25

    pdf.set_font("Helvetica", "U", size=20)
    pdf.text(50, y, "20pt underlined")
    y += 40

    # Different fonts
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, y, "Different fonts:")
    y += 25

    pdf.set_font("Helvetica", "U", size=12)
    pdf.text(50, y, "Helvetica underlined")
    y += 20

    pdf.set_font("Times", "U", size=12)
    pdf.text(50, y, "Times Roman underlined")
    y += 20

    pdf.set_font("Courier", "U", size=12)
    pdf.text(50, y, "Courier underlined")

    pdf.output(OUTPUT_DIR / "text_decorations.pdf")
    print("  text_decorations.pdf")


def gen_text_style():
    """Text style API: setTextStyle with color and decoration combinations."""
    pdf = make_pdf()
    pdf.add_page()

    y = 50
    line_height = 25

    # Title
    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, y, "Text Style Test")
    y += 40

    pdf.set_font("Helvetica", "", size=14)

    # Default style (black, no decoration)
    pdf.set_text_color(0, 0, 0)
    pdf.text(50, y, "Default style (black, no decoration)")
    y += line_height

    # Color only
    pdf.set_text_color(255, 0, 0)  # Red
    pdf.text(50, y, "Red text")
    y += line_height

    pdf.set_text_color(0, 128, 0)  # Green (0.5 * 255 = 127.5 ≈ 128)
    pdf.text(50, y, "Green text")
    y += line_height

    pdf.set_text_color(0, 0, 255)  # Blue
    pdf.text(50, y, "Blue text")
    y += line_height + 10

    # Decoration only (black)
    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "U", size=14)  # Underline
    pdf.text(50, y, "Underlined (black)")
    y += line_height

    pdf.set_font("Helvetica", "S", size=14)  # Strikethrough
    pdf.text(50, y, "Strikethrough (black)")
    y += line_height + 10

    # Color + decoration combined
    pdf.set_text_color(255, 0, 0)  # Red
    pdf.set_font("Helvetica", "U", size=14)
    pdf.text(50, y, "Red underlined")
    y += line_height

    pdf.set_text_color(0, 0, 255)  # Blue
    pdf.set_font("Helvetica", "S", size=14)
    pdf.text(50, y, "Blue strikethrough")
    y += line_height

    pdf.set_text_color(128, 0, 128)  # Purple (0.5 * 255 = 127.5 ≈ 128)
    pdf.set_font("Helvetica", "US", size=14)  # Both
    pdf.text(50, y, "Purple with both decorations")
    y += line_height + 10

    # Reset and verify
    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "", size=14)
    pdf.text(50, y, "Reset to defaults")
    y += line_height

    # Grayscale colors
    pdf.set_text_color(128)  # 50% gray
    pdf.text(50, y, "50% gray text")
    y += line_height

    pdf.set_text_color(77)  # 30% gray (0.3 * 255 = 76.5 ≈ 77)
    pdf.set_font("Helvetica", "U", size=14)
    pdf.text(50, y, "30% gray underlined")
    y += line_height + 20

    # Styled text box - manual word positioning with inline styles
    pdf.set_font("Helvetica", "B", size=12)
    pdf.set_text_color(0, 0, 0)
    pdf.text(50, y, "Styled Text in Box (using write()):")
    y += 20

    # Draw a bordered box with light gray fill
    box_x = 50
    box_y = y
    box_width = 400
    box_height = 80
    padding = 10

    pdf.set_fill_color(242, 242, 242)  # 0.95 * 255 = 242
    pdf.set_draw_color(0, 0, 0)
    pdf.set_line_width(1)
    pdf.rect(box_x, box_y, box_width, box_height, style="FD")

    # Write styled text inside the box - simulate wrapped text with inline styles
    pdf.set_font("Helvetica", "", size=11)
    text_y = box_y + padding + 11  # baseline offset
    x = box_x + padding

    # Line 1: "The quick brown fox jumps over the lazy dog,"
    pdf.set_text_color(0, 0, 0)
    pdf.text(x, text_y, "The ")
    x += pdf.get_string_width("The ")

    pdf.set_text_color(153, 77, 0)  # brown (0.6, 0.3, 0) * 255
    pdf.text(x, text_y, "quick brown fox ")
    x += pdf.get_string_width("quick brown fox ")

    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "U", size=11)
    pdf.text(x, text_y, "jumps ")
    x += pdf.get_string_width("jumps ")

    pdf.set_font("Helvetica", "", size=11)
    pdf.text(x, text_y, "over the ")
    x += pdf.get_string_width("over the ")

    pdf.set_text_color(128)  # 0.5 gray
    pdf.set_font("Helvetica", "S", size=11)
    pdf.text(x, text_y, "lazy ")
    x += pdf.get_string_width("lazy ")

    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "", size=11)
    pdf.text(x, text_y, "dog,")

    # Line 2
    text_y += 16
    x = box_x + padding

    pdf.set_text_color(0, 0, 0)
    pdf.text(x, text_y, "demonstrating how ")
    x += pdf.get_string_width("demonstrating how ")

    pdf.set_text_color(0, 0, 204)  # (0, 0, 0.8) * 255
    pdf.text(x, text_y, "different ")
    x += pdf.get_string_width("different ")

    pdf.set_text_color(0, 0, 0)
    pdf.text(x, text_y, "words can have ")
    x += pdf.get_string_width("words can have ")

    pdf.set_text_color(204, 0, 0)  # (0.8, 0, 0) * 255
    pdf.set_font("Helvetica", "U", size=11)
    pdf.text(x, text_y, "unique colors")
    x += pdf.get_string_width("unique colors")

    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "", size=11)
    pdf.text(x, text_y, " and")

    # Line 3
    text_y += 16
    x = box_x + padding

    pdf.set_text_color(0, 128, 0)  # (0, 0.5, 0) * 255
    pdf.set_font("Helvetica", "S", size=11)
    pdf.text(x, text_y, "decorations")
    x += pdf.get_string_width("decorations")

    pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "", size=11)
    pdf.text(x, text_y, " within the same wrapped paragraph.")

    pdf.output(OUTPUT_DIR / "text_style.pdf")
    print("  text_style.pdf")


def gen_auto_height():
    """Auto-height box: box height determined by text content."""
    pdf = make_pdf()
    pdf.add_page()

    # Title
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, 50, "Auto-height Box Demo")

    # Box with auto-height using multi_cell
    pdf.set_font("Helvetica", "", size=11)
    box_width = 250
    box_padding = 8
    box_y = 80

    sample_text = ("This box height is automatically calculated based on the text content. "
                   "The text wraps within the specified width, and the box grows to fit.")

    # Set colors for the box
    pdf.set_fill_color(230, 242, 255)  # light blue (0.9, 0.95, 1.0) * 255
    pdf.set_draw_color(0, 0, 0)

    # Position and draw multi_cell with border and fill
    # multi_cell handles the padding internally via cell margin
    pdf.c_margin = box_padding
    pdf.set_xy(50, box_y)
    pdf.multi_cell(w=box_width, h=11 * 1.2, text=sample_text, border=1, fill=True)

    pdf.output(OUTPUT_DIR / "auto_height.pdf")
    print("  auto_height.pdf")


def gen_valign():
    """Test vertical alignment of text within boxes (top, middle, bottom) with different fonts."""
    pdf = make_pdf()
    pdf.add_page()

    # Register fonts
    pdf.add_font("Inter", "", "test/fonts/Inter/Inter-Regular.ttf")
    pdf.add_font("Gentium", "", "test/fonts/Gentium/Gentium-Regular.ttf")

    # Title
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 30, "Vertical Alignment Test")

    # Common settings
    box_width = 150
    box_height = 120
    padding = 8
    font_size = 11
    line_height = font_size * 1.2
    content_width = box_width - 2 * padding

    # Sample text that will wrap to multiple lines
    sample_text = ("The quick brown fox jumps over the lazy dog. "
                   "Pack my box with five dozen liquor jugs.")

    valigns = [
        ("Top (valign=T)", "top"),
        ("Middle (valign=M)", "middle"),
        ("Bottom (valign=B)", "bottom"),
    ]

    fonts = [
        ("Helvetica", "Helvetica (built-in):"),
        ("Inter", "Inter (embedded):"),
        ("Gentium", "Gentium (embedded):"),
    ]

    for row, (font_name, font_label) in enumerate(fonts):
        y = 60 + row * 150

        # Row label
        pdf.set_font("Helvetica", "B", size=12)
        pdf.text(50, y - 15, font_label)

        # Set font and calculate line count for this font
        pdf.set_font(font_name, "", size=font_size)
        words = sample_text.split()
        lines = []
        current_line = ""
        for word in words:
            test_line = f"{current_line} {word}".strip()
            if pdf.get_string_width(test_line) <= content_width:
                current_line = test_line
            else:
                if current_line:
                    lines.append(current_line)
                current_line = word
        if current_line:
            lines.append(current_line)

        num_lines = len(lines)
        text_height = num_lines * line_height

        for i, (label, valign) in enumerate(valigns):
            x = 50 + i * (box_width + 20)

            # Draw label above box
            pdf.set_font("Helvetica", "B", size=10)
            pdf.text(x, y - 5, label)

            # Draw box border
            pdf.set_draw_color(0, 0, 0)
            pdf.set_line_width(0.5)
            pdf.rect(x, y, box_width, box_height, style="D")

            # Draw alignment guide lines (before text)
            pdf.set_line_width(0.3)
            # Red line at top padding edge
            pdf.set_draw_color(255, 0, 0)
            pdf.line(x, y + padding, x + box_width, y + padding)
            # Blue line at center
            pdf.set_draw_color(0, 0, 255)
            pdf.line(x, y + box_height / 2, x + box_width, y + box_height / 2)
            # Green line at bottom padding edge
            pdf.set_draw_color(0, 180, 0)
            pdf.line(x, y + box_height - padding, x + box_width, y + box_height - padding)

            # Calculate text Y position based on valign
            if valign == "top":
                text_y = y + padding
            elif valign == "middle":
                text_y = y + (box_height - text_height) / 2
            else:  # bottom
                text_y = y + box_height - text_height - padding

            # Draw the text
            pdf.set_font(font_name, "", size=font_size)
            pdf.set_xy(x + padding, text_y)
            pdf.multi_cell(w=content_width, h=line_height, text=sample_text, align="L")

    pdf.output(OUTPUT_DIR / "valign.pdf")
    print("  valign.pdf")


def gen_kerning():
    """Kerning test - extensive kerning pair coverage."""
    pdf = make_pdf()
    pdf.add_page()

    # Load Charter font (has good kerning data)
    pdf.add_font(family="Charter", fname="test/fonts/Charter/Charter Regular.ttf")
    pdf.add_font(family="Charter", style="B", fname="test/fonts/Charter/Charter Bold.ttf")
    pdf.add_font(family="Charter", style="I", fname="test/fonts/Charter/Charter Italic.ttf")

    # Enable text shaping with kerning
    pdf.set_text_shaping(True, features={"kern": True})

    y = 30

    # Title
    pdf.set_font("Charter", "B", size=16)
    shaped_text(pdf, 50, y, "Kerning Test")
    y += 24

    # Section 1: Classic kerning pairs
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Classic Kerning Pairs:")
    y += 14

    pdf.set_font("Charter", "", size=14)
    # AV, AW, AY, AT combinations
    shaped_text(pdf, 50, y, "AV AW AY AT Av Aw Ay At")
    y += 18
    # To, Ta, Te, Ti, Tr, Ty, Tu, Tw
    shaped_text(pdf, 50, y, "To Ta Te Ti Tr Ty Tu Tw")
    y += 18
    # VA, Vo, WA, Wa, We, Ya, Yo
    shaped_text(pdf, 50, y, "VA Vo WA Wa We Ya Yo")
    y += 18
    # LT, LV, LY, LA, PA
    shaped_text(pdf, 50, y, "LT LV LY LA PA")
    y += 18
    # Punctuation kerning
    shaped_text(pdf, 50, y, "T. V. W. Y. F. P. r. f.")
    y += 24

    # Section 2: Words with kerning
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Words with Kerning:")
    y += 14

    pdf.set_font("Charter", "", size=14)
    shaped_text(pdf, 50, y, "AVATAR WAVE TYPEWRITER")
    y += 18
    shaped_text(pdf, 50, y, "Today Tomorrow Typography")
    y += 18
    shaped_text(pdf, 50, y, "Water Weather Welcome")
    y += 18
    shaped_text(pdf, 50, y, "Yellow Yield Youth")
    y += 24

    # Section 3: Sentence with many kerning opportunities
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Sentence with Kerning:")
    y += 14

    pdf.set_font("Charter", "", size=12)
    shaped_text(pdf, 50, y, "The AVATAR watched TypeWriter keys Today.")
    y += 16
    shaped_text(pdf, 50, y, "We Welcome You To This Typography Test.")
    y += 20

    # Section 4: Comparison - same text at different sizes
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Size Comparison (kerning scales):")
    y += 14

    for size in [10, 14, 18, 24]:
        pdf.set_font("Charter", "", size=size)
        shaped_text(pdf, 50, y, "AWAY Today")
        y += size + 4

    y += 8

    # Section 5: Italic kerning
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Italic Kerning:")
    y += 14

    pdf.set_font("Charter", "I", size=14)
    shaped_text(pdf, 50, y, "AV AW To Ta Typography WAVE")
    y += 20

    # Section 6: Bold kerning
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Bold Kerning:")
    y += 14

    pdf.set_font("Charter", "B", size=14)
    shaped_text(pdf, 50, y, "AV AW To Ta Typography WAVE")
    y += 20

    # Section 7: Numbers and punctuation
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Numbers and Punctuation:")
    y += 14

    pdf.set_font("Charter", "", size=14)
    shaped_text(pdf, 50, y, "1. 2. 3. 4. 5. 6. 7. 8. 9. 0.")
    y += 18
    shaped_text(pdf, 50, y, '"Quote" (Paren) [Bracket]')
    y += 20

    # Section 8: Long paragraph to show cumulative effect
    pdf.set_font("Charter", "B", size=11)
    shaped_text(pdf, 50, y, "Paragraph (cumulative kerning):")
    y += 14

    # Use individual lines to match zpdf's writeAt positioning
    pdf.set_font("Charter", "", size=11)
    shaped_text(pdf, 50, y, "Typography is the art of arranging type to make written")
    y += 11 * 1.2
    shaped_text(pdf, 50, y, "language legible and appealing. WATER flows Today as")
    y += 11 * 1.2
    shaped_text(pdf, 50, y, "WAVES crash Tomorrow. The Yellow sun Yields warmth.")

    pdf.output(OUTPUT_DIR / "kerning.pdf")
    print("  kerning.pdf")


def gen_gentium_family():
    """PDF demonstrating all Gentium font weights and styles."""
    pdf = make_pdf()
    fonts_dir = Path("test/fonts/Gentium")

    # Add all Gentium fonts - main family
    pdf.add_font("Gentium", "", str(fonts_dir / "Gentium-Regular.ttf"))
    pdf.add_font("Gentium", "B", str(fonts_dir / "Gentium-Bold.ttf"))
    pdf.add_font("Gentium", "I", str(fonts_dir / "Gentium-Italic.ttf"))
    pdf.add_font("Gentium", "BI", str(fonts_dir / "Gentium-BoldItalic.ttf"))

    # Extra weights as separate families
    pdf.add_font("GentiumMedium", "", str(fonts_dir / "Gentium-Medium.ttf"))
    pdf.add_font("GentiumMedium", "I", str(fonts_dir / "Gentium-MediumItalic.ttf"))
    pdf.add_font("GentiumSemiBold", "", str(fonts_dir / "Gentium-SemiBold.ttf"))
    pdf.add_font("GentiumSemiBold", "I", str(fonts_dir / "Gentium-SemiBoldItalic.ttf"))
    pdf.add_font("GentiumExtraBold", "", str(fonts_dir / "Gentium-ExtraBold.ttf"))
    pdf.add_font("GentiumExtraBold", "I", str(fonts_dir / "Gentium-ExtraBoldItalic.ttf"))

    # Enable text shaping with kerning
    pdf.set_text_shaping(True, features={"kern": True})

    pdf.add_page()
    y = 40

    # Title
    pdf.set_font("Gentium", "B", size=24)
    shaped_text(pdf, 50, y, "Gentium Font Family")
    y += 40

    # Main family section
    pdf.set_font("Gentium", "B", size=14)
    shaped_text(pdf, 50, y, "Main Family (using FontFamily API)")
    y += 25

    pdf.set_font("Gentium", "", size=12)
    shaped_text(pdf, 50, y, "Regular: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("Gentium", "B", size=12)
    shaped_text(pdf, 50, y, "Bold: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("Gentium", "I", size=12)
    shaped_text(pdf, 50, y, "Italic: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("Gentium", "BI", size=12)
    shaped_text(pdf, 50, y, "Bold Italic: The quick brown fox jumps over the lazy dog.")
    y += 35

    # Extra weights section
    pdf.set_font("Gentium", "B", size=14)
    shaped_text(pdf, 50, y, "Extra Weights (loaded separately)")
    y += 25

    pdf.set_font("GentiumMedium", "", size=12)
    shaped_text(pdf, 50, y, "Medium: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("GentiumMedium", "I", size=12)
    shaped_text(pdf, 50, y, "Medium Italic: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("GentiumSemiBold", "", size=12)
    shaped_text(pdf, 50, y, "SemiBold: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("GentiumSemiBold", "I", size=12)
    shaped_text(pdf, 50, y, "SemiBold Italic: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("GentiumExtraBold", "", size=12)
    shaped_text(pdf, 50, y, "ExtraBold: The quick brown fox jumps over the lazy dog.")
    y += 18
    pdf.set_font("GentiumExtraBold", "I", size=12)
    shaped_text(pdf, 50, y, "ExtraBold Italic: The quick brown fox jumps over the lazy dog.")
    y += 35

    # Unicode section
    pdf.set_font("Gentium", "B", size=14)
    shaped_text(pdf, 50, y, "Unicode Support")
    y += 25

    pdf.set_font("Gentium", "", size=12)
    shaped_text(pdf, 50, y, "Diacritics: café, naïve, résumé, Zürich, señor")
    y += 18
    shaped_text(pdf, 50, y, "Greek: Ελληνικά, Αθήνα")
    y += 18
    shaped_text(pdf, 50, y, "Cyrillic: Москва, Київ")

    pdf.output(OUTPUT_DIR / "gentium_family.pdf")
    print("  gentium_family.pdf")


def gen_pdfa():
    """Generate PDF/A conformance test document."""
    from fpdf.enums import OutputIntentSubType
    from fpdf.output import PDFICCProfile
    import pathlib

    pdf = make_pdf()

    # Read the ICC profile (same one zpdf uses)
    icc_data = pathlib.Path("src/data/sRGB2014.icc").read_bytes()

    # Add output intent for PDF/A
    icc_profile = PDFICCProfile(icc_data, n=3, alternate="DeviceRGB")
    pdf.add_output_intent(
        OutputIntentSubType.PDFA,
        output_condition_identifier="sRGB IEC61966-2.1",
        registry_name="http://www.color.org",
        dest_output_profile=icc_profile,
    )

    # Add embedded font (required for PDF/A - no standard fonts)
    pdf.add_font("Inter", "", "test/fonts/Inter/Inter-Regular.ttf")

    # Enable text shaping with kerning
    pdf.set_text_shaping(True, features={"liga": True, "kern": True})

    pdf.add_page()

    # Title
    pdf.set_font("Inter", size=16)
    shaped_text(pdf, 50, 30, "PDF/A Conformance Test")

    # Description
    pdf.set_font("Inter", size=10)
    y = 60
    shaped_text(pdf, 50, y, "This document uses PDF/A structures:")
    y += 15
    shaped_text(pdf, 70, y, "- OutputIntent with sRGB ICC profile")
    y += 12
    shaped_text(pdf, 70, y, "- Embedded fonts (Inter)")
    y += 12
    shaped_text(pdf, 70, y, "- No transparency (fully opaque)")
    y += 25

    # Colored rectangles (no transparency for PDF/A-1b)
    pdf.set_fill_color(200, 220, 255)
    pdf.set_draw_color(0, 50, 150)
    pdf.rect(50, y, 80, 40, style="DF")

    pdf.set_fill_color(255, 220, 200)
    pdf.set_draw_color(150, 50, 0)
    pdf.rect(140, y, 80, 40, style="DF")

    pdf.set_fill_color(220, 255, 220)
    pdf.set_draw_color(0, 150, 50)
    pdf.rect(230, y, 80, 40, style="DF")

    pdf.output(OUTPUT_DIR / "pdfa.pdf")
    print("  pdfa.pdf")


GENERATORS = {
    "gentium_family": gen_gentium_family,
    "kerning": gen_kerning,
    "text_decorations": gen_text_decorations,
    "text_style": gen_text_style,
    "auto_height": gen_auto_height,
    "valign": gen_valign,
    "outlines": gen_outlines,
    "minimal": gen_minimal,
    "hello_world": gen_hello_world,
    "multi_font": gen_multi_font,
    "all_fonts": gen_all_fonts,
    "multi_page": gen_multi_page,
    "insert_page": gen_insert_page,
    "embedded_fonts": gen_embedded_fonts,
    "cid_fonts": gen_cid_fonts,
    "inter_fonts": gen_inter_fonts,
    "opentype_features": gen_opentype_features,
    "text_flow": gen_text_flow,
    "justify": gen_justify,
    "colored_text": gen_colored_text,
    "shapes": gen_shapes,
    "images": gen_images,
    "svg": gen_svg,
    "svg_text": gen_svg_text,
    "svg_use_defs": gen_svg_use_defs,
    "paths": gen_paths,
    "gradients": gen_gradients,
    "opacity": gen_opacity,
    "landscape": gen_landscape,
    "colors": gen_colors,
    "pdfa": gen_pdfa,
}


def main():
    parser = argparse.ArgumentParser(description="Generate reference PDFs with fpdf2")
    parser.add_argument("--test", help="Generate only the specified test")
    parser.add_argument("--all", action="store_true",
                        help="Generate all tests, including excluded ones")
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if args.test:
        # Generate specific test
        if args.test not in GENERATORS:
            print(f"Unknown test: {args.test}")
            print(f"Available: {', '.join(GENERATORS.keys())}")
            sys.exit(1)
        if args.test in EXCLUDED_TESTS and not args.all:
            print(f"Warning: {args.test} is excluded (fpdf2 can't generate correct reference)")
            print("Use --all to force generation, or maintain this reference manually from zpdf output")
            sys.exit(1)
        print(f"Generating {args.test}.pdf...")
        GENERATORS[args.test]()
    else:
        # Generate all non-excluded tests
        print("Generating reference PDFs with fpdf2...")
        for name, gen_func in GENERATORS.items():
            if name in EXCLUDED_TESTS and not args.all:
                print(f"  {name}.pdf (SKIPPED - manually maintained)")
                continue
            gen_func()

    print(f"\nDone. References in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
