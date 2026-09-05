# Arty A7-100T

The primary bring-up target. The -100T has room for the core several times
over, so nothing here is squeezed.

## Build

```
cd boards/arty_a7_100t
vivado -mode batch -source build.tcl
```

`build/z80fpga.bit` comes out the other end, along with `utilization.rpt` and
`timing.rpt`. Program it with Vivado's hardware manager or `openFPGALoader -b
arty_a7_100 build/z80fpga.bit`.

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
