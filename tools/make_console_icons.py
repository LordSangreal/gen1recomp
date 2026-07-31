#!/usr/bin/env python3
"""Generate the Nintendo homebrew menu icons for the LÖVE Potion builds.

Each console wants a different size AND a different container, and the sizes
are not advisory: the homebrew menu reads a fixed-size record out of the
metadata section, so an icon of the wrong dimensions is a corrupt entry rather
than a scaled one.  From lovebrew/bundler-api (crates/asset/src/icon.rs), which
is what the bundler service applies server-side:

    ctr  (3DS)     48x48    PNG
    hac  (Switch)  256x256  JPEG
    cafe (Wii U)   128x128  PNG

The service resizes with `thumbnail`, which preserves aspect ratio.  That is a
trap for a non-square source: a 822x241 logo thumbnailed into a 48x48 box comes
back 48x14, and that is what gets embedded.  So this script always emits an
exactly square icon, letterboxed rather than stretched, and the service's
resize then becomes a no-op on an already-correct file.

JPEG cannot carry alpha, so the Switch icon is flattened onto a background
first; left to Pillow, an RGBA->JPEG save either raises or produces black
fringing wherever the source was transparent.

Usage:
    python3 tools/make_console_icons.py [--source PATH] [--out DIR]
                                        [--background '#RRGGBB']
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install Pillow")

ROOT = Path(__file__).resolve().parent.parent

# The square cover art, not logo.png: the logo is 822x241, so every console
# icon cut from it would be a thin band floating in a mostly empty square.
DEFAULT_SOURCE = ROOT / "assets" / "logo" / "gen1recomp_cover.png"

# (filename, pixel size, Pillow format).  Names are referenced by the
# [metadata].icons table that scripts/build.sh writes into lovebrew.toml.
TARGETS = (
    ("icon-ctr.png", 48, "PNG"),
    ("icon-hac.jpg", 256, "JPEG"),
    ("icon-cafe.png", 128, "PNG"),
)


def square(image, background):
    """Center `image` on a square canvas without distorting it.

    Returns the image unchanged when it is already square, so a square source
    (the cover art) never takes a needless resample.
    """
    w, h = image.size
    if w == h:
        return image
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), background + (0,))
    canvas.paste(image, ((side - w) // 2, (side - h) // 2))
    return canvas


def render(source, out_dir, background):
    src = Image.open(source)
    # Normalize up front: palette and grayscale sources both reach the resize
    # with a usable alpha channel this way, and RGBA is what square() pastes.
    src = src.convert("RGBA")
    src = square(src, background)

    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for name, size, fmt in TARGETS:
        # LANCZOS: these are large downscales (1024 -> 48 is 21x), where a
        # cheaper filter aliases the sprite work into noise.
        icon = src.resize((size, size), Image.LANCZOS)
        if fmt == "JPEG":
            # Flatten: JPEG has no alpha, and compositing explicitly is what
            # keeps transparent edges from turning into black fringes.
            flat = Image.new("RGB", icon.size, background)
            flat.paste(icon, mask=icon.split()[3])
            icon = flat
        path = out_dir / name
        icon.save(path, fmt, **({"quality": 95} if fmt == "JPEG" else {}))
        written.append((path, size, fmt))
    return written


def parse_color(text):
    text = text.lstrip("#")
    if len(text) != 6:
        raise argparse.ArgumentTypeError("expected #RRGGBB")
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                    help="source image (default: assets/logo/gen1recomp_cover.png)")
    ap.add_argument("--out", type=Path, default=ROOT / "dist" / "console" / "icons",
                    help="output directory")
    ap.add_argument("--background", type=parse_color, default="#000000",
                    help="fill behind transparency, for JPEG and letterboxing")
    args = ap.parse_args()

    if not args.source.is_file():
        sys.exit(f"source image not found: {args.source}")

    background = args.background
    if isinstance(background, str):
        background = parse_color(background)

    for path, size, fmt in render(args.source, args.out, background):
        print(f"{path.relative_to(ROOT) if ROOT in path.parents else path}"
              f"  {size}x{size} {fmt}")


if __name__ == "__main__":
    main()
