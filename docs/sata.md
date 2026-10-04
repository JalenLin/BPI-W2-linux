# SATA

Status (2026-10-04): not started. No mainline driver. No disk attached to
the board yet.

## Hardware

- AHCI controller at `0x9803f000` (size 0x1000), GIC SPI 28.
- SATA PHY registers at `0x9803ff60` (0x100), plus `0x9801a980` (0x10).
- Two ports in the SoC (`SATA0_*` and `SATA1_*` nets on schematic page 10,
  "SATA/USB HUB"). Check on the board and the schematic which one reaches
  the connector, and how the drive gets power.

## The BSP

| File (under `../bpiw2_pikvm/vendor/bpi-w2-bsp/linux-rtk/`) | What |
|---|---|
| `drivers/ata/ahci_rtk.c` (508 lines) | The AHCI glue on top of libahci_platform |
| `drivers/phy/phy-rtk-sata.c` | The PHY: parameter tables, spread spectrum, TX drive |
| `arch/arm64/boot/dts/realtek/rtd129x/rtd-129x-sata.dtsi` | The two nodes, compatibles `Realtek,ahci-sata` and `Realtek,rtk-sata-phy` |
| `arch/arm64/boot/dts/realtek/rtd129x/rtd-1296-sata.dtsi` | RTD1296's clocks, resets and per-port data; the W2 includes this one |

From `rtd-1296-sata.dtsi` (BSP clock/reset numbering, which is bit numbers
like the mainline `crt_clk`):

| | Port 0 | Port 1 |
|---|---|---|
| resets | `rst1 5` (sata), `rst1 7` (phy) | `rst4 10`, `rst4 9` |
| PHY power reset | `rst1 10` | `rst4 7` |
| power GPIO | MISC GPIO 56 | ISO GPIO 15 |
| controller clocks | `clk_en_1 2`, `clk_en_1 7`, `clk_en_2 25`, `clk_en_2 26` | |

`rtd-1296-sata.dtsi` deletes its own `phy-param` and `tx-driving-tbl`
properties, so the PHY driver's built-in defaults are what runs. Read those
in `phy-rtk-sata.c`. BPI's W2 DTS sets both nodes to `okay`.

## Things to know before starting

- The hardware NAT code has a flag "MAC0 interface used by SATA (0) or
  NAT (1)" and toggles a `sata_func_exist_0` reset. That is the NAT
  engine's MAC0 in SGMII mode using the SATA0 PHY as its SerDes
  (`SB2_SATA_PHY_CTRL.sata_sgmii_sel`). The second RJ45 is MAC5, not MAC0,
  so it does not touch SATA (see second-ethernet.md, "Port numbering").
- Mainline approach: `ahci_platform` with a small glue (resets, clocks, the
  power GPIO) and a `phy` driver for the PHY, as `ahci_mtk.c` or
  `ahci_brcm.c` do.
- MISC GPIO 56 is on the MISC GPIO controller the PiKVM DTS already has
  (`&misc_gpio`, mainline `gpio-rtd`). ISO GPIO 15 is not: the ISO GPIO
  controller is left out of that DTS because mainline's driver claims a
  range that overlaps the ISO reset/clock controllers (PiKVM docs/10 §7).
- The PiKVM DTS's reserved memory and CMA (128 MiB) must stay as they are.

## Tried

Nothing yet.
