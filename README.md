# Vostok DomFrags Overhaul

A single VMZ that bundles six mods into one coordinated package. Install this one file instead of juggling six individual mods.

## Bundled mods

| Mod | Purpose | Component version |
|---|---|---|
| **Cash System** | Adds cash items that drop as loot and fund trader purchases. Injects a cash item pool into the loot database, adds a wallet UI at traders, sell/buy flow. | 2.9.2 |
| **Secure Container** | Three tiers of secure pouches (Field / Secure / Case) as lootable items with their own tetris-inventory window. Protects contents across deaths (configurable). | 1.0.6 |
| **XP & Skills System** | 13-skill progression tree with XP earned from containers / kills / tasks / trades. Prestige ranks, skill books, MCM-tunable rewards and bonuses. | 2.5.3 |
| **Quick Stack & Sort** | Inventory QoL — quick-stack into containers, full sort with multiple modes, per-slot locking. | 2.5.1 |
| **Run Summary** | Post-run stats modal after death or shelter return. Persistent history of last 10 runs with XP earned, kills, damage taken, cash earned/spent, and more. | 1.2.5 |
| **Vostok AI** | Tactical AI overhaul — 5 personality archetypes, squad coordination, group spawning with formations, suppression, panic, call-for-backup, weapon-role awareness, enhanced hearing, investigation, XP-scaled difficulty. | 1.2.0 |

## Installation

1. **Remove any of the individual mods first** — the bundle re-declares their autoloads, so installing both the bundle and an individual copy causes a duplicate-autoload error in the mod loader.
2. Drop `Vostok-DomFrags-Overhaul.vmz` into `<game>/mods/`.
3. Launch.

## Compatibility notes

All six bundled mods are self-consistent; the bundle just packages them together. A few points worth knowing:

- **Interface.gd chain** — Cash, Secure Container, and XP all override `res://Scripts/Interface.gd`. The mod loader will report `CHAIN OK` or `CHAIN BROKEN` in `%APPDATA%/Road to Vostok/modloader_conflicts.txt` depending on whether `super()` is properly threaded. The chain has been stable in previous testing but any update to one mod may break it; check the conflict report after any version bump.
- **MCM entries** — each mod registers its own MCM section (six in total). Config saves per-mod to `user://MCM/<ModId>/`. No MCM key collisions.
- **Save data** — each mod saves to its own `user://` file (WalletData.cfg, XPData.cfg, SecureContainer.json, RunSummaryHistory_*.cfg, QuickStackSort_locks.cfg, VostokAI settings). Paths unchanged from the individual releases so existing save data is preserved when switching from individual mods to the bundle.
- **Metadata namespaces** — each mod uses a unique `Engine.set_meta` key (`CashMain`, `XPMain`, `RunSummary`, `SecureContainer`, `SecureContainerConfig`, `VostokAIMain`). No collisions.

## Building locally

```
python repack.py
```

This zips `mod.txt` + `mods/` into `Vostok-DomFrags-Overhaul.vmz`, installs it to the game mods folder, and clears the mount cache.

## Layout

```
vostok-domfrags-overhaul/
├── mod.txt                               # Single manifest, 7 autoloads declared
├── README.md
├── CHANGELOG.md
├── repack.py                             # Build + deploy helper
└── mods/
    ├── CashSystem/
    ├── SecureContainer/
    ├── XPSkillsSystem/
    ├── QuickStack/
    ├── RunSummary/
    └── VostokAI/
```

## Source repos

Each bundled mod has its own development repo for granular changes:

- [vostok-cash](https://github.com/Dominicode-s/vostok-cash)
- [vostok-secure-container](https://github.com/Dominicode-s/vostok-secure-container)
- [vostok-skills](https://github.com/Dominicode-s/vostok-skills)
- [vostok-quick-stack](https://github.com/Dominicode-s/vostok-quick-stack)
- [vostok-run-summary](https://github.com/Dominicode-s/vostok-run-summary)
- [vostok-domfrags-ai](https://github.com/Dominicode-s/vostok-domfrags-ai)

Updates to any bundled mod land here after the individual repo is updated.
