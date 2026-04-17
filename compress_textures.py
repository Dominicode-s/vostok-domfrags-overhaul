"""
compress_textures.py — lossless PNG recompression for the bundled mod.

Strategy (all lossless — no visible change to the textures):
  1. Re-encode every PNG with PIL's optimize=True + compress_level=9 (zopfli-
     grade DEFLATE). Always an improvement over the original encoder.
  2. Try palette quantization (PIL convert to "P" mode). If the original
     image has <= 256 distinct colors, this is lossless AND typically much
     smaller. We keep the palette version only if it's smaller than the
     optimized RGBA output AND the pixel-exact comparison matches.
  3. Keep whichever re-encoded form is smallest. Skip if no improvement.

Reports a per-file before/after table and a grand total.
"""

from __future__ import annotations
import io
import os
from pathlib import Path
from PIL import Image, ImageChops

ROOT = Path(__file__).parent / "mods"


def encode_optimized(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    # Ensure we emit RGBA/RGB cleanly. PIL maps L/LA/P through correctly.
    img.save(buf, format="PNG", optimize=True, compress_level=9)
    return buf.getvalue()


def encode_palette(img: Image.Image) -> bytes | None:
    """Quantize to palette if the image has <= 256 colors. Returns None if
    quantization would be lossy."""
    if img.mode not in ("RGB", "RGBA", "LA", "L"):
        return None
    # Fast reject: count unique colors via getcolors (cap 256 tells us if
    # the image is already within palette range).
    colors = img.getcolors(maxcolors=256)
    if colors is None:
        return None  # > 256 unique colors — lossy palette conversion
    # Quantize using PIL's default method (median cut). Use adaptive
    # palette with RGBA preserved when the original has alpha.
    if img.mode in ("RGBA", "LA"):
        pal = img.quantize(colors=256, method=Image.Quantize.LIBIMAGEQUANT) \
              if hasattr(Image, "Quantize") and hasattr(Image.Quantize, "LIBIMAGEQUANT") \
              else img.quantize(colors=256)
    else:
        pal = img.quantize(colors=256)
    # Verify losslessness — a palette image converted back must match the
    # original exactly at the pixel level.
    decoded = pal.convert(img.mode)
    diff = ImageChops.difference(decoded, img)
    if diff.getbbox() is not None:
        return None
    buf = io.BytesIO()
    pal.save(buf, format="PNG", optimize=True, compress_level=9)
    return buf.getvalue()


def process(path: Path) -> tuple[int, int, str]:
    original = path.read_bytes()
    original_size = len(original)
    img = Image.open(path)
    img.load()

    candidates: list[tuple[int, bytes, str]] = []
    try:
        opt = encode_optimized(img)
        candidates.append((len(opt), opt, "opt"))
    except Exception as e:
        print(f"  [{path.name}] optimize failed: {e}")
    try:
        pal = encode_palette(img)
        if pal is not None:
            candidates.append((len(pal), pal, "palette"))
    except Exception as e:
        print(f"  [{path.name}] palette failed: {e}")

    if not candidates:
        return original_size, original_size, "skipped"

    candidates.sort(key=lambda t: t[0])
    best_size, best_bytes, best_kind = candidates[0]
    if best_size >= original_size:
        return original_size, original_size, "no-gain"
    path.write_bytes(best_bytes)
    return original_size, best_size, best_kind


def main() -> None:
    pngs = list(ROOT.rglob("*.png"))
    if not pngs:
        print(f"No PNGs found under {ROOT}")
        return
    total_before = 0
    total_after = 0
    print(f"Scanning {len(pngs)} PNGs...\n")
    print(f"{'file':60s} {'before':>10s} {'after':>10s} {'save':>10s} {'kind':>8s}")
    print("-" * 102)
    for p in sorted(pngs):
        before, after, kind = process(p)
        total_before += before
        total_after += after
        rel = p.relative_to(ROOT.parent)
        saved = before - after
        pct = (saved / before * 100) if before else 0
        print(f"{str(rel):60s} {before:>10,} {after:>10,} {saved:>7,} ({pct:4.1f}%)  {kind:>8s}")
    print("-" * 102)
    total_saved = total_before - total_after
    total_pct = (total_saved / total_before * 100) if total_before else 0
    print(f"{'TOTAL':60s} {total_before:>10,} {total_after:>10,} {total_saved:>7,} ({total_pct:4.1f}%)")


if __name__ == "__main__":
    main()
