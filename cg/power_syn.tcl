# Synthesis-netlist power (OpenSTA, typical corner, no wires, ideal clock: no clock tree),
# default activity and SAIF activity. Used to compare the gating granularities before layout.
# env: LIBDIR, NETLIST, BP55_SDC, BP55_PERIOD, SAIF (optional), SAIF_SCOPE (default TOP/bp55)
set lib $::env(LIBDIR)/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib
if {![file exists $lib]} { set lib $lib.gz }
read_liberty $lib
read_verilog $::env(NETLIST)
link_design bp55
set ::bp55_io_ref_pin ""
read_sdc $::env(BP55_SDC)
puts "==== power: default activity"
report_power -digits 4
if {[info exists ::env(SAIF)] && $::env(SAIF) ne ""} {
  set scope [expr {[info exists ::env(SAIF_SCOPE)] ? $::env(SAIF_SCOPE) : "TOP/bp55"}]
  read_saif -scope $scope $::env(SAIF)
  puts "==== power: SAIF [file tail $::env(SAIF)]"
  report_power -digits 4
}
