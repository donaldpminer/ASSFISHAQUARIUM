# ASSFISH AQUARIUM

A single World of Warcraft **Classic Era** addon that bundles several of Donald Miner's
Classic Era helpers under one roof, with **unified options** (one page in
*Options → AddOns*, a subcategory per module) and **one minimap button**.

Each bundled tool is a **module** you can enable or disable independently:

| Module | What it does |
| --- | --- |
| **Mobber** | Mob-centric enemy-debuff grid — a row per nearby enemy, prioritized debuffs first, "my debuff" highlighting. |
| **FF Tracker** | Configurable countdown bars for Faerie Fire and any HoT / DoT / debuff / buff. |
| **Sunderboard** | Leaderboard for armor-reduction debuffs (Sunder / Expose / Faerie Fire / CoR), scored by the physical damage they enable. |
| **Shaman Stuff** | Restoration Shaman helper — effective-healing / Chain Heal tracker, a party/totem frame, and the always-on "WF Now" windfury announcer. |

Each module's window can be **Disabled**, **Unlocked** (shown + movable), or **Locked**
(shown + pinned) from the minimap dropdown (left-click) or its settings page.

## Install (manual, while in development)

```bash
bash scripts/install.sh
```

Then `/reload`. Copies `AssfishAquarium/` into your Classic Era `Interface/AddOns/` folder.

## Layout

```
AssfishAquarium/            the addon (folder name must match the .toc)
  AssfishAquarium.toc
  Core/                     shared core: addon table, module registry, unified settings,
                            the one minimap button, saved variables
  Modules/                  each bundled tool, gated by its enable toggle
    Mobber/  FFTracker/  Sunderboard/  ButtBass/
```

## Status

Work in progress — assembled from the four standalone addons and passed a static +
adversarial-review pass, but **not yet tested in-game**. Interface `11509` (the modernized
Classic Era / 1.15.9 client).

## Notes

- Fresh unified config — the old standalone SavedVariables are **not** migrated; everyone
  starts at bundle defaults. Settings live in `AssfishAquariumDB` (account-wide) and
  `AssfishAquariumCharDB` (per-character); Sunderboard's leaderboard is account-wide.
- **Shaman Stuff** is enabled by default only on Shamans; its **Windfury announcer runs for
  every class** regardless (toggle it off in the Shaman Stuff settings). Sunderboard's board
  is visible everywhere while unlocked so you can position it; the group/instance gate applies
  once it's locked.
- Windfury addon-message prefixes (`ButtBassWF`, `WF_STATUS`) are unchanged, so cross-player
  "WF Now" interop still works.

MIT licensed. Not affiliated with Blizzard Entertainment.
