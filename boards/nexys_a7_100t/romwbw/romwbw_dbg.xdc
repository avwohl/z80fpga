## The debug unit's serial line, on Pmod JA.  Used only when build_romwbw.tcl
## runs with Z80_DEBUG_UNIT=1; the default build does not read this file.
##
## Wire a 3.3 V USB-serial adapter to the JA header: the adapter's TX to JA1
## (pin 1, dbg_rx), the adapter's RX to JA2 (pin 2, dbg_tx), the adapter's GND
## to JA pin 5.  Not 5 V: the Artix-7 pins here are LVCMOS33.
##
## C17 and D18 are JA1 and JA2 as Digilent's Nexys A7-100T master constraints
## file lists them.  Check them against the board's reference manual before the
## first run: this file was written without the board in reach.
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports dbg_rx]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports dbg_tx]

## dbg_rx is asynchronous and goes through a two-flip-flop synchroniser in
## rtl/soc/dbg_uart.sv; nothing times a path from the pin.
set_false_path -from [get_ports dbg_rx]
