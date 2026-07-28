#!/usr/bin/env python3
"""Package the ASSFISH AQUARIUM suite into ``dist/AssfishAquarium.zip``.

The suite is now MULTIPLE addons -- the Core plus one addon per tool -- so the zip
contains several top-level folders (each a WoW addon). This is what you upload to
CurseForge (see publish_curseforge.py) and is also handy for a manual install.

Uses Python's stdlib ``zipfile`` (no external ``zip`` binary), so it runs the same
on Windows / Git Bash / macOS / Linux.

    python package_addon.py            # -> dist/AssfishAquarium.zip
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
ZIP = DIST / "AssfishAquarium.zip"

# The Core addon plus one addon per tool (each a top-level folder in the zip).
ADDONS = [
    "AssfishAquarium",
    "AssfishAquarium_Mobber",
    "AssfishAquarium_FFTracker",
    "AssfishAquarium_Sunderboard",
    "AssfishAquarium_ButtBass",
    "AssfishAquarium_Windfury",
]

EXCLUDE_NAMES = {".DS_Store", "Thumbs.db", "__pycache__", ".git"}
EXCLUDE_SUFFIXES = (".swp", ".swo", ".orig", ".bak", "~")


def _included(path: Path) -> bool:
    if any(part in EXCLUDE_NAMES for part in path.parts):
        return False
    return not path.name.endswith(EXCLUDE_SUFFIXES)


def main() -> int:
    missing = [a for a in ADDONS if not (ROOT / a).is_dir()]
    if missing:
        print(f"ERROR: addon folder(s) not found: {', '.join(missing)}", file=sys.stderr)
        return 1
    for a in ADDONS:
        toc = ROOT / a / f"{a}.toc"
        if not toc.exists():
            print(f"ERROR: {toc.name} not found in {a}", file=sys.stderr)
            return 1

    DIST.mkdir(exist_ok=True)
    if ZIP.exists():
        ZIP.unlink()

    count = 0
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for a in ADDONS:
            addon_dir = ROOT / a
            for path in sorted(addon_dir.rglob("*")):
                if not path.is_file() or not _included(path):
                    continue
                # Stage each file under its addon's top-level folder (forward slashes).
                arcname = (Path(a) / path.relative_to(addon_dir)).as_posix()
                zf.write(path, arcname)
                count += 1

    if count == 0:
        print(f"ERROR: no files packaged", file=sys.stderr)
        return 1

    # sanity: no backslash entries (breaks extraction on macOS/Linux)
    with zipfile.ZipFile(ZIP) as zf:
        bad = sum("\\" in n for n in zf.namelist())
    if bad:
        print(f"ERROR: {bad} entries contain backslashes", file=sys.stderr)
        return 1

    print(f"packaged {count} files from {len(ADDONS)} addons -> {ZIP} ({ZIP.stat().st_size / 1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
