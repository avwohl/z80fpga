# DDR2 on the Nexys A7-100T

Bring-up for the board's 128 MiB of DDR2. **Verified on hardware** on
2026-09-06: it calibrates, and 1024 sixteen-byte lines written and read back
across 4 MB all match.

```
$ cd boards/nexys_a7_100t/ddr2
$ vivado -mode batch -source build_ddr2.tcl
$ # program build/ddr2_test.bit, then watch the console
CWP0000
```

That is the whole report, one character per milestone:

- **C** — `init_calib_complete`, the MIG finished calibrating against the part.
- **W** — the write pass finished.
- **P0000** — the read pass finished with `0x0000` mismatches. `F` and a
  non-zero count would mean the opposite.

The LEDs carry the same thing for when no terminal is attached: `led[0]`
calibrated, `led[1]` written, `led[2]` passed, `led[3]` failed.

This is not the SoC. It is the smallest design that proves the memory works
and that we can drive it, so the Z80 can be pointed at it next.

## Why it is built this way

- **512 KB of RAM already fits in block RAM**, measured at 128 of the part's
  135 RAMB36 tiles, so DDR2 is not what unblocks RomWBW's RAM. What it
  unblocks is the *ROM*: 512 KB of ROM alongside 512 KB of RAM is 1 MB and
  block RAM tops out near 540 KB. DDR2 holds both with 127 MB to spare.
- **AXI, not the native app interface.** Digilent's `mig.prj` enables the AXI4
  slave, and it is 128 bits wide with `C0_S_AXI_SUPPORTS_NARROW_BURST = 0`, so
  every access is a single beat of sixteen bytes with `AWSIZE = 4`. That is
  awkward for a Z80's single-byte accesses and exactly right for a
  sixteen-byte cache line, which is what the memory path will want anyway.
- **81.25 MHz.** The memory clock is 325 MHz (`TimePeriod` 3077 ps) at a 4:1
  PHY ratio, so `ui_clk` comes back at 325/4. Everything on this side of the
  AXI port runs on it, including the UART — whose divisor is computed from
  81.25 MHz, not 100 MHz. Get that wrong and the console prints garbage while
  the memory is perfectly fine.
- **`mig.prj` is committed here.** It is Digilent's, from their
  `vivado-boards` repository under the MIT licence, and carries the DDR2 part,
  the timing and all fifty pin assignments. With it the build needs no
  board-files install and the pinout cannot drift.

## Two things that will bite

**The MIG wants the raw clock pin.** Its generated XDC contains
`set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk_i]`, and it
even assigns `PACKAGE_PIN E3` and `LVCMOS25` to a port called `sys_clk_i` that
this design does not have. But the IODELAY reference has to be 200 MHz and the
board has one oscillator, so an MMCM has to be in the path and the system
clock comes off it too. That constraint then lands on the MMCM output and
implementation dies with

```
ERROR: [DRC RTRES-1] Backbone resources: 1 net(s) have CLOCK_DEDICATED_ROUTE
set to BACKBONE but do not use backbone resources.
```

`ddr2.xdc` relaxes it for that one net, which is the documented way out.

**Reset polarity.** MIG generates with `RST_ACT_LOW = 1`, so `sys_rst` is
active low and `CPU_RESETN` drives it directly. `aresetn` is separate and is
held low until the MIG's own `ui_clk_sync_rst` clears.

## What is not here yet

The Z80 cannot reach this memory. Wiring it in means a cache between the
core's byte-wide, `clk_en`-paced bus and the AXI port's sixteen-byte beats,
plus a way to get a ROM image into DDR2 at power-up, since DDR2 is volatile
and the reset fetch has to come from somewhere. Block RAM or the QSPI flash
can hold the first bank for that.
