## Digilent Arty A7-100T constraints for the z80fpga SoC.

set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk [get_ports CLK100MHZ]

## Buttons - btn[0] is the reset
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN B8  IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

## Slide switches
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]

## LEDs
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## USB-UART bridge
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## ---------------------------------------------------------------- multicycle
## The core runs on a clock enable, not a divided clock: every register in
## z80_core is gated by clk_en, which is high one cycle in CPU_DIV (12, set in
## top.sv).  So a core-to-core path has twelve periods to settle.  Say nothing
## and the tools try to close the 23-level path out of the microcode ROM in one
## 10 ns period, miss by 8.7 ns, and hand back a bitstream with 893 failing
## endpoints.  Keep these numbers in step with CPU_DIV -- too large and the
## tools stop checking something the hardware really does need.
##
## An XDC is Tcl, but a restricted dialect: `if`, `puts` and
## `remove_from_collection` are rejected with "not supported in the xdc
## constraint file", and the variable they were building then does not exist,
## so the exception silently never applies.  Everything below is therefore one
## get_cells per set, with the exclusions written into the filter.
##
## The filters are read once before synthesis and again for implementation, so
## they have to match at both stages.  IS_SEQUENTIAL does; REF_NAME =~ RAMB*
## does not, because the block RAM primitives do not exist until synthesis has
## mapped the memory -- that spelling costs four "No valid object(s) found"
## critical warnings and applies the exception to implementation only.  Mind
## the globs too: the RAM is inside a generate block, so its cells are named
## "u_soc/g_bram.u_ram/mem_reg_0_2", which contains no "/u_ram/" -- a */u_ram/*
## pattern matches nothing at all, for one ordinary warning and no error.

## The core, except nmi_q and nmi_pend, the only registers in it that update on
## every clock rather than on clk_en.
set core_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ */u_cpu/* && NAME !~ */nmi_q* && NAME !~ */nmi_pend*}]

set_multicycle_path 12 -setup -from $core_ff -to $core_ff
set_multicycle_path 11 -hold  -from $core_ff -to $core_ff

## The memory gets a tighter number, and it has to be shared.  sync_ram is
## instantiated with en = 1'b1, so the block RAM captures its address on every
## clock even though the core only changes it on a clk_en tick -- but the
## intermediate captures are discarded: the write enable is gated by clk_en, so
## no intermediate cycle writes, and the core samples rdata only when latch_now
## (also clk_en) says to.  The path may therefore take more than one clock.  It
## may not take all twelve: the RAM has a clock of read latency, and whatever
## is left of the twelve once the address arrives is all the time the read data
## gets to come back through the dispatch decode.  Six out and six back; give
## the address eleven and the return path is left with one cycle, which fails
## by 0.270 ns.  Each half needs about 12 ns of the 60 it now has.
set mem_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && (NAME =~ *u_ram/* || NAME =~ *u_rom/*)}]

set_multicycle_path 6 -setup -from $core_ff -to $mem_ff
set_multicycle_path 5 -hold  -from $core_ff -to $mem_ff

set_multicycle_path 6 -setup -from $mem_ff -to $core_ff
set_multicycle_path 5 -hold  -from $mem_ff -to $core_ff

## The peripherals take core data the same way: led, the MMU bank register and
## the UART transmit register are all written under port_wr, and z80_soc ANDs
## clk_en into port_wr before it leaves.  The UART's shift register also
## advances on its own baud divider every clock, but an exception is per path,
## not per register -- the paths that start in the core are relaxed and the
## baud-driven ones into the same flops stay single-cycle, which is what they
## need.
set soc_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && (NAME =~ *led_reg* || NAME =~ *u_mmu/* || NAME =~ *u_uart/*)}]

set_multicycle_path 12 -setup -from $core_ff -to $soc_ff
set_multicycle_path 11 -hold  -from $core_ff -to $soc_ff
