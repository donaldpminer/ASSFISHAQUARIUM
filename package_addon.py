#!/usr/bin/env python3
"""Package the Assfish Aquarium addon into ``dist/AssfishAquarium.zip``.

The zip is what you upload to CurseForge (see publish_curseforge.py) and is also
handy for a manual install. The addon is staged under its WoW-required top-level
folder name (``AssfishAquarium/``) inside the archive.

Uses Python's stdlib ``zipfile`` (no external ``zip`` binary needed), so it runs
the same on Windows / Git Bash / macOS / Linux.

    python package_addon.py            # -> dist/AssfishAquarium.zip
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ADDON_NAME = "AssfishAquarium"       # WoW-required top-level folder name (matches the .toc)
ADDON_DIR = ROOT / ADDON_NAME        # install-ready source folder (tracked in git)
DIST = ROOT / "dist"
ZIP = DIST / f"{ADDON_NAME}.zip"

# Things we never want inside the packaged addon.
EXCLUDE_NAMES = {".DS_Store", "Thumbs.db", "__pycache__", ".git"}
EXCLUDE_SUFFIXES = (".swp", ".swo", ".orig", ".bak", "~")


def _included(path: Path) -> bool:
    if any(part in EXCLUDE_NAMES for part in path.parts):
        return False
    return not path.name.endswith(EXCLUDE_SUFFIXES)


def main() -> int:
    if not ADDON_DIR.is_dir():
        print(f"ERROR: addon folder not found: {ADDON_DIR}", file=sys.stderr)
        return 1
    toc = ADDON_DIR / f"{ADDON_NAME}.toc"
    if not toc.exists():
        print(f"ERROR: {toc.name} not found in {ADDON_DIR}", file=sys.stderr)
        return 1

    DIST.mkdir(exist_ok=True)
    if ZIP.exists():
        ZIP.unlink()

    count = 0
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(ADDON_DIR.rglob("*")):
            if not path.is_file() or not _included(path):
                continue
            # Stage every file under the top-level "AssfishAquarium/" folder WoW expects.
            arcname = Path(ADDON_NAME) / path.relative_to(ADDON_DIR)
            zf.write(path, arcname.as_posix())
            count += 1

    if count == 0:
        print(f"ERROR: no files packaged from {ADDON_DIR}", file=sys.stderr)
        return 1

    print(f"packaged {count} files -> {ZIP} ({ZIP.stat().st_size / 1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
