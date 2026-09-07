# Roadmap: Z180, eZ80, and the rest

The core is microcoded for exactly this reason. Adding an instruction means
adding a line to `tools/gen_z80.py`, regenerating, and running the suite —
not editing a decoder. What follows is what each step actually costs, from
having built the Z80.

## Z180 (HD64180)

The Z180 is a superset of the Z80's instruction set with a different MMU, a
different timing profile, and a pile of on-chip peripherals. The work splits
cleanly.

### New instructions — small

All of them are `ED`-prefixed, and all fit the existing micro-op vocabulary:

| instruction | encoding | notes |
|---|---|---|
| `IN0 r,(n)` | `ED 00+8r nn` | I/O read with the high address byte zero |
| `OUT0 (n),r` | `ED 01+8r nn` | needs an `ASRC` of `{8'h00, Z}` |
| `TST r` | `ED 04+8r` | `AND` that keeps the flags and drops the result |
| `TST n` | `ED 64 nn` | |
| `TST (HL)` | `ED 34` | |
| `TSTIO n` | `ED 74 nn` | `AND` against the byte read from port `(C)` |
| `MLT rr` | `ED 4C/5C/6C/7C` | 8×8→16 multiply; the one real datapath addition |
| `OTIM`/`OTDM` | `ED 83`/`ED 8B` | block I/O with the port in C, incrementing |
| `OTIMR`/`OTDMR` | `ED 93`/`ED 9B` | the repeating forms |
| `SLP` | `ED 76` | like `HALT`, with a different pin |

Everything except `MLT` is a new `ed_prog()` branch plus, in two cases, a new
`ASRC` value and a new `ALU` op. `MLT` wants a 16-bit result path — either a
multi-cycle shift-add sequenced from micro-code, which costs nothing in area
and matches the Z180's own 17-cycle figure, or a DSP block on parts that have
one.

The Z180 also **traps undefined opcodes** rather than ignoring them. That is a
new `CTL` code that pushes PC and vectors, plus the ITC's TRAP and UFO bits.

### Timing — a second profile

Z180 instruction timings are not Z80 timings: the fetch is shorter, and many
instructions lose a T-state or two. The `tx` field and the cycle-length rules
already carry all the timing, so this is a matter of parameterising
`gen_z80.py` on a target and emitting a second ROM. The generator would grow
a `--target z180` flag and the RTL a second `.mem` file; the engine itself
does not change.

There is no equivalent of SingleStepTests for the Z180, so the timing profile
would have to be checked against the databook by hand, or against a Z180
emulator run in lockstep.

### The MMU — a new module

The Z180 MMU is not the RomWBW bank register. It maps a 64 KB logical space
into 1 MB physical through three registers:

- `CBAR` splits the logical space into Common Area 0, the Bank Area, and
  Common Area 1;
- `BBR` and `CBR` supply the physical base of the Bank Area and Common Area 1,
  in 4 KB units.

That is a different `rtl/soc/` module — `z180_mmu.sv` alongside
`z80_mmu.sv` — with the same interface to the memory: logical address in,
physical address out. Nothing in the core changes. A board would instantiate
one or the other.

### Peripherals — the bulk of the work

Two ASCIs (asynchronous serial, close to what `rtl/soc/uart.sv` already is),
two PRTs (16-bit down-counting timers), a clocked serial port, two DMA
channels, an interrupt controller with the INT1/INT2 and internal sources, a
wait-state generator, and the refresh controller. These are ordinary
peripheral RTL, independent of the core, and are the largest single block of
remaining effort — probably more than the core took.

### Order of work

1. The new instructions, verified against the existing suite for
   non-regression and by directed tests for the new opcodes.
2. `z180_mmu.sv` and a `z180_soc.sv`, verified the way `sw/boot.z80` verifies
   the bank map today.
3. The timing profile.
4. The peripherals, one at a time, ASCI first since it replaces the UART.

## eZ80

A bigger step, and honestly a different core that shares the generator rather
than an extension of this one:

- **24-bit addressing.** PC, SP, HL, IX, IY and the address bus all widen to
  24 bits. The register file, the address mux, and every `ASRC` grow; the
  micro-op format does not.
