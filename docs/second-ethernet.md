# The second RJ45 (hardware NAT engine)

Status (2026-10-05): **complete**, as a loadable module,
`drivers/nat-eth/rtd1295-hwnat.c` (checkpatch --strict clean), with the
node applied as a runtime overlay (no board DTB has it yet).
10/100/1000 Mbps, TCP at line rate both ways with CPU load like eth0's,
802.1Q VLANs, pause, promiscuous mode, RX checksum, interrupt mitigation,
ethtool (link, pause, coalescing, MIB statistics), recovery from a TX
stall; eth0 untouched. See "Verified" and "Open".

The first survey (2026-09-17) is `docs/06-changes.md` §11 on the `main`
branch of `../bpiw2_pikvm`
(`git -C ../bpiw2_pikvm show main:docs/06-changes.md`).

## Hardware

The two RJ45 sockets are driven by two different MACs:

| Socket | MAC | PHY | State |
|---|---|---|---|
| Next to the USB ports | `gmac@98016000` (`r8169soc`, PiKVM patch 0008) | the SoC's embedded gigabit PHY (`ETN_MDI*`) | works, `eth0` |
| The other one | **port 5 (MAC5)** of the hardware NAT engine, `0x98060000` | an external RTL8211F over RGMII0, MDIO address 1 | `rtd1295-hwnat` (this repo), eth1 |

Schematic page 12 ("HWNAT_0"): `RGMII0_*` (RXC, RXCTL, RXD0-3, TXC, TXCTL,
TXD0-3, MDIO/MDC) to the RTL8211F, whose line side is `NAT0_MDI0-3`.
Page 11 ("GBE") has a 20-pin header (CON5) with `RGMII1_*`: a second RGMII
that BPI leaves to expansion.

### Port numbering (corrects the 2026-10-04 note, which said MAC0)

The NAT switch core has these external ports (from `rtd129x_clk.c` and
the BSP DT properties `mac0_*`, `mac4_*`, `mac5_*`):

