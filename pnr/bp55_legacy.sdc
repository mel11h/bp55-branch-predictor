# LEGACY constraints of the original BP55 layout (the committed pnr/bp55.sdc before
# the v1 constraints replaced it). Kept so the original numbers stay reproducible.
# The only change from the original file is that the period can be overridden with
# BP55_PERIOD: the committed layout was placed with 5.0 ns (pnr/1_place.log, output
# required time 4.40 ns), while this file said 6.0 ns. The README numbers are checked
# at 6.0 and 6.2 ns (pnr/signoff/).
# Known weaknesses, see pnr/bp55.sdc for the replacement: IO delays are referenced to the
# ideal clock while the flops see the propagated clock tree, and one 0.5 ns budget is
# used for every port.
#
# BP55 block-level constraints. Lookup is single-cycle: f_pc comes from the PC flop of the core,
# prediction outputs go through the next-PC mux back into the PC flop.
set clk_period [expr {[info exists ::env(BP55_PERIOD)] ? $::env(BP55_PERIOD) : 6.0}]
create_clock -name clk -period $clk_period [get_ports clk]
set_clock_uncertainty -setup 0.10 [get_clocks clk]
set_clock_uncertainty -hold 0.03 [get_clocks clk]
set data_in {}
foreach p [all_inputs] { if {[get_full_name $p] ne "clk" && [get_full_name $p] ne "rst_n"} { lappend data_in $p } }
set_input_delay  0.50 -clock clk $data_in
set_output_delay 0.50 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
set_driving_cell -lib_cell BUFX4H7R -pin Y $data_in
set_load 0.010 [all_outputs]
