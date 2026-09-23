# RomWBW on the Icepi Zero

The full 512 KB + 512 KB map, with both halves in the board's SDRAM and the
ROM half fetched off the microSD card at power-up.

## Why the ROM has to come off the card

On the Nexys A7 the ROM is the bank in block RAM and the RAM is in DDR2. The
ROM is the one whose contents have to be there before the first instruction
fetch, and 512 KB of block RAM is available on an XC7A100T, so that is where
it goes.

Neither half of that reasoning survives here. An ECP5 LFE5U-25F has 56 EBRs,
a byte-wide ROM packs at 2304 bytes into each, and 126 KB is therefore the
ceiling for all the block RAM in the design put together — so a 512 KB ROM
cannot come out of the bitstream on this part whatever else is given up.
Something has to fetch it.

The card does. This build needs the slot anyway, for HDSK0: and HDSK1:;
`rtl/soc/sd_spi.sv` is the only thing in this repository that has been proved
against a real card; and `rtl/soc/rom_loader.sv` is 150 lines on top of it.
The alternative was the SPI configuration flash, which would want a second
SPI master and the `USRMCLK` primitive to drive a pin the configuration
engine owns.

## Preparing the card

Two things have to be on it. The CP/M slices go where they always go —
[../../nexys_a7_100t/romwbw/README.md](../../nexys_a7_100t/romwbw/README.md)
has that sequence, and it is unchanged. The new one is the ROM image, at
block **0x400000**, which is 2 GiB in:

```
dd if=SBC_simh_std.rom of=/dev/sdX bs=512 seek=4194304 conv=fsync
```

That is a stock `SBC_simh_std.rom` — one you have, or
`python tools/romwbw_fetch.py -o SBC_simh_std.rom`, which takes
`Binary/SBC_simh_std.rom` out of the upstream release package the romwbw_disks
catalog names and checks the package against its published SHA-256. It has to
be the stock image and not an emulator ROM;
[../../nexys_a7_100t/romwbw/README.md](../../nexys_a7_100t/romwbw/README.md)
says why. `dd` takes the `.rom` itself, not a `.hex`.

That block is not arbitrary. `hdsk.sv` puts its two units 0x200000 blocks
apart, so unit 0 owns blocks 0 to 0x1FFFFF and unit 1 owns 0x200000 to
0x3FFFFF; 0x400000 is the first block after both of them. The card therefore
has to be larger than 2 GiB, and the image must be a whole number of 512-byte
blocks — a stock RomWBW `.rom` is 512 KB, which is 1024 of them.

`ROM_LBA` and `ROM_BLOCKS` in `top_romwbw.sv` are both parameters if a
different layout suits you better.

### Writing a prepared image instead of running FDISK80

