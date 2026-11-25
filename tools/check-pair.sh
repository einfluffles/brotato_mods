#!/usr/bin/env bash
# Pair tests: brotato:together's local-play scenarios with a host and one or more clients as
# headless game processes, linked as in tools\play-local.ps1's windows: the dev mod
# mods/brotato-together/dev/einfluffles-TogetherLocal puts its Steam emulator under the mod's
# unchanged transport and connects the games over TCP on 127.0.0.1 (inside the container).
# One container per scenario, at most PAIR_JOBS at once.
#
# The game is reference/ (or tools/check.sh's copy of it, tools/game-env.sh) with its
# project.godot replaced, in the container only, by one without the feature "steam": the game's
# local build. Each process gets its own HOME and XDG_DATA_HOME (its user folder is
# /pair/<name>/data/Brotato, not $HOME/.local/share/Brotato), the dev mod's BT_LOCAL_* variables
# and BT_LOCAL_SCENARIO: it runs its part of the scenario (scenarios.gd, in step with the other
# games: scenario_runner.gd), prints "PAIR-TESTS: PASS" or "PAIR-TESTS: FAIL <why>" and closes.
# The dev mod's refusal rules hold as in a window: stock Godot has no Steam singleton, the copy
# has no feature "steam", the user folder is not the game's own. The clients join through the
# launch option "+connect_lobby <the host's first lobby>", as in a window.
#
# A scenario's launch settings come from scenarios.gd's LAUNCH, as for tools\play-local.ps1:
# clients (games client1..N), host_dlcs / client_dlcs (BT_LOCAL_DLCS), no_join (no autohost, no
# +connect_lobby) and client_ref / host_ref: that side runs brotato:together of a git ref
# (last_release: the newest tag brotato-together/*). Its src/ comes from git archive into the
# run's folder and is mounted, with this worktree's dev mod, over a second mount of the same game
# at /proj-ref; nothing is copied.
#
# A scenario passes when every game prints PASS within PAIR_TIMEOUT, without a script error in mod
# code. On a failure every log's relevant lines are printed; the folders are kept.
#
# Usage: tools/check-pair.sh [-q] [scenario ...]   (default: every one in scenarios.gd's HEADLESS)
#   -q  print the summary lines only
# Environment:
#   CONTAINER, MOD_CHECK_CACHE, MOD_CHECK_RESYNC   as for tools/check.sh
#   PAIR_JOBS     scenarios at once (default 4)
#   PAIR_TIMEOUT  seconds a scenario's games may run (default 420)
#   PAIR_BREAK    token: the clients get another wire token than the host, so their handshake
#                 fails and every scenario must fail (a check of this script)
#   PAIR_KEEP     1: keep the folders of passed scenarios too
#   PAIR_DIR      where the scenario folders go (default: a new folder under TMPDIR)
#   PAIR_CLIENT_REF, PAIR_HOST_REF   a git ref for the scenarios whose LAUNCH names another build:
#                 the clients' (or the host's) build instead of the scenario's own
set -uo pipefail

KNOWN_ARTIFACTS="set_locale' in base 'TranslationServer'"  # as in tools/check.sh
FIRST_LOBBY=$(((1 << 55) + (1 << 8) + 1))  # steam_emulator.gd: the host's (number 1) first lobby

