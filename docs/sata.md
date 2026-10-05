# SATA

Status (2026-10-05): **works on the board**: 6 Gbps link, reads at
SATA III's limit, writes verified, ext4, all alongside the other DMA
masters (see "Tried"). Tested with the development overlay; the
regulator path of `dts/sata.dtsi` needs that DTB installed.
Mainline's generic AHCI driver (`ahci_platform`, built in) does the
controller; `drivers/sata/phy-rtd1295-sata.c` is the PHY. Builds clean
(`W=1`, checkpatch --strict); its PHY register writes are, word for word,
what the BSP writes on this chip (checked by re-encoding the tables). DT
in `dts/sata.dtsi`, binding validated. Test drive: ADATA SX930 240 GB
on the connector nearer the board edge, which is **port 1** (`ata2`).

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

2026-10-05, development overlay (drive power by GPIO hog), first try:

- `sata-up.sh`: PHY driver probes ("2 PHY(s), chip revision 0x30000"),
  ahci_platform binds (AHCI 1.3.1, 32 slots, 6 Gbps, NCQ, FBS not on these
  ports), `ports-implemented` forces PI 0 -> 3. Port 0 (nothing
  connected): link down. Port 1: **link up at 6.0 Gbps**, ADATA SX930
  identified, LBA48, NCQ depth 32.
- **First link-up took 18 s** ("link is slow to respond", one "softreset
  failed (device not ready)"): the hog powered the drive at the same
  moment the controller probed, and the SSD needed that long after power
  on. On a reload with the drive already powered: link up in 0.5 s.
  libata waits on its own; nothing to fix in the driver. (With the
  regulator of `dts/sata.dtsi` the same wait will happen at every probe
  from cold.)
- Unload (`sata-up.sh down`): every SATA reset and clock back exactly to
  the boot values (`SOFT_RESET1` 0xfffa3357, `CLK_EN1` 0x9bffc571,
  `CLK_EN2` 0xd9ffe497, `SOFT_RESET4` 0x903f). The hog's removal leaves
  GPIO 56 high (the drive stays powered).
- Reads (read-only; the SSD has no partition table and reads zeros):
  1 MiB direct 322 MB/s (one request at a time), 4 MiB 476, 16 MiB 519,
  buffered 527 MB/s -- SATA III's practical limit; 4 KiB random reads
  6548 IOPS at queue depth 1. The same 512 MiB read twice: identical.
- **Alongside every other DMA master** (`sata-dma.sh`: continuous SSD
  reads plus `dma-stress.sh` -- TCP both ways on eth0/eth1, eMMC and SD
  reads, byte-exact loop tests): TCP 836 + 496 Mbit/s, loop tests 1200/1200
  both ways, eMMC 103 MB/s, SD 17.6 MB/s, no error counter moved, and the
  SSD region checksummed 4 times under that load equal to the quiet read.
  No SATA or MMC error in dmesg.

- **Writes** (the user allowed overwriting this SSD; `sata-write.sh`): a
  256 MiB random pattern written at 16 places over the disk, the last 8
  while `dma-stress.sh` ran (TCP 882 + 532 Mbit/s, loop tests 1200/1200,
  eMMC 111 MB/s, SD 19.7 MB/s, no error counter moved): **all 16 read
  back identical**. 307-313 MB/s per copy alone, 206-249 under the load;
  4 GiB sequential 305 MB/s (16 MiB direct writes, one at a time).
- **ext4** (`sata-fs.sh`): GPT, one partition, `mkfs.ext4`; 8 x 256 MiB
  files from two writers at once, with sync, 454 MB/s; after dropping the
  page cache all 8 read back identical; `fsck.ext4 -f` clean. No SATA or
  filesystem message in dmesg. The filesystem is left on the SSD.

- **Port 0** (SSD moved to the other connector, CN12, after a power cut
  **without a clean shutdown** following the write tests): link up at 6.0
  Gbps and IDENTIFY completes, so PHY 0, its clocks and resets, SB2's
  SATA/SGMII select and CN12's power (GPIO 56 too) work. But the drive
  answered as "Generic FCR SATA Loader Loader Device", 8192 sectors (4
  MiB), UDMA/100 -- the JMicron controller's ROM loader: the SSD's
  firmware did not load. The same after 85 s more of power. Most likely
  the abrupt power-off after writes (no STANDBY IMMEDIATE); being checked
  on another PC. Lesson in docs/testing.md.

Not done yet: reads and writes on port 0 (needs a working drive), the
regulator path of `dts/sata.dtsi` (needs that DTB), hot-plug, a long
soak.
