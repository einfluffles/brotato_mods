#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over the mod sources.
set -euo pipefail
exec "$(dirname "$0")/run.sh" gdlint mods-unpacked/
