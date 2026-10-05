# The board, the PiKVM repository, and how to build and test

## The board

Banana Pi BPI-W2: Realtek RTD1296 (4x Cortex-A53, 1.4 GHz with the PiKVM
cpufreq driver), 2 GiB DDR4, 8 GB eMMC, microSD, HDMI in, HDMI out, mini
DisplayPort, two RJ45, SATA, PCIe, USB 3/2, a Type-C OTG port, IR receiver.

It runs the PiKVM image from `../bpiw2_pikvm` (Linux 6.18 LTS, Arch Linux
ARM, kvmd). That image is the base for all work here: boot it, then load the
modules built here on top.

- **Boot paths.** SW4 = 1: SPI flash + the SD card's u-boot. SW4 = 0: the
  eMMC's u-boot, which boots the SD card if one is in, else the eMMC. See
  `../bpiw2_pikvm/docs/11-install-and-use.md`.
- **Network.** `eth0` (the RJ45 next to the USB ports) with DHCP. The last
  address used is in `../bpiw2_pikvm/build/board_ip`. The image answers
  mDNS as `bpi-w2-pikvm.local`.
- **Login.** root, with the image's default password (see the PiKVM
  repository; it may have been changed). Pass it as `BOARD_PASS`, never in
  a committed file.
- **Serial console.** 115200 8N1 on the board's debug UART, `/dev/ttyUSB0`
  on the development host, reached through Docker:
  `../bpiw2_pikvm/scripts/serial-cmd.sh`. Needed when the network is down,
  and for u-boot.

## Access helpers (in ../bpiw2_pikvm/scripts)

| Script | Use |
|---|---|
| `board-ssh.sh "<cmd>"` | Run a command on the board (`BOARD_HOST=<ip>`) |
| `board-ssh.sh --put <local> <remote>` / `--get <remote> <local>` | Copy files |
| `push-kernel-mainline.sh [--modules] [--reboot]` | Install a freshly built kernel, dtb and modules on the running board |
| `serial-cmd.sh "<cmd>" [seconds]` | Talk to the serial console |

Reading registers: `/dev/mem` works for MMIO and the reserved-memory
regions (`STRICT_DEVMEM` only blocks RAM). A tiny read-only peek in Python
is enough (`mmap` the page, `struct.unpack_from(">I" or "<I", ...)`).
Registers of a block whose clock is gated read `0xdeadbeef`. **Do not write
registers by hand unless you know what is behind them** -- and never the
PMIC (see AGENTS.md).

## Never unbind or rebind the SD card driver

