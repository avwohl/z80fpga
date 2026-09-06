# Vivado build for the Nexys A7-100T DDR2 bring-up test.
#   cd boards/nexys_a7_100t/ddr2 && vivado -mode batch -source build_ddr2.tcl
# Writes build/ddr2_test.bit.
#
# This one uses a project on disk rather than the in-memory flow the SoC build
# uses, because the MIG has to be generated and synthesised as IP first.
#
# mig.prj is Digilent's, from their vivado-boards repository (MIT licensed),
# and carries the DDR2 part, the timing and all fifty pin assignments.  It is
# committed here on purpose: with it the build needs no board-files install,
# and the pinout cannot drift away from the board.

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out  $here/build

file mkdir $out
create_project -force ddr2_test $out/proj -part xc7a100tcsg324-1

# ------------------------------------------------------------------- the MIG
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
    -module_name mig_7series_0
set_property CONFIG.XML_INPUT_FILE $here/mig.prj [get_ips mig_7series_0]
generate_target all [get_ips mig_7series_0]

# --------------------------------------------------- 200 MHz reference clock
# The MIG's reference clock is "No Buffer" in mig.prj, so it has to come from
# outside.  clk_out1 is the 200 MHz reference, clk_out2 the 100 MHz system
# clock the MIG asks for.
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
] [get_ips clk_wiz_0]
generate_target all [get_ips clk_wiz_0]

# ------------------------------------------------------------------- sources
add_files [list \
    $root/rtl/soc/uart.sv \
    $here/ddr2_bist.sv \
    $here/top_ddr2.sv]
add_files -fileset constrs_1 $here/ddr2.xdc
set_property top top_ddr2 [current_fileset]
update_compile_order -fileset sources_1

# --------------------------------------------------------------------- build
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis failed - see $out/proj/ddr2_test.runs/synth_1"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed - see $out/proj/ddr2_test.runs/impl_1"
}

open_run impl_1
report_timing_summary -file $out/timing.rpt
report_utilization    -file $out/utilization.rpt

set bit [glob -nocomplain $out/proj/ddr2_test.runs/impl_1/*.bit]
if {[llength $bit] == 0} { error "no bitstream produced" }
file copy -force [lindex $bit 0] $out/ddr2_test.bit
puts "wrote $out/ddr2_test.bit"
puts "WNS [get_property STATS.WNS [get_runs impl_1]]"
