#!/usr/bin/env bash
# Build and copy the zip into our (private) Workshop item's local content folder.
# The Steam build of Brotato only loads *subscribed Workshop items* (mod_loader.gd::_load_mod_zips with the
# steam options profile); the local <game>/mods folder is ignored. So: upload once as a private/friends-only
# Workshop item, subscribe, then iterate by overwriting the local copy. Steam may restore the uploaded version
# on item update/verify — re-run this script after that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${WORKSHOP_ITEM_ID:?set WORKSHOP_ITEM_ID to the published Workshop item id}"
WORKSHOP_DIR="${BROTATO_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/1942280}"
TARGET="$WORKSHOP_DIR/$WORKSHOP_ITEM_ID"
[ -d "$TARGET" ] || { echo "not subscribed / not downloaded: $TARGET" >&2; exit 1; }
"$ROOT/tools/build.sh"
cp "$ROOT/dist/einfluffles-BrotatoTogether.zip" "$TARGET/"
echo "deployed to $TARGET/"
