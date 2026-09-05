# Vivado batch build for the Arty A7-100T.
#   cd boards/arty_a7_100t && vivado -mode batch -source build.tcl
# Writes build/z80fpga.bit.
#
# The .mem files are copied next to the build so the $readmemh paths inside
# the RTL resolve without Vivado's working-directory rules getting in the way.

set root [file normalize [file dirname [info script]]/../..]
set out  [file join [file dirname [info script]] build]
file mkdir $out
foreach f {rtl/core/z80_ucode.mem rtl/core/z80_dispatch.mem sw/boot.hex} {
    file copy -force [file join $root $f] $out
}

create_project -in_memory -part xc7a100tcsg324-1
set_property target_language Verilog [current_project]

read_verilog -sv [list \
    [file join $root rtl/core/z80_alu.sv] \
    [file join $root rtl/core/z80_core.sv] \
    [file join $root rtl/mem/sync_ram.sv] \
    [file join $root rtl/soc/z80_mmu.sv] \
    [file join $root rtl/soc/uart.sv] \
    [file join $root rtl/soc/z80_soc.sv] \
    [file join [file dirname [info script]] top.sv]]

set_property include_dirs [file join $root rtl/core] [current_fileset]
read_xdc [file join [file dirname [info script]] arty_a7_100t.xdc]

cd $out
synth_design -top top -part xc7a100tcsg324-1
opt_design
place_design
phys_opt_design
route_design
report_utilization -file utilization.rpt
report_timing_summary -file timing.rpt
write_bitstream -force z80fpga.bit
puts "wrote [file join $out z80fpga.bit]"
