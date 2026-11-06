# Debug unit

The debug unit lets a host program stop the Z80, step the Z80, set breakpoints,
and read and write registers and memory. The host talks to the unit over a
byte link of its own: JTAG (the Nexys A7 build, no adapter) or a serial line
(other boards). The console stays with the guest. The design is
phase 10 of `docs/debugger_plan.md` in the cpmemu repository.

The debug unit is off by default. A build that sets the parameter `DEBUG_UNIT`
to 1 on `z80_soc` has the debug unit. A build that leaves the parameter at 0 has
none of the debug unit logic. The simulation results of that build are the same
as before, and the generic cells of `z80_core` are the same. The Vivado netlist
of the Nexys build with the parameter at 0 is not proven until someone runs
step 2 of `MANUAL_CHECKS.md`.

## Parts

- `rtl/soc/dbg_unit.sv` holds the command decoder, the breakpoints and the
  stop control.
- `rtl/soc/dbg_uart.sv` is a small 8N1 serial port for the unit.
- `rtl/soc/dbg_jtag_link.sv` is the JTAG link: the same byte interface as
  `dbg_uart.sv`, on the user register USER3 of the FPGA. The parameter
  `JTAG_LINK` of `dbg_unit` selects the link.
- `rtl/soc/dbg_bscan_xilinx.sv` is the Xilinx part: a `BSCANE2` with
  `JTAG_CHAIN` 3, and a `BUFG` on TCK. Only a synthesis flow uses the file.
  `sim/bscane2_stub.v` replaces the two primitives for lint.
- `tools/z80dbg_jtag.py` drives an FTDI chip in MPSSE mode as a JTAG master.
- `rtl/core/z80_core.sv` has the register hooks. The hooks exist only when
  its parameter `DEBUG_UNIT` is 1.
- `rtl/soc/z80_mmu.sv` has a bank override for the low 32 KB window.
- `rtl/soc/z80_soc.sv` connects the parts, and shares the memory port with
  the HDSK DMA.
- `tools/z80dbg_bridge.py` turns the serial protocol into GDB remote serial
  protocol (RSP).

## Parameters of `z80_soc`

- `DEBUG_UNIT`: 1 builds the unit. The default is 0.
- `DBG_BAUD`: the baud rate of the unit. The default is 115200.
- `DBG_BP_N`: the number of hardware breakpoints, 1 to 8. The default is 4.
- `DBG_HALT_ON_RESET`: 1 holds the core stopped at 0000H after reset.
  The default is 0.
- `DBG_JTAG`: 1 selects the JTAG link. The default is 0, the serial line.

The ports `dbg_rx` and `dbg_tx` carry the serial line. The ports
`dbg_jt_tck`, `dbg_jt_sel`, `dbg_jt_capture`, `dbg_jt_shift`,
`dbg_jt_update`, `dbg_jt_tdi`, `dbg_jt_reset` and `dbg_jt_tdo` carry the TAP
signals of the JTAG link. A build with no unit, and a build with the other
link, leaves the unused ports unconnected.

## How the unit stops the core

The unit gates the clock enable of the core. The core stops only at an
instruction boundary. The core output `dbg_at_boundary` marks the boundary.
The boundary is the first T-state of an opcode fetch that does not follow a
prefix byte. At the boundary every register is complete and no bus cycle is
half done.

A stop has three causes: a halt request from the host, the end of a single
step, and a breakpoint. The status reply tells which cause stopped the core.

A resume sets a `skip` flag. The flag stays set until the core leaves the
boundary. The `skip` flag lets the core run on from an address that has a
breakpoint, as GDB expects.

The unit does not stop at an interrupt acknowledge. The SoC does not connect
the interrupt pins today, so the missing stop has no effect yet.

## Breakpoints

Each breakpoint holds a 16-bit address, an enable bit and a bank. The unit
compares the address with PC at each boundary. A breakpoint can also name a bank.
The unit then compares the bank of the breakpoint with the bank that PC uses.

PC at 8000H or above always uses the common bank. PC below 8000H uses the bank
that the CPU selected. The unit never writes a breakpoint byte into memory, so
a breakpoint works in ROM.

## Memory access at a stop

The unit uses the memory port of the SoC through the same multiplexer as the
HDSK DMA. A read or a write goes through the MMU, and then to block RAM, DDR2
or SDRAM. The core is idle at the boundary, so the port is free. The unit
waits for the same ready signal that the HDSK DMA uses.

