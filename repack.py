"""
repack.py — build and install the Vostok DomFrags Overhaul bundle.

Zips mod.txt + mods/ into a .vmz with forward-slash paths (required by the
mod loader), installs it to the game mods folder, clears the mount cache.
"""

import zipfile
import shutil
import os

MOD_NAME  = "Vostok-DomFrags-Overhaul"
SRC_DIR   = "mods"
VMZ_NAME  = f"{MOD_NAME}.vmz"

GAME_MODS = r"D:\Steam\steamapps\common\Road to Vostok\mods"
APPDATA   = os.path.join(os.environ["APPDATA"], "Road to Vostok")
CACHE_DIR = os.path.join(APPDATA, "vmz_mount_cache")

# File-extension skip list (build artifacts that occasionally slip in)
SKIP_EXTS = (".bak", ".tmp")

print(f"Packing mod.txt + {SRC_DIR}/ -> {VMZ_NAME}")
with zipfile.ZipFile(VMZ_NAME, "w", zipfile.ZIP_DEFLATED) as z:
    z.write("mod.txt", "mod.txt")
    print("  + mod.txt")
    for root, dirs, files in os.walk(SRC_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for filename in files:
            if filename.endswith(SKIP_EXTS):
                continue
            filepath = os.path.join(root, filename)
            arcname = filepath.replace("\\", "/")
            z.write(filepath, arcname)
            print(f"  + {arcname}")

size_kb = os.path.getsize(VMZ_NAME) // 1024
print(f"Built {VMZ_NAME} ({size_kb} KB)")

dest = os.path.join(GAME_MODS, VMZ_NAME)
shutil.copy2(VMZ_NAME, dest)
print(f"Installed -> {dest}")

cleared = 0
if os.path.isdir(CACHE_DIR):
    for entry in os.listdir(CACHE_DIR):
        entry_norm = entry.lower().replace("-", "").replace(" ", "")
        target_norm = MOD_NAME.lower().replace("-", "")
        if target_norm in entry_norm:
            path = os.path.join(CACHE_DIR, entry)
            try:
                if os.path.isdir(path):
                    shutil.rmtree(path)
                else:
                    os.remove(path)
                print(f"Cleared cache: {entry}")
                cleared += 1
            except OSError as e:
                print(f"  Warning: could not remove {entry}: {e}")
if cleared == 0:
    print("No cache entries found (OK on first install)")

print("\nDone. Launch the game to test.")