`rtd129x-sdmmc` (98010400.mmc, the PiKVM kernel's SD host) holds the "CR"
clock (`<&crt_clk 25>`) and pulses `RSTN_CR` in probe. The eMMC -- the
root filesystem -- sits in the same card-reader block but does not
reference either, so:

- unbind: devm drops the last reference to the CR clock and it is gated;
  the eMMC times out on every command from that moment;
- bind: the `RSTN_CR` pulse resets the clock generator the boot loader set
  up for the eMMC; its driver cannot recover it.

On 2026-10-05 this left the root filesystem unwritable (CMD24/25/17
timeouts, the eMMC down to 25 MHz 1-bit) and needed a hard reset (the
shutdown hung on I/O). The filesystem came back clean. To recover a stuck
SD card, pull and reinsert it, or reboot -- **with the card out**: with a
card in, the board boots from the card.

## Read this before writing any DMA driver: SB2

The RTD129x bus bridge, SB2, **holds CPU writes to DDR back until it is
told to sync**. A barrier alone does not get them out. Realtek's kernel
hides this inside arm64 `wmb()` (`CONFIG_RTK_RBUS_BARRIER`: every `wmb()`
writes SB2's sync register, `0x9801a020`). Mainline's `wmb()` does not.
So any driver ported from the BSP silently loses that flush.

What it costs: the eMMC DMAC fetched stale descriptors and corrupted
memory. `eth0`'s transmitter wedged under load, with nothing in the logs.
See `../bpiw2_pikvm/docs/09-mainline-bringup.md` §14 and §21.

Since `8ad0763` in the PiKVM repository (patch 0018), the kernel does
this for every driver, as Realtek's did: `wmb()` and every `writel()`
drain SB2 on RTD129x. A driver using plain `writel()` for its doorbell is
covered. `writel_relaxed()` is **not**: put a `wmb()` before a relaxed
doorbell. To A/B a suspected SB2 problem, switch it with
`/sys/kernel/debug/rtd_sb2_sync` (or `rtd_sb2_sync=off` at boot).

Before that commit, the advice was this: after writing descriptors, and buffers the device will read,
and before the doorbell, write the SB2 sync register. Get it through the
`realtek,sb2` syscon (`syscon_regmap_lookup_by_phandle(np, "realtek,sb2")`,
then `regmap_write(sb2, 0x20, 0)`). `emmc-rtd129x.c` and `r8169soc.c` in
the PiKVM repository do it this way. Test any DMA driver under concurrent
DMA load (network + eMMC + SD), not just alone: the eth0 stall needed all
three.

## Building a driver here

The drivers are part of the kernel build (docs/kernel-build.md): a driver's
source goes in `kernel/src/`, a patch in `kernel/patches/` hooks it into
its subsystem's Kconfig and Makefile, `kernel/configs/bpiw2.config`
enables it, and `make kernel` builds it with everything else.

```sh
make builder kernel-sources kernel     # once; then make kernel after a change
```

The modules end up in `vendor/linux` (`find vendor/linux -name '*.ko'`).
Their vermagic must match the running kernel: with the drivers enabled,
this kernel's `.config` is no longer the PiKVM kernel's, so its modules
are for this kernel installed on the board, not for the PiKVM image.
Copying modules or a kernel to the board is the debug tools' job
(`BPI-W2-linux-tools`, at `../bpiw2_debug`).

### Device tree

A new driver's node is first tried as a runtime overlay (no new DTB on the
board), then goes into a board DTS; docs/device-tree.md has both, the
binding and its validation, worked through for the second RJ45.

The mainline headers for this SoC: `dt-bindings/reset/realtek,rtd1295.h`
(`RTD1295_RSTN_*`), the clocks are `<&crt_clk N>` (bit N of CLK_EN1, N-32 of
CLK_EN2) and `<&iso_clk N>`, interrupts go through `&misc_irq_mux` /
`&iso_irq_mux` or straight to the GIC. Syscons: `&crt`, `&iso`, `&misc`,
`&sb2`, `&scpu_wrapper`.

### Graduating a driver

The PiKVM image keeps its own kernel and board DTS at what PiKVM needs;
the drivers here are part of this kernel, not of that image. To test them,
the board runs this kernel under the PiKVM rootfs (docs/kernel-build.md).

### Testing on the board

In the debug tools (`BPI-W2-linux-tools`, private, at `../bpiw2_debug`): docs/testing.md has the
setup (tools under `/root` via `scripts/board-tools.sh`, the far ends, the
LAN), the tests with their scripts and pass criteria, the traps met, the
safety rules.

## Where the reference material is

Everything below is under `../bpiw2_pikvm/vendor/` (fetched by that
repository's `scripts/prepare-sources.sh`; not committed anywhere).

| Path | What |
|---|---|
| `bpi-w2-bsp/linux-rtk/` | BPI's BSP kernel 4.9: the Realtek drivers to read |
| `bpi-w2-bsp/linux-rtk/arch/arm64/boot/dts/realtek/rtd129x/` | The BSP device trees; `.rtd-1296-bananapi-w2-2GB.dtb.dts.tmp` is the preprocessed W2 tree, all includes resolved |
| `bpi-w2-bsp/u-boot-rtk/` | BPI's u-boot, sometimes the simplest version of an init sequence |
| `bpi-1296-android7/` | BPI's Android 7 tree, a **sparse, blob-less** clone. `find` sees almost nothing: ask git (`git ls-tree -r HEAD --name-only`), then `git sparse-checkout add <path>` |
| `linux-mainline/` | The 6.18 tree the PiKVM kernel is built from |

The schematic (`../bpiw2_pikvm/docs/refs/bpi-w2-v1_1-pub.pdf`, not
distributed): sheet titles by PDF page are 1 RTD1296, 3 MSDC, 4 power,
5 PMU G2227, 6 HDMI, 7 DP, 8 PCIe, 9 USB, 10 SATA/USB hub, 11 GbE,
12 HWNAT_0, 13 GPIO (40-pin header, IR, LEDs, buttons), 14 analog, 15 M.2.
`pdftotext -layout` in a Docker container makes it searchable.

The PiKVM repository's own docs record how every other block was brought up
and what went wrong; `docs/09-mainline-bringup.md` is the long version,
`docs/10-mainline-summary.md` the summary.
