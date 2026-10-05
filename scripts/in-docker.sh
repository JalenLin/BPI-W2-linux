#!/bin/bash
# Run a command in the kernel build container, this repository at /work,
# as the caller's uid/gid.   scripts/in-docker.sh <command...>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm -i -v "$HERE:/work" -w /work \
    -e "BUILD_UID=$(id -u)" -e "BUILD_GID=$(id -g)" \
    "${BUILDER_IMAGE:-bpiw2-kernel/builder:trixie}" "$@"
