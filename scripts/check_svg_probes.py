#!/usr/bin/env python3
"""
Check platen's SVG gradient rendering against resvg's colors.

    python3 scripts/check_svg_probes.py <probes.json> <pdf> <name>...

The PDF has one page per SVG test case, in the order of the names given
(file names from test/svg_gradients). Each page is rendered with pdftoppm
at the zoom probes.json was recorded at, and every probe's pixel must be
within TOLERANCE of resvg's color in each channel. The tolerance covers
8-bit rounding and the half pixel two rasterizers may sample apart;
gen_svg_probes.py only accepts probes where that is worth no more.

Exit status: 0 when every probe matches, 1 on a mismatch, 2 when
pdftoppm is missing.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_pdfs import read_netpbm  # noqa: E402

TOLERANCE = 3


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 1
    if shutil.which("pdftoppm") is None:
        print("pdftoppm not found", file=sys.stderr)
        return 2
    spec = json.loads(Path(sys.argv[1]).read_text())
    pdf, names = sys.argv[2], sys.argv[3:]
    zoom = spec["zoom"]
    cases = {c["file"]: c for c in spec["cases"]}

    errors = []
    missing = sorted(set(cases) - set(names))
    if missing:
        errors.append(f"cases with probes but no page: {', '.join(missing)}")
    with tempfile.TemporaryDirectory() as tmp:
        for page, name in enumerate(names, start=1):
            case = cases.get(name)
            if case is None:
                errors.append(f"{name}: no probes recorded (run scripts/gen_svg_probes.py)")
                continue
            prefix = Path(tmp) / f"p{page}"
            subprocess.run(["pdftoppm", "-r", str(72 * zoom), "-f", str(page), "-l", str(page),
                            "-singlefile", str(pdf), str(prefix)], check=True)
            width, height, rgb = read_netpbm(prefix.with_suffix(".ppm"))
            if (width, height) != (case["width"] * zoom, case["height"] * zoom):
                errors.append(f"{name}: page renders {width}x{height}, expected "
                              f"{case['width'] * zoom}x{case['height'] * zoom}")
                continue
            for probe in case["probes"]:
                x, y = int(probe["x"] * zoom), int(probe["y"] * zoom)
                i = (y * width + x) * 3
                got = list(rgb[i:i + 3])
                want = probe["rgb"]
                if max(abs(a - b) for a, b in zip(got, want)) > TOLERANCE:
                    errors.append(f"{name}: at {probe['x']:g},{probe['y']:g} platen {got}, resvg {want}")

    if errors:
        print("\n".join(errors))
        return 1
    print(f"{len(names)} SVG gradient cases match resvg at every probe")
    return 0


if __name__ == "__main__":
    sys.exit(main())
