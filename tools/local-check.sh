#!/usr/bin/env bash
# Run gdlint, the headless tests and (for brotato:together) the pair tests on a clean, pushed HEAD,
# then mark that commit on GitHub with the commit status "local-check" = success. The release
# workflow refuses a tag without it: the tests need the decompiled game (reference/), so they
# cannot run in CI.
# Refuses a dirty tree (untracked files too) and a HEAD that is on no remote branch.
# Runs from WSL / Linux, or from Git Bash on Windows: there, without podman or docker, lint and
# tests run in WSL (wsl.exe), and git and gh in Git Bash (gh or gh.cmd).
# Usage: tools/local-check.sh [-n] [mods/<folder> ...]   (default: every mod with tests/)
#   -n  run everything but post the status (prints it instead)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The pair tests (tools/check-pair.sh: brotato:together's local-play scenarios, a host and a client
# as two headless games) are informative until they have run stable for a few releases: a failure
# is reported, not blocking. 1 makes a failure stop the release check.
PAIR_BLOCKING=0
cd "$ROOT"

dry=0
if [ "${1:-}" = -n ]; then dry=1; shift; fi

mods=()
if [ $# -eq 0 ]; then
  for d in mods/*/tests; do mods+=("${d%/tests}"); done
else
  for m in "$@"; do
    m="${m%/}"
    [ -d "$m/tests" ] || { echo "no tests in $m (expected mods/<folder>)" >&2; exit 2; }
    mods+=("$m")
  done
fi

GH="$(command -v gh || command -v gh.cmd || true)"
[ -n "$GH" ] || { echo "gh (GitHub CLI) not found" >&2; exit 1; }
url="$(git remote get-url origin)"
repo="$(printf '%s\n' "$url" | sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p')"
repo="${repo%.git}"
[ -n "$repo" ] || { echo "origin is not a GitHub repo: $url" >&2; exit 1; }

clean_head() {
  [ -z "$(git status --porcelain)" ] || { echo "the work tree is not clean: commit, stash or remove the changes" >&2; git status --short >&2; exit 1; }
  git rev-parse HEAD
}
sha="$(clean_head)"
git fetch -q origin
[ -n "$(git branch -r --contains "$sha")" ] || { echo "HEAD $sha is on no remote branch: push it first" >&2; exit 1; }

# In Git Bash without a container runtime: run in WSL, from the same folder.
in_env() {
  if [ -n "${CONTAINER:-}" ] || command -v podman > /dev/null 2>&1 || command -v docker > /dev/null 2>&1 \
    || ! command -v wsl.exe > /dev/null 2>&1; then
    "$@"
  else
    # shellcheck disable=SC2016 # expands in WSL
    MSYS_NO_PATHCONV=1 wsl.exe -e bash -c 'cd "$(wslpath -u "$1")" && shift && exec "$@"' _ "$(cygpath -m "$ROOT")" "$@"
  fi
}

echo "local-check of $sha: ${mods[*]}"
in_env tools/lint.sh
in_env tools/check.sh -q "${mods[@]}"
pair=""
if [[ " ${mods[*]} " == *" mods/brotato-together "* ]]; then
  if in_env tools/check-pair.sh -q; then
    pair=" (pair tests passed)"
  elif [ "$PAIR_BLOCKING" = 1 ]; then
    echo "the pair tests failed" >&2
    exit 1
  else
    pair=" (pair tests FAILED, not blocking yet)"
    echo "the pair tests failed: informative for now, the check goes on" >&2
  fi
fi

[ "$(clean_head)" = "$sha" ] || { echo "HEAD moved while the checks ran: run again" >&2; exit 1; }
description="gdlint + check.sh passed: ${mods[*]}$pair"
body="$(printf '{"state":"success","context":"local-check","description":"%s"}' "$description")"
if [ "$dry" = 1 ]; then
  echo "dry run, would post to repos/$repo/statuses/$sha: $body"
  exit 0
fi
printf '%s' "$body" | "$GH" api --method POST "repos/$repo/statuses/$sha" --input - > /dev/null
echo "posted local-check = success on $repo@$sha ($description)"
