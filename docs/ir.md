# IR receiver

Status (2026-10-05): **works on the board** (`kernel/src/rtd1295-ir.c`,
rc-core, raw mode), tested with an air-conditioner remote, through
the development overlay and from the board DTB. Builds clean (`W=1`,
checkpatch --strict). DT in `dts/ir.dtsi`, binding validated. Needs an IR
remote to test: any household remote works (NEC, RC-5, RC-6 and Sony are
decoded).

## Hardware

- The IR unit at `0x98007400` (0x100) in the ISO block (`iso: syscon@7000`
  in mainline, so the node is `ir@400` under it). The BSP node also maps
  the whole ISO block, `0x98007000` (0x400); not needed.
- Interrupt: ISO interrupt mux line 5 (`&iso_irq_mux 5`, "IrDA" in
  `irq-rtd129x.c`).
- Clock gate: ISO `CLK_EN` bit 7 (`<&iso_clk 7>`). Reset: ISO reset 1
  (`RTD1295_ISO_RSTN_IR`). The sampling clock divides the 27 MHz crystal
  (`&osc27M`): the BSP computes its divider as `us * 27 - 1`.
- Pin: IR_RX is ISO pin 8, `ISO_MUXPAD0` (`0x98007310`) bits 7:6,
  function 1 (BSP `pinctrl-rtd129x.h`); `&iso_pinmux` (pinctrl-single)
  takes it as `<0x0 0x40 0xc0>`. IR_TX (bits 9:8) goes to the 40-pin
  header (pin 22) and is not used here.
- On the running board (read-only, 2026-10-05): the IR reset asserted
  (`0x98007088` = `0x3fe0`, bit 1 clear), its clock off (`0x9800708c` =
  `0x1d79`, bit 7 clear), the pin a GPIO (`0x98007310` bits 7:6 = 0). The
  boot loader and PiKVM leave it alone.

## Registers

From Realtek's `iso_reg.h` (`drivers/video/fbdev/rtk/dc2vo/fpga/include/`
in the BSP tree; `ISO_IR_*`) and the BSP driver:

| Offset | Name | Fields used |
|---|---|---|
| 0x08 | `IR_SF` | sampling clock divider: 27 MHz / (SF + 1); 0x437 = 40 us |
| 0x10 | `IR_CR` | 31 soft reset; 14 raw overflow IE, 13 raw data IE, 12 raw enable; 10 hardware-decoder IE; 9 `irres`; 8 unit enable |
| 0x18 | `IR_SR` | 3 raw FIFO overflow, 2 raw FIFO data, 1 repeat, 0 hardware data valid |
| 0x1c | `IR_RAW_CTRL` | 25 write enable for 24:8; 24 stop sampling; 23:8 stop time (samples after the last edge); 6 write enable for 5:0; 5:0 FIFO threshold (words) |
| 0x20 | `IR_RAW_FF` | FIFO: 32 samples per word, earliest in bit 31, 0 = carrier present |
| 0x28 | `IR_RAW_WL` | 5:0 words in the FIFO |
| 0x2c | `IR_RAW_DEB` | 15:0 debounce, in 27 MHz clocks |

The BSP's raw settings (its software-decoder mode, used for Comcast):
`SF` 0x437, `RAW_DEB` 0x21b (20 us), `RAW_CTRL` 0x03138850 (stop after
5000 samples = 200 ms, interrupt at 16 words = 20 ms of samples), `CR`
0x7300. Its interrupt handler writes `SR & ~0xf` back (the raw flags are
not written: they seem to clear as the FIFO is read) and reads `RAW_WL`
words. The sample format follows from its Comcast decoder: runs of 0s are
marks, of 1s spaces, and its symbol lengths (760 + n * 136 us) match 19-70
samples of 40 us.

## The driver

Raw mode only; rc-core decodes. Bits are turned into runs and stored with
`ir_raw_event_store_with_filter()`, carried across words and interrupts.
Runs go to `ir_raw_event_store_with_filter()`, which merges a run with
the previous one of the same kind and enters idle once a space reaches
`rc->timeout` (default 125 ms).

**The unit never stops sampling by itself.** Sampling starts at the first
edge after the unit leaves reset, then runs on: 16 words of all-space
every 20 ms, 50 interrupts a second, forever. `stop_time`/`stop_sample`
(the stop bit does not even read back), the soft reset (`CR` bit 31),
toggling `raw_en`, and a full re-init after a soft reset all left it
running. Only the unit's reset line (ISO reset 1, the IR's alone) puts it
back to waiting for an edge. So when rc-core enters idle (`s_idle`), a
work item pulses that reset and sets the unit up again: 6 interrupts per
button press, none in between. Removal first stops the rearm (flag,
`disable_irq`, `cancel_work_sync`) so nothing touches the unit after its
clock is off. Overflow: `ir_raw_event_overflow()`.
`linux,rc-map-name` picks a keymap (default `rc-empty`: scancodes only).

