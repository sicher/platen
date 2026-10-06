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


if __name__ == "__main__":
    unittest.main(verbosity=1)
