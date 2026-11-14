#!/usr/bin/env bash
# Parse/compile-check every mod script with headless Godot 3 inside the decompiled game project
# (reference/, see README), so game class_names and res:// paths resolve. Catches syntax/type errors only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_ID="einfluffles-BrotatoTogether"
[ -f "$ROOT/reference/project.godot" ] || { echo "reference/ missing — decompile the game first (README)" >&2; exit 1; }
mkdir -p "$ROOT/reference/mods-unpacked/$MOD_ID"
scripts=$(cd "$ROOT" && find "mods-unpacked/$MOD_ID" -name '*.gd' -not -path '*/.claude/*' | sort)
podman run --rm --userns=keep-id -e HOME=/tmp \
  -v "$ROOT/reference:/proj:Z" -v "$ROOT/mods-unpacked/$MOD_ID:/proj/mods-unpacked/$MOD_ID:ro,Z" \
  -v "$ROOT/tools/check_stubs/log.gd:/proj/addons/mod_loader/api/log.gd:ro,Z" \
  brotato-modtools bash -c '
    fail=0
    for s in '"$(echo $scripts | tr '\n' ' ')"'; do
      out=$(godot3 --path /proj --no-window --check-only -s "res://$s" 2>&1) || true
      errs=$(echo "$out" | grep -E "SCRIPT ERROR|Parse Error|ERROR:" | grep -v "Condition \"!p_ignore_state" || true)
      if [ -n "$errs" ]; then echo "FAIL $s"; echo "$out" | grep -A3 -E "SCRIPT ERROR|Parse Error|ERROR:" | head -20; fail=1; else echo "ok   $s"; fi
    done
    exit $fail'
