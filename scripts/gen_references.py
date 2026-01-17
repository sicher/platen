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
    return pdf


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


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Generating reference PDFs with fpdf2...")
    gen_minimal()
    gen_hello_world()
    gen_multi_font()
    gen_all_fonts()
    gen_multi_page()
    gen_embedded_fonts()
    print(f"\nDone. References in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
