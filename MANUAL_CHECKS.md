# Manual checks

Checks that need a person, a board or a tool that the simulation does not
have. Each item says what a correct result is. Delete an item after someone runs
the item. If the run found a fault, the fix goes in `CHANGELOG.md`.

## Debug unit on the Nexys A7-100T

The simulation of the debug unit passes (`make test-debug`). Nobody has built
the unit for the board or run the unit on the board. This check needs Vivado
(about 25 minutes per build) and the board. It needs no adapter: the unit
speaks JTAG over the USB cable of the board.

1. Build the default board once, with no environment variable:
   `cd boards/nexys_a7_100t/romwbw && vivado -mode batch -source build_romwbw.tcl`.
   The first build gives the reference numbers for the same Vivado version.
2. Build the board with the unit:
   `Z80_DEBUG_UNIT=1 vivado -mode batch -source build_romwbw.tcl`
   (the JTAG link). `Z80_DEBUG_LINK=uart` builds the old Pmod JA link.
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
5. Search the log for `No valid object(s) found` and read the timing report
   for the clock `jtag_tck`. `romwbw_dbg_jtag.xdc` is not tried: no Vivado has
   run the file. Wrong names need a fix in that file only. (Only for a
   `Z80_DEBUG_LINK=uart` build: check the Pmod pins C17 and D18 against the
   Nexys A7 reference manual.)
6. Program the second bitstream. Right: the console shows the RomWBW banner and
   `Boot [H=Help]:` as before.
7. Close the hardware manager of Vivado (one program at a time holds channel
   A of the cable). Run `python3 tools/z80dbg_jtag.py --check`. Right: the
   IDCODE is 0x13631093 (or 0x3631093) and the USER3 scan does not come back
   as a 1-bit BYPASS (each word shifted left by one). Then run
   `python3 tools/z80dbg_bridge.py --jtag --listen 1234` (macOS and Linux:
   `pip install pyftdi`). Right: the bridge prints `listening on
   127.0.0.1:1234` and does not stop. Wrong: a timeout from the unit. Check
   that the bitstream has the unit, and try `--jtag-freq 1e6`. On Windows, run
   the same with `--jtag --jtag-backend d2xx` (`pip install ftd2xx`). The
   `d2xx` back end is not tried on any device. For the serial link
   (`Z80_DEBUG_LINK=uart`): adapter TX to JA pin 1, adapter RX to JA pin 2,
   GND to JA pin 5, and `--serial DEVICE`.
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
12. Build a CP/M program with `um80 --debug-info` and `ul80 --debug-info`, and
    put the `.COM` file on the disk of the board. Run `udb80 PROG.dbg
    --connect 127.0.0.1:1234 --wait-program` (um80 0.4.2 or later), and type
    the name of the program at the CP/M prompt. Right: udb80 says `The
    program has started at 0x0100.`, `monitor status` shows `cpu-bank=8E`,
    and `break` on a source line, `continue` and `bt` work. Then quit udb80,
    run `monitor break-bank off` (the rule fired once and left the breakpoints
    on bank 8E), and run the same with GDB: `monitor wait-program sha256
    LENGTH HEX64`, `continue`, and start the program again at the CP/M
    prompt. Right: `Program received signal SIGTRAP` at the first line of the
    program. Wrong: the program runs and nothing stops. Then compare the bank
    that RomWBW gives the program with `--program-bank` (the default is 8E).

## Debug unit simulation on Windows

`tb_debug_cosim.sv` reads standard input through the Icarus descriptor
`32'h8000_0000`. This works on macOS. Nobody has run `make test-debug` with
the OSS CAD Suite `vvp` on Windows.

14. On the Windows machine, run `mingw32-make test-debug`. Right: seven PASS
    lines, the last one `PASS: 506 checks, bridge against the RTL` (494, with
    a `NOTE` line, on a machine with no LAN address). Wrong: the
    bridge test hangs or prints no `READY`. Then change how
    `tb_debug_cosim.sv` reads its input.
