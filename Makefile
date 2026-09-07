# z80fpga - top-level tasks.  Put the OSS CAD Suite on PATH first:
#     source tools/ossenv.sh
#
#   make gen        regenerate the microcode and dispatch ROMs
#   make sim        build the simulation binaries
#   make test       assembler, interrupts, SoC boot, and an opcode sweep
#   make test-full  the whole SingleStepTests suite, 1000 tests per opcode
#   make boot       assemble sw/boot.z80
#   make lint       Verilator lint over the core and the SoC
#   make synth      iCE40 resource report for the core alone

# The recipes are POSIX shell, and on Windows mingw32-make would otherwise
# hand them to cmd.exe - where Verilator's wrapper cannot find its own root.
SHELL   := /bin/sh

PYTHON  ?= python
IVERILOG ?= iverilog
VVP     ?= vvp
YOSYS   ?= yosys
# Verilator's wrapper locates its own headers from argv[0], so it has to be
# called by its full path.
VERILATOR ?= $(shell command -v verilator 2>/dev/null || echo verilator)

CORE := rtl/core/z80_alu.sv rtl/core/z80_core.sv
SOC  := $(CORE) rtl/mem/sync_ram.sv rtl/soc/z80_mmu.sv rtl/soc/uart.sv \
        rtl/soc/z80_soc.sv
GEN  := rtl/core/z80_defs.svh rtl/core/z80_ucode.mem rtl/core/z80_dispatch.mem

all: sim

gen $(GEN): tools/gen_z80.py tools/z80_enc.py
	$(PYTHON) tools/gen_z80.py

boot sw/boot.hex: sw/boot.z80
	$(PYTHON) tools/zasm.py sw/boot.z80 -o sw/boot.hex --size 32768

sim: sim/tb_sst.vvp sim/tb_soc.vvp sim/tb_irq.vvp sim/tb_ddr2ram.vvp \
     sim/tb_sdram.vvp sim/tb_sdram_soc.vvp sim/tb_romload.vvp \
     sim/tb_hdsk.vvp sim/tb_hdsk_soc.vvp

sim/tb_sst.vvp: sim/tb_sst.sv $(CORE) $(GEN)
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_sst.sv $(CORE)

sim/tb_soc.vvp: sim/tb_soc.sv $(SOC) $(GEN) sw/boot.hex
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_soc.sv $(SOC)

sim/tb_irq.vvp: sim/tb_irq.sv $(CORE) $(GEN)
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_irq.sv $(CORE)

# The SoC with its RAM in DDR2: wait states and the AXI handshakes, against a
# behavioural slave with deliberately awkward latency.
sim/tb_ddr2ram.vvp: sim/tb_ddr2ram.sv $(SOC) rtl/mem/ddr2_ram.sv $(GEN) sw/boot.hex
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_ddr2ram.sv $(SOC) rtl/mem/ddr2_ram.sv

# The SDRAM controller against a behavioural MT48LC16M16 that refuses anything
# the chip would not accept, and then the whole SoC with its RAM behind it.
sim/tb_sdram.vvp: sim/tb_sdram.sv sim/sdram_model.sv rtl/mem/sdram_ram.sv
	$(IVERILOG) -g2012 -o $@ sim/tb_sdram.sv sim/sdram_model.sv rtl/mem/sdram_ram.sv

sim/tb_sdram_soc.vvp: sim/tb_sdram_soc.sv sim/sdram_model.sv $(SOC) rtl/mem/sdram_ram.sv $(GEN) sw/boot.hex
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_sdram_soc.sv $(SOC) \
	    rtl/mem/sdram_ram.sv sim/sdram_model.sv

# A ROM image staged off a card into SDRAM and then executed out of it.  Four
# blocks rather than the 1024 a RomWBW image needs: enough to prove the
# sequencing, short enough to simulate, and the monitor is in the first one.
sim/boot2k.hex: sw/boot.z80
	$(PYTHON) tools/zasm.py sw/boot.z80 -o $@ --size 2048

