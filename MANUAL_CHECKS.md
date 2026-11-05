# Manual checks

Checks that need a person, a board or a tool that the simulation does not
have. Each item says what a correct result is. Delete an item after someone runs
the item. If the run found a fault, the fix goes in `CHANGELOG.md`.

## Debug unit on the Nexys A7-100T

The simulation of the debug unit passes (`make test-debug`). Nobody has built
the unit for the board or run the unit on the board. This check needs Vivado
(about 25 minutes per build), the board and a 3.3 V USB-serial adapter.

1. Build the default board once, with no environment variable:
   `cd boards/nexys_a7_100t/romwbw && vivado -mode batch -source build_romwbw.tcl`.
   The first build gives the reference numbers for the same Vivado version.
2. Build the board with the unit:
   `Z80_DEBUG_UNIT=1 vivado -mode batch -source build_romwbw.tcl`.
   Use a separate clone or move `build/` away first.
3. Search the log of the second build for `ERROR: [DRC` and `REQP-1962`.
   Right: no `DRC` error and no `REQP-1962`. The block RAM stays at 128 of 135
   RAMB36. Wrong: any `REQP-1962` line. The placement of the ROM is fragile
   (see `CLAUDE.md`), and the unit must not move the ROM.
4. Compare `utilization.rpt` and `timing.rpt` of the two builds. Right: the
   second build uses about 550 more LUTs and about 370 more flip-flops than the
   first build, and no more RAMB36. Timing meets all constraints. The slack was
   +0.237 ns before the unit. Write down the new slack in `CHANGELOG.md`.
   Read the worst paths that start or end in `u_dbg` (`report_timing -from
   [get_cells -hier *u_dbg*]` and `-to`). `romwbw.xdc` has no 12-cycle
   exception for `u_dbg`, so two paths run in one clock: the PC compare into
   `stopped`, and `stopped` and `skip` into `core_clk_en`, which feeds the
   clock enable of the core. Wrong: a path with negative slack. Then register the stop
   signal in `dbg_unit.sv`, and run `make test-debug` again.
5. Check the Pmod pins C17 and D18 against the Nexys A7 reference manual.
   The author of `romwbw_dbg.xdc` had no board. Wrong pins need a fix in
   that file only.
6. Program the second bitstream. Right: the console shows the RomWBW banner and
   `Boot [H=Help]:` as before.
7. Connect the adapter: adapter TX to JA pin 1, adapter RX to JA pin 2, GND to
   JA pin 5. Run
   `python3 tools/z80dbg_bridge.py --serial DEVICE --listen 1234`.
   Right: the bridge prints `listening on 127.0.0.1:1234` and does not stop.
   Wrong: a timeout from the unit. Check the wires and the baud rate (115200).
8. Run GDB (build with `--target=z80-unknown-elf`, see `docs/debug_unit.md`):
   `set architecture z80`, `target remote :1234`, then `monitor status`.
   Right: the bridge answers `running` or `stopped` and a PC.
9. Press ^C in GDB while RomWBW waits at the prompt. Right: GDB shows a stop
   with PC in the ROM or in the common bank. The console of the guest still
   works after `continue`.
10. Run `stepi` three times and `info registers`. Right: PC moves by the length
    of each instruction. Run `x/16xb $sp`. Right: the bytes read from DDR2 are
    the same on a second read, and a `set {char}ADDR = 0x55` followed by
    `x/1xb ADDR` shows 0x55 (use an address in RAM above 8000H).
11. Set `break *ADDR` at an address that RomWBW runs often, and `continue`.
    Right: GDB stops at ADDR. Run `monitor bank 8E` and `x/16xb 0x100`. Right:
    the bytes differ from the bytes of `monitor bank cur` when the two banks
    differ.

## Debug unit with udb80, no board

GDB 18.1 (`--target=z80-unknown-elf`) ran against the bridge on 2026-11-04:
`target remote`, `info registers`, `stepi`, `x/8xb 0x0`, `break *0x8000` and
`continue` worked. udb80 needs a `prog.dbg` for the program, and
`sim/dbg_prog.z80` is built with `tools/zasm.py`, which writes none.

13. Build a program with `um80 --debug-info` and `ul80 --debug-info`, load
    the program in the cosim, run `python3 tools/z80dbg_bridge.py --vvp
    sim/tb_debug_cosim.vvp --listen 1234`, and run `udb80 prog.dbg --connect
    127.0.0.1:1234`. Right: udb80 connects, `break` on a source line and
    `continue` stop there, and `bt` shows the callers. Wrong: udb80 refuses
    the image or reports a protocol error.

## Debug unit simulation on Windows

`tb_debug_cosim.sv` reads standard input through the Icarus descriptor
`32'h8000_0000`. This works on macOS. Nobody has run `make test-debug` with
the OSS CAD Suite `vvp` on Windows.

14. On the Windows machine, run `mingw32-make test-debug`. Right: four PASS
    lines, the last one `PASS: 130 checks, bridge against the RTL`. Wrong: the
    bridge test hangs or prints no `READY`. Then change how
    `tb_debug_cosim.sv` reads its input.
