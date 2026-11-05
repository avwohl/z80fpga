# z80fpga on macOS

What to install on a Mac, and how to use the simulation, the Nexys A7-100T
board and the GDB bridge from the Mac. The earlier work on this project was on
Windows. The steps below were measured on 2026-11-05 on macOS 27 (arm64), with
a Nexys A7-100T on USB. A step that was not run says so.

## What runs on a Mac, and what does not

| Task | On a Mac |
|---|---|
| Simulation (`make test`, `make test-debug`) | yes |
| Lint (`make lint`) | yes |
| The GDB bridge on the cosim | yes |
| Load a bitstream into the board (JTAG) | yes, with openFPGALoader |
| The serial console of the board | yes |
| Build a bitstream for the Nexys A7 | no: Vivado runs on Windows and Linux only |
| The debug unit on the board | needs a bitstream from Vivado; no adapter (`--jtag`, `pyftdi`) |

## Install

With [Homebrew](https://brew.sh):

```
brew install icarus-verilog verilator openfpgaloader
python3 -m pip install --user --break-system-packages pyserial pyftdi
```

- `icarus-verilog` gives `iverilog` and `vvp` (13.0 was measured).
- `verilator` is for `make lint` (5.054 was measured).
- `openfpgaloader` loads a bitstream through the USB port of the board (1.2.0
  was measured). It takes the place of the Vivado hardware manager.
- `pyftdi` is for the GDB bridge with `--jtag`: the bridge talks JTAG to the
  board through the USB cable. It needs no adapter.
- `pyserial` is for the GDB bridge with `--serial`. Use a virtual environment
  if you do not want a `--user` install.

For the debugger:

```
python3 -m pip install --user --break-system-packages "um80>=0.4.2"
brew install gdb
```

- um80 gives `udb80` and `dbg2elf`, and `um80` and `ul80` with
  `--debug-info`.
- GDB must have the Z80 target. The Homebrew formula `gdb` is built with
  `--enable-targets=all`, which includes z80. A GDB 18.1 built with the
  options of the formula was measured here. The Homebrew bottle itself was not
  installed. The um80_and_friends document
  [gdb.md](https://github.com/avwohl/um80_and_friends/blob/main/docs/gdb.md)
  has the build from source.

The OSS CAD Suite and `tools/ossenv.sh` are for Windows. On a Mac, the
Homebrew tools are on `PATH`, and you do not source `tools/ossenv.sh`.

## Simulation

```
git clone --depth 1 https://github.com/SingleStepTests/z80.git ~/src/z80tests
make test Z80_TESTS=$HOME/src/z80tests
make test-debug
make lint
```

`make test` needs the opcode suite (about 280 MB) outside this repository.

Measured:

- `make test`: `0/72 assembler cases failed`, `PASS: all interrupt cases`,
  `0/32080 tests failed across 1604 opcodes`.
- `make test-debug`: the three debug-unit benches (305, 308 and 317 checks)
  and the bridge test (253 checks).
- `make lint`: no warning.

The Makefile uses `python3` when `python3` runs, and `python` if not. macOS
has no `python`.

## The board on USB

The Nexys A7 has one USB port with an FTDI FT2232. macOS gives each of its two
channels a serial device, with the serial number of the board in the name:

```
/dev/cu.usbserial-210292BD6CD40    channel A: JTAG
/dev/cu.usbserial-210292BD6CD41    channel B: the console UART
```

The names on your Mac have the serial number of your board. macOS has the
FTDI driver. You install no driver, and you do not unload one for JTAG.

### Load a bitstream

Build the bitstream on a Windows or Linux machine with Vivado
(`boards/nexys_a7_100t/romwbw/README.md`), and copy `build/romwbw_soc.bit` to
the Mac. Then:

```
openFPGALoader -b nexys_a7_100 --detect
openFPGALoader -b nexys_a7_100 build/romwbw_soc.bit
```

- `--detect` reads the FPGA only. Measured: `idcode 0x3631093`, `artix a7
  100t`. The console worked after the JTAG access.
- The second command loads the bitstream into the FPGA. The FPGA loses it at
  power off, and the board then starts from its flash again. This command was
  not run: no bitstream was on the Mac.
- `openFPGALoader -b nexys_a7_100 -f FILE.bit` writes the flash of the board.
  This command was not run. `boards/nexys_a7_100t/flash.tcl` is the Vivado
  way.

### The console

```
screen /dev/cu.usbserial-210292BD6CD41 115200
```

To leave `screen`, type ^A, then `k`, then `y`. `brew install picocom` gives
`picocom -b 115200 /dev/cu.usbserial-210292BD6CD41`, which `picocom`
leaves with ^A ^X. Use the `cu.` device, not the `tty.` device: `tty.` waits
for a carrier signal. Measured: the board sent the RomWBW device list and
`Boot [H=Help]:`, and `H` gave the help text. The measurement used a small
Python program on the device, not `screen`.

## The debug unit on the board

A bitstream with the debug unit is necessary, and it was not on the Mac on
2026-11-05. Build the bitstream with Vivado and `Z80_DEBUG_UNIT=1` on Windows
or Linux (`MANUAL_CHECKS.md`, "Debug unit on the Nexys A7-100T").

The unit needs no adapter. The unit speaks JTAG (USER3) over the same USB cable
that loads the bitstream. The cable keeps channel A for JTAG and channel B for
the console, so the console works at the same time. Run:

```
python3 -m pip install --user --break-system-packages pyftdi
python3 tools/z80dbg_jtag.py --check
python3 tools/z80dbg_bridge.py --jtag --listen 1234
```

`--check` reads the IDCODE. Measured on 2026-11-05: 0x13631093 at 6 MHz and at
30 MHz, with pyftdi, with no extra step for libusb. One program at a time holds
channel A, so close `openFPGALoader` and the hardware manager of Vivado before
you start the bridge. For the serial link on Pmod JA (other builds), use
`--serial /dev/cu.ADAPTER` with `Z80_DEBUG_LINK=uart`.

Connect GDB or udb80 as [debug_unit.md](debug_unit.md) says (The GDB bridge).
The same steps work on the cosim with no board: replace `--serial DEVICE`
with `--vvp sim/tb_debug_cosim.vvp`. On the cosim, GDB 18.1 and udb80 0.4.2
stopped at a program with `monitor wait-program` (measured).