| Port | Wired to | BSP setting on the W2 |
|---|---|---|
| MAC0 | RGMII1 (the CON5 header) in RGMII mode, or SGMII through the SATA0 SerDes | `mac0_enable = <1>`, `mac0_mode = <0>` (RGMII), `mac0_phy_id = <2>`; the router patch sets `mac0_enable = <0>` |
| MAC4 | the embedded GPHY, **only** once `etn_gphy_switch_nat` moves it over (that is eth0's PHY) | `mac4_phy_id = <4>` |
| MAC5 | RGMII0 -> the on-board RTL8211F, the second RJ45 | `mac5_phy_id = <1>`, `mac5_conn_to = <0>` (PHY) |

So the second RJ45 is MAC5. `rtd129x_hwnat_set_rgmii0_init()` is MAC5's
pad setup; `..._rgmii1_init()` is MAC0's. MAC0 in SGMII mode is what
shares the SATA0 PHY (`rtd129x_hwnat_set_sata_pllddsa()`,
`..._set_serdes_sgmii_init()`): with MAC0 off, SATA is not involved.

### IO voltage and PHY strapping

- `RGMII0_VDD` is on 1.8VD (schematic page 1); the RTL8211F's MDIO pull-up
  (RG5, 2K2) goes to 1.8VD too. So the RGMII0 pads need the 1.8 V setting
  (BSP `rgmii_voltage = <1>`).
- RTL8211F strap pins: RXD3/PHYAD0, RXC/PHYAD1, RXCTL/PHYAD2 -> address 1
  (confirmed: ID 001c:c916 answers there). `PHYRSTB0` has a 4K7 pull-up to
  0_DVDD33 and no GPIO found driving it: no hardware reset line for the PHY.
- Delay straps, read at page 0xd08 before any driver touched them: reg 17
  = 0x0009 (**TX delay off**), reg 21 = 0x0019 (**RX delay on**). So both
  delays belong in the PHY: `phy-mode = "rgmii-id"`. With `rgmii-txid` the
  mainline `realtek` driver turns the RX delay off and every received frame
  fails its FCS at port 5 (seen in the MIB counters).
- ISO `0x98007064` bit 1 ("RGMII/MDIO to GMAC", which r8169soc sets only in
  its RGMII output modes) is 0: RGMII0 and its MDIO belong to the NAT
  engine.

### Live state on the running PiKVM image (read with /dev/mem, 2026-10-05)

| Register | Value | Meaning |
|---|---|---|
| CRT `SOFT_RESET1` 0x98000000 | 0xfffa3355 | bit 1 `rstn_nat` = 0: NAT held in reset |
| CRT `CLOCK_ENABLE2` 0x98000010 | 0xd9ffe496 | bit 0 `clk_en_nat` = 0: gated (`<&crt_clk 32>`) |
| CRT `PLL_DDSB2` 0x98000178 | 0x3 | POW = 1, RSTB = 1, OEB = 0: PLLDDSB already on and output enabled |
| CRT `PLL_SSC_DIG_DDSB1` 0x98000584 | 0x6800 | 432 MHz, as the BSP sets it |
| CRT 0x98000400 (SRAM isolation) | 0x0008022c | bit 18 (NAT) = 0: not isolated |
| CRT 0x98000430 (NAT SRAM `PWR4`) | 0 | bit 0 = 0: NAT SRAM powered |
| ISO `POWERCUT_ETN` 0x9800705c | 0x703 | bit 4 `etn_gphy_switch_nat` = 0, bit 5 = 0: GPHY belongs to eth0 |
| SB2 `PFUNC_RG0..2` 0x9801a960 | 0x3f, 0, 0xa4000000 | RGMII0 pads at the **3.3 V** setting (wrong for this board) |
| SB2 `MUXPAD_RG0` 0x9801a96c | 0x05555555 | RGMII0 pins already muxed to RGMII + MDC/MDIO |
| SB2 `PFUNC_RG3..5`, `MUXPAD_RG1` | 0x3f, 0, 0xa4000000, 0x05555555 | RGMII1, same |
| NAT 0x98060000.. | 0xdeadbeef | clock gated |

The NAT SRAM power domain (BSP `pwrctrl-rtd129x.c`, `nat_pd`: PWR at CRT
0x420, isolation CRT 0x400 bit 18) is already on, so no power-domain code
is needed for a first version.

## Bring-up sequence for MAC5 alone

From `AsicDriver/rtd129x_clk.c` (`rtd129x_hwnat_clk_init()`), with what to
keep and what to drop:

| BSP step | Keep? |
|---|---|
| `power_control_power_on("pctrl_nat")` | Already on (see above). Check, don't touch. |
| `rtd129x_hwnat_set_pllddsb()`: PLLDDSB at 432 MHz, power on, output on | Already on. Check, don't touch (who else uses it is not known). |
| `rtd129x_hwnat_set_etn_clk()`: deassert ISO `rstn_gmac`/`rstn_gphy`, clear `ISO_ETN_TESTIO.etn_bpsgphy_mode`, clear `ISO_ETN_DBUS_CTRL.iso_etn_pwr_ctrl_en`, toggle `clk_en_etn_sys`/`etn_250m` on and **off** | **Drop.** All of it is eth0's (`r8169soc` owns these). Turning the ETN clocks off would kill eth0. |
| ... then: `clk_en_nat` on, off; deassert `rstn_nat`; `clk_en_nat` on | Keep: `<&crt_clk 32>`, `<&reset1 RTD1295_RSTN_NAT>`. |
| MAC0 (`hwnat_mac0_enable`): RGMII1 pads, or SATA PLLDDSA + SerDes | Drop (MAC0 off). |
| `rtd129x_hwnat_set_rgmii0_init()`: `MUXPAD_RG0 = 0x05555555`; 1.8 V pads: `PFUNC_RG0 = 0`, `PFUNC_RG1 = 0x44444444`, `PFUNC_RG2 = 0x24444444` | Keep. |
| ... then clear `POWERCUT_ETN.gphy_mdio_outside_ctrl_en`, set `POWERCUT_ETN.etn_gphy_switch_nat` | **Drop.** This is what takes the embedded PHY away from eth0. |
| `rtd129x_switch_init()`: `EEECR = 0`, `EEEABICR1 = 0`; `EPIDR` embedded PHY IDs | Keep EEE off; EPIDR only matters for embedded PHYs. |
| ... MAC4: `EPIDR` port 4, `PITCR` port 4 = UTP, `rtd129x_phy_8211f_init(4)` (MDIO writes at address 4) | **Drop.** No MDIO traffic to address 4. |
| ... MAC5: `PCRP5.ExtPHYID = 1`; `PITCR` port 5 = GMII/MII/RGMII; `P5GMIICR.CFG_GMAC = RGMII`; `rtd129x_phy_8211f_init(1)`; RTL8211F page 0xd08 reg 17 bit 8 (TX delay) | Keep, with the RTL8211F left to the mainline `realtek` PHY driver, `phy-mode = "rgmii-id"`, `realtek,clkout-disable`. Its RXC/system-clock SSC settings are not set (mainline has no option for them). |
| probe: interrupt mitigation `CPUIMTTR0..3`, `CPUIMPNTR0..2`, `CPUIMCR` | Not set yet (NAPI only, `CPUIMCR` = 0). |
| `re865x_probe()` on the 8197F core: `CPUICR1.CF_PKT_HDR_TYPE = TX_PKTHDR_SHORTCUT_LSO`, `CF_TX_GATHER` (TSO/GSO builds) | **Keep -- essential**, see "Findings". |
| `rtl865x_initAsicL2()`, `rtl865x_config()` | The subset in "What the driver does". |

## The vendor driver

BPI's router build ships it, in the OpenWrt kernel of the Android tree:

```
../bpiw2_pikvm/vendor/bpi-1296-android7/Openwrt/linux-4.1.7/drivers/soc/realtek/rtd129x/hw_nat/
```

The clone is sparse. Materialise what you need with
`git -C ../bpiw2_pikvm/vendor/bpi-1296-android7 sparse-checkout add <path>`
(the top-level files and `AsicDriver/` were added on 2026-10-04). Don't run
`git ls-tree -l` there: it fetches every blob.

It is Realtek's RTL819x router SDK: 223 files and 267k lines, plus 2,308
`CONFIG_RTL_*` conditionals patched into 94 files of `net/` and `include/`.
The parts a plain NIC needs:

| File | Lines | What |
|---|---|---|
| `rtl_nic.c` | 28,439 | The netdev driver (most of it router features); `re865x_probe()`, `re865x_open()`, `rtl865x_config()` |
| `rtl819x_swNic.c`, `.h` | 2,189, 637 | **The rings this core uses**: the RTL8197F six-word descriptors (`New_swNic_*`) |
| `rtl865xc_swNic.c`, `.h` | 2,761 | The older pkthdr/mbuf rings; on this core only its headers (ring sizes) matter |
| `rtl819x_switch.c` | 535 | Only the OpenWrt swconfig interface |
| `AsicDriver/rtd129x_clk.c` | 914 | Clocks, resets, pads, PHY init for the NAT block |
| `AsicDriver/rtl865x_asicCom.c`, `rtl865x_asicL2.c` | 2,247, 11,669 | Switch core registers: VLAN/netif tables, MDIO, ports |
| `AsicDriver/rtl865x_asicBasic.S` | 16,317 | Table access (`_rtl8651_forceAddAsicEntry` etc.), shipped **only as ARM64 compiler output**; readable, see "Table access" |
| `AsicDriver/rtl865xc_asicregs.h`, `rtl865x_asicCom.h` | | Register and table-entry layouts |

The NAT block is an **RTL8197F** switch core: `RTD_1295_HWNAT` selects
`RTL_8197F`, and `rtl_types.h` then `#define`s
`CONFIG_RTL_SWITCH_NEW_DESCRIPTOR`.

Reading tip: the code is unreadable with all its `#ifdef`s. Resolve the
Kconfig with kconfiglib (`hw_nat/Kconfig` with `RTD_1295_HWNAT=y`; 42
symbols come out set, among them `RTL_8197F`, `RTL_MULTI_LAN_DEV`,
`RTL_TSO`, `RTL_GSO`, `OPENWRT_SDK`) and strip the dead branches with
`unifdef` (both in Docker): `rtl_nic.c` drops from 28k to 9k lines. But
symbols `#define`d in headers must be left alone: treating
`CONFIG_RTL_SWITCH_NEW_DESCRIPTOR` as undefined hid the one line that
selects the descriptor format, and cost a debugging round.

The board DTS in that tree has the node disabled. The router build enables
it with `Openwrt/target/linux/rtd1295/dts/patches/001-Enable-router-mac-but-disable-umac.patch`,
which also **disables the working MAC**.

## Why the vendor setup turns eth0 off

In `AsicDriver/rtd129x_clk.c`, the NAT bring-up "switches the gphy channel
for NAT": it sets `etn_gphy_switch_nat` in `ISO_POWERCUT_ETN`. That moves
the embedded PHY -- the one `eth0` uses -- over to the NAT engine. In
router mode the NAT engine has both ports, and the ordinary MAC has
nothing.

So a driver that leaves `eth0` alone must:

- skip that step, and bring up only MAC5 on RGMII0 with the external
  RTL8211F;
- run the switch core with just the CPU port and port 5, and forward
  everything between them (no NAT, no L2 offload).

Also in the same file: `hwnat_mac0_enable` is commented "0: interface used
by SATA, 1: interface used by NAT", and a `sata_func_exist_0` reset is
handled there. That is MAC0 in SGMII mode borrowing the SATA0 PHY as its
SerDes (see "Port numbering" above); the second RJ45 does not need it.

The vendor's order: `re865x_probe()` (clocks, `rtl865x_initAsicL2()`,
`rtl865x_init()`, `rtl865x_config(vlanconfig)`, the CPUICR1 descriptor
setup), then `re865x_open()` -> `rtl865x_init_hw()` -> `New_swNic_init()`,
`rtl865x_start()`, `rtl865x_enableDevPortForward()`. No smaller copy of
this driver exists in BPI's trees (u-boot and the BSP 4.9 kernel have none).

