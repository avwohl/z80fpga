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
ICESTORM_LC     5107 / 5280   96%
ICESTORM_RAM      20 /   30   66%
SB_SPRAM256KA      4 /    4  100%
SB_IO              5 /   21
Max frequency for clk_sys: 8.64 MHz (PASS at 6.00 MHz)
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

## Untested on hardware

No C0-microSD was available. This is verified to a placed, routed,
timing-closed bitstream and no further; the SoC itself is verified in
simulation (`make test` at the repository root).
