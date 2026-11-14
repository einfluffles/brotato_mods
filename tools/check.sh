#!/usr/bin/env bash
# Boot the decompiled game (reference/, see README) headless with the mod + the dev-only test mod
# (tests/einfluffles-TogetherTests). Fails on any script error in our code or a failing test.
# No Steam in here: the transport reports "Steam singleton not available", which is expected; the game's
# own Steam calls also error out (Nil) — those lines are ignored.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_ID="einfluffles-BrotatoTogether"
TEST_ID="einfluffles-TogetherTests"
[ -f "$ROOT/reference/project.godot" ] || { echo "reference/ missing — decompile the game first (README)" >&2; exit 1; }
mkdir -p "$ROOT/reference/mods-unpacked/$MOD_ID" "$ROOT/reference/mods-unpacked/$TEST_ID"
LOG="$(mktemp "${TMPDIR:-/tmp}/together-check.XXXXXX")"
podman run --rm --userns=keep-id -e HOME=/tmp \
  -v "$ROOT/reference:/proj:Z" \
  -v "$ROOT/mods-unpacked/$MOD_ID:/proj/mods-unpacked/$MOD_ID:ro,Z" \
  -v "$ROOT/tests/$TEST_ID:/proj/mods-unpacked/$TEST_ID:ro,Z" \
  brotato-modtools timeout 120 godot3 --path /proj --no-window > "$LOG" 2>&1
own_errors=$(grep -A2 "SCRIPT ERROR" "$LOG" | grep -B1 "mods-unpacked" || true)
grep -E "^  (ok  |FAIL) |TOGETHER-TESTS" "$LOG"
if [ -n "$own_errors" ]; then echo "Script errors in mod code:"; echo "$own_errors"; fi
if [ -n "$own_errors" ] || ! grep -q "TOGETHER-TESTS: PASS" "$LOG"; then
  echo "check FAILED (full log: $LOG)"; exit 1
fi
rm -f "$LOG"; echo "check passed"
