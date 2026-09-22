# yosys / nextpnr / gowin_pack build for the Sipeed Tang Nano 20K
# (Gowin GW2AR-LV18QN88C8/I7).  Tier (a): the core, a UART and sw/boot.z80 in
# block RAM.  No SDRAM, no microSD.
#   mingw32-make            -> z80fpga.fs
#   mingw32-make prog       -> load it into the FPGA (lost on power down)
#   mingw32-make flash      -> write it to the board's SPI flash
#   mingw32-make stat       -> the resource report only
#   mingw32-make timing     -> what nextpnr said about the clock
# Source ../../tools/ossenv.sh first, to get the OSS CAD Suite on PATH.
#
# FREQ is not decoration, and on this family the command line is the only
# place it can be written.  A .cst has no frequency syntax at all, and --sdc
# is worse than useless here: `create_clock ... [get_ports {clk}]` prints
#     Info: constraining clock net 'clk' to 27.00 MHz
# and then the design is still reported "(PASS at 12.00 MHz)", because the net
# it named is gone by the time timing runs -- packing renames the clock after
# whatever it ends up driving, and that name is never the port's.  This design
# reports `u_soc.clk`; a bare counter on the same pin reports `clk_IBUF_I_O`,
# so it is not a name to hard-code either.  Do NOT grep for the "constraining
# clock net" line the way the Icepi Makefile greps its ECP5 equivalent: here
# it is the grep that always passes.
# What has teeth is the target printed in the result itself.  Without --freq
# nextpnr times the design against its own 12 MHz default, says PASS and exits
# 0, and only the "at 27.00 MHz" in the second recipe line tells them apart.

# The recipes are POSIX shell, and mingw32-make would otherwise hand them to
# cmd.exe, where cp and grep do not exist.  Same reason as the root Makefile.
SHELL   := /bin/sh

ROOT    := ../..
TOP     := top
# Three tools, three spellings of one part.  nextpnr wants the full ordering
# code -- and the C8/I7 on the end is the speed grade, which it looks up and
# refuses if it does not know ("Speed grade 'C6/I5' not found in database"),
# so this number cannot quietly become optimistic.  gowin_pack and the chipdb
# want the family, and synth_gowin's -family is coarser still.  gowin_pack has
# to be given the family in particular: handed the ordering code it matches it
# down to "GW2A-18", which is a different database from the "GW2A-18C"
# nextpnr placed against, and it stops rather than guess.
DEVICE  := GW2AR-LV18QN88C8/I7
FAMILY  := GW2A-18C
SYNFAM  := gw2a
CST     := tang_nano_20k.cst
# The 27 MHz board oscillator runs the whole design, one T-state per clock:
# a 27 MHz Z80, and the fastest target in this tree.  That second half is
# top.sv's CPU_DIV = 1 talking rather than this file's -- move CPU_DIV and the
# Z80's rate moves with it, while FREQ stays where it is.  Routed, this design
# reports 41.3 to 41.5 MHz over two runs: 53% of margin, where the Icepi has
# 14% at its 25 MHz.  An integer, and it has to stay one -- the guard below
# spells the target "$(FREQ).00".
FREQ    := 27

SRC := $(ROOT)/rtl/core/z80_alu.sv \
       $(ROOT)/rtl/core/z80_core.sv \
       $(ROOT)/rtl/mem/sync_ram.sv \
       $(ROOT)/rtl/soc/z80_mmu.sv \
       $(ROOT)/rtl/soc/uart.sv \
       $(ROOT)/rtl/soc/z80_soc.sv \
       top.sv

MEMS := z80_ucode.mem z80_dispatch.mem boot.hex

all: z80fpga.fs

z80_ucode.mem: $(ROOT)/rtl/core/z80_ucode.mem
	cp $< $@
z80_dispatch.mem: $(ROOT)/rtl/core/z80_dispatch.mem
	cp $< $@

# 16 KB, and not the whole 32 KB bank the Icepi has room for, because 46
# blocks of 18 Kbit do not stretch to it.  Counted out of the netlist rather
# than reasoned about: the 64 KB of RAM is 32 blocks, the core's dispatch
# table is one more, and that leaves 13.  A 32 KB ROM wants 15 -- at that size
# yosys moves it into the 9-bit SPX9 mode, which uses all 18 Kbit of a block,
# about 2304 bytes each -- so it overshoots by two, and synthesis really does
# emit 48 block cells for a part that has 46.  At 16 KB the ROM stays in the
# same x1 mode the RAM uses, 2048 bytes a block, which is 8: 41 of 46 in all,
# and the ROM mirrors across the top half of the bank the way the C0-microSD's
# 8 KB does.  The monitor is 228 bytes, so this is already seventy times what
# it needs; if block RAM ever matters more than headroom, ROM_AW_P 13 and
# --size 8192 take four blocks back.
#
# --size has to agree with top.sv's ROM_AW_P, at 2**ROM_AW_P bytes exactly.
# Nothing will say so if they drift: a short image is not an error anywhere,
# $readmemh fills what it has and the tools zero the rest.
boot.hex: $(ROOT)/sw/boot.z80 $(ROOT)/tools/zasm.py
	python $(ROOT)/tools/zasm.py $< -o $@ --size 8192

z80fpga.json: $(SRC) $(MEMS)
	yosys -p "read_verilog -sv -I $(ROOT)/rtl/core $(SRC); \
	          synth_gowin -family $(SYNFAM) -top $(TOP) -json $@" -l yosys.log

