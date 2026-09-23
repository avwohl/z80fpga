# Icepi Zero

A Lattice **LFE5U-25F-6BG256C** in a Raspberry Pi Zero footprint, from
[Icy Electronics](https://www.crowdsupply.com/icy-electronics/icepi-zero).
The whole SoC fits in a quarter of the part, and the Z80 runs at 25 MHz — the
fastest of any target here, three times the Nexys A7's.

The `-6` in that part number is the speed grade, and it is not a detail. The
Makefile passes `--speed 6` so the timing report is for the part that is
actually on the board: one placement of this design reported 29.17 MHz at
grade 6 and 37.01 MHz at grade 8, which is the difference between a pass with
17% to spare and one with 48%, for the same bitstream. Grade 6 is also
nextpnr's default for `--25k`, so the flag changes nothing today and stops the
number quietly becoming optimistic if that ever changes.

The part number is from
[cheyao/icepi-zero](https://github.com/cheyao/icepi-zero)'s
`hardware/v1.0/icepi-zero.kicad_sch`, and every pin in the `.lpf` is from that
repository's `gateware/icepi-zero.lpf`.

## Which revision these files are for: v1.2 onward, and verified on a v1.3

`gateware/icepi-zero.lpf` upstream is a **symlink**, and it has been retargeted
twice. When these files were written it resolved to `v1.3/icepi-zero-v1_3.lpf`;
it now points at v1.4. So the pins here are v1.3/v1.4 pins, and the sentence
above, while true as written, names a path that does not say so.

Checked ball by ball against every upstream revision on 2026-09-23, which
sharpens that: **v1.3 and v1.4 are pin-identical** -- the only difference in
126 constraints is that v1.4 *adds* `programn` on N12, matching its changelog.
And almost nothing here is v1.3-specific. The LED, button and SD pins are
**v1.2 onward**; the v1.2-to-v1.3 diff is exactly two lines, `clk` M2 to M1 and
`gpio[23]` M1 to M2. So the clock is the only pin that makes these files v1.3
rather than v1.2.

Against upstream v1.3 the three `.lpf` files here match on **every one of 115
signals, zero mismatches**. `sd_dat1`/`sd_dat2` are spelled `sd_dat[1]`/
`sd_dat[2]` upstream and sit on the same balls, R14 and M15; that is a naming
difference and not a discrepancy.

**On a v1.0 or v1.1 board this design will configure, assert DONE, and do
nothing.** The 50 MHz oscillator is on **M2** there and on **M1** from v1.3
onward — upstream's `hardware/changes.md` records the swap as "Swapped pins M1
and M2 / PCLKC is not a clock pin", and on a v1.1 board M1 is a Pi-header GPIO
that is not connected to anything. `LOCATE COMP "clk" SITE "M1";` therefore
binds the clock to a floating pin. It is the same failure as loading an Arty
bitstream on a Nexys, and it looks the same from outside.

Two other things differ, and both moved at **v1.2**, not v1.3 -- so they bite a
v1.0 or v1.1 board and nothing later:

- `led[0]`, `led[1]`, `led[2]` are **E13/D14/E12** here and **E14/E15/D14** on
  v1.1. (`led[0]` went F16 on v1.0, E14 on v1.1, E13 from v1.2; `led[3]` C13
  and `led[4]` D13 never moved.) E13 and E12 are unconnected balls on a v1.1,
  so a perfectly working RomWBW build would show exactly the LED signature the
  romwbw README tells you means "stopped at SDRAM init". Note which lamp
  survives: on a v1.1 this design's `led[1]` lands on D14, which *is* a real
  LED there, so the board looks half alive rather than dead.
- **`sd_clk` and `sd_cmd`** exchange **N16** and **P15** at v1.2 -- v1.0 and
  v1.1 have `sd_clk` on N16, v1.2 onward on P15. This used to say `sd_clk` and
  `sd_mosi`, which cannot be right: `sd_mosi`, `sd_miso` and `sd_csn` are SPI
  *aliases* that upstream only added at v1.2 ("Added aliases for sd card
  pins"), so on a v1.1 board `sd_mosi` does not exist to be swapped with.

The SDRAM bus is identical across every revision — all 39 sites, checked ball
by ball — and so are the part number, the console pins and the JTAG wiring.

**Telling the boards apart:** one push button is v1.0, two is v1.1 or later.
v1.0 and v1.1 are *not* the same pinout either — v1.0 puts `led[0]` on F16 and
has no second button — so a v1.1 file is a v1.1 file, not a "v1.0/v1.1" one.

Nothing here is hard to fix: four `LOCATE` lines in `icepi_zero.lpf` and
`sdram/icepi_zero_sdram.lpf`, six in `romwbw/icepi_zero_romwbw.lpf`, and a
`REV ?=` variable in the three Makefiles so the question is asked once per
build. It still has not been done, but the reason has changed: a **v1.3 board
now runs this design** (see below), and no v1.0 or v1.1 board is on hand to
test a back-port against. Writing untested `LOCATE` lines for a board nobody
here has is how the wrong pins get believed.

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
powershell -ExecutionPolicy Bypass -File ../../tools/console.ps1 -Port COM9
```

### Which USB-C, and it is not obvious

The board has **three** USB-C sockets and neither the vendor README nor the
Crowd Supply page says which does what. **Use the one nearest the HDMI.**

Traced through `hardware/v1.3/usb.kicad_sch` and `production/positions.csv`:
J3, J4 and J5 all sit on the same edge at Y = -13.0 mm, and the mini-HDMI
(J2, a GPDI connector) is at X = -21.6 mm on that same end.

- **J5**, X = **-6.0 mm**, nearest the HDMI. Its `D+` (A6/B6) and `D-`
  (A7/B7) go straight to **U9 FT231XQ pins 8 (USBDP) and 9 (USBDM)**. This is
  the one. JTAG and console both.
- **J3**, X = +6.5 mm, middle. Data pair goes through ESD diodes to the
  **ECP5** at balls F15/E16.
- **J4**, X = +19.0 mm, farthest. Same, to ECP5 balls J16/J15.

J3 and J4 are the FPGA's own USB ports; nothing in this SoC uses them. All
three `VBUS` pins are on one `+5V` net, so any socket will *power* the board —
which is the trap. A board plugged into J3 lights up and is completely
unreachable.

### On Windows you cannot have the programmer and the console at once

The FT231X is a single-channel part, so the bit-banged JTAG and the console
are the *same* USB interface, and one driver owns it:

- bound to **FTDI VCP** (`FTDIBUS`/`FTSER2K`) you get a COM port and a working
  console, and `openFPGALoader` fails with
  `Error code -12 Operation not supported or unimplemented on this platform` —
  that -12 is libusb's way of saying "wrong driver", not a broken cable;
- bound to **WinUSB** `openFPGALoader` works and **the COM port disappears**.

To program, swap it with [Zadig](https://zadig.akeo.ie/): *Options → List All
Devices* first, or the device will not be in the dropdown at all, because
Zadig hides devices that already have a driver. Pick the entry whose **USB ID
is `0403 6015`** (an FT231X; it shows as `USB Serial Converter` on VCP and
`FT231X USB UART` on WinUSB) and replace the driver with WinUSB. Going back is
Device Manager → Update driver → *Let me pick* → **USB Serial Converter**;
Zadig will not undo it.

Verified working on 2026-09-23: after the swap, `openFPGALoader -b icepi-zero
--detect` returns `idcode 0x41111043`, `lattice`, `ECP5`, `LFE5U-25`.

So to end up with a running board *and* a console, use `mingw32-make flash`
rather than `prog` — flash survives the power cycle, so you can put the VCP
driver back afterwards and the design is still there. `prog` loads SRAM only
and is the faster loop while you are iterating on the bitstream.

Upstream's `documentation/PROGRAMMING.md` is not the authority it looks like:
it is a 21-byte symlink stub pointing at `../firmware/README.md`.

## What it builds to

```
TRELLIS_COMB    6202 / 24288   25%
TRELLIS_FF       419 / 24288    1%
DP16KD            48 /    56   85%
TRELLIS_IO        10 /   197    5%
Max frequency for clock 'clk_sys': 28.57 MHz (PASS at 25.00 MHz)
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
[sdram/](sdram/), which puts all sixteen banks in the board's 32 MB of SDRAM,
and [romwbw/](romwbw/), which puts the ROM there too and fetches it off the
microSD card at power-up.

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

That leaves about 14% of margin, which is worth stating plainly
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

## It runs, 2026-09-23

**An Icepi Zero v1.3 passes the bank check on hardware.** `sw/ledchk.z80`
held **6** -- `led[2:1]` lit, `led[0]`, `led[3]` and `led[4]` dark -- which is
its terminal BANK CHECK PASSED state: RAM bank `80h` selected and written,
`81h` selected and written, both read back, every byte matching. `7` would
have been a bank reading back wrong and shows one more lamp.

That one lamp pattern carries the whole stack: the ECP5 bitstream, the 25 MHz
clock with `constraining clock net 'clk_sys' to 25.00 MHz` in the log, the Z80
core, the banked MMU, both RAM banks, and execution from the common bank at
`8000h` -- the bank checker cannot run from ROM, so `6` means the copy to
`8000h` ran there and returned.

Read the lamps by position, not by guesswork. D1 through D5 are `led[0]`
through `led[4]` in board order, anodes through R1-R5 with common cathodes, so
**lit = 1**, and the row sits at the opposite end of the board from the HDMI.
There is a free check on any reading: `ledchk` only ever writes 1 to 7, so a
pattern that decodes above 7 means you are reading the row backwards.

**And the console works.** With the design in flash and the FTDI driver put
back, `sw/boot.z80` came up on COM9 at 115200:

```
z80fpga ready
banked memory ok
> 
```

and typing `AB<CR>` at it returns `AB<CR><LF>`, which is the echo loop turning
a bare CR into a newline. So banner, bank check, prompt and both UART
directions are all proved on hardware.

The banner needs a reset to see, because the board prints it microseconds
after power-up, long before a terminal can open the port -- hold the port open
and press a button. Both buttons are on the **bottom** of the board, in the
middle, 3.4 mm apart (SW1 and SW2 at X = 12.4 mm); one of them is `button[0]`
on C4, the reset.

**Still bitstream-only:** the SDRAM and RomWBW variants.

If a future board is silent, the Nexys A7 README's advice applies here too:
bisect with a design that has no CPU in it at all. `make` in `gateware/blinky` from the
vendor repository builds and loads one, which proves the cable, the driver and
the board in a step, and `gateware/uart` proves K15 and the baud rate on top
of that. Both use the same `openFPGALoader -b icepi-zero` this Makefile does.

## What is not here

- **The GPDI/HDMI output, USB and the Pi header.** Out of scope; nothing in
  this SoC has a use for them.
- **The microSD slot, and so HDSK and CP/M.** Not in *this* build, which is
  the deliberately small one. [romwbw/](romwbw/) has them: the full
  512 KB + 512 KB map with the ROM half fetched off the card at power-up,
  because 126 KB is the most byte-wide ROM this part's block RAM can hold and
  a bitstream therefore cannot carry a RomWBW image.
