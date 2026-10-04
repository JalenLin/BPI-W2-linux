# The second RJ45 (hardware NAT engine)

Status (2026-10-04): surveyed, not started. The first survey (2026-09-17)
is `docs/06-changes.md` §11 on the `main` branch of `../bpiw2_pikvm`
(`git -C ../bpiw2_pikvm show main:docs/06-changes.md`). The facts that
matter are below.

## Hardware

The two RJ45 sockets are driven by two different MACs:

| Socket | MAC | PHY | State |
|---|---|---|---|
| Next to the USB ports | `gmac@98016000` (`r8169soc`, PiKVM patch 0008) | the SoC's embedded gigabit PHY (`ETN_MDI*`) | works, `eth0` |
| The other one | MAC0 of the hardware NAT engine, `0x98060000` | an external RTL8211F over RGMII0 | no driver |

Schematic page 12 ("HWNAT_0"): `RGMII0_*` (RXC, RXCTL, RXD0-3, TXC, TXCTL,
TXD0-3, MDIO/MDC) to the RTL8211F, whose line side is `NAT0_MDI0-3`.
Page 11 ("GBE") has a 20-pin header (CON5) with `RGMII1_*`: a second RGMII
that BPI leaves to expansion.

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

- skip that step, and bring up only MAC0 on RGMII0 with the external
  RTL8211F;
- run the switch core with just the CPU port and port 0, and forward
  everything between them (no NAT, no L2 offload).

Also in the same file: `hwnat_mac0_enable` is commented "0: interface used
by SATA, 1: interface used by NAT", and a `sata_func_exist_0` reset is
handled there. So MAC0 and SATA share something (see sata.md).

## Approach

1. Map out the minimum from `rtd129x_clk.c` (clock, reset, power for NAT,
   minus the GPHY switch) and `rtl819x_switch.c` / `swNic.c` (core reset,
   port 0 as RGMII with the PHY address, CPU port, VLAN/L2 so frames reach
   the CPU, the RX/TX rings).
2. Write a small netdev driver with `phylink` or `phylib` for the RTL8211F
   (mainline `realtek` PHY driver) over the NAT block's MDIO.
3. Test with a cable in the second socket, `eth0` staying up the whole time.

A USB 3.0 gigabit adapter works today without any of this: the PiKVM image
has `r8152` and `ax88179_178a`.

## Tried

Nothing beyond reading.
