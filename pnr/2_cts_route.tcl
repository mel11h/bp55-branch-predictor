source common.tcl
load_tech
read_db 1_place.odb
read_sdc bp55.sdc
set_rc
# ---- clock tree (the library has no dedicated clock buffers: use balanced BUFX)
set_propagated_clock [all_clocks]
clock_tree_synthesis -buf_list {BUFX4H7R BUFX8H7R} -root_buf BUFX8H7R -sink_clustering_enable
repair_clock_nets
detailed_placement
estimate_parasitics -placement
repair_timing -setup
repair_timing -hold -hold_margin 0.0 -max_buffer_percent 80
detailed_placement
check_placement
write_db 2_cts.odb
rpt "after CTS + timing repair"
# ---- routing
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
global_route -congestion_iterations 50 -verbose
estimate_parasitics -global_routing
rpt "after global route"
write_db 3_grt.odb
detailed_route -output_drc 4_drt_drc.rpt -verbose 1
write_db 4_drt.odb
# ---- finishing
filler_cell_placement {FILLER64H7R FILLER32H7R FILLER16H7R FILLER8H7R FILLER4H7R FILLER2H7R FILLER1H7R}
check_placement
estimate_parasitics -global_routing
rpt "final (post-route, global-route parasitics)"
report_clock_skew
report_power -corner tt
report_checks -corner ss -path_delay max -fields {slew cap fanout} -digits 3
check_antennas
write_db 5_final.odb
write_def 5_final.def
write_verilog 5_final.v
