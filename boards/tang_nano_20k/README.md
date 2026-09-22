# Sipeed Tang Nano 20K — a plan, not a build

**Nothing here builds yet.** This is the case for doing it and the order to do
it in, written down so the work can start from a settled position rather than
from research. The Qomu note next door is the same shape for the opposite
answer.

The short version: this is the best tier (b) target of any small board in this
tree, because it is the only one whose RomWBW-sized memory is already inside
the FPGA package, and because the whole toolchain is already installed.

## The part

A **GW2AR-LV18QN88C8/I7**. From Gowin DS226-2.7E (2026-07-31), Table 1-1 and
Tables 1-2/1-3:

- 20,736 LUT4s and 15,552 flip-flops
- 828 Kbit of BSRAM in 46 blocks of 18 Kbit, plus 40 Kbit of shadow SRAM
- two PLLs in the QN88 package (PLLL1, PLLR1), 66 user I/O
- **64 Mbit — 8 MB — of SDR SDRAM in the package**, four banks of 512K x 32,
  each bank 2048 rows x 256 columns x 32 bits, 166 MHz, CAS 2 or 3, 4096
  refresh cycles per 64 ms, 3.3 V LVTTL

Logic is not the constraint. The Icepi RomWBW build is 7456 LUT4 and 1094
flip-flops, which is about 36% of this part.

Block RAM is *tighter* than the ECP5's — 828 Kbit against 1008 Kbit — so a
512 KB ROM cannot come out of the bitstream here either. That does not matter,
because 8 MB of SDRAM is eight times the entire RomWBW map and costs no board
wiring at all.

## The board

From Sipeed's own constraint files in `sipeed/TangNano-20K-example`, not from
prose: 27 MHz clock on pin 4; UART to the on-board BL616 debugger on pins 69
(tx) and 70 (rx); microSD on 83 (CLK), 82 (CMD), 84 (DAT0), 85 (DAT1), 80
(DAT2), 81 (DAT3, which is chip select in SPI mode); six active-low LEDs on
15-20; two buttons on 87 and 88. One USB-C carries both the bitstream and the
console, exactly as the Icepi Zero's FT231X does.

## The toolchain is already here

This was the thing most likely to sink it, and it does not. Verified on this
machine, by inspection rather than by building:

- `yosys` has `synth_gowin` with `-family gw2a`
- `nextpnr-himbaechel` reports `Supported uarches: gowin, gatemate`, ships
  `chipdb-GW2A-18C.bin`, and answers
  `--device GW2AR-LV18QN88C8/I7` with `Info: Using uarch gowin`
- `gowin_pack` (apicula 0.34.dev2) is installed
- `openFPGALoader --list-boards` has `tangnano20k`

So this board drops into the same Makefile-driven shape as `boards/icepi_zero`
and `boards/c0_microsd`. No vendor IDE, no new build idiom. The constraint file
becomes a `.cst` instead of a `.lpf`, and the three tool invocations change.

apicula also knows the in-package SDRAM by name — `O_sdram_addr[11]`,
`IO_sdram_dq[32]`, `O_sdram_dqm[4]`, `O_sdram_ba[2]` and the six control
signals are all in the shipped device database, and the widths agree with the
datasheet exactly.

## The one piece of real work

`rtl/mem/sdram_ram.sv` is a controller for a **16-bit** MT48LC16M16 with a
13-bit row and a 9-bit column. This part's SDRAM is **32-bit with an 11-bit row
and an 8-bit column**, and four DQM lanes rather than two. The controller has
to be parameterised on that geometry, and the widths leak into
`rtl/soc/z80_soc.sv`'s port list and into `sim/sdram_model.sv`.

That is contained, well-understood RTL — but it touches `rtl/soc/`, so
`CLAUDE.md`'s rule applies: rebuild the Nexys RomWBW bitstream afterwards and
check the log for `ERROR: [DRC`. [../../docs/porting.md](../../docs/porting.md)
has the rest of what that entails, including the `req`/`ready` disagreement
that has to be settled before a third backing store is written.

## Order to do it in

1. **Tier (a) first, with no SDRAM at all.** 32 KB ROM + 64 KB RAM in BSRAM, the
   UART on 69/70, LEDs on 15-20. This proves the toolchain, the constraint
   file, the clock and the console in one go, and it is about 40 lines of board
   top. A banner on the console is the milestone.
2. **Pick the clock deliberately.** 27 MHz with `CPU_DIV = 2` gives a 13.5 MHz
   Z80. Note that `uart.sv` computes `DIV = CLK_HZ / BAUD` by truncation, so
   check the baud error, and note that a 13.5 MHz fabric clock shortens the
   SDRAM's 100 us power-up wait through the same truncation — a path this tree
   has never exercised.
3. **Parameterise `sdram_ram.sv`** and rebuild the Nexys. Do this as its own
   commit, with the Icepi SDRAM build rebuilt as the regression: it is the
   existing user of that controller and must come out unchanged.
4. **Tier (a) with 512 KB of RAM in SDRAM**, mirroring `boards/icepi_zero/sdram`.
   This is the memory test with every other variable already settled.
5. **Tier (b).** `rom_loader.sv` stages the 512 KB ROM off the microSD card into
   SDRAM at power-up, exactly as `boards/icepi_zero/romwbw` does, because the
   bitstream cannot carry it here either.

## What is not established

- Whether the open Gowin flow's timing analysis is trustworthy enough to rely
  on for a 13.5 MHz target. The chipdb does carry a per-speed-grade model for
  the C8/I7 grade, so there is an Fmax to read — but nobody here has read one.
- apicula issue #541 reports a signedness miscompile on this exact part. The
  maintainer replied the same day pointing at a probable duplicate. There is no
  `$signed` anywhere under `rtl/`, so it likely does not apply, but it is the
  kind of thing to remember if something behaves impossibly.
- Every pin above comes from Sipeed's own example constraint files. They should
  be checked against the board in hand before the first build, not after.
