#!/usr/bin/env bash
# Pair tests: brotato:together's local-play scenarios with a host and a client as two headless game
# processes, linked as in tools\play-local.ps1's windows: the dev mod
# mods/brotato-together/dev/einfluffles-TogetherLocal puts its Steam emulator under the mod's
# unchanged transport and connects the games over TCP on 127.0.0.1 (inside the container).
# One container per scenario, at most PAIR_JOBS at once.
#
# The game is reference/ (or tools/check.sh's copy of it, tools/game-env.sh) with its
# project.godot replaced, in the container only, by one without the feature "steam": the game's
# local build. Each process gets its own HOME and XDG_DATA_HOME (its user folder is
# /pair/<name>/data/Brotato, not $HOME/.local/share/Brotato), the dev mod's BT_LOCAL_* variables
# and BT_LOCAL_SCENARIO: it runs its part of the scenario (scenarios.gd, in step with the other
# game: scenario_runner.gd), prints "PAIR-TESTS: PASS" or "PAIR-TESTS: FAIL <why>" and closes.
# The dev mod's refusal rules hold as in a window: stock Godot has no Steam singleton, the copy
# has no feature "steam", the user folder is not the game's own. The client joins through the
# launch option "+connect_lobby <the host's first lobby>", as in a window.
#
# A scenario passes when both sides print PASS within PAIR_TIMEOUT, without a script error in mod
# code. On a failure both logs' relevant lines are printed; the folders are kept.
#
# Usage: tools/check-pair.sh [-q] [scenario ...]   (default: every one in scenarios.gd's HEADLESS)
#   -q  print the summary lines only
# Environment:
#   CONTAINER, MOD_CHECK_CACHE, MOD_CHECK_RESYNC   as for tools/check.sh
#   PAIR_JOBS     scenarios at once (default 4)
#   PAIR_TIMEOUT  seconds a scenario's games may run (default 420)
#   PAIR_BREAK    token: the client gets another wire token than the host, so its handshake fails
#                 and every scenario must fail (a check of this script)
#   PAIR_KEEP     1: keep the folders of passed scenarios too
#   PAIR_DIR      where the scenario folders go (default: a new folder under TMPDIR)
set -uo pipefail

KNOWN_ARTIFACTS="set_locale' in base 'TranslationServer'"  # as in tools/check.sh
FIRST_LOBBY=$(((1 << 55) + (1 << 8) + 1))  # steam_emulator.gd: the host's (number 1) first lobby
NAMES=(host client1)

# --- In the container: one scenario's two games ---
if [ "${1:-}" = --inside ]; then
  scenario="$2"
  ulimit -c 0  # a crash leaves no core file
  hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
  port=$((20000 + RANDOM % 20000))
  token="$(hex)"
  run="$scenario-$(hex | head -c 8)"
  pids=()
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    dir="/pair/$name"
    mkdir -p "$dir/home" "$dir/data"
    role=host
    args=()
    env_more=(BT_LOCAL_AUTOHOST=1)
    instance_token="$token"
    if [ "$i" -gt 0 ]; then
      role=client
      args=(+connect_lobby "$FIRST_LOBBY")
      env_more=()
      [ "${PAIR_BREAK:-}" = token ] && instance_token="$(hex)"
    fi
    env HOME="$dir/home" XDG_DATA_HOME="$dir/data" BT_LOCAL_ROLE="$role" BT_LOCAL_ID="$((i + 1))" \
      BT_LOCAL_NAME="$([ "$i" = 0 ] && echo Host || echo "Client $i")" BT_LOCAL_PORT="$port" \
      BT_LOCAL_TOKEN="$instance_token" BT_LOCAL_DIR="$dir" BT_LOCAL_PROFILE=lan \
      BT_LOCAL_SCENARIO="$scenario" BT_LOCAL_RUN="$run" BT_LOCAL_PEERS="$(IFS=,; echo "${NAMES[*]}")" \
      "${env_more[@]}" timeout "${PAIR_TIMEOUT:-420}" godot3 --path /proj --no-window "${args[@]}" \
      > "$dir/stdout.log" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"
  exit 0
