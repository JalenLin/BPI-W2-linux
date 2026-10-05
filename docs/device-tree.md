# Device tree: how a driver here gets its node

Written for the second RJ45 (`kernel/src/rtd1295-hwnat.c`), the first driver done
this way; the same steps apply to SATA, PCIe and IR. Everything below was
run on 2026-10-05.

There are three stages, each with its own files:

| Stage | What | Files | Touches the board's boot partition? |
|---|---|---|---|
| 1. Develop | the node as a runtime overlay, loaded and removed with a module | `overlays/<name>/<x>-overlay.dtso.in`, `scripts/build-<name>-overlay.sh`, `drivers/<name>/*-overlay.c` | no |
| 2. Permanent | the node in a board DTS | `dts/<name>.dtsi` | yes: a new DTB has to be installed (ask first) |
| 3. Upstream | binding + SoC node + board node | `dts/bindings/...yaml`, a split of `dts/<name>.dtsi` | -- |

## The node, property by property

`dts/nat-eth.dtsi`:

```dts
&rbus {
	nat: ethernet@60000 {
		compatible = "realtek,rtd1295-hwnat";
		reg = <0x60000 0x170000>;
		interrupts = <GIC_SPI 24 IRQ_TYPE_LEVEL_HIGH>;
		clocks = <&crt_clk 32>;			/* CLK_EN2 0: NAT */
		resets = <&reset1 RTD1295_RSTN_NAT>;
		realtek,sb2 = <&sb2>;			/* RGMII0 pad control */
		/* the RTL8211F's RX delay is strapped on, TX delay is set by its driver */
		phy-mode = "rgmii-id";
		phy-handle = <&nat_phy>;

		mdio {
			#address-cells = <1>;
			#size-cells = <0>;

			nat_phy: ethernet-phy@1 {
				reg = <1>;
				realtek,clkout-disable;
			};
		};
	};
};
```

| Property | Value | Why |
|---|---|---|
| parent | `&rbus` | `bus@98000000`, `ranges = <0x0 0x98000000 0x200000>`: children use offsets. 0x60000 + 0x170000 still fits in the 2 MiB window. |
| `reg` | 0x170000 bytes | As the BSP: the tables start at the base, the CPU interface is at +0x160000, MIB, MAC and port registers follow up to +0x165fff, then the SerDes and NAT wrappers at +0x168000-0x16afff (unused here, but part of the block). One range: the driver claims it, nothing else maps it. |
| `interrupts` | GIC SPI 24, level | The BSP's `interrupts = <0 24 4>`; straight to the GIC, not through an interrupt mux. |
| `clocks` | `<&crt_clk 32>` | The PiKVM CRT gate driver numbers CLK_EN1 bits 0-31 and CLK_EN2 bits as 32 + n; the NAT gate is CLK_EN2 bit 0. |
| `resets` | `<&reset1 RTD1295_RSTN_NAT>` | SOFT_RESET1 bit 1. The only reset the driver takes. Not the ISO GMAC/GPHY resets (eth0's) and not the SATA/SerDes ones (MAC0's SGMII path). |
| `realtek,sb2` | `<&sb2>` | The RGMII0 pad mux, slew and drive registers are at SB2 0x960-0x96c. A syscon phandle, as eMMC and eth0 already use under the same name. |
| `phy-mode` | `"rgmii-id"` | Both RGMII delays in the PHY. The RTL8211F's RX delay is strapped on; with `rgmii-txid` the mainline driver turns it off and every received frame fails its FCS. MAC side: no compensation (`P5GMIICR` RCOMP/TCOMP 0), which a sweep showed is the best setting. |
| `mdio` / `ethernet-phy@1` | address 1 | The strap pins give address 1. The switch's MDIO controller routes by port (the port whose ExtPHYID matches), so this bus only reaches port 5's PHY. |
| `realtek,clkout-disable` | | The PHY's CLKOUT pin is unused; Realtek's driver turns it off too. |

