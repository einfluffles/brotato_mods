# shellcheck shell=bash disable=SC2034  # run_as, label, empty_mods: for the scripts that source this
# Sourced by tools/check.sh and tools/check-pair.sh (needs ROOT): the container runtime and the
# decompiled game the headless runs boot.
#
# Sets RUNTIME (podman, else docker; CONTAINER picks one), run_as, label, empty_mods (the runtime's
# options for the user, shared mounts and an empty tmpfs) and GAME, the folder mounted as /proj:
# reference/ itself, or a copy of it in ~/.cache/brotato-modtools when the repo is on a slow mount.
# The game reads ~17000 files while booting. Over a network-style mount (a Windows drive under WSL
# is 9p) that takes close to a minute instead of a few seconds. The copy is refreshed when
# reference/project.godot changes.
# Environment:
#   MOD_CHECK_CACHE   1: always run from the copy, 0: never (default: only on a slow mount)
#   MOD_CHECK_RESYNC  1: refresh the copy even if reference/ looks unchanged

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
    mkdir -p "$GAME" && rm -f "$GAME/.source-stamp"  # a copy cut short must not look complete
    if command -v rsync > /dev/null 2>&1; then
      rsync -a --delete --exclude /mods-unpacked/ --exclude /.source-stamp "$ROOT/reference/" "$GAME/" || exit 1
    else
      rm -rf "$GAME" && mkdir -p "$GAME" && cp -a "$ROOT/reference/." "$GAME/" || exit 1
      rm -rf "$GAME/mods-unpacked"
    fi
    echo "$stamp" > "$GAME/.source-stamp"
  fi
fi
mkdir -p "$GAME/mods-unpacked"  # the mount point of each process's own tmpfs

# --- Packaged mode: the mods as players get them, zips instead of folders in mods-unpacked/ ---
# The Mod Loader loads every zip in the folder that --mods-path names. A game that has loaded a
# zip no longer lists res://mods-unpacked/, so zips and folders cannot be mixed in one game: in
# this mode every mod of a game is a zip, the dev and test mods too.

#
# The Steam build (project.godot's feature "steam", as tools/check.sh runs the game) has the Mod
# Loader take zips from the Steam Workshop's subscriptions, which need Steam; the local build
# (tools/check-pair.sh) takes them from --mods-path. STEAM_PROFILE: the Mod Loader's options for
# the feature "steam"; steam_profile writes a copy without the Workshop, to mount over it.
STEAM_PROFILE=addons/mod_loader/options/profiles/steam.tres

# steam_profile <file>: the Mod Loader's steam profile with steam_workshop_enabled = false.
steam_profile() {
  local line="steam_workshop_enabled = true"
  grep -q -x -F "$line" "$GAME/$STEAM_PROFILE" \
    || { echo "$STEAM_PROFILE has no line '$line': the Mod Loader changed" >&2; return 1; }
  sed "s/^$line\$/steam_workshop_enabled = false/" "$GAME/$STEAM_PROFILE" > "$1"
}

# package_zips <dir>: tools/package.sh's zips of every mod (what tools/release.sh uploads) in
# <dir>/dist/<name>/<name>.zip.
package_zips() {
  CONTAINER="$RUNTIME" "$ROOT/tools/package.sh" "$1/dist" > "$1/package.log" 2>&1 \
    || { cat "$1/package.log" >&2; echo "tools/package.sh failed" >&2; return 1; }
}

# zip_folders <out dir> <mod folder>...: a zip per folder (<out dir>/<mod_id>.zip), laid out as
# package.sh lays out a mod's zip (mods-unpacked/<mod_id>/...). For the mods package.sh never
# packages (tests/, dev/) and for another build's src/ (tools/check-pair.sh's refs).
zip_folders() {
  local out="$1" dir id mounts=() ids=()
  shift
  mkdir -p "$out"
  for dir in "$@"; do
    id="$(basename "$dir")"
    mounts+=(-v "${dir%/}:/in/$id:ro$label")
    ids+=("$id")
  done
  # shellcheck disable=SC2016 # expands in the container
  "$RUNTIME" run --rm "${run_as[@]}" -e HOME=/tmp "${mounts[@]}" -v "$out:/out$label" \
    brotato-modtools bash -euc '
      for id in "$@"; do
        stage=$(mktemp -d)
        mkdir -p "$stage/mods-unpacked"
        cp -r "/in/$id" "$stage/mods-unpacked/$id"
        rm -f "/out/$id.zip"
        (cd "$stage" && zip -qr "/out/$id.zip" mods-unpacked -x "*/.*" "*.import")
      done
    ' _ "${ids[@]}"
}

# src_zip <dir> <src mod folder>: the path of package.sh's zip of that mod in <dir>/dist (the
# manifest's "name" names it, as in package.sh).
src_zip() {
  local name
  name="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${2%/}/manifest.json" | head -n 1)"
  if [ -z "$name" ] || [ ! -f "$1/dist/$name/$name.zip" ]; then
    echo "no zip of ${2%/} in $1/dist" >&2
    return 1
  fi
  echo "$1/dist/$name/$name.zip"
}

# translations_unloaded <log> <mod_id>...: prints a line for each of the mods (those with a
# translations.csv: every mod of this repo) whose mod_main.gd did not log "Init (<n> translated
# texts)" with n > 0, and the loader's warnings about the mods' own files. Nothing when all loaded.
translations_unloaded() {
  local log="$1" id
  shift
  for id in "$@"; do
    grep -q -E "$id:Main: Init \([1-9][0-9]* translated texts\)" "$log" \
      || echo "$id: no translated texts ($(grep -o -m1 "$id:Main: Init ([0-9]* translated texts)" "$log" || echo 'no Init line'))"
  done
  grep "L10n: .*res://mods-unpacked/" "$log" || true
}
