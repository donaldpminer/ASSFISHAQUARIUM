#!/bin/bash
# Copy the ASSFISH AQUARIUM suite (Core + each tool's addon) into your WoW Classic Era
# AddOns folder, then /reload. Override the target with WOW_ADDONS_DIR if needed.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADDONS_DIR="${WOW_ADDONS_DIR:-/c/Program Files (x86)/World of Warcraft/_classic_era_/Interface/AddOns}"

# The Core addon plus one addon per tool. (Adopted third-party addons, if any, are listed by
# their original folder name here too.)
ADDONS="AssfishAquarium AssfishAquarium_Mobber AssfishAquarium_FFTracker AssfishAquarium_Sunderboard AssfishAquarium_ButtBass AssfishAquarium_Windfury"

if [ ! -d "$ADDONS_DIR" ]; then
  echo "ERROR: AddOns dir not found: $ADDONS_DIR"
  echo "Set WOW_ADDONS_DIR to your Classic Era Interface/AddOns path and re-run."
  exit 1
fi

for addon in $ADDONS; do
  src="$ROOT/$addon"
  if [ ! -d "$src" ]; then echo "SKIP (missing): $addon"; continue; fi
  rm -rf "$ADDONS_DIR/$addon"
  cp -r "$src" "$ADDONS_DIR/$addon"
  echo "installed $addon"
done
echo "done -> $ADDONS_DIR"
