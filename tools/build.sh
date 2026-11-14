#!/usr/bin/env bash
# Package the mod as dist/<mod_id>.zip (layout: mods-unpacked/<mod_id>/...), zipped inside the container.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_ID="einfluffles-BrotatoTogether"
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/$MOD_ID.zip"
"$ROOT/tools/run.sh" zip -qr "dist/$MOD_ID.zip" "mods-unpacked/$MOD_ID" -x '*.import' '*/.claude/*'
echo "built dist/$MOD_ID.zip"