- **ADL mode and the suffix prefixes** (`.SIS`, `.LIS`, `.SIL`, `.LIL`, the
  `40h`/`49h`/`52h`/`5Bh` bytes). These change the width of operands and of
  the stack push for the *current instruction*, which means the prefix state
  the fetch unit already tracks grows a mode field, and the micro-programs
  become width-parameterised. This is the interesting design problem.
- **A pipelined bus.** The eZ80 fetches in one clock and overlaps cycles. The
  T-state model here is explicitly non-overlapping; matching eZ80 timing would
  mean a new sequencer, not a new timing table.
- **New instructions** — `LEA`, `PEA`, the 24-bit loads, `MLT`, `TST` — are
  the easy part, again just generator lines.

A reasonable path is: get the Z180 done, then fork the core for the eZ80
rather than trying to make one engine cover both bus models.

## Nearer-term work on the Z80 itself

- **Interrupt tests.** NMI, IM 0, IM 1 and IM 2 are implemented and the
  T-state counts follow the databook, but nothing exercises them. A directed
  bench with an interrupting device is the biggest coverage gap.
- **A real bus grant.** `busak_n` mirrors `busrq_n` today; tri-stating the
  pins at an M-cycle boundary needs doing before anything shares the bus.
- **DDR3 on the Arty**, for the full 512 KB + 512 KB RomWBW map. Block RAM
  tops out around 256 KB of RAM on the -100T; the map wants four times that.
  This needs a cache in front of the MIG, because the core expects its byte
  by the end of T2.
- **Booting a real RomWBW image.** The bank map matches, the ports match, and
  the console is at 0x00/0x01 the way the emulators present it, but nothing
  has actually run a RomWBW ROM yet. That is the test that would prove the
  whole thing, and it needs either the DDR3 work or a cut-down ROM.
- **RomWBW on the Icepi Zero**, which needs the ROM staged into memory rather
  than baked into the bitstream. The board's 32 MB of SDRAM is far more than
  the 512 KB + 512 KB map wants, and `boards/icepi_zero/sdram/` already has
  the RAM half of it; the obstacle is the other half. An ECP5 LFE5U-25F holds
  at most 126 KB of byte-wide ROM in block RAM, so on this part the ROM cannot
  come out of the bitstream the way it does on the Nexys — something has to
  copy the image into SDRAM before the first instruction fetch. The pieces are
  mostly here already: `rtl/soc/sd_spi.sv` reads 512-byte blocks from a
  microSD card and has been verified against a real one, and the board has a
  slot. What is missing is a loader state machine that reads the image into
  the SDRAM's ROM space at power-up, an arbiter in `sdram_ram.sv` so the
  loader and the CPU can share the one port, holding the core in reset until
  it is done, and a `sel_rom` path in `z80_soc.sv` that goes to SDRAM instead
  of to `sync_ram` — which also means `sdram_ram`'s `AW` grows from 19 to 20
  to address both halves. The same machinery would let the C0-microSD boot
  from its card.

  Two things that are cheap on the boards that have run would have to be
  looked at first. `sd_spi.sv`'s 512-byte `blkbuf` is written from two places,
  which stops yosys inferring a block RAM for it; Vivado infers one anyway, so
  it has never mattered, but on an ECP5 the same code becomes flip-flops and
  costs thousands of LUTs. And `z80_soc.sv`'s DMA arm of `mem_wr_eff` has no
  `!sel_rom` guard, so a DMA write while a ROM bank is selected would land in
  RAM at the same physical address. Neither is reachable today — the only
  build with `USE_HDSK` has its RAM in DDR2, whose `req` is gated by
  `ram_cycle`, which does carry the guard — but both are in the way of this.
- **Area.** The core is 4641 LUT4s. The obvious remaining reductions are
  sharing the two register-file read ports (they are used in different
  T-states) and moving the micro-code ROM into block RAM, which needs the
  micro-op fetched a cycle ahead. Together they are worth perhaps 1200 LUTs,
  which is what would take the C0-microSD build from 96% full to comfortable.
