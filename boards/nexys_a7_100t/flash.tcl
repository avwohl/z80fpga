# Write a bitstream into the Nexys A7's QSPI flash, so the board comes up
# running it with no computer attached.
#
#   vivado -mode batch -source boards/nexys_a7_100t/flash.tcl \
#          -tclargs boards/nexys_a7_100t/romwbw/build/romwbw_soc.bit
#
# **Set the MODE jumper (JP1) to QSPI before this is any use.** The FPGA reads
# its configuration from wherever the mode pins say at power-up; with JP1 on
# JTAG it will ignore the flash entirely and come up blank, which looks exactly
# like the programming having failed. Programming over JTAG works either way --
# it is only the power-up path that cares.
#
# The flash is a 16 MB Spansion S25FL128S. A bitstream for this part is about
# 3.8 MB, so there is room for the bitstream and plenty left over; a ROM image
# or a disk image could live at a high offset later, which is what -loaddata on
# write_cfgmem is for.
#
# SPIx1 rather than SPIx4 on purpose: x4 needs the bitstream itself built with
# CONFIG_MODE SPIx4 and BITSTREAM.CONFIG.SPI_BUSWIDTH 4, and gets configuration
# down from about a second to a quarter of one. That is not worth making the
# bitstream and the flash image agree about, and a mismatch there fails in a
# way that is tedious to diagnose. If you want it, set both properties in the
# board XDC and change the -interface below to match.

if {[llength $argv] < 1} {
    error "usage: vivado -mode batch -source flash.tcl -tclargs <bitfile> \[mcsfile\]"
}

set bit [file normalize [lindex $argv 0]]
if {![file exists $bit]} { error "no such bitstream: $bit" }

if {[llength $argv] >= 2} {
    set mcs [file normalize [lindex $argv 1]]
} else {
    set mcs [file rootname $bit].mcs
}

# The part on the Nexys A7-100T, a 16 MB Spansion S25FL128S.
#
# Look it up with -of_objects against the actual device, not by globbing the
# whole catalogue.  A bare `get_cfgmem_parts {s25fl128s*}` matches names from
# other device families first -- s25fl128s-3.3v-qspi-x1-single among them --
# and those are accepted by get_cfgmem_parts and then rejected by
# create_hw_cfgmem with "Cfgmem part ... is not supported for device artix7".
set flash_part "s25fl128sxxxxxx0-spi-x1_x2_x4"

puts "==> building $mcs from [file tail $bit]"
write_cfgmem -force -format mcs -size 16 -interface SPIx1 \
    -loadbit "up 0x00000000 $bit" -file $mcs

puts "==> connecting"
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "==> device [get_property PART $dev]"

set part [lindex [get_cfgmem_parts -of_objects $dev $flash_part] 0]
if {$part eq ""} {
    error "no flash part matching $flash_part is compatible with this device"
}
create_hw_cfgmem -hw_device $dev $part
set cfg [get_property PROGRAM.HW_CFGMEM $dev]

set_property PROGRAM.FILES         [list $mcs] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file}  $cfg
set_property PROGRAM.BLANK_CHECK   0           $cfg
set_property PROGRAM.ERASE         1           $cfg
set_property PROGRAM.CFG_PROGRAM   1           $cfg
set_property PROGRAM.VERIFY        1           $cfg
set_property PROGRAM.CHECKSUM      0           $cfg

# Programming the flash is done by a small helper design loaded into the FPGA,
# which is what this pair of commands is for; it has nothing to do with the
# bitstream being stored.
puts "==> loading the flash programmer"
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev

puts "==> erasing, programming and verifying (this takes a couple of minutes)"
program_hw_cfgmem -hw_cfgmem $cfg

# Put the real design back.  Programming the flash leaves the flash-programmer
# helper loaded in the FPGA, which answers nothing: the console goes dead and
# it looks for all the world as though the flashing broke the board.  It did
# not -- the flash is written and a power cycle would come up fine -- but there
# is no reason to leave it looking broken until then.
puts "==> reloading $bit so the board is running the real design again"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev

puts "==> done. The board is running it now, and with JP1 on QSPI it will come"
puts "    up running it after a power cycle too."
close_hw_target
close_hw_manager
