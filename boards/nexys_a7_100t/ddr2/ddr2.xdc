## Nexys A7-100T constraints for the DDR2 bring-up test.
## The DDR2 pins themselves are NOT here: the MIG generates its own
## constraints from mig.prj, and duplicating them would fight with it.

set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk [get_ports CLK100MHZ]

set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports CPU_RESETN]

set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

set_property -dict {PACKAGE_PIN D4  IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN C4  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## The MIG's own constraints carry
##     set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk_i]
## which assumes its system clock arrives straight from the clock pin -- its
## XDC even assigns E3 and LVCMOS25 to a port called sys_clk_i, which this
## design does not have.  There is only one oscillator on the board and the
## IODELAY reference has to be 200 MHz, so the MMCM has to be in the path and
## the system clock comes off it too.  That constraint then lands on the MMCM
## output and cannot be met: "1 net(s) have CLOCK_DEDICATED_ROUTE set to
## BACKBONE but do not use backbone resources".  Relax it for that one net.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -quiet u_clk/inst/clk_out2]
