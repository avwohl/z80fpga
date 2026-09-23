# Sipeed Tang Nano 20K

Tier (a) builds, and the bitstream has been loaded onto a real board. The
board prints its banner and then restarts; **the design is not why**. `make
gatesim` runs the monitor on the synthesised netlist -- the same netlist that
becomes the bitstream -- and it prints `z80fpga ready`, `banked memory ok` and
the prompt. The section at the bottom says what that rules out, what is left,
and how to read the board when its console is dead. The rest of this file is
the case for the board and the order to take it in, which is unchanged.

The short version: this is the best tier (b) target of any small board in this
tree, because it is the only one whose RomWBW-sized memory is already inside
the FPGA package, and because the whole toolchain is already installed.

## Talking to it on Windows

openFPGALoader needs libusb access to the FT2232's **interface 0**, and
Windows binds its own VCP driver to both interfaces, which shows up as
`usb_open() failed (-4)` -- the device is found and cannot be claimed. Zadig
(Options > List All Devices) fixes it: pick the entry for interface 0 and
replace `FTDIBUS` with `WinUSB`.

Sipeed sets the string descriptor to "USB Debugger" for both interfaces, so
Zadig lists them as **USB debugger 0** and **USB debugger 1** rather than the
"USB Serial Converter A/B" a stock FTDI part would show. Take **0**. Leave 1
alone: it is the console. Afterwards the interface-0 COM port disappears and
the console port remains, and that is the check that you took the right one.

## The part

A **GW2AR-LV18QN88C8/I7**. From Gowin DS226-2.7E (2026-07-31), Table 1-1 and
Tables 1-2/1-3:

- 20,736 LUT4s and 15,552 flip-flops
- 828 Kbit of BSRAM in 46 blocks of 18 Kbit, plus 40 Kbit of shadow SRAM
- two PLLs in the QN88 package (PLLL1, PLLR1), 66 user I/O
- **64 Mbit — 8 MB — of SDR SDRAM in the package**, four banks of 512K x 32,
  each bank 2048 rows x 256 columns x 32 bits, 166 MHz, CAS 2 or 3, 4096
  refresh cycles per 64 ms, 3.3 V LVTTL

Logic is not the constraint. The Icepi RomWBW build is 7456 LUT4 and 1094
flip-flops, which is about 36% of this part.

Block RAM is *tighter* than the ECP5's — 828 Kbit against 1008 Kbit — so a
512 KB ROM cannot come out of the bitstream here either. That does not matter,
because 8 MB of SDRAM is eight times the entire RomWBW map and costs no board
wiring at all.

## The board

From Sipeed's own constraint files in `sipeed/TangNano-20K-example`, not from
prose: 27 MHz clock on pin 4; UART to the on-board BL616 debugger on pins 69
(tx) and 70 (rx); microSD on 83 (CLK), 82 (CMD), 84 (DAT0), 85 (DAT1), 80
(DAT2), 81 (DAT3, which is chip select in SPI mode); six active-low LEDs on
15-20; two buttons on 87 and 88. One USB-C carries both the bitstream and the
console, exactly as the Icepi Zero's FT231X does.

## The toolchain is already here

This was the thing most likely to sink it, and it does not. Verified on this
machine, by inspection rather than by building:

- `yosys` has `synth_gowin` with `-family gw2a`
- `nextpnr-himbaechel` reports `Supported uarches: gowin, gatemate`, ships
  `chipdb-GW2A-18C.bin`, and answers
  `--device GW2AR-LV18QN88C8/I7` with `Info: Using uarch gowin`
- `gowin_pack` (apicula 0.34.dev2) is installed
- `openFPGALoader --list-boards` has `tangnano20k`

So this board drops into the same Makefile-driven shape as `boards/icepi_zero`
and `boards/c0_microsd`. No vendor IDE, no new build idiom. The constraint file
becomes a `.cst` instead of a `.lpf`, and the three tool invocations change.

apicula also knows the in-package SDRAM by name — `O_sdram_addr[11]`,
`IO_sdram_dq[32]`, `O_sdram_dqm[4]`, `O_sdram_ba[2]` and the six control
signals are all in the shipped device database, and the widths agree with the
datasheet exactly.

## The one piece of real work

