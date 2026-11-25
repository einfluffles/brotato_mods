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
# Every mod of this repo has a translations.csv: a process also fails when one of its mods from
# src/ did not log "Init (<n> translated texts)" with n > 0 (tools/game-env.sh).
#
# -p (packaged) runs the mods as players get them: src/ as the zips tools/package.sh builds (what
# tools/release.sh uploads), tests/ and dev/ zipped the same way (into a temporary folder, never by
# package.sh), all of them loaded by the Mod Loader from a folder of zips (--mods-path, with the
# Workshop switched off in its options: tools/game-env.sh) instead of folders in mods-unpacked/. A
# file in a zip reads differently from one in a folder (docs/testing.md).
#
# Usage: tools/check.sh [-q] [-p] [-s suite[,suite...]] [mods/<folder> ...]
#   -s  run only these suites, in one process
#   -q  print failures, info lines and the summary only
#   -p  packaged: every mod from a zip
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
packaged=0
only_suites=""
while getopts "qps:" opt; do
  case "$opt" in
    q) quiet=1 ;;
    p) packaged=1 ;;
    s) only_suites="$OPTARG" ;;
    *) echo "Usage: tools/check.sh [-q] [-p] [-s suite[,suite...]] [mods/<folder> ...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# The container runtime and the game (reference/, or its copy on a slow mount): GAME, RUNTIME, ...
# shellcheck source=tools/game-env.sh
. "$ROOT/tools/game-env.sh"

# run_game <log> <suites> <mod folder...>: the folders mounted in mods-unpacked/, or (-p) their
# zips in a folder of their own, mounted as /mods. mods-unpacked/ is a tmpfs per process: the Mod
# Loader stops at a mod folder without a manifest, which another mod's check would leave behind.
run_game() {
  local log="$1" suites="$2" dir mounts=() args=()
  shift 2
  if [ "$packaged" = 1 ]; then
    local zips="$log.zips"
    mkdir -p "$zips"
    for dir in "$@"; do
      cp "$(zip_of "$dir")" "$zips/$(basename "$dir").zip" || return 1
    done
    mounts=(-v "$zips:/mods:ro$label" -v "$pack/steam.tres:/proj/$STEAM_PROFILE:ro$label")
    args=(--mods-path=/mods)
  else
    for dir in "$@"; do mounts+=(-v "${dir%/}:/proj/mods-unpacked/$(basename "$dir"):ro$label"); done
  fi
  "$RUNTIME" run --rm "${run_as[@]}" -e HOME=/tmp -e MOD_TEST_SUITES="$suites" \
    -v "$GAME:/proj${label:+:${label#,}}" --tmpfs "$empty_mods" "${mounts[@]}" \
    brotato-modtools timeout 240 godot3 --path /proj --no-window "${args[@]}" > "$log" 2>&1
}

# -p: a mod folder's zip, package.sh's for src/, one of zip_folders' for the others.
zip_of() {
  case "$1" in
    */src/*) src_zip "$pack" "$1" ;;
    *) echo "$pack/extra/$(basename "$1").zip" ;;
  esac
}

# report <log> <src mod_id...>
report() {
  local log="$1" errors own_errors runtime_errors engine_errors untranslated
  shift
  # The log without the known artifact and its "at: apply_settings" line: the boot splash that sets
  # the locale can also end after the tests started. The same error from elsewhere stays.
  errors=$(awk -v known="$KNOWN_ARTIFACTS" '
    held != "" { if ($0 ~ /at: apply_settings \(/) { held = ""; next } print held; held = "" }
    index($0, known) { held = $0; next }
    1
    END { if (held != "") print held }' "$log")
  own_errors=$(grep -A2 "SCRIPT ERROR" <<<"$errors" | grep -B1 "mods-unpacked" || true)
  runtime_errors=$(awk '/MOD-TESTS: START/{f=1} f' <<<"$errors" | grep -A1 "SCRIPT ERROR" \
    | grep -v -e "in base 'Nil'" -e "SteamPlatform" -e "^--" | grep -B1 "  at: " | sort -u || true)
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
  untranslated="$(translations_unloaded "$log" "$@")"
  if [ -n "$untranslated" ]; then echo "Translations not loaded:"; echo "$untranslated"; fi
  [ -z "$own_errors" ] && [ -z "$runtime_errors" ] && [ -z "$engine_errors" ] \
    && [ -z "$untranslated" ] && grep -q "MOD-TESTS: PASS" "$log"
}

pack=""
if [ "$packaged" = 1 ]; then
  pack="$(mktemp -d "${TMPDIR:-/tmp}/mod-check-zips.XXXXXX")"
  trap 'rm -rf "$pack"' EXIT
  echo "packaged: every mod from a zip (tools/package.sh's for src/, in $pack)"
  package_zips "$pack" && steam_profile "$pack/steam.tres" || exit 1
fi

if [ $# -gt 0 ]; then folders=("$@"); else folders=("$ROOT"/mods/*/); fi
overall=0
for folder in "${folders[@]}"; do
  folder="$(cd "$folder" && pwd)"
  [ -d "$folder/tests" ] || { echo "== ${folder#"$ROOT"/}: no tests, skipped"; continue; }
  echo "== ${folder#"$ROOT"/}"
  dirs=()  # the folder's mods: src/, tests/, dev/
  shards=()
  extras=()  # per shard: the other mod folders its process loads, "+"-separated
  only_extra=""
  for dir in "$folder"/src/*/ "$folder"/tests/*/ "$folder"/dev/*/; do
    [ -d "$dir" ] || continue  # no dev/ (an unmatched glob stays as it is)
    dirs+=("${dir%/}")
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

  if [ "$packaged" = 1 ]; then
    others=()
    for dir in "${dirs[@]}"; do
      case "$dir" in */src/*) ;; *) others+=("$dir") ;; esac
    done
    [ ${#others[@]} -eq 0 ] || zip_folders "$pack/extra" "${others[@]}" || exit 1
  fi

  started=$(date +%s)
  logs=()
  pids=()
  translated=()  # per shard: the mod_ids of its src/ mods, whose translations must load
  for i in "${!shards[@]}"; do
    log="$(mktemp "${TMPDIR:-/tmp}/mod-check.XXXXXX")"
    logs+=("$log")
    shard_dirs=("${dirs[@]}")
    for other in ${extras[$i]//+/ }; do
      for dir in "$ROOT/mods/$other"/src/*/; do shard_dirs+=("${dir%/}"); done
    done
    src_ids=""
    for dir in "${shard_dirs[@]}"; do
      case "$dir" in */src/*) src_ids+=" $(basename "$dir")" ;; esac
    done
    translated+=("$src_ids")
    run_game "$log" "${shards[$i]}" "${shard_dirs[@]}" &
    pids+=($!)
  done
  wait "${pids[@]}"

  failed=0
  checks=0
  for i in "${!shards[@]}"; do
    [ ${#shards[@]} -gt 1 ] && echo "-- ${shards[$i]}"
    checks=$((checks + $(grep -c "^  ok   " "${logs[$i]}")))
    # shellcheck disable=SC2086 # the mod_ids, one argument each
    if report "${logs[$i]}" ${translated[$i]}; then
      rm -rf "${logs[$i]}" "${logs[$i]}.zips"
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