## The driver

`drivers/nat-eth/rtd1295-hwnat.c` (compatible `realtek,rtd1295-hwnat`),
DT node in `dts/nat-eth.dtsi`. A plain NIC: phylib, NAPI, one RX and one
TX ring, RX checksum offload; no switch features.

### What it does

Probe:

1. RGMII0 pads to 1.8 V through the `realtek,sb2` syscon (`MUXPAD_RG0`,
   `PFUNC_RG0..2`).
2. NAT clock and reset in Realtek's order: assert reset, clock on, clock
   off, deassert, clock on.
3. Switch core, L2 only: EEE off; `MSCR` = L2 only (no ACL, L3, L4, STP);
   L2 aging on; netif, VLAN (4096) and L2 (1024) tables cleared; netif
   decision **by port** (`PLITIMR`: port 5 -> netif 0; see "Findings"),
   `NAPTF2CPU`, unknown multicast to CPU; VLAN ingress
   filter off; checksum-error frames not forwarded; vendor flow-control
   thresholds (`PBFCR5`/`PBFCR6` = 0x1ac/0x1a6); one output queue per
   port; every CPU queue to RX ring 0.
4. Port 5: `PITCR` RGMII, `P5GMIICR` RGMII + `Conf_done`, `PCRP5` with
   ExtPHYID = the PHY's address, **force mode** (see "Findings"), STP
   forwarding, PHY interface on.