`rtl/mem/sdram_ram.sv` is a controller for a **16-bit** MT48LC16M16 with a
13-bit row and a 9-bit column. This part's SDRAM is **32-bit with an 11-bit row
and an 8-bit column**, and four DQM lanes rather than two. The controller has
to be parameterised on that geometry, and the widths leak into
`rtl/soc/z80_soc.sv`'s port list and into `sim/sdram_model.sv`.

That is contained, well-understood RTL — but it touches `rtl/soc/`, so
`CLAUDE.md`'s rule applies: rebuild the Nexys RomWBW bitstream afterwards and
check the log for `ERROR: [DRC`. [../../docs/porting.md](../../docs/porting.md)
has the rest of what that entails, including the `req`/`ready` disagreement
that has to be settled before a third backing store is written.

## Order to do it in

1. **Tier (a) first, with no SDRAM at all.** 32 KB ROM + 64 KB RAM in BSRAM, the
   UART on 69/70, LEDs on 15-20. This proves the toolchain, the constraint
   file, the clock and the console in one go, and it is about 40 lines of board
   top. A banner on the console is the milestone.
2. **Pick the clock deliberately.** 27 MHz with `CPU_DIV = 2` gives a 13.5 MHz
   Z80. Note that `uart.sv` computes `DIV = CLK_HZ / BAUD` by truncation, so
   check the baud error, and note that a 13.5 MHz fabric clock shortens the
   SDRAM's 100 us power-up wait through the same truncation — a path this tree
   has never exercised.
3. **Parameterise `sdram_ram.sv`** and rebuild the Nexys. Do this as its own
   commit, with the Icepi SDRAM build rebuilt as the regression: it is the
   existing user of that controller and must come out unchanged.
4. **Tier (a) with 512 KB of RAM in SDRAM**, mirroring `boards/icepi_zero/sdram`.
   This is the memory test with every other variable already settled.
5. **Tier (b).** `rom_loader.sv` stages the 512 KB ROM off the microSD card into
   SDRAM at power-up, exactly as `boards/icepi_zero/romwbw` does, because the
   bitstream cannot carry it here either.

## What is not established

- Whether the open Gowin flow's timing analysis is trustworthy enough to rely
  on for a 13.5 MHz target. The chipdb does carry a per-speed-grade model for
  the C8/I7 grade, so there is an Fmax to read — but nobody here has read one.
- apicula issue #541 reports a signedness miscompile on this exact part. The
  maintainer replied the same day pointing at a probable duplicate. There is no
  `$signed` anywhere under `rtl/`, so it likely does not apply, but it is the
  kind of thing to remember if something behaves impossibly.
- Every pin above comes from Sipeed's own example constraint files. They should
  be checked against the board in hand before the first build, not after.

## How far the first bring-up got, 2026-09-22

Honest state: **the bitstream is proved, the board runs it, and the console
has not printed.** What follows is what was established rather than what was
guessed, because most of a day went into telling those apart.

What is settled:

- The build places, routes and packs: LUT4 7030/20736, **BSRAM 37/46**, 9 IOB,
  1 BUFG, no PLL, **39.51 MHz against a 27 MHz target**. Zero `Unconstrained
  IO`, and zero `not found` after nextpnr's `Reading constraints` line.
- JTAG works and programming works, repeatedly: `idcode 0x81b`, `GW2A(R)-18(C)`,
  `DONE` every time.
- **The FPGA runs the design.** The heartbeat LED blinks and the out-of-reset
  LED lights, which is the 27 MHz clock, the configuration and the reset
  counter all working on real silicon.
- **The UART path works.** A throwaway beacon writing `0x55` to the data port
  from a counter, with no Z80 involved, delivered exactly its designed rate --
  258 bytes in 25 s and 106 in 8 s, against a predicted 12.9/s. So pin 69, the
  bridge, the console port and `rtl/soc/uart.sv` at 27 MHz are all good.

**It prints.** `CPU_DIV = 2` was the fault, and the fix is `CPU_DIV = 1`:

```
z80fpga ready
z80fpga ready
...
```

`CPU_DIV > 1` makes the core advance on a `clk_en` tick, which turns the
memory paths into multi-cycle ones -- and CLAUDE.md already records that
nextpnr accepts a `MULTICYCLE` constraint in total silence and does nothing
with it. A Vivado board can have `CPU_DIV > 1` because an XDC can say so; the
Arty does. A nextpnr board cannot, which is why `boards/icepi_zero` and
`boards/c0_microsd` both use 1. This board now does too, and it costs nothing:
the design routes at 40.6 MHz, so the Z80 runs at the full 27 MHz -- faster
than the Nexys that boots CP/M today.

