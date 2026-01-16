#!/usr/bin/env python3
"""
Semantic PDF comparator.

Compares two PDFs based on visual content rather than internal structure:
- Same text content
- Similar positions (within tolerance)
- Same fonts used per page (via qpdf)

Usage:
    python scripts/compare_pdfs.py expected.pdf actual.pdf [--tolerance=5.0]

Exit codes:
    0 = PDFs match semantically
    1 = PDFs differ
    2 = Error
"""

import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Word:
    text: str
    x_min: float
    y_min: float
    x_max: float
    y_max: float

    @property
    def center_x(self) -> float:
        return (self.x_min + self.x_max) / 2

    @property
    def center_y(self) -> float:
        return (self.y_min + self.y_max) / 2


@dataclass
class Page:
    width: float
    height: float
    words: list[Word]
    fonts: set[str] = field(default_factory=set)  # Font names used on this page

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words)


@dataclass
class PdfContent:
    pages: list[Page]

    @property
    def text(self) -> str:
        return "\n".join(p.text for p in self.pages)


def normalize_font_name(name: str) -> str:
    """Normalize font name for comparison."""
    if not name:
        return ""
    # Remove subset prefix (e.g., "MPDFAA+" or "ABCDEF+")
    if "+" in name:
        name = name.split("+", 1)[1]
    # Lowercase and remove spaces/hyphens for comparison
    n = name.lower().replace(" ", "").replace("-", "")
    # Remove "regular" suffix (often omitted in PDF font names)
    if n.endswith("regular"):
        n = n[:-7]
    return n


def extract_fonts_qpdf(pdf_path: str) -> list[set[str]]:
    """Extract font names per page using qpdf JSON output."""
    result = subprocess.run(
        ["qpdf", "--json", pdf_path],
        capture_output=True,
        text=True,
    )
    # Exit code 0 = success, 3 = success with warnings
    if result.returncode not in (0, 3):
        return []  # qpdf not available or failed

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    # Build mapping from object ref to font BaseFont name
    font_names = {}  # "obj:X 0 R" -> normalized font name
    objects = data.get("qpdf", [{}])
    if len(objects) > 1:
        objects = objects[1]  # Second element has the objects
    else:
        objects = {}

    for key, obj in objects.items():
        if not key.startswith("obj:"):
            continue
        value = obj.get("value", {})
        if value.get("/Type") == "/Font" and "/BaseFont" in value:
            base_font = value["/BaseFont"].lstrip("/")
            font_names[key] = normalize_font_name(base_font)

    # Get fonts per page from page resources
    pages_fonts = []
    for page_info in data.get("pages", []):
        page_obj_ref = page_info.get("object", "")
        page_key = f"obj:{page_obj_ref}"

        # Get page's Resources/Font dict
        page_fonts = set()
        if page_key in objects:
            page_value = objects[page_key].get("value", {})
            resources = page_value.get("/Resources", {})

            # Resources might be inline or a reference
            if isinstance(resources, str) and resources.endswith(" R"):
                res_key = f"obj:{resources}"
                if res_key in objects:
                    resources = objects[res_key].get("value", {})

            font_dict = resources.get("/Font", {})
            if isinstance(font_dict, str) and font_dict.endswith(" R"):
                font_key = f"obj:{font_dict}"
                if font_key in objects:
                    font_dict = objects[font_key].get("value", {})

            # font_dict maps /F1, /F2 etc. to object refs
            for font_ref in font_dict.values():
                if isinstance(font_ref, str) and font_ref.endswith(" R"):
                    ref_key = f"obj:{font_ref}"
                    if ref_key in font_names:
                        page_fonts.add(font_names[ref_key])

        pages_fonts.append(page_fonts)

    return pages_fonts