Not in the node, on purpose: a MAC address (none stored per board; random
until a `mac-base` nvmem cell exists, see second-ethernet.md); EEE and pause
settings (the driver handles them); the embedded GPHY (eth0's).

## The binding

`dts/bindings/net/realtek,rtd1295-hwnat.yaml`: `ethernet-controller.yaml`
plus `mdio.yaml`, everything required except the PHY's own properties,
`unevaluatedProperties: false`. Validate with the kernel's tools in the
build container (dtschema 2026.9 there). The binding must sit inside a
bindings tree for its relative `$ref`s to resolve, so work on a copy:

```sh
docker run --rm -v "$PIKVM:/work:ro" -v "$PWD:/ext:ro" bpiw2-pikvm/builder-mainline:trixie sh -c '
  K=/work/vendor/linux-mainline
  cp -r $K/Documentation/devicetree/bindings /tmp/b
  cp /ext/dts/bindings/net/realtek,rtd1295-hwnat.yaml /tmp/b/net/
  yamllint -c /tmp/b/.yamllint /tmp/b/net/realtek,rtd1295-hwnat.yaml
  dt-doc-validate -u /tmp/b /tmp/b/net/realtek,rtd1295-hwnat.yaml
  dt-mk-schema -j /tmp/b > /tmp/s.json
  dt-extract-example /tmp/b/net/realtek,rtd1295-hwnat.yaml > /tmp/ex.dts
  cpp -nostdinc -I $K/include -I $K/scripts/dtc/include-prefixes -undef -D__DTS__ \
      -x assembler-with-cpp /tmp/ex.dts > /tmp/ex.pre && $K/scripts/dtc/dtc -q -O dtb -o /tmp/ex.dtb /tmp/ex.pre
  dt-validate -s /tmp/s.json /tmp/ex.dtb'
```

Results: yamllint and dt-doc-validate clean; the example and the board DTB
below validate. To be sure the schema is actually applied: an example with
`phy-mode = "sgmii"`, a bogus property and no `mdio` gets all three
reported.

## Stage 1: runtime overlay (development)

The board's DTB has no `__symbols__`, so an overlay cannot refer to
`&crt_clk` and friends by label. It carries the running board's phandle
numbers instead:

1. `overlays/nat-eth/nat-overlay.dtso.in` is the node with placeholders
   (`@GIC@`, `@CRT_CLK@`, `@RESET1@`, `@SB2@`, `@PHY_MODE@`), under
   `target-path = "/soc@0/bus@98000000"`.
2. `scripts/build-overlay.sh nat-eth` (debug tools; `PHY_MODE=`) reads each phandle from the
   board (`/proc/device-tree/<path>/phandle`) and writes
   `nat-overlay.dtso` (generated, gitignored).
3. kbuild compiles the `.dtso` to a `.dtbo` and wraps it in an object
   (`nat-overlay-mod-y := nat-overlay.o nat-overlay.dtbo.o`).
   `nat-overlay.c` applies it with `of_overlay_fdt_apply()` on insmod and
   removes it on rmmod. dtc warns that the numeric cells are not phandle
   references; expected.
4. Load the overlay module, then the driver; the platform bus creates
   `98060000.ethernet` and binds it. `board/nat-up.sh` does both.

Phandles of the live tree (2026-10-05): GIC 1, `crt_clk` 13, `reset1` 15,
`sb2` 17. They only change with a new board DTB: re-run step 2 then.

For the next driver: copy the three files, change the node and the
phandles the script looks up.

## Stage 2: the node in a board DTS

Append the fragment to the board DTS (or `#include` it; the board DTS
already includes the GIC and RTD1295 reset headers it needs) and build
the DTB. Checked without touching the PiKVM repository, on a copy:

```sh
cp ../bpiw2_pikvm/kernel/mainline/rtd1296-bananapi-w2.dts /tmp/t/board.dts
cp dts/nat-eth.dtsi /tmp/t/
printf '\n#include "nat-eth.dtsi"\n' >> /tmp/t/board.dts
docker run --rm -v "$PIKVM:/work" -v /tmp/t:/t bpiw2-pikvm/builder-mainline:trixie sh -c '
  cd /work/vendor/linux-mainline
  cpp -nostdinc -I include -I arch/arm64/boot/dts/realtek -I scripts/dtc/include-prefixes \
      -undef -D__DTS__ -x assembler-with-cpp /t/board.dts > /t/board.pre.dts
  scripts/dtc/dtc -I dts -O dtb -o /t/board.dtb /t/board.pre.dts
  scripts/dtc/dtc -I dtb -O dts /t/board.dtb > /t/back.dts'
```

Result: builds (the only warning, about `hdmirx@34000`'s unit address, is
the board DTS's own); the node decompiles as intended (`clocks = <0x0d
0x20>`, `resets = <0x0f 0x01>`, `realtek,sb2 = <0x11>`, interrupt 0x18);
dt-validate against the binding passes. A full diff against the DTB the
board runs (both decompiled) shows the node and nothing else -- except
that the PHY node takes phandle 0x20 and every phandle from 0x20 up moves
by one (L2 cache, CPU clock, cpu-supply, OPP table, thermal trip). The
DTB stays consistent; only something holding numeric phandles from
outside would notice. The overlay's (1, 13, 15, 17) are below 0x20 and
unchanged. (An earlier version of this note said no phandle moved; it had
only looked at the low ones.)

Then, for a kernel image: the node goes into the board DTS of whichever
tree builds the image, and the driver into that kernel (`=m` or `=y`).
Installing a new DTB writes the boot partition **and, on an eMMC-booted
board, the eMMC's raw boot slot**: the eMMC's u-boot cannot read files
from the eMMC and loads the DTB from a raw slot at 16 MiB, which
`bpikvm-emmc-bootsync` (PiKVM) refreshes whenever the files under
`/boot/bananapi/bpi-w2/linux` change. A bad DTB is then not fixed by
renaming `.prev` back: it needs booting from an SD card and rewriting the
slot. So: diff the new DTB against the installed one first, **ask the
user**, keep `.prev`, and never reboot the board with an SD card in (it
would boot from the card).

Done on 2026-10-05: the new DTB (the node appended to the PiKVM board DTS,
uncommitted there) installed with `.prev` kept, bootsync wrote only the
DTB slot and its read-back matched; after a power cycle the board booted
from the eMMC, `ethernet@60000` came from the DTB, and the driver probed
without the overlay (link up at 1 Gbps, flow control rx/tx). Phandles of
the live tree then: GIC 1, `crt_clk` 13, `reset1` 15, `sb2` 17, `reset4`
25; the MISC GPIO controller has none. `scripts/install-dtb.sh` does the
same install with every check (`--rollback` puts `.prev` back).

Second install, same day: the board DTS also got `dts/sata.dtsi` and
`dts/ir.dtsi` (still uncommitted in the PiKVM repository). The diff
against the installed DTB showed the new nodes (`ir-rx-pins`, `ir@400`,
`phy@3ff00`, `sata@3f000`, `regulator-hdd-power`) and, again, renumbered
phandles: `ir-rx-pins` took 0x0b, so `crt_clk` is now 14, `sb2` 18 and so
on, and the MISC GPIO controller gained one (0x2a). Overlays built for
the old numbers must be rebuilt -- but with the nodes in the DTB the test
scripts skip the overlays anyway. Installed with `install-dtb.sh`
(read-back of the raw slot matched), rebooted, booted from the eMMC. In the PiKVM tree: `kernel/mainline/rtd1296-bananapi-w2.dts`, then
`make kernel-mainline` and `scripts/push-kernel-mainline.sh`
(docs/board-and-tooling.md, "Graduating a driver"); `CHECK_DTBS=1` runs
dt-validate there.

## Stage 3: upstream shape

Mainline splits SoC and board:

- the SoC's `rtd129x.dtsi` gets the node with everything that is the
  chip's (`reg`, `interrupts`, `clocks`, `resets`, `realtek,sb2`) and
  `status = "disabled"`;
- the board's `rtd1296-bananapi-w2.dts` enables it and adds what the board
  wires: `phy-mode`, `phy-handle`, the `mdio` node with the RTL8211F;
- the binding goes to `Documentation/devicetree/bindings/net/`, and the
  `realtek,sb2` property may want its own description in a common Realtek
  schema, since eMMC and the GMAC use it too.

Before that, mainline needs the pieces this node points at that only the
PiKVM tree has today: the CRT clock gate driver (`crt_clk`) and the SB2
syscon users.
