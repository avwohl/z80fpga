# Vivado build for RomWBW on the Nexys A7-100T: 512 KB ROM in block RAM,
# 512 KB RAM in DDR2.
#
#   python tools/mkromhex.py path/to/SBC_simh_std.rom \
#       boards/nexys_a7_100t/romwbw/romwbw512k.hex --size 524288
#   cd boards/nexys_a7_100t/romwbw && vivado -mode batch -source build_romwbw.tcl
#
# The ROM image is not in the repository; make it first with the command above.
# A project on disk rather than the in-memory flow, because the MIG has to be
# generated and synthesised as IP.

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out  $here/build

if {![file exists $here/romwbw512k.hex]} {
    error "romwbw512k.hex is missing - build it with tools/mkromhex.py, see the header of this file"
}

file mkdir $out
# $readmemh resolves relative to the run directory, so put the images there.
foreach f [list $root/rtl/core/z80_ucode.mem $root/rtl/core/z80_dispatch.mem] {
    file copy -force $f $out
}
file copy -force $here/romwbw512k.hex $out

create_project -force romwbw_soc $out/proj -part xc7a100tcsg324-1

# ------------------------------------------------------------------- the MIG
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
    -module_name mig_7series_0
set_property CONFIG.XML_INPUT_FILE $here/mig.prj [get_ips mig_7series_0]
generate_target all [get_ips mig_7series_0]

# --------------------------------------------------- 200 MHz reference clock
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
    $root/rtl/core/z80_alu.sv \
    $root/rtl/core/z80_core.sv \
    $root/rtl/mem/sync_ram.sv \
    $root/rtl/mem/ddr2_ram.sv \
    $root/rtl/soc/z80_mmu.sv \
    $root/rtl/soc/uart.sv \
    $root/rtl/soc/z80_soc.sv \
    $here/top_romwbw.sv]
set_property include_dirs $root/rtl/core [current_fileset]
add_files -fileset constrs_1 $here/romwbw.xdc
set_property top top_romwbw [current_fileset]
update_compile_order -fileset sources_1

# $readmemh resolves relative to whatever directory the tool is running in,
# and synthesis and implementation each run in their own.  A pre-step hook is
# the reliable way to put the images there: it executes inside that directory,
# after the run has been reset, so nothing can clean the files away again.
set hook $out/copy_mem.tcl
set fh [open $hook w]
foreach f [list z80_ucode.mem z80_dispatch.mem romwbw512k.hex] {
    puts $fh "file copy -force {$out/$f} [file join . $f]"
}
close $fh
set_property STEPS.SYNTH_DESIGN.TCL.PRE  $hook [get_runs synth_1]
set_property STEPS.OPT_DESIGN.TCL.PRE    $hook [get_runs impl_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis failed - see $out/proj/romwbw_soc.runs/synth_1"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed - see $out/proj/romwbw_soc.runs/impl_1"
}

open_run impl_1
report_timing_summary -file $out/timing.rpt
report_utilization    -file $out/utilization.rpt

set bit [glob -nocomplain $out/proj/romwbw_soc.runs/impl_1/*.bit]
if {[llength $bit] == 0} { error "no bitstream produced" }
file copy -force [lindex $bit 0] $out/romwbw_soc.bit
puts "wrote $out/romwbw_soc.bit"
puts "WNS [get_property STATS.WNS [get_runs impl_1]]"