ROMLOAD := rtl/mem/sdram_ram.sv rtl/soc/rom_loader.sv rtl/soc/sd_spi.sv \
           rtl/soc/hdsk.sv sim/sdram_model.sv sim/sd_card.sv

sim/tb_romload.vvp: sim/tb_romload.sv $(ROMLOAD) $(SOC) $(GEN) sim/boot2k.hex
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_romload.sv $(SOC) $(ROMLOAD)

# Boot a stock RomWBW ROM.  The image is not in the repository; ROMWBW_ROM
# points at one, the way Z80_TESTS points at the opcode suite:
#
#   make romwbw ROMWBW_ROM=path/to/SBC_simh_std.rom
#
# Takes a few minutes: the loader prompt is about 8.6 M clocks in.
ROMWBW_ROM ?=

sim/romwbw64k.hex:
	@test -n "$(ROMWBW_ROM)" || 	  (echo "set ROMWBW_ROM=path/to/a/RomWBW .rom image" && false)
	$(PYTHON) tools/mkromhex.py $(ROMWBW_ROM) $@ --size 65536

sim/tb_romwbw.vvp: sim/tb_romwbw.sv $(SOC) $(GEN)
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_romwbw.sv $(SOC)

# The SIMH HDSK controller and the SD block layer against a behavioural card.
sim/tb_hdsk.vvp: sim/tb_hdsk.sv rtl/soc/hdsk.sv rtl/soc/sd_spi.sv
	$(IVERILOG) -g2012 -o $@ sim/tb_hdsk.sv rtl/soc/hdsk.sv rtl/soc/sd_spi.sv

# The whole SoC driving HDSK from a real Z80: OTIR, the MMU translating the
# DMA address, and the memory behind it, none of which tb_hdsk can reach.
sim/hdsk_test.hex: sim/hdsk_test.z80
	$(PYTHON) tools/zasm.py sim/hdsk_test.z80 -o $@ --size 32768

sim/tb_hdsk_soc.vvp: sim/tb_hdsk_soc.sv $(SOC) rtl/mem/ddr2_ram.sv rtl/soc/sd_spi.sv rtl/soc/hdsk.sv $(GEN) sim/hdsk_test.hex
	$(IVERILOG) -g2012 -I rtl/core -o $@ sim/tb_hdsk_soc.sv $(SOC) rtl/mem/ddr2_ram.sv rtl/soc/sd_spi.sv rtl/soc/hdsk.sv

romwbw: sim/tb_romwbw.vvp sim/romwbw64k.hex
	$(VVP) sim/tb_romwbw.vvp

test: sim
	$(PYTHON) tools/test_zasm.py
	$(VVP) sim/tb_irq.vvp
	$(VVP) sim/tb_soc.vvp
	$(VVP) sim/tb_ddr2ram.vvp
	$(VVP) sim/tb_sdram.vvp
	$(VVP) sim/tb_sdram_soc.vvp
	$(VVP) sim/tb_romload.vvp
	$(VVP) sim/tb_hdsk.vvp
	$(VVP) sim/tb_hdsk_soc.vvp
	$(PYTHON) tools/run_sst.py --all -n 20 --cycles

test-full: sim
	$(PYTHON) tools/run_sst.py --all --cycles --chunk 40

# MULTIDRIVEN is a false positive here: Verilator counts each task that does a
# non-blocking assignment as its own process, and every one of them is called
# from the single always_ff in z80_core.sv.
lint: $(GEN)
	verilator --lint-only -Wall +incdir+rtl/core --top-module z80_soc 	    -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-MULTIDRIVEN 	    $(SOC)

synth: $(GEN)
	$(YOSYS) -p "read_verilog -sv -I rtl/core $(CORE); \
	             synth_ice40 -top z80_core; stat"

clean:
	rm -f sim/*.vvp sim/vec.txt sim/res.txt

.PHONY: all gen boot sim test test-full lint synth clean
