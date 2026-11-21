#!/usr/bin/env bash
# Run a command inside the toolchain container with the repo mounted at /work.
# CONTAINER picks the runtime (default: podman, else docker).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${CONTAINER:-$(command -v podman > /dev/null 2>&1 && echo podman || echo docker)}"
if [ "$(basename "$RUNTIME")" = podman ]; then
  exec "$RUNTIME" run --rm --userns=keep-id -e HOME=/tmp -v "$ROOT:/work:Z" -w /work brotato-modtools "$@"
fi
exec "$RUNTIME" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/work" -w /work brotato-modtools "$@"
