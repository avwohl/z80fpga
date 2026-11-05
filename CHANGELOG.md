# Changelog

## Unreleased

### Added

- `make romwbw-debug` (`sim/tb_romwbw_dbg.sv`): the debug unit on RomWBW 3.6.0
  (`SBC_simh_std.rom`, 512 KB). Reads ROM banks through the override and
  compares them with the image, steps `JP 056CH`, runs to a bank-qualified
  breakpoint in ROM bank 0, lets HBIOS reach the boot prompt with the unit
  present, then halts in the prompt loop, walks 12 steps, misses a
  breakpoint with the wrong bank and hits it with the right bank. 196 checks
  pass, 2 to 3 minutes. The ROM image is not in the repository, so
  `make test` does not run this bench.
- A debug unit (`rtl/soc/dbg_unit.sv`, `rtl/soc/dbg_uart.sv`) behind the
  parameter `DEBUG_UNIT` of `z80_soc` and `z80_core`. The parameter is 0 by
  default. The unit halts the core at an instruction boundary, single-steps,
  compares PC (and the MMU bank) with up to 8 breakpoints, reads and writes
  the registers, and reads and writes memory through the MMU while the core is
  stopped. A second serial line carries a small binary protocol.
  `docs/debug_unit.md` has the protocol.
- `z80_mmu` has a bank override for the low window, so the unit can reach any
  bank without a change to the CPU's bank register.
- `sim/tb_debug.sv` in three variants, `sim/tb_debug_cosim.sv`, and
  `sim/dbg_prog.z80`. `make test-debug` runs them. `make test` includes them.
- `tools/z80dbg_bridge.py`: GDB remote serial protocol to the debug unit, with
  the packets that cpmemu's stub offers. `tools/test_z80dbg_bridge.py` runs a
  GDB session against the RTL in Icarus Verilog.
- Nexys A7-100T: `Z80_DEBUG_UNIT=1` in the environment of `build_romwbw.tcl`
  adds the unit and `romwbw_dbg.xdc` (Pmod JA1 and JA2). Without the variable
  the build is unchanged. `MANUAL_CHECKS.md` has the first run on the board.

### Fixed

- A write to PC through the debug unit now clears the HALT state of the core.
  Before the change, a core that stopped on a HALT instruction stayed in HALT
  after `W 11`: with `INC A; INC A; HALT` at 8040H, PC written to 8040H and
  `C`, A stayed 0 and PC stayed 8040H, and register 14 read 0x10. A GDB
  `jump` or `set $pc` followed by `continue` did nothing. `tb_debug` has the
  case, and the case fails (3 checks) with the fix removed.

### Changed

- `sim/dbg_host.svh` holds the host side of the protocol (the tasks of
  `tb_debug.sv`), so `tb_debug.sv` and the new `tb_romwbw_dbg.sv` share the
  tasks. The checks of `tb_debug` did not change in the move (274, 277 and
  286 before the HALT case).
- `tb_debug_cosim.sv` reads standard input through `32'h8000_0000`, not
  `/dev/stdin`, because a native Windows `vvp` has no `/dev/stdin`. Run on
  macOS only (`test_z80dbg_bridge.py`: 130 checks pass). `MANUAL_CHECKS.md`
  has a check for Windows.

### Measured

Host: macOS 27 arm64, Icarus Verilog 13.0, yosys 0.70 (`yowasp-yosys`).

- With `DEBUG_UNIT` at 0, the simulation results are the same. `make test`
  prints the same text as before, including the `$finish` time of each bench,
  for `tb_irq`, `tb_soc`, `tb_ddr2ram`, `tb_sdram`, `tb_sdram_soc`,
  `tb_romload`, `tb_hdsk` and `tb_hdsk_soc`. `make test` also prints `0/72
  assembler cases failed`. The generic cells of `z80_core` and of the whole
  SoC with the Nexys parameters (yosys `proc; flatten; opt -full`) are
  identical to the commit before the change. The Vivado netlist of the Nexys
  build is not proven until step 2 of `MANUAL_CHECKS.md` is done.
- SingleStepTests, 20 cases per opcode with bus traces: 0/32080 failed before
  and after. The whole suite: 0/1604000 failed, with `DEBUG_UNIT` at 0 (the
  repository) and at 1 (a scratch copy of `tb_sst.sv` with the unit's inputs tied
  to 0), after the fix of the HALT state.
- The generic cells of `z80_core` (yosys `proc; flatten; opt -full`) with
  `DEBUG_UNIT` at 0 equal the cells of the commit before the change: 424
  `$mux`, 233 `$eq`, 40 `$sdffe` and the rest. The ABC mapping of the same
  logic moves by up to about 80 LUTs from one run to the next, so the Vivado
  netlist of the Nexys build needs a rebuild (`MANUAL_CHECKS.md`).
- `tb_debug`: 305, 308 and 317 checks pass in the three variants (CPU_DIV 1
  and 3, RAM in block RAM and in DDR2, stopped at reset and halted in flight).
  `test_z80dbg_bridge.py`: 130 checks pass.
- Five changes to the RTL made `tb_debug` fail: no `skip` flag, no bank
  compare, a stop inside a prefixed instruction, no bank override, no PC write.
- Cost on the Nexys RomWBW parameters (ROM reduced to 64 KB for the run, 7-series
  mapping): 4142 LUTs and 1048 flip-flops with the parameter at 0 (4063 LUTs at
  the commit before the change), 4677 LUTs and 1417 flip-flops with the unit.
  No RAMB tile and no LUT RAM. This is an estimate, not a Vivado result. The 79
  LUTs between 4063 and 4142 come from the mapping and not from the logic:
  the generic cells are identical, and `z80_core` alone maps to 3107 LUTs at the
  commit before the change and 3012 LUTs after it.

### Not done

- No udb80 ran against the bridge (`MANUAL_CHECKS.md`, item 13). GDB 18.1
  did: `target remote`, `info registers`, two `stepi` (PC 0, 1, 4),
  `x/8xb 0x0` and `break *0x8000` with `continue` worked against
  `tb_debug_cosim.vvp` (measured 2026-11-04).
- `tb_debug_cosim.sv` was not run on Windows (item 14).
- The timing of the paths through `u_dbg` is unknown: no 12-cycle exception
  covers `u_dbg` (`docs/debug_unit.md`, Limits).
- No Vivado build. The Nexys build with the unit has not been placed, and the
  Pmod pins are from memory of Digilent's master constraints file.
- Verilator was not installed, so `make lint` did not run on the new files.
- No watchpoints, no write to the alternate register set, no stop at an
  interrupt acknowledge.