The command `K` makes the MMU show a chosen bank in the low 32 KB. The CPU bank
register does not change. A write to a ROM bank has no effect.

Do not use the memory commands while `rom_loader` stages the ROM into SDRAM.
The loader owns the memory port until `rom_done` rises.

## Serial protocol

The protocol below is the same on both links. Only the carrier of the bytes
differs (see "JTAG link").

The host sends a command byte and its arguments. The unit answers with the
command byte, or with `E` and an error code. Multi-byte values are little
endian. The unit drops a command that stops half way after 10 ms without a byte.
To resynchronize, the host keeps quiet for 12 ms and then sends `N`.

| Command | Arguments | Reply |
|---|---|---|
| `N` | none | `N` |
| `S` | none | `S`, state, number of breakpoints, protocol revision |
| `H` | none | `H`. The core stops at the next boundary. |
| `C` | none | `C`. The core runs. |
| `T` | none | `T`. The core runs one instruction. |
| `R` | register | `R`, low byte, high byte |
| `W` | register, low byte, high byte | `W` |
| `M` | address (2), length | `M`, then the bytes. Length 0 means 256. |
| `P` | address (2), length, bytes | `P`, after the last byte |
| `B` | index, address (2), bank, flags | `B` |
| `K` | flags, bank | `K` |

Flags of `B`: bit 0 enables the breakpoint. Bit 1 makes the bank count.
Flag of `K`: bit 0 turns the bank override on.

State byte of `S`: bit 0 is high when the core has stopped. Bit 1 is high
after a breakpoint stop. Bit 2 is high after a step stop. Bit 3 is high after
a halt request stop. Bit 4 is high when the override is on.

Bits 7 to 5 hold the number of the breakpoint that stopped the core.

Error codes: `01` the core is running, `02` unknown command, `03` bad
breakpoint number, `04` the register has no write port.

Register numbers: 0 AF, 1 BC, 2 DE, 3 HL, 4 AF', 5 BC', 6 DE', 7 HL', 8 IX,
9 IY, 10 SP, 11 PC, 12 IR, 13 WZ. Register 14 holds the flags IFF1 (bit 0),
IFF2 (bit 1), IM (bits 3 and 2) and HALT (bit 4). A write to register 11 (PC)
also clears HALT, so the core runs the code at the new PC. A core that stopped
on a HALT instruction would otherwise stay in the HALT state. Register 15 is
the bank that the CPU selected.

The core has no write port for the alternate set (registers 4 to 7). Register 15
belongs to the MMU. A write to register 4, 5, 6, 7 or 15 returns `E 04`.

## JTAG link

The link is a second implementation of the byte interface of `dbg_uart.sv`.
The command protocol does not change. A board that has no JTAG access to the
FPGA, or a build with `DBG_JTAG` at 0, uses the serial line.

### The register

