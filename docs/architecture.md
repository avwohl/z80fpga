# How the core works

The core is microcoded. `tools/gen_z80.py` holds a Python description of the
instruction set; it emits three files that the RTL reads:

| file | what it is |
|---|---|
| `rtl/core/z80_defs.svh` | field encodings, widths, interrupt entry points |
| `rtl/core/z80_ucode.mem` | 357 micro-ops, 51 bits each — 2.2 KB |
| `rtl/core/z80_dispatch.mem` | opcode → micro-program entry, five 256-entry tables |

`rtl/core/z80_core.sv` is the engine that runs them, and `rtl/core/z80_alu.sv`
is the 8-bit ALU and flag unit. Nothing else is generated, and nothing about
the encoding is written down twice — that is what keeps the Z180 and eZ80 work
tractable (see [roadmap.md](roadmap.md)).

## The micro-op

A micro-op is **an action and a bus cycle**:

```
{ bus, tx, asrc, ainc, ds, dd, pd, wsrc, alu, fw, eop, ctl, nx }
```

- `bus` — `NONE`, `INT`, `MR`, `MW`, `IOR`, `IOW`. Cycle lengths are
  1+`tx`, 3+`tx` and 4+`tx` T-states respectively; `NONE` costs nothing.
- `asrc` / `ainc` — where the address comes from and what happens to that
  register: post-increment, pre-decrement, post-decrement.
- `ds` → ALU operand B; `dd` ← the ALU result, or a plain move when `alu` is
  `NOP`.
- `pd` — the *post*-destination: the byte a read cycle brings in is written
  here when the cycle retires. This is the datapath the real part uses for
  operand and return-address fetches, and it is why `LD BC,nn` is two
  micro-ops rather than four.
- `wsrc` — the byte a write cycle drives.
- `eop` — a 16-bit or composite operation: `ADD_HL`, `LDI`, `CPD`, `OUTI`,
  `DISP` (the IX+d address), `REPEAT`, the MEMPTR updates, and so on.
- `ctl` — `EX_DE_HL`, `EXX`, `EX_AF`, `DI`, `EI`, `SET_IM`, `HALT`, `RETN`.
- `nx` — what happens after the cycle: `NEXT`, `END`, or one of the
  conditional endings (`CC`, `CCJ`, `NZ_B`, `BLK`).

### When the action happens

**The action is applied on the clock edge that enters the micro-op** — which is
the same edge on which the previous bus cycle retires. Two things follow, and
both are load-bearing:

1. An action can consume the byte the previous cycle just read (`DIN`).
2. The bus cycle in the *same* micro-op already sees the action's result, so
   `INC (HL)` is `MR(HL)` then `{ALU_INC(DIN)→TMP, MW(HL) from TMP}` — two
   micro-ops, and the write address and the written byte are both right.

A zero-length (`BUS.NONE`) micro-op's bus cycle is the *following*
micro-op's, started on the same edge. That would ask one edge to apply two
actions, so the generator asserts that the following micro-op carries none.
`tools/gen_z80.py` refuses to build a program that breaks the rule, naming the
opcode.

### Things that move on the entry edge

Several registers are written by the fetch on the very edge that applies the
first action, so the action would otherwise read a stale value. The core
carries an explicit "as the entry edge sees it" copy of each:

| signal | why |
|---|---|
| `ir_x` | the opcode only reaches `ir` on that edge, and `resolve()` needs it |
| `pc_x` | the fetch increments PC there; the first operand read must use PC+1 |
| `wz_x` | `DD CB d op` computes IX+d on the `XOP` retire, and the next cycle addresses it |
| `q_x` | the fetch hands Q over to `qPrev`, which SCF and CCF read |
| `r_x` | the refresh increment lands there, and `LD A,R` must see the new R |
| `bc_x` | `OUTI` decrements B before the port address is driven |

Each of these was a real bug the test suite caught. They are the price of
applying actions on the retiring edge rather than a cycle later, and they are
cheap — a mux apiece.

## Register selection