fi

# --- Outside: the containers and the report ---
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/reference/project.godot" ] || { echo "reference/ missing: decompile the game first (docs/game-code.md)" >&2; exit 1; }
MOD="$ROOT/mods/brotato-together"
SCENARIOS_GD="$MOD/dev/einfluffles-TogetherLocal/scenarios.gd"

quiet=0
while getopts "q" opt; do
  case "$opt" in
    q) quiet=1 ;;
    *) echo "Usage: tools/check-pair.sh [-q] [scenario ...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# A list constant of scenarios.gd ("const NAMES := [" up to "]"), one name per line.
gd_list() { sed -n "/^const $1 := \[/,/\]/p" "$SCENARIOS_GD" | grep -o '"[a-z_]*"' | tr -d '"'; }
mapfile -t known < <(gd_list NAMES)
if [ $# -gt 0 ]; then scenarios=("$@"); else mapfile -t scenarios < <(gd_list HEADLESS); fi
[ ${#scenarios[@]} -gt 0 ] || { echo "no scenarios found in $SCENARIOS_GD" >&2; exit 2; }
for scenario in "${scenarios[@]}"; do
  case " ${known[*]} " in *" $scenario "*) ;; *) echo "no scenario '$scenario' (one of ${known[*]})" >&2; exit 2 ;; esac
done

# shellcheck source=tools/game-env.sh
. "$ROOT/tools/game-env.sh"

work="${PAIR_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/check-pair.XXXXXX")}"
mkdir -p "$work"
# The local build's project.godot: the Steam build's line removed, the user folder as assumed.
project="$work/project.godot"
grep -v -x '_custom_features="steam"' "$ROOT/reference/project.godot" > "$project"
removed=$(($(wc -l < "$ROOT/reference/project.godot") - $(wc -l < "$project")))
[ "$removed" = 1 ] || { echo "project.godot has no line _custom_features=\"steam\"" >&2; exit 1; }
for needed in 'config/name="Brotato"' 'config/use_custom_user_dir=true'; do
  grep -q -x -F "$needed" "$project" || { echo "project.godot lacks $needed: the user folder is unknown" >&2; exit 1; }
done

mounts=(-v "$project:/proj/project.godot:ro$label")
for dir in "$MOD"/src/*/ "$MOD"/dev/*/; do
  [ -d "$dir" ] || continue
  mounts+=(-v "${dir%/}:/proj/mods-unpacked/$(basename "$dir"):ro$label")
done
mounts+=(-v "$ROOT/tools/check-pair.sh:/pair-tool/check-pair.sh:ro$label")

