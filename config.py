"""Central configuration / secrets loader for FFTracker's CurseForge publish.

All values come from **environment variables**, so the same code runs unchanged
locally and in CI. This file contains NO secrets and is safe to commit. For local
development, keep your secrets in a gitignored ``.env`` file next to this module
(see ``.env.example``) — it's loaded automatically below, so you don't have to
export anything in your shell. Real environment variables always take precedence
over the ``.env`` file.

Consumers just ``import config`` and read e.g. ``config.CURSEFORGE_API_TOKEN``.
"""
import json
import os
from pathlib import Path
from typing import Optional


def _load_dotenv(env_path: Optional[Path] = None) -> None:
    """Populate ``os.environ`` from a gitignored ``.env`` file, if present.

    Parses the simple ``KEY=VALUE`` format (one per line, optional surrounding
    quotes stripped). Blank lines and full-line ``# comments`` are skipped, but
    inline ``# comments`` after a value are NOT stripped — put comments on their
    own line (see ``.env.example``). ``setdefault`` means a value already present
    in the real environment (e.g. injected by CI) is never overwritten by the
    file. No dependency on python-dotenv; the format is trivial here.
    """
    if env_path is None:
        env_path = Path(__file__).resolve().parent / ".env"
    if not env_path.exists():
        return
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def _env_int(name: str, default: int = 0) -> int:
    """Read an integer env var, falling back to ``default`` if unset/empty."""
    value = os.environ.get(name, "").strip()
    return int(value) if value else default


def _env_json_list(name: str) -> Optional[list]:
    """Read an optional JSON-list env var, or ``None`` if unset/empty."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ValueError(
            f"{name} must be a JSON list (e.g. '[\"1.15.8\"]'), got {raw!r}: {e}"
        ) from e
    if not isinstance(value, list):
        raise ValueError(
            f"{name} must be a JSON *list* (e.g. '[\"1.15.8\"]'), "
            f"got {type(value).__name__}: {raw!r}"
        )
    return value


_load_dotenv()

# CurseForge addon publishing (see publish_curseforge.py). PROJECT_ID is a public
# identifier (the number on your project page), not a secret; the API token is.
CURSEFORGE_API_TOKEN = os.environ.get("CURSEFORGE_API_TOKEN", "")
CURSEFORGE_PROJECT_ID = _env_int("CURSEFORGE_PROJECT_ID", 0)

# Optional override for the addon's CurseForge game versions, as a JSON list
# (e.g. CURSEFORGE_GAME_VERSIONS='["1.15.8"]'). Defaults to None, in which case
# publish_curseforge.py derives the version from the .toc Interface field.
CURSEFORGE_GAME_VERSIONS = _env_json_list("CURSEFORGE_GAME_VERSIONS")
