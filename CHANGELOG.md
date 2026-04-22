# Changelog

### v2.0.0 — MML v3.0.0 compatibility

**Requires Metro Mod Loader v3.0.0 or newer.** Incompatible with earlier MML versions. If you run the Overhaul bundle alongside the individual mod VMZs, make sure each individual mod is also at its v3.0.0-compat release (Cash 3.0.0, Secure Container 2.0.0, XP & Skills 3.0.0, Vostok AI 2.0.0).

Synced bundled copies with the hook-API refactors:
- **Cash System → 3.0.0** (Drop / ContextPlace hooks, no more `take_over_path` on Interface)
- **Secure Container → 2.0.0** (7 Interface hooks — hover getters + Drop/ContextPlace)
- **XP & Skills System → 3.0.0** (Character + Interface hooks, decoupled from `gameData.xp*` fields, Skills UI preserved)
- **Vostok AI → 2.0.0** (12 hooks on AI / AISpawner, per-instance state on node meta)

No `script.take_over_path()` calls or `overrideScript()` functions remain anywhere in the bundle. The sole `icon.take_over_path(...)` in XPSkillsSystem is a Resource-level call (for the dynamically-generated skillbook icon), unrelated to the script chain and harmless.

QuickStack and RunSummary were not affected by the MML v3.0.0 change and carry unchanged into this bundle.

### v1.0.3
- Picked up XP & Skills System 2.5.3, which folds the Character.gd override chain-fix alongside the earlier Interface.gd fix. All XP overrides on Character.gd (Energy / Hydration / Mental / Stamina / Temperature / Clamp) now chain `super()` so any future Character.gd-overriding mod stacked on top of the bundle still runs. Math is preserved at default MCM values.

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
