#!/bin/bash
# Fetch the upstream kernel into vendor/linux and apply kernel/patches/.
# An existing checkout is kept, restored to the pinned tag and re-patched
# (tracked files only: the build in it survives). LINUX_URL overrides the
# source, e.g. a local mirror.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX_URL="${LINUX_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
LINUX_REF="v6.18.55"
DIR="$HERE/vendor/linux"

if [ ! -d "$DIR/.git" ]; then
    mkdir -p "$HERE/vendor"
    echo ">>> clone $LINUX_URL @ $LINUX_REF"
    git clone --depth 1 --branch "$LINUX_REF" "$LINUX_URL" "$DIR"
else
    echo ">>> restoring vendor/linux to $LINUX_REF, unmodified"
    git -C "$DIR" checkout -q -- .
    if [ "$(git -C "$DIR" rev-parse --verify --quiet "$LINUX_REF^{commit}" || true)" \
         != "$(git -C "$DIR" rev-parse HEAD)" ]; then
        git -C "$DIR" fetch --depth 1 origin "tag" "$LINUX_REF"
        git -C "$DIR" checkout -q "$LINUX_REF"
    fi
fi
echo ">>> applying kernel/patches"
for p in "$HERE"/kernel/patches/*.patch; do
    echo "    $(basename "$p")"
    git -C "$DIR" apply "$p"
done
