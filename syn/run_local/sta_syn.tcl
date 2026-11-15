# Zero-wire-load OpenSTA check of a synthesis netlist (ideal clock, no IO budgets).
# env: NETLIST, CORNER (tt|ss), BP55_ROOT
set LIBD $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty
if {$::env(CORNER) eq "ss"} {
  read_liberty $LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib
} else {
  read_liberty $LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib
}
read_verilog $::env(NETLIST)
link_design bp55
create_clock -name clk -period 10.0 [get_ports clk]
set data_in {}
foreach p [all_inputs] { if {[lsearch {clk rst_n} [get_full_name $p]] < 0} { lappend data_in $p } }
set_input_delay 0 -clock clk $data_in
set_output_delay 0 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
set_driving_cell -lib_cell BUFX4H7R -pin Y $data_in
set_load 0.010 [all_outputs]
puts "== worst path of each kind, 10 ns ideal clock, zero wire load, corner $::env(CORNER)"
foreach {tag from to} {reg2reg reg reg in2reg in reg reg2out reg out in2out in out} {
  set f [expr {$from eq "reg" ? [all_registers -clock_pins] : $data_in}]
  set t [expr {$to eq "reg" ? [all_registers -data_pins] : [all_outputs]}]
  puts "-- $tag (Actual delay = arrival from clock edge, includes clock-to-Q for reg starts)"
  report_checks -from $f -to $t -path_delay max -format end -digits 3
}
puts "== critical path detail (reg2out / reg2reg)"
report_checks -from [all_registers -clock_pins] -to [all_outputs] -path_delay max -digits 3
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -digits 3
