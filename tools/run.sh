#!/usr/bin/env bash
# Run a command inside the toolchain container with the repo mounted at /work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec podman run --rm --userns=keep-id -e HOME=/tmp -v "$ROOT:/work:Z" -w /work brotato-modtools "$@"
