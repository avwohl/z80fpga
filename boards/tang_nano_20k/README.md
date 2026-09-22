# Sipeed Tang Nano 20K

Tier (a) builds, and the bitstream has been loaded onto a real board. It does
not print yet, and the section at the bottom says exactly how far it got and
what is still unknown. The rest of this file is the case for the board and the
order to take it in, which is unchanged.

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

What is left is the bank check, and it is narrowed a long way. The banner
prints and then the monitor restarts, looping on the banner -- about 270 times
a second, which is a crash running through the mirrored ROM and wrapping to
zero, not a USB dropout. Two throwaway images reported on the LEDs rather than
the console, because the serial channel on this board dies while JTAG stays
up, and between them they cleared both prime suspects: **`LDIR` completes and
`CALL 08000h` executes out of RAM and returns.**

So the remaining suspect is the one path nothing else exercises: the MMU's
`cur_bank` register through `phys_addr` into the block RAM's address pins,
which only the bank check drives. Note also that **every test that passes
touches only the high window** -- `08000h` and `0FFF0h` are both the common
bank -- while the checker writes to `4000h`, in the low banked window. That is
untested ground, and it is where the monitor dies.

Reading the netlist sharpens that from "the low window" to something narrower
and physical. The 64 KB of RAM is **32 BSRAM blocks configured one bit wide**,
in four groups of eight, and the netlist bears out the obvious structure: the
four groups have four distinct `WRE` nets, so depth is decoded by gating the
writes, and no two blocks drive the same output bit. Which group an access
lands in is `phys[15:14]`, so:

- the common bank, `phys[15] = 1`, is **groups 2 and 3**;
- a RAM bank in the low window, `phys[15] = 0`, is **groups 0 and 1**.

The stack at `0FFF0h`, the `LDIR` target at `08000h` and the execute-from-RAM
test are all `phys[15] = 1`. **Nothing that has ever worked on this board has
addressed groups 0 and 1**, and `ld (4000h),a` with bank `80h` selected is the
first access in the whole bring-up that does. That is the shape of the thing
to test, and `make ledchk` is how to read the answer.

Simulating the netlist itself is the obvious next instrument, and it is
half-built. `sim/gowin_sp.v` is the piece the OSS CAD Suite does not ship: its
`SP` primitive is an empty `(* blackbox *)`, so a post-synthesis run reads
back `zz` and looks like a dead end. With that model, and with the constant-0
net given a driver -- `write_verilog` names it `u_soc.dma_ack`, wires it to
every block's `BLKSEL`, and never drives it -- the netlist comes out of reset
properly and fetches `0F3h`, `di`, from the ROM. It then goes X in the CPU's
address-ALU carry chain one clock later, for no reason yet found. The header
of that file says exactly where to resume.

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

## The state of the board itself

The board's flash holds a **diagnostic**, not the monitor: a staged test that
emits `A` once it is alive, `B` once `LDIR` into the common bank has
completed, and then `P` or `E` for whether `4000h` in the low banked window
reads back what was written. One power-up prints the answer, if the console
ever comes back. `make flash` puts the real build back.

Its SRAM currently holds the `make ledchk` image, which needs no console at
all.

**Its serial channel has failed.** JTAG is perfectly healthy -- `idcode 0x81b`,
`GW2A(R)-18(C)`, and `openFPGALoader` reports `DONE` on every load -- while the
UART delivers nothing. COM7 enumerates, opens without error, and every USB
device reports OK, so the host side is not at fault. Spent on it, all
successful and none of them any help: Windows USB selective suspend disabled,
JTAG dropped from 6 MHz to 1 MHz, `pnputil /restart-device` on the FTDIBUS
child, on the `MI_01` interface and on the parent composite device, a full
`/disable-device` + `/enable-device` cycle, and `openFPGALoader --reset`. A
physical replug has revived it before and nothing else has.

So the last measurement needs a power cycle, and the diagnostic in flash is
there to make that power cycle produce the answer by itself.