The symptom was worth recording because it was so misleading. With
`CPU_DIV = 2`, instruction fetch and both I/O directions worked perfectly
while **every** access to data memory failed, which reads like a broken block
RAM and is not one. With `CPU_DIV = 1` a throwaway image that stores `0A5h`
at `0FFF0h` and reads it back returned the right nibble 8904 times running.

What was taken to be left is the bank check. The capture that says so is a
14-second one holding 3851 copies of `z80fpga ready` and no `banked memory
ok`, read at the time as the monitor crashing and restarting -- a run through
the mirrored ROM wrapping to zero, about 270 times a second.

**That reading should not be trusted, and the reason arrived late.** The
channel it came off is now proved dead in hardware by `make beacon`, and this
same link is already recorded below as having delivered 4133 bytes in eight
seconds from a design that sends 13. A bridge that fabricates bytes can
replay a buffer, and 3851 byte-identical 15-byte blocks is exactly the shape
that would take. The one piece of evidence that the machine misbehaves comes
from an instrument since shown to be broken and already shown to invent data.

It may still be true. But nothing else supports it: the monitor runs
correctly on a gate-level simulation of the netlist that becomes the
bitstream, bank check included, and every other suspect in this file has been
cleared. `make ledchk` is how to settle it without the console, and it does
not depend on the link at all.

Two throwaway images did report on the LEDs rather than the console, and
between them they cleared both prime suspects: **`LDIR` completes and
`CALL 08000h` executes out of RAM and returns.**

So the remaining suspect is the one path nothing else exercises: the MMU's
`cur_bank` register through `phys_addr` into the block RAM's address pins,
which only the bank check drives. Note also that **every test that passes
touches only the high window** -- `08000h` and `0FFF0h` are both the common
bank -- while the checker writes to `4000h`, in the low banked window. That is
untested ground, and it is where the monitor dies.

**The design is not the fault.** `make gatesim` runs the console bench against
the *synthesised netlist* -- the same one nextpnr places and `gowin_pack`
turns into the bitstream -- and it prints:

```
z80fpga ready
banked memory ok
>
```

That is the whole monitor, bank check included, out of the flattened gate
netlist with real block RAM contents. It takes three things, and each was a
day's worth of dead end on its own; `sim/gowin_sp.v`'s header records them:

- The suite ships `SP` **and `SPX9`** as empty `(* blackbox *)` cells. Model
  only `SP` and the dispatch table -- the one x9 block -- stays undriven, the
  micro-PC goes X one clock after reset, and the netlist sits dead with no
  error anywhere.
- `SP`'s `INIT_RAM_*` are 256 bits; **`SPX9`'s are 288**, because in x9 mode
  the block's parity bits are part of the array. Get that wrong and the
  memory still elaborates and still simulates, holding the wrong contents.
  `tools/` has the check that compares the netlist's packed init against
  `z80_dispatch.mem`: all 1280 entries match, low-first, 9 bits per word.
- `write_verilog` leaves the constant-0 net undriven. Here it is
  `u_soc.dma_ack`, reaching 2396 places including every block's `BLKSEL`.
  `setundef -undriven -zero` plus `tools/tie_undriven.py` fixes it.

So this much is now settled rather than assumed, and none of it is where the
fault is:

- **The depth expansion is correct.** The 64 KB of RAM is 32 BSRAM blocks one
  bit wide in four groups of eight, selected by `phys[15:14]`; the groups have
  four distinct `WRE` nets, no two blocks drive the same output bit, and the
  read mux's select is a **flip-flop** clocked by `clk`, which is what a
  registered BSRAM output requires.
- **Groups 0 and 1 are fine.** It was tempting that every test which has ever
  passed on this board touches only `phys[15] = 1` -- the stack at `0FFF0h`,
  the `LDIR` target, execute-from-RAM -- while `ld (4000h),a` with bank `80h`
  is the first access to the low half. The gate-level run drives exactly that
  and passes. Dead end; do not spend it again.
- **The dispatch table's 9th bit does not matter here.** Only 40 of 1280
  entries have bit 8 set and they are all in the `FD` page; `LDIR` is `047h`.
  Even total loss of the x9 parity bits would leave the monitor working.

