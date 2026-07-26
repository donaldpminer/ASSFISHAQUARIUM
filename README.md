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
| **ButtBass** | Restoration Shaman helper — effective-healing / Chain Heal tracker and the "WF Now" windfury announcer. |

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

Work in progress — being assembled from the four standalone addons. Interface `11509`
(the modernized Classic Era / 1.15.9 client).

MIT licensed. Not affiliated with Blizzard Entertainment.
