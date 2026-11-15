# STA of the layout optimised for 6.0 ns, checked against another clock period.
source ../common.tcl
load_tech
read_def final_6p0.def ;# gunzip -c ../5_final.def.gz > final_6p0.def
read_sdc sta.sdc
set_propagated_clock [all_clocks]
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
# drop detailed wires so the global router rebuilds routes for RC estimation (placement is unchanged)
foreach net [[ord::get_db_block] getNets] { if {![$net isSpecial]} { set w [$net getWire]; if {$w ne "NULL"} { odb::dbWire_destroy $w } } }
global_route -congestion_iterations 50
estimate_parasitics -global_routing
rpt "layout optimised at 6.0 ns, checked at $::env(PERIOD) ns"
