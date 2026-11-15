# OpenRCX extraction of a detailed-routed BP55 layout with one rules file (one RC corner).
# env: BP55_ROOT, RCX_LAYOUT (.def/.def.gz/.odb), RCX_RULES, RCX_SPEF (output, uncompressed)
#      RCX_CC_THRESH (fF, default 0.1), RCX_MAX_RES (ohm, default 0: no merging of wire
#      segments, so every routed shape keeps its own RC node and layer)
set ROOT $::env(BP55_ROOT)
set SC $ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR
set lay $::env(RCX_LAYOUT)
if {[string match *.odb $lay]} {
  read_db $lay
} else {
  read_lef $ROOT/pdk/prtech/techLEF/N551P6M_ecos.lef
  read_lef $SC/lef/ics55_LLSC_H7CR_ecos.lef
  if {[string match *.gz $lay]} {
    set tmp $::env(RCX_SPEF).layout.def
    exec gunzip -c $lay > $tmp
    read_def $tmp
    file delete $tmp
  } else {
    read_def $lay
  }
}
set cc  [expr {[info exists ::env(RCX_CC_THRESH)] ? $::env(RCX_CC_THRESH) : 0.1}]
set mr  [expr {[info exists ::env(RCX_MAX_RES)] ? $::env(RCX_MAX_RES) : 0}]
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $::env(RCX_RULES) -max_res $mr -coupling_threshold $cc \
  -cc_model 12 -context_depth 5
write_spef $::env(RCX_SPEF)
# escape non-bus bracketed net names (see fix_spef_names.py)
puts [exec [expr {[info exists ::env(PYTHON)] ? $::env(PYTHON) : "/usr/bin/python3"}] -I $::env(BP55_ROOT)/rcx/scripts/fix_spef_names.py $::env(RCX_SPEF)]

# Per-layer breakdown from the extraction database: every resistor segment carries the
# capacitance of its target node; the layer is that of the wire shape the segment was made
# from. Coupling is counted on both nets (as in the per-net SPEF totals).
set gnd [dict create]; set cpl [dict create]; set len [dict create]
set dec [odb::new_dbWireDecoder]
set END $::odb::dbWireDecoder_END_DECODE
foreach net [[ord::get_db_block] getNets] {
  if {[$net isSpecial]} continue
  set wire [$net getWire]
  if {$wire eq "NULL"} continue
  # junction id -> layer name (vias: "via"); a resistor segment's shape id is the junction
  # id of the last wire shape it covers, so the nearest junction at or below it is used
  set jids {}; set jl [dict create]
  $dec begin $wire
  while {[set op [$dec next]] != $END} {
    set l [$dec getLayer]
    set j [$dec getJunctionId]
    if {$op == $::odb::dbWireDecoder_VIA || $op == $::odb::dbWireDecoder_TECH_VIA} {
      dict set jl $j via
    } elseif {$l ne "NULL"} {
      dict set jl $j [$l getName]
    } else continue
    lappend jids $j
  }
  set jids [lsort -integer -unique $jids]
  foreach rseg [$net getRSegs] {
    set sid [$rseg getShapeId]
    set lname other
    foreach j $jids { if {$j <= $sid} { set lname [dict get $jl $j] } else break }
    set cn [$rseg getTargetCapNode]
    if {![dict exists $gnd $lname]} { dict set gnd $lname 0.0; dict set cpl $lname 0.0 }
    dict set gnd $lname [expr {[dict get $gnd $lname] + [$rseg getCapacitance]}]
    set c 0.0
    foreach cc [$cn getCCSegs] { set c [expr {$c + [$cc getCapacitance]}] }
    dict set cpl $lname [expr {[dict get $cpl $lname] + $c}]
  }
}
puts "==== per-layer capacitance (fF): layer ground coupling total"
foreach l [lsort [dict keys $gnd]] {
  puts [format "layer %-5s %10.1f %10.1f %10.1f" $l [dict get $gnd $l] [dict get $cpl $l] \
    [expr {[dict get $gnd $l] + [dict get $cpl $l]}]]
}
puts "fills in block: [llength [[ord::get_db_block] getFills]]"
