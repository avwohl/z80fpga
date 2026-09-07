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
- **A RomWBW image actually through the Icepi Zero's loader.**
  `boards/icepi_zero/romwbw/` stages the ROM off the microSD card into SDRAM
  and `sim/tb_romload.sv` proves the mechanism, but with a 2 KB boot monitor
  as the image. No RomWBW `.rom` has been through that path, in simulation or
  otherwise, and no Icepi Zero has run any of it. The 512 KB case differs from
  the 2 KB one only in the block count, which is a parameter -- but "only"
  is doing work there, and a bench that stages the real image would be worth
  the runtime.
- **A bus grant, so the loader need not borrow the reset.** The core is held
  in reset while the image is staged, which is simple and correct and means
  the loader owns the memory by default. A real BUSRQ/BUSAK would let a
  loader run against a live CPU, which is what a second-stage loader or a
  debugger would want. `busak_n` mirrors `busrq_n` today.
- **Area.** The core is 4641 LUT4s. The obvious remaining reductions are
  sharing the two register-file read ports (they are used in different
  T-states) and moving the micro-code ROM into block RAM, which needs the
  micro-op fetched a cycle ahead. Together they are worth perhaps 1200 LUTs,
  which is what would take the C0-microSD build from 96% full to comfortable.
