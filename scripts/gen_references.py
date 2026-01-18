#!/usr/bin/env python3
"""
Generate reference PDFs using fpdf2.

These serve as the baseline for testing zpdf output.
Run with: python scripts/gen_references.py

Will auto-create .venv and install fpdf2 if needed.
"""

import os
import subprocess
import sys
from pathlib import Path

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


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Generating reference PDFs with fpdf2...")
    gen_minimal()
    gen_hello_world()
    gen_multi_font()
    gen_all_fonts()
    gen_multi_page()
    gen_embedded_fonts()
    gen_cid_fonts()
    gen_inter_fonts()
    gen_opentype_features()
    print(f"\nDone. References in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