5. VLAN 1 = {port 5}, untagged, FID 0; netif 0 = VLAN 1 with the
   interface's MAC; port 5's PVID = 1.
6. `CPUICR1`: new descriptor format, TX gather, little-endian.
7. MDIO bus (`MDCIOCR`/`MDCIOSR`), the `mdio` child node, then the netdev.

Open: rings (256 RX, 256 TX; rings 1-5 and TX 1-3 get two empty,
CPU-owned descriptors so a stray frame finds no buffer), TX ring 0 tail
in `DMA_CR1` + `DMA_CR4.TX0_TAIL_AWARE` (as Realtek: no EOR on TX),
`CPUICR` = TX/RX on, 128-word bursts, `DMA_CR0` FIFO marks, interrupt
mitigation, interrupts RX done / RX runout / TX ring 0 one-frame-done,
`SSIR.TRXRDY`.

Data path: TX is a direct send to port 5 (`opts4` port mask bit 5,
`opts3` VLAN 1, lengths + 4 for the FCS the MAC appends), then
`CPUICR.TXFD`; completion by the descriptors' owner bit (Realtek reads
the current-descriptor pointer instead; see "Findings"). RX polls both owner bits (`opts1[0]`,
`opts5[15]`), marks unfragmented TCP/UDP whose checksum flags are OK
`CHECKSUM_UNNECESSARY` (everything else `CHECKSUM_NONE`, for the stack to
check and count; Realtek drops frames with the flags clear, this driver
does not), refills, and clears `CPUIISR` runout to resume reception.
`nat_adjust_link()` mirrors phylib's link, speed, duplex and pause into
`PCRP5`.

Stop only stops the CPU side (`CPUICR`, interrupts); the switch keeps
running (`SSIR.TRXRDY` stays set; see "Findings"). A TX timeout (the
netdev watchdog, 5 s with the queue stopped) schedules a work item that
stops the DMA, rebuilds both rings and starts again.

VLANs: `NETIF_F_HW_VLAN_CTAG_FILTER`. A VID the stack adds
(`ndo_vlan_rx_add_vid`, e.g. creating eth1.2700 or a VLAN-aware bridge)
gets a VLAN table entry with port 5 as a tagged member; tagged frames on
other VIDs are discarded at port 5's ingress. Tagged frames reach the CPU
with the tag in the data (the stack strips it) and go out as the stack
built them. VID 1 is the port's own untagged VLAN and is refused (-EBUSY).
In promiscuous mode every VID is open (a work item writes the ~4000
entries under RTNL; the VIDs asked for are kept in a bitmap to restore).

Promiscuous mode sends unknown unicast to the CPU (`FFCR`). Multicast
always reaches it (unknown multicast to CPU, empty multicast table).
Unicast the switch has learned on port 5 stays on port 5, so traffic
between two other hosts on that side is not seen even in promiscuous
mode.

