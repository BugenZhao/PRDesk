#!/usr/bin/env python3
"""Gives the org badges' logos one optical size, in the assets themselves.

Logos come drawn to their own measures: a wide wordmark and a full disc fitted into the same
square look nothing alike in size. This measures each logo's ink (rendered with `rsvg-convert`,
its alpha) and rescales it about the middle of its ink so that every logo has the same optical
size, as far as the square allows:

    optical size = sqrt(ink width × ink height) × density ** DENSITY_WEIGHT

where density is how much of that box the ink covers (a solid square looks bigger than an outline
of the same box). A logo too wide or tall for the target at that size is as big as the square
lets it be. An SVG gets a new `viewBox` (its paths untouched); a PNG is redrawn on its canvas.
A dark variant takes its light logo's measures, so the two stay alike. Running it again changes
nothing, give or take a rounding.

    scripts/normalize-badges.py            # rewrites the assets
    scripts/normalize-badges.py --dry-run  # only prints the measures and the scales
"""

import glob
import io
import math
import os
import re
import subprocess
import sys

from PIL import Image

ASSETS = os.path.join(os.path.dirname(__file__), "..", "Shared", "Resources", "Assets.xcassets")
# The optical size every logo gets, as a fraction of the square.
TARGET = 0.72
# How much the ink's density counts: 0 is the box alone.
DENSITY_WEIGHT = 0.25
# The ink's box may come this close to the square's edges.
MAX_EXTENT = 1.0
MEASURE_SIDE = 512


def render(path):
    if path.endswith(".svg"):
        png = subprocess.run(
            ["rsvg-convert", "-w", str(MEASURE_SIDE), "-h", str(MEASURE_SIDE), "-a", path],
            check=True, capture_output=True,
        ).stdout
        return Image.open(io.BytesIO(png)).convert("RGBA")
    return Image.open(path).convert("RGBA")


def measure(image):
    """The ink's box (in fractions of the square) and how much of the box it covers."""
    alpha = image.getchannel("A")
    width, height = image.size
    box = alpha.point(lambda v: 255 if v > 8 else 0).getbbox()
    x0, y0, x1, y1 = box[0] / width, box[1] / height, box[2] / width, box[3] / height
    coverage = sum(alpha.tobytes()) / 255 / (width * height)
    return (x0, y0, x1, y1), coverage / ((x1 - x0) * (y1 - y0))


def scale_for(box, density):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    optical = math.sqrt(w * h) * density ** DENSITY_WEIGHT
    return min(TARGET / optical, MAX_EXTENT / max(w, h)), optical


def rescale_svg(path, box, scale):
    text = open(path).read()
    tag = re.search(r"<svg\b[^>]*>", text).group(0)
    vx, vy, vw, vh = map(float, re.search(r'viewBox="([^"]+)"', tag).group(1).split())
    assert abs(vw - vh) < 1e-6, f"{path}: viewBox not square"
    cx = vx + (box[0] + box[2]) / 2 * vw
    cy = vy + (box[1] + box[3]) / 2 * vh
    side = vw / scale
    view_box = f'viewBox="{cx - side / 2:.3f} {cy - side / 2:.3f} {side:.3f} {side:.3f}"'
    new_tag = re.sub(r'viewBox="[^"]+"', view_box, tag)
    open(path, "w").write(text.replace(tag, new_tag, 1))


def rescale_png(path, box, scale):
    image = Image.open(path).convert("RGBA")
    side = image.size[0]
    assert image.size[0] == image.size[1], f"{path}: not square"
    cx, cy = (box[0] + box[2]) / 2 * side, (box[1] + box[3]) / 2 * side
    size = round(side * scale)
    scaled = image.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    out.alpha_composite(scaled, (round(side / 2 - cx * scale), round(side / 2 - cy * scale)))
    out.save(path)


def main():
    dry_run = "--dry-run" in sys.argv
    for imageset in sorted(glob.glob(os.path.join(ASSETS, "org-*.imageset"))):
        files = sorted(f for f in os.listdir(imageset) if f.endswith((".svg", ".png")))
        light = next(f for f in files if "-dark." not in f)
        box, density = measure(render(os.path.join(imageset, light)))
        scale, optical = scale_for(box, density)
        name = os.path.basename(imageset)[: -len(".imageset")]
        print(f"{name:18} box {box[2] - box[0]:.2f}×{box[3] - box[1]:.2f} density {density:.2f} "
              f"optical {optical:.2f} → scale {scale:.3f}")
        if dry_run or abs(scale - 1) < 0.02:
            continue
        for file in files:
            path = os.path.join(imageset, file)
            (rescale_svg if file.endswith(".svg") else rescale_png)(path, box, scale)


if __name__ == "__main__":
    main()
