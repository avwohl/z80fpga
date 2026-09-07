# Verification

## The result

```
$ make test-full
0/1604000 tests failed across 1604 opcodes (1604 opcodes clean)
```

Every opcode in the [SingleStepTests](https://github.com/SingleStepTests/z80)
suite — base, `CB`, `ED`, `DD`, `FD`, `DD CB` and `FD CB` — 1000 randomised
cases each, compared on:

- **the full architectural state**: A F B C D E H L, the alternate set, IX, IY,
  SP, PC, **WZ** (MEMPTR), I, R, IFF1, IFF2, the interrupt mode, and **Q** —
  the internal flag latch that SCF and CCF read;
- **memory**, at every address the instruction is expected to have touched;
- **the port transaction**, address and byte and direction;
- **the T-state count**;
- **the bus trace, cycle by cycle**: the address pins, the data pins, and
  RD / WR / MREQ / IORQ, in every T-state of the instruction.

That last one is what makes it more than a functional check. It catches, for
instance, the refresh address staying on the pins through the internal cycles
of `INC BC`, and the extra T-state of a taken `CALL cc,nn` landing inside the
second operand read rather than after it.

## How to run it

```
source tools/ossenv.sh
make sim
python tools/run_sst.py --all -n 20 --cycles     # a 30-second sweep
python tools/run_sst.py --all --cycles           # the whole thing
python tools/run_sst.py "dd cb __ 06" -v --cycles  # one opcode, with detail
```

Point `--suite` (or `Z80_TESTS`) at a checkout of the suite. `-n` limits the
cases per opcode; `-v` prints the first failing case's initial state and the
first ten mismatches.

`tools/run_sst.py` flattens the JSON into a text vector file, runs
`sim/tb_sst.sv` over it under `vvp`, and diffs the results. It batches many
opcode files into one bench run because launching the simulator dominates
otherwise — the full sweep at 20 cases per opcode takes about half a minute.

Everything goes through plain file I/O, so no VPI and no C compiler are
needed; Icarus Verilog on its own is enough.

## The bench

`sim/tb_sst.sv` forces the core's registers to the test's initial state,
writes the initial RAM, runs exactly one instruction, and reports. "One
instruction" is detected by watching for the core to return to the start of an
opcode fetch with its first-fetch flag set. For a repeating block instruction
that is one iteration, which is what the suite expects.

Two details the bench has to get right, both learned from mismatches:

- The register load has to happen a delta after a clock edge, or the
  non-blocking updates from that edge overwrite it.
- A byte read appears on the data pins in the T-state *after* the strobe, not
  during it. The suite's "simplified memory access" model pulses MREQ/RD for
  one T-state and shows the data in the next.

## The SoC test

```
make test        # runs every bench and a 20-case sweep
vvp sim/tb_soc.vvp
```

`sim/tb_soc.sv` boots `sw/boot.z80` out of ROM bank 0 at a deliberately slow
1 MHz, so a 115200-baud bit is eight clocks. It decodes `uart_tx` and drives
`uart_rx` for real, so the serialiser is in the loop, and it checks that:

- the banner comes out;
- the monitor's bank check passes — it copies a routine into the common bank,
  writes a signature into every RAM bank through the low window, reads them all
  back, and reports the error count;
- `AB<CR>` typed at the port comes back as `A`, `B`, `CR`, `LF`.

`+trace_io=1` logs the CPU's console port traffic, which is how you tell a
byte lost in the UART from one the program never read. That is exactly how the
missing receive FIFO was found: the CPU's `in` log showed `41` then `0d`, with
no `42` in between.

## The off-chip memory tests

The RAM banks do not always live in block RAM, and a backing store that cannot
answer inside a T-state has to hold `wait_n` low until it can. That path has
three benches.

```
vvp sim/tb_ddr2ram.vvp     # RAM in DDR2, behind a behavioural AXI slave
vvp sim/tb_sdram.vvp       # the SDRAM controller against a model of the chip
vvp sim/tb_sdram_soc.vvp   # the SoC with 512 KB of RAM in SDRAM
```

`sim/tb_ddr2ram.sv` and `sim/tb_sdram_soc.sv` both run the ordinary boot
monitor, which is the point: its bank check writes a signature into every RAM
bank and reads it back from code running in the common bank, so reads, writes,
bank switching and a long, variable `wait_n` are all exercised at once against
an answer already known from the block RAM build. The DDR2 slave's latency
wanders between 3 and 18 clocks so that nothing can accidentally depend on a
fixed number.

`sim/tb_sdram.sv` is the unit test underneath the second of those, and the
model it runs against does most of the work. `sim/sdram_model.sv` decodes the
command bus the way an MT48LC16M16 does and stops the simulation on anything
the chip would have quietly turned into garbage — a column command before
tRCD, a READ on a bank with no open row, an ACTIVE inside tRC, a row outside
the window it was given, a refresh that never came — so the power-up sequence
and the timing are checked whether the bench mentions them or not. What the
bench itself checks is the address decode, with a dozen bytes chosen to move
each field on its own, and the read latency, which has to be exact rather than
merely sufficient: the model's clock is the inverted fabric clock, the way the
board wires it, and the bench fails if the capture is one clock out in either
direction.

## Staging the ROM

```
vvp sim/tb_romload.vvp
```

The one bench where nothing in the memory path comes out of the bitstream.
`sim/tb_romload.sv` puts a ROM image on the behavioural card, lets
`rtl/soc/rom_loader.sv` fetch it into the behavioural SDRAM while the core is
held in reset, compares the chip's contents against the original byte for
byte, and then has the Z80 execute it until the monitor prints its banner and
echoes what is typed at it.

Both halves of that are needed. The byte compare catches a staging bug the
console would survive — most of the image is padding, and a monitor whose text
is intact prints a perfectly good banner out of a ROM whose top half is wrong.
The console catches a decode bug the compare would survive, because the
compare only ever looks at the ROM window.

Four ways of breaking it were tried, and each makes it fail: the loader
ignoring `ROM_LBA`, its buffer read off by one, the core released before
staging finished, and the ROM and RAM windows landing on the same megabyte.
The third of those is why the bench watches `mreq_n` rather than watching for
early console output: a core let go early fetches zeros, which are `NOP`s,
walks the whole 64 KB and arrives back at 0000 to run the firmware properly,
printing a banner that looks entirely correct.

## The interrupt tests

The SingleStepTests suite does not exercise interrupt entry at all, so
`sim/tb_irq.sv` covers it directly:

| case | checked |
|---|---|
| NMI | vectors to 0066h, pushes PC, clears IFF1 and keeps IFF2, 11 T |
| INT, IM 1 | vectors to 0038h, clears both IFFs, 13 T |
| INT, IM 2 | fetches the vector from `{I, bus byte}`, 19 T |
| INT, IM 0 | executes the byte on the bus - `FFh`, RST 38h - 13 T |
| masked | nothing happens while IFF1 is clear |
| EI delay | the instruction after EI is not interruptible; the one after it is |
| HALT | holds with `halt_n` low and PC still, and an interrupt wakes it |

Each case checks where the CPU ended up, what it pushed, what happened to
IFF1 and IFF2, and the entry's T-state count against the databook figure.

The EI delay falls out of the design rather than being special-cased: IFF1 is
read before the clock edge that EI's own action sets it on, so the boundary at
the end of EI cannot accept an interrupt and the next one can.

## What is not covered

- **BUSRQ.** `busak_n` currently just mirrors `busrq_n`; a real bus grant that
  tri-states the pins at an M-cycle boundary is not implemented. `wait_n` is
  no longer on this list — the off-chip memory benches above hold it low for a
  variable number of T-states on every access.
- **Hardware, except on one board.** The Nexys A7-100T has run: banner, bank
  check, console echo, and RomWBW and CP/M 2.2 on top of that. The Arty,
  Icepi Zero and C0-microSD builds are verified to a placed, routed,
  timing-closed bitstream and no further, because none of those boards was
  ever attached.
- **The SDRAM, against a real chip.** `sim/sdram_model.sv` is a model, and a
  model agreeing with the controller proves they agree, not that either
  matches the part on the board.
- **A real RomWBW image through the loader.** `sim/tb_romload.sv` stages 2 KB
  of boot monitor, not 512 KB of RomWBW. The difference is a block count and
  a parameter, but nothing has driven the real image through that path.
