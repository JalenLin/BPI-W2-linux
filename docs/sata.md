# SATA

Status (2026-10-05): driver written, **not tried on the board yet**.
Mainline's generic AHCI driver (`ahci_platform`, built in) does the
controller; `drivers/sata/phy-rtd1295-sata.c` is the PHY. Builds clean
(`W=1`, checkpatch --strict); its PHY register writes are, word for word,
what the BSP writes on this chip (checked by re-encoding the tables). DT
in `dts/sata.dtsi`, binding validated. A small 2.5" SATA SSD is available
for testing; connecting it needs the board powered off.

## Hardware

- AHCI controller at `0x9803f000`, GIC SPI 28. Its last 256 bytes
  (`0x9803ff00`) are Realtek's wrapper: PHY status, the PHYs' MDIO
  controller, speed limits, debug and BIST (register map: the SDK's
  `hw_nat/AsicDriver/sata_reg.h` in `../bpiw2_pikvm/vendor/bpi-1296-android7`).
- Two ports, two PHYs, two connectors: SATA0 -> CN12, SATA1 -> CN15, both
  22-pin (7+15, data and power) on schematic sheet 12 "SATA/USB HUB".
- Drive power: 5VS_HDD0/1 (G524 load switches U10/U11) and 12VS_HDD0/1
  (MOSFETs Q4-Q7), sheet 6 "POWER", switched by `HDD0_PWR` = **MISC GPIO
  56** (SoC ball `GPIO_56 / AI_LRCK / DMIC_DATA`, 4K7 on sheet 2). The text
  of sheet 6 shows `HDD0_PWR` on both 12 V gates; whether port 1 has its
  own enable was not settled from the PDF (the BSP's "ISO GPIO 15" for port
  1 is `UR1_RTS#` on this board). The PiKVM image does not use GPIO 56.
- GPIO 56's pin mux: DISP pinmux `0x9804d008` bits 5:4, 0 = GPIO (BSP
  `pinctrl-rtd129x.h`). Not read yet: unsure whether that block is always
  clocked.
- Chip revision: SB2 `0x9801a204` = `0x00030000`, B01 on this board. The
  PHY's RX settings depend on it (A00/A01 vs later), and one extra write is
  B00-only.

### Clocks and resets

| | Port 0 | Port 1 | Node |
|---|---|---|---|
| controller clock | CLK_EN1 2 (`crt_clk 2`) | CLK_EN2 25 (`crt_clk 57`) | AHCI |
| alive clock | CLK_EN1 7 (`crt_clk 7`) | CLK_EN2 26 (`crt_clk 58`) | PHY |
| controller reset | `reset1` 5 `SATA_0` | `reset4` 10 `SATA_1` | AHCI |
| PHY reset | `reset1` 7 `SATA_PHY_0` | `reset4` 9 `SATA_PHY_1` | PHY |
| PHY power reset | `reset1` 10 `SATA_PHY_POW_0` | `reset4` 7 `SATA_PHY_POW_1` | PHY |
| function exist | `reset1` 11 | `reset4` 8 | not used (see below) |

On the running board (read-only, 2026-10-05) every one of these clocks is
off and every reset asserted: the boot loader never touches SATA, and
neither does PiKVM.

`SATA_FUNC_EXIST_0/1`: the BSP's SATA drivers never release them. Only the
NAT engine's SGMII path (MAC0 through PHY 0) does, in the SDK's
`rtd129x_clk.c`. Left asserted; the first thing to try if the link never
comes up.

### The PHY registers

`SATA_MDIO_CTR` (`+0x60`): data 31:16, "PHY address" 15:14, register
13:8, busy 7, ready 4, write 0. `SATA_MDIO_CTR1` (`+0x64`) selects PHY 0
or 1. The BSP's tables are raw MDIO words, each register written at
addresses 0, 1 and 2: one value per link rate (presumably 1.5/3/6 Gbit/s;
only register 0x01, 0x03 differ between them). Decoded, the driver writes
18 registers (Realtek's defaults; TX swing level 2 = 683 mV, as the
RTD1296 DTs set; spread spectrum off), then 2 RX-sensitivity registers by
revision. `SATA_SPD` (`+0x68`, 2 bits per port) = 2, no speed limit.
`SATA_PHY_MON` (`+0x24`): calibrated (bit n), ready (bit 2 + n).

SB2 `SATA_PHY_CTRL` (`0x9801a980`): per PHY n, bandgap enable (bit n),
bias enable (2 + n), RX 50-ohm termination (4 + n); bit 8 selects SATA
rather than SGMII for PHY 0.

## The drivers

- **AHCI**: `ahci_platform`, compatible `"realtek,rtd1295-ahci",
  "generic-ahci"`. It takes all the node's clocks and resets, each port's
  PHY and `target-supply`, and enables them in the order regulators,
  clocks, resets, PHYs (init, then power on) -- the BSP's order too.
  `ports-implemented = <0x3>`: the BSP writes PI itself (it reads 0 out of
  reset). Registers `0x3f000-0x3feff`; the wrapper is the PHY node's.
- **PHY** (`phy-rtd1295-sata.c`): `init` turns on the port's alive clock,
  releases its PHY reset, sets the SB2 bits and writes the tables
  (1 ms after each write, as the BSP); `power_on` releases the power reset
  and reports (does not require) `PHY_MON` calibrated; `power_off`/`exit`
  undo. The BSP's power saving, its hot-plug kthread and the 8-second
  delayed host start are left out.
- The kernel's SB2 sync in `writel()` covers libahci's doorbells (docs/
  board-and-tooling.md); nothing to add.

Not in mainline yet, for upstream: `realtek,rtd1295-ahci` in
`ata/ahci-platform.yaml`; the PHY binding is
`dts/bindings/phy/realtek,rtd1295-sata-phy.yaml`.

## Device tree

`dts/sata.dtsi`: a fixed regulator on GPIO 56 for drive power, the PHY
node (both PHYs) and the AHCI node with both ports. Builds into the board
DTB; `dt-validate` with the PHY binding is clean. Binding: yamllint,
dt-doc-validate and its example clean; a bogus property and a missing
`realtek,sb2` are both reported.

Development overlay (`drivers/sata/sata-overlay.dtso.in`,
`scripts/build-overlay.sh sata`): the same nodes, except drive power. The
board DTB gives the MISC GPIO controller no phandle (nothing refers to
it), so the overlay cannot point a regulator at it; it adds a `gpio-hog`
under the controller instead, which turns the power on when the overlay is
applied.

To try it: `phy-rtd1295-sata.ko` first, then `sata-overlay-mod.ko`
(ahci_platform probes as soon as the node appears and defers until the PHY
exists).

## Tried

Nothing on the board yet.
