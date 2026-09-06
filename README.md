# z80fpga

A Zilog Z80 in SystemVerilog, with RomWBW-compatible banked memory. It boots
RomWBW and CP/M 2.2 on a Digilent Nexys A7-100T.

The core is **microcoded**: `tools/gen_z80.py` describes the instruction set in
Python and emits the micro-program ROM, the opcode dispatch tables and the
field encodings the RTL uses. Adding an instruction means adding a line to the
description, not editing a decoder — which is the point, because the plan is
to extend this to the Z180 and possibly the eZ80.

It passes the whole of the
[SingleStepTests](https://github.com/SingleStepTests/z80) suite:

```
0/1604000 tests failed across 1604 opcodes (1604 opcodes clean)
```

That is every opcode including the DD/FD/ED/CB and DD CB prefixed forms, 1000
randomised cases each, compared on the full architectural state — the
undocumented X and Y flags, MEMPTR (WZ), the Q register that SCF and CCF read,
I, R, IFF1/IFF2 and the interrupt mode — **and** on the cycle-by-cycle bus
trace: address, data and the RD / WR / MREQ / IORQ pins in every T-state.

The suite says nothing about interrupts, so `sim/tb_irq.sv` covers those
separately: NMI, IM 0, IM 1, IM 2, the EI delay, masking by IFF1, and waking
from HALT, each checked against the databook's T-state count.

## What is here

| | |
|---|---|
| `rtl/core/` | the CPU: ALU, sequencer, and the generated ROMs |
| `rtl/soc/` | banked-memory MMU, UART, and a small SoC around the core |
| `rtl/mem/` | block-RAM and iCE40 SPRAM backing stores |
| `tools/gen_z80.py` | the instruction-set description and the ROM generator |
| `tools/run_sst.py` | the SingleStepTests harness |
| `tools/zasm.py` | a Z80 assembler, for the boot ROM and test programs |
| `sim/` | test benches |
| `sw/boot.z80` | the boot monitor: banner, bank check, console echo |
| `boards/` | Nexys A7-100T (runs on hardware), Arty A7-100T, Signaloid C0-microSD, and why not the Qomu |

`docs/architecture.md` explains how the microcode engine works,
`docs/verification.md` how it is tested, `docs/memory_banking.md` the bank map,
and `docs/roadmap.md` what the Z180 and eZ80 need.
`docs/vivado_license.md` is for the Vivado builds: what the free licence is
called since 2026.1 renamed it, and how to get one.
`docs/romwbw.md` is how a stock RomWBW ROM boots on this core, all the way to
CP/M 2.2 on real hardware, and what the console has to look like for that.

## Getting the tools

Everything here builds with the [OSS CAD
Suite](https://github.com/YosysHQ/oss-cad-suite-build) — Icarus Verilog for
simulation, yosys and nextpnr for the iCE40 bitstream. Unpack it and:

```
source tools/ossenv.sh          # set OSS_CAD_ROOT if it is not /c/temp/tools
```

The Arty flow wants Vivado. The test harness wants a checkout of
[SingleStepTests/z80](https://github.com/SingleStepTests/z80); point
`Z80_TESTS` or `--suite` at it.

## Running it

```
make gen                        # regenerate the microcode ROMs
make sim                        # build the benches
make test                       # assembler, interrupts, SoC boot, opcode sweep
make test-full                  # the whole suite, ~1.6M cases
```

`make test` boots the monitor in simulation and should print:

```
z80fpga ready
banked memory ok
>
```

— the banner, the result of writing a signature into every RAM bank and
reading it back, and the prompt. Then it types `AB<CR>` at the UART and checks
what comes back.

## The core

```
z80_core #(.STROBE_1T(1)) (
    clk, rst_n, clk_en,
    a, din, dout,
    mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n, busak_n,
    wait_n, int_n, nmi_n, busrq_n
);
```

One `clk_en` tick is one T-state, so the CPU speed is set by how often you
raise it; tie it high to run at the fabric clock. The pins behave like the
part: M1 with a refresh address on T3–T4, 3-T memory cycles, 4-T I/O cycles,
WAIT stretching, and NMI, IM 0, IM 1 and IM 2 interrupt acknowledge.

`STROBE_1T` picks between the one-T-state strobes the test suite models
(default, and what a synchronous FPGA memory wants) and holding MREQ/RD/WR
across the cycle the way the real part drives an external bus.

## Boards

- **[Nexys A7-100T](boards/nexys_a7_100t/)** — the one that has run. RomWBW
  and CP/M 2.2, with 512 KB of ROM in block RAM and 512 KB of RAM in DDR2;
  console on the on-board USB-UART. `romwbw/` is that build, `ddr2/` the
  memory bring-up.
- **[Arty A7-100T](boards/arty_a7_100t/)** — same part, different pinout.
  8.33 MHz Z80, 64 KB ROM and 256 KB RAM in block RAM. Timing-closed but never
  run: no Arty was ever attached.
- **[Signaloid C0-microSD](boards/c0_microsd/)** — fits, at 94% of the
  UP5K's logic. 128 KB of RAM in the four SPRAM blocks, an 8 KB boot ROM,
  console on the SD breakout pins.
- **[Qomu](boards/qomu/)** — does not fit, and cannot. The note explains why
  and what the board is good for instead.

What has and has not run, kept honest: the Nexys A7-100T boots RomWBW's HBIOS
and CP/M 2.2 on real silicon, off a bitstream in the board's QSPI flash. The
Arty and C0-microSD builds are verified to a placed, routed, timing-closed
bitstream and no further, because neither board was ever attached. The
SD-backed disks read *and* write: CP/M copies a file to `C:`, and after
reconfiguring the FPGA the file is still there and runs from the card.
[boards/nexys_a7_100t/romwbw](boards/nexys_a7_100t/romwbw/) has the bug that
made writes fail -- a wait reply one clock too late to stall the read it
belonged to -- and the measurement traps it cost along the way.

## Licence

GPLv3 — see [LICENSE](LICENSE).

The two `mig.prj` files are Digilent's, from their
[vivado-boards](https://github.com/Digilent/vivado-boards) repository under the
MIT licence, and are included unmodified so the DDR2 build needs no board-files
install; see [THIRD-PARTY.txt](THIRD-PARTY.txt). Nothing else here is anyone
else's: the RomWBW ROM and disk images the board runs are deliberately *not*
committed, and are fetched from the
[RomWBW](https://github.com/wwarthen/RomWBW) release package instead.

## Related Projects

- [80un](https://github.com/avwohl/80un) - Unpacker for the CP/M archive and compression formats LBR, ARC, squeeze, crunch, and CrLZH. A Python 3 program and a native CP/M program give the same output.
- [cpmdroid](https://github.com/avwohl/cpmdroid) - Z80/CP/M emulator for Android phones and tablets. It emulates the RomWBW HBIOS interface and a VT100 terminal.
- [cpmemu](https://github.com/avwohl/cpmemu) - Z80/CP/M emulator for Linux and Windows, with Z80 and 8080 CPU cores. It translates the BDOS and BIOS calls of CP/M 2.2 programs to the host file system.
- [ioscpm](https://github.com/avwohl/ioscpm) - Z80/CP/M emulator for iOS and macOS. It emulates the RomWBW HBIOS interface and runs CP/M 2.2 and CP/M 3.
- [learn-ada-z80](https://github.com/avwohl/learn-ada-z80) - Collection of more than 90 Ada example programs for uada80, the Ada compiler for the Z80 processor and CP/M.
- [mbasic](https://github.com/avwohl/mbasic) - Python interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. Two compiler backends compile the programs to CP/M .COM files or to JavaScript.
- [mbasic2025](https://github.com/avwohl/mbasic2025) - Reconstruction of the lost source code of MBASIC 5.21, the Microsoft BASIC-80 for CP/M. The MACRO-80 source code assembles to a binary that matches mbasic.com byte for byte.
- [mbasicc](https://github.com/avwohl/mbasicc) - C++17 interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. It runs on Linux and macOS.
- [mbasicc_web](https://github.com/avwohl/mbasicc_web) - Web browser interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. Emscripten compiles the mbasicc interpreter to WebAssembly.
- [mpm2](https://github.com/avwohl/mpm2) - Z80 emulator for MP/M II, the multi-user CP/M operating system. Users connect over SSH, and SFTP clients transfer files.
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) - Hardware-level Z80/CP/M emulator for Linux and macOS. It emulates the RomWBW HBIOS interface and switches banks in 512 KB of ROM and 512 KB of RAM.
- [scelbal](https://github.com/avwohl/scelbal) - Floating-point BASIC interpreter for the 8080 processor and CP/M. A translator converts the original 8008 source code to 8080 source code.
- [uada80](https://github.com/avwohl/uada80) - Ada compiler for the Z80 processor and CP/M 2.2. It compiles a subset of Ada 2012 to CP/M .COM files.
- [uc80](https://github.com/avwohl/uc80) - C compiler for the Z80 processor and CP/M. It optimizes for small code size.
- [ucow](https://github.com/avwohl/ucow) - Cowgol compiler for the Z80 processor and CP/M. It runs on Linux in Python.
- [um80_and_friends](https://github.com/avwohl/um80_and_friends) - Linux toolchain that is compatible with Microsoft MACRO-80. It has an assembler, a linker, a librarian, and a disassembler.
- [upeepz80](https://github.com/avwohl/upeepz80) - Peephole optimizer for Z80 compilers that write lowercase Z80 assembly language. It shortens jumps to jr, builds djnz loops, and removes dead stores.
- [uplm80](https://github.com/avwohl/uplm80) - PL/M-80 compiler for the Z80 processor and CP/M. It writes Intel 8080 and Zilog Z80 assembly language.
- [z80cpmw](https://github.com/avwohl/z80cpmw) - Z80/CP/M emulator for Windows. It emulates the RomWBW HBIOS interface and boots CP/M from disk images.
