# The second RJ45 (hardware NAT engine)

Status (2026-10-05): bring-up sequence mapped (clocks, resets, pads, PHY);
switch core and CPU rings being read. No code yet. A cable is in the second
socket. The first survey (2026-09-17)
is `docs/06-changes.md` §11 on the `main` branch of `../bpiw2_pikvm`
(`git -C ../bpiw2_pikvm show main:docs/06-changes.md`). The facts that
matter are below.

## Hardware

The two RJ45 sockets are driven by two different MACs:

| Socket | MAC | PHY | State |
|---|---|---|---|
| Next to the USB ports | `gmac@98016000` (`r8169soc`, PiKVM patch 0008) | the SoC's embedded gigabit PHY (`ETN_MDI*`) | works, `eth0` |
| The other one | **port 5 (MAC5)** of the hardware NAT engine, `0x98060000` | an external RTL8211F over RGMII0, MDIO address 1 | no driver |

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
  per the BSP. `PHYRSTB0` has a 4K7 pull-up to 0_DVDD33 and no GPIO found
  driving it: no hardware reset line for the PHY.

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
| ... MAC5: `PCRP5.ExtPHYID = 1`; `PITCR` port 5 = GMII/MII/RGMII; `P5GMIICR.CFG_GMAC = RGMII`; `rtd129x_phy_8211f_init(1)`; RTL8211F page 0xd08 reg 17 bit 8 (TX delay) | Keep. Leave the RTL8211F setup to the mainline `realtek` PHY driver with `phy-mode = "rgmii-txid"`, after checking that it matches (CLKOUT off, SSC, TX delay). |
| probe: interrupt mitigation `CPUIMTTR0..3`, `CPUIMPNTR0..2`, `CPUIMCR` | Keep (or NAPI with mitigation off at first). |

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
| `rtl_nic.c` | 28,439 | The netdev driver (most of it router features) |
| `rtl865xc_swNic.c`, `.h` | 2,761 | The CPU port's descriptor rings (RX/TX via mbuf/pkthdr) |
| `rtl819x_switch.c` | 535 | Switch setup |
| `AsicDriver/rtd129x_clk.c` | 914 | Clocks, resets, power for the NAT block |
| `AsicDriver/rtl865x_asicCom.c`, `rtl865x_asicL2.c` | 2,247, 11,669 | Switch core registers, L2 tables |

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

## Approach

1. Map out the minimum from `rtd129x_clk.c` (clock, reset, power for NAT,
   minus the GPHY switch) and `rtl_nic.c` / `swNic.c` (core reset,
   port 5 as RGMII with the PHY address, CPU port, VLAN/L2 so frames reach
   the CPU, the RX/TX rings).
2. Write a small netdev driver with `phylink` or `phylib` for the RTL8211F
   (mainline `realtek` PHY driver) over the NAT block's MDIO.
3. Test with a cable in the second socket, `eth0` staying up the whole time.

A USB 3.0 gigabit adapter works today without any of this: the PiKVM image
has `r8152` and `ax88179_178a`.

`rtl819x_switch.c` turned out to be only the OpenWrt swconfig interface;
the switch setup is in `rtl_nic.c` (`re865x_probe()`: clocks, then
`rtl865x_initAsicL2()`, `rtl865x_init()`, `rtl865x_config(vlanconfig)`,
then the rings in `re865x_open()` -> `rtl865x_init_hw()` ->
`RTL_swNic_init()`). No smaller copy of this driver exists in BPI's trees
(u-boot and the BSP 4.9 kernel have none).

## Tried

Nothing beyond reading.
