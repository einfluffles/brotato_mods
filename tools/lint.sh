#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over all mod and test sources (config: gdlintrc), then the localization
# guard (tools/l10n_guard.py: shown texts go through translations.csv).
set -euo pipefail
"$(dirname "$0")/run.sh" gdlint mods/
exec "$(dirname "$0")/run.sh" python3 -I tools/l10n_guard.py
