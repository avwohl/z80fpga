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

Reading and writing both work at the controller level on hardware, verified
byte for byte. **Disk access under RomWBW does not**: `CLRDIR C:` reports
"Directory cleared" and nothing lands, and CP/M then says `NO DIRECTORY SPACE`
while `DIR C:` says `NO FILE` — the signature of a directory of zeros rather
than `E5`, which is what a blank card reads back as.

Note that a blank card makes a broken read indistinguishable from a working
one: both hand back a sector of zeros. `STAT C:` reporting
`Bytes Remaining On C: 8176k` was read as evidence that reads worked, and it is
not — CP/M computes that from a directory of zeros. Reads are verified instead
by writing a known pattern and reading it back past a buffer flush.

What has been established, so nobody repeats it:

- **Writes reach the card.** A bare-metal probe on this exact board build —
  81.25 MHz, the same MIG, RAM in DDR2, the same constraints, only the ROM
  contents and the console ports differ — writes a sector, reads a *different*
  sector to refill the controller's 512-byte buffer, reads the first one back
  and compares all 512 bytes: `W00 F00 R00 A5A6A7A8 OK`, over and over. The
  flushing read matters: without it the comparison is answered out of the
  buffer the write just filled and passes whether or not anything ever reached
  the card, which is how an earlier version of this probe passed while the card
  was untouched.
- **So the write path is not the problem**: not the card, not `sd_spi`, not
  CMD24, not the DMA out of DDR2, not the MMU translating the DMA address.
- **The fault is the command framing on port `$FD`.** Driving the controller by
  hand from the CP/M TPA with `DDT` — the same seven-byte block and `IN` that
  `hdsk.asm` issues — a command reproducibly loses one of its seven bytes. The
  controller then sits half-fed, and the *next* command's first byte completes
  the previous one, so every command after it is assembled from bytes belonging
  to the one before. Operations report the previous command's status, which is
  how `CLRDIR` says "Directory cleared" while nothing is written.
- **Not the bank window**: the same test fails with buffers in the common bank
  (`8000`+) and in the banked low window (`2000`+).
- **Not interrupts**: it fails identically with `DI` around the sequence.
- **Not reproducible in simulation.** `sim/tb_hdsk_soc.sv` runs the whole SoC
  with a real Z80 driving `$FD` exactly as `hdsk.asm` does, now at `CPU_DIV=12`
  so the clock-enable-gated strobes are exercised, with the blocks fetched from
  DDR2 so `OTIR`'s reads take wait states, and with the three commands issued
  back to back. It passes. Whatever loses the byte is not in that model.

Two earlier conclusions in this file were wrong and are worth recording as
traps. A timing measurement was taken on a build with no multicycle
constraints, where 4801 of 7118 endpoints failed; nothing measured on it meant
anything. And a probe reported failure for a week because it issued its first
command microseconds after reset, while the card was still polling ACMD41 —
`H_GO` now waits for the card instead of failing the command.

What the controller does about it now, since the root cause is not found:

- Every wait is bounded. `hdsk` times out a command rather than leaving
  `io_wait` asserted with the CPU frozen behind it, and `sd_spi` times out any
  state that stops changing — `S_WR_BUSY` previously had no limit at all.
- A status read part way through a parameter block aborts it and reports `8F`,
  so a lost byte costs one operation instead of desyncing the port for good.
- A status read with nothing outstanding reports `8E` rather than handing back
  the previous command's status, which is what made a command that never
  framed report success.
- The status codes say where it stopped: `8x` the controller's own state, `Cx`
  a card state that genuinely stalled, `Ex` what the card machine was doing
  when the controller gave up, `4x`/`Ax`/`Bx` the card's own R1 and data
  responses. A second status read returns the companion code.

Each unit is `UNIT_STRIDE` blocks apart on the card, 1 GiB, matching what the
driver claims. Unit 0 starts at card block 0, so **writing to `C:` overwrites
the start of the card**.

## Power-up

`../flash.tcl` writes a bitstream into the board's QSPI flash so it comes up
running with no computer attached. Set the MODE jumper **JP1 to QSPI** first,
or the FPGA will ignore the flash at power-up and come up blank.
