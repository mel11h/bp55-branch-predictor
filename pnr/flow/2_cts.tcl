# Clock tree and post-CTS timing repair. Recipe of pnr/2_cts.tcl, parameterised;
# additions: BP55_CTS_PRE / BP55_CTS_ARGS hooks and a clock-gating report.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
# OpenROAD v2.0-17598 crashed (SIGSEGV in sta::ClkInfo::refsFilter, multi-threaded arrival
# search) on the first timing report after CTS in one of three identical runs; STA-heavy
# steps therefore run single-threaded, detailed routing uses up to 8 threads.
set_thread_count 1
load_tech
read_db $RUN/1_place.odb
read_constraints
set_rc
# ---- clock tree (the library has no dedicated clock buffers: use balanced BUFX)
set_propagated_clock [all_clocks]
# BP55_CTS_PRE: optional Tcl run before CTS (clock-gating runs: ICG placement / dont_touch)
if {[info exists ::env(BP55_CTS_PRE)] && $::env(BP55_CTS_PRE) ne ""} { source $::env(BP55_CTS_PRE) }
# BP55_CTS_ARGS: extra clock_tree_synthesis options (empty = the pnr/flow recipe)
set cts_extra [expr {[info exists ::env(BP55_CTS_ARGS)] ? $::env(BP55_CTS_ARGS) : ""}]
puts "clock_tree_synthesis extra options: '$cts_extra'"
clock_tree_synthesis -buf_list {BUFX4H7R BUFX8H7R} -root_buf BUFX8H7R -sink_clustering_enable {*}$cts_extra
repair_clock_nets
detailed_placement
estimate_parasitics -placement
puts "==== clock tree before timing repair"
foreach c {ss tt ff} { report_clock_latency -corner $c -digits 3 }
foreach c {ss tt ff} { report_clock_skew -corner $c -digits 3 }
# ---- re-read the constraints with the IO reference pin (only if the SDC uses it)
if {[info exists ::env(BP55_IO_REF)] && $::env(BP55_IO_REF)} {
  pick_io_ref_pin
  read_constraints
  set_propagated_clock [all_clocks]
}
rpt "after CTS, before timing repair"
cg_report
repair_timing -setup
repair_timing -hold -hold_margin 0.0 -max_buffer_percent 80
detailed_placement
check_placement
write_db $RUN/2_cts.odb
rpt "after CTS + timing repair"
report_cell_usage
