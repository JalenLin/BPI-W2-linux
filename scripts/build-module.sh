#!/bin/bash
# Build one driver in drivers/<name>/ as an external module, against the
# kernel tree of the PiKVM repository, inside its build container.
#
#   scripts/build-module.sh <name>        e.g. scripts/build-module.sh ir
#
# Needs ../bpiw2_pikvm with a built kernel ("make kernel-mainline" there) --
# the module must match that kernel exactly. PIKVM=<path> overrides the
# location of that repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIKVM="$(cd "${PIKVM:-$HERE/../bpiw2_pikvm}" && pwd)"
NAME="${1:?usage: $0 <driver directory under drivers/>}"
[ -d "$HERE/drivers/$NAME" ] || { echo "no drivers/$NAME" >&2; exit 1; }
[ -f "$PIKVM/vendor/linux-mainline/arch/arm64/boot/Image" ] ||
    { echo "build the kernel first: (cd $PIKVM && make kernel-mainline)" >&2; exit 1; }

exec docker run --rm -i \
    -v "$PIKVM:/work" -v "$HERE:/ext" \
    -e "BUILD_UID=$(id -u)" -e "BUILD_GID=$(id -g)" \
    bpiw2-pikvm/builder-mainline:trixie \
    make -C /work/vendor/linux-mainline ARCH=arm64 \
        CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
        M="/ext/drivers/$NAME" modules
