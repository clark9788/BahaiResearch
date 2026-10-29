#!/usr/bin/env python3
"""Generate assets/BahaiResearch.ico from the Android launcher artwork.

The Android app's 512x512 play-store icon is the source of truth for the branding: a light
blue field with the black nine-pointed star. This script reuses it for Windows, where the
shortcut, the uninstaller entry and the installer itself need a multi-resolution .ico.

Two treatments are used, because a 30px-wide outline on a 512px canvas collapses to about one
pixel at 16px and reads as a blob:

  * 16-24 px  solid star (the outlined interior filled in)
  * 32 px +   the original outline

Each size is rendered separately and packed into the .ico as uncompressed BMP frames (Inno
Setup's SetupIconFile is stricter than Explorer about PNG-compressed frames), so no size is a
downscale of another.

Usage (Linux shell; Pillow is required and is not part of the standard library):

    sudo apt install python3-pil   # or: pip install Pillow
    tools/make-windows-icon.py [--source PATH] [--output PATH]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("ERROR: Pillow is required (pip install Pillow).")

DEFAULT_SOURCE = Path(
    "/home/clarkdev/projects/BahaiResearchA/app/src/main/ic_launcher-playstore.png"
)
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "assets" / "BahaiResearch.ico"

BACKGROUND = (61, 196, 220)
DARK_THRESHOLD = 60
OUTLINE_SIZES = (32, 40, 48, 64, 128, 256)
SOLID_SIZES = (16, 20, 24)
OUTLINE_ALPHA_CUTOFF = 60
SOLID_ALPHA_CUTOFF = 110


def star_masks(source: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Return (outline mask, solid mask) for the star, both full canvas size."""
    outline = source.convert("L").point(lambda v: 255 if v < DARK_THRESHOLD else 0)

    # Fill the star interior by flooding the cyan area enclosed by the outline, then merge.
    widened = source.copy()
    width, height = source.size
    ImageDraw.floodfill(widened, (width // 2, height // 2), (255, 0, 255), thresh=40)
    widened_pixels = widened.load()

    solid = Image.new("L", source.size, 0)
    solid_pixels = solid.load()
    outline_pixels = outline.load()
    for y in range(height):
        for x in range(width):
            if outline_pixels[x, y] or widened_pixels[x, y] == (255, 0, 255):
                solid_pixels[x, y] = 255
    return outline, solid


def render(mask: Image.Image, size: int, alpha_cutoff: int) -> Image.Image:
    scaled = mask.resize((size, size), Image.LANCZOS)
    frame = Image.new("RGB", (size, size), BACKGROUND)
    frame_pixels = frame.load()
    scaled_pixels = scaled.load()
    for y in range(size):
        for x in range(size):
            if scaled_pixels[x, y] >= alpha_cutoff:
                frame_pixels[x, y] = (0, 0, 0)
    return frame


def write_ico(frames: dict[int, Image.Image], destination: Path) -> None:
    """Write a multi-frame .ico from the pre-rendered frames.

    Frames are stored as uncompressed BMP entries rather than PNG ones: Inno Setup's
    SetupIconFile is stricter than Explorer about PNG-compressed icon frames.
    """
    ordered = [frames[size] for size in sorted(frames)]
    largest = ordered[-1]
    destination.parent.mkdir(parents=True, exist_ok=True)
    largest.save(
        destination,
        format="ICO",
        sizes=[(size, size) for size in sorted(frames)],
        append_images=ordered,
        bitmap_format="bmp",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                        help=f"launcher artwork (default: {DEFAULT_SOURCE})")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help=f"destination .ico (default: {DEFAULT_OUTPUT})")
    args = parser.parse_args()

    if not args.source.is_file():
        sys.exit(f"ERROR: source artwork not found: {args.source}")

    source = Image.open(args.source).convert("RGB")
    if source.size != (512, 512):
        print(f"WARNING: expected 512x512 artwork, got {source.size[0]}x{source.size[1]}")

    outline_mask, solid_mask = star_masks(source)

    frames = {}
    for size in SOLID_SIZES:
        frames[size] = render(solid_mask, size, SOLID_ALPHA_CUTOFF)
    for size in OUTLINE_SIZES:
        frames[size] = render(outline_mask, size, OUTLINE_ALPHA_CUTOFF)

    write_ico(frames, args.output)
    print(f"Wrote {args.output} ({args.output.stat().st_size:,} bytes)")
    print("Sizes:", ", ".join(f"{s}x{s}" for s in sorted(frames)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
