#!/usr/bin/env bash
# Headless integration tests. For each mod folder (default: all mods/*/ with a tests/ dir), boot the
# decompiled game (reference/, see README) in the container with the mod's src/<mod_id>,
# tests/<test_id> and dev/<dev_mod_id> (dev-only mods the tests use, never packaged) mounted as
# mods-unpacked/. A test mod prints "MOD-TESTS: START", "  ok   ...", "  FAIL ...", "  info: ..."
# and finally "MOD-TESTS: PASS" / "MOD-TESTS: FAIL ...", then quits.
# Fails on: any script error in mod code, any game-script error while tests run (except the
# missing-Steam ones), a get_meta / get_child / get_node engine error while tests run, a
# missing PASS.
#
# The tests mostly wait in real time, so a test mod can split itself into suites: it runs the ones
# named in MOD_TEST_SUITES (comma-separated, empty: all), and its shards.txt lists one group of
# suites per line. Each line gets its own game process, all of them at once. A line can end in
# "+<mod folder>" (repeatable): that process also loads the mod in mods/<mod folder>/src, for
# tests of one mod next to another ("together +brotato-together").
#
# Usage: tools/check.sh [-q] [-s suite[,suite...]] [mods/<folder> ...]
#   -s  run only these suites, in one process
#   -q  print failures, info lines and the summary only
# Environment:
#   CONTAINER         container runtime (default: podman, else docker)
#   MOD_CHECK_CACHE   1: always run from a copy of reference/ in ~/.cache, 0: never (default: only
#                     when the repo is on a slow mount such as a Windows drive under WSL)
#   MOD_CHECK_RESYNC  1: refresh that copy even if reference/ looks unchanged
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/reference/project.godot" ] || { echo "reference/ missing: decompile the game first (docs/game-code.md)" >&2; exit 1; }

# Known headless artifacts: no Steam -> no language -> set_locale(Nil) in ProgressData.apply_settings,
# which surfaces through script extensions of ProgressData.
KNOWN_ARTIFACTS="set_locale' in base 'TranslationServer'"

quiet=0
only_suites=""
while getopts "qs:" opt; do
  case "$opt" in
    q) quiet=1 ;;
    s) only_suites="$OPTARG" ;;
    *) echo "Usage: tools/check.sh [-q] [-s suite[,suite...]] [mods/<folder> ...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

RUNTIME="${CONTAINER:-$(command -v podman > /dev/null 2>&1 && echo podman || echo docker)}"
if [ "$(basename "$RUNTIME")" = podman ]; then
  run_as=(--userns=keep-id)
  label=",z"  # shared label: several containers mount the same folders at once
  empty_mods="/proj/mods-unpacked:notmpcopyup"  # podman would copy the folder's content in
else
  run_as=(--user "$(id -u):$(id -g)")
  label=""
  empty_mods="/proj/mods-unpacked"
fi

# The game reads ~17000 files while booting. Over a network-style mount (a Windows drive under WSL
# is 9p) that takes close to a minute instead of a few seconds, so the game then runs from a copy
# on the local filesystem. The copy is refreshed when reference/project.godot changes.
GAME="$ROOT/reference"
use_cache="${MOD_CHECK_CACHE:-auto}"
if [ "$use_cache" = auto ]; then
  case "$(df --output=fstype "$ROOT" 2> /dev/null | tail -1)" in
    9p | drvfs | cifs | smb3 | virtiofs | vboxsf) use_cache=1 ;;
    *) use_cache=0 ;;
  esac
fi
if [ "$use_cache" = 1 ]; then
  GAME="${XDG_CACHE_HOME:-$HOME/.cache}/brotato-modtools/reference"
  stamp="$(stat -c '%Y %s' "$ROOT/reference/project.godot")"
  if [ "${MOD_CHECK_RESYNC:-0}" = 1 ] || [ "$(cat "$GAME/.source-stamp" 2> /dev/null)" != "$stamp" ]; then
    echo "copying reference/ to $GAME (once per game version) ..."
    mkdir -p "$GAME"
    if command -v rsync > /dev/null 2>&1; then
      rsync -a --delete --exclude /mods-unpacked/ --exclude /.source-stamp "$ROOT/reference/" "$GAME/" || exit 1
    else
      rm -rf "$GAME" && mkdir -p "$GAME" && cp -a "$ROOT/reference/." "$GAME/" || exit 1
      rm -rf "$GAME/mods-unpacked"
    fi
    echo "$stamp" > "$GAME/.source-stamp"
  fi
fi

# run_game <log> <suites> <mount args...>. mods-unpacked/ is a tmpfs per process: the Mod Loader
# stops at a mod folder without a manifest, which another mod's check would leave behind.
mkdir -p "$GAME/mods-unpacked"
run_game() {
  local log="$1" suites="$2"
  shift 2
  "$RUNTIME" run --rm "${run_as[@]}" -e HOME=/tmp -e MOD_TEST_SUITES="$suites" \
    -v "$GAME:/proj${label:+:${label#,}}" --tmpfs "$empty_mods" "$@" \
    brotato-modtools timeout 240 godot3 --path /proj --no-window > "$log" 2>&1
}

