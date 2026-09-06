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

Reading is verified on hardware — `STAT C:` under CP/M returns
`Bytes Remaining On C: 8176k`, read off the card. **Writing is not yet
working**: `CLRDIR C:` and `PIP` report success and nothing lands, so a
directory written to the card reads back unchanged and CP/M then says
`NO DIRECTORY SPACE` while `DIR C:` says `NO FILE` — the signature of a
directory full of zeros rather than `E5`.

What has been ruled out, so nobody repeats it:

- **The card layer works.** A hardware probe using this exact `sd_spi` module
  writes a block and reads it back byte-correct: `R1 W00 D00` and the pattern
  intact.
- **The protocol and the DMA work in simulation**, including against the real
  `ddr2_ram` with a behavioural AXI slave — `make test` runs both.
- **Two real bugs were found and fixed** on the way, either of which would
  have done it: the write path sent one CRC byte where the card expects two,
  and `start_rd`/`start_wr` were one-cycle pulses whose completion was tested
  as `!busy`, so a pulse the card layer did not happen to see reported success
  having transferred nothing.

The remaining difference between the passing simulation and the failing
hardware is the MMU: on hardware the DMA address is translated by the live
bank mapping, which the module-level testbench does not exercise.

Each unit is `UNIT_STRIDE` blocks apart on the card, 1 GiB, matching what the
driver claims. Unit 0 starts at card block 0, so **writing to `C:` overwrites
the start of the card**.

## Power-up

`../flash.tcl` writes a bitstream into the board's QSPI flash so it comes up
running with no computer attached. Set the MODE jumper **JP1 to QSPI** first,
or the FPGA will ignore the flash at power-up and come up blank.
