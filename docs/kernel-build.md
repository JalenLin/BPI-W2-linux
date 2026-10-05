# Building the kernel here

Since 2026-10-05 this repository builds the BPI-W2 kernel on its own: the
build container, the upstream tree, the patch series, the board DTS and the
config fragment are all here. Before, the kernel tree and the container
came from the PiKVM repository (`../bpiw2_pikvm`); its kernel files were
imported from there at commit `3398bdd` (branch `kernel-6.18`).

```sh
make builder          # the container image bpiw2-kernel/builder:trixie, once
                      # (DEBIAN_MIRROR=http://free.nchc.org.tw/debian if the CDN is slow)
make kernel-sources   # vendor/linux: v6.18.55 from kernel.org + kernel/patches
make kernel           # Image, the board DTB, modules (in vendor/linux)
make dtbs             # just the DTBs; CHECK_DTBS=1 scripts/build-kernel.sh validates
```

| Path | What |
|---|---|
| `docker/builder.Dockerfile`, `docker/entrypoint.sh` | Debian trixie, the distro's aarch64 GCC, dtc, dtschema; runs as the caller's uid |
| `scripts/fetch-kernel.sh` | `git clone --depth 1` of the stable tree at the pinned tag (`LINUX_URL` overrides the source), then `git apply` of every patch; an existing checkout is restored to the tag and re-patched |
| `kernel/patches/` | 18 patches against upstream files (Makefiles, Kconfig, bindings, the DTS Makefile, the SB2 barrier hook...) |
| `kernel/src/` | Whole new files copied into the tree at build time: irq mux, SD and eMMC hosts, r8169soc, CRT/SCPU clocks, G2227 PMIC, thermal, SB2 sync, HDMI RX, audio CPU, the irq-mux binding |
| `kernel/configs/bpiw2.config` | Fragment merged onto `arm64 defconfig` (`CONFIG_LOCALVERSION="-bpiw2"`) |
| `dts/board/rtd1296-bananapi-w2.dts` | The board DTS, with the second RJ45, SATA and IR nodes (dts/board/README.md) |
| `scripts/build-kernel.sh` | Copies the board DTS and `kernel/src/` in, merges the fragment (only when it changed), builds |
| `vendor/linux` | The tree (gitignored) |

The second RJ45, SATA PHY and IR drivers are in the tree too: their
sources in `kernel/src/`, hooked in by patches 0019-0021, the AHCI
binding extended by 0022, their bindings copied in from `dts/bindings/`,
enabled in the fragment (`RTD1295_HWNAT=m`, `PHY_RTD1295_SATA=y`,
`IR_RTD1295=m`, and rc-core's LIRC and NEC/RC-5/RC-6/Sony decoders).

## Verified (2026-10-05)

First build here, with the PiKVM repository's container image (same
Dockerfile; this repository's own image was still downloading):

- `fetch-kernel.sh`: v6.18.55 cloned, all 18 patches applied cleanly.
- `build-kernel.sh`: 3 min 42 s on 32 cores. **The board DTB is
  byte-identical** to the one built in the PiKVM tree and installed on the
  board (md5 `f9a5e9b3677130618dd96e4210f667ac`); **`.config` is
  identical**; kernel release `6.18.55-bpiw2`; `Image` the same size
  (43612672 bytes). The PiKVM tree has 18 more `.ko` files: leftovers of
  older configs (dw_mmc, USB gadget functions, now built in) -- same
  config, same output.
- The three out-of-tree drivers and the development rc-core build against
  `vendor/linux` with vermagic `6.18.55-bpiw2 SMP preempt mod_unload
  aarch64`, and load on the board's running kernel (eth1 up and pinging,
  `rc0` registered, SATA probing with links down and unloading cleanly).
- Then with this repository's own image (`make builder`): the default
  Debian CDN gave the container ~90 KB/s from here (2.4 MB/s from the host
  itself), so the image was built through the NCHC mirror
  (`DEBIAN_MIRROR`, 4 min 18 s). Same tools as the PiKVM image (GCC
  14.2.0-19, DTC 1.7.2, dtschema 2026.9). `make clean` and a full build:
  3 min 40 s, Image 43612672 bytes, DTB md5 `f9a5e9b3...` again, 1416
  modules; the three drivers rebuild clean.

## The drivers in-tree (2026-10-05)

The three drivers moved from out-of-tree modules into the build (patches
0019-0022, config above). The 22 patches apply cleanly on v6.18.55; a full
build with `CHECK_DTBS=1` passes, the board DTB validates against the
bindings with no message about its SATA, IR or NAT nodes (patch 0022 lets
`realtek,rtd1295-ahci` have a reset per port), and is still byte-identical
(`f9a5e9b3...`). `.config` now differs from the PiKVM kernel's by these
options, so this kernel's modules are no longer for the PiKVM kernel the
board runs: testing the in-tree drivers needs this kernel on the board.
