# Hold ECO on a finished, routed database: remove fillers, repair hold with a margin on
# global-route parasitics, legalise, route, refill. Input: $RUN/eco_in.odb (a 5_final.odb).
# env: BP55_HOLD_MARGIN (ns, default 0.06), BP55_ECO_IN_MIN (see below). The margin is larger than in 3_route.tcl because
# the final check uses the extracted wires of pnr/flow/def2spef.py, which left a 10 ps
# fast-corner violation on one output that the global-route estimate had shown as met.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
set margin [expr {[info exists ::env(BP55_HOLD_MARGIN)] ? $::env(BP55_HOLD_MARGIN) : 0.06}]
set_thread_count 1
load_tech
read_db $RUN/eco_in.odb
read_constraints
set_propagated_clock [all_clocks]
# BP55_ECO_IN_MIN (ns, optional): minimum input delay used during the repair only, in place of
# the SDC's 0.10 ns. The coupled extraction (rcx/) shows input-to-flop hold paths about 0.17 ns
# worse than the global-route estimate used here; a general margin of that size would touch
# thousands of flop-to-flop endpoints that are fine. The final checks use the unmodified SDC.
if {[info exists ::env(BP55_ECO_IN_MIN)] && $::env(BP55_ECO_IN_MIN) ne ""} {
  set ins {}
  foreach p [all_inputs] { if {[get_full_name $p] ne "clk"} { lappend ins $p } }
  set_input_delay -min $::env(BP55_ECO_IN_MIN) -clock clk -reference_pin [get_pins $::bp55_io_ref_pin] $ins
  puts "repair-only input min delay $::env(BP55_ECO_IN_MIN) ns on [llength $ins] inputs"
}
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
# remove_fillers leaves these cells in place (the LEF does not class them CORE SPACER);
# delete them by master name. FILLTAP* (well taps) stay.
set nfill 0
foreach inst [[ord::get_db_block] getInsts] {
  if {[string match FILLER* [[$inst getMaster] getName]]} { odb::dbInst_destroy $inst; incr nfill }
}
puts "removed $nfill filler instances"
global_route -congestion_iterations 50
estimate_parasitics -global_routing
rpt "before hold ECO (global-route parasitics)"
global_route -start_incremental
puts "hold margin $margin ns"
repair_timing -hold -hold_margin $margin -max_buffer_percent 5
detailed_placement
# the incremental reroute of the new buffer nets ends with a few congested gcells;
# detailed routing resolves them (checked by its violation count)
global_route -end_incremental -congestion_iterations 50 -allow_congestion
estimate_parasitics -global_routing
check_placement
rpt "after hold ECO (global-route parasitics)"
set_thread_count 8
detailed_route -output_drc $RUN/4_drt_drc.rpt -verbose 1
set_thread_count 1
filler_placement {FILLER64H7R FILLER32H7R FILLER16H7R FILLER8H7R FILLER4H7R FILLER2H7R FILLER1H7R}
check_placement
write_db $RUN/5_final.odb
write_def $RUN/5_final.def
write_verilog $RUN/5_final.v
check_antennas -report_file $RUN/antenna.rpt
report_cell_usage
