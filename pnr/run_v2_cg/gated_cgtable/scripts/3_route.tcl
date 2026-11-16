# Global route, post-GRT repair, detailed route, fillers. Recipe of pnr/3_route.tcl,
# parameterised; reports go to files in the run directory.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
# OpenROAD v2.0-17598 crashed (SIGSEGV in sta::ClkInfo::refsFilter, multi-threaded arrival
# search) on the first timing report after CTS in one of three identical runs; STA-heavy
# steps therefore run single-threaded, detailed routing uses up to 6 threads.
set_thread_count 1
load_tech
read_db $RUN/2_cts.odb
read_constraints
set_propagated_clock [all_clocks]
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
# ---- global route + timing repair on global-route parasitics
global_route -congestion_iterations 50
estimate_parasitics -global_routing
rpt "after global route"
global_route -start_incremental
# OpenROAD v2.0-17598 crashed (SIGSEGV in GlobalRouter::mergeNetsRouting called from
# Resizer::removeBuffer) during this repair in the legacy 5.0 ns run; that run sets
# SKIP_BUFFER_REMOVAL=1, which only stops repair_timing from deleting buffers here.
if {[info exists ::env(SKIP_BUFFER_REMOVAL)] && $::env(SKIP_BUFFER_REMOVAL)} {
  repair_timing -setup -skip_buffer_removal
} else {
  repair_timing -setup
}
repair_timing -hold -hold_margin 0.02 -max_buffer_percent 80
detailed_placement
global_route -end_incremental -congestion_iterations 50
estimate_parasitics -global_routing
check_placement
rpt "after post-GRT timing repair"
write_db $RUN/3_grt.odb
# ---- detailed route
set_thread_count 6
detailed_route -output_drc $RUN/4_drt_drc.rpt -verbose 1
set_thread_count 1
# ---- finishing
filler_placement {FILLER64H7R FILLER32H7R FILLER16H7R FILLER8H7R FILLER4H7R FILLER2H7R FILLER1H7R}
check_placement
write_db $RUN/5_final.odb
write_def $RUN/5_final.def
write_verilog $RUN/5_final.v
# in the routing session the global routes that guided the detailed router are still in memory
estimate_parasitics -global_routing
rpt "final (routed design, global-route parasitics)"
check_antennas -report_file $RUN/antenna.rpt
report_cell_usage
