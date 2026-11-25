#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over all mod and test sources (config: gdlintrc), then the localization
# guard (tools/l10n_guard.py: shown texts go through translations.csv) and the socket-class check
# of tools/zip_guard.py over mods/*/src (shipped code talks through Steam only).
set -euo pipefail
"$(dirname "$0")/run.sh" gdlint mods/
"$(dirname "$0")/run.sh" python3 -I tools/zip_guard.py src
exec "$(dirname "$0")/run.sh" python3 -I tools/l10n_guard.py
