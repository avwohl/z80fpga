# yosys / nextpnr / ecppack build for the Icepi Zero (ECP5 LFE5U-25F).
#   mingw32-make            -> z80fpga.bit
#   mingw32-make prog       -> load it into the FPGA (lost on power down)
#   mingw32-make flash      -> write it to the board's SPI flash
#   mingw32-make stat       -> the resource report only
#   mingw32-make timing     -> what nextpnr said about the clock
# Source ../../tools/ossenv.sh first, to get the OSS CAD Suite on PATH.
#
# FREQ is not decoration.  nextpnr does not know that clk_sys is half of clk,
# and an unconstrained clock is not checked at all; the .lpf says so too, and
# whichever gets there first, "constraining clock net 'clk_sys'" in the log is
# the only proof the constraint applied.

# The recipes are POSIX shell, and mingw32-make would otherwise hand them to
# cmd.exe, where cp and grep do not exist.  Same reason as the root Makefile.
SHELL   := /bin/sh

ROOT    := ../..
TOP     := top
DEVICE  := 25k
PACKAGE := CABGA256
# The board carries an LFE5U-25F-6BG256C.  Grade 6 is also nextpnr's default,
# but saying it means the timing report cannot quietly become optimistic.
SPEED   := 6
LPF     := icepi_zero.lpf
FREQ    := 25

SRC := $(ROOT)/rtl/core/z80_alu.sv \
       $(ROOT)/rtl/core/z80_core.sv \
       $(ROOT)/rtl/mem/sync_ram.sv \
       $(ROOT)/rtl/soc/z80_mmu.sv \
       $(ROOT)/rtl/soc/uart.sv \
       $(ROOT)/rtl/soc/z80_soc.sv \
       top.sv

MEMS := z80_ucode.mem z80_dispatch.mem boot.hex

all: z80fpga.bit

z80_ucode.mem: $(ROOT)/rtl/core/z80_ucode.mem
	cp $< $@
z80_dispatch.mem: $(ROOT)/rtl/core/z80_dispatch.mem
	cp $< $@

# A whole 32 KB ROM bank: this part has the block RAM for it, unlike the UP5K.
boot.hex: $(ROOT)/sw/boot.z80
	python $(ROOT)/tools/zasm.py $< -o $@ --size 32768

z80fpga.json: $(SRC) $(MEMS)
	yosys -p "read_verilog -sv -I $(ROOT)/rtl/core $(SRC); \
	          synth_ecp5 -top $(TOP) -json $@" -l yosys.log

# A missed timing target nextpnr reports itself, by exiting 1 -- do not grep
# the log for it, because the placement-stage estimate says "FAIL" in runs that
# route perfectly well.  A constraint that never applied is the one it will not
# tell you about: an unimplemented .lpf line is dropped in silence, and the
# design is then placed with no target at all.  Absence of the line the second
# recipe line looks for, not the presence of a warning, is the signal.
z80fpga.config: z80fpga.json $(LPF)
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
	             --lpf $(LPF) --json $< \
	             --textcfg $@ --freq $(FREQ) -l nextpnr.log
	@grep -q "constraining clock net 'clk_sys'" nextpnr.log || { echo "the clk_sys constraint never applied - see nextpnr.log"; exit 1; }

z80fpga.bit: z80fpga.config
	ecppack --compress $< $@

prog: z80fpga.bit
	openFPGALoader -b icepi-zero $<

flash: z80fpga.bit
	openFPGALoader -b icepi-zero $< --write-flash

# The device utilisation table, which is the one after packing.  nextpnr also
# prints a "Total LUT4s" line, but that is "Logic utilisation before packing"
# and it is a smaller number -- quoting it next to the rest of the table would
# be flattering by a couple of hundred LUTs.
stat: z80fpga.config
	@grep -A 28 "Device utilisation" nextpnr.log | 	 grep -E "Device utilisation|TRELLIS_COMB|TRELLIS_FF|DP16KD|TRELLIS_IO|DCCA|SIOLOGIC"

timing: z80fpga.config
	@grep -E "constraining clock net|Max frequency|Max delay" nextpnr.log

clean:
	rm -f z80fpga.json z80fpga.config z80fpga.bit *.log $(MEMS)

# nextpnr writes the textcfg even when timing fails, and then exits 1.  Without
# this, the next make would find a newer .config than .json, skip nextpnr
# entirely, and pack the failing placement into a bitstream without a word.
.DELETE_ON_ERROR:

.PHONY: all prog flash stat timing clean
