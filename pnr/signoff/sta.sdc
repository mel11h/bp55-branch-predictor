# BP55 block-level constraints. Lookup is single-cycle: f_pc comes from the PC flop of the core,
# prediction outputs go through the next-PC mux back into the PC flop.
set clk_period $::env(PERIOD)
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
