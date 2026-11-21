#!/usr/bin/env bash
# Upload a GitHub Release of a mod to its Steam Workshop item with steamcmd, from the maintainer's
# PC (no Steam credentials anywhere else). Downloads the release's <Name>.zip, <Name>.zip.sha256 and
# changenote.txt, checks the hash, stages a content folder that holds only the zip (the Mod Loader
# loads every .zip / .pck in the item's folder) and runs steamcmd's workshop_build_item. The VDF
# leaves out title, description, preview and visibility: the item keeps what its page has.
# Usage: tools/release.sh [-y] [--dry-run] [--from-dir DIR] <mod> <tag> local|live
#   <mod>         folder in mods/ (brotato-together, brotato-trade)
#   <tag>         the release's tag, <mod>/<YYYY-MM-DD-HHMM>
#   local         no upload: the release's zip into this PC's copy of the subscribed item (as
#                 tools/deploy.sh does), to try exactly that file in the game first
#   live          upload to the item of mods/<mod>/workshop.json
#   -y            no confirmation prompt
#   --dry-run     everything but steamcmd
#   --from-dir    take the three files from DIR instead of the GitHub Release
# Environment: STEAM_USER (the Steam account that owns the item, logged in once by hand in steamcmd
#   so its login is cached), STEAMCMD (default: steamcmd on PATH, else
#   %LOCALAPPDATA%/steamcmd/steamcmd.exe), BROTATO_WORKSHOP_DIR (local: the Workshop content folder
#   of app 1942280, as for tools/deploy.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID=1942280
usage() { echo "usage: tools/release.sh [-y] [--dry-run] [--from-dir DIR] <mod> <tag> local|live" >&2; exit 2; }

yes=0 dry=0 from_dir=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y) yes=1 ;;
    --dry-run) dry=1 ;;
    --from-dir) [ $# -ge 2 ] || usage; from_dir="$2"; shift ;;
    -*) usage ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ ${#args[@]} -eq 3 ] || usage
mod="${args[0]}" tag="${args[1]}" target="${args[2]}"
case "$target" in local | live) ;; *) usage ;; esac
[[ "$tag" =~ ^${mod}/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || { echo "tag $tag is not $mod/<YYYY-MM-DD-HHMM>" >&2; exit 2; }
config="mods/$mod/workshop.json"
[ -f "$ROOT/$config" ] || { echo "no $config" >&2; exit 2; }

json_value() { sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",]*\)"\{0,1\}[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$ROOT/$config" | head -n 1; }
zip="$(json_value zip)"
item="$(json_value live)"
[ -n "$zip" ] || { echo "no \"zip\" in $config" >&2; exit 1; }
[[ "$item" =~ ^[0-9]+$ ]] || { echo "\"live\" in $config is not a Workshop id: $item" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/release" "$work/content"
files=("$zip" "$zip.sha256" changenote.txt)
if [ -n "$from_dir" ]; then
  for f in "${files[@]}"; do cp "$from_dir/$f" "$work/release/"; done
else
  GH="$(command -v gh || command -v gh.cmd || true)"
  [ -n "$GH" ] || { echo "gh (GitHub CLI) not found" >&2; exit 1; }
  url="$(git -C "$ROOT" remote get-url origin)"
  repo="$(printf '%s\n' "$url" | sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p')"
  repo="${repo%.git}"
  # Relative paths only: gh may be a wrapper into WSL that sees this folder under /mnt.
  pattern=()
  for f in "${files[@]}"; do pattern+=(--pattern "$f"); done
  (cd "$work/release" && "$GH" release download "$tag" --repo "$repo" "${pattern[@]}")
fi
for f in "${files[@]}"; do [ -f "$work/release/$f" ] || { echo "the release has no $f" >&2; exit 1; }; done
(cd "$work/release" && sha256sum -c --quiet "$zip.sha256") || { echo "SHA256 of $zip does not match $zip.sha256" >&2; exit 1; }
cp "$work/release/$zip" "$work/content/"

if [ "$target" = local ]; then
  # As tools/deploy.sh: every zip of the item folder goes (two with the same mod load it twice).
  workshop="${BROTATO_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/$APP_ID}"
  [ -d "$workshop/$item" ] || { echo "not subscribed / not downloaded: $workshop/$item (set BROTATO_WORKSHOP_DIR)" >&2; exit 1; }
  echo "Release $tag -> this PC's copy of item $item ($workshop/$item)"
  if [ "$dry" = 1 ]; then
    echo "dry run, would replace the zips in $workshop/$item with $zip"
    exit 0
  fi
  find "$workshop/$item" -maxdepth 1 -name "*.zip" -print -delete | sed "s/^/  removed /"
  cp "$work/release/$zip" "$workshop/$item/"
  echo "installed $zip locally: start the game and check it. Steam may put the uploaded version"
  echo "back when it updates or verifies the item; run this again after that."
  exit 0
fi

# Windows steamcmd.exe takes C:/... paths; elsewhere the path stays as it is.
native() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
vdf_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
note="$(tr -d '\r' < "$work/release/changenote.txt" | vdf_escape)"
vdf="$work/item.vdf"
{
  printf '"workshopitem"\n{\n'
  printf '\t"appid"\t\t"%s"\n' "$APP_ID"
  printf '\t"publishedfileid"\t\t"%s"\n' "$item"
  printf '\t"contentfolder"\t\t"%s"\n' "$(native "$work/content" | vdf_escape)"
  printf '\t"changenote"\t\t"%s"\n' "$note"
  printf '}\n'
} > "$vdf"

if [ -z "${STEAMCMD:-}" ]; then
  STEAMCMD=steamcmd
  if ! command -v steamcmd > /dev/null 2>&1 && [ -n "${LOCALAPPDATA:-}" ]; then
    STEAMCMD="$(native "$LOCALAPPDATA")/steamcmd/steamcmd.exe"
  fi
fi
echo "Release $tag -> $target item $item (https://steamcommunity.com/sharedfiles/filedetails/?id=$item)"
echo "content folder (uploaded as the item's files):"
(cd "$work/content" && ls -l)
echo "sha256: $(cut -d' ' -f1 "$work/release/$zip.sha256")"
echo "change note:"
sed 's/^/  | /' "$work/release/changenote.txt"
echo "VDF:"
sed 's/^/  | /' "$vdf"

if [ "$dry" = 1 ]; then
  echo "dry run, would run: $STEAMCMD +login \"\$STEAM_USER\" +workshop_build_item $(native "$vdf") +quit"
  exit 0
fi
[ -n "${STEAM_USER:-}" ] || { echo "set STEAM_USER to the Steam account that owns the item" >&2; exit 1; }
command -v "$STEAMCMD" > /dev/null 2>&1 || { echo "steamcmd not found: install it or set STEAMCMD" >&2; exit 1; }
if [ "$yes" != 1 ]; then
  read -r -p "Upload to the $target item $item as $STEAM_USER? [y/N] " answer
  case "$answer" in y | Y | yes) ;; *) echo "not uploaded"; exit 1 ;; esac
fi

log="$work/steamcmd.log"
set +e
"$STEAMCMD" +login "$STEAM_USER" +workshop_build_item "$(native "$vdf")" +quit 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
if grep -q "ERROR" "$log" || ! grep -q "^Success" "$log"; then
  echo "upload FAILED (steamcmd exit $status): see the output above" >&2
  exit 1
fi
echo "uploaded $tag to $target item $item"
