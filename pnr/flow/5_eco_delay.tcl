# Targeted hold ECO on a finished, routed database: one delay cell in front of each listed
# flop data pin, then legalise, route incrementally, refill.
# Inputs: $RUN/eco_in.odb (a 5_final.odb), $RUN/eco_pins.txt (one "inst/pin" per line, rest of
# the line ignored, # comments). env: BP55_ECO_CELL (default DLY1X2H7R).
# Why not repair_timing: the pins come from STA on the coupled extraction (rcx/), which this
# tool cannot use for repair; its global-route estimate shows these paths as met, and a margin
# large enough to catch them selects thousands of endpoints that are fine.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
set cellname [expr {[info exists ::env(BP55_ECO_CELL)] && $::env(BP55_ECO_CELL) ne "" ? $::env(BP55_ECO_CELL) : "DLY1X2H7R"}]
set_thread_count 1
load_tech
read_db $RUN/eco_in.odb
read_constraints
set_propagated_clock [all_clocks]
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
set block [ord::get_db_block]
set nfill 0
foreach inst [$block getInsts] {
  if {[string match FILLER* [[$inst getMaster] getName]]} { odb::dbInst_destroy $inst; incr nfill }
}
puts "removed $nfill filler instances"
global_route -congestion_iterations 50
global_route -start_incremental
set master [[ord::get_db] findMaster $cellname]
if {$master eq "NULL"} { error "no master $cellname" }
set f [open $RUN/eco_pins.txt]; set n 0
while {[gets $f line] >= 0} {
  set pin [lindex $line 0]
  if {$pin eq "" || [string match "#*" $pin]} continue
  lassign [split $pin /] iname pname
  set flop [$block findInst $iname]
  if {$flop eq "NULL"} { error "no instance $iname" }
  set it [$flop findITerm $pname]
  set old [$it getNet]
  set inst [odb::dbInst_create $block $master holdeco_$n]
  set net [odb::dbNet_create $block holdeco_net_$n]
  lassign [$flop getLocation] x y
  $inst setLocation $x $y
  $inst setPlacementStatus PLACED
  $it disconnect
  [$inst findITerm A] connect $old
  [$inst findITerm Y] connect $net
  $it connect $net
  incr n
}
close $f
puts "inserted $n $cellname delay cells"
set loc [dict create]
foreach inst [$block getInsts] { dict set loc [$inst getName] [$inst getLocation] }
detailed_placement
# Drop the detailed wires of every net touched by the ECO or by legalisation before the
# incremental global route. This OpenROAD build aborts in GlobalRouter::removeWireUsage
# (edge index out of range) when it removes the usage of some existing wires itself; without
# a wire it has nothing to remove. The nets are routed again by detailed_route.
set dirty [dict create]
foreach inst [$block getInsts] {
  set nm [$inst getName]
  if {[string match holdeco_* $nm] || [dict get $loc $nm] ne [$inst getLocation]} {
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
rpt "after delay-cell ECO (global-route parasitics)"
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
