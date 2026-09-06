# Arty A7-100T

The primary bring-up target. The -100T has room for the core several times
over, so nothing here is squeezed.

## Build

The flow wants Vivado 2026.1 or later, which dropped the ML Standard and
Enterprise editions: the installer offers one product, Vivado Design Suite,
and a license tier decides what it will build. The free Basic tier covers all
of 7 Series, so it is enough for this board — but unlike the old Standard
edition it is a license you have to generate before Vivado will start at all.
[docs/vivado_license.md](../../docs/vivado_license.md) is how to get one and
what it is called now.

Two things bite here specifically. Leave the Artix-7 device family checked
when the installer asks what to install. And if your license file carries more
than one tier, Vivado takes the first one in the file rather than the one that
fits the part — land on `ALVEO` and the build dies at `create_project` with

```
ERROR: [Coretcl 2-106] Specified part could not be found.
```

which reads like a missing device family and may be either — the tier on the
startup banner tells you which. `BASIC` is the one that builds this board.

```
cd boards/arty_a7_100t
vivado -mode batch -source build.tcl
```

`build/z80fpga.bit` comes out the other end, along with `utilization.rpt` and
`timing.rpt`. It does not meet timing yet — see [Timing](#timing) below.
Program it with Vivado's hardware manager or `openFPGALoader -b arty_a7_100
build/z80fpga.bit`.

Regenerate `sw/boot.hex` first if you changed the monitor:

```
python tools/zasm.py sw/boot.z80 -o sw/boot.hex --size 32768
```

## Configuration

- **Clock** 100 MHz board oscillator, Z80 at 100/12 = 8.33 MHz (`CPU_DIV` in
  `top.sv`).
- **Console** the on-board USB-UART at 115200 8N1. `btn[0]` resets.
- **Memory** 2 ROM banks (64 KB) and 8 RAM banks (256 KB) in block RAM, about
  half of the part's 4860 Kbit.

`RAM_BANKS = 16` also fits, at roughly 95% of the block RAM, and is the
configuration that gives the RomWBW common-bank id 0x8F. The full 512 KB +
512 KB map does not fit in block RAM and wants the board's DDR3 behind a
cache — see [docs/roadmap.md](../../docs/roadmap.md).

## Timing

The flow routes and writes a bitstream, but the design does not close timing
and the bitstream has never been on hardware:

- **WNS** — -8.668 ns, **TNS** -3214 ns, 893 failing endpoints of 2665.
- **Hold** — clean (WHS +0.037 ns, no failing endpoints).
- **Worst path** — `u_cpu/upc_reg[3]` to `u_cpu/rL_reg[6]`, 18.7 ns over 23
  logic levels, 79% of it routing.

The constraints are the reason, not the logic depth. `z80_soc.sv` divides the
100 MHz fabric clock with a *clock enable*, not a clock: `clk_en` is asserted
one cycle in `CPU_DIV` (12 here), and every core register is gated by it. So
a core-to-core path has 120 ns to settle while `arty_a7_100t.xdc` gives it
one 10 ns period. Those paths need a multicycle exception before any of these
numbers mean anything.

The exception is not a blanket one: the block RAM in `sync_ram.sv` has its
write enable gated by `clk_en` but its read port free-running, so paths in
and out of memory have to be looked at separately from the register-to-
register ones. Until that is written and checked, treat the bitstream as
unproven.
