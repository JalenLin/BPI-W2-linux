# BPI-W2-linux

Mainline Linux for the Banana Pi BPI-W2 (Realtek RTD1296): the patch series
on top of the upstream kernel, the board device tree, the drivers mainline
still lacks, and the toolchain that builds it all. The kernel side of an
independent OS for the board (the userland could be OpenWrt or Ubuntu); the
[PiKVM port](https://github.com/JalenLin/BananaPi_W2_PiKVM) is where it
came from and still the image the board is tested with.

```sh
make builder          # build container (DEBIAN_MIRROR=... if the Debian CDN is slow)
make kernel-sources   # v6.18.55 + kernel/patches into vendor/linux
make kernel           # Image, the board DTB, modules (the drivers below included)
```

[docs/kernel-build.md](docs/kernel-build.md) has the details. Start with
[AGENTS.md](AGENTS.md), then the note for each block:

| Block | State | Note |
|---|---|---|
| Second RJ45 (NAT engine port 5) | works, in the board DTB, 4-hour soak passed | [docs/second-ethernet.md](docs/second-ethernet.md) |
| SATA (AHCI + PHY) | works on both ports, in the board DTB | [docs/sata.md](docs/sata.md) |
| IR receiver | works (raw mode, rc-core), in the board DTB | [docs/ir.md](docs/ir.md) |
| PCIe | on hold: no card; a 4 KiB outbound window question | [docs/pcie.md](docs/pcie.md) |

How a driver gets its device-tree node: [docs/device-tree.md](docs/device-tree.md).
The board, its access and the rules for it: [docs/board-and-tooling.md](docs/board-and-tooling.md).

**Test and debug tooling is not in this repository.** The board tests
(`board/...`), the development overlays (`overlays/<name>/`), the rc-dev
build (`rc-dev/`), the host scripts for them (`scripts/board-tools.sh`,
`push-module.sh`, `build-overlay.sh`, `build-rc-dev.sh`, `install-dtb.sh`)
and the test notes (`docs/testing.md`) live in a separate repository,
`JalenLin/BPI-W2-linux-tools` (private; checked out next to this one as
`../bpiw2_debug`). The notes here name them by those paths.
