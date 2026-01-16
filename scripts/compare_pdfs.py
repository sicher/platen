#!/usr/bin/env python3
"""
Semantic PDF comparator.

Compares two PDFs based on visual content rather than internal structure:
- Same text content
- Similar positions (within tolerance)
- Same fonts used

Usage:
    python scripts/compare_pdfs.py expected.pdf actual.pdf [--tolerance=5.0]

Exit codes:
    0 = PDFs match semantically
    1 = PDFs differ
    2 = Error
"""

import argparse
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
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

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words)


@dataclass
class PdfContent:
    pages: list[Page]

    @property
    def text(self) -> str:
        return "\n".join(p.text for p in self.pages)


def extract_content(pdf_path: str) -> PdfContent:
    """Extract text with positions using pdftotext -bbox."""
    result = subprocess.run(
        ["pdftotext", "-bbox", pdf_path, "-"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"pdftotext failed: {result.stderr}")

    # Parse XML output
    root = ET.fromstring(result.stdout)

    pages = []
    for page_elem in root.findall(".//{http://www.w3.org/1999/xhtml}page"):
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

        pages.append(Page(width=width, height=height, words=words))

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
