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
