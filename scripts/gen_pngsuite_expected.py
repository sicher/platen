#!/usr/bin/env python3
"""
Convert PngSuite's expected pixels (JSON) into compact truth files.

    python3 scripts/gen_pngsuite_expected.py /path/to/lunapaint/pngsuite

Reads <suite>/json/<name>.json ([r,g,b,a,...], 16-bit files at full 16-bit
range) for every valid image in test/images/pngsuite/ and writes
test/images/pngsuite/expected/<name>.rgba:

    u32 big-endian width, u32 big-endian height, then width*height*4 bytes
    of 8-bit RGBA (16-bit samples keep their high byte - the precision the
    PDF comparison sees through pdfimages).

The truth comes from PngSuite itself, not from any PDF library: fpdf2
(Pillow) decodes 16-bit grayscale wrongly, so it cannot be the pixel
authority. Width/height come from each PNG's IHDR. No dependencies.
"""

import json
import struct
import sys
from pathlib import Path

SUITE_PNG_DIR = Path("test/images/pngsuite")
OUT_DIR = SUITE_PNG_DIR / "expected"


def ihdr_size(png: Path) -> tuple[int, int]:
    data = png.read_bytes()
    if data[12:16] != b"IHDR":
        raise ValueError(f"{png}: IHDR is not the first chunk")
    return struct.unpack(">II", data[16:24])


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    json_dir = Path(sys.argv[1]) / "json"
    OUT_DIR.mkdir(exist_ok=True)

    names = sorted(p.name for p in SUITE_PNG_DIR.glob("*.png") if not p.name.startswith("x"))
    for name in names:
        width, height = ihdr_size(SUITE_PNG_DIR / name)
        pixels = json.loads((json_dir / (name[:-4] + ".json")).read_text())
        if len(pixels) != width * height * 4:
            raise ValueError(f"{name}: {len(pixels)} samples for {width}x{height}")
        wide = max(pixels) > 255
        rgba = bytes((v >> 8) if wide else v for v in pixels)
        (OUT_DIR / (name[:-4] + ".rgba")).write_bytes(struct.pack(">II", width, height) + rgba)
    print(f"wrote {len(names)} files to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
