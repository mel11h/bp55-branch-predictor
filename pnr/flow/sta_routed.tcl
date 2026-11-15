# Multi-corner STA of a routed netlist with the parasitics of its routed wires
# (SPEF from pnr/flow/def2spef.py). Run with openroad -threads 1 (the standalone sta 2.6.0
# binary on this machine segfaults on the pin arrival query used by PICK_IO_REF).
# env: BP55_ROOT, STA_NETLIST, STA_SPEF, BP55_SDC, BP55_PERIOD, IO_REF_FILE (optional)
set LIBD $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty
define_corners ss tt ff
read_liberty -corner ss $LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib
read_liberty -corner tt $LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib
read_liberty -corner ff $LIBD/ics55_LLSC_H7CR_ff_rcbest_1p32_m40_nldm.lib
if {[llength [info commands read_lef]]} {
  set SC $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR
  read_lef $::env(BP55_ROOT)/pdk/prtech/techLEF/N551P6M_ecos.lef
  read_lef $SC/lef/ics55_LLSC_H7CR_ecos.lef
}
read_verilog $::env(STA_NETLIST)
link_design bp55
# no RC-corner data in the PDK: the same routed-wire parasitics for all three corners
foreach c {ss tt ff} { read_spef -corner $c $::env(STA_SPEF) }
set ::bp55_io_ref_pin ""
if {[info exists ::env(IO_REF_FILE)] && [file exists $::env(IO_REF_FILE)]} {
  set f [open $::env(IO_REF_FILE)]; set ::bp55_io_ref_pin [string trim [read $f]]; close $f
}
puts "constraints [file tail $::env(BP55_SDC)], period $::env(BP55_PERIOD) ns, IO reference pin '$::bp55_io_ref_pin'"
read_sdc $::env(BP55_SDC)
set_propagated_clock [all_clocks]
# PICK_IO_REF=1: choose the IO reference pin here (median slow-corner flop clock arrival),
# for layouts that were not built with this flow (the committed layout)
if {$::bp55_io_ref_pin eq "" && [info exists ::env(PICK_IO_REF)] && $::env(PICK_IO_REF)} {
  # build the timing graph first: the arrival property segfaults on an unbuilt graph
  report_worst_slack -max
  set arr {}
  foreach p [get_pins -hierarchical */CK] { lappend arr [list [get_property $p arrival_max_rise] [get_full_name $p]] }
  set arr [lsort -real -index 0 $arr]
  set med [lindex $arr [expr {[llength $arr] / 2}]]
  puts [format "clock arrival at %d flop CK pins (max over corners): min %.3f median %.3f max %.3f ns -> IO reference %s" \
        [llength $arr] [lindex $arr 0 0] [lindex $med 0] [lindex $arr end 0] [lindex $med 1]]
  set ::bp55_io_ref_pin [lindex $med 1]
  read_sdc $::env(BP55_SDC)
  set_propagated_clock [all_clocks]
}
report_parasitic_annotation -report_unannotated
puts "==== summary"
foreach c {ss tt ff} {
  set cn [sta::find_corner $c]
  puts [format "corner %s: setup WNS %7.3f ns TNS %8.3f ns | hold WNS %7.3f ns TNS %8.3f ns" $c \
    [sta::time_sta_ui [sta::worst_slack_corner $cn max]] [sta::time_sta_ui [sta::total_negative_slack_corner_cmd $cn max]] \
    [sta::time_sta_ui [sta::worst_slack_corner $cn min]] [sta::time_sta_ui [sta::total_negative_slack_corner_cmd $cn min]]]
}
foreach c {ss tt ff} {
  puts "==== corner $c: worst setup and hold endpoints"
  report_checks -corner $c -path_delay max -group_count 5 -format end -digits 3
  report_checks -corner $c -path_delay min -group_count 5 -format end -digits 3
}
puts "==== hold-violating endpoints per corner"
foreach c {ss tt ff} {
  set n [llength [find_timing_paths -corner $c -path_delay min -slack_max 0 -group_count 100000 -endpoint_count 1]]
  puts "corner $c: $n endpoints with hold slack < 0"
}
puts "==== clock network"
foreach c {ss tt ff} { report_clock_latency -corner $c -digits 3 }
foreach c {ss tt ff} { report_clock_skew -corner $c -digits 3 }
puts "==== critical path, slow corner"
report_checks -corner ss -path_delay max -path_group clk -fields {slew cap fanout} -digits 3 -format full_clock_expanded
puts "==== critical register-to-register path, slow corner"
report_checks -corner ss -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3 -format full_clock
puts "==== worst hold path, slow and fast corner"
report_checks -corner ss -path_delay min -digits 3 -format full_clock
report_checks -corner ff -path_delay min -digits 3 -format full_clock
puts "==== power, typical corner, default activity"
report_power -corner tt -digits 4
