# IR receiver

Status (2026-10-04): not started. No mainline driver. No remote to test
with yet.

## Hardware

- The IR block at `0x98007400` (0x100) in the ISO domain. The BSP node also
  maps the whole ISO block, `0x98007000` (0x400).
- Interrupt: ISO interrupt mux line 5 (mainline: `&iso_irq_mux` 5).
- Clock: ISO clock 7 (`<&iso_clk 7>` in the PiKVM DTS's numbering).
  Reset: ISO reset 1.
- The receiver module (IR-3PIN) is on schematic page 13 ("GPIO"), net
  `IR_RX`. `IR_TX` goes to the 40-pin header (pin 22, ISO GPIO 9).
- Pin mux: the IR_RX pad's function; see `ir_rx_pins` in
  `rtd-1295-pinctrl.dtsi`. The PiKVM DTS has a small `pinctrl-single` for
  ISO_MUXPAD0/1 (`&iso_pinmux`) that can take the IR pins as well.

## The BSP

| File | What |
|---|---|
| `drivers/net/irda/realtek/rtk_irda.c`, `irda_sw_decoder.h`, `rtk_irda.h` (1727 lines together) | Hardware NEC decoding and a software decoder for raw timings; input device with a keymap |
| `arch/arm64/boot/dts/realtek/rtd129x/rtd-1295-irda.dtsi` | The node |

The W2's settings (preprocessed tree, `irda@98007400` / `irda_rx0`): NEC,
`transcode-mode = <1>`, customer code 0x7f80, scancode mask 0x00ff0000,
customer mask 0x0000ffff, `reg-ir-dpir = <50>`, `sample-rate = <40>`, and a
ten-key keymap for BPI's remote.

## Things to know before starting

- Mainline approach: an rc-core driver (`drivers/media/rc/`). Prefer raw
  mode (pulse/space timings into `ir_raw_event_store()`) so every protocol
  rc-core knows works. The hardware NEC decoder (`RC_DRIVER_SCANCODE`) is
  the fallback if raw sampling is not available.
- `meson-ir.c` and `sunxi-cir.c` are good small models.
- PiKVM itself has no use for it. It is for other users of the board.

## Tried

Nothing yet.