# A missed timing target nextpnr reports itself, by exiting 1 -- do not grep
# the log for it, because the placement-stage estimate is printed as an Info
# line in runs that route perfectly well, and only the post-route one is
# raised to ERROR.  The failure it will not tell you about is the target
# never having been set: --freq is where it comes from on this family, and
# without it every clock is checked against 12 MHz and passes.  The presence
# of "at 27.00 MHz" in the result, not the absence of a warning, is the
# signal.
z80fpga_pnr.json: z80fpga.json $(CST)
	nextpnr-himbaechel --device $(DEVICE) --vopt family=$(FAMILY) \
	                   --vopt cst=$(CST) --json $< \
	                   --write $@ --freq $(FREQ) -l nextpnr.log
	@grep -q "PASS at $(FREQ).00 MHz)" nextpnr.log || { echo "no \"PASS at $(FREQ).00 MHz\" in nextpnr.log: either the target never applied or it did not close - see the log"; exit 1; }

# gowin_pack is apicula, and it complains on stderr that numpy, msgspec and
# fastcrc are missing.  Those are its optional accelerators; the bitstream is
# the same without them.  Not compressed: -c exists, but no board here has
# been proved to configure from a compressed .fs and 7 MB loads in a second.
z80fpga.fs: z80fpga_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

# One USB-C carries the bitstream and the console, as the Icepi's FT231X
# does.  Whether the console can stay open across a prog here has not been
# tried; assume it cannot until it has been.
# JTAG_FREQ is not decoration.  openFPGALoader defaults to 6 MHz on this
# cable, and this board's USB link has been intermittent -- enumerating,
# working, then vanishing with no Windows error logged at all.  A marginal
# FTDI link often holds at 1 MHz where it fails at 6, and nothing here is
# big enough for the slower clock to be worth noticing.  Raise it once the
# link has been proved over a few sessions.
JTAG_FREQ := 1000000

prog: z80fpga.fs
	openFPGALoader -b tangnano20k --freq $(JTAG_FREQ) $<

# `make ledchk` builds and loads the LED-reporting twin of sw/boot.z80's bank
# check.  This board's console has failed while JTAG stays perfectly healthy,
# and the LED port at 0xFF is the one output channel that still carries a
# number off the part: the three rightmost LEDs read as a 3-bit stage, lit =
# 1.  sw/ledchk.z80 says what each value means, and so does the README.
#
# It goes through a generated top rather than a parameter because $readmemh
# resolves against the Verilog source file, not the working directory, so the
# ROM's name has to be a literal in a file that sits in this directory.  The
# generated names all start "ledchk", so nothing here collides with the real
# build and `make` afterwards does not find a stale boot.hex.
ledchk.hex: $(ROOT)/sw/ledchk.z80 $(ROOT)/tools/zasm.py
	python $(ROOT)/tools/zasm.py $< -o $@ --size 8192

ledchk_top.sv: top.sv
	sed 's|"boot.hex"|"ledchk.hex"|' $< > $@

ledchk.fs: $(filter-out top.sv,$(SRC)) ledchk_top.sv ledchk.hex \
           z80_ucode.mem z80_dispatch.mem
	yosys -p "read_verilog -sv -I $(ROOT)/rtl/core \
	          $(filter-out top.sv,$(SRC)) ledchk_top.sv; \
	          synth_gowin -family $(SYNFAM) -top $(TOP) -json ledchk.json" \
	      -l ledchk_yosys.log
	nextpnr-himbaechel --device $(DEVICE) --vopt family=$(FAMILY) \
	                   --vopt cst=$(CST) --json ledchk.json \
	                   --write ledchk_pnr.json --freq $(FREQ) -l ledchk_pnr.log
	gowin_pack -d $(FAMILY) -o $@ ledchk_pnr.json

ledchk: ledchk.fs
	openFPGALoader -b tangnano20k --freq $(JTAG_FREQ) $<

# -f is --write-flash.  Without it openFPGALoader writes SRAM, which is the
# default and is gone at power down.  Plain -f is what this part wants: the
# GW2AR has no internal flash, so there is nothing for --external-flash to
# choose between.
flash: z80fpga.fs
	openFPGALoader -b tangnano20k --freq $(JTAG_FREQ) -f $<

# The device utilisation table, which is the one after packing.  The
# MUX2_LUT* rows are the slice muxes that pair LUT4s up, not more LUT4s --
# the MUX2_LUT5 row's denominator is exactly half the LUT4 row's -- so LUT4
# alone is the figure to set beside the other boards'.
stat: z80fpga_pnr.json
	@grep -A 34 "Device utilisation" nextpnr.log | 	 grep -E "Device utilisation|IOB:|LUT4:|MUX2_LUT|ALU:|DFF:|RAM16SDP4:|BSRAM:|BUFG:|rPLL:"

# Two lines: the placement-stage estimate and the post-route result.  The
# second is the one that counts, and the "at 27.00 MHz" on the end of both is
# the proof the target applied at all.
timing: z80fpga_pnr.json
	@grep -E "Max frequency|Max delay" nextpnr.log

clean:
	rm -f z80fpga.json z80fpga_pnr.json z80fpga.fs *.log $(MEMS)
	rm -f ledchk.json ledchk_pnr.json ledchk.fs ledchk.hex ledchk_top.sv

# nextpnr writes the post-route netlist even when timing fails, and then exits
# 1.  Without this, the next make would find a newer _pnr.json than .json,
# skip nextpnr entirely, and pack the failing placement into a bitstream
# without a word.
.DELETE_ON_ERROR:

.PHONY: all prog flash ledchk stat timing clean