The slices can be written on from the host instead of made inside the machine,
if the image carries the MBR `FDISK80` would have written. `hd1k_combo` from
[romwbw_disks](https://github.com/avwohl/romwbw_disks) does: its first
partition entry is type `0x2E` at LBA 2048, and that is the entry HBIOS looks
for. A bare single-slice image has no MBR at all and will not do.

Each unit's own block 0 is where it goes, so the seek is the unit base and
nothing else — `UNIT_STRIDE` in `rtl/soc/hdsk.sv` is `0x200000` blocks, so
unit 0 starts at 0 and unit 1 at 2097152:

```
dd if=hd1k_combo-v0-3.6.0.img of=/dev/sdX bs=512 seek=0       conv=fsync
dd if=hd1k_combo-v0-3.6.0.img of=/dev/sdX bs=512 seek=2097152 conv=fsync
```

**This has not been tried on hardware.** Every prepared card here was made the
other way, with `FDISK80` and `CLRDIR` in the booted machine, and whether HBIOS
reads an MBR laid down by `dd` exactly as it reads one it wrote itself is
untested. The `FDISK80` sequence is the proven one.

## Build

```
source ../../../tools/ossenv.sh
cd boards/icepi_zero/romwbw
mingw32-make
mingw32-make flash
```

There is no `boot.hex` in this build and nothing to regenerate when the
monitor changes: the ROM is on the card, not in the bitstream. Changing the
firmware means rewriting the card, not rebuilding the FPGA.

## What happens at power-up

1. `sdram_ram` runs the chip's 100 µs initialisation. `led[2]` goes up.
2. `rom_loader` waits for `sd_spi` to bring the card up, then reads 1024
   blocks into the bottom 512 KB of the chip. `led[3]` goes up.
3. The Z80 comes out of reset and fetches its first instruction from what was
   just staged.

The core is held in reset for all of that, and that matters more than it
sounds: released early it would fetch zeros, which are `NOP`s, and walk the
whole 64 KB before arriving back at 0000 to run the firmware properly — a
board that works, several milliseconds late, until the day the timing shifts
and it does not. `sim/tb_romload.sv` watches `mreq_n` for exactly this.

Staging 512 KB takes something under a second at the SPI clock `sd_spi`
settles on, so step 2 is visible rather than instant. `led[4]` is
`rom_failed`: the card answered but would not give the image up after three
attempts. All three dark means the card never came up at all, which is the
slot, the card or the wiring rather than anything here.

## What it builds to

```
TRELLIS_COMB    7456 / 24288   30%
TRELLIS_FF      1094 / 24288    4%
DP16KD             3 /    56    5%
TRELLIS_IO        56 /   197   28%
Max frequency for clock 'clk_sys': 28.82 MHz (PASS at 25.00 MHz)
```

Three EBRs of the 56 — the core's dispatch table and `sd_spi`'s sector buffer,
and nothing else. Every byte the Z80 can address is in the SDRAM.

HDSK and the loader are 20% more logic than the base SoC and it costs nothing
in speed worth measuring: 28.82 MHz against the plain build's 28.57. The
margin over 25 MHz is 14%, the same order as the other two, and the same
escape hatch applies — `CLK_SHIFT` in `top_romwbw.sv` and the `FREQUENCY NET`
line in the `.lpf` go to 12.5 MHz together, and a 12.5 MHz Z80 is still faster
than the Nexys that runs CP/M today.

That sector buffer was the whole problem. Written as a memory with two write
ports, which is the obvious way to say it and is what it was, no memory on any
family can hold it: yosys reports "using FF mapping", and forcing the issue
gets "no valid mapping found". Vivado does the same thing without saying so —
the Nexys RomWBW utilisation report shows zero RAMB18s and 4096 flip-flops,
which on a part with 126,800 registers nobody noticed. On an ECP5 the same
512 bytes made `sd_spi` alone **17,687 LUT4s**, three quarters of the part
before the Z80. Muxing the two writers onto one port, which costs nothing
because they are already exclusive in time, makes it two EBRs and 606.

It also broke the Nexys, which is the other half of the story and is in
`rtl/soc/sd_spi.sv`: that build is at 94.81% of its part's block RAM and the
muxed buffer made its `place_design` fail, for reasons that turned out not to
be the block RAM. It pins `SD_BUF_MUX` to 0 and keeps the netlist it was
proved with. This board takes the default.

## Untested on hardware

No Icepi Zero has run this, and nothing here has booted a RomWBW image on
this board. What has been done is `sim/tb_romload.sv`: a ROM image on a
behavioural card, staged into a behavioural MT48LC16M16 by this loader,
compared against the original byte for byte, and then executed by the Z80
until the monitor prints its banner and echoes what is typed at it. Four ways
of breaking it — the loader ignoring `ROM_LBA`, its buffer read off by one,
the core released before staging finished, and the ROM and RAM windows landing
on top of each other — each make that bench fail.

That is a long way from a board on a desk. In particular the image in that
bench is 2 KB of boot monitor, not 512 KB of RomWBW, and no RomWBW image has
been through this path at all.

## The card comes up, and which card matters, 2026-09-23

First hardware run of this build. With a **16 GB SDHC** card in the slot and
no image on it, the lamps read **`led[3]` alone**: `rom_done` high, the Z80
released, `led8` still zero because it is executing whatever was at
LBA 0x400000 on a blank card. That is the expected shape of a good card with
nothing useful on it, and it puts `sd_spi`, the SPI wiring, `rom_loader` and
1024 blocks of staging on the record.

A **128 GB SDXC** card in the same slot, same bitstream, gave **`led[2]`
alone**: `sdram_ready` high, `rom_done` and `rom_failed` both low. Per
`rom_loader.sv`'s own header that is a card that never raised ready -- the
loader sitting in its first state, waiting. So the initialisation in
`sd_spi.sv` does not bring that card up. Which step it stops at is not known
yet; `sdtest` below is the build that would say.

This is one card of each kind, not a survey. But **start with SDHC**: it is
the conservative case and it is the one that has worked here.

### `make sdtest`, when a card will not come up

`romwbw/` holds the Z80 in reset until the ROM has been staged, so a card that
never comes up gives a board that says nothing and one lamp to read it by.
`top_sdtest.sv` answers the same question with a console instead: same pins,
same `.lpf`, but the ROM is in the bitstream, so the CPU runs immediately and
`sim/hdsk_test.z80` drives the card and prints what it said. HDSK's debug port
is 0xFC, and its `status2` reads `E0 + sd_spi`'s state while the card machine
is still working, which is how a stuck initialisation names the step it is
stuck on.

It writes a sector as well as reading one. The HDSK units sit below
LBA 0x400000, clear of the ROM image, but do not point it at a card whose
contents matter.
