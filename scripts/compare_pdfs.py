#!/usr/bin/env python3
"""
Semantic PDF comparator.

Compares two PDFs based on visual content rather than internal structure:
- Same text content
- Similar positions (within tolerance)
- Same fonts used per page (via qpdf)
- With --compare-images: identical decoded image pixels and alpha masks
  (via poppler's pdfimages; exact, no tolerance)

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
import tempfile
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
    # Exit code 0 = success, 3 = success with warnings. Anything else is an
    # error: returning "no fonts" here silently disabled the font check.
    if result.returncode not in (0, 3):
        raise RuntimeError(f"qpdf failed on {pdf_path} (exit {result.returncode}): {result.stderr.strip()[:300]}")

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"qpdf --json output for {pdf_path} is not JSON: {e}")

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


def compare_pages(expected: Page, actual: Page, tolerance: float, page_num: int, skip_fonts: bool = False) -> list[str]:
    """Compare two pages, return list of differences."""
    diffs = []

    # Compare dimensions
    if abs(expected.width - actual.width) > 0.01:
        diffs.append(f"Page {page_num}: width differs ({expected.width} vs {actual.width})")
    if abs(expected.height - actual.height) > 0.01:
        diffs.append(f"Page {page_num}: height differs ({expected.height} vs {actual.height})")

    # Compare fonts used on this page (skip if fonts are in Form XObjects).
    # Whenever EITHER side has fonts: a page that lost all of them is a
    # difference, not a reason to skip the check.
    if not skip_fonts and (expected.fonts or actual.fonts):
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


def read_netpbm(path: Path) -> tuple[int, int, bytes]:
    """Parse a P4/P5/P6 file (as written by pdfimages) into 8-bit RGB."""
    data = path.read_bytes()
    fields: list[bytes] = []
    pos = 2
    magic = data[:2]
    need = 2 if magic == b"P4" else 3
    while len(fields) < need:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1  # single whitespace before the raster
    width, height = int(fields[0]), int(fields[1])
    maxval = 1 if magic == b"P4" else int(fields[2])
    raster = data[pos:]

    if magic == b"P4":
        row_bytes = (width + 7) // 8
        gray = bytearray()
        for y in range(height):
            row = raster[y * row_bytes:(y + 1) * row_bytes]
            for x in range(width):
                bit = (row[x // 8] >> (7 - x % 8)) & 1
                gray.append(0 if bit else 255)  # PBM: 1 = black
        samples, channels = bytes(gray), 1
    else:
        channels = 1 if magic == b"P5" else 3
        if maxval > 255:  # 16-bit big-endian samples: keep the high byte
            samples = raster[0:width * height * channels * 2:2]
        else:
            samples = raster[:width * height * channels]
            if maxval != 255:
                samples = bytes(round(v * 255 / maxval) for v in samples)

    if channels == 1:
        samples = bytes(v for v in samples for _ in range(3))
    return width, height, samples


def extract_images(pdf_path: str, workdir: Path) -> list[tuple[str, Path]]:
    """All image XObjects in page/drawing order as (type, netpbm path);
    type is "image" or "smask" (an smask follows the image it masks)."""
    listing = subprocess.run(["pdfimages", "-list", pdf_path], capture_output=True, text=True, check=True).stdout
    types = [line.split()[2] for line in listing.splitlines()[2:] if line.strip()]
    prefix = workdir / "img"
    subprocess.run(["pdfimages", pdf_path, str(prefix)], check=True)
    files = sorted(workdir.glob("img-*"))
    if len(files) != len(types):
        raise RuntimeError(f"pdfimages listed {len(types)} images but wrote {len(files)}")
    return list(zip(types, files))


def group_images(entries: list[tuple[str, Path]]) -> list[tuple[Path, Path | None]]:
    groups: list[tuple[Path, Path | None]] = []
    for kind, path in entries:
        if kind == "smask" and groups and groups[-1][1] is None:
            groups[-1] = (groups[-1][0], path)
        else:
            groups.append((path, None))
    return groups


def compare_images(expected_path: str, actual_path: str, skip_expected: set[int],
                   skip_actual: set[int] | None = None) -> list[str]:
    """Compare decoded images (and their soft masks) pixel for pixel.
    `skip_expected` lists indices of images present only in the reference
    (e.g. formats the generator does not support yet); `skip_actual` lists
    actual images to leave out (e.g. ones the reference renders wrongly)."""
    with tempfile.TemporaryDirectory() as tmp:
        exp_dir, act_dir = Path(tmp) / "e", Path(tmp) / "a"
        exp_dir.mkdir()
        act_dir.mkdir()
        expected = [g for i, g in enumerate(group_images(extract_images(expected_path, exp_dir))) if i not in skip_expected]
        actual = [g for i, g in enumerate(group_images(extract_images(actual_path, act_dir))) if i not in (skip_actual or set())]

        if len(expected) != len(actual):
            return [f"Image count differs: {len(expected)} vs {len(actual)} (after skipping {len(skip_expected)} expected, {len(skip_actual or ())} actual)"]

        diffs = []
        for n, ((e_img, e_mask), (a_img, a_mask)) in enumerate(zip(expected, actual)):
            for what, e, a in (("image", e_img, a_img), ("mask", e_mask, a_mask)):
                if e is None and a is None:
                    continue
                if e is None or a is None:
                    diffs.append(f"Image {n + 1}: {what} only in {'actual' if e is None else 'expected'}")
                    continue
                ew, eh, ep = read_netpbm(e)
                aw, ah, ap = read_netpbm(a)
                if (ew, eh) != (aw, ah):
                    diffs.append(f"Image {n + 1} {what}: size {ew}x{eh} vs {aw}x{ah}")
                elif ep != ap:
                    bad = sum(1 for i in range(0, len(ep), 3) if ep[i:i + 3] != ap[i:i + 3])
                    diffs.append(f"Image {n + 1} {what}: {bad} of {ew * eh} pixels differ")
        return diffs


def read_truth(path: Path) -> tuple[int, int, bytes, bytes]:
    """Truth file from scripts/gen_pngsuite_expected.py -> (w, h, rgb, alpha)."""
    data = path.read_bytes()
    width, height = int.from_bytes(data[0:4], "big"), int.from_bytes(data[4:8], "big")
    rgba = data[8:]
    rgb = bytes(b for i, b in enumerate(rgba) if i % 4 != 3)
    return width, height, rgb, rgba[3::4]


def compare_images_to_truth(actual_path: str, names: list[str], truth_dir: str, known_gaps: set[str]) -> list[str]:
    """Compare each image in `actual_path` (drawn in `names` order) with its
    truth file: RGB exactly, and the soft mask against the truth alpha (a
    missing mask is a mismatch when the truth has any transparency).
    `known_gaps` must mismatch - a listed file that now matches is reported
    so the list cannot go stale."""
    with tempfile.TemporaryDirectory() as tmp:
        groups = group_images(extract_images(actual_path, Path(tmp)))
        if len(groups) != len(names):
            return [f"Truth: {len(groups)} images in PDF but {len(names)} names given"]
        mismatches: dict[str, str] = {}
        for name, (img, mask) in zip(names, groups):
            tw, th, t_rgb, t_alpha = read_truth(Path(truth_dir) / (name[:-4] + ".rgba"))
            aw, ah, a_rgb = read_netpbm(img)
            if (aw, ah) != (tw, th):
                mismatches[name] = f"size {aw}x{ah}, truth {tw}x{th}"
                continue
            if a_rgb != t_rgb:
                bad = sum(1 for i in range(0, len(t_rgb), 3) if a_rgb[i:i + 3] != t_rgb[i:i + 3])
                mismatches[name] = f"{bad} of {tw * th} pixels differ"
                continue
            if mask is None:
                if any(a != 255 for a in t_alpha):
                    mismatches[name] = "no transparency, truth has some"
            else:
                _, _, m = read_netpbm(mask)
                if m[0::3] != t_alpha:
                    bad = sum(1 for a, b in zip(m[0::3], t_alpha) if a != b)
                    mismatches[name] = f"{bad} of {tw * th} alpha values differ"

    diffs = [f"Truth {n}: {why}" for n, why in mismatches.items() if n not in known_gaps]
    diffs += [f"Truth {n}: matches now - remove it from the known gaps" for n in sorted(known_gaps) if n not in mismatches]
    return diffs


def compare_pdfs(expected_path: str, actual_path: str, tolerance: float = 5.0, skip_fonts: bool = False,
                 images: bool = False, skip_expected_images: set[int] | None = None,
                 skip_actual_images: set[int] | None = None) -> tuple[bool, list[str]]:
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
        page_diffs = compare_pages(exp_page, act_page, tolerance, i + 1, skip_fonts)
        diffs.extend(page_diffs)

    if images:
        diffs.extend(compare_images(expected_path, actual_path, skip_expected_images or set(), skip_actual_images))

    return len(diffs) == 0, diffs


def main():
    parser = argparse.ArgumentParser(description="Semantic PDF comparator")
    parser.add_argument("expected", help="Expected/reference PDF")
    parser.add_argument("actual", help="Actual/generated PDF")
    parser.add_argument("--tolerance", type=float, default=5.0,
                        help="Position tolerance in points (default: 5.0)")
    parser.add_argument("--skip-fonts", action="store_true",
                        help="Skip font comparison (for SVG Form XObjects)")
    parser.add_argument("--compare-images", action="store_true",
                        help="Also compare decoded image pixels exactly (pdfimages)")
    parser.add_argument("--skip-expected-images", default="",
                        help="Comma-separated 0-based indices of reference images absent from actual")
    parser.add_argument("--skip-actual-images", default="",
                        help="Comma-separated 0-based indices of actual images to leave out")
    parser.add_argument("--truth-dir", default="",
                        help="Directory of .rgba truth files (scripts/gen_pngsuite_expected.py)")
    parser.add_argument("--truth-names", default="",
                        help="Comma-separated file names of the actual PDF's images, in drawing order")
    parser.add_argument("--truth-known-gaps", default="",
                        help="Comma-separated names expected to mismatch the truth (known gaps)")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Only output on failure")
    args = parser.parse_args()

    if not Path(args.expected).exists():
        print(f"Error: {args.expected} not found", file=sys.stderr)
        sys.exit(2)
    if not Path(args.actual).exists():
        print(f"Error: {args.actual} not found", file=sys.stderr)
        sys.exit(2)

    skip = {int(i) for i in args.skip_expected_images.split(",") if i}
    skip_actual = {int(i) for i in args.skip_actual_images.split(",") if i}
    match, diffs = compare_pdfs(args.expected, args.actual, args.tolerance, args.skip_fonts,
                                args.compare_images, skip, skip_actual)
    if args.truth_dir:
        names = [n for n in args.truth_names.split(",") if n]
        gaps = {n for n in args.truth_known_gaps.split(",") if n}
        truth_diffs = compare_images_to_truth(args.actual, names, args.truth_dir, gaps)
        diffs.extend(truth_diffs)
        match = match and not truth_diffs

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
