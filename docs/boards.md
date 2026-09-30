# Boards

- **[Nexys A7-100T](../boards/nexys_a7_100t/)** — the one that has run. RomWBW
  and CP/M 2.2, with 512 KB of ROM in block RAM and 512 KB of RAM in DDR2;
  console on the on-board USB-UART. `romwbw/` is that build, `ddr2/` the
  memory bring-up.
- **[Arty A7-100T](../boards/arty_a7_100t/)** — same part, different pinout.
  8.33 MHz Z80, 64 KB ROM and 256 KB RAM in block RAM. Timing-closed but never
  run: no Arty was ever attached.
- **[Icepi Zero](../boards/icepi_zero/)** — an ECP5 LFE5U-25F in a Pi Zero
  footprint, and the fastest Z80 here at 25 MHz. Three builds:
  32 KB of ROM and 64 KB of RAM in block RAM,
  [`sdram/`](../boards/icepi_zero/sdram/) with the full 512 KB of RAM in the
  board's SDRAM, and [`romwbw/`](../boards/icepi_zero/romwbw/) with the ROM in
  there too — fetched off the microSD card at power-up, because 126 KB is all
  the byte-wide ROM this part's block RAM can hold and a bitstream therefore
  cannot carry a RomWBW image. yosys and nextpnr, and the board programs
  itself over its own USB-C.
- **[Signaloid C0-microSD](../boards/c0_microsd/)** — fits, at 94% of the
  UP5K's logic. 128 KB of RAM in the four SPRAM blocks, an 8 KB boot ROM,
  console on the SD breakout pins.
- **[Tang Nano 20K](../boards/tang_nano_20k/)** — a Gowin GW2AR-18 with 8 MB of
  SDR SDRAM *inside the package*, the only small board here whose RomWBW-sized
  memory needs no board wiring at all. 8 KB of ROM and 64 KB of RAM in block
  RAM, a 27 MHz Z80, yosys and nextpnr. It builds, it has been loaded onto a
  real board, and **it prints its banner and then restarts** — the one target
  here that has run and not worked. The design is not why: `make gatesim` runs
  the monitor on the synthesised netlist and gets the whole thing, bank check
  included. That board's README has what is ruled out and what is left.
- **[Qomu](../boards/qomu/)** — does not fit, and cannot. The note explains why
  and what the board is good for instead.

[porting.md](porting.md) is what a new board costs: what it inherits
from `rtl/`, what is irreducibly per board, and the one file that is less
portable than it looks.

What has and has not run, kept honest: the Nexys A7-100T boots RomWBW's HBIOS
and CP/M 2.2 on real silicon, off a bitstream in the board's QSPI flash. The
Icepi Zero runs too, on a v1.3: `banked memory ok` and a console at 25 MHz,
and its `sdram/` build passes the same check across all sixteen banks of the
board's SDRAM. The Arty and C0-microSD builds are verified to a placed,
routed, timing-closed bitstream and no further, because neither of those
boards has been attached. The Tang Nano 20K runs as well, and
reports through its configuration flash because that board's UART bridge is
dead hardware: `banked memory ok` and the prompt. It spent a long time
printing only its banner, and the fault turned out to be in this repository
after all -- a read mux whose select was a clock ahead of the data it was
selecting, which broke instruction fetch out of the common bank and nothing
else. The SD-backed disks read *and* write: CP/M copies a file to `C:`,
and after reconfiguring the FPGA the file is still there and runs from the
card.
[boards/nexys_a7_100t/romwbw](../boards/nexys_a7_100t/romwbw/) has the bug that
made writes fail -- a wait reply one clock too late to stall the read it
belonged to -- and the measurement traps it cost along the way.

## The serial console

Every board's console runs at 115200 8N1 with no flow control. Each board's
README says which port and pins carry the console.

`tools/console.ps1` is a minimal Windows terminal that needs nothing installed:

```
powershell -ExecutionPolicy Bypass -File tools/console.ps1 -Port COM3
```

`console.ps1` is enough for the RomWBW boot loader and the CP/M command line.
`console.ps1` is not a VT100, so full-screen programs such as WordStar, ZDE and
Zork's status line do not draw properly. For those programs use a terminal
emulator:

- **PuTTY**: connection type Serial, serial line `COMn`, speed 115200. Under
  Connection > Serial, set flow control to None.
- **Tera Term**: New connection > Serial, pick the port. Under Setup > Serial
  port, set 115200, 8 data bits, no parity, 1 stop bit, flow control none.
  Under Setup > Terminal, set the terminal ID to VT100.
- **Linux or macOS**: `picocom -b 115200 /dev/ttyUSB1` or
  `screen /dev/ttyUSB1 115200`. The device name depends on the board and the
  host.

Only one program can hold a serial port at a time. Close one terminal before
opening another, and close the terminal before a tool that shares the port,
such as the Icepi Zero's programmer.

## Third-party files and the RomWBW ROM

The two `mig.prj` files are Digilent's, from their
[vivado-boards](https://github.com/Digilent/vivado-boards) repository under the
MIT licence, and are included unmodified so the DDR2 build needs no board-files
install. The Icepi Zero's pin assignments come from
[cheyao/icepi-zero](https://github.com/cheyao/icepi-zero)'s own constraint
file, under the zlib licence, altered. Both are recorded in
[THIRD-PARTY.txt](../THIRD-PARTY.txt). Nothing else here is anyone else's: the
RomWBW ROM the board runs is deliberately *not* committed. Point `ROMWBW_ROM`
at an image you already have, or let `tools/romwbw_fetch.py` take
`Binary/SBC_simh_std.rom` out of the
[RomWBW](https://github.com/wwarthen/RomWBW) release package for you. No disk
image is needed: the card's CP/M slices are made in place, by `FDISK80` and
`CLRDIR` inside the booted machine. A prepared image may be written on instead,
which `boards/icepi_zero/romwbw/README.md` describes and nobody has tried.
