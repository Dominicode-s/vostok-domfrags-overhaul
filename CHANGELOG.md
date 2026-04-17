# Changelog

### v1.0.2
- Bumped bundled mod versions to match their post-shrink-textures releases:
  - Cash System 2.9.1 → 2.9.2
  - Secure Container 1.0.5 → 1.0.6
  - XP & Skills System 2.5.0 → 2.5.2
- XP 2.5.2 additionally fixes the Interface.gd `CHAIN BROKEN` warning that appeared when Cash + Secure Container + XP were loaded together. `_process` now threads `super(delta)` and `UpdateStats` is a delta-style override on top of the base-game method instead of a silent full-replacement.

### v1.0.1
- Texture optimization — VMZ size reduced from 31 MB → 7 MB (77% smaller) with no visual impact:
  - Skillbook icon PNGs pre-resampled to 128×256 on disk. The XP mod was already calling `Image.INTERPOLATE_LANCZOS` to this exact target at load time, so shipping at source resolution (720×1456) was pure bandwidth waste. Zero functional change.
  - Skillbook cover PNGs and SecureContainer pouch textures downscaled from 1024×1024 to 512×512. Textures wrap small in-hand 3D props and are visually indistinguishable at normal gameplay distance.
  - All remaining PNGs recompressed with max DEFLATE + palette quantization where lossless.
- Added `compress_textures.py` (lossless PNG recompression) and `downscale_textures.py --aggressive` (targeted downscale) helpers.

### v1.0.0
- Initial bundled release combining six mods into a single VMZ package:
  - Cash System 2.9.1
  - Secure Container 1.0.5
  - XP & Skills System 2.5.0
  - Quick Stack & Sort 2.5.1
  - Run Summary 1.2.5
  - Vostok AI 1.2.0
- Unified `mod.txt` declaring all 7 autoloads (SecureContainer contributes 2)
- Save data paths preserved from individual releases — existing progress carries over when switching from standalone mods to the bundle
