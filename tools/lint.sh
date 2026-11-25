#!/usr/bin/env bash
# gdlint (gdtoolkit 3.x) over all mod sources: src/, tests/ and dev/ (config: gdlintrc). Then the
# socket-class check of tools/zip_guard.py over mods/*/src only (shipped code talks through Steam
# only; dev/ mods such as the local-play emulator may open sockets and are never packaged), and the
# localization guard (tools/l10n_guard.py: shown texts go through translations.csv).
set -euo pipefail
"$(dirname "$0")/run.sh" gdlint mods/
"$(dirname "$0")/run.sh" python3 -I tools/zip_guard.py src
exec "$(dirname "$0")/run.sh" python3 -I tools/l10n_guard.py
