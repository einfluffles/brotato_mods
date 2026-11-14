#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over the mod and test sources (config: gdlintrc).
set -euo pipefail
exec "$(dirname "$0")/run.sh" gdlint mods-unpacked/ tests/
