# Icepi Zero

A Lattice **LFE5U-25F-6BG256C** in a Raspberry Pi Zero footprint, from
[Icy Electronics](https://www.crowdsupply.com/icy-electronics/icepi-zero).
The whole SoC fits in a quarter of the part, and the Z80 runs at 25 MHz — the
fastest of any target here, three times the Nexys A7's.

The `-6` in that part number is the speed grade, and it is not a detail. The
Makefile passes `--speed 6` so the timing report is for the part that is
actually on the board: the same design and the same placement report 29.17 MHz
at grade 6 and 37.01 MHz at grade 8, which is the difference between a pass
with 17% to spare and a pass with 48%. Grade 6 is also nextpnr's default for
`--25k`, so the flag changes nothing today and stops the number quietly
becoming optimistic if that ever changes.

The part number is from
[cheyao/icepi-zero](https://github.com/cheyao/icepi-zero)'s
`hardware/v1.0/icepi-zero.kicad_sch`, and every pin in the `.lpf` is from that
repository's `gateware/icepi-zero.lpf`.

## Build

```
source ../../tools/ossenv.sh
cd boards/icepi_zero
mingw32-make            # or make, on a machine that has it
mingw32-make prog       # into the FPGA; gone at power down
mingw32-make flash      # into the board's SPI flash; survives
```

`z80fpga.bit` comes out. The board carries its own FT231X USB-to-JTAG, so
`openFPGALoader -b icepi-zero` is the whole of it — no external programmer, and
the same USB-C socket carries the console:

```
powershell -ExecutionPolicy Bypass -File ../../tools/console.ps1 -Port COM4
```

One caveat that is worth knowing before it is confusing: the FT231X is a
single-channel part, so the bit-banged JTAG and the console are the *same* USB
interface, and only one thing can hold it at a time. Close the terminal before
`mingw32-make prog`, and reopen it afterwards. On Windows the driver choice
makes that sharper — the vendor's instructions have you swap the FTDI to
WinUSB with [Zadig](https://zadig.akeo.ie/) for the browser loader, and a
device on WinUSB is not a COM port any more. None of this has been tried here;
[cheyao/icepi-zero](https://github.com/cheyao/icepi-zero)'s
`documentation/PROGRAMMING.md` is the authority.

## What it builds to

```
TRELLIS_COMB    6198 / 24288   25%
TRELLIS_FF       419 / 24288    1%
DP16KD            48 /    56   85%
TRELLIS_IO        10 /   197    5%
Max frequency for clock 'clk_sys': 29.17 MHz (PASS at 25.00 MHz)
```

Logic is not the constraint on this part; block RAM is. 48 of the 56 EBRs go
to 32 blocks of RAM, 15 of ROM and 1 for the core's dispatch table — a
byte-wide ROM packs at 2304 bytes per block because yosys can use the 512x36
mode and all 18 Kbit of it, a byte-wide RAM at 2048 because it wastes the
parity bit.

A third RAM bank does not fit, and the reason is not the eight spare blocks.
`sync_ram` allocates `2**AW`, and `RAM_AW` defaults to `15 + $clog2(RAM_BANKS)`
— so three banks round up to a 17-bit, 128 KB store, which is 64 blocks on its
own. Two banks is the ceiling on this part. For more than 64 KB of RAM see
[sdram/](sdram/), which puts all sixteen banks in the board's 32 MB of SDRAM.

## Configuration

- **Clock** the 50 MHz board oscillator on M1, halved on a global buffer, and
  one T-state per clock: a 25 MHz Z80.
- **Console** 115200 8N1 on the FT231X — `usb_tx` on K15, `usb_rx` on K16.
  That is the same USB-C socket the bitstream was loaded through, so the port
  appears on the host as an ordinary serial port and there is no second cable.
- **Memory** 1 ROM bank (32 KB) and 2 RAM banks (64 KB) in block RAM. The
  common bank is `0x81`.
- **LEDs** five, showing the low five bits of the LED port (`0xFF`).
- **Buttons** `button[0]` on C4 resets; `button[1]` on C5 reads back as
  switch 0 on the input port. Both are pulled up, so they read 0 when pressed.

## Why 25 MHz, and not 50

Because nextpnr has no way to be told about the clock enable.

The Vivado targets run the fabric at 100 MHz and the Z80 at 100/12, and close
timing only because `arty_a7_100t.xdc` says a core register moves one clock in
twelve. There is nowhere to write that down for an ECP5. nextpnr-ecp5's LPF
reader implements `LOCATE`, `IOBUF`, `FREQUENCY`, `SYSCONFIG`, `BANK` and
`BLOCK`, and nothing else; `MULTICYCLE` and `MAXDELAY` lines are accepted in
silence and have no effect. Through `--sdc` it is worse and better at once —
`set_multicycle_path` is a hard error, so at least it tells you.

So the honest thing is to run the fabric at a rate the core really closes at.
Routed, this design reports **27.9 to 29.5 MHz** across four placement seeds,
so 25 MHz passes and 50 MHz misses by a factor of nearly two.

That leaves between 12% and 18% of margin, which is worth stating plainly
rather than burying: it is a pass, on the right speed grade, but it is not a
comfortable one, and nextpnr's model is a single timing corner with no
temperature or voltage derating of its own. If a board ever turns out to be
marginal, `CLK_SHIFT` in `top.sv` is the knob — 2 gives a 12.5 MHz Z80 with
more than twice the margin, and the `FREQUENCY NET` line in the `.lpf` has to
move with it. Halving the clock is also the first thing to try if the board
runs but misbehaves; a design that is right and slightly too fast fails in
ways that look like a logic bug.

The `FREQUENCY NET` line is load bearing and silent when it is wrong. An
unconstrained internal clock is not checked at all, and nextpnr says nothing
when a constraint fails to apply — an `.lpf` line it does not implement is
dropped without a warning. The proof it took is the line

```
Info: constraining clock net 'clk_sys' to 25.00 MHz
```

in `nextpnr.log`, which `mingw32-make timing` prints along with the result.
The Makefile checks for it too, because the failure is otherwise invisible:
misspell the net and nextpnr places the design with no timing target at all,
prints "Program finished normally" and **exits 0**. Tried, to be sure it has
teeth — the build stops with `the clk_sys constraint never applied`, and
`.DELETE_ON_ERROR:` takes the untimed `z80fpga.config` away with it so the
next `make` cannot quietly pack it into a bitstream.

## Untested on hardware

This is verified to a placed, routed, timing-closed bitstream and no further.
The SoC itself is verified in simulation (`make test` at the repository root),
and the pinout is the vendor's own, but no Icepi Zero has run this.

If it is silent, the Nexys A7 README's advice applies here too: bisect with a
design that has no CPU in it at all. `make` in `gateware/blinky` from the
vendor repository builds and loads one, which proves the cable, the driver and
the board in a step, and `gateware/uart` proves K15 and the baud rate on top
of that. Both use the same `openFPGALoader -b icepi-zero` this Makefile does.

## What is not here

- **The GPDI/HDMI output, USB and the Pi header.** Out of scope; nothing in
  this SoC has a use for them.
- **The microSD slot, and so HDSK and CP/M.** Not because the slot is
  awkward — `rtl/soc/sd_spi.sv` would drive it unchanged — but because the
  thing that would use it cannot fit yet. RomWBW wants 512 KB of ROM, and
  126 KB is the most byte-wide ROM this part's block RAM can hold. Getting
  there needs the ROM staged into SDRAM from somewhere at power-up; see
  [../../docs/roadmap.md](../../docs/roadmap.md).
