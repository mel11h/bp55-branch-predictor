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
