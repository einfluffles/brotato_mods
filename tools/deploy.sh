#!/usr/bin/env bash
# Copy a packaged mod zip into the local copy of its (already subscribed) Workshop item, for fast
# iteration without re-uploading. The Steam build of Brotato only loads subscribed Workshop items
# (mod_loader.gd::_load_mod_zips); <game>/mods is ignored. Steam may restore the uploaded version on
# item update/verify: re-run after that.
# Replaces every zip already in the item folder (e.g. one with an older file name): two zips with the
# same mod inside would make the loader load it twice.
# Usage: tools/deploy.sh <name> <workshop_item_id> [package_dir]   (run tools/package.sh first)
#   <name> = the package folder in dist/, i.e. the manifest's "name" (e.g. BrotatoTogether)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: deploy.sh <name> <workshop_item_id> [package_dir]}"
ITEM_ID="${2:?usage: deploy.sh <name> <workshop_item_id> [package_dir]}"
PACKAGES="${3:-$ROOT/dist}"
WORKSHOP_DIR="${BROTATO_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/1942280}"
ZIP="$PACKAGES/$NAME/$NAME.zip"
[ -f "$ZIP" ] || { echo "missing $ZIP: run tools/package.sh first" >&2; exit 1; }
[ -d "$WORKSHOP_DIR/$ITEM_ID" ] || { echo "not subscribed / not downloaded: $WORKSHOP_DIR/$ITEM_ID" >&2; exit 1; }
find "$WORKSHOP_DIR/$ITEM_ID" -maxdepth 1 -name "*.zip" -print -delete | sed "s/^/  removed /"
cp "$ZIP" "$WORKSHOP_DIR/$ITEM_ID/"
echo "deployed $NAME.zip to $WORKSHOP_DIR/$ITEM_ID/"
