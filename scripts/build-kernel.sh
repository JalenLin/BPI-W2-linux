#!/bin/bash
# Build the kernel (Image, the board DTB, modules) in vendor/linux, inside
# the build container. Needs scripts/fetch-kernel.sh first.
#
#   scripts/build-kernel.sh                   Image dtbs modules
#   TARGETS=dtbs scripts/build-kernel.sh      just the DTBs
#   CHECK_DTBS=1 ...                          also dt-validate the DTBs
#   EXTRA_CONFIG=kernel/configs/x.config ...  a second fragment on top
#
# New files (the board DTS, drivers kept as whole files in kernel/src/)
# are copied into the tree here; changes to existing upstream files are
# the patches in kernel/patches/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HERE/vendor/linux/Makefile" ] || { echo "run scripts/fetch-kernel.sh first" >&2; exit 1; }
TARGETS="${TARGETS:-Image dtbs modules}"
EXTRA_CONFIG="${EXTRA_CONFIG:-}"
# the kernel tests ifneq($(CHECK_DTBS),): it must be unset, not 0
MAKE_ARGS=""
[ "${CHECK_DTBS:-0}" != "0" ] && MAKE_ARGS="CHECK_DTBS=1"

exec "$HERE/scripts/in-docker.sh" bash -c '
set -euo pipefail
cd /work/vendor/linux
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=bpiw2 KBUILD_BUILD_HOST=builder
# LOCALVERSION set (even empty) keeps setlocalversion from appending
# "-dirty"; the version suffix is CONFIG_LOCALVERSION in the fragment
export LOCALVERSION=""

S=/work/kernel/src
cp /work/dts/board/rtd1296-bananapi-w2.dts arch/arm64/boot/dts/realtek/
cp $S/irq-rtd129x.c drivers/irqchip/
cp $S/sdmmc-rtd129x.c $S/emmc-rtd129x.c drivers/mmc/host/
cp $S/r8169soc.c drivers/net/ethernet/realtek/
cp $S/clk-rtd129x-crt.c $S/clk-rtd129x-scpu.c drivers/clk/
cp $S/g2227-regulator.c drivers/regulator/
cp $S/rtd129x-thermal.c drivers/thermal/
cp $S/rtd129x-sb2-sync.c arch/arm64/kernel/
# directories: sources in step (stale ones removed), build products kept --
# an rm -rf here once dropped hdmirx.ko after a dtbs-only build
SYNC="rsync -r --checksum --delete --exclude=*.o --exclude=*.ko --exclude=.*.cmd --exclude=*.mod --exclude=*.mod.c --exclude=modules.order"
$SYNC $S/hdmirx/ drivers/media/platform/realtek-rtd129x-hdmirx/
$SYNC $S/acpu/ sound/realtek-rtd129x-acpu/
cp "$S/realtek,rtd1295-irq-mux.yaml" Documentation/devicetree/bindings/interrupt-controller/
cp $S/rtd1295-hwnat.c drivers/net/ethernet/realtek/
cp $S/phy-rtd1295-sata.c drivers/phy/realtek/
cp $S/rtd1295-ir.c drivers/media/rc/
# bindings, by subsystem directory (net/, phy/, media/)
cp -r /work/dts/bindings/. Documentation/devicetree/bindings/

# arm64 defconfig, then only what this board needs on top
FRAGMENTS="/work/kernel/configs/bpiw2.config"
EXTRA='"$EXTRA_CONFIG"'
[ -n "$EXTRA" ] && FRAGMENTS="$FRAGMENTS /work/$EXTRA"
STAMP=.bpiw2-fragments
regen=0
[ -f .config ] || regen=1
[ "$(cat $STAMP 2>/dev/null)" = "$FRAGMENTS" ] || regen=1
for f in $FRAGMENTS; do [ "$f" -nt .config ] && regen=1; done
if [ "$regen" = 1 ]; then
    make defconfig
    ./scripts/kconfig/merge_config.sh -m -O . .config $FRAGMENTS
    make olddefconfig
    echo "$FRAGMENTS" > $STAMP
fi

make -j"$(nproc)" '"$MAKE_ARGS"' '"$TARGETS"'
echo
echo "--- built ---"
ls -l arch/arm64/boot/Image arch/arm64/boot/dts/realtek/rtd1296-bananapi-w2.dtb 2>/dev/null || true
'
