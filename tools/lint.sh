#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over all mod and test sources (config: gdlintrc).
set -euo pipefail
exec "$(dirname "$0")/run.sh" gdlint mods/
