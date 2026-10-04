# BPI-W2 peripherals

Mainline Linux drivers for the Banana Pi BPI-W2 (Realtek RTD1296) blocks
that mainline still lacks: SATA, PCIe, the IR receiver and the second RJ45.
The kernel side of an independent OS for the board (the userland could be
OpenWrt or Ubuntu); the [PiKVM port](https://github.com/JalenLin/BananaPi_W2_PiKVM)
serves as the build and test base.

The second RJ45 works as a loadable module (`drivers/nat-eth/`); the
rest is not started. This is where that work happens. Start with
[AGENTS.md](AGENTS.md), then [docs/board-and-tooling.md](docs/board-and-tooling.md)
and the note for the feature:

- [SATA](docs/sata.md)
- [PCIe](docs/pcie.md)
- [IR receiver](docs/ir.md)
- [Second RJ45](docs/second-ethernet.md)

The drivers build as external modules against the PiKVM repository's
kernel tree (expected at `../bpiw2_pikvm`):

```sh
scripts/build-module.sh <name>
scripts/push-module.sh <name>
```
