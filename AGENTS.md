# AGENTS.md

Instructions for AI coding agents (and people) working in this repository.

## What this is

Mainline Linux drivers for the Banana Pi BPI-W2 (Realtek RTD1296) peripherals
that the PiKVM port does not need and therefore left out:

| Feature | Hardware | Notes |
|---|---|---|
| SATA | AHCI at `0x9803f000`, PHY at `0x9803ff60` | [docs/sata.md](docs/sata.md) |
| PCIe | two x1 root ports, `0x9804e000` and `0x9803b000` | [docs/pcie.md](docs/pcie.md) |
| IR receiver | `0x98007400` (ISO block) | [docs/ir.md](docs/ir.md) |
| Second RJ45 | the hardware NAT engine's port 5 (`0x98060000`) + RTL8211F | [docs/second-ethernet.md](docs/second-ethernet.md) |

None of these has a mainline driver. Each has a Realtek BSP 4.9 driver to read
(not to copy wholesale). The goal is clean drivers in mainline style that could
one day go upstream.

**Scope (2026-10-05): this is mainline kernel work for the RTD1296, independent
of PiKVM.** Treat it as the kernel of an independent OS; the userland may end
up OpenWrt or Ubuntu. So solve things in the kernel and the device tree
(drivers, DT properties, nvmem, data the boot loader provides), never with
files for a particular userland: no PiKVM overlay files, udev rules, systemd
`.link`/`.network` files or distro scripts as part of a feature. A driver
going into the PiKVM image is optional, not the goal.

The PiKVM port lives in a sibling repository, `../bpiw2_pikvm`
(GitHub `JalenLin/BananaPi_W2_PiKVM`, branch `kernel-6.18`). It is this
repository's **build and test base**, not its target: the kernel tree, the
board device tree, the toolchain container, the image the board runs and the
board access scripts come from there. Read
[docs/board-and-tooling.md](docs/board-and-tooling.md) before building.

## Working rules (non-negotiable)

- **Talk to the user in Traditional Chinese.** Write code, comments, commit
  messages and documentation in English.
- **No credentials anywhere**: no SSH keys, `authorized_keys`, host keys,
  TLS keys or any private key, in this repo or in an image. The board's SSH
  password comes from the environment (`BOARD_PASS`, default in
  `../bpiw2_pikvm/scripts/board-ssh.sh`), never from a committed file.
- **BPI's schematic PDF is not ours to distribute.** It is at
  `../bpiw2_pikvm/docs/refs/bpi-w2-v1_1-pub.pdf` locally (see that
  directory's README for where to get it). Quote net names and page
  numbers, never the file.
- **Ask before anything destructive on the board**: writing a disk or
  partition, the eMMC, the boot loader areas, the SPI flash, or anything
  that could leave it unbootable.
- **Never drive the G2227 PMIC by hand** (I2C0 address 0x12, through
  `/dev/mem` or `i2cset`). A hand-made sequence once cut the board's power.
  Use the kernel regulator driver. Before writing a new PMIC register, tell
  the user so they can stand by to power-cycle.
- **Never `pkill -f`** over SSH on the board: the pattern matches the SSH
  session's own command line. Use `pgrep -x` / `pkill -x`.
- **Shared hardware with PiKVM**: the audio CPU firmware, the interrupt
  muxes, CRT clocks and resets are already in use. A driver for a new block
  must not reset or re-clock something PiKVM depends on. The second RJ45
  in particular must not take the embedded PHY away from `eth0` (see its
  notes).
- **Sync SB2 before handing memory to a DMA master** (see docs/board-and-tooling.md): the BSP did it inside `wmb()`, mainline does not.
- **Keep the system clean**: dependencies go into Docker containers, not
  onto the host.
- **Verify on the board before claiming anything works**, and say exactly
  what was verified and what was not. If a step was skipped, say so.

## Git

- Commit author e-mail: `jalen.lin@gmail.com`.
- Commit when a piece works or when a finding is worth keeping. Commit
  messages: a short subject, then what and why.
- This repository has no remote yet. Do not create one or push anywhere
  without the user's say-so.
- In `../bpiw2_pikvm`, keep `main` and `kernel-6.18` separate (never merge),
  and touch it only when the user wants a driver here in that image (see
  "Graduating a driver" in docs/board-and-tooling.md).

## Layout

| Path | What |
|---|---|
| `drivers/<feature>/` | One directory per driver, built as an external module against the PiKVM kernel tree |
| `dts/` | Device-tree fragments for the board; `dts/bindings/` their DT bindings (docs/device-tree.md) |
| `scripts/` | Build and deploy helpers |
| `scripts/board/` | Tests and tools that run on the board; `scripts/board-tools.sh` puts them there (docs/testing.md) |
| `docs/` | Per-feature notes: what the hardware is, where the BSP code is, what is known, what has been tried |

## How to work on a feature

1. Read its `docs/<feature>.md`. Add what you find there as you go,
   including dead ends: they cost time to rediscover.
2. Read the BSP driver it names, and the DT node data quoted there.
3. Write the driver in `drivers/<feature>/` (mainline APIs: `devm_*`,
   regmap or plain MMIO, `reset_control`, `clk`, existing subsystems such
   as libahci_platform, rc-core, the PCI host bridge helpers or phylink).
4. Add its DT node to `dts/`. Test it as a runtime overlay (as
   `drivers/nat-eth/` does; docs/board-and-tooling.md), or in the board
   DTS in `../bpiw2_pikvm` on a local, uncommitted change (or a work
   branch) -- installing a new DTB means asking first.
5. Build, push and test on the board (docs/board-and-tooling.md,
   docs/testing.md).
6. Each feature needs real hardware to test: a SATA disk, a PCIe card, an
   IR remote, a cable in the second RJ45. As of 2026-10-05 only the
   second RJ45 has its cable (to the same LAN as eth0); ask before
   assuming anything else.
