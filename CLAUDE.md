# z80fpga

A Z80 CPU in SystemVerilog with RomWBW-compatible banked memory. `README.md`
says what it is; this file is only the things a session working on it has to
know that the code does not say.

## Build and test

```
source tools/ossenv.sh      # OSS CAD Suite on PATH; OSS_CAD_ROOT to relocate
make gen                    # regenerate the micro-code ROMs after a generator change
make sim
make test                   # SoC smoke test + 20 cases per opcode, ~40s
make test-full              # the whole SingleStepTests suite, ~1.6M cases
```

`make test-full` must stay at **0 failures across all 1604 opcodes**. It
compares the full architectural state including WZ and Q, the memory, the port
transaction, the T-state count, **and** the cycle-by-cycle bus trace. If a
change makes it fail, the change is wrong; the suite is not.

The suite lives outside the repo. `Z80_TESTS` or `--suite` points at a
checkout of https://github.com/SingleStepTests/z80.

## Do not hand-edit the generated files

`rtl/core/z80_defs.svh`, `z80_ucode.mem` and `z80_dispatch.mem` all come from
`tools/gen_z80.py`, which in turn takes its field encodings from
`tools/z80_enc.py`. Edit those and run `make gen`. They are committed because
the RTL reads them at elaboration; that does not make them sources.

## The one rule the micro-code engine imposes

The action of a micro-op is applied on the clock edge that *enters* it, which
is the same edge on which the previous bus cycle retires. A zero-length
(`BUS.NONE`) micro-op's bus cycle is therefore the *next* micro-op's, started
on that same edge — so the next micro-op may not carry an action of its own.
`gen_z80.py` asserts this and names the offending opcode.

The corollary that bites: any register the fetch writes on that edge needs an
"as the entry edge sees it" copy, because the action would otherwise read the
stale value. `z80_core.sv` has `ir_x`, `pc_x`, `wz_x`, `q_x`, `r_x` and
`bc_x` for exactly this, and every one of them was a bug the suite caught.
`docs/architecture.md` has the table.

## Lint

`make lint` runs Verilator over the core and the SoC. On this machine it has
to be typed at the shell instead:

```
verilator --lint-only -Wall +incdir+rtl/core --top-module z80_soc \
    -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-MULTIDRIVEN \
    rtl/core/z80_alu.sv rtl/core/z80_core.sv rtl/mem/sync_ram.sv \
    rtl/soc/z80_mmu.sv rtl/soc/uart.sv rtl/soc/z80_soc.sv
```

The OSS CAD Suite's Verilator is a Perl wrapper that finds its own headers
from `$RealBin`, and under `mingw32-make` that resolves to the suite's build
prefix rather than where it is installed. MULTIDRIVEN is waived because
Verilator counts every task that does a non-blocking assignment as its own
process, and all of them are called from the single `always_ff` in
`z80_core.sv`.

## Board builds

`boards/arty_a7_100t` wants Vivado; `boards/c0_microsd` wants yosys and
nextpnr from the OSS CAD Suite, and `mingw32-make` on this machine (there is
no plain `make`). `boards/qomu` is a note explaining why the core does not fit
an EOS S3, not a build.

No hardware has ever run this. The board flows are verified to a placed,
routed, timing-closed bitstream and no further — say so rather than implying
otherwise.