One level deeper was tried and does not reach: **the netlist nextpnr writes
is not the netlist yosys wrote**. Packing adds cells -- 2617 LUT4 and 728 ALU
against 2400 and 622 -- so `make gatesim` does not prove the placed design.
`tools/pnr_json_to_v.py` converts `z80fpga_pnr.json` to Verilog (yosys cannot:
`read_json` asserts on nextpnr's duplicate cell names), `sim/gowin_extra.v`
has the primitives that only appear after packing, and `sim/gowin_alu.v` has
the carry-chain helpers whose string `ALU_MODE` the suite's model has no case
for. What stops it is the ALU itself: **packing folds each ALU's constant
inputs into its LUT configuration and drops the ports**. 461 cells have an
empty `I3`, where the post-synthesis netlist tied every one of them to a
constant -- 415 to 1 and 207 to 0. The intent survives only in a
`RAW_ALU_LUT` parameter, and apicula's own portmap maps `I0`, `I1` and `I3`
to the slice LUT while leaving `I2` out, so those 16 bits are not indexed by
the four data inputs and cannot be read off without documentation this flow
does not carry. Reconstructing it would be a guess with a conclusion resting
on it. Post-synthesis is as deep as this flow can be verified.

Two things were also checked directly on the placed design and are fine: the
clock is on a global network (`'u_soc.clk' net was routed` under "Routing
globals"; the dangling `BUFG` cell in the JSON is how nextpnr represents it,
not a missing buffer), and every block RAM's control pins are tied where they
should be -- `CE` and `OCE` to `GOWIN_VCC`, `RESET` to `GOWIN_GND`, `WRE` to
real logic on the 32 that are written.

One thing nextpnr does **not** do on this family is check hold time. The log
has a single `setup` line and no min-delay report anywhere. A hold violation
would be silent, would survive slowing the clock -- which is exactly what
halving it to 13.5 MHz showed -- and would not appear in any simulation here.
It is the one mechanism still consistent with every observation, and nothing
in this flow can confirm or locate it.

What that leaves is the two links a simulation cannot reach: `gowin_pack`'s
placement of block RAM contents into the bitstream, and the board itself.
`gowin_unpack` recovers 37 `BSRAM` cells from `z80fpga.fs` -- the right count,
32 + 4 + 1 -- but no `INIT_RAM`, so it cannot read the contents back.

The x9 path was tested differently, and it passes. The build is
**byte-deterministic**: two untouched runs produce identical `.fs` files, so a
diff means something. Setting bit 8 -- the parity position, the one apicula
treats specially at width 288 -- on sixteen dispatch entries moves **8 lines**
of the bitstream, and removing the change restores it byte for byte. So the
9th bit does reach the silicon, and `gowin_pack`'s x9 handling is not the
fault. (The packed netlist also carries `BSRAM_SUBTYPE = X9` with 288-bit init
rows on `u_cpu.drom.0.0`, which is what selects that path.)

That leaves the placement of the other 36 blocks' contents, which nothing here
can read back, and the board.

And the board's own USB link is documented below as having enumerated, failed
with Code 43, recovered on a replug, worked, gone silent and then vanished
from USB entirely. A part whose serial bridge dies while JTAG survives is not
a part whose block RAM should be trusted on faith.

Three more hypotheses were tried and cleared, so nobody spends them again:

- **Block RAM read-during-write semantics.** Simulating the monitor with a
  write-first `sync_ram` instead of the repo's read-before-write one changes
  nothing: both print `banked memory ok`. Gowin's `SP` is `WRITE_MODE 2`,
  read-before-write, which is what the RTL already models.
- **The memory falling out of block RAM.** `yosys.log` reports exactly one
  `using FF mapping for memory`, and it is the core's micro-code ROM, which is
  meant to be logic. The count agrees with the map: **36 `SP` blocks is 32 for
  the 64 KB of RAM plus 4 for the 8 KB ROM**, with nothing left over. The RAM
  is whole, it is real block RAM, and it does not alias.
- **A wait state.** Not worth building: halving the clock already gives more
  margin than an extra T-state would, and that was measured to change nothing.
  Whatever this is, it is functional, not a propagation delay.

Two things were tried and did *not* fix it, recorded so nobody spends them
again:

- **Halving the clock.** 13.5 MHz through a `BUFG` with `CPU_DIV = 1`, on the
  theory that the bank-switch path was marginal. A flash-booted 13.5 MHz build
  printed 4411 banners and never reached `banked memory ok`, exactly as 27 MHz
  does. Reverted.
- **Everything on the host USB side.** Selective suspend off, JTAG down to
  1 MHz, `pnputil /restart-device` on the FTDIBUS child, the MI_01 interface
  and the parent composite device, and a full `/disable-device` +
  `/enable-device` cycle. All succeeded and re-enumerated cleanly; the UART
  channel stayed dead. The fault is the board's BL616 bridge, not Windows.

A claim made earlier and since withdrawn: that SRAM programming over JTAG is
what kills the UART. It is not -- program-then-capture worked repeatedly
earlier in the same session. The simpler reading that fits every observation
is that the link is good for a window after a power-up and then degrades,
whatever is done with it. That is also why a multi-minute flash write wedged
partway while a ten-second SRAM load does not.

The bisection that got here, before the `CPU_DIV` fix was found:

- **The Z80 executes from the block-RAM ROM, and `OUT` works.** A loop of
  `ld a,5Ah / out (1),a` delivered clean `Z` bytes.
- **`IN` works and the UART status is right.** A loop reporting
  `in a,(0) and 3 or 40h` returned `B` -- 0x02, transmitter-idle set -- 101
  times in a row, which also exercises `AND`, `OR`, `DJNZ` and `JR`.

So the core, the ROM fetch, both I/O directions and the UART are all good on
silicon. What is *not* settled is why `sw/boot.z80` itself does not print. The
one thing the passing tests never touch and the monitor needs immediately is
**RAM**: it sets a stack at `0FFF0h` and calls. A `CALL`/`RET` test produced
nothing, which points there, but a direct RAM write/read-back test came back
contaminated by the link and has to be repeated before it means anything.

The identical configuration -- `ROM_AW_P 13`, an 8 KB image, `CPU_DIV 2`,
`RAM_BANKS 2` -- prints `z80fpga ready` and `banked memory ok` in simulation,
so it is not the parameters. **Next step: prove or clear the RAM**, on a link
that stays up long enough for a result to be trusted.

**A theory to not waste time on.** A readback appeared to show every byte with
bit 7 set coming back as `0x3f`, which looked like block RAM initialisation
losing the top bit. It is not that. The same corruption appeared with a
hardcoded constant and no memory in the design at all, and that run delivered
4133 bytes in 8 seconds from a design that sends 13 -- a receiver mis-locking
on a bad line, not a byte being altered. `0x55` is precisely the byte that
decodes plausibly through a broken link, which is what made the earlier clean
runs look conclusive. `gowin_pack` was separately shown to carry BSRAM
contents: rewriting the ROM's INIT changed 68,930 bytes of bitstream.

**The USB link is the thing to fix first.** Across one session it enumerated,
failed with `Device Descriptor Request Failed` (Code 43), recovered on a
replug, worked, went silent while Windows still reported it healthy, and then
vanished from USB entirely with no error logged anywhere. Two mitigations are
in place: Windows USB selective suspend was disabled, and `JTAG_FREQ` in the
Makefile now clocks JTAG at 1 MHz rather than openFPGALoader's default 6 MHz,
since a marginal FTDI link often holds at the lower rate. Whether either helps
is unknown. If it stays unreliable the on-board BL616 bridge is the suspect,
and reflashing it is a Sipeed exercise rather than anything in this repository.

## Reading it without a console

`make ledchk` builds and loads `sw/ledchk.z80`, which walks exactly the steps
`sw/boot.z80`'s bank checker walks and reports on the LED port at `0xFF`
instead of the UART. The **three rightmost LEDs** are that port's low three
bits, and a lit LED is a 1, so they read as a number with the leftmost of the
three as the high bit:

- **1** -- alive, running from ROM
- **2** -- reached `8000h` in the common bank
- **3** -- RAM bank `80h` selected and written
- **4** -- RAM bank `81h` selected and written
- **5** -- every bank read back
- **6** -- **the bank check passed**
- **7** -- **the bank check failed**, a bank read back wrong

It halts on the final value, so a steady reading is a result and a flickering
or dark one means it died before getting that far. **6** clears the banked
memory and moves the fault elsewhere in the monitor; **7** convicts it; **2**,
**3** or **4** says it does not survive the bank switch at all.

The three LEDs beside them are unchanged: the leftmost blinks as the
heartbeat, the next is lit out of reset, and the third is lit once the UART
has seen its line pulled low -- which on this board it has not, and that is
the bridge failure itself.

This is worth having rather than a throwaway because the LED port is the only
channel off this part that still works. It needs one glance and no serial.

## If the console is dead, the flash is the way out

Not built, but scouted, because it is the only channel off this part that
does not need a person looking at it. `gowin_pack --mspi_as_gpio` hands the
configuration SPI pins to user logic after configuration, and
`openFPGALoader --dump-flash -o <addr> --file-size <n>` reads the flash back.
Between them, logic that writes a flash page is a readback channel over JTAG.

The pins are bonded out on this package, which was the part in doubt. From
apicula's own chipdb (`GW2A-18C.msgpack.xz`, the `pinout`/`QFN88` table), the
configuration-SPI signals are:

- **MCLK** pin 59 (`IOR34B`), **MCS_N** pin 60 (`IOR34A`)
- **MO** pin 61 (`IOR33B`) to the flash, **MI** pin 62 (`IOR33A`) from it
- and, unused for this, DOUT 53, DIN 54, SSPI_CS_N 55, FASTRD_N 57

A page program needs an erased page, so pick an address past the bitstream --
a `.fs` here is about 7.3 MB -- and read it first to see what is there.

Two reasons it was scouted and not built. It can issue an erase or a program
by accident and take the boot bitstream with it, which is recoverable over
JTAG but not free. And it answers a diagnostic question that `make ledchk`
answers for nothing. It is written down because the same channel is what a
flash-backed disk or a bitstream-resident ROM would need later, and finding
those four pin numbers was the slow part.

It is worth being clear that this would *not* make the board usable. The
console is this design's only I/O; a flash readback is a debug port, not a
console. While the bridge is dead there is no operational system to have.

## The state of the board itself

The board's flash holds the **`make ledchk` image**, not the monitor, so the
LED reading above survives a power cycle and needs no JTAG, no console and no
host. Plug the board in and the three rightmost LEDs settle on the answer.
`make flash` puts the real build back.

It replaced an earlier staged diagnostic that reported over the console --
`A` alive, `B` after `LDIR` into the common bank, then `P` or `E` for whether
`4000h` in the low banked window read back what was written. That one is
useless on a board whose console has failed, which is why it was replaced.

**Its serial channel has failed, and that is now proved rather than
inferred.** `make beacon` builds a console beacon with no Z80 in it -- a
counter writing `0x55` to the UART's data port about 103 times a second, so
the only things in the path are pin 69, the BL616 bridge, the host's COM port
and `rtl/soc/uart.sv`. The identical construction earlier in this bring-up
delivered exactly its designed rate, 258 bytes in 25 s. It now delivers
**zero bytes in 12 seconds**, where a live channel would give about 1240.

`make loopback` asks the same question the other way and is the shorter one:
the whole design is `assign uart_tx = uart_rx;`. Eight bytes sent at the
console port come back as **none**, with CTS, DSR and CD all false. There is
no logic in that design at all, so nothing in this repository can be the
reason.

So the bridge is dead as a hardware matter, in both directions, and no change
to this repository can revive it. Run one of those two before believing
anything a silent console seems to say about the design: they separate a
broken link from a broken build, which is a distinction most of a day went
into re-learning. `loopback` is the one to reach for first -- it is ten lines
and it covers both directions at once.

JTAG is meanwhile perfectly healthy -- `idcode 0x81b`, `GW2A(R)-18(C)`, and
`openFPGALoader` reports `DONE` on every load. COM7 enumerates, opens without
error, and every USB device reports OK, so the host side is not at fault. Spent on it, all
successful and none of them any help: Windows USB selective suspend disabled,
JTAG dropped from 6 MHz to 1 MHz, `pnputil /restart-device` on the FTDIBUS
child, on the `MI_01` interface and on the parent composite device, a full
`/disable-device` + `/enable-device` cycle, and `openFPGALoader --reset`. A
physical replug has revived it before and nothing else has.

So the last measurement needs a power cycle, and the diagnostic in flash is
there to make that power cycle produce the answer by itself.
