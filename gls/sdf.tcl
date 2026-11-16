# OpenSTA: write a slow-corner SDF for a routed netlist with its routed-wire SPEF.
# env: BP55_ROOT, SDF_NETLIST, SDF_SPEF, SDF_OUT, BP55_PERIOD (default 6.0), BP55_SDC (default pnr/bp55.sdc),
#      IO_REF_FILE (optional, the IO reference pin chosen by the layout flow)
# The SPEF is the lumped routed-wire RC of pnr/flow/def2spef.py (not a sign-off extraction).
set LIBD $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty
read_liberty $LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib
read_verilog $::env(SDF_NETLIST)
link_design bp55
read_spef $::env(SDF_SPEF)
if {![info exists ::env(BP55_PERIOD)]} { set ::env(BP55_PERIOD) 6.0 }
set ::bp55_io_ref_pin ""
if {[info exists ::env(IO_REF_FILE)] && [file exists $::env(IO_REF_FILE)]} {
  set f [open $::env(IO_REF_FILE)]; set ::bp55_io_ref_pin [string trim [read $f]]; close $f
}
set sdc [expr {[info exists ::env(BP55_SDC)] ? $::env(BP55_SDC) : "$::env(BP55_ROOT)/pnr/bp55.sdc"}]
read_sdc $sdc
set_propagated_clock [all_clocks]
report_checks -path_delay max -format end
report_checks -path_delay min -format end
report_worst_slack -max
report_worst_slack -min
write_sdf -divider . -digits 4 $::env(SDF_OUT)
puts "wrote $::env(SDF_OUT)"
