#!/bin/bash
# Copy the AssfishAquarium addon into your WoW Classic Era AddOns folder, then /reload.
# Override the target with WOW_ADDONS_DIR if your install isn't at the default path.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../AssfishAquarium"
ADDONS_DIR="${WOW_ADDONS_DIR:-/c/Program Files (x86)/World of Warcraft/_classic_era_/Interface/AddOns}"
DEST="$ADDONS_DIR/AssfishAquarium"

if [ ! -d "$SRC" ]; then echo "ERROR: addon source not found: $SRC"; exit 1; fi
if [ ! -d "$ADDONS_DIR" ]; then
  echo "ERROR: AddOns dir not found: $ADDONS_DIR"
  echo "Set WOW_ADDONS_DIR to your Classic Era Interface/AddOns path and re-run."
  exit 1
fi

rm -rf "$DEST"
cp -r "$SRC" "$DEST"
echo "installed $SRC -> $DEST"
