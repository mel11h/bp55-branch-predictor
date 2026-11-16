# Post-route checks on 5_final.odb, independent of the routing session: router DRC checker,
# antenna check, placement check, cell usage, area, ICG count. Used for gated_cg2, whose
# 3_route.log stopped after pin access (its run.sh wrapper was killed; the OpenROAD process
# finished in its systemd scope and wrote 5_final.* and the report files, but its stdout was lost).
source $::env(RUN_DIR)/scripts/common.tcl ;# snapshot made by run.sh
set_thread_count 6
load_tech
read_db $RUN/5_final.odb
puts "==== router DRC check (drt::check_drc) on 5_final.odb"
drt::check_drc -output_file $RUN/4_postroute_drc.rpt
puts "4_postroute_drc.rpt bytes: [file size $RUN/4_postroute_drc.rpt]"
puts "==== antenna check"
check_antennas -report_file $RUN/4_postroute_antenna.rpt
check_placement
report_design_area
report_cell_usage
puts "ICG instances: [llength [get_cells -quiet -filter {ref_name =~ ICG*} *]]"
