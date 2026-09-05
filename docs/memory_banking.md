# Banked memory

The bank scheme is the one the RomWBW SBC/MBC boards implement and
[avwohl/romwbw_emu](https://github.com/avwohl/romwbw_emu) emulates, so a ROM
image built for those boots here unchanged. `rtl/soc/z80_mmu.sv` is the whole
of it.

## The map

- **32 KB banks.** Bit 7 of the bank id picks the space: `0x00`–`0x0F` are ROM
  banks, `0x80`–`0x8F` are RAM banks.
- **The CPU's low 32 KB** (`0000`–`7FFF`) shows the selected bank.
- **The high 32 KB** (`8000`–`FFFF`) always shows the *common bank*, the
  highest RAM bank — `0x8F` on a full sixteen-bank build.
- **After reset** the low window shows ROM bank 0, which is where the CPU
  starts.

## Selecting a bank

```
OUT (78h),A     ; select the bank in A
OUT (7Ch),A     ; the same register
IN  A,(78h)     ; read back the current selection
```

Both ports write the same register. RomWBW uses `0x78` for RAM banks and
`0x7C` for ROM banks by convention, and the hardware does not care which.

## Writing code that switches banks

Selecting a RAM bank swaps the low 32 KB out from under the program counter.
Anything that switches banks has to already be running above `8000h`, in the
common bank, and it cannot call back into a ROM routine while a RAM bank is
selected.

`sw/boot.z80` does this the usual way: it copies its bank-check routine into
the common bank and calls it there, and the routine does its own port I/O
rather than using the ROM's `putc`. The stack lives at `FFF0h`, also in the
common bank, so it survives the switch.

## Sizing it for a part

`ROM_BANKS` and `RAM_BANKS` set how many banks exist; `COMMON_BANK` defaults
to the highest RAM bank, so it is `0x8F` only when `RAM_BANKS` is 16. A bank
id outside the configured range reads back `FF` and swallows writes.

`ROM_AW_P` and `RAM_AW_P` size the backing store independently, for parts
whose memory is smaller than the bank map implies — the C0-microSD's 8 KB boot
ROM mirrors across the whole of ROM bank 0 that way.

`USE_SPRAM` puts the RAM in an iCE40 UltraPlus's four SPRAM blocks
(`rtl/mem/spram_ice40.sv`), which is 128 KB, exactly four banks. That part's
block RAM cannot hold even one bank, so on a UP5K it is SPRAM or nothing.

| target | ROM | RAM | common bank |
|---|---|---|---|
| simulation (`sim/tb_soc.sv`) | 1 bank, 32 KB | 2 banks, 64 KB | `0x81` |
| Arty A7-100T | 2 banks, 64 KB | 8 banks, 256 KB | `0x87` |
| C0-microSD | 8 KB, mirrored | 4 banks, 128 KB SPRAM | `0x83` |

A build with `RAM_BANKS = 16` also fits the Arty's block RAM, at around 95% of
it, and is the configuration that gives the RomWBW common-bank id. The full
512 KB + 512 KB map does not fit in block RAM on any of these parts and wants
the Arty's DDR3 — see [roadmap.md](roadmap.md).

## What is not implemented

The emulator's `0xEC` (inter-bank copy) and `0xED` (bank call) ports are
emulator conveniences with no hardware counterpart, and are not here. RomWBW
code that uses them expects `emu_*` firmware; real SBC/MBC ROMs do not.
