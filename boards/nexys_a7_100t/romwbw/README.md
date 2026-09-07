# RomWBW on the Nexys A7-100T

The full 512 KB + 512 KB machine. **CP/M 2.2 runs on this**, verified on
hardware on 2026-09-06 — see [docs/romwbw.md](../../../docs/romwbw.md) for the
console transcript.

```
python tools/mkromhex.py path/to/SBC_simh_std.rom \
    boards/nexys_a7_100t/romwbw/romwbw512k.hex --size 524288
cd boards/nexys_a7_100t/romwbw
vivado -mode batch -source build_romwbw.tcl
```

Program `build/romwbw_soc.bit`, open the console at 115200 8N1, and you get
HBIOS, the device inventory and `Boot [H=Help]:`. `L` lists the ROM
applications; `C` boots CP/M 2.2.

The ROM image is not in the repository — build it first with the command
above, from your own RomWBW checkout or emulator ROM set.

Timing closes at WNS +1.216 ns, 0 of 14909 endpoints failing, using 7243 LUTs
(11%) and 128 of the 135 block RAM tiles.

## Where the memory lives

- **ROM, 512 KB, block RAM.** 128 RAMB36 tiles, initialised from the image at
  bitstream build. It has to be this one rather than the RAM, because it is the
  only half whose contents must already exist at the first instruction fetch.
- **RAM, 512 KB, DDR2.** Volatile, which suits RAM, since it starts undefined
  anyway. Reached through `rtl/mem/ddr2_ram.sv` over the MIG's AXI port.

DDR2 cannot answer in a T-state, so it does not pretend to: `ddr2_ram` holds
`wait_n` low until the transaction finishes and the core freezes `tcnt` at the
strobe T-state. That is the whole mechanism — no cache is required to be
correct. There is a one-line read cache anyway, because instruction fetch is
sequential and it turns sixteen DDR2 reads into one.

Everything runs on the MIG's `ui_clk` at 81.25 MHz, and `CPU_DIV` stays at 12
for a 6.8 MHz Z80, which also keeps the core's multicycle constraints the same
as the block RAM build.

## The constraint that actually mattered

The Z80's write data reaches the MIG's AXI port combinationally out of core
registers, and that is an eighteen-level path that does not make 12.3 ns:

```
u_cpu/upc_reg[5] -> u_mig/.../u_ui_top/ui_wr_data0/write_buffer...
Requirement 12.308ns, Data Path Delay 12.945ns
```

Two cycles is the right exception and it is provable rather than hopeful:
`ddr2_ram` registers `awvalid`, so the MIG cannot see a request until the clock
after the core presented it, and cannot sample address or data before `awready`
the cycle after that — while the core sits stalled on `wait_n` changing
nothing. Two, not twelve: the launch is a `clk_en` edge but the capture is not,
so the argument that gives core-to-core paths twelve does not apply here.

Worth recording how this was misdiagnosed, because the evidence was
misleading. The failing paths reported were overwhelmingly *inside* the MIG —
its XADC temperature monitor missing 200 MHz by 0.73 ns where it had 2.6 ns of
slack in a design without the SoC — which looks exactly like congestion from
128 of 135 block RAMs. It was not. Halving the ROM to 256 KB dropped block RAM
to 47% and made timing **worse** (WNS -0.983, 178 failing endpoints, against
-0.730 and 63). The real cause was one unconstrained path, and the MIG's
internal failures were downstream of the placer being pushed around by it.

## The disks

`HDSK0:`/`HDSK1:` are the SIMH AltairZ80 hard disk on port `$FD`, and
`rtl/soc/hdsk.sv` implements that controller against the microSD card through
`rtl/soc/sd_spi.sv`. No firmware change was needed: the driver is already in a
stock `SBC_simh_std` ROM, enabled by `HDSKENABLE`, and had been enumerating two
units that nothing answered for.

Reading and writing both work, on hardware, from CP/M. `PIP C:=B:STAT.COM`
copies a file to the card, `DIR C:` lists it, `STAT C:` shows the space gone,
and after reconfiguring the FPGA the file is still there and runs from `C:` --
which is as strong as this gets, since nothing survives reconfiguration except
the card.

## The bug that made writes fail, and why it hid for so long

The controller's wait reply arrived one clock too late to stall the read it
belonged to.

`port_rd` was gated by `clk_en`, and `clk_en` is high only in the *last* clock
of a T-state -- the same edge on which the core tests `wait_n`, latches the
data bus and leaves the strobe T-state. `io_wait` was a register, so it rose
one clock after that. The core therefore saw `wait_n` still high, took whatever
was in the status register *before* the controller had run, and moved on. Two
things followed, and both of them look like something else:

- **Every status read answered the read before it.** A command's real result
  was handed to the *next* `IN`. Since a successful status is 0 and the reset
  value of the register is also 0, this is invisible until something fails --
  and then the failure is reported against the wrong command.
- **The transfer was not actually stalled.** The stall landed on the following
  bus cycle instead, freezing an M1 fetch with `mreq_n` low while the DMA moved
  `mem_addr` out from under it.

The fix is that `io_wait` is combinational and held for the whole read cycle
until there is something true to hand back, with an independent backstop so
that no path through the state machine can leave the CPU frozen.

`sim/hdsk_test.z80` now checks this directly: after its three commands it reads
the status port once more with nothing outstanding, which must return `8E`. If
the wait is late it returns the previous command's `00` instead. That one byte
is the difference between a test that catches this and one that cannot.

## Measurement traps this cost, all of them mine