Micro-code names registers symbolically, and `resolve()` turns the symbol into
a physical selector using the opcode and the prefix state:

- `RLO` / `RHI` — `r[opcode[2:0]]` and `r[opcode[5:3]]`, prefix-aware, so `H`
  becomes `IXH` under a DD prefix.
- `RLOR` / `RHIR` — the same fields, never substituted. The `(IX+d)` forms use
  these, because in `LD H,(IX+d)` the destination is the real H.
- `RPH`/`RPL` and `RQH`/`RQL` — the halves of the pair `opcode[5:4]` selects,
  from the BC/DE/HL/SP and BC/DE/HL/AF tables.
- `RLOT` — like `RLOR`, but index 6 lands in the temp register. The
  undocumented `DD CB` forms write their result to memory *and* to `r[z]`;
  when `z` is 6 there is no register, and both the memory write and the
  register write need somewhere real to read from.

Index 6 in the `r[]` table is `(HL)`, and in the data selector it is the bus
latch `DIN` — a coincidence worth preserving, since it makes the mapping
honest and writes to it are simply discarded.

## The fetch and prefix unit

The sequencer's phases:

```
PH_M1     opcode fetch, 4 T; also every byte of a prefix chain
PH_XD     the displacement byte of DD CB d op, 3 T
PH_XOP    the opcode byte of DD CB d op, 5 T, and IX+d is computed here
PH_EXEC   running micro-code
PH_ACK    interrupt acknowledge, 6 T
PH_NMIA   NMI acknowledge, 5 T
```

`PH_M1` consumes `DD`, `FD`, `ED` and `CB` itself and loops, accumulating the
prefix state, rather than spending micro-code on it. R increments on every M1,
prefixes included, and Q is handed over on every M1 — which is why SCF after a
DD prefix sees Q = 0 and one after no prefix does not.

The five dispatch tables are `BASE`, `DDFD`, `CB`, `DDCB` and `ED`. `DDFD` is
mostly the same entry points as `BASE`; only the opcodes that use `(HL)` as
memory get their own programs, prefixed with a displacement read and the
5-T-state internal cycle that computes IX+d.

## Bus timing

Cycle lengths and pin behaviour follow the part: M1 is 4 T with the refresh
address on the bus during T3–T4, memory cycles are 3 T, I/O cycles are 4 T,
and WAIT stretches the strobe T-state.

Strobes default to the one-T-state model the SingleStepTests suite uses —
MREQ/RD/WR pulse in T2 for memory and T3 for I/O — which is also what a
synchronous FPGA memory wants: the address is stable from T1 and the byte is
latched at the end of T2. `STROBE_1T = 0` holds them across the cycle the way
the real part drives an external bus.

The address register holds its last value through internal cycles, so the
refresh address stays on the pins during, say, the two extra T-states of
`INC BC`. The bus traces in the test suite check this, and it is not
cosmetic — external glue that decodes the bus sees the same thing.

## Size

On an iCE40 (yosys, `synth_ice40`), the core alone:

```
4641  SB_LUT4
 338  flip-flops
   3  SB_RAM40_4K      (the dispatch tables)
```

The micro-code ROM accounts for about 770 LUTs of that; the rest is the
datapath — the register file's read muxes and write decoder, the ALU, and the
composite-operation block. The dispatch tables are read synchronously, when
the opcode byte is latched, which is at least one T-state before the answer is
needed; that is what lets them sit in block RAM instead of a 1280-entry mux.

On an ECP5 (`synth_ecp5`, LFE5U-25F), the same core:

```
5303  LUT4
 261  CCU2C           (carry, two LUT4 positions each)
 335  flip-flops
   1  DP16KD          (the dispatch tables)
```

That is 5825 LUT4 positions once the carry cells are counted the way nextpnr
counts them, against the iCE40's 4641 — a difference in how carry logic is
accounted for as much as in how much logic there is. Only one block RAM this
time, because an ECP5's is 18 Kbit rather than 4 Kbit and all 1280 dispatch
entries fit in one.
