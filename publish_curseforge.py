#!/usr/bin/env python3
"""
Publish the packaged Assfish Aquarium addon zip to CurseForge via the author Upload API.

This is a DELIBERATE publish step, not automated. The zip is produced by
package_addon.py -> dist/AssfishAquarium.zip, so the usual flow is:

    python package_addon.py
    python publish_curseforge.py --dry-run     # sanity-check metadata first
    python publish_curseforge.py               # actually upload

One-time setup - put these in a gitignored .env (see .env.example), or export
them as real environment variables:
    CURSEFORGE_API_TOKEN=...        # https://legacy.curseforge.com/account/api-tokens
    CURSEFORGE_PROJECT_ID=1605689  # the number on your addon's project page
    # optional override; default is derived from the .toc Interface:
    # CURSEFORGE_GAME_VERSIONS=["1.15.9"]

Note: the CurseForge project must already exist (create it once on the website);
this script uploads a new file to it, it does not create the project.

Docs: https://support.curseforge.com/en/support/solutions/articles/9000197321
"""
import argparse
import json
import logging
import re
import sys
from datetime import date
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import config  # noqa: E402  (local env/secret loader)

log = logging.getLogger("publish_curseforge")

API_BASE = "https://wow.curseforge.com/api"
ADDON_NAME = "AssfishAquarium"
TOC = ROOT / ADDON_NAME / f"{ADDON_NAME}.toc"
ZIP = ROOT / "dist" / f"{ADDON_NAME}.zip"


def _toc_field(name, default=None):
    """Read a '## Field: value' line from the addon .toc."""
    if not TOC.exists():
        return default
    for line in TOC.read_text(encoding="utf-8").splitlines():
        m = re.match(rf"##\s*{name}\s*:\s*(.+)", line, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return default


def _version_from_interface(iface):
    """Interface number -> game version string. 11509 -> '1.15.9'."""
    n = int(iface)
    return f"{n // 10000}.{(n // 100) % 100}.{n % 100}"


def _fetch_game_versions(token):
    """GET /api/game/versions -> the raw list of {name, id, ...} entries."""
    r = httpx.get(f"{API_BASE}/game/versions",
                  headers={"X-Api-Token": token}, timeout=30)
    r.raise_for_status()
    return r.json()


def _resolve_game_version_ids(versions, wanted_names):
    """Map game-version NAMES (e.g. '1.15.9') to the numeric IDs the upload API
    needs. Raises with the available names if none match, so a flavor mismatch
    fails loudly, not silently."""
    by_name = {}
    for v in versions:
        by_name.setdefault(v.get("name"), []).append(v.get("id"))
    ids = [i for name in wanted_names for i in by_name.get(name, [])]
    if not ids:
        sample = sorted({v.get("name") for v in versions if v.get("name")})[:40]
        raise SystemExit(
            f"No CurseForge game version matched {wanted_names}. "
            f"Set CURSEFORGE_GAME_VERSIONS to one of (sample): {sample}")
    return ids


def _parse_semver(name):
    """'1.15.9' -> (1, 15, 9); returns None for non-numeric names."""
    parts = (name or "").split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)


def _warn_if_outdated(versions, wanted_names):
    """Loudly warn when a wanted version is behind the newest patch in its own
    major.minor family (e.g. tagging 1.15.8 when CurseForge already lists 1.15.9).
    CurseForge hides files tagged only for an outdated version under the default
    'current version' filter, so the upload 'succeeds' but stays invisible."""
    available = [v for v in (_parse_semver(n) for n in
                             {x.get("name") for x in versions}) if v]
    for name in wanted_names:
        want = _parse_semver(name)
        if not want:
            continue
        newer = [v for v in available if v[:2] == want[:2] and v > want]
        if newer:
            latest = ".".join(map(str, max(newer)))
            log.warning(
                "game version %s is OUTDATED - CurseForge already lists %s in the "
                "same family. The upload will succeed but be HIDDEN under the "
                "current-version filter. Bump '## Interface' in the .toc (or set "
                "CURSEFORGE_GAME_VERSIONS) to %s.", name, latest, latest)


def main():
    ap = argparse.ArgumentParser(description="Publish Assfish Aquarium to CurseForge.")
    ap.add_argument("--release-type", choices=["release", "beta", "alpha"], default="release")
    ap.add_argument("--version", default=None,
                    help="release version string (default: '<toc Version>.<YYYYMMDD>', "
                         "e.g. 0.1.0.20260727 - keeps every publish unique & sortable)")
    ap.add_argument("--changelog", default=None, help="changelog text (default: auto)")
    ap.add_argument("--zip", type=Path, default=ZIP)
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve metadata + game versions but do not upload")
    args = ap.parse_args()

    token = config.CURSEFORGE_API_TOKEN
    project_id = config.CURSEFORGE_PROJECT_ID
    if not token:
        raise SystemExit("Missing CURSEFORGE_API_TOKEN - set it in .env (see .env.example).")
    if not project_id:
        raise SystemExit("Missing CURSEFORGE_PROJECT_ID - set it in .env "
                         "(the number on your CurseForge project page).")

    if not args.zip.exists():
        raise SystemExit(f"addon zip not found: {args.zip} - run 'python package_addon.py' first")

    # The .toc Version is the semantic base (e.g. "0.1.0"); we append a date
    # stamp so each publish is a unique, sortable file on CurseForge (avoids the
    # "you must upload a unique file" rejection and keeps files distinguishable).
    base_version = _toc_field("Version", "0.0")
    version = args.version or f"{base_version}.{date.today():%Y%m%d}"
    iface = _toc_field("Interface", "11509")
    wanted = config.CURSEFORGE_GAME_VERSIONS or [_version_from_interface(iface)]
    versions = _fetch_game_versions(token)
    _warn_if_outdated(versions, wanted)
    game_version_ids = _resolve_game_version_ids(versions, wanted)

    changelog = args.changelog or (
        f"Assfish Aquarium {version} - https://github.com/donaldpminer/ASSFISHAQUARIUM")
    metadata = {
        "changelog": changelog,
        "changelogType": "text",
        "displayName": f"Assfish Aquarium {version}",
        "releaseType": args.release_type,
        "gameVersions": game_version_ids,
    }
    log.info("publishing %s (%.0f KB) as '%s' [%s] for game versions %s -> ids %s",
             args.zip.name, args.zip.stat().st_size / 1024, metadata["displayName"],
             args.release_type, wanted, game_version_ids)

    if args.dry_run:
        log.info("dry run - metadata: %s", json.dumps(metadata))
        return

    with open(args.zip, "rb") as fh:
        r = httpx.post(
            f"{API_BASE}/projects/{project_id}/upload-file",
            headers={"X-Api-Token": token},
            data={"metadata": json.dumps(metadata)},
            files={"file": (args.zip.name, fh, "application/zip")},
            timeout=120,
        )
    if r.status_code >= 400:
        raise SystemExit(f"CurseForge upload failed ({r.status_code}): {r.text}")
    log.info("uploaded. CurseForge file id: %s", r.json().get("id"))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    main()