def extract_content(pdf_path: str) -> PdfContent:
    """Extract text with positions using pdftotext, fonts using qpdf."""
    result = subprocess.run(
        ["pdftotext", "-bbox", pdf_path, "-"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"pdftotext failed: {result.stderr}")

    # Get font info from qpdf
    pages_fonts = extract_fonts_qpdf(pdf_path)

    # Parse XML output
    root = ET.fromstring(result.stdout)

    pages = []
    for i, page_elem in enumerate(root.findall(".//{http://www.w3.org/1999/xhtml}page")):
        width = float(page_elem.get("width", 0))
        height = float(page_elem.get("height", 0))

        words = []
        for word_elem in page_elem.findall(".//{http://www.w3.org/1999/xhtml}word"):
            words.append(Word(
                text=word_elem.text or "",
                x_min=float(word_elem.get("xMin", 0)),
                y_min=float(word_elem.get("yMin", 0)),
                x_max=float(word_elem.get("xMax", 0)),
                y_max=float(word_elem.get("yMax", 0)),
            ))

        fonts = pages_fonts[i] if i < len(pages_fonts) else set()
        pages.append(Page(width=width, height=height, words=words, fonts=fonts))

    return PdfContent(pages=pages)


def compare_words(expected: Word, actual: Word, tolerance: float) -> list[str]:
    """Compare two words, return list of differences."""
    diffs = []

    if expected.text != actual.text:
        diffs.append(f"Text differs: '{expected.text}' vs '{actual.text}'")

    # Compare center positions (more forgiving than corners)
    dx = abs(expected.center_x - actual.center_x)
    dy = abs(expected.center_y - actual.center_y)

    if dx > tolerance:
        diffs.append(f"X position differs by {dx:.1f}pt (tolerance: {tolerance})")
    if dy > tolerance:
        diffs.append(f"Y position differs by {dy:.1f}pt (tolerance: {tolerance})")

    return diffs


def compare_pages(expected: Page, actual: Page, tolerance: float, page_num: int) -> list[str]:
    """Compare two pages, return list of differences."""
    diffs = []

    # Compare dimensions
    if abs(expected.width - actual.width) > 0.01:
        diffs.append(f"Page {page_num}: width differs ({expected.width} vs {actual.width})")
    if abs(expected.height - actual.height) > 0.01:
        diffs.append(f"Page {page_num}: height differs ({expected.height} vs {actual.height})")

    # Compare fonts used on this page
    if expected.fonts and actual.fonts:
        missing = expected.fonts - actual.fonts
        extra = actual.fonts - expected.fonts
        if missing:
            diffs.append(f"Page {page_num}: missing fonts: {', '.join(sorted(missing))}")
        if extra:
            diffs.append(f"Page {page_num}: extra fonts: {', '.join(sorted(extra))}")

    # Compare word count
    if len(expected.words) != len(actual.words):
        diffs.append(f"Page {page_num}: word count differs ({len(expected.words)} vs {len(actual.words)})")
        diffs.append(f"  Expected: {expected.text}")
        diffs.append(f"  Actual: {actual.text}")
        return diffs

    # Compare each word
    for i, (exp_word, act_word) in enumerate(zip(expected.words, actual.words)):
        word_diffs = compare_words(exp_word, act_word, tolerance)
        for d in word_diffs:
            diffs.append(f"Page {page_num}, word {i+1} '{exp_word.text}': {d}")

    return diffs


def compare_pdfs(expected_path: str, actual_path: str, tolerance: float = 5.0) -> tuple[bool, list[str]]:
    """
    Compare two PDFs semantically.

    Returns (match: bool, differences: list[str])
    """
    try:
        expected = extract_content(expected_path)
        actual = extract_content(actual_path)
    except Exception as e:
        return False, [f"Error extracting content: {e}"]

    diffs = []

    # Compare page count
    if len(expected.pages) != len(actual.pages):
        diffs.append(f"Page count differs: {len(expected.pages)} vs {len(actual.pages)}")
        return False, diffs

    # Compare each page
    for i, (exp_page, act_page) in enumerate(zip(expected.pages, actual.pages)):
        page_diffs = compare_pages(exp_page, act_page, tolerance, i + 1)
        diffs.extend(page_diffs)

    return len(diffs) == 0, diffs


def main():
    parser = argparse.ArgumentParser(description="Semantic PDF comparator")
    parser.add_argument("expected", help="Expected/reference PDF")
    parser.add_argument("actual", help="Actual/generated PDF")
    parser.add_argument("--tolerance", type=float, default=5.0,
                        help="Position tolerance in points (default: 5.0)")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Only output on failure")
    args = parser.parse_args()

    if not Path(args.expected).exists():
        print(f"Error: {args.expected} not found", file=sys.stderr)
        sys.exit(2)
    if not Path(args.actual).exists():
        print(f"Error: {args.actual} not found", file=sys.stderr)
        sys.exit(2)

    match, diffs = compare_pdfs(args.expected, args.actual, args.tolerance)

    if match:
        if not args.quiet:
            print("MATCH: PDFs are semantically equivalent")
        sys.exit(0)
    else:
        print("DIFFER: PDFs have differences:")
        for d in diffs:
            print(f"  {d}")
        sys.exit(1)


if __name__ == "__main__":
    main()
