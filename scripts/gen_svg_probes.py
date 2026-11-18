#!/usr/bin/env python3
"""
Record resvg's colors at the probe points of the SVG gradient test cases.

    .venv/bin/python scripts/gen_svg_probes.py

Each test/svg_gradients/*.svg lists its probes in a comment,
`<!-- probes: x,y x,y ... -->`, in the SVG's own px. resvg (resvg-py, in
.venv) renders each file at ZOOM over white; the color of the pixel at
(x * ZOOM, y * ZOOM) goes to test/svg_gradients/probes.json, which
scripts/check_svg_probes.py compares platen's pdftoppm render against.
resvg is only needed here: the JSON is committed, so the test suite and CI
need just pdftoppm.

A probe must sit where the color changes slowly: its 5 x 5 neighborhood
in the resvg render may span at most MAX_SPREAD levels (about 6 per
pixel). Two rasterizers can sample half a pixel apart, which is then worth
at most ~3 levels, the checker's tolerance; on a shape edge, a hard stop or
next to a radial focal point (where pdftoppm approximates the shading) it
is worth much more, so such probes are refused here rather than tolerated
there.
"""

import io
import json
import re
import sys
from pathlib import Path

ZOOM = 2
MAX_SPREAD = 24
CASES = Path(__file__).resolve().parent.parent / "test" / "svg_gradients"


def probes_of(svg: str) -> list[tuple[float, float]]:
    m = re.search(r"<!--\s*probes:([^>]*)-->", svg)
    if not m:
        raise SystemExit("no <!-- probes: ... --> comment")
    return [tuple(float(v) for v in p.split(",")) for p in m.group(1).split()]


def main() -> int:
    try:
        import resvg_py
        from PIL import Image
    except ImportError:
        print("needs resvg-py and pillow: .venv/bin/python -m pip install resvg-py pillow", file=sys.stderr)
        return 1

    cases = []
    bad = []
    for path in sorted(CASES.glob("*.svg")):
        rgba = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_path=str(path), zoom=ZOOM)))).convert("RGBA")
        img = Image.new("RGB", rgba.size, (255, 255, 255))
        img.paste(rgba, mask=rgba.split()[3])
        px = img.load()
        probes = []
        for x, y in probes_of(path.read_text()):
            cx, cy = int(x * ZOOM), int(y * ZOOM)
            window = [px[i, j] for i in range(max(cx - 2, 0), min(cx + 3, img.width))
                      for j in range(max(cy - 2, 0), min(cy + 3, img.height))]
            spread = max(max(c[k] for c in window) - min(c[k] for c in window) for k in range(3))
            if spread > MAX_SPREAD:
                bad.append(f"{path.name}: probe {x:g},{y:g} spans {spread} levels in its 5x5 neighborhood")
            probes.append({"x": x, "y": y, "rgb": list(px[cx, cy])})
        cases.append({"file": path.name, "width": img.width // ZOOM, "height": img.height // ZOOM, "probes": probes})

    if bad:
        print("\n".join(bad), file=sys.stderr)
        return 1
    out = CASES / "probes.json"
    out.write_text(json.dumps({"zoom": ZOOM, "cases": cases}, indent=1) + "\n")
    print(f"wrote {out} ({sum(len(c['probes']) for c in cases)} probes in {len(cases)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