# --- In the container: one scenario's games ---
# PAIR_CLIENTS, PAIR_HOST_DLCS, PAIR_CLIENT_DLCS, PAIR_NO_JOIN, PAIR_REF_SIDE, PAIR_REF_LABEL: the
# scenario's launch settings (set by the outside part).
if [ "${1:-}" = --inside ]; then
  scenario="$2"
  ulimit -c 0  # a crash leaves no core file
  hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
  port=$((20000 + RANDOM % 20000))
  token="$(hex)"
  run="$scenario-$(hex | head -c 8)"
  names=(host)
  for ((c = 1; c <= ${PAIR_CLIENTS:-1}; c++)); do names+=("client$c"); done
  pids=()
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    dir="/pair/$name"
    mkdir -p "$dir/home" "$dir/data"
    role=host
    args=()
    env_more=()
    [ "${PAIR_NO_JOIN:-0}" = 1 ] || env_more=(BT_LOCAL_AUTOHOST=1)
    instance_token="$token"
    dlcs="${PAIR_HOST_DLCS:-}"
    if [ "$i" -gt 0 ]; then
      role=client
      env_more=()
      [ "${PAIR_NO_JOIN:-0}" = 1 ] || args=(+connect_lobby "$FIRST_LOBBY")
      [ "${PAIR_BREAK:-}" = token ] && instance_token="$(hex)"
      dlcs="${PAIR_CLIENT_DLCS:-}"
    fi
    project=/proj
    if [ "${PAIR_REF_SIDE:-}" = "$role" ]; then
      project=/proj-ref
      env_more+=(BT_LOCAL_REF="$PAIR_REF_LABEL")
    fi
    [ -z "$dlcs" ] || env_more+=(BT_LOCAL_DLCS="$dlcs")
    env HOME="$dir/home" XDG_DATA_HOME="$dir/data" BT_LOCAL_ROLE="$role" BT_LOCAL_ID="$((i + 1))" \
      BT_LOCAL_NAME="$([ "$i" = 0 ] && echo Host || echo "Client $i")" BT_LOCAL_PORT="$port" \
      BT_LOCAL_TOKEN="$instance_token" BT_LOCAL_DIR="$dir" BT_LOCAL_PROFILE=lan \
      BT_LOCAL_SCENARIO="$scenario" BT_LOCAL_RUN="$run" BT_LOCAL_PEERS="$(IFS=,; echo "${names[*]}")" \
      "${env_more[@]}" timeout "${PAIR_TIMEOUT:-420}" godot3 --path "$project" --no-window "${args[@]}" \
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

# git for this checkout. A Windows worktree's .git names a Windows path that WSL's git cannot
# follow: then Git for Windows, through WSL's interop.
git_here() {
  if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$ROOT" "$@"
  else
    (cd "$ROOT" && git.exe "$@")
  fi
}

# A scenario's LAUNCH settings in scenarios.gd ("<name>": "key=value ..."), one per line.
launch_of() {
  sed -n '/^const LAUNCH := {/,/^}/p' "$SCENARIOS_GD" \
    | sed -n "s/^[[:space:]]*\"$1\": \"\([^\"]*\)\".*/\1/p" | tr ' ' '\n' | grep -v '^$' || true
}

# brotato:together's src/ of a git ref (last_release: the newest tag brotato-together/*) in
# $work/refs/<commit>: sets ref_label and ref_dir.
prepare_ref() {
  local ref="$1" commit
  if [ "$ref" = last_release ]; then
    ref="$(git_here for-each-ref --sort=-creatordate --count=1 --format='%(refname:short)' \
      'refs/tags/brotato-together/*' | tr -d '\r')"
    [ -n "$ref" ] || { echo "no tag brotato-together/* for last_release" >&2; return 1; }
  fi
  commit="$(git_here rev-parse --verify -q "$ref^{commit}" | tr -d '\r')"
  [ -n "$commit" ] || { echo "no commit for the ref '$ref'" >&2; return 1; }
  ref_label="$ref (${commit:0:12})"
  ref_dir="$work/refs/${commit:0:12}"
  [ -f "$ref_dir/.complete" ] && return 0
  rm -rf "$ref_dir" && mkdir -p "$ref_dir"
  git_here archive --format=tar "$commit" mods/brotato-together/src | tar -x -C "$ref_dir" \
    || { echo "git archive of $ref failed" >&2; return 1; }
  echo "$ref $commit" > "$ref_dir/.complete"
}