Four separate "results" in the earlier version of this file were artefacts.
They are recorded because each one sent the investigation somewhere wrong.

- **A timing measurement taken on a build with no multicycle constraints**,
  where 4801 of 7118 endpoints failed. Nothing measured on it meant anything.
- **A probe that reported failure because it ran too early.** It issued its
  first command microseconds after reset, while the card was still polling
  ACMD41. `H_GO` now waits for the card instead of failing the command.
- **A probe that reported silence because the console moved.** This build puts
  the console on RomWBW's SSER ports, `0x6D`/`0x68`; the test program wrote to
  `0x00`/`0x01`. That was briefly read as a DDR2 fault.
- **A probe whose status bytes were `db` labels in the ROM image.** Every
  `ld (st1),a` went nowhere and every `ld a,(st1)` read the ROM's zero back,
  which prints as a perfectly plausible `status 00` whatever the controller
  said. They live in RAM now.

And one about the card rather than the design: on a blank card a broken read is
indistinguishable from a working one, because both hand back a sector of zeros.
`STAT C:` reporting `8176k` was taken as evidence that reads worked and is not
-- CP/M computes that from a directory of zeros. Reads are only really verified
by writing a known pattern and reading it back past a buffer flush, which is
what `sim/hdsk_test.z80` does: it reads a *different* sector between the write
and the read-back, because without that the comparison is answered out of the
controller's own 512-byte buffer and passes whether or not anything reached the
card.

## What the controller does when something does go wrong

- Every wait is bounded. `hdsk` times out a command rather than leaving the CPU
  frozen behind it, `sd_spi` times out any state that stops changing -- with
  `S_WR_BUSY` previously having no limit at all -- and the stall itself has a
  backstop independent of both.
- A status read part way through a parameter block aborts it and reports `8F`,
  so a lost byte would cost one operation instead of desyncing the port.
- A status read with nothing outstanding reports `8E` rather than the previous
  command's status.
- The codes say where it stopped: `8x` the controller's own state, `Cx` a card
  state that genuinely stalled, `Ex` what the card machine was doing when the
  controller gave up, `4x`/`Ax`/`Bx` the card's own R1 and data responses.
- Port `0xFC` reads the strobe counters: write 0-3 to it, read it back, and get
  the number of writes to the command port that were accepted, that were
  dropped because the previous one had not been retired, that arrived while no
  case arm was collecting, and the controller's state. Those three account for
  every strobe that reaches the port, which is how "a byte of the block is
  going missing" was ruled out: they rose by exactly seven per command.

## Preparing the card

A card straight out of a camera or a card reader will not work past `C:`, and
`C:` only by accident. RomWBW keeps its CP/M slices in an area reserved in the
MBR, and a factory card has a FAT32 partition sitting exactly where that area
has to go. The symptom is that `C:` can be made to work with `CLRDIR` while
`D:` onwards answer `Invalid drive specified`, and selecting one of them wedges
CP/M (see below).

Prepare each HBIOS unit once, from the RAM disk, with RomWBW's own `FDISK80`.
Unit 2 is `HDSK0:` (drives `C:`-`F:`) and unit 3 is `HDSK1:` (`G:`-`J:`):

```
B>FDISK80
HBIOS unit number [0..3]: 2
>>D      Partition number to delete: 1      (repeat for every non-empty entry)
>>P                                         check they are all empty
>>R      Reserve how many CP/M slices: 8
>>P                                         "Reserved 8 x 8Mb CP/M slices"
>>W      Do you really want to write to disk? [N/y]: y
```

Two things about driving it, both of which cost a run to find out. The unit
number is taken as a single keypress, so the RETURN after it is read as the
first command and prints the table -- send it deliberately and wait, or the
command after it is swallowed. And `D 1` on one line does not work; `D` prompts
for the number separately.

Then give each drive a directory, from a drive that is not itself being
cleared. `CLRDIR` takes the drive as an argument, which is what breaks the
circularity of a drive that cannot be selected until it has a directory:

```
B>CLRDIR C:      ... and D:, E:, F:, G:, H:, I:, J:
```

After that all ten drives select, and `STAT` reports each of the eight card
slices as `R/W, Space: 8176k`.

## Selecting a drive that is not prepared

CP/M 2.2 has no way out of this, and it is worth knowing that it is CP/M's
behaviour rather than a fault in the controller:

```
B>D:
Bdos Err On D: Select
Bdos Err On D: Select      ... for ever
```

BDOS prints the error and warm boots, the CCP's default drive is still `D:`, so
it selects it again and errors again. Ctrl-C, RETURN and typing another drive
letter all just produce another error, because each of them reaches the CCP
only after the select has already failed. **Press the red CPU RESET button** --
`CPU_RESETN`, pin C12 -- which resets the MIG and the SoC and reboots RomWBW.

The controller is not involved in this. Sector reads of an unprepared slice
succeed and return promptly: reading LBA `004000`, `004001`, `004002` and
`004010` directly through port `$FD` gives status `00` for all four, and the
data that comes back is the FAT boot sector that was there -- `EB 58 90` then
`mkfs.fat`. HBIOS refuses the drive before the controller is ever asked.

Each unit is `UNIT_STRIDE` blocks apart on the card, 1 GiB, matching what the
driver claims. Unit 0 starts at card block 0, so **writing to `C:` overwrites
the start of the card**.

## Power-up

`../flash.tcl` writes a bitstream into the board's QSPI flash so it comes up
running with no computer attached. Set the MODE jumper **JP1 to QSPI** first,
or the FPGA will ignore the flash at power-up and come up blank.
