# Arty A7-100T

The -100T has room for the core several times over, so nothing here is
squeezed. No Arty has ever run this, though — bring-up happened on a
[Nexys A7-100T](../nexys_a7_100t/README.md), which carries the same
XC7A100T-CSG324 part. This target is verified to a timing-closed bitstream and
no further.

If your board is silent, check which board it is before anything else: an Arty
bitstream loads happily on a Nexys, asserts DONE and runs completely mute,
because the two share the part and the E3 clock and nothing else. The Nexys
README has the pin differences and how to tell the boards apart.

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

The design meets timing at the 100 MHz board clock, with 0 failing endpoints
on setup, hold and pulse width. It has still never been on hardware.

- **WNS** — +0.927 ns, **TNS** 0.000 ns, 0 of 2506 endpoints failing.
- **Hold** — WHS +0.037 ns, THS 0.000 ns.
- **Utilization** — about 3000 LUTs (4.7%), 392 registers, 72 block RAM
  tiles (53%). The LUT count wanders by a few between runs.

Closing it is entirely a matter of constraints, and the constraints are the
interesting part of `arty_a7_100t.xdc`. The core runs on a *clock enable*, not
a divided clock: `clk_en` is high one cycle in `CPU_DIV`, and every register in
`z80_core` is gated by it, so a core-to-core path has twelve periods rather
than one. Left unsaid, the tools try to close the 23-level path out of the
microcode ROM in 10 ns, miss by 8.7 ns and report 893 failing endpoints.

The exception cannot be a blanket one, which is what makes it worth reading:

- **The core** gets twelve, less `nmi_q` and `nmi_pend` — the only registers in
  it that update on every clock rather than on `clk_en`.
- **The memory** shares a budget, six cycles out and six back. `sync_ram` is
  instantiated with `en = 1'b1`, so the block RAM latches its address every
  clock; the intermediate captures are harmless, because the write enable is
  gated by `clk_en` and the core samples `rdata` only on `latch_now`. But the
  RAM has a clock of read latency, so whatever the address takes comes out of
  what the read data has left. Give the address the full eleven and the return
  path is left with a single cycle, which fails by 0.270 ns.
- **The peripherals** get twelve. `led`, the MMU bank register and the UART
  transmit register are all written under `port_wr`, which `z80_soc` ANDs with
  `clk_en`. The UART's shift register also advances on its own baud divider,
  but a timing exception is per path rather than per register, so those paths
  stay single-cycle.

Two spellings in that file are load-bearing, and both fail quietly rather than
loudly. An XDC is a restricted Tcl dialect that rejects `if`, `puts` and
`remove_from_collection`, leaving the variable they were building undefined and
the exception inert. And the filters are evaluated before synthesis as well as
for implementation, so `REF_NAME =~ RAMB*` matches nothing on the first pass —
the primitives do not exist yet. `IS_SEQUENTIAL` matches at both.