# Each scenario's launch settings, before any container starts (the refs are unpacked once).
declare -A clients_of host_dlcs_of client_dlcs_of no_join_of ref_side_of ref_label_of ref_dir_of
for scenario in "${scenarios[@]}"; do
  side="" ref=""
  while IFS='=' read -r key value; do
    case "$key" in
      clients) clients_of[$scenario]="$value" ;;
      host_dlcs) host_dlcs_of[$scenario]="$value" ;;
      client_dlcs) client_dlcs_of[$scenario]="$value" ;;
      no_join) no_join_of[$scenario]="$value" ;;
      client_ref | host_ref) side="${key%_ref}" ref="$value" ;;
      *) echo "scenarios.gd LAUNCH of $scenario: unknown setting '$key'" >&2; exit 2 ;;
    esac
  done < <(launch_of "$scenario")
  [ -n "$side" ] || continue
  if [ -n "${PAIR_HOST_REF:-}" ]; then
    side=host ref="$PAIR_HOST_REF"
  elif [ -n "${PAIR_CLIENT_REF:-}" ]; then
    side=client ref="$PAIR_CLIENT_REF"
  fi
  prepare_ref "$ref" || exit 1
  ref_side_of[$scenario]="$side"
  ref_label_of[$scenario]="$ref_label"
  ref_dir_of[$scenario]="$ref_dir"
done

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
  local scenario="$1" dir="$work/$1" name="brotato-pair-$$-$1" clients="${clients_of[$1]:-1}" c mod
  rm -rf "$dir" && mkdir -p "$dir"
  date +%s > "$dir/started"
  { echo host; for ((c = 1; c <= clients; c++)); do echo "client$c"; done; } > "$dir/names"
  # The other build's side: the same game a second time, with that build's mods.
  local more=()
  if [ -n "${ref_side_of[$1]:-}" ]; then
    more=(-v "$GAME:/proj-ref${label:+:${label#,}}" --tmpfs "/proj-ref${empty_mods#/proj}")
    more+=(-v "$project:/proj-ref/project.godot:ro$label")
    for mod in "${ref_dir_of[$1]}"/mods/brotato-together/src/*/ "$MOD"/dev/*/; do
      [ -d "$mod" ] && more+=(-v "${mod%/}:/proj-ref/mods-unpacked/$(basename "$mod"):ro$label")
    done
  fi
  "$RUNTIME" run --rm --name "$name" "${run_as[@]}" -e HOME=/tmp \
    -e PAIR_TIMEOUT="${PAIR_TIMEOUT:-420}" -e PAIR_BREAK="${PAIR_BREAK:-}" \
    -e PAIR_CLIENTS="$clients" -e PAIR_HOST_DLCS="${host_dlcs_of[$1]:-}" \
    -e PAIR_CLIENT_DLCS="${client_dlcs_of[$1]:-}" -e PAIR_NO_JOIN="${no_join_of[$1]:-0}" \
    -e PAIR_REF_SIDE="${ref_side_of[$1]:-}" -e PAIR_REF_LABEL="${ref_label_of[$1]:-}" \
    -v "$GAME:/proj${label:+:${label#,}}" --tmpfs "$empty_mods" "${mounts[@]}" "${more[@]}" \
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
  local scenario="$1" dir="$work/$1" passed=1 checks=0 took name log count errors best="" names
  mapfile -t names < "$dir/names"
  took=$(($(cat "$dir/ended") - $(cat "$dir/started")))
  for name in "${names[@]}"; do
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
    for name in "${names[@]}"; do
      # Godot 3.6.2's headless build can crash in its own teardown, after everything else; a
      # crash before the verdict leaves none and fails above.
      if awk '/^PAIR-TESTS: PASS/{f=1} f' "$dir/$name/stdout.log" | grep -q "^handle_crash"; then
        echo "  info: $name crashed while closing, after its verdict ($(grep -m1 -o "signal [0-9]*" "$dir/$name/stdout.log"))"
      fi
    done
    return 0
  fi
  echo "== $scenario: FAILED (${took} s; folder: $dir)"
  for name in "${names[@]}"; do
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
