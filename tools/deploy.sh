#!/usr/bin/env bash
# Copy a packaged mod zip into the local copy of its (already subscribed) Workshop item, for fast
# iteration without re-uploading. The Steam build of Brotato only loads subscribed Workshop items
# (mod_loader.gd::_load_mod_zips); <game>/mods is ignored. Steam may restore the uploaded version on
# item update/verify — re-run after that.
# Usage: tools/deploy.sh <mod_id> <workshop_item_id> [package_dir]   (run tools/package.sh first)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_ID="${1:?usage: deploy.sh <mod_id> <workshop_item_id> [package_dir]}"
ITEM_ID="${2:?usage: deploy.sh <mod_id> <workshop_item_id> [package_dir]}"
PACKAGES="${3:-$ROOT/dist}"
WORKSHOP_DIR="${BROTATO_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/1942280}"
ZIP="$PACKAGES/$MOD_ID/$MOD_ID.zip"
[ -f "$ZIP" ] || { echo "missing $ZIP — run tools/package.sh first" >&2; exit 1; }
[ -d "$WORKSHOP_DIR/$ITEM_ID" ] || { echo "not subscribed / not downloaded: $WORKSHOP_DIR/$ITEM_ID" >&2; exit 1; }
cp "$ZIP" "$WORKSHOP_DIR/$ITEM_ID/"
echo "deployed $MOD_ID to $WORKSHOP_DIR/$ITEM_ID/"