report() {
  local log="$1" own_errors runtime_errors engine_errors
  own_errors=$(grep -A2 "SCRIPT ERROR" "$log" | grep -v -F "$KNOWN_ARTIFACTS" | grep -B1 "mods-unpacked" \
    | grep -v -F "apply_settings (res://mods-unpacked" || true)
  runtime_errors=$(awk '/MOD-TESTS: START/{f=1} f' "$log" | grep -A1 "SCRIPT ERROR" \
    | grep -v -e "in base 'Nil'" -e "SteamPlatform" -e "^--" -F -e "$KNOWN_ARTIFACTS" \
    | grep -B1 "  at: " | sort -u || true)
  # Engine errors that always mean a script bug (a script carries on after them, so they are no
  # SCRIPT ERROR): get_meta of a missing key (also with a default), get_child out of range,
  # get_node of a path that names nothing (a focus neighbour left on a freed control) and the
  # get_path_to(null) that follows it.
  engine_errors=$(awk '/MOD-TESTS: START/{f=1} f' "$log" \
    | grep -E "^ERROR: (The object does not have any 'meta' values|Index p_index = .* is out of bounds \(data\.children|\(?Node not found: |Parameter \"p_node\" is null)" \
    | sort -u || true)
  if [ "$quiet" = 1 ]; then
    grep -E "^  (FAIL|info:) |MOD-TESTS: (PASS|FAIL)" "$log"
  else
    grep -E "^  (ok  |FAIL|info:) |MOD-TESTS: (PASS|FAIL)" "$log"
  fi
  if [ -n "$own_errors" ]; then echo "Script errors in mod code:"; echo "$own_errors"; fi
  if [ -n "$runtime_errors" ]; then echo "Game script errors during tests:"; echo "$runtime_errors"; fi
  if [ -n "$engine_errors" ]; then echo "Engine errors during tests:"; echo "$engine_errors"; fi
  [ -z "$own_errors" ] && [ -z "$runtime_errors" ] && [ -z "$engine_errors" ] \
    && grep -q "MOD-TESTS: PASS" "$log"
}

if [ $# -gt 0 ]; then folders=("$@"); else folders=("$ROOT"/mods/*/); fi
overall=0
for folder in "${folders[@]}"; do
  folder="$(cd "$folder" && pwd)"
  [ -d "$folder/tests" ] || { echo "== ${folder#"$ROOT"/}: no tests, skipped"; continue; }
  echo "== ${folder#"$ROOT"/}"
  mounts=()
  shards=()
  extras=()  # per shard: the other mod folders its process loads, "+"-separated
  only_extra=""
  for dir in "$folder"/src/*/ "$folder"/tests/*/ "$folder"/dev/*/; do
    [ -d "$dir" ] || continue  # no dev/ (an unmatched glob stays as it is)
    id="$(basename "$dir")"
    mounts+=(-v "${dir%/}:/proj/mods-unpacked/$id:ro$label")
    [ -f "$dir/shards.txt" ] || continue
    while IFS= read -r line; do
      line="$(echo "$line" | tr -d ' \t\r')"
      case "$line" in "" | "#"*) continue ;; esac
      suites="${line%%+*}"
      extra=""
      [ "$suites" = "$line" ] || extra="${line#*+}"
      if [ -z "$only_suites" ]; then
        shards+=("$suites")
        extras+=("$extra")
      elif [ -n "$extra" ]; then
        # -s: the named suites get the mods their shards ask for, each mod once (two suites
        # from one line, or two lines naming the same mod, must not mount it twice).
        for suite in ${only_suites//,/ }; do
          case ",$suites," in *",$suite,"*) ;; *) continue ;; esac
          for other in ${extra//+/ }; do
            case "+$only_extra+" in *"+$other+"*) ;; *) only_extra="$only_extra+$other" ;; esac
          done
        done
      fi
    done < "$dir/shards.txt"
  done
  if [ ${#shards[@]} -eq 0 ]; then  # one process: the named suites, or everything
    shards=("$only_suites")
    extras=("$only_extra")
  fi
  # Every extra mod is checked before the first process starts: none is left running behind.
  for extra in "${extras[@]}"; do
    for other in ${extra//+/ }; do
      [ -d "$ROOT/mods/$other/src" ] || { echo "shards.txt: no mod in mods/$other" >&2; exit 2; }
    done
  done

  started=$(date +%s)
  logs=()
  pids=()
  for i in "${!shards[@]}"; do
    log="$(mktemp "${TMPDIR:-/tmp}/mod-check.XXXXXX")"
    logs+=("$log")
    shard_mounts=("${mounts[@]}")
    for other in ${extras[$i]//+/ }; do
      for dir in "$ROOT/mods/$other"/src/*/; do
        id="$(basename "$dir")"
        shard_mounts+=(-v "${dir%/}:/proj/mods-unpacked/$id:ro$label")
      done
    done
    run_game "$log" "${shards[$i]}" "${shard_mounts[@]}" &
    pids+=($!)
  done
  wait "${pids[@]}"

  failed=0
  checks=0
  for i in "${!shards[@]}"; do
    [ ${#shards[@]} -gt 1 ] && echo "-- ${shards[$i]}"
    checks=$((checks + $(grep -c "^  ok   " "${logs[$i]}")))
    if report "${logs[$i]}"; then
      rm -f "${logs[$i]}"
    else
      echo "FAILED${shards[$i]:+ (${shards[$i]})} (full log: ${logs[$i]})"
      failed=1
    fi
  done
  took=$(($(date +%s) - started))
  if [ "$failed" = 1 ]; then
    overall=1
    echo "FAILED ($checks checks ok, ${took} s)"
  else
    echo "passed ($checks checks, ${took} s)"
  fi
done
exit $overall
