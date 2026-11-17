# Second clock-latency balancing pass, on a finished, routed database: pad the early clock
# branches against the clock arrivals of the extracted routed wires, then legalise, route
# incrementally, refill.
# Inputs: $RUN/eco_in.odb (a 5_final.odb) and the three-corner SPEF of that layout in
# BP55_BAL_SPEF (bp55_rcworst/typ/rcbest.spef.gz, from rcx/run_rcx.sh).
# How: the padding itself is cts_balance.tcl. Its passes re-time against placement-based
# parasitics, which do not match the routed wires, so they are only used for the change:
# per flop, offset = arrival on the SPEF - arrival on the placement estimate, both taken
# before anything is inserted; every later arrival is estimate + offset.
# env: BP55_BAL_SPEF, BP55_BAL_PREFIX (default clkbal2), BP55_BAL_FREEZE, BP55_BAL_SIDE / _ITERS / _MIN.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
if {![info exists ::env(BP55_BAL_PREFIX)] || $::env(BP55_BAL_PREFIX) eq ""} { set ::env(BP55_BAL_PREFIX) clkbal2 }
set_thread_count 1
load_tech
read_db $RUN/eco_in.odb
read_constraints
set_propagated_clock [all_clocks]
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
set block [ord::get_db_block]
set bal_defer 1
source $RUN/scripts/cts_balance.tcl

set S $::env(BP55_BAL_SPEF)
foreach {c n} {ss rcworst tt typ ff rcbest} { read_spef -corner $c $S/bp55_$n.spef.gz }
report_worst_slack -max
set tree [bal_walk [$block findNet clk]]
puts "extracted routed wires: [bal_stats $tree]"
proc bal_pins {nodes} {
  set r {}
  foreach n $nodes {
    lassign $n it kind kids
    if {$kind eq "sink"} { lappend r [[$it getInst] getName]/[[$it getMTerm] getName] } else { lappend r {*}[bal_pins $kids] }
  }
  return $r
}
set spef_arr [dict create]
foreach nm [bal_pins $tree] { dict set spef_arr $nm [get_property [get_pins $nm] arrival_max_rise] }

set nfill 0
foreach inst [$block getInsts] {
  if {[string match FILLER* [[$inst getMaster] getName]]} { odb::dbInst_destroy $inst; incr nfill }
}
puts "removed $nfill filler instances"
global_route -congestion_iterations 50
global_route -start_incremental
set loc [dict create]
foreach inst [$block getInsts] { dict set loc [$inst getName] [$inst getLocation] }

estimate_parasitics -placement
report_worst_slack -max
puts "placement estimate:     [bal_stats $tree]"
dict for {nm a} $spef_arr { dict set bal_off $nm [expr {$a - [get_property [get_pins $nm] arrival_max_rise]}] }
set offs [lsort -real [dict values $bal_off]]
puts [format "offset SPEF - estimate: min %.3f median %.3f max %.3f ns" [lindex $offs 0] [lindex $offs [expr {[llength $offs] / 2}]] [lindex $offs end]]
# Freeze every existing cell while the padding cells are legalised (BP55_BAL_FREEZE=0: off).
# Without it detailed_placement shifts cells all over the block to make room: 7,047 nets were
# rerouted for 1,609 padding cells, the arrivals moved by more than the balancing gained (flop
# spread 0.415 -> 0.387 ns on the extraction) and the critical data path lost 0.32 ns.
set freeze [expr {![info exists ::env(BP55_BAL_FREEZE)] || $::env(BP55_BAL_FREEZE) ne "0"}]
set status [dict create]
if {$freeze} {
  foreach inst [$block getInsts] { dict set status [$inst getName] [$inst getPlacementStatus]; $inst setPlacementStatus FIRM }
  puts "froze [dict size $status] placed instances"
}
bal_run
dict for {nm st} $status { [$block findInst $nm] setPlacementStatus $st }

# Drop the detailed wires of every net touched by the ECO or by legalisation before the
# incremental global route (see 5_eco_delay.tcl for why).
set dirty [dict create]
foreach inst [$block getInsts] {
  set nm [$inst getName]
  if {![dict exists $loc $nm] || [dict get $loc $nm] ne [$inst getLocation]} {
    foreach it [$inst getITerms] {
      set net [$it getNet]
      if {$net ne "NULL" && ![$net isSpecial]} { dict set dirty [$net getName] $net }
    }
  }
}
set nw 0
dict for {nm net} $dirty { set w [$net getWire]; if {$w ne "NULL"} { odb::dbWire_destroy $w; incr nw } }
puts "nets touched: [dict size $dirty], detailed wires dropped: $nw"
global_route -end_incremental -congestion_iterations 50 -allow_congestion
estimate_parasitics -global_routing
check_placement
rpt "after clock balancing ECO (global-route parasitics)"
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
