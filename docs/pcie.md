# PCIe

Status (2026-10-04): not started. No mainline driver. No card attached yet.

## Hardware

Two PCIe 2.0 x1 root complexes, Realtek's own design (not DesignWare):

| | Slot 1 | Slot 2 |
|---|---|---|
| registers | `0x9804e000`, `0x9804f000` (0x1000 each) | `0x9803b000`, `0x9803c000` |
| shared | `0x9801c600` (0x100), `0x9801a000` (0x300), `0x98012000` (0x1000) | same |
| interrupt | GIC SPI 61 | GIC SPI 62 |
| memory window | `0xc0000000`, 16 MiB | `0xc1000000`, 16 MiB |
| I/O window | `0x30000`, 64 KiB | `0x40000`, 64 KiB |
| PERST# GPIO | MISC GPIO 16 on the W2 (BPI's board DTS overrides ISO GPIO 29 from the SoC DTS) | ISO GPIO 30 in the SoC DTS; the W2 board file lists MISC GPIO 19 as "pcie2 rst" |
| clock | `clk_en_1 1` | `clk_en_2 5` |
| resets (rstn, core, power, nonstitch, stitch, phy, phy_mdio) | `rst2 8, 13, 14, 15, 6, 7`, `rst4 13` | `rst2 17, 20, 21, 22, 19, 16`, `rst4 14` |

The ranges above are from the preprocessed W2 tree
(`.rtd-1296-bananapi-w2-2GB.dtb.dts.tmp`). It also has per-slot PHY
parameter lists (`phys_a`/`phys_b` for slot 1, `phys` for slot 2), which are
register writes in Realtek's MDIO encoding. Copy them from there.

Schematic page 8 ("PCIe"): `PCIE1_*` and `PCIE2_*` (TX/RX pairs, clock,
`CLKREQ`, `RST`), plus WiFi/BT wake lines. Check which physical slot
(mini-PCIe or M.2) each goes to. Page 15 ("M.2 USB") carries USB and LTE
signals.

`0x98012000` is the eMMC/NAND/CR pinmux block, also mapped by the PiKVM
eMMC and SD drivers. Map it without claiming the range, and touch only the
PCIe bits.

## The BSP

| File | What |
|---|---|
| `drivers/pci/host/pcie-rtd129x-slot1.c`, `-slot2.c` (929 lines each, nearly identical) | Host bridge: PHY setup over MDIO, link training, config space access, translation |
| `drivers/pci/host/pcie-rtd129x.h` | Registers |

## Things to know before starting

- Mainline approach: one driver for both slots (`pci_host_probe`,
  `pci_host_bridge`, ECAM-like config accessors over the controller's
  indirect registers), the PHY sequence from the DT data.
- The BSP config space accessors have workarounds (look for retries and
  delays). Keep them, and find out why.
- The PiKVM CMA and reserved memory must stay as they are. Check that the
  inbound DMA window covers the CMA area.

## Tried

Nothing yet.
