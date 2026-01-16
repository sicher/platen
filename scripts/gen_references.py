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


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Generating reference PDFs with fpdf2...")
    gen_minimal()
    gen_hello_world()
    gen_multi_font()
    gen_all_fonts()
    gen_multi_page()
    print(f"\nDone. References in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
