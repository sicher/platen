#!/usr/bin/env python3
"""Self-tests for scripts/compare_pdfs.py (run by `zig build test` via
testing.zig). The comparator decides whether every reference test passes,
so its own blind spots are test failures waiting to be missed."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare_pdfs as c  # noqa: E402


def page(fonts):
    return c.Page(width=595, height=842, words=[], fonts=set(fonts))


class FontComparison(unittest.TestCase):
    def test_actual_page_without_fonts_is_a_difference(self):
        # Fonts were compared only when BOTH pages had some, so a page
        # that lost all its fonts passed.
        diffs = c.compare_pages(page({"Helvetica"}), page(set()), 1.0, 1)
        self.assertTrue(any("missing fonts" in d for d in diffs), diffs)

    def test_extra_fonts_on_an_expected_fontless_page(self):
        diffs = c.compare_pages(page(set()), page({"Courier"}), 1.0, 1)
        self.assertTrue(any("extra fonts" in d for d in diffs), diffs)

    def test_matching_and_fontless_pages_pass(self):
        self.assertEqual([], c.compare_pages(page({"Helvetica"}), page({"Helvetica"}), 1.0, 1))
        self.assertEqual([], c.compare_pages(page(set()), page(set()), 1.0, 1))

    def test_skip_fonts_still_skips(self):
        self.assertEqual([], c.compare_pages(page({"Helvetica"}), page(set()), 1.0, 1, skip_fonts=True))


class QpdfFailures(unittest.TestCase):
    def test_unreadable_pdf_is_an_error_not_no_fonts(self):
        # A qpdf failure used to become "no fonts" silently.
        with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
            f.write(b"%PDF-1.4\nnot really a pdf\n")
            f.flush()
            with self.assertRaises(RuntimeError):
                c.extract_fonts_qpdf(f.name)


def square_pdf(path: Path, color: str) -> str:
    """A one-page PDF with a filled square in `color` ("r g b") and no
    text: the text/position comparison sees nothing to tell apart."""
    content = f"{color} rg 20 20 40 40 re f".encode()
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 80 80] /Contents 4 0 R >>",
            b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content)]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (n, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    path.write_bytes(out)
    return str(path)


class RenderComparison(unittest.TestCase):
    def test_a_drawing_change_is_a_difference(self):
        # References platen generated itself: a change in how something is
        # drawn (a color glyph, a gradient) leaves text and positions alone
        with tempfile.TemporaryDirectory() as tmp:
            red = square_pdf(Path(tmp) / "red.pdf", "1 0 0")
            blue = square_pdf(Path(tmp) / "blue.pdf", "0 0 1")
            self.assertTrue(c.compare_pdfs(red, blue, 1.0)[0])
            diffs = c.compare_renders(red, blue)
            self.assertEqual(1, len(diffs), diffs)
            self.assertIn("pixels differ", diffs[0])
            self.assertEqual([], c.compare_renders(red, red))


if __name__ == "__main__":
    unittest.main(verbosity=1)
