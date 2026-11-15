source common.tcl
load_tech
read_verilog bp55_pnr_in.v
link_design bp55
read_sdc bp55.sdc
# ---- floorplan: 55 % initial utilisation, square, 5 um core margin
initialize_floorplan -utilization 55 -aspect_ratio 1.0 -core_space 5 -site core7
make_tracks
# ---- pins on MET2 (vertical) / MET3 (horizontal)
place_pins -hor_layers MET3 -ver_layers MET2 -min_distance 2
# ---- well taps
tapcell -distance 40 -tapcell_master FILLTAPH7R
# ---- power grid: MET1 rails, MET4 vertical + MET5 horizontal straps
add_global_connection -net VDD -pin_pattern {^VDD$} -power
add_global_connection -net VSS -pin_pattern {^VSS$} -ground
global_connect
set_voltage_domain -power VDD -ground VSS
define_pdn_grid -name grid
add_pdn_stripe -grid grid -layer MET1 -width 0.20 -followpins
add_pdn_stripe -grid grid -layer MET4 -width 0.60 -pitch 28 -offset 6
add_pdn_stripe -grid grid -layer MET5 -width 0.60 -pitch 28 -offset 6
add_pdn_connect -grid grid -layers {MET1 MET4}
add_pdn_connect -grid grid -layers {MET4 MET5}
pdngen
# ---- placement
set_rc
set_routing_layers -signal MET2-MET5 -clock MET3-MET5
global_placement -density 0.62 -timing_driven -routability_driven
estimate_parasitics -placement
repair_design
detailed_placement
write_db 1_place.odb
rpt "after placement"
