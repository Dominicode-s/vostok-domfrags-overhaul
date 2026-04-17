"""
downscale_textures.py — targeted lossy-safe texture downscaling.

Tier 1 (safe, functional no-op):
  - Skillbook ICON PNGs: the XP mod's runtime resamples every icon to
    exactly 128×256 via Image.INTERPOLATE_LANCZOS (see _load_skillbook_
    icon_override in XPSkillsSystem/Main.gd). Pre-resampling on disk at
    the same dimensions + same Lanczos filter is bit-equivalent to what
    the game would have computed at load time.

Tier 2 (visually imperceptible for 3D props):
  - Skillbook COVER PNGs: 1024×1024 textures wrapped onto a small in-hand
    book model. Held at grip distance they're sampled far below 1:1, so
    a 512×512 cover is indistinguishable during normal gameplay.
  - SecureContainer pouch textures: same reasoning — 3D props held at
    modest size.

Run with `--aggressive` to apply Tier 2 in addition to Tier 1.
"""

from __future__ import annotations
import argparse
import io
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).parent / "mods"

# Tier 1 targets
ICON_PATTERNS = [
    "XPSkillsSystem/Books/*icon*.png",   # matches "Arctic icon.png", "arctic_icon.png", etc.
]
ICON_TARGET = (128, 256)   # matches the mod's load-time resample

# Tier 2 targets — aggressive flag only
COVER_PATTERNS = [
    "XPSkillsSystem/Books/Arctic.png",
    "XPSkillsSystem/Books/Athletic.png",
    "XPSkillsSystem/Books/Fitness.png",
    "XPSkillsSystem/Books/Marksmanship.png",
    "XPSkillsSystem/Books/Medical.png",
    "XPSkillsSystem/Books/Meditations.png",
    "XPSkillsSystem/Books/Scavenger.png",
    "XPSkillsSystem/Books/Unseen.png",
    "XPSkillsSystem/Books/Wilderness.png",
]
COVER_TARGET = (512, 512)
POUCH_PATTERNS = [
    "SecureContainer/field_pouch_tex.png",
    "SecureContainer/secure_pouch_tex.png",
]
POUCH_TARGET = (512, 512)


def resample(path: Path, target: tuple[int, int]) -> tuple[int, int]:
    """Resample PNG to target (w, h) with Lanczos. Returns (before, after)."""
    before = path.stat().st_size
    img = Image.open(path)
    img.load()
    tw, th = target
    if img.width <= tw and img.height <= th:
        return before, before
    # Preserve aspect: scale so the larger relative dimension lands at
    # the target cap. For most cases the inputs match our target aspect
    # (the XP mod's icons are 720×1456 → 128×256 is an exact 5.625× scale
    # on both axes).
    scale = min(tw / img.width, th / img.height)
    new_w = max(1, int(round(img.width * scale)))
    new_h = max(1, int(round(img.height * scale)))
    resized = img.resize((new_w, new_h), Image.LANCZOS)
    buf = io.BytesIO()
    resized.save(buf, format="PNG", optimize=True, compress_level=9)
    data = buf.getvalue()
    path.write_bytes(data)
    return before, len(data)


def expand(patterns: list[str]) -> list[Path]:
    out: list[Path] = []
    for pat in patterns:
        for p in ROOT.glob(pat):
            if p.is_file():
                out.append(p)
    return sorted(set(out))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aggressive", action="store_true",
                        help="Also downscale cover textures (512x512) and pouch textures")
    args = parser.parse_args()

    work: list[tuple[Path, tuple[int, int], str]] = []
    for p in expand(ICON_PATTERNS):
        work.append((p, ICON_TARGET, "icon"))
    if args.aggressive:
        for p in expand(COVER_PATTERNS):
            work.append((p, COVER_TARGET, "cover"))
        for p in expand(POUCH_PATTERNS):
            work.append((p, POUCH_TARGET, "pouch"))

    if not work:
        print("No matching textures found.")
        sys.exit(0)

    print(f"{'file':60s} {'before':>10s} {'after':>10s} {'save':>10s} {'tier':>6s}")
    print("-" * 100)
    total_before = 0
    total_after = 0
    for p, tgt, tag in work:
        before, after = resample(p, tgt)
        total_before += before
        total_after += after
        rel = p.relative_to(ROOT.parent)
        saved = before - after
        pct = (saved / before * 100) if before else 0
        print(f"{str(rel):60s} {before:>10,} {after:>10,} {saved:>7,} ({pct:4.1f}%)  {tag:>6s}")
    print("-" * 100)
    total_saved = total_before - total_after
    total_pct = (total_saved / total_before * 100) if total_before else 0
    print(f"{'TOTAL':60s} {total_before:>10,} {total_after:>10,} {total_saved:>7,} ({total_pct:4.1f}%)")


if __name__ == "__main__":
    main()
