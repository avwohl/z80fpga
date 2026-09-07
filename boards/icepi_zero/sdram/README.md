# Icepi Zero, with the RAM in SDRAM

The same board and the same SoC as [../](../), with all sixteen RAM banks —
the full 512 KB of the RomWBW map — in the board's SDRAM instead of the two
banks that fit in block RAM.

The chip is a **MT48LC16M16A2P**, from the schematic rather than from a guess:
4 banks x 8192 rows x 512 columns x 16 bits, which is 32 MB. The controller
uses the -75 grade's timings, the slowest of that family, so it is right
whichever bin the board was populated from.

## Build

```
source ../../../tools/ossenv.sh
cd boards/icepi_zero/sdram
mingw32-make
mingw32-make prog       # or flash
```

## The split, and why it is the other way round from the Nexys

On the Nexys A7 the ROM is the bank in block RAM and the RAM is in DDR2, and
the reason is that the ROM is the only bank whose contents have to survive to
the first instruction fetch — DDR2 comes up empty and there is nothing to fill
it from.

(If you want the ROM in there as well, and RomWBW with it, that is
[../romwbw/](../romwbw/). This build is the halfway house: the ROM still
comes out of the bitstream, so it needs no card and nothing prepared.)

Here the same reasoning applies and the sizes do not. A byte-wide ROM packs
at 2304 bytes per EBR on an ECP5 — yosys uses the 512x36 mode and all 18 Kbit
of the block — and the LFE5U-25F has 56 of them, so 126 KB is the ceiling for
a ROM and 112 KB for a RAM, which packs at 2048 bytes and wastes the parity
bit. 512 KB of ROM is out of reach whatever else is given up. So the ROM is one 32 KB bank —
enough for the boot monitor, which is what this build runs — and the RAM, all
512 KB of it, is in the chip, of whose 32 MB that is the bottom sixteenth.

## What it builds to

```
TRELLIS_COMB    6371 / 24288   26%
TRELLIS_FF       515 / 24288    2%
DP16KD            16 /    56   28%
TRELLIS_IO        49 /   197   24%
SIOLOGIC           1 /    69    1%      (the ODDR on sdram_clk)
Max frequency for clock 'clk_sys': 29.13 MHz (PASS at 25.00 MHz)
```

Moving 64 KB of RAM out of the EBRs gives 32 of them back, at the cost of 169
logic cells and 96 flip-flops against the block RAM build — a net figure, not
the controller's alone, since the block RAM it replaces had an address decode
of its own.

## The controller

`rtl/mem/sdram_ram.sv`, and it is deliberately dull: ACTIVE, then READ or
WRITE with auto-precharge, and that is all. No open-row tracking, no bank
interleaving, no bursts, no read cache.

It can afford to be. `sim/tb_sdram.sv` measures and prints what an access
costs, and at 25 MHz it is **5 clocks for a read and 2 for a write** from the
request to the answer, so a three-T-state memory cycle becomes seven or four.
Instruction fetch is unaffected — the ROM is still block RAM and still answers
in one — so what this costs is a fraction of the data accesses, on a Z80 that
is three times the speed of the one on the Nexys. A read cache would recover
some of it, because a read fetches two bytes and throws one away, and it would
buy a second copy of the invalidation logic that is easy to get wrong.

It presents the same interface to the SoC as `ddr2_ram.sv` — hold `req` for
the bus cycle, `ready` when the byte is there — so `wait_n` and the HDSK DMA
path work the same way for both, and the SoC needed one new `generate` branch
rather than a new memory model.

The 25 MHz is not a free choice either — [../README.md](../README.md)
explains why the fabric runs at the Z80's own rate on this part, and how much
margin that leaves.

## Clocking the chip

`sdram_clk` is an **inverted** copy of the 25 MHz fabric clock, sent out
through an `ODDRX1F` rather than routed to a pad, so it leaves from an IO
register with a defined delay.

Inverted means the chip's rising edge falls half a fabric clock — 20 ns —
after the edge that launched the command, against the 1.5 ns of setup the part
asks for; and read data is driven half a clock before the fabric samples it.
That is what buys this design out of the PLL and the 90-degree phase shift the
usual ECP5 SDRAM references need at 100 MHz, which matters, because
nextpnr-ecp5 has no output delay constraint to check such a thing with.

The read latency is the one number here that has to be exact rather than
merely sufficient: the word is on the bus **three** fabric clocks after the
edge that issued READ, being CAS latency 2 plus the half-clock each way.
`RD_LAT` in `sdram_ram.sv` is that number, and `sim/tb_sdram.sv` fails if it
is one out in either direction.

## How it is tested

Two benches, both in `make test`:

- **`sim/tb_sdram.sv`** — the controller against `sim/sdram_model.sv`, a
  behavioural MT48LC16M16 that stops the simulation on anything the chip would
  have quietly turned into garbage: a column command before tRCD, a READ on a
  bank with no open row, a row outside the window, an ACTIVE inside tRC, a
  refresh that never came. It writes and reads back a dozen bytes chosen to
  move each field of the address decode on its own — both halves of a word,
  a column carry, both bank bits, and the top of the 512 KB window. Its
  `CLK_HZ` is a parameter, so the controller's cycle-count arithmetic can be
  re-checked at another fabric clock without editing anything; it passes at
  25, 50 and 100 MHz.
- **`sim/tb_sdram_soc.sv`** — the whole SoC with `RAM_BANKS = 16` behind the
  same model, running the boot monitor. Its bank check writes a signature into
  a RAM bank and reads it back from code running in the common bank, which
  exercises reads, writes, bank switching and a long variable `wait_n` all at
  once, and the answer is already known from the block RAM build. It walks two
  banks, not sixteen: `RAM_N` in `sw/boot.z80` is 2, and the monitor is shared
  with every other target. The common bank is `0x8F` either way, and that is
  where the stack lives, so the top of the 512 KB window is exercised whether
  the check walks it or not.

Both run the fabric at the 25 MHz the board really uses, so the model's
nanosecond checks are being asked a real question. The console runs at
3.125 Mbaud in simulation to keep it short; nothing about the memory depends
on that.

The checks have been shown to have teeth rather than assumed to: breaking the
read latency by one clock in either direction, issuing the column command
inside tRCD, dropping the auto-precharge bit so a bank is left open, and
never refreshing at all each make the benches fail with the right message.

## Untested on hardware

No Icepi Zero has run this. It is verified to a placed, routed, timing-closed
bitstream, and the memory path is verified in simulation against a model of
the chip — which is not the same as against the chip.

`led[4]` is `sdram_init_done`, and it is the first thing to look at if the
console is silent: low means the controller never finished its 100 µs power-up
sequence, which would mean the clock or the reset, not the memory. Nothing
holds the CPU in reset while that happens — the monitor's first stack push is
its first RAM access, and it simply waits there — so a chip that never comes
up shows as a board that says nothing at all rather than as one that says
something wrong.
