# Metal fill on the routed design (OpenROAD density_fill, rules in pnr/flow/fill_rules.json),
# with the router's DRC checker run before and after fill on the same database.
# Inputs: $RUN/5_final.odb. Outputs: $RUN/8_fill.odb, $RUN/8_fill.def,
# $RUN/8_drc_unfilled.rpt, $RUN/8_drc_filled.rpt.
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
set_thread_count 8
load_tech
read_db $RUN/5_final.odb
puts "==== router DRC check before fill"
drt::check_drc -output_file $RUN/8_drc_unfilled.rpt
set block [ord::get_db_block]
puts "fills before: [llength [$block getFills]]"
puts "==== density_fill"
density_fill -rules $::env(BP55_ROOT)/pnr/flow/fill_rules.json
set counts [dict create]
foreach f [$block getFills] {
  dict incr counts "[[$f getTechLayer] getName] opc=[$f needsOPC]"
}
puts "fills after: [llength [$block getFills]]"
dict for {k v} $counts { puts "  fill $k : $v" }
puts "==== router DRC check after fill"
drt::check_drc -output_file $RUN/8_drc_filled.rpt
write_db $RUN/8_fill.odb
write_def $RUN/8_fill.def
