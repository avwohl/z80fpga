# Running RomWBW

**CP/M 2.2 runs on the hardware.** On a Nexys A7-100T, 2026-09-06:

```
Loading CP/M 2.2...

CBIOS v3.5.1 [WBW]

Formatting RAMDISK...

Configuring Drives...
        A:=MD0:0
        B:=MD1:0
        ...
CP/M-80 v2.2, 54.0K TPA

B>DIR
B: ASM      COM : CLRDIR   COM : COMPARE  COM : COPY     COM
B: DDT      COM : DDTZ     COM : DUMP     COM : ED       COM
...
B>PIP A:=B:STAT.COM
B>DIR A:
A: STAT     COM
A>STAT
A: R/W, Space: 242k
B: R/W, Space: 22k
```

That last part is the whole memory system working at once: a file copied from
the ROM disk in block RAM onto the RAM disk in DDR2, listed back, and then
loaded from DDR2 and executed. "Formatting RAMDISK" is CP/M writing its way
across a quarter of a megabyte of DDR2 before it will even give you a prompt.

The build is [boards/nexys_a7_100t/romwbw](../boards/nexys_a7_100t/romwbw/README.md).

## In simulation

`make romwbw` gets to the loader prompt without any hardware:

```
RomWBW HBIOS v3.5.1, 2025-05-21

RetroBrew SBC [SBC_simh_std] Z80 @ 8.000MHz
0 MEM W/S, 1 I/O W/S, INT MODE 1, SBC MMU
512KB ROM, 512KB RAM, HEAP=0x5961
ROM VERIFY: 00 00 00 00 PASS

SSER: IO=0x6D
SIMRTC: Tue 20FF-FF-FF FF:FF:FF
MD: UNITS=2 ROMDISK=384KB RAMDISK=256KB
HDSK: DEVICES=2

Unit        Device      Type              Capacity/Mode
----------  ----------  ----------------  --------------------
Char 0      EF0:        RS-232            9600,8,N,1
Disk 0      MD0:        RAM Disk          256KB,LBA
Disk 1      MD1:        ROM Disk          --
Disk 2      HDSK0:      Hard Disk         1024MB,LBA
Disk 3      HDSK1:      Hard Disk         1024MB,LBA

RetroBrew SBC [SBC_simh_std] Boot Loader

Boot [H=Help]:
```

That is HBIOS initialising, verifying its own ROM, finding the console,
enumerating devices and handing off to the loader — 738 characters, every one
of them shifted out of the real UART a bit at a time.

## Doing it

The ROM image is not in this repository. It is large, it is not ours, and it
moves independently — the same reason the opcode suite lives outside the tree.
Point at one you already have:

```
make romwbw ROMWBW_ROM=path/to/SBC_simh_std.rom
```

That converts the first 64 KB with `tools/mkromhex.py` and runs
`sim/tb_romwbw.sv`. Allow a few minutes: the prompt is about 8.6 M clocks in,
and the run stops as soon as it sees it.

## The console has to be SSER

This is the part that is easy to get wrong, because the failure is silence
rather than an error.

The avwohl emulators put the console at ports 0x00 and 0x01 —
`romwbw_emu/src/hbios_cpu.cc` answers exactly there, with bit 0 for receive
ready and bit 1 for transmit — and `rtl/soc/uart.sv` was built to match. But a
*stock* RomWBW ROM does not drive that. `SBC_simh_std.rom` selects RomWBW's
**SSER** device, whose driver sits at ROM offset 0x1F3D and tests its status
with `E6 01` for receive and `E6 20` for transmit:

- **0x6D** — status. Bit 0 a byte is waiting, **bit 5** the transmitter is idle.
- **0x68** — data, read and write.

So the ready bits are in different places *and* the ports move. Build the SoC
with the emulator's ports and a stock ROM prints nothing at all: HBIOS polls
0x6D, gets 0xFF back from the unclaimed-port default in `z80_soc.sv`, reads
bit 0 as "a byte is waiting" forever, and never transmits.

`uart #(.CONSOLE_SSER(1))` selects it, and `z80_soc` passes the parameter
through. The two interfaces are deliberately exclusive rather than aliased:
HBIOS probes port 0x00 while hunting for hardware and counts a stable non-0xFF
answer as a device, so leaving the emulator ports decoded in a RomWBW build
invents a console that is not there.

The pleasant part is what SSER *does not* need. Its INITDEV at ROM offset
0x1F88 is `CD 1A 10 / 3E FE / B7 / C9` — it performs no port I/O whatsoever.
There is no chip to initialise and no register model to fake, which is why
this was five lines rather than a 16C550.

## What works, and what does not yet

The core needed no changes at all. It runs HBIOS as-is, including the bank
switching, and `docs/memory_banking.md`'s scheme is what HBIOS expects: the
image asks for 16 RAM banks and 16 ROM banks (offsets 0x10B and 0x10C), with
`BIDCOM` 0x8F, and the MMU already answers that when `RAM_BANKS = 16`.

What is missing is the rest of the ROM. The simulation loads only the first
64 KB — HBIOS in bank 0 and the loader in bank 1 — because that is what fits
in block RAM beside 512 KB of RAM. Banks 2 to 15 read as 0xFF, so the 384 KB
ROM disk the banner advertises is not really there and the loader's disk
commands will not find it. Reaching the prompt does not depend on it.

On hardware both halves fit, but not in the same place. 512 KB of ROM is 128
of the part's 135 RAMB36 tiles, which leaves nothing for the RAM, so the RAM
goes to DDR2. The ROM has to be the one in block RAM, because it is the only
one whose contents must exist before the first instruction fetch: DDR2 is
volatile and there is nothing to load it from at reset. RAM does not care,
since it starts undefined anyway.

DDR2 cannot answer in a T-state and does not pretend to. `rtl/mem/ddr2_ram.sv`
holds `wait_n` low until its AXI transaction finishes, and the core freezes
`tcnt` at the strobe T-state until it lets go. No cache is needed to be
correct; there is a one-line read cache anyway, because instruction fetch is
sequential and it turns sixteen DDR2 reads into one.

What is still missing is a disk. `HDSK0:`/`HDSK1:` are advertised but nothing
is behind them, so `C:` through `J:` are not real. The board has a microSD
slot and RomWBW knows how to use one; that is the next piece.