cleanup_done=0
cleanup() {
  [ "$cleanup_done" = 1 ] && return
  local scenario
  for scenario in "${scenarios[@]}"; do
    "$RUNTIME" rm -f "brotato-pair-$$-$scenario" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

start_scenario() {
  local scenario="$1" dir="$work/$1" name="brotato-pair-$$-$1"
  rm -rf "$dir" && mkdir -p "$dir"
  date +%s > "$dir/started"
  "$RUNTIME" run --rm --name "$name" "${run_as[@]}" -e HOME=/tmp \
    -e PAIR_TIMEOUT="${PAIR_TIMEOUT:-420}" -e PAIR_BREAK="${PAIR_BREAK:-}" \
    -v "$GAME:/proj${label:+:${label#,}}" --tmpfs "$empty_mods" "${mounts[@]}" \
    -v "$dir:/pair$label" brotato-modtools bash /pair-tool/check-pair.sh --inside "$scenario" \
    > "$dir/container.log" 2>&1
  date +%s > "$dir/ended"
}

# Script errors in mod code (as tools/check.sh's report): nothing when there are none.
own_errors() {
  grep -A2 "SCRIPT ERROR" "$1" | grep -v -F "$KNOWN_ARTIFACTS" | grep -B1 "mods-unpacked" \
    | grep -v -F "apply_settings (res://mods-unpacked" || true
}

# Engine errors that always mean a script bug, from the scenario's start (as tools/check.sh's).
engine_errors() {
  awk '/^PAIR-TESTS: START/{f=1} f' "$1" \
    | grep -E "^ERROR: (The object does not have any 'meta' values|Index p_index = .* is out of bounds \(data\.children|\(?Node not found: |Parameter \"p_node\" is null)" \
    | sort -u || true
}

# Prints a scenario's result; true when it passed.
report() {
  local scenario="$1" dir="$work/$1" passed=1 checks=0 took name log count errors best=""
  took=$(($(cat "$dir/ended") - $(cat "$dir/started")))
  for name in "${NAMES[@]}"; do
    log="$dir/$name/stdout.log"
    [ -f "$log" ] || { passed=0; continue; }
    grep -q "^PAIR-TESTS: PASS" "$log" || passed=0
    [ -z "$(own_errors "$log")$(engine_errors "$log")" ] || passed=0
    count=$(grep -c "^  ok   " "$log")
    if [ "$count" -gt "$checks" ] || [ -z "$best" ]; then checks=$count; best="$log"; fi
  done
  if [ "$passed" = 1 ]; then
    echo "== $scenario: passed ($checks checks, ${took} s)"
    [ "$quiet" = 1 ] || grep "^  ok   " "$best"
    for name in "${NAMES[@]}"; do
      # Godot 3.6.2's headless build can crash in its own teardown, after everything else; a
      # crash before the verdict leaves none and fails above.
      if awk '/^PAIR-TESTS: PASS/{f=1} f' "$dir/$name/stdout.log" | grep -q "^handle_crash"; then
        echo "  info: $name crashed while closing, after its verdict ($(grep -m1 -o "signal [0-9]*" "$dir/$name/stdout.log"))"
      fi
    done
    return 0
  fi
  echo "== $scenario: FAILED (${took} s; folder: $dir)"
  for name in "${NAMES[@]}"; do
    log="$dir/$name/stdout.log"
    echo "-- $name ($log)"
    if [ ! -f "$log" ]; then
      echo "   no log; the container's output:"
      tail -20 "$dir/container.log"
      continue
    fi
    grep -E "^(PAIR-TESTS|step )|^  [^ \"]" "$log" | grep -v "^  ok   " | tail -40
    grep -q "^PAIR-TESTS: \(PASS\|FAIL\)" "$log" || echo "   no PAIR-TESTS verdict (timed out or crashed)"
    errors="$(own_errors "$log")"
    [ -z "$errors" ] || { echo "   script errors in mod code:"; echo "$errors"; }
    errors="$(engine_errors "$log")"
    [ -z "$errors" ] || { echo "   engine errors during the scenario:"; echo "$errors"; }
    grep -E "(WARNING|ERROR).*(TogetherLocal|BrotatoTogether)" "$log" | tail -12 | sed 's/^/   /'
  done
  return 1
}

echo "pair tests: ${scenarios[*]} (in $work)"
started=$(date +%s)
jobs_max="${PAIR_JOBS:-4}"
running=0
for scenario in "${scenarios[@]}"; do
  if [ "$running" -ge "$jobs_max" ]; then
    wait -n
    running=$((running - 1))
  fi
  start_scenario "$scenario" &
  running=$((running + 1))
done
wait
cleanup_done=1  # every container has ended (--rm)

failed=0
for scenario in "${scenarios[@]}"; do
  if report "$scenario"; then
    [ "${PAIR_KEEP:-0}" = 1 ] || rm -rf "${work:?}/$scenario"
  else
    failed=$((failed + 1))
  fi
done
took=$(($(date +%s) - started))
if [ "$failed" -gt 0 ]; then
  echo "FAILED ($failed of ${#scenarios[@]} scenarios, ${took} s)"
  exit 1
fi
[ "${PAIR_KEEP:-0}" = 1 ] || [ -n "${PAIR_DIR:-}" ] || rm -rf "$work"
echo "passed (${#scenarios[@]} scenarios, ${took} s)"
