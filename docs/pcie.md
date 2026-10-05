# PCIe

Status (2026-10-05): BSP read, hardware questions written down below; no
driver yet. No card: both slots are M.2 **E-key** sockets and the user has
no E-key card. Read "The outbound window" before choosing one.

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

Schematic sheet 10 "PCIe": `PCIE1_*` and `PCIE2_*` (TX/RX pairs, clock,
`CLKREQ`, `RST`) to two M.2 E-key sockets (see "On the W2"). Sheet 17
"M.2 USB" is a third M.2 socket, `CN40` key B (3042, for an LTE modem):
USB only, no PCIe.

`0x98012000` is the eMMC/NAND/CR pinmux block, also mapped by the PiKVM
eMMC and SD drivers. Map it without claiming the range, and touch only the
PCIe bits.

## On the W2

Both root complexes go to M.2 2230 **E-key** sockets (schematic sheet 10
"PCIe": CN7 and CN8, `NGFF2230 (KEY-E)`), with REFCLK, CLKREQ# and PERST#
each. PERST#: `PCIE1_RST#` = MISC GPIO 16, `PCIE2_RST#` = MISC GPIO 19
(sheet 2), as BPI's board DTS says. CLKREQ# are the pins' alternate
functions (`GPIO_95/PCIE1_CLKREQ`, `GPIO_96/PCIE2_CLKREQ`).

## The BSP

| File | What |
|---|---|
| `drivers/pci/host/pcie-rtd129x-slot1.c`, `-slot2.c` (929 lines each, nearly identical) | Host bridge: PHY setup over MDIO, link training, config space access, translation |
| `drivers/pci/host/pcie-rtd129x.h` | Registers |

## What the BSP driver really does (2026-10-05)

- **One device, no root port.** Config accesses go only to bus 0, device
  0, function 0, through indirect registers (`PCIE_CFG_ADDR/WDATA/RDATA`,
  `CFG_EN`, `CFG_CT` go, poll `CFG_ST` done/error); anything else returns
  "device not found". The root complex's own config space is the first
  4 KiB of the control registers (it writes command = 7 and the bridge
  memory base/limit there itself); Linux never sees it as a bridge, the
  endpoint *is* bus 0 device 0. A "direct" config mode exists
  (`cfg_direct_access`), switched off.
- **DLLP error patch**: after each config read, `0xC7C` low 5 bits set
  means a DLLP error: clear and retry, up to 5 times. `0xC78 = 0x200001`
  "prevents a hang if a DLLP error occurs".
- **Bring-up**: on RTD1296 other than B00 (so on this B01) it first writes
  `0x9801C614[2:0] = 1`, `0x9801C600[3:0] = 0` ("--PCIE"; slot 2:
  `[19:16]`) and `0x9801C608 = 0x51`. Not understood yet: what that block
  is, whether it is clocked, and whether it selects between PCIe and a
  SerDes PiKVM uses (USB3). **Find out before running anything**: do not
  even read it blind. Then all seven resets deasserted, the clock on,
  `0xC00 = 0x140010` (MDIO out of reset), the PHY table written to
  `0xC1C` (MDIO, one word each, 1 ms apart; slot 1 `phys_b` on B
  revisions, 6 words; slot 2 `phys`, longer), PERST# low 100 ms then high,
  `0xC00 = 0x1E0022` (LTSSM on, indirect config), 50 ms, `0x710 =
  0x10120`, then link-up (`0xCB4` bit 11) is awaited **only 60 ms**. On
  failure everything is put back in reset.
- **Lock API**: `CONFIG_RTK_SW_LOCK_API` serialised RBUS1 accesses at
  offsets 0x800-0x9ff across eMMC, SD, USB, PCIe and the WiFi drivers
  ("emmc hardware error"). It bypasses itself on revision B00 and later
  (`rtd129x_lockapi.c`), so not on this chip. That is why PiKVM never
  needed it.

## The outbound window: probably 4 KiB (the big open question)

The DT gives each slot a 16 MiB memory window (`0xc0000000`,
`0xc1000000`, mapped 1:1). But:

- The controller translates through one base/mask/translate set: `0xCFC`
  = `0x9804f000` (base), `0xD00` = `0xfffff000` (mask, 4 KiB), `0xD04`
  (translated PCI address).
- Realtek's WiFi drivers for this SoC (`rtl8822be_io.c`,
  `RTK_129X_PLATFORM`) never access a BAR beyond its first 4 KiB: for an
  offset >= 0x1000 they write `0xD04` to move the window, access
  `bar + (offset & 0xfff)`, and put `0xD04` back, under a lock. The host
  driver exports `rtk_pcie1_read/write` doing the same.
- Their comment: offset `0xCEC` "can't be used because of 1295 hardware
  issue", naming it `0x9804FCEC` -- i.e. CPU address `0xc0000cec` lands on
  the control page. The 16 MiB CPU range seems to alias one 4 KiB page.
- SB2's PCI translation registers (`0x9801a030`-`0x9801a060`, in the BSP
  header) read `0xdeadbeef` on this chip: not implemented.

If the CPU really sees only 4 KiB at a time, an unmodified mainline
device driver (it `ioremap`s a whole BAR: 16 KiB for Intel AX200, 64 KiB
for RTL8822CE, 1 MiB for MT7921) cannot work, whatever the host driver
does. Config space and enumeration are not affected (indirect registers).
**The first experiment with a card**: set the mask to the window size and
compare BAR reads beyond 4 KiB against the 4 KiB-window method. That
decides whether PCIe is worth a mainline host driver at all.

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