ethtool: `-c/-C` (interrupt mitigation, rx/tx usecs and frames; default
RX 32 frames / 200 us, TX 32 / 400 us), `-k/-K rx` (RX checksum),
`-a/-A` (pause: negotiated by default, or forced), `-S` (port 5's MIB
counters and the CPU port's discards), link settings and `-r` through
phylib. Changing the MAC address works live (`ndo_set_mac_address`).

The MIB counter registers are 22 bits wide (frame counters wrap after
4,194,304 frames, under 3 s at line rate with small frames); a delayed
work item reads them every second and keeps 64-bit totals for
`ethtool -S`. The bring-up debugfs file and register dumps are gone.

### Register map (offsets from 0x98060000)

| Offset | Block |
|---|---|
| 0x000000 + (type << 16) + index * 32 | Switch tables (read side); type 0 L2, 4 netif, 6 VLAN |
| 0x160000 | CPU interface: `CPUICR`, `CPURPDCR0-5`, `CPUTPDCR0-1`, `CPUIIMR`, `CPUIISR`, `CPUQDM*`, `DMA_CR0-4`, `CPUTPDCR2-3`, `CPUIM*`, `CPUICR1` (0xa4) |
| 0x161000 | MIB counters: in at 0x100 + port * 0x80, out at 0x800 + port * 0x80 (port 6 = CPU) |
| 0x164000 | MAC control: `MDCIOCR` 0x004, `MDCIOSR` 0x008, `CSCR` 0x048 |
| 0x164100 | Ports: `PITCR`, `PCRP0-8` 0x104.., `PSRP0-8` 0x128.., `P5GMIICR` 0x150, `EEECR` 0x160 |
| 0x164200 | `SSIR` 0x204 (`TRXRDY`) |
| 0x164400 | ALE: `TEACR`, `MSCR` 0x410, `SWTCR0` 0x418, `FFCR` 0x428 |
| 0x164500 | Flow control thresholds: `PBFCR0-6` 0x50c.. |
| 0x164700 | `QNUMCR` 0x754 |
| 0x164a00 | VLAN: `VCR0`, `PVCR0..` 0xa08 (12 bits per port, two per word) |
| 0x164d00 | Table access: `SWTACR`, `SWTASR`, `SWTAA` 0xd08, `TCR0-7` 0xd20 |
| 0x165100 | `MACCTRL1` |
| 0x169000 | NAT wrapper (SGMII/SerDes; not used) |

### Table access

From the compiler output in `rtl865x_asicBasic.S`: set `SWTCR0` bit 18
(stop the lookup unit), wait for bit 19; wait for `SWTACR` bit 0 to
clear; write the entry's words to `TCR0..`; write `SWTAA` = the table's
**physical** address (`0x98060000 + (type << 16) + index * 32`); write 9
(force add) to `SWTACR`; wait for bit 0; clear `SWTCR0` bit 18. Words per
entry (`_rtl8651_asicTableSize`): L2 2, netif 5, VLAN 3, ACL 11.

## Testing it

The procedures, the scripts and the traps: docs/testing.md. The node and
its overlay: docs/device-tree.md.

The base DTB has no `__symbols__`, so the node goes in as a runtime
overlay with the running board's phandles:

```sh
scripts/build-nat-overlay.sh          # writes drivers/nat-eth/nat-overlay.dtso
scripts/build-module.sh nat-eth       # rtd1295-hwnat.ko and nat-overlay-mod.ko
# on the board: insmod nat-overlay-mod.ko (adds the node), insmod rtd1295-hwnat.ko
```

`rmmod nat_overlay_mod` removes the node again. Nothing on the board's
disk changes. Re-run the script after a new board DTB.

The image's networkd brings eth1 up with DHCP as soon as it appears (it
matches `eth*`). Both NICs then sit on the same subnet, so to test the
wire move eth1 into a network namespace (`scripts/board/README.md`).

## Verified (2026-10-05, cable to the same LAN switch as eth0)

- Probe: MDIO works through the NAT block; RTL8211F ID 001c:c916 at 1.
- Link 1 Gbps full, stable over repeated loads, no flap.
- DHCP on eth1.
- `looptest.py` (frames of 60-1514 bytes from one NIC to the other's MAC
  across the LAN switch, every byte compared): 4000/4000 each way, also
  **while the eMMC read 104 MB/s with `O_DIRECT`** (the SB2 concern).
- TCP (`tput.py`, eth1 in a namespace): eth1 -> eth0 940 Mbit/s,
  eth0 -> eth1 941 Mbit/s. Both at once plus the eMMC read: 564 + 630
  Mbit/s (four A53 cores running both Python ends), no errors.
- rmmod/insmod with the interface up, a dozen times.
- eth0 stayed up with its address through all of it; no eth0 messages in
  dmesg.

Later the same day, after the fixes in "Findings":

- 10/100/1000 Mbps forced through `ethtool -s`: 100 full 94/94 Mbit/s,
  100 half 86/78, 10 full 9.3/9.2, 10 half 7.9/7.3, back to 1 Gbps.
- Promiscuous: frames to a MAC nobody has, 0/100 normally, 100/100
  byte-exact with promiscuous on, 0/100 off again.
- Pause negotiated rx/tx: under bidirectional TCP plus eMMC reads the
  switch sent 40,429 PAUSE frames and discarded nothing (without pause the
  same test discarded 339 frames on port 5); TCP 599 + 751 Mbit/s;
  forced settings (`ethtool -A ... autoneg off`) land in `PCRP5` bits
  17:16 as asked.
- `ethtool -S` octets equal the kernel's bytes plus 4 per frame, exactly,
  past 476 MB (so the 22-bit low word is read right).
- TX stall induced on purpose (`CPUICR.TXCMD` cleared through /dev/mem,
  ring then filled): watchdog after 5.3 s, rings rebuilt, ping and TCP
  (936 Mbit/s) back without intervention.
- Regression run (`scripts/board/regress.sh`):
  insmod/rmmod x3; loop test 1200/1200 each way under eMMC DMA; link
  down/up x5 each followed by TCP at 936-940 Mbit/s; iperf3 to the host
  904/914 Mbit/s; ping 100/100 at 0.31 ms; bad checksums counted by the
  stack; no MIB errors, no driver errors, nothing in dmesg.

Storage DMA alongside (2026-10-05, SD card in): SD reads alone, with
eMMC reads, with TCP both ways, and with both, no SD error
(`scripts/board/sd-isolate.sh`); then TCP both ways plus eMMC and SD
reads, and the byte-exact loop test during the reads: 1200/1200 each
way, no error counter moved (`scripts/board/dma-stress.sh`). The first
attempt had failed with SD CRC errors (-84) that also kept the reinserted
card from initialising; after the card was reseated it never recurred,
so most likely a badly seated card. (Recovering from it by rebinding the
SD driver took the eMMC down: docs/board-and-tooling.md.)