The BSP's hardware NEC decoder, its key table, sysfs and chardev
interfaces, IR TX, and the wake-up keys it hands to the audio CPU's
firmware through shared memory for suspend are left out.

## Testing it: a development rc-core

The board's kernel has rc-core as a module, but no protocol decoders and
no LIRC. Decoders cannot simply be added: their state is in rc-core's
`struct ir_raw_event_ctrl`, whose members exist only with the matching
`CONFIG_IR_*_DECODER` (and `struct rc_dev` changes with `CONFIG_LIRC`). So
`scripts/build-rc-dev.sh` copies rc-core (with `lirc_dev.c`) and the NEC,
RC-5, RC-6 and Sony decoders from the kernel tree into
`rc-dev/` of the debug tools, whose Kbuild builds
them and the driver with one set of options. They load from `/root` with
`insmod` instead of the board's `rc-core.ko` (not loaded by anything on
the PiKVM image). A driver built that way only works with that rc-core:
This kernel now has the decoders and LIRC itself (`kernel/configs/`), so
the development rc-core is only needed for the PiKVM kernel the board ran
while the driver was written.

```sh
scripts/build-rc-dev.sh; scripts/build-overlay.sh ir     # debug tools
# (debug tools) copy rc-dev/*.ko to /root, then on the board:
sh /root/ir-up.sh          # rc-core, decoders, overlay, driver; all protocols on
python3 /root/ir-watch.py 30   # raw pulses from /dev/lirc0, scancodes, keys
sh /root/ir-up.sh down
```

With an air-conditioner remote (the one at hand, 2026-10-05): its
frames carry the whole state, often 100-200+ bits in a vendor protocol, so
rc-core's decoders give no scancode. `ir-watch.py` decodes any
pulse-distance frame (equal marks, short/long spaces: NEC and most
air-conditioner remotes) into bytes, LSB first. Pass criteria: the same
button twice gives the same bytes (nothing dropped or shifted across the
FIFO interrupts of a long frame), one step of temperature changes only a
byte or two, and mark/space widths sit at the protocol's values within a
sample (40 us). A TV remote would add an end-to-end scancode test.

Development overlay: `overlays/ir/ir-overlay.dtso.in` (the pin group under
`iso_pinmux`, the node under `iso`), phandles filled by
`scripts/build-overlay.sh ir` (ISO clock 9, reset 8, IRQ mux 7, osc 6 on
2026-10-05).

## Binding

`dts/bindings/media/realtek,rtd1295-ir.yaml` (`rc.yaml` for
`linux,rc-map-name`): yamllint, dt-doc-validate and its example clean; a
missing clock name and a bogus property are reported. The board DTB with
`dts/ir.dtsi` builds and validates.

## Tried

2026-10-05, development overlay, development rc-core, an
air-conditioner remote:

- Probe: `rc0` with `/dev/lirc0` and an input device; the registers read
  back as written (`SF` 0x437, `CR` 0x7300, `RAW_DEB` 0x21b, `RAW_CTRL`
  0x00138810: the write-enable bits and `stop_sample` read 0); pin in
  `ir_rx`, clock and reset on. No interrupt until the first button.
- Frames: header 3280/1560 us, marks 480-560, spaces 320/1200-1240 us,
  72 bits, pulse-distance. Temperature up, down, up:
  `0c fd fc fc f8 38 fc 04 41`, `... d8 fc 04 a1`, `... 38 fc 04 41` --
  the first and third identical bit for bit, and identical to the same
  buttons pressed in an earlier session and driver load. (No checksum
  matched LSB first; see below for MSB first.) rc-core decodes no
  scancode from it, as expected.
- First version: sampling never stopped after a press (50 interrupts/s,
  words all space, so no noise on the line), and calling
  `ir_raw_event_set_idle()` after rc-core's filter had already entered
  idle stored an empty event ("nonsensical timing event of duration 0",
  "two consecutive events of type space"). Both fixed as described in
  "The driver"; no warning since.
- Unload and reload: IR reset asserted again (`0x98007088` back to
  0x3fe0), its clock gate off; reload clean, 0 interrupts idle.

- **From the board DTB** (`dts/ir.dtsi`, installed 2026-10-05): probes
  without the overlay, pin in `ir_rx`, no interrupt while idle. Down
  then up: `... f8 58 fc 04 21`, `... f8 d8 fc 04 a1`.
- **The frames decoded**: the protocol is MSB first. Bit-reversed, byte 6
  is the temperature in degrees C (0x1a 26, 0x1b 27, 0x1c 28), and the
  last byte is the XOR of the other eight, XOR 0x11 -- it holds in all
  three temperatures captured (26: 0x95 ^ 0x11 = 0x84; 27: 0x85; 28:
  0x82). Any wrong bit among the 72 would break it: the capture is
  bit-exact, through both the overlay and the DTB, across driver loads.

Not done: a remote that rc-core decodes (a TV remote: NEC/RC-5/RC-6/Sony
scancodes end to end).
