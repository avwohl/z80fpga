# yosys / nextpnr build for the Signaloid C0-microSD.
#   mingw32-make            -> z80fpga.bin
#   mingw32-make stat       -> the resource report only
# Source ../../tools/ossenv.sh first, to get the OSS CAD Suite on PATH.

ROOT    := ../..
TOP     := top
DEVICE  := up5k
PACKAGE := uwg30
PCF     := c0_microsd.pcf

SRC := $(ROOT)/rtl/core/z80_alu.sv \
       $(ROOT)/rtl/core/z80_core.sv \
       $(ROOT)/rtl/mem/sync_ram.sv \
       $(ROOT)/rtl/mem/spram_ice40.sv \
       $(ROOT)/rtl/soc/z80_mmu.sv \
       $(ROOT)/rtl/soc/uart.sv \
       $(ROOT)/rtl/soc/z80_soc.sv \
       top.sv

MEMS := z80_ucode.mem z80_dispatch.mem boot.hex

all: z80fpga.bin

z80_ucode.mem: $(ROOT)/rtl/core/z80_ucode.mem
	cp $< $@
z80_dispatch.mem: $(ROOT)/rtl/core/z80_dispatch.mem
	cp $< $@

# 8 KB here, not 32 KB: this board's ROM bank is backed by block RAM
boot.hex: $(ROOT)/sw/boot.z80
	python $(ROOT)/tools/zasm.py $< -o $@ --size 8192

z80fpga.json: $(SRC) $(MEMS)
	yosys -p "read_verilog -sv -I $(ROOT)/rtl/core $(SRC); \
	          synth_ice40 -top $(TOP) -json $@" -l yosys.log

z80fpga.asc: z80fpga.json $(PCF)
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --json $< --pcf $(PCF) \
	              --asc $@ --freq 6 -l nextpnr.log

z80fpga.bin: z80fpga.asc
	icepack $< $@

stat: z80fpga.json
	@grep -A 25 "Printing statistics" yosys.log | tail -24

clean:
	rm -f z80fpga.json z80fpga.asc z80fpga.bin *.log $(MEMS)

.PHONY: all stat clean
