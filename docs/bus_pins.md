# Driving a real Z80 bus

The strobes of the core change on whole T-states. That is correct for the
SingleStepTests suite and for a synchronous FPGA memory. A real Z80 bus is
different: the real part changes some strobes at the falling edge in the
middle of a T-state, and samples read data at that falling edge. To drive a
real bus, put a pin stage between the core and the pins. The pin stage makes
the half-T-state edges. The core gives the pin stage the information that it
needs.

The [z80replacement](https://github.com/avwohl/z80replacement) project uses
the core this way: an FPGA module in the socket of a Z80. Its file
`docs/bus_timing.md` has the edge table of the Z84C00 data sheet, with the
parameter numbers.

## Parameters

The three parameters are 0 by default. With all three at 0, every new term
in the core is a constant. The core then has the same logic as before the
parameters existed.

| Parameter | Effect |
|---|---|
| `LATE_READ` | A memory read and an I/O read take the byte at the end of T3, not at the end of T2. Opcode fetches and the interrupt vector are still taken at the end of T2. |
| `BUSREQ` | `busrq_n` works. The core stops at the end of an M-cycle, sets `bus_float` and lowers `busak_n`. |
| `REAL_ACK` | The interrupt acknowledge and the NMI response have the timing, the refresh and the R count of the real part. |

### LATE_READ

The real part samples the data of an opcode fetch at the rising edge that
starts T3. It samples the data of a memory read or an I/O read at the falling
edge in the middle of T3, half a T-state later. A core that takes all bytes
at the rising edge gives memory and I/O devices half a T-state less time than
the real part.

With `LATE_READ = 1`, the pin stage captures the byte at the T3 falling edge
and holds it on `din` until the end of T3. The core takes the byte at the
rising edge that ends T3. The DD CB displacement byte and the DD CB opcode
byte are memory reads, so they also use the late edge.

A read of 3 T-states (4 for I/O) now ends on the edge that takes its byte.
The action of the next micro-op happens on that edge too, and the action can
read the byte. Thus the core uses `rdin_v` and `rwz_v` (DIN and WZ as that
edge sees them), in the same way as the `_x` signals in
[architecture.md](architecture.md). The read byte also gets its own register
write port. The write port of the action comes after that port. Thus the
action wins if both write the same register.

`make test-full-late` runs the complete opcode suite on this core. The pins
do not change, so the same bus traces apply. If the core reads WZ or DIN
without these views, JP, RET, JR, IN A,(n) and ADD A,(HL) fail.

With `STROBE_1T = 0`, a late read also keeps its strobes active through T3.

### BUSREQ

The real part samples `/BUSREQ` at the rising edge that starts the last
T-state of each M-cycle. If `/BUSREQ` is low, the real part floats the bus at
the end of that T-state and lowers `/BUSACK`. It then samples `/BUSREQ` at
each rising edge. In the T-state that starts with `/BUSREQ` high, `/BUSACK`
goes high at the falling edge, and the next M-cycle starts at the next rising
edge.

With `BUSREQ = 1`, the core does the same:

- The core samples `busrq_n` at each `clk_en` edge.
- At the edge that ends an M-cycle, if `busrq_n` was low at the start of the
  last T-state, the core does not do that edge. It stays in the last T-state
  of the M-cycle with `bus_float` high and `busak_n` low.
- `mreq_n`, `iorq_n`, `rd_n`, `wr_n`, `m1_n` and `rfsh_n` are high while
  `bus_float` is high.
- `bus_resume` is high in the last T-state of the hold. The pin stage can
  raise `/BUSACK` at the falling edge of that T-state, as the real part does.
  `busak_n` from the core goes high at the next rising edge.
- A T-state that starts with `busrq_n` high is the last T-state of the
  hold. At the edge after it, the core does the edge that it did not do,
  and the next M-cycle starts.

The core does not drive tri-state outputs. The pin stage must float the
address bus, the data bus, `/MREQ`, `/IORQ`, `/RD` and `/WR` while
`bus_float` is high. `/M1`, `/RFSH`, `/HALT` and `/BUSACK` do not float.

`sim/tb_busrq.sv` checks this protocol. Refer to
[verification.md](verification.md#busrq).

### REAL_ACK

The real part makes the interrupt acknowledge in 6 T-states: T1, T2, two
automatic wait states (TW1 and TW2), T3 and T4. /IORQ goes low at the
falling edge in TW1. The real part samples /WAIT at the falling edge in TW2
and takes the vector at the rising edge that starts T3. T3 and T4 are a
refresh, as in an opcode fetch. The NMI response is an opcode fetch whose
byte the real part ignores, with one more T-state.

Without `REAL_ACK`, the core samples `wait_n` in the 3rd T-state of the
acknowledge and takes the vector at the end of it. That is one T-state too
early for a real device, because /IORQ is then low for only half a T-state.
The NMI response has no wait states. Neither cycle has a refresh.

With `REAL_ACK = 1`:

- The acknowledge samples `wait_n` in its 4th T-state (TW2) and takes the
  vector at the end of that T-state. `bus_t` stays at 4 during wait states.
- The NMI response samples `wait_n` in T2 and takes its byte at the end of
  T2, as an opcode fetch. The core asserts `mreq_n` and `rd_n` in the cycle.
- Both cycles put I and R on `a` in T3 and T4 (the 5th and 6th T-states of
  the acknowledge), assert `rfsh_n` there, and increment R.

The number of T-states does not change. `sim/tb_irq.sv` with
`-Ptb_irq.REAL_ACK=1` (`sim/tb_irq_real.vvp`) checks the cases again, checks
R, and gives the vector only in the 4th T-state of the acknowledge.

## Status ports

| Port | Width | Meaning |
|---|---|---|
| `bus_t` | 4 | The T-state of the M-cycle, 1 for T1. During wait states, `bus_t` stays at 2 in a memory cycle and at 3 in an I/O cycle or an interrupt acknowledge (at 4 in the acknowledge with `REAL_ACK`). |
| `bus_cyc` | 3 | The type of M-cycle, from the table below. |
| `bus_last` | 1 | High in the last T-state of the M-cycle. |
| `bus_float` | 1 | High while the bus is given away (`BUSREQ` only). |
| `bus_resume` | 1 | High in the last T-state of the hold (`BUSREQ` only). |

| `bus_cyc` | Cycle |
|---|---|
| 0 | Internal T-states, with no strobe |
| 1 | Opcode fetch (M1), with refresh in T3 and T4 |
| 2 | Memory read |
| 3 | Memory write |
| 4 | I/O read |
| 5 | I/O write |
| 6 | Interrupt acknowledge |
| 7 | The NMI response cycle |

A board that has no pin stage leaves these ports unconnected.

## What the pin stage must do

- Make each strobe edge from `bus_t` and `bus_cyc`, with registers on the
  falling edge for the edges in the middle of a T-state.
- Sample `/WAIT` at the falling edge of T2 (or of the wait state) and give
  the sampled value to `wait_n`. The core reads `wait_n` at the next rising
  edge.
- For an opcode fetch and an interrupt acknowledge, give the live data bus to
  `din`. For a memory read and an I/O read with `LATE_READ`, give the byte
  captured at the T3 falling edge.
- Hold the captured byte on `din` until the core takes it. A bus hold can
  start on the edge that takes the byte. In that case the core takes the
  byte after the hold, when the data bus belongs to another device.

## Known differences from the real part

- **BUSREQ grant point.** The core divides the internal T-states of an
  instruction into separate micro-ops. Each micro-op is an M-cycle for
  BUSREQ. The real part counts some of those T-states as part of the
  previous M-cycle. Thus the core can give the bus away a few T-states
  earlier than the real part, inside an instruction such as `INC BC`. The
  data and the result do not change.
- **Interrupt acknowledge and NMI response without `REAL_ACK`.** In these
  cycles, the core does not refresh: no refresh address on `a`, no
  `rfsh_n`, and no increment of R. The real part does all three. The NMI
  response cycle also has no `mreq_n` or `rd_n` from the core. `REAL_ACK`
  removes these differences.
- **/HALT.** The core changes `halt_n` on the rising edge at the end of T4.
  The real part changes /HALT at the falling edge in T4, half a T-state
  earlier.
