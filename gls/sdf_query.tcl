# sdf_query.tcl : slow-corner path figures behind the SDF testbench timing (results.txt, item 4).
# Run in a directory holding net.v (routed netlist) and net.spef (name-fixed SPEF, see icarus_tb.sh):
#   BP55_ROOT=<repo> sta -no_init -exit sdf_query.tcl   (zero IO delays, ideal 6.0 ns clock, propagated)
set LIBD $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty
read_liberty $LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib
read_verilog net.v
link_design bp55
read_spef net.spef
create_clock -name clk -period 6.0 [get_ports clk]
set_propagated_clock [all_clocks]
set_input_delay 0 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 0 -clock clk [all_outputs]
foreach o {f_busy f_ckpt[*] f_meta[*] f_hit f_taken f_target[*] f_dir f_ras_top[*] f_type[*]} {
  puts "== max to $o"; report_checks -to [get_ports $o] -path_delay max -format end
}
puts "== input to flops max"; report_checks -from [delete_from_list [all_inputs] [get_ports clk]] -to [all_registers -data_pins] -path_delay max -format end
puts "== input to flops min"; report_checks -from [delete_from_list [all_inputs] [get_ports clk]] -to [all_registers -data_pins] -path_delay min -format end
puts "== flop to flop max"; report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -format end
