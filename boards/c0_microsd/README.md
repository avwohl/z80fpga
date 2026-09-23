# Signaloid C0-microSD

An iCE40UP5K-UWG30 in a microSD card. The whole SoC fits, with very little to
spare.

## Build

```
source ../../tools/ossenv.sh
cd boards/c0_microsd
mingw32-make            # or make, on a machine that has it
```

`z80fpga.bin` comes out. Loading it needs Signaloid's own tooling — see
[C0-microSD-utilities](https://github.com/signaloid/C0-microSD-utilities);
`iceprog` does not apply to this board.

## What it builds to

```
ICESTORM_LC     5076 / 5280   96%
ICESTORM_RAM      20 /   30   66%
SB_SPRAM256KA      4 /    4  100%
SB_IO              5 /   21
Max frequency for clk_sys: 8.65 MHz (PASS at 6.00 MHz)
```

96% of the logic is not comfortable. The two reductions that would fix it —
sharing the register-file read ports and moving the micro-code ROM into block
RAM — are in [../../docs/roadmap.md](../../docs/roadmap.md), and together are
worth roughly 1200 LUTs.

## Configuration

- **Clock** the 12 MHz board oscillator, halved to 6 MHz on a global buffer,
  and one T-state per clock: a 6 MHz Z80. The halving is not a preference —
  the core closes at about 8.7 MHz at this utilisation, and the iCE40 PLL
  cannot synthesise anything below 16 MHz, so a divider is the only way down.
- **Console** 115200 8N1 on the SD breakout pins: TX on SD_CMD (A4), RX on
  SD_DAT0 (A1). The board's clock pin B3 doubles as SD_CLK, which is why the
  receive line does not come from LiteX's `serial` entry.
- **Memory** the four SPRAM blocks give exactly four 32 KB RAM banks, 128 KB.
  Block RAM cannot hold even one bank on this part, so SPRAM is not an
  optimisation, it is the only option. The boot ROM is 8 KB of block RAM and
  mirrors across the rest of ROM bank 0.
- **LEDs** the red and green LEDs show bits 0 and 1 of the LED port (0xFF).

Pin assignments follow
`litex-boards/litex_boards/platforms/signaloid_c0_microsd.py`.

## RomWBW will not run here, and that is arithmetic

**512 KB of RAM cannot be found on this module in any configuration**, so the
question does not need re-opening. The iCE40UP5K has four SPRAM blocks of
256 Kbit — 128 KB in total, which is the four RAM banks above and nothing left
over — and 120 Kbit of block RAM, which cannot hold even one 32 KB bank. There
is no external RAM on the C0-microSD, and in a microSD form factor there are
six usable pads, none of them a memory bus. Lattice is explicit that SPRAM has
no configuration preload (FPGA-DS-02008-2.0 §3.1.6), so it cannot be a ROM
either.

The ROM half is less absolute and worth stating precisely, because the obvious
objection is the wrong one: the 16 MiB AT25QL128A on the module is large
enough, the ROM is read-only (`sync_ram` gates every write on `READ_ONLY`), and
the SoC already has a `wait_n` path that could stall the core for a slow fetch.
So a 512 KB ROM executing in place out of flash is *architecturally* available.
It is the RAM that is impossible, not the ROM.

The tier that does fit is the one that is here: the core, a UART and a monitor.
See [../../docs/porting.md](../../docs/porting.md) for what the two tiers mean.

## The clock comes from the host, which is worth knowing

`top.sv` takes `clk12` on pin B3, and B3 is **SD_CLK**. There is no oscillator
on this module — the schematic's whole BOM is the FPGA, a flash, two
regulators, two LEDs, a diode and passives — so this design runs only while
something is clocking the SD bus, at whatever rate that something chooses.

The part has its own oscillator. `SB_HFOSC` gives 48 MHz with a `CLKHF_DIV`
divider down to 6 MHz, which is what the timing report above is already
measured against, and it would make the board self-clocked. That is the first
change to make if one of these ever reaches a bench.

## Untested on hardware

No C0-microSD was available. This is verified to a placed, routed,
timing-closed bitstream and no further; the SoC itself is verified in
simulation (`make test` at the repository root). At 96% of the logic cells the
two reductions in [../../docs/roadmap.md](../../docs/roadmap.md) are worth
about 1200 LUTs between them, which would take it to roughly 74% — not urgent,
but the margin is thin enough that a future core change could simply fail to
place.
