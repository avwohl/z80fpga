## The debug unit's JTAG link (rtl/soc/dbg_jtag_link.sv).  Used only when
## build_romwbw.tcl runs with Z80_DEBUG_UNIT=1 and Z80_DEBUG_LINK is jtag or
## unset; Z80_DEBUG_LINK=uart reads romwbw_dbg.xdc instead.
##
## There are no pins to place: BSCANE2 is the FPGA's own TAP, on the
## configuration JTAG pins that the programming cable already uses.  What the
## link needs is timing.
##
## NO VIVADO HAS RUN THIS FILE.  The names below are written from the
## documentation of BSCANE2 and from how the Vivado debug hub constrains its
## own BSCANE2, and are unchecked.  After the first build read the log for
## "No valid object(s) found" from either command, and read the timing report
## for jtag_tck.

## TCK is an output of the BSCANE2 primitive, and Vivado does not know its
## rate.  The host runs it at 6 MHz by default and at most 30 MHz; 33.333 ns is
## the 30 MHz bound.  The clock then goes through the BUFG in
## dbg_bscan_xilinx.sv to the link's TCK-domain flip-flops.
create_clock -period 33.333 -name jtag_tck \
    [get_pins -hierarchical -filter {NAME =~ *u_dbg_bscan/u_bscan/TCK}]

## TCK and the unit's clock (ui_clk, 81.25 MHz) are asynchronous.  Every path
## between them is a toggle handshake through two flip-flops in
## dbg_jtag_link.sv, or a data byte that the handshake holds still while the
## other side reads it, so none of them is timed.
set_clock_groups -asynchronous \
    -group [get_clocks jtag_tck] \
    -group [get_clocks -of_objects [get_nets ui_clk]]
