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
    """PDF with embedded TTF fonts - comprehensive showcase."""
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

    # Page 1: Title and Courier Prime showcase
    pdf.add_page()

    # Title with standard font
    pdf.set_font("Helvetica", "B", size=24)
    pdf.text(50, 40, "Embedded Font Reference")

    pdf.set_font("Helvetica", size=12)
    pdf.text(50, 60, "Generated by fpdf2 - reference for zpdf font embedding")

    # Courier Prime section
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, 100, "Courier Prime (Monospace)")

    y = 130
    pdf.set_font("CourierPrime", "", size=14)
    pdf.text(50, y, "Regular: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("CourierPrime", "B", size=14)
    pdf.text(50, y, "Bold: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("CourierPrime", "I", size=14)
    pdf.text(50, y, "Italic: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("CourierPrime", "BI", size=14)
    pdf.text(50, y, "Bold Italic: The quick brown fox jumps.")
    y += 40

    # Charter section
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, y, "Charter (Serif)")
    y += 30

    pdf.set_font("Charter", "", size=14)
    pdf.text(50, y, "Regular: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("Charter", "B", size=14)
    pdf.text(50, y, "Bold: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("Charter", "I", size=14)
    pdf.text(50, y, "Italic: The quick brown fox jumps over the lazy dog.")
    y += 20

    pdf.set_font("Charter", "BI", size=14)
    pdf.text(50, y, "Bold Italic: The quick brown fox jumps over the lazy dog.")
    y += 40

    # Size comparison
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, y, "Size Comparison")
    y += 25

    for size in [10, 12, 14, 18, 24]:
        pdf.set_font("Charter", "", size=size)
        pdf.text(50, y, f"{size}pt: ABCabc123")
        y += size + 8

    # Page 2: Character set and mixed fonts
    pdf.add_page()

    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 40, "Character Set Test")

    y = 70
    pdf.set_font("CourierPrime", "", size=12)

    # ASCII printable characters
    lines = [
        " !\"#$%&'()*+,-./0123456789:;<=>?",
        "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_",
        "`abcdefghijklmnopqrstuvwxyz{|}~",
    ]
    for line in lines:
        pdf.text(50, y, line)
        y += 18

    y += 20
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, y, "Mixed Standard and Embedded Fonts")
    y += 30

    pdf.set_font("Helvetica", "", size=12)
    pdf.text(50, y, "Helvetica (standard): Hello World")
    y += 18

    pdf.set_font("CourierPrime", "", size=12)
    pdf.text(50, y, "Courier Prime (embedded): Hello World")
    y += 18

    pdf.set_font("Times", "", size=12)
    pdf.text(50, y, "Times (standard): Hello World")
    y += 18

    pdf.set_font("Charter", "", size=12)
    pdf.text(50, y, "Charter (embedded): Hello World")
    y += 30

    # Numbers and alignment test
    pdf.set_font("Helvetica", "B", size=16)
    pdf.text(50, y, "Number Alignment (Monospace)")
    y += 25

    pdf.set_font("CourierPrime", "", size=12)
    numbers = [
        "    1.00",
        "   12.50",
        "  123.75",
        " 1234.00",
        "12345.99",
    ]
    for num in numbers:
        pdf.text(50, y, num)
        y += 16

    # Page 3: Paragraph text
    pdf.add_page()

    pdf.set_font("Helvetica", "B", size=18)
    pdf.text(50, 40, "Paragraph Text")

    y = 80
    pdf.set_font("Charter", "", size=11)

    paragraph = """Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat."""

    # Simple word wrap (fpdf2 has multi_cell but we want precise positioning)
    words = paragraph.split()
    line = ""
    max_width = 500

    for word in words:
        test_line = line + " " + word if line else word
        # Approximate width check
        if len(test_line) * 5.5 > max_width:
            pdf.text(50, y, line)
            y += 16
            line = word
        else:
            line = test_line
    if line:
        pdf.text(50, y, line)

    y += 40
    pdf.set_font("Helvetica", "B", size=14)
    pdf.text(50, y, "Font Metrics")
    y += 25

    pdf.set_font("Helvetica", "", size=10)
    pdf.text(50, y, "Courier Prime: Monospace, optimized for code and screenplays")
    y += 14
    pdf.text(50, y, "Charter: Designed by Matthew Carter for low-resolution printing")
    y += 14
    pdf.text(50, y, "Both fonts are open source and freely distributable")

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