Not verified: long runs (hours); the gateway answering ping (it ignores
ICMP from eth0 too).

### 802.1Q VLANs

At first this LAN's switch passed only VID 0 (delivered
untagged) and dropped every other VID; the user then set it to trunk VIDs
2700-2710. Before any VLAN code, tagged frames from eth1 left with their
tag intact, and tagged frames for eth1 were discarded at port 5's ingress
(`rx_port_discards`). With VLAN filtering in the driver
(`scripts/board/vlantest.sh`, eth0 VLAN devices as the far end):

- no eth1 VLAN device: VID 2700 filtered; eth1.2700 and .2705 created:
  those pass, 2710 does not; eth1.2705 deleted: closed again;
- loop test over eth1.2700 and .2705, 400/400 byte-exact each way (frames
  up to 1518 bytes with the tag), untagged traffic at the same time
  400/400;
- promiscuous on: an unregistered VID (2708) passes; off: closed again,
  2700 still open;
- IP over VLAN 2700 (eth1.2700 in a netns): ping 1472 bytes with DF
  20/20, TCP 924 Mbit/s out, 939 Mbit/s in;
- eth1.1 refused (Device or resource busy), as designed.

## CPU load (2026-10-05)

iperf3 between the board and the development host (one end off the board,
through the LAN's router, which caps the path at ~820-920 Mbit/s), CPU
from `/proc/stat` with `scripts/board/cpustat.py`. "busy" is of all four
A53 cores together (100 % = four cores); ~3 % is the idle baseline. eth0
(r8169soc, SG/checksum/TSO offload on) is the reference.

| Test | eth0 | eth1 (rtd1295-hwnat) |
|---|---|---|
| TX at 700 Mbit/s | 27.2 % busy, 6.3k irq/s | 30.5 %, 4.6k irq/s |
| TX, unlimited | 826 Mbit/s, 21.1 % | 878 Mbit/s, 23.2 %, 3.1k irq/s |
| RX at 700 Mbit/s | 25.6 %, 4.6k irq/s | 34.1 %, **49k irq/s** |
| RX, unlimited | 917-920 Mbit/s, 29-30 % | 887-900 Mbit/s, 41.6 %, **53k irq/s** |

Per core during unlimited RX (both NICs' interrupts land on CPU0):

| | CPU0 (IRQ + NAPI) | iperf3's core |
|---|---|---|
| eth0 | 70.7 % (softirq 67 %) | 33 % (sys 29 %) |
| eth1 | **95.8 %** (softirq 84 %, irq 11 %) | 60 % (sys 49 %) |

- TX costs about what eth0's does, without any offload.
- RX costs ~35-40 % more and leaves CPU0 nearly saturated at ~900 Mbit/s.
  Two causes visible: an interrupt per few frames (no mitigation: 53k/s
  against eth0's 8k/s), and checksums computed in software
  (`CHECKSUM_NONE`), which shows as the receiving process's extra sys time
  (checksum-and-copy).
- So the worthwhile work is interrupt mitigation and RX checksum
  (`CHECKSUM_UNNECESSARY` when the core's L3/L4 flags say OK). TX
  checksum/TSO is not needed for throughput.

### After interrupt mitigation and RX checksum (same day)

Defaults RX 32 frames / 200 us, TX 32 / 400 us, RX checksum on:

| Test | before | after | eth0 |
|---|---|---|---|
| RX, unlimited (~900 Mbit/s) | 41.6 % busy, CPU0 95.8 %, 53k irq/s | ~31-32 %, CPU0 ~68-71 %, 12-14k irq/s | 29-30 %, CPU0 70.7 %, 8k irq/s |
| RX at 700 Mbit/s | 34.1 %, 49k irq/s | 30.5 %, 9.9k irq/s | 25.6 % |
| TX, unlimited | 878 Mbit/s, 23.2 % | 871-908 Mbit/s, 22.6 %, 6k irq/s | 826 Mbit/s, 21.1 % |
| ping eth0 -> eth1, 10 ms apart | 0.30 ms avg | 0.30-0.31 ms avg | |

RX now costs about what eth0's does; CPU0 has headroom at line rate.
Throughput through the router varies run to run by ±40 Mbit/s for both
NICs alike (three alternating runs: eth1 841/903/917, eth0 899/904/869).
512 RX descriptors instead of 256 changed nothing (no port discards
either way), so 256 stays.

## Findings

- **Descriptor format.** Out of reset `CPUICR1.CF_PKT_HDR_TYPE` = 0
  selects the older RTL8198C layout. With the six-word descriptors still
  written, the core took descriptor 0, sent a 1538-byte frame with a bad
  FCS into the switch, and stopped with `CPUTPDCR0` at ring base + 4.
  `CF_PKT_HDR_TYPE = 1` (`TX_PKTHDR_SHORTCUT_LSO`) fixes it.
- **The MAC manages the PHY unless told not to.** With `PCR.EnForceMode`
  = 0, the port polls the PHY at ExtPHYID and `PCR[22:16]` is its
  advertisement (out of reset: all speeds, pause). Next to phylib this
  dropped the link a second after it came up, and it renegotiated down to
  100 Mbps; once it dropped in the middle of a TCP transfer for 11 s.
  Force mode with `PollLinkStatus` = 0, link/speed/duplex from phylib.
- **ExtPHYID routes MDIO.** Pointing port 5's ExtPHYID at an unused
  address (so the MAC would poll nothing) made every MDIO read of
  address 1 return 0: the MDIO controller drives the pins of the port
  whose ExtPHYID matches. It must stay the PHY's address.
- **EEE.** The RTL8211F advertises EEE by default and phylib keeps that;
  the link then dropped once ~1 s after coming up, every time. The driver
  calls `phy_disable_eee()` (the MAC has `EEECR` = 0 anyway).
- **Stopping must not clear `SSIR.TRXRDY`.** The first stop path cleared
  it, as Realtek's `rtl865x_down()` does. Every `ip link set down/up` (and
  every move to another network namespace, which closes the device) then
  left the switch worse: TCP 938 -> 300 -> 0 Mbit/s over successive
  cycles, while the sparse loop test still passed. Probably packet
  buffers lost in the switch when it is stopped mid-flight. Stopping only
  the CPU interface fixed it (5/5 cycles at line rate since).
- **Pause works -- the earlier verdict was wrong.** It had been taken off
  after TCP stalls and lost/corrupted frames with flow control on (one
  60-byte frame arrived as 1514 bytes). Those runs had gone through
  namespace moves, so through the `SSIR` stop above. With that fixed,
  pause behaves (see "Verified") and is on by default.
- **TX completion by owner bit.** Realtek reclaims TX descriptors up to
  the current-descriptor pointer (`CPUTPDCR0`). That pointer reads the
  ring's base once TX is stopped, so the driver reclaimed descriptors the
  core still owned: TX turned into a silent black hole and the watchdog
  never fired. The core clears the owner bit of each sent descriptor;
  ours are coherent memory, so the driver goes by that.
- **The netdev watchdog only fires with the queue stopped.** After the
  induced TX stall, TCP backed off and never filled the ring (93 of 256
  pending), so no timeout for as long as the test ran. Any real load
  fills the ring; the test filled it with raw frames.
- **Interfaces chosen by port, not VLAN.** A frame addressed to the
  interface reaches the CPU through the netif table. With the decision by
  VLAN, a frame on VID 2700 needed a netif entry for VLAN 2700: ARP replies
  on the VLAN were discarded, and there are only eight entries. By port
  (`SWTCR0` = port based, `PLITIMR` port 5 -> netif 0), one entry covers
  every VID on the port.
- **"TCP runs slower after a link change" -- what it really was**
  (2026-10-05, corrects an earlier note that blamed this LAN; the eth0
  comparison behind it never renegotiated eth0: r8169soc does not support
  `ethtool -r`):
  - phylib polls the PHY once a second (the RTL8211F's INTB pin is not
    wired), so a link drop is noticed up to 1 s late; frames sent
    meanwhile are lost. Normal for a polled PHY.
  - After the link really comes up, nothing passes for 0-0.32 s on eth1,
    both directions at once, outside the MAC (`scripts/board/linkup-trace.py`).
    eth0 (r8169soc, `ip link down/up`) shows 0.58-0.78 s. Link settling,
    not a driver fault.
  - Without any link event, 3-s TCP tests still varied: an occasional
    single retransmission costs hundreds of ms of a 3-s run. Some were
    tail-loss probes the receiver answered with D-SACKs (nothing lost: an
    ACK came late), some real single-segment losses. Both NICs share CPU0
    for their interrupts in these board-to-board tests.
  - UDP "loss" at 900 Mbit/s was never the network: with frame accounting
    at every layer, the receiver's socket buffer (`UdpRcvbufErrors`) or the
    sender's qdisc (eth0 or eth1, iperf3 bursting) accounts for it; what
    the sending driver hands over equals what port 5 sends, and what eth0
    sends equals what port 5 receives.
  - What is left on the wire: **port 5 receives a few frames with bad FCS**,
    0 to 14 per 800k at 900 Mbit/s (10^-6 to 10^-5), with no symbol
    errors and the PHY's idle-error counter at 0. RGMII RX timing sweep
    (PHY RX delay on/off x MAC RCOMP 0/1.5/2/2.5 ns): the current setting
    (PHY on, MAC 0) is the best; Schmitt triggers on the RX pads made no
    clear difference. **Resolved: the cable or switch port.** With another
    cable and port: 0 FCS errors in 4 x 30 s at 900 Mbit/s (9.6 M frames).
  - On the new cable, six 30-s runs of 900 Mbit/s UDP towards eth1 with
    every layer counted (`scripts/board/udp-account.sh`): port 5 received
    exactly what the driver delivered, every run; no switch discards; the
    only losses were eth0's qdisc and the receiving socket's buffer (one
    run: 649 + 3259 = 3908, the loss iperf3 reported).
- **The CPU port's MIB counts every frame from the DMA as an FCS error**
  (its "in" side, `fcs_err` = `rxdv`), apparently because the FCS is
  appended later. Not a fault.
- `dot1dTpPortInDiscards` on port 5: 339 out of 2.55 M frames under the
  concurrent test (before mitigation), presumably while RX ring 0 was
  full. None in the TCP runs after mitigation.
- **RX checksum flags** (checked with frames broken on purpose,
  `scripts/board/badcsum.py`): `opts3[31:29]` is the type (5 TCP, 6 UDP,
  3 ICMP and ICMPv6, 0 other, e.g. ARP), `opts4` bit 8/9 IPv4/IPv6, bit 11
  fragment. The core checks the IPv4 header and TCP/UDP checksums over
  IPv4 and IPv6 and clears `opts5` bit 31 (L3) or 30 (L4) when one is
  wrong. It still passes such frames to the CPU, `CSCR`'s "do not
  forward" bits notwithstanding. It leaves the L4 flag set on fragments,
  and a UDP checksum of 0 counts as OK.
- **Interrupt mitigation registers** (no field definitions in the SDK;
  inferred from Realtek's values and checked): ten sources, RX rings 0-5
  and TX rings 0-3. `CPUIMCR` bit n enables RX ring n, bit 8 + n TX ring
  n. `CPUIMTTR0-3`: 10-bit timeouts in 512 ns units, three per register
  in source order. `CPUIMPNTR0-2`: frame counts one per byte, RX 0-3,
  RX 4-5, TX 0-3, **6 bits wide**: 64 reads as 0 and the interrupt fires
  continuously (an interrupt storm, 223k/s). The timeout acts like a
  minimum gap between interrupts: a lone frame is not delayed (ping
  unchanged).
- **TX completion interrupt.** "TX ring all done" (`CPUIISR` bit 1) is
  not mitigated, and during TCP RX the ring empties after every ACK:
  27k interrupts/s whatever the settings. "One frame done" (bit 9) is
  mitigated; the driver uses that.
- The core did not need the NAT SRAM power domain or PLLDDSB touched (both
  on already), nor `rtl865x_enableDevPortForward()`'s ForceLink toggling,
  nor any ACL.

## MAC address

Neither RJ45 has an address of its own. u-boot leaves 00:10:20:30:40:50
(CONFIG_ETHADDR) on every board; r8169soc and rtd1295-hwnat fall back to a
random address. The efuse's 96-bit `uuid` cell (0x98017000 + 0x1a4, the
BSP DT's `efuse_uuid`) reads all zero on this board (2026-10-05; other
efuse words read fine), so the SoC offers no per-board ID to derive one
from.

The driver takes `local-mac-address`/`mac-address`/`nvmem-cells` from DT
(`of_get_ethdev_address()`), else a random one, and supports changing it,
live (`ndo_set_mac_address` rewrites netif entry 0, through which frames
for us reach the CPU; verified: loop test clean after a live change).

Tried and dropped (2026-10-05): eth1 = eth0 + 1 through a udev rule and a
script in a PiKVM-style overlay (commit f7bf81a). It worked on two loads
(same address, same DHCP lease), but it ties the feature to one userland,
which this project avoids (AGENTS.md, "Scope"). eth0's address in the
PiKVM image comes from udev and machine-id too, so the kernel cannot
derive from it at probe.

The mainline way to get "eth0, and eth0 + 1" is DT only: a `mac-base`
nvmem cell referenced by both nodes with offsets 0 and 1
(`nvmem-cells = <&macaddr 0>` / `<&macaddr 1>`), filled from a per-board
store the boot loader or a factory partition provides (for example
u-boot's environment `ethaddr` through the `u-boot,env` nvmem layout).
That needs a per-board address stored somewhere first: the user's call,
as it means writing the boot loader's environment or a partition.

**Decision (2026-10-05): for now the kernel keeps a random address**,
marked `NET_ADDR_RANDOM`, as mainline does for boards with no stored
address; the distribution makes it stable (OpenWrt's own configuration,
systemd's `MACAddressPolicy=persistent` on Ubuntu). The `mac-base` way is
for later, once the boot loader and distribution are chosen.

## Open

- MAC address: random by decision for now; `mac-base` from a per-board
  store later (see "MAC address").
- TX checksum/TSO: not needed for throughput (TX costs what eth0's
  does); the descriptor fields are known (`TD_L3CS`/`TD_L4CS`, `TD_LSO`)
  if CPU on TX ever matters.
- RX VLAN tag stripping (`NETIF_F_HW_VLAN_CTAG_RX`): the stack strips the
  tag in software now; the descriptor carries the VLAN fields if it ever
  matters. 802.1ad (S-tags) not tried.
- Remove what is only for bring-up before upstreaming (`nat_dump()`, the
  debugfs file).
- A permanent node: `dts/nat-eth.dtsi` into a board DTS (into the PiKVM
  image's only if the user wants it there).

A USB 3.0 gigabit adapter remains the no-driver alternative: the PiKVM
image has `r8152` and `ax88179_178a`.