The link uses the Xilinx primitive `BSCANE2` with `JTAG_CHAIN` 3. The
instruction USER3 (6'b100010, 0x22, IR length 6 on 7-series) selects the data
register. USER3 keeps clear of USER1, which the Vivado debug hub uses. The data
register has 10 bits. The host shifts the least significant bit first, on TDI
and on TDO.

Host to FPGA, shifted in:

- Bits 7 to 0: a byte.
- Bit 8, HV: 1 means the host sends the byte.
- Bit 9: 0. The bit is reserved, and the unit ignores the bit.

FPGA to host, captured at CAPTURE-DR and shifted out in the same scan:

- Bits 7 to 0: a byte. Without a waiting byte the value is not defined.
- Bit 8, FV: 1 means the byte is new. The scan takes the byte at UPDATE-DR.
- Bit 9, RJ: 1 means the FPGA rejects the host byte of this scan.

### The rules

- A scan always has CAPTURE-DR, 10 SHIFT-DR cycles and UPDATE-DR.
- RJ at CAPTURE-DR is 1 when the one-byte host mailbox is full (the clock of
  the unit has not taken the previous byte), or when the sticky reject flag is
  set.
- At UPDATE-DR, if HV is 1 and RJ of the same scan was 0, the byte goes into
  the mailbox. The unit sees `rx_valid` for one clock. If HV is 1 and
  RJ was 1, the link drops the byte and sets the sticky flag.
- A scan with HV at 0 clears the sticky flag at UPDATE-DR.
- So, in a batch of scans, every byte from the first rejected one onward is
  rejected, in order. The host sends one scan with HV at 0, and then sends
  again from the first rejected byte. `JtagLink` in `z80dbg_bridge.py` does
  this.
- TCK and the clock of the unit are asynchronous. Each direction has a toggle
  handshake with two flip-flops at the receiving side, and a one-byte mailbox.
  TCK can be faster or slower than the clock of the unit.
- A TAP reset (`RESET` of `BSCANE2`) clears the TCK-domain flags.
- `tx_busy` is high while the mailbox to the host holds a byte that the host
  has not taken. The unit still drops a half-sent command after 10 ms. The host
  sends a whole command in one batch, so the bytes arrive microseconds apart.
- Leave the TAP in Run-Test/Idle between scans. TCK can be slower than the
  unit clock. Then a scan that follows UPDATE-DR with no Run-Test/Idle can
  see RJ at 1, because the acknowledgement has not crossed yet. The host retries, so no
  byte is lost. The cosim and the `JtagLink` batches give the idle cycle.

### Build options

- `Z80_DEBUG_UNIT=1` in the environment of `build_romwbw.tcl` builds the unit
  with the JTAG link. The build has no Pmod pins and reads
  `romwbw_dbg_jtag.xdc`. The Tcl script defines the macro `WITH_DEBUG_UNIT`.
- `Z80_DEBUG_LINK=uart` (with `Z80_DEBUG_UNIT=1`) builds the old serial link on
  Pmod JA with `romwbw_dbg.xdc`, and defines `WITH_DEBUG_UART`. Any other
  value of `Z80_DEBUG_LINK` stops the script with an error.
- `romwbw_dbg_jtag.xdc` has a `create_clock` of 33.333 ns on TCK and an
  asynchronous clock group against `ui_clk`. Vivado 2026.1 read the file on
  2026-11-06, and both names are correct: `jtag_tck` is on
  `u_dbg_bscan/u_bscan/TCK`, and `ui_clk` gives the clock `clk_pll_i`.

### Bridge options

```
python3 tools/z80dbg_bridge.py --jtag --listen 1234
python3 tools/z80dbg_bridge.py --vvp-jtag sim/tb_debug_cosim_jtag.vvp --listen 1234
```

- `--jtag`: the board, through an FTDI chip.
- `--jtag-backend pyftdi|d2xx`: the FTDI library. The default is `pyftdi`.
- `--jtag-url`: a pyftdi URL (default `ftdi://0x0403:0x6010/1`, channel A of
  the Digilent FT2232) or, for `d2xx`, a device index. Without an index, `d2xx`
  uses the first device whose name ends in A, which is channel A. The driver
  sets the index order: on Windows 11, index 0 was channel B.
- `--jtag-freq`: TCK in Hz. The default is 6e6. The maximum is 30e6. The driver rounds the clock down, so TCK never exceeds this value.
- `--vvp-jtag FILE`: the JTAG cosim.

`python3 tools/z80dbg_jtag.py --check` reads the IDCODE and scans USER3 once,
with no bridge. The expected IDCODE of the XC7A100T is 0x13631093
(openFPGALoader prints 0x3631093, with no version nibble).

### One cable

The Nexys A7 has one USB cable. The FT2232 chip gives two channels: channel A
is JTAG, and channel B is the console UART. The debug unit uses channel A, so
the console and the debugger work at the same time on the same cable.

- macOS: `python3 -m pip install --user --break-system-packages pyftdi`, and
  then `--jtag`. See `docs/macos.md`.
- Linux: `pip install pyftdi`, and then `--jtag`. The user needs access to the
  USB device (a udev rule). Not tried.
- Windows: `--jtag --jtag-backend d2xx` (`pip install ftd2xx`). The D2XX driver
  is the driver that Vivado uses. The cable drivers of Vivado install the D2XX
  driver: as administrator, go to `data\xicom\cable_drivers\nt64` in the
  Vivado installation and run `install_drivers_wrapper.bat` there. Tried on
  Windows 11 (see "What is measured").
- One program at a time holds channel A. Close the hardware manager of Vivado
  (or `openFPGALoader`) before the bridge starts. If you load a new bitstream,
  start the bridge after the load.

### The cosim

`sim/tb_debug_cosim_jtag.vvp` (the Makefile builds the file with
`-DDBG_JTAG`) has the same SoC as `tb_debug_cosim.vvp`, with the JTAG link.
Its lines on standard input:

- `J w0 w1 ...`: one DR scan per hex word, back to back, each with one
  Run-Test/Idle after the scan. The answer is `JR r0 r1 ...`, 3 hex digits
  each, `{RJ, FV, byte}`.
- `X`: a TAP reset. The answer is `XR`.
- `R n`: runs n clocks of the unit, and answers `RECV`.
- `S`: answers `ERR S needs the serial build`.

The unit clock is 1 MHz. TCK is 73 kHz, which keeps the ratio of the board
(81.25 MHz to 6 MHz). Simulated time passes during a scan.

### What is measured

- `sim/tb_jtag_link.sv`: 87080 checks of the link alone, in four fixtures:
  TCK 6 times faster than the unit clock, 37 times faster, 6 MHz against
  81.25 MHz, and 43.5 MHz against 58.8 MHz. Six deliberate faults in the link
  each made the bench fail. A directed test checks that a byte in the host
  mailbox is dropped when `rst_n` is low.
- `tools/test_z80dbg_jtag.py`: 195 checks of the Python side with a model of
  the FPGA, and fake FTDI objects. No RTL, no board.
- `tools/test_z80dbg_bridge.py`: the same 269 checks over each link, 538 in
  all. The checks include an attach to a running core.
- GDB 18.1 over `--vvp-jtag`: `monitor wait-program sha256 128 HEX64` and
  `continue` gave `Program received signal SIGTRAP` at `start ()`. udb80 0.4.2
  `--wait-program` stopped at 0100H, and `break wp.mac:3`, `continue` and `bt`
  worked.
- On the real Nexys A7 (2026-11-05, macOS 27, pyftdi): IDCODE 0x13631093 at
  6 MHz and at 30 MHz. A bitstream with no unit answers a USER3 scan like a
  1-bit BYPASS register.
- Vivado 2026.1 build with the JTAG link (2026-11-06): 0 DRC errors, no
  `REQP-1962`, 128 of 135 RAMB36. All timing constraints are met, with WNS
  +0.254 ns and WHS +0.060 ns. In the `jtag_tck` domain, the worst hold slack
  is +0.160 ns and the worst setup slack is +30.395 ns.
- `report_cdc` of that build: 1 Critical, CDC-4 "multi-bit unknown CDC
  circuitry" from `f_data_reg[7:0]` (unit clock) to `sr_reg[7:0]` (TCK). The
  handshake holds that byte still, so that Critical item is not a fault. From TCK to
  the unit clock, `h_data_reg` to `rx_data_reg` gives CDC-15 warnings: a
  structure with a clock enable. The toggle synchronizers are CDC-3, and
  Vivado sees `ASYNC_REG`.
- On the real Nexys A7 (2026-11-06, Windows 11, d2xx, that bitstream): IDCODE
  and USER3 answers at 6 MHz and at 30 MHz. GDB 18.1 (MSYS2 `gdb-multiarch`)
  through the bridge stopped the running RomWBW at attach, read the 13
  registers, did 3 `stepi`, and stopped at a `break`. `continue` with ^C
  worked 3 times. A memory write above 8000H read back, and `monitor bank`
  showed other banks. The console kept its echo after each stop.
- A read of the whole ROM bank 00H through `monitor bank 00` and GDB `dump`:
  32768 bytes, all equal to the ROM image, at 30 MHz and at 6 MHz. Each read
  took about 2.5 seconds.

### What is not measured

- Vivado does not time the paths from the `BSCANE2` outputs (`SEL`, `SHIFT`,
  `CAPTURE`, `UPDATE`, `RESET`, `TDI`) to the TCK flip-flops, or the path from
  `sr_reg[0]` to `TDO`. These paths have no start clock. The board passes at
  6 MHz and at 30 MHz, but a different placement can change the margin.
- The xdc has no `set_max_delay -datapath_only` for the data buses.
- The pyftdi back end on Linux is not tried.
- udb80 on the board is not tried (`MANUAL_CHECKS.md`, item 12).

## The GDB bridge

`tools/z80dbg_bridge.py` listens on `127.0.0.1` by default and speaks the GDB
remote serial protocol. The bridge offers the same packets as the cpmemu stub: `?`, `g`, `G`,
`p`, `P`, `m`, `M`, `c`, `s`, `Z0`, `z0`, `Z1`, `z1`, `vCont`, `qSupported`,
`qXfer:features:read` for `target.xml`, `qRcmd` and the byte 03H. The register set
is the 13 registers of cpmemu, all 16 bits wide.

```
python3 tools/z80dbg_bridge.py --serial /dev/cu.usbserial-XXXX --listen 1234
gdb
(gdb) set architecture z80
(gdb) target remote :1234
```

The bridge needs `pyserial` for `--serial`. The `monitor` commands use the
words of romwbw_emu:

- `monitor bank XX` shows bank XX in the low 32 KB. `monitor bank cur` returns
  to the bank of the CPU.
- `monitor break-bank XX` makes breakpoints below 8000H apply in bank XX only.
  `monitor break-bank off` removes the limit.
- `monitor wait-program bytes HEX...` or `monitor wait-program sha256 LENGTH
  HEX64` stops the target when a program with those bytes starts at 0100H in
  the program bank. `monitor wait-program off` removes the rule, and
  `monitor wait-program` shows it. The forms and the replies are those of
  romwbw_emu. The bridge is stricter on input: `sha256` takes exactly a
  decimal length and 64 hex digits, with nothing after them.
- `monitor status` shows the state of the unit and of the wait-program rule.
  The unit reads registers only at a stop. For a core that runs, the PC and the
  bank show as `?`.

The core can run when the debugger attaches. An example is a board with
`DBG_HALT_ON_RESET` at 0, or a core that a previous `detach` let go. GDB then
sends `?` and reads the registers. So the bridge stops a running core at `?`
and replies `T02`, as gdbserver stops a process at attach. A core that is
already stopped gives `T05`.

A ^C (03H) outside a `continue` also stops a
running core, with the reply `T02`. `detach` lets the core run again.

### Find a CP/M program: wait-program

RomWBW's CP/M 2.2 loads a `.COM` file into bank 8EH at 0100H. The program bank
of the bridge is 8EH. `--program-bank XX` sets a different bank. The tests use
80H, because the cosim has RAM banks 80H and 81H only.

The rule uses one of the hardware breakpoints of the unit, at 0100H, limited
to the program bank. While the rule is armed, the debugger has one breakpoint
less. If all the breakpoints are in use, the bridge refuses to arm the rule.

At each stop on the rule, the bridge reads the bytes at 0100H as the CPU sees
them. When the bytes do not match, the bridge continues the target. When the
bytes match, the bridge removes the rule and limits the breakpoints to the
program bank (as `monitor break-bank`). Then it sends the stop reply `T05`. A
breakpoint of the debugger at 0100H stops the target first, and the rule
stays armed.

With udb80 (um80 0.4.2 or later):

```
udb80 PROG.dbg --connect 127.0.0.1:1234 --wait-program
```

With GDB:

```
(gdb) target remote :1234
(gdb) monitor wait-program sha256 LENGTH HEX64
(gdb) continue
```

Then start the program at the CP/M prompt. GDB stops with
`Program received signal SIGTRAP` at the first line of the program. LENGTH and
HEX64 are `image.length` and `image.sha256` of `PROG.dbg`.

### Stop replies

A stop at a breakpoint is `T05swbreak:;` (`Z0`) or `T05hwbreak:;` (`Z1`), only
for a client that said `swbreak+` or `hwbreak+` in `qSupported`. GDB says both.
udb80 says `swbreak+` only and sets `Z0` breakpoints only. A client that said
neither gets `T05`. The wait-program stop is always `T05`: no debugger set that
breakpoint, and GDB continues past a `swbreak` that it does not know.

cpmemu's stub (4.12.0 and later) follows the same rule for `swbreak` and gives
the same `T05` for the wait-program stop. cpmemu has no `hwbreak`: its `Z1`
works as `Z0`. The `hwbreak` reply is the bridge's own.

### From another machine

The bridge has no password, and a client can read and write the memory of the
target. By default the bridge listens on 127.0.0.1 only.

Use an SSH tunnel
(`ssh -N -L 1234:127.0.0.1:1234 USER@BRIDGE-HOST` on the debugger machine). Or
start the bridge with `--listen-addr ADDR`: `0.0.0.0` for every interface, or
the IPv4 address of one interface. A name such as `localhost` is refused. For
an address outside 127.0.0.0/8, the bridge prints a warning. Use the option
only on a network that you trust.

The unit has 4 breakpoints by default. The bridge answers the fifth `Z0` or `Z1` with `E0e`.
The unit has no watchpoints, so the bridge answers `Z2` to `Z4` with an empty reply. A `G`
packet writes only the registers that differ from the registers of the unit.
A changed alternate register returns `E01`.

## Tests

`make test-debug` builds and runs the tests below, a JTAG cosim check and the
Python test of the JTAG driver. `make test` includes them.
The Makefile uses `python3` if `python3` runs, and `python` if not. On the
host "Mac" (Icarus Verilog 13.0), the results were:

```
tb_debug.vvp         305 checks, CPU_DIV 1, RAM in block RAM, stopped at reset
tb_debug_div3.vvp    308 checks, CPU_DIV 3, boot monitor halted in flight
tb_debug_ddr2.vvp    317 checks, CPU_DIV 3, RAM in DDR2, stack in DDR2
test_z80dbg_bridge   506 checks, RSP client, bridge, and the RTL, 253 per link
tb_jtag_link.vvp     87080 checks, the JTAG link alone
test_z80dbg_jtag     195 checks, JTAG driver and transport, no RTL
```

`sim/tb_debug.sv` plays the host. The bench runs the program in
`sim/dbg_prog.z80`. The tasks of the host side are in `sim/dbg_host.svh`.

The bench checks the registers in both directions. The bench checks ROM, RAM and
bank-override memory. The bench checks a breakpoint and a bank-qualified
breakpoint that misses and then hits. The bench checks single steps across a
prefixed instruction, the halt request, the error replies and the timeout. The
bench also runs a program that ends in HALT, stops the program, writes PC and
checks that the program runs again. In
the DDR2 variant, the bench also reads the stack bytes from the
DDR2 model.

`sim/tb_debug_cosim.sv` runs the same SoC as a server on standard input and
output. `tools/test_z80dbg_bridge.py` starts the bridge on this server and
runs a GDB session through a socket. The answers come from the RTL, not from
a model. The bench reads standard input through the Icarus descriptor
`32'h8000_0000`. The test ran on macOS. No one has run the test on a Windows
build of `vvp`.

The session also checks these items:

- The stop replies for a client without `swbreak+` and `hwbreak+`.
- `monitor wait-program` in bank 80H. A start that does not match stops at
  the rule once and runs on. A start that matches stops with `T05`. The
  `sha256` form. A rule for bank 81H does not stop a start in bank 80H. A
  breakpoint of the debugger at 0100H. The error replies, and a bad word,
  after which the bridge still answers. The breakpoint that the rule holds.
- `--listen-addr`, with the bridge program itself. Bad addresses are refused.
  The default refuses the LAN address of the host. `0.0.0.0` takes a client
  on the LAN address and prints the warning. The address of one interface
  refuses 127.0.0.1.

The session runs twice, over the UART cosim and over the JTAG cosim. The count
of each run is 253 on a host with a LAN address (an IPv4 address that is not
127.x). On a host without one, the test prints a `NOTE` line, does not run the
six LAN checks, and counts 247 for each run.

### Test on a RomWBW ROM

`make romwbw-debug` runs `sim/tb_romwbw_dbg.sv`. The bench is `tb_romwbw.sv`
with `DEBUG_UNIT` at 1. The bench needs the same ROM image as `make romwbw`
(for example `ROMWBW_VERSION=3.6.0`). The bench does these steps:

1. Read three ROM banks through the override and compare them with the image.
2. Step the first instruction of RomWBW (`JP 056CH`).
3. Run to a breakpoint in ROM bank 0.
4. Remove the breakpoint, let HBIOS run to the boot prompt, and check that the
   console prints the prompt.
5. Halt the core at the prompt and step twelve instructions.
6. Set a breakpoint with a bank that does not match, and check that the core
   does not stop.
7. Set the same breakpoint with the right bank, and check the stop and the
   next step.

The run takes 2 to 3 minutes on the host "Mac". With RomWBW 3.6.0
(`SBC_simh_std.rom`), the result was `PASS: 196 checks`. `make test` does not
run this bench, because the ROM image is not in the repository.

GDB 18.1 for z80 ran against the bridge and `tb_debug_cosim.vvp` on
2026-11-04: `target remote`, `info registers`, `stepi`, `x/8xb 0x0`, and
`break *0x8000` with `continue` worked (measured). No one has run `udb80`
against the bridge yet: see item 13 of `MANUAL_CHECKS.md`.

Five changes to the RTL each made the benches fail: no `skip` flag, no bank
compare, a stop inside a prefixed instruction, no bank override, and no PC
write. The failures show that the benches check these functions.

## Cost

yosys 0.70 (the `yowasp-yosys` package) mapped the SoC with the Nexys RomWBW
parameters to Xilinx 7-series cells. The ROM was 64 KB for this run. The unit
adds 535 LUTs and 369 flip-flops (4677 LUTs and 1417 flip-flops, against 4142
and 1048 with the parameter at 0). The unit adds no RAMB tile and no LUT RAM.

The mapping of the same logic varies from run to run by about 80 LUTs, so
treat the numbers as an estimate of 550 LUTs.

Vivado 2026.1 gives the real number for the Nexys RomWBW build with the JTAG
link (2026-11-06). In the hierarchical utilization report, `u_dbg` has 410
LUTs and 353 flip-flops. The JTAG link inside `u_dbg` has 43 LUTs and 50
flip-flops. The unit adds no RAMB tile and no LUT RAM. The whole design has
15178 LUTs and 9295 flip-flops, against 15009 LUTs and 8934 flip-flops with no
unit. The difference in LUTs (169) is less than the size of `u_dbg`, because
Vivado packs the other logic differently.

The worst path of that build has a slack of +0.254 ns. The path goes from a
breakpoint address register in `u_dbg` to a clock enable of the core
(`rIX_reg`).
The build with no unit has a WNS of +0.237 ns.

With `DEBUG_UNIT` at 0, the generic cells of `z80_core` are the same as the
cells of the commit before the unit (30 `$add`, 424 `$mux` and the rest). The
cells of the whole SoC with the Nexys parameters are the same too. A comparison
used the yosys commands `proc; flatten; opt -full`. The SoC has 4142 LUTs,
against 4063 LUTs before the unit. The difference comes from the mapping. From
the same generic cells, `z80_core` alone maps to 3107 LUTs before the unit and
to 3012 LUTs after the unit.

## Nexys A7 build

The option is off by default. To build it, set `Z80_DEBUG_UNIT=1` in the
environment of `build_romwbw.tcl`. The script then adds the RTL files, the
macro `WITH_DEBUG_UNIT` and `romwbw_dbg_jtag.xdc`. The unit uses the JTAG
link. The build needs no adapter and no Pmod pin (see "JTAG link").

For the serial link, also set `Z80_DEBUG_LINK=uart`. The script then adds
`romwbw_dbg.xdc` and the macro `WITH_DEBUG_UART`. The serial line uses Pmod JA
pin 1 (`dbg_rx`) and Pmod JA pin 2 (`dbg_tx`). Use a 3.3 V serial adapter.
Connect the GND of the adapter to JA pin 5.

Rebuild the board after any change to `rtl/`, and read the DRC messages. The
Nexys RomWBW build is at 94.81 percent of the block RAM, and `CLAUDE.md` has
the history. `MANUAL_CHECKS.md` has the steps for the first run on the board.

## Limits

- The unit has 4 breakpoints by default, 8 at most, and no watchpoints.
- The unit does not stop at an interrupt acknowledge.
- The host cannot write the alternate register set and the bank register.
- The unit cannot stop the core inside an instruction.
- The unit has no flow control. The host must wait for each reply.
- The bank override reaches the low window only.
- The address path to memory has one more multiplexer. Check the timing slack
  of the Nexys build. `romwbw.xdc` has 12-cycle exceptions for the flops of
  `u_cpu`, `u_mmu`, `u_uart`, `u_hdsk` and `led_reg`, and no exception for the
  flops of `u_dbg`. Two paths run in one cycle of the 81.25 MHz clock. The first
  path goes from PC through the breakpoint compare into `stopped`. The second
  path goes from `stopped` and `skip` into `core_clk_en`, which drives the
  clock enable of the flops of the core. If a worst path that starts or ends
  in `u_dbg` fails, register the stop signal in `dbg_unit`. The stop then lands
  one enable tick later.
