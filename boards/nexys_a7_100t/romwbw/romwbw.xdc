## Nexys A7-100T constraints for the RomWBW build.
## DDR2 pins come from the MIG's own generated constraints, not from here.

set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk [get_ports CLK100MHZ]

set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports CPU_RESETN]

set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

set_property -dict {PACKAGE_PIN D4  IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN C4  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]
## Flow control.  Measured, not assumed: D3 read 1 undriven so it is ours to
## drive, E5 read 0 driven by the bridge so it is an input here.
set_property -dict {PACKAGE_PIN E5  IOSTANDARD LVCMOS33} [get_ports uart_rts]
set_property -dict {PACKAGE_PIN D3  IOSTANDARD LVCMOS33} [get_ports uart_cts]

## microSD
set_property -dict {PACKAGE_PIN E2  IOSTANDARD LVCMOS33} [get_ports sd_reset]
set_property -dict {PACKAGE_PIN A1  IOSTANDARD LVCMOS33} [get_ports sd_cd]
set_property -dict {PACKAGE_PIN B1  IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN C1  IOSTANDARD LVCMOS33} [get_ports sd_cmd]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33} [get_ports {sd_dat[0]}]
set_property -dict {PACKAGE_PIN E1  IOSTANDARD LVCMOS33} [get_ports {sd_dat[1]}]
set_property -dict {PACKAGE_PIN F1  IOSTANDARD LVCMOS33} [get_ports {sd_dat[2]}]
set_property -dict {PACKAGE_PIN D2  IOSTANDARD LVCMOS33} [get_ports {sd_dat[3]}]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## See boards/nexys_a7_100t/ddr2/README.md: the MIG asks for BACKBONE routing
## on whatever drives sys_clk_i, which assumes the raw pin, and the 200 MHz
## IODELAY reference forces an MMCM into the path instead.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -quiet u_clk/inst/clk_out2]

## ---------------------------------------------------------------- multicycle
## Same reasoning as the block RAM build -- see
## boards/nexys_a7_100t/../arty_a7_100t/README.md -- and the same numbers,
## because CPU_DIV is still 12.  What changed is the memory: the ROM is still
## block RAM and keeps the split six-out-six-back budget, while the RAM is now
## in DDR2 behind ddr2_ram, which runs at the full clock rather than on clk_en
## and holds wait_n instead.  Those paths are deliberately left single-cycle:
## ddr2_ram latches the address when it starts a transaction, not on a clk_en
## tick, so the clock-enable argument for relaxing them does not apply.
set core_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ */u_cpu/* && NAME !~ */nmi_q* && NAME !~ */nmi_pend*}]

set_multicycle_path 12 -setup -from $core_ff -to $core_ff
set_multicycle_path 11 -hold  -from $core_ff -to $core_ff

set rom_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ *u_rom/*}]

set_multicycle_path 6 -setup -from $core_ff -to $rom_ff
set_multicycle_path 5 -hold  -from $core_ff -to $rom_ff
set_multicycle_path 6 -setup -from $rom_ff  -to $core_ff
set_multicycle_path 5 -hold  -from $rom_ff  -to $core_ff

## u_hdsk is in here for the same reason as the UART: its port strobes are
## ANDed with clk_en in z80_soc, so a path from the core into it is launched
## and captured on enable ticks.  Left out, the core's microcode PC reaching
## the HDSK state machine is seventeen levels against 12.3 ns and misses by
## 0.8 ns.  u_sd is deliberately NOT here -- it free-runs on the SPI divider
## and takes nothing directly from the core.
set soc_ff [get_cells -quiet -hier -filter {IS_SEQUENTIAL && (NAME =~ *led_reg* || NAME =~ *u_mmu/* || NAME =~ *u_uart/* || NAME =~ *u_hdsk/*)}]

set_multicycle_path 12 -setup -from $core_ff -to $soc_ff
set_multicycle_path 11 -hold  -from $core_ff -to $soc_ff

## The Z80 also talks to the MIG, and that crossing needs saying too.  The
## write data and the address reach the AXI port combinationally out of core
## registers -- ddr2_ram drives them straight from `dout` and `addr` -- and
## that is an eighteen-level path which does not make 12.3 ns:
##
##   u_cpu/upc_reg[5] -> u_mig/.../u_ui_top/ui_wr_data0/write_buffer...
##   Requirement 12.308ns, Data Path Delay 12.945ns
##
## Two cycles is the honest number, and it is provable rather than hopeful.
## ddr2_ram registers awvalid, so the MIG cannot see a request until the clock
## after the core presented it, and cannot sample the address or data before
## awready the cycle after that.  Meanwhile the core is stalled on wait_n and
## is not going to change anything.  Two, not twelve: the launch here is the
## clk_en edge but the capture is not, so the clock-enable argument that gives
## the core-to-core paths twelve does not apply.
set mig_axi [get_cells -quiet -hier -filter {NAME =~ *u_memc_ui_top_axi/*}]

set_multicycle_path 2 -setup -from $core_ff -to $mig_axi
set_multicycle_path 1 -hold  -from $core_ff -to $mig_axi
