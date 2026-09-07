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

## Block RAM that is not block RAM

A memory with **two write ports has no RAM mapping on either family**, and
both tools fail at it silently. `sd_spi.sv`'s 512-byte sector buffer was
written that way. yosys says "using FF mapping for memory" and, if forced with
a `ram_style` attribute, "no valid mapping found"; Vivado says nothing at all
-- the Nexys RomWBW utilisation report shows **zero** RAMB18s and carries the
512 bytes as 4096 flip-flops, which on a part with 126,800 registers nobody
noticed. On an ECP5 the identical code made `sd_spi` alone **17,687 LUT4s**,
three quarters of an LFE5U-25F.

So: **one write port, however many reads.** If two things write a buffer,
check whether they are exclusive in time -- they usually are -- and mux them.
`grep "mapping for memory" yosys.log` after any change to a memory, and read
the RAMB rows of Vivado's utilisation report rather than assuming.

## The Nexys RomWBW build is delicate, and must not be perturbed

It is the only bitstream here that has run on hardware, and it sits at **94.81%
of the part's block RAM** -- 128 of 135 RAMB36 tiles, a 512 KB ROM that Vivado
cascades in pairs. Changing `sd_spi`'s buffer to the muxed form above makes its
`place_design` fail with **sixty-four `REQP-1962` "cascade ADDR15 pin check"**
errors. That was bisected: the pushed commit builds clean, that one file on top
of it does not.

It is not the block RAM the change adds. Asking for the muxed buffer as
`ram_style = "distributed"` keeps the tile count at exactly the baseline's 128
and it fails identically. Nor is it cell naming -- the same failure appears
with the hierarchy untouched. Something about that placement is simply fragile.

So `sd_spi` carries a `BUF_MUX` parameter, defaulting to the portable form,
and `boards/nexys_a7_100t/romwbw/top_romwbw.sv` pins it to 0 to get the
netlist it was proved with. `SDRAM_ROM` shrinks `u_rom` to two bytes rather
than removing it for the same instinct: a generate block would rename every
cell under that ROM.

**Rebuild that board after any change to `rtl/soc/` or `rtl/mem/`**, and check
for `ERROR: [DRC` in the log -- `place_design` failing is the failure mode,
and it takes about 25 minutes to find out.

## Board builds

`boards/arty_a7_100t` and `boards/nexys_a7_100t` want Vivado;
`boards/c0_microsd` and `boards/icepi_zero` want yosys and nextpnr from the
OSS CAD Suite, and `mingw32-make` on this machine (there is no plain `make`).
`boards/qomu` is a note explaining why the core does not fit an EOS S3, not a
build.

yosys on this machine does not understand MSYS paths — `/c/temp/...` is "file
not found" — so the nextpnr board Makefiles use relative paths from the board
directory, which works. A `$readmemh` inside the RTL resolves relative to the
Verilog source file, not the working directory.

**The Nexys A7-100T has run on hardware** — 2026-09-06, banner, `banked memory
ok` across all eight RAM banks, and console echo over the USB-UART. That is
the only target that has. The Arty flow is verified to a placed, routed,
timing-closed bitstream and no further; keep the two claims apart rather than
letting the hardware result leak onto the board nobody has plugged in.

The two boards use the same XC7A100T-CSG324 and both clock from E3, so an Arty
bitstream loads on a Nexys, asserts DONE and runs mute — every other pin
differs, and the Arty's LED pins drive the Nexys seven-segment display, which
makes it look alive. Tell them apart by the FTDI serial in the JTAG target:
`210292…` is the Nexys, `210319…` the Arty.

Timing closes only because `arty_a7_100t.xdc` says the core advances on a
`clk_en` tick one cycle in `CPU_DIV`. Those multicycle exceptions are load
bearing: without them the same design misses by 8.7 ns over 893 endpoints. If
you change `CPU_DIV`, the clock-enable structure, or the `en` on `sync_ram`,
the numbers in that file have to move with it. Two of its spellings fail
silently — an XDC rejects `if`/`puts`/`remove_from_collection`, and a
`REF_NAME =~ RAMB*` filter matches nothing before synthesis — so check the log
for "not supported in the xdc" and "No valid object(s) found" rather than
trusting that an exception applied.

**nextpnr-ecp5 has no such escape hatch.** Its LPF reader knows `LOCATE`,
`IOBUF`, `FREQUENCY`, `SYSCONFIG`, `BANK` and `BLOCK` and nothing else; a
`MULTICYCLE` or `MAXDELAY` line is accepted in total silence and does nothing,
and `set_multicycle_path` through `--sdc` is a hard error. So the ECP5 build
cannot run its fabric faster than its Z80: `boards/icepi_zero` halves the
50 MHz board clock and sets `CPU_DIV = 1`, because the core routes at
27.9–29.5 MHz on an LFE5U-25F. `FREQUENCY NET "clk_sys" 25 MHZ;` is what
constrains the derived clock, and an unconstrained internal clock is not
checked at all — the only proof it applied is
`constraining clock net 'clk_sys'` in `nextpnr.log`, which
`mingw32-make timing` prints.
