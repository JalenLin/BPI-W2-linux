#!/bin/bash
# Build one driver in drivers/<name>/ as an external module, against this
# repository's kernel tree (vendor/linux), inside the build container.
#
#   scripts/build-module.sh <name>        e.g. scripts/build-module.sh ir
#
# Needs a built kernel (make kernel-sources kernel): the module must match
# the kernel the board runs. KTREE=<path to a built kernel tree> builds
# against another one (it must be under this repository or be mounted).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KTREE="$(cd "${KTREE:-$HERE/vendor/linux}" && pwd)"
NAME="${1:?usage: $0 <driver directory under drivers/>}"
[ -d "$HERE/drivers/$NAME" ] || { echo "no drivers/$NAME" >&2; exit 1; }
[ -f "$KTREE/arch/arm64/boot/Image" ] ||
    { echo "build the kernel first: make kernel-sources kernel" >&2; exit 1; }

exec docker run --rm -i \
    -v "$KTREE:/ktree" -v "$HERE:/ext" \
    -e "BUILD_UID=$(id -u)" -e "BUILD_GID=$(id -g)" \
    "${BUILDER_IMAGE:-bpiw2-kernel/builder:trixie}" \
    make -C /ktree ARCH=arm64 \
        CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
        M="/ext/drivers/$NAME" modules
