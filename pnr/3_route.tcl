source common.tcl
load_tech
read_db 2_cts.odb
read_sdc bp55.sdc
set_propagated_clock [all_clocks]
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
# ---- global route + timing repair on global-route parasitics
global_route -congestion_iterations 50
estimate_parasitics -global_routing
rpt "after global route"
global_route -start_incremental
repair_timing -setup
repair_timing -hold -hold_margin 0.02 -max_buffer_percent 80
detailed_placement
global_route -end_incremental -congestion_iterations 50
estimate_parasitics -global_routing
check_placement
rpt "after post-GRT timing repair"
write_db 3_grt.odb
# ---- detailed route
detailed_route -output_drc 4_drt_drc.rpt -verbose 1
write_db 4_drt.odb
# ---- finishing
filler_placement {FILLER64H7R FILLER32H7R FILLER16H7R FILLER8H7R FILLER4H7R FILLER2H7R FILLER1H7R}
check_placement
write_db 5_final.odb
write_def 5_final.def
write_verilog 5_final.v
estimate_parasitics -global_routing
rpt "final (routed design, global-route parasitics)"
report_clock_skew
report_power -corner tt
report_checks -corner ss -path_delay max -fields {slew cap fanout} -digits 3
report_checks -corner tt -path_delay max -digits 3 -format end
catch {check_antennas -report_file antenna.rpt}
report_cell_usage
