#!/usr/bin/env bash
# Headless integration tests. For each mod folder (default: all mods/*/ with a tests/ dir), boot the
# decompiled game (reference/, see README) in the container with the mod's src/<mod_id> and
# tests/<test_id> mounted as mods-unpacked/. A test mod prints "MOD-TESTS: START", "  ok   ...",
# "  FAIL ...", "  info: ..." and finally "MOD-TESTS: PASS" / "MOD-TESTS: FAIL ...", then quits.
# Fails on: any script error in mod code, any game-script error while tests run (except the
# missing-Steam ones), a missing PASS.
# Usage: tools/check.sh [mods/<folder> ...]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/reference/project.godot" ] || { echo "reference/ missing — decompile the game first (README)" >&2; exit 1; }

# Known headless artifacts: no Steam -> no language -> set_locale(Nil) in ProgressData.apply_settings,
# which surfaces through script extensions of ProgressData.
KNOWN_ARTIFACTS="set_locale' in base 'TranslationServer'"

if [ $# -gt 0 ]; then folders=("$@"); else folders=("$ROOT"/mods/*/); fi
overall=0
for folder in "${folders[@]}"; do
  folder="$(cd "$folder" && pwd)"
  [ -d "$folder/tests" ] || { echo "== ${folder#$ROOT/}: no tests, skipped"; continue; }
  echo "== ${folder#$ROOT/}"
  mounts=()
  for dir in "$folder"/src/*/ "$folder"/tests/*/; do
    id="$(basename "$dir")"
    mkdir -p "$ROOT/reference/mods-unpacked/$id"
    mounts+=(-v "$dir:/proj/mods-unpacked/$id:ro,Z")
  done
  LOG="$(mktemp "${TMPDIR:-/tmp}/mod-check.XXXXXX")"
  podman run --rm --userns=keep-id -e HOME=/tmp -v "$ROOT/reference:/proj:Z" "${mounts[@]}" \
    brotato-modtools timeout 240 godot3 --path /proj --no-window > "$LOG" 2>&1
  own_errors=$(grep -A2 "SCRIPT ERROR" "$LOG" | grep -v -F "$KNOWN_ARTIFACTS" | grep -B1 "mods-unpacked" \
    | grep -v -F "apply_settings (res://mods-unpacked" || true)
  runtime_errors=$(awk '/MOD-TESTS: START/{f=1} f' "$LOG" | grep -A1 "SCRIPT ERROR" \
    | grep -v -e "in base 'Nil'" -e "SteamPlatform" -e "^--" -F -e "$KNOWN_ARTIFACTS" \
    | grep -B1 "  at: " | sort -u || true)
  grep -E "^  (ok  |FAIL|info:) |MOD-TESTS: (PASS|FAIL)" "$LOG"
  if [ -n "$own_errors" ]; then echo "Script errors in mod code:"; echo "$own_errors"; fi
  if [ -n "$runtime_errors" ]; then echo "Game script errors during tests:"; echo "$runtime_errors"; fi
  if [ -n "$own_errors" ] || [ -n "$runtime_errors" ] || ! grep -q "MOD-TESTS: PASS" "$LOG"; then
    echo "FAILED (full log: $LOG)"; overall=1
  else
    rm -f "$LOG"; echo "passed"
  fi
done
exit $overall
