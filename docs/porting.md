# Porting this to another board

What a new board costs, what it inherits, and what has to be written again.
The short answer is that a tier (a) board is an afternoon and a tier (b) board
is a weekend, unless its memory is shaped differently from the one part
`rtl/mem/sdram_ram.sv` was written for — in which case read the last section
first, because that is the whole of the work.

## The two tiers

Keep them apart. Every claim in this repository is about one or the other.

- **Tier (a)** — the core, a UART and `sw/boot.z80` in block RAM. 32 KB ROM +
  64 KB RAM is the usual map. About 5100 LUT4s and 420 flip-flops, plus the
  microcode ROM. This fits parts that RomWBW never will.
- **Tier (b)** — RomWBW: 512 KB ROM + 512 KB RAM, a console, and a microSD slot
  for `HDSK0:`/`HDSK1:`. About 7500 LUT4s once the SD stack is in. The memory
  is what decides it, never the logic.

## What a new board inherits

Everything under `rtl/` except three files, and those three are not board
files — they are *family* files. `rtl/soc/z80_soc.sv` carries 22 parameters and
14 generate arms, and between them they cover every combination the four
existing boards use. Nothing in `rtl/` names a pin.

The deliberate decision that makes this cheap is that no tristate lives in
`rtl/`. The SDRAM data bus leaves the SoC as `sdram_dq_o`, `sdram_dq_oe` and
`sdram_dq_i`, and the board top writes the one line that needs a pad:

```systemverilog
assign sdram_dq = dq_oe ? dq_o : 16'bz;
```

That is why a tier (a) board top is 32 to 46 lines: a clock divider, a reset
counter, one `z80_soc` instance wiring about eight ports, and the LEDs.

Also inherited whole: `rtl/soc/sd_spi.sv` (the only thing here proved against a
real card), `hdsk.sv`, `rom_loader.sv`, `uart.sv`, `z80_mmu.sv`,
`tools/mkromhex.py`, `tools/romwbw_fetch.py`, and — on any nextpnr family — the
Makefile shape that `boards/icepi_zero` and `boards/c0_microsd` already use,
including the `grep` that fails the build when the clock constraint did not
apply.

## What is irreducibly per board

- **The pin constraint file.** 8 lines for the C0-microSD, 60 to 167 for the
  Icepi, 91 for the Artix boards. There is no way to share this and no reason
  to want to.
- **Clock and reset.** Which pad, which PLL primitive, what divides down to a
  sane Z80 clock. Four lines, but four different lines every time.
- **The programming recipe.** `openFPGALoader -b <board>`, or Vivado's hardware
  manager, or in one case a vendor utility.
- **The timing-constraint dialect**, and this one bites. An XDC carries the
  multicycle exceptions the Artix builds need; nextpnr's LPF reader knows
  `LOCATE`, `IOBUF`, `FREQUENCY`, `SYSCONFIG`, `BANK` and `BLOCK` and silently
  ignores everything else. `CLAUDE.md` has the full list of what fails quietly.

## What is per family, not per board

- **The memory backing.** `ddr2_ram.sv` is a Xilinx MIG over AXI4,
  `spram_ice40.sv` is an iCE40 UltraPlus primitive, `sdram_ram.sv` is an SDR
  controller, `sync_ram.sv` is inferred block RAM.
- **The PLL primitive**, where one is used at all.
- **The multicycle story.** On a Vivado family it is 65 lines of XDC, and those
  65 lines are byte-identical between `arty_a7_100t.xdc` and `romwbw.xdc` —
  71% of a 91-line file, duplicated. On a nextpnr family there is no multicycle
  exception to write, but `FREQUENCY NET` still has to be right and is silent
  when it is not.

## The one thing that is not as portable as it looks

`rtl/mem/sdram_ram.sv` is not a generic SDR SDRAM controller. It is a
controller for one part — a 16-bit MT48LC16M16 with a 13-bit row, a 9-bit
column and two DQM lanes — and that geometry is written into it as literals at
lines 131-133:

```systemverilog
col  = 9'(wa);
bank = 2'(wa >> 9);
row  = 13'(wa >> 11);
```

Those widths leak outwards. `rtl/soc/z80_soc.sv` lines 80-90 fix the port
widths to match, three Icepi board tops carry `16'bz`, and `sim/sdram_model.sv`
models that same part. **Any board whose SDRAM is not that shape cannot reach
tier (b) until this is parameterised**, and parameterising it touches
`rtl/soc/`, which by this repository's own rule means rebuilding the Nexys
bitstream and grepping the log for `ERROR: [DRC` afterwards.

There is a second, smaller trap beside it. The `req`/`ready` handshake the SoC
uses for slow memory is implemented by **two** of the four backing stores, not
four — `sync_ram` and `spram_ice40` have no `req` or `ready` at all, which is
why `z80_soc.sv:186-188` ties `ram_ready` high for them. Worse, the two that do
implement it describe it differently: `sdram_ram.sv` holds `ready` high until
`req` drops, `ddr2_ram.sv` says it pulses. A third backing store written to the
wrong one of those two comments will not work, and nothing in the tree says
which is normative. **Settle that before writing a third.**

## Is a refactor worth doing first?

For one new board, no. Copying 40 lines of board top is cheaper than inventing
an abstraction for three cases.

For the SDRAM geometry, yes, and it is not really a refactor — it is the
feature. Parameterise `sdram_ram.sv` on row/column/bank/data width, widen the
SoC's `sdram_*` ports to match, give `sim/sdram_model.sv` the same parameters,
and both the existing Icepi build and any new SDRAM board fall out of it. Do
that once, with the Nexys rebuild it obliges, rather than once per board.

## The three boards on the desk

- **Tang Nano 20K** — the best tier (b) fit of any small board here, and the
  only one whose memory is already inside the FPGA package. See
  [../boards/tang_nano_20k/README.md](../boards/tang_nano_20k/README.md).
- **Icepi Zero v1.1** — already supported at both tiers, but **the constraint
  files in this tree are for a later revision and will not run on a v1.1**.
  See [../boards/icepi_zero/README.md](../boards/icepi_zero/README.md).
- **Signaloid C0-microSD** — tier (a) only, and that is arithmetic rather than
  effort. See [../boards/c0_microsd/README.md](../boards/c0_microsd/README.md).
