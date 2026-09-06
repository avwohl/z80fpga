# Nexys A7-100T

**The only target that has run on hardware.** On 2026-09-06 this booted on a
Nexys A7-100T and said:

```
z80fpga ready
banked memory ok
> Hello Z80
```

— banner, the bank check walking all eight RAM banks, the prompt, and then
`Hello Z80` typed from the host and echoed back through the UART. The Z80
fetched from ROM, banked memory under itself and drove the console, on a real
part.

## Build

```
cd boards/nexys_a7_100t
vivado -mode batch -source build.tcl
```

Same `xc7a100tcsg324-1` as the Arty, so the flow, the microcode ROMs and the
multicycle constraints are identical — see
[../arty_a7_100t/README.md](../arty_a7_100t/README.md) for what those
constraints are doing and
[../../docs/vivado_license.md](../../docs/vivado_license.md) for the licence
Vivado 2026.1 wants. Timing closes at WNS +1.038 ns, 0 of 2507 endpoints
failing, using about 3000 LUTs (4.7%), 393 registers and 72 block RAM tiles.

## The console, and the cable

One micro-USB does everything. The board's FT2232 is a two-channel part:
channel A is the JTAG the bitstream is programmed over, and channel B is a
USB-UART bridge that appears on the host as an ordinary serial port. So the
console is on the same cable you programmed with — 115200 8N1, no second
adapter, no jumper.

Program `build/z80fpga.bit` with Vivado's hardware manager, open the port, and
press `CPU_RESETN` to see the banner again. Configuration itself resets the
design, so re-programming with the port already open prints it too.

Note that the FPGA emits one spurious `00` byte as it configures, when the pin
stops floating and starts being driven. It is not a fault and not the design.

## If you have both boards, read this first

The Nexys A7-100T and the Arty A7-100T carry **the same
XC7A100T-CSG324 part**, and both put a 100 MHz oscillator on **E3**. An Arty
bitstream therefore loads onto a Nexys perfectly happily, reports
`End of startup status: HIGH`, and runs — silently and invisibly, because
every other pin is wrong. Nothing in the toolchain will warn you.

- **Console** — Nexys `C4`/`D4`, Arty `A9`/`D10`. On the wrong pinout the port
  stays dead.
- **LEDs** — Nexys `H17`/`K15`/`J13`/`N14`, Arty `H5`/`J5`/`T9`/`T10`. The
  Arty's LED pins land on the Nexys **seven-segment display**, so an Arty
  bitstream makes the 7-seg flicker and looks convincingly like it is working.
- **Reset** — Nexys has a dedicated active-low `CPU_RESETN` on `C12`; the Arty
  build uses `btn[0]`, active high. Get this one backwards and the core sits
  in reset forever.

The way to tell the boards apart without opening the case is the FTDI serial
number, which Vivado prints as the JTAG target: `210292…` is this board,
`210319…` is an Arty.

If a board is silent, bisect with a design that has no CPU in it at all — a
dozen lines that shift `0x55` out of the console pin forever. If `U` comes back
at 115200, the clock, the pin and the baud divisor are all good and the fault
is in the SoC; if nothing comes back, it is the pin or the board. That test is
what found this, after the full SoC and a minimal transmitter were equally
mute on `D10`.

## Configuration

- **Clock** 100 MHz on E3, Z80 at 100/12 = 8.33 MHz (`CPU_DIV` in `top.sv`).
- **Console** the USB-UART at 115200 8N1. `CPU_RESETN` resets.
- **Memory** 2 ROM banks (64 KB) and 8 RAM banks (256 KB) in block RAM.
- **LEDs and switches** four of each are wired, the low four of the SoC's byte.
  The board has sixteen; the rest are unconstrained.

Regenerate `sw/boot.hex` first if you changed the monitor:

```
python tools/zasm.py sw/boot.z80 -o sw/boot.hex --size 32768
```
