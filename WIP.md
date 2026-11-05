# Next on Windows, 2026-11-05: the debug unit over JTAG on the Nexys A7

Written on the Mac for the Windows session. Delete this section when the
board check passes.

The debug unit has a JTAG link now (bf783ef, `docs/debug_unit.md`, JTAG
link). Everything that runs without Vivado passes on the Mac: `make test`,
`make test-debug` (the bridge test is 506 checks over the UART and the JTAG
cosim), `make lint`, and a read-only IDCODE over JTAG on the board. Nothing
has run on the board with the link, because only Vivado builds the bitstream.

On the Windows machine:

1. `git pull`, then build with the link:
   `cd boards/nexys_a7_100t/romwbw`, `set Z80_DEBUG_UNIT=1`,
   `vivado -mode batch -source build_romwbw.tcl`. The default link is JTAG
   (`Z80_DEBUG_LINK=jtag`).
2. Read the log: no DRC error, no `REQP-1962`, timing met. Read
   `report_cdc`, and the hold paths of `jtag_tck` from the BSCANE2 outputs
   (`docs/debug_unit.md`, What is not measured). `romwbw_dbg_jtag.xdc` has
   never been read by Vivado, so its net and pin names can be wrong.
3. Program the bitstream (Vivado's hardware manager), then close the hardware
   manager: one program at a time holds JTAG channel A.
4. `pip install ftd2xx`, then `python tools/z80dbg_jtag.py --check --backend d2xx`.
   Right: IDCODE 0x13631093, and a USER3 scan that is not a 1-bit bypass.
   The d2xx back end has never touched a device.
5. `python tools/z80dbg_bridge.py --jtag --jtag-backend d2xx --listen 1234`,
   then GDB or udb80 as `MANUAL_CHECKS.md` says (Debug unit on the Nexys
   A7-100T, items 6 to 12; no adapter now). GDB needs the Z80 target, and
   udb80 needs um80 0.4.2 or later.
6. Copy `build/romwbw_soc.bit` to the Mac too: there `openFPGALoader -b
   nexys_a7_100 romwbw_soc.bit` loads it, and `--jtag` uses the pyftdi back end
   (`docs/macos.md`).

# Work in progress, 2026-09-23

Written to survive a reboot. Delete it when the open item below is closed.

## Where things stand

**Three boards run on hardware now**, up from one this morning:

- **Nexys A7-100T** — unchanged, still boots RomWBW and CP/M 2.2.
- **Tang Nano 20K** — fixed. It had been printing only its banner for a long
  time, and the fault was in this repository after all: `z80_soc.sv` picked
  between the ROM's and the RAM's read data with a select taken off the *live*
  address, while the data behind it came out of registered memories a clock
  later. On an M1 cycle the refresh address arrives at exactly the edge the
  instruction is latched, so the mux switched under the fetch. It broke
  instruction fetch out of the common bank and nothing else, which is why
  every other test passed. Registering the select fixed it.
- **Icepi Zero v1.3** — new. Base build and `sdram/` build both pass the bank
  check; base build has a working console at 25 MHz. `romwbw/` is the open
  item.

`make test` 0/32080 and `make test-full` 0/1604000. Nexys RomWBW, Arty,
icepi base/sdram/romwbw and c0_microsd all rebuilt and closing timing.

## The one open question

**The Icepi's microSD will not initialise.** With a card in the slot,
`rom_done` and `rom_failed` are both low, which `rom_loader.sv`'s own header
calls a card that never raised ready -- `sd_spi` is stuck in initialisation.
The lamps can say that much and no more.

What is known:

- A **16 GB SDHC** card, blank, *did* stage once: `led[3]` alone, meaning
  1024 blocks read and the Z80 released. So the wiring and `sd_spi` are not
  hopeless.
- A **128 GB SDXC** card never came up.
- The same 16 GB card, after being imaged on a PC and put back, does not come
  up either. Whether that is the card, the seating or something else is not
  established.
- The RomWBW image on it is correct: 524288 bytes at LBA 4194304, verified by
  reading it back off the card, and byte-identical (same sha256) to the image
  the Nexys boots.
- **In simulation the whole path works**: `make test-romwbw512
  ROMWBW_ROM=sim/SBC_simh_std.rom` stages 1024 blocks off a card model into
  SDRAM, finds them byte-perfect, and boots `RomWBW HBIOS v3.5.1`. So the
  loader, the staging and running RomWBW out of SDRAM are all sound. That run
  takes hours of wall clock; an earlier attempt waited 128 ms, saw nothing and
  read it as a loader bug, and was wrong by about 28 ms.

**Next step, already built and waiting:** `boards/icepi_zero/romwbw/sdtest.bit`
(28.25 MHz, PASS at 25.00). It runs `sim/hdsk_test.z80` from block RAM so the
CPU is not gated on the card, and prints what the card said over the console.
HDSK's debug port is 0xFC and its `status2` reads `E0 + sd_spi`'s state, so a
stuck initialisation names its own step. No lamp-reading.

To use it: Zadig the FT231X to WinUSB, `cd boards/icepi_zero/romwbw &&
mingw32-make sdtest`, put the FTDI driver back (see below), then read COM9.

## Board and host state at reboot

- Icepi Zero on USB, FT231X bound to **FTDIBUS**, console on **COM9**.
- Its SPI flash holds the **RomWBW** build. The ROM comes off the card, so
  changing the card needs no reflash.
- The 16 GB card is **out of the slot** as of the last exchange.
- Tang Nano 20K is not attached.

## Procedures worth not rediscovering

**The driver dance.** The FT231X is single-channel, so the programmer and the
console cannot both be bound. Going *to* WinUSB needs Zadig -- Options, List
All Devices, pick USB ID `0403 6015`, replace with WinUSB -- because
`pnputil /add-driver <oem>.inf /install` will not rebind against FTDI's
higher-ranked signed package and pnputil has no force. Coming *back* is
scriptable and needs no GUI:

```
pnputil /remove-device "USB\VID_0403&PID_6015\DK0GFG9S"
pnputil /scan-devices
```

Run those from PowerShell, not Git Bash, which mangles `/switches` into paths
and eats the `&`.

**Resetting without touching the board.** All three Icepi tops reset on a DTR
edge (`usb_dtrn`, L15). Open COM9, set `DtrEnable` true for ~150 ms, then
false, and the board reboots from flash and prints its banner. Both physical
buttons are on the underside and unreachable in a remote session; this is why
that exists. `tools/console.ps1` asserts DTR on open, so opening the console
reboots the machine deliberately.

**Which USB-C.** Use the one **nearest the HDMI** -- J5, the only socket
wired to the FT231X. J3 and J4 go straight to ECP5 balls. All three carry
+5V, so a board on the wrong socket lights up and is unreachable.

**Writing a card on Windows.** `dd` is not it: raw writes inside a mounted
volume are refused and removable media will not go offline. Lock and dismount
the volume, hold the handle for the write, release it after -- and read the
image back off the card rather than trusting the write.

**Reading the Icepi's lamps.** D1..D5 are `led[0]`..`led[4]` in board order,
at the end away from the HDMI, and lit is 1. `sd_det` is **high when a card is
present**; the lamp used to show `~sd_det` and read "no card" with a card in,
which cost a diagnosis.

## Decision left open

Whether to build a **USB CDC console on J3**, so the console stops competing
with the programmer. Measured headroom says it fits: logic is 25-30% used with
~17,000 LUT4s free against ~1-1.5k for a USB 1.1 device core, both PLLs are
unused for the 48 MHz clock, and `usb_dp[0]` F15 / `usb_dn[0]` E16 plus the
pull-up control G15/H14 are unclaimed -- the board wires that pull-up control
precisely so the FPGA can be a device. Block RAM is the only tight spot, and
only on the base build (48 of 56); `romwbw/` uses 3.

Cost is about a day: a second clock domain with CDC to the 25 MHz SoC, a
third-party core to import, and a USB enumeration to debug blind. Payoff is
one last Zadig run and then never again.
