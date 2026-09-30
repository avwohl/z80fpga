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

## What is here

| | |
|---|---|
| `rtl/core/` | the CPU: ALU, sequencer, and the generated ROMs |
| `rtl/soc/` | banked-memory MMU, UART, microSD and HDSK, the ROM loader, and a small SoC around the core |
| `rtl/mem/` | block-RAM, iCE40 SPRAM, DDR2 and SDRAM backing stores |
| `tools/gen_z80.py` | the instruction-set description and the ROM generator |
| `tools/run_sst.py` | the SingleStepTests harness |
| `tools/zasm.py` | a Z80 assembler, for the boot ROM and test programs |
| `sim/` | test benches |
| `sw/boot.z80` | the boot monitor: banner, bank check, console echo |
| `boards/` | Nexys A7-100T, Icepi Zero and Tang Nano 20K (all three run on hardware), Arty A7-100T, Signaloid C0-microSD, and why not the Qomu |

## Getting the tools

Everything here builds with the [OSS CAD
Suite](https://github.com/YosysHQ/oss-cad-suite-build) — Icarus Verilog for
simulation, yosys and nextpnr for the iCE40 and ECP5 bitstreams. Unpack it
and:

```
source tools/ossenv.sh          # set OSS_CAD_ROOT if it is not /c/temp/tools
```

The Arty and Nexys flows want Vivado. The test harness wants a checkout of
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

## Boards

The [Nexys A7-100T](boards/nexys_a7_100t/) runs RomWBW and CP/M 2.2 on
hardware. The [Icepi Zero](boards/icepi_zero/) and the
[Tang Nano 20K](boards/tang_nano_20k/) run on hardware too. The
[Arty A7-100T](boards/arty_a7_100t/) and
[Signaloid C0-microSD](boards/c0_microsd/) builds are timing-closed but have
never run, and the [Qomu](boards/qomu/) does not fit.
[docs/boards.md](docs/boards.md) has the detail for each board.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the microcode engine works, and the core's ports
- [docs/verification.md](docs/verification.md) - how the core is tested, interrupts included
- [docs/boards.md](docs/boards.md) - each board, what has run on hardware, and the third-party files
- [docs/porting.md](docs/porting.md) - what a new board costs
- [docs/memory_banking.md](docs/memory_banking.md) - the bank map
- [docs/romwbw.md](docs/romwbw.md) - how a stock RomWBW ROM boots on this core, all the way to CP/M 2.2 on real hardware, and what the console has to look like for that
- [docs/roadmap.md](docs/roadmap.md) - what the Z180 and eZ80 need
- [docs/vivado_license.md](docs/vivado_license.md) - for the Vivado builds: what the free licence is called since 2026.1 renamed it, and how to get one

## Licence

GPLv3 — see [LICENSE](LICENSE). Third-party files are listed in
[THIRD-PARTY.txt](THIRD-PARTY.txt) and described in
[docs/boards.md](docs/boards.md#third-party-files-and-the-romwbw-rom). The
RomWBW ROM is not committed; [docs/romwbw.md](docs/romwbw.md) says where the
image comes from.

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
- [romwbw_disks](https://github.com/avwohl/romwbw_disks) - ROM images and CP/M disk images for the RomWBW emulators, served from a two-level JSON catalog. One stable index URL reaches every published RomWBW release, and every asset carries the SHA-256 a client checks it against.
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) - Hardware-level Z80/CP/M emulator for Linux and macOS. It emulates the RomWBW HBIOS interface and switches banks in 512 KB of ROM and 512 KB of RAM.
- [scelbal](https://github.com/avwohl/scelbal) - Floating-point BASIC interpreter for the 8080 processor and CP/M. A translator converts the original 8008 source code to 8080 source code.
- [uada80](https://github.com/avwohl/uada80) - Ada compiler for the Z80 processor and CP/M 2.2. It compiles a subset of Ada 2012 to CP/M .COM files.
- [uc80](https://github.com/avwohl/uc80) - C compiler for the Z80 processor and CP/M. It optimizes for small code size.
- [ucow](https://github.com/avwohl/ucow) - Cowgol compiler for the Z80 processor and CP/M. It runs on Linux in Python.
- [um80_and_friends](https://github.com/avwohl/um80_and_friends) - Linux toolchain that is compatible with Microsoft MACRO-80. It has an assembler, a linker, a librarian, and a disassembler.
- [upeepz80](https://github.com/avwohl/upeepz80) - Peephole optimizer for Z80 compilers that write lowercase Z80 assembly language. It shortens jumps to jr, builds djnz loops, and removes dead stores.
- [uplm80](https://github.com/avwohl/uplm80) - PL/M-80 compiler for the Z80 processor and CP/M. It writes Intel 8080 and Zilog Z80 assembly language.
- [z80cpmw](https://github.com/avwohl/z80cpmw) - Z80/CP/M emulator for Windows. It emulates the RomWBW HBIOS interface and boots CP/M from disk images.
