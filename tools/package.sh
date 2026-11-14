#!/usr/bin/env bash
# Package every mod (mods/*/src/<mod_id>/) into a Steam-Workshop-ready folder:
#   <target>/<name>/<name>.zip       zip layout mods-unpacked/<mod_id>/... (Godot Mod Loader)
#   <target>/<name>/preview.png      mods/<folder>/preview.png, or rendered from mods/<folder>/preview.svg
# <name> is the manifest's "name" (e.g. BrotatoTogether). Only the folder inside the zip identifies
# the mod (<mod_id> = namespace-name); the zip's file name is free.
# Upload each folder with the game's GodotWorkshopUtility (select the zip + preview image).
# Usage: tools/package.sh [target_dir]   (default: dist)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-dist}"
case "$TARGET" in /*) ;; *) TARGET="$ROOT/$TARGET" ;; esac
mkdir -p "$TARGET"

shopt -s nullglob
manifests=("$ROOT"/mods/*/src/*/manifest.json)
[ ${#manifests[@]} -gt 0 ] || { echo "no mods found under mods/*/src/*/manifest.json" >&2; exit 1; }

for manifest in "${manifests[@]}"; do
  src_dir="$(dirname "$manifest")"
  mod_id="$(basename "$src_dir")"
  mod_folder="$(cd "$src_dir/../.." && pwd)"
  rel_src="${src_dir#$ROOT/}"
  name="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)"
  [ -n "$name" ] || { echo "no \"name\" in $manifest" >&2; exit 1; }
  out="$TARGET/$name"
  rm -rf "$out"
  mkdir -p "$out"
  # Validate + zip inside the toolchain container (python3/zip live there).
  podman run --rm --userns=keep-id -e HOME=/tmp \
    -v "$ROOT:/work:ro,Z" -v "$out:/out:Z" -w /work brotato-modtools bash -euc '
      python3 -I - "$1" "$2" <<PY
import json, sys
path, mod_id = sys.argv[1], sys.argv[2]
m = json.load(open(path))
expected = "%s-%s" % (m["namespace"], m["name"])
if expected != mod_id:
    sys.exit("manifest namespace-name %r does not match folder %r" % (expected, mod_id))
print("  %s %s" % (mod_id, m["version_number"]))
PY
      stage=$(mktemp -d)
      mkdir -p "$stage/mods-unpacked"
      cp -r "$3" "$stage/mods-unpacked/$2"
      cp LICENSE "$stage/mods-unpacked/$2/LICENSE"  # MIT: the notice travels with every copy
      (cd "$stage" && zip -qr "/out/$5.zip" mods-unpacked -x "*/.*" "*.import")
      if [ -f "$4/preview.svg" ] && [ ! -f "$4/preview.png" ]; then
        rsvg-convert -w 1024 -h 1024 "$4/preview.svg" -o /out/preview.png
      fi
    ' _ "$rel_src/manifest.json" "$mod_id" "$rel_src" "${mod_folder#$ROOT/}" "$name"
  if [ -f "$mod_folder/preview.png" ]; then cp "$mod_folder/preview.png" "$out/preview.png"; fi
  echo "  -> ${out#$ROOT/}/"
done
