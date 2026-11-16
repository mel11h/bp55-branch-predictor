# Shared setup, copy of pnr/flow/common.tcl for the clock-gating runs (pnr/run_v2_cg).
# Changes: BP55_LIBDIR selects the Liberty directory (cg/lib = patched ICG cells, .lib or .lib.gz);
# BP55_CELL_LEF replaces the cell LEF (cg/lib/ics55_LLSC_H7CR_ecos_icgsig.lef, made by
# cg/patch_lef_icg_use.py: workaround for the OpenROAD getFirstOutput bug, see that script).
# Driven by environment variables, no absolute paths:
#   BP55_ROOT    repository root (source tools/env.sh, or set by pnr/flow/run.sh)
#   RUN_DIR      run directory; every .odb/.log/.rpt of the run goes there
#   BP55_SDC     constraint file (default: pnr/bp55.sdc)
#   BP55_PERIOD  clock period in ns, read by the SDC
#   NETLIST      place-and-route input netlist (1_place.tcl only)
set ROOT $::env(BP55_ROOT)
set PDK  $ROOT/pdk
set SC   $PDK/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR
# The release archive unpacks to <SC>/liberty/*.lib (PDK Makefile layout); the
# original machine had one extra level (<SC>/liberty/liberty). Accept both.
set LIBD $SC/liberty
if {[file isdirectory $LIBD/liberty]} { set LIBD $LIBD/liberty }
if {[info exists ::env(BP55_LIBDIR)] && $::env(BP55_LIBDIR) ne ""} { set LIBD $::env(BP55_LIBDIR) }
puts "liberty directory: [string map [list $ROOT/ {}] $LIBD]"
set RUN  $::env(RUN_DIR)
set SDC  [expr {[info exists ::env(BP55_SDC)] ? $::env(BP55_SDC) : "$ROOT/pnr/bp55.sdc"}]

proc load_tech {} {
  global PDK SC LIBD
  define_corners ss tt ff
  foreach {c f} {ss ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm tt ics55_LLSC_H7CR_typ_tt_1p2_25_nldm ff ics55_LLSC_H7CR_ff_rcbest_1p32_m40_nldm} {
    set lib $LIBD/$f.lib
    if {![file exists $lib]} { set lib $lib.gz }
    read_liberty -corner $c $lib
  }
  read_lef $PDK/prtech/techLEF/N551P6M_ecos.lef
  set cell_lef $SC/lef/ics55_LLSC_H7CR_ecos.lef
  if {[info exists ::env(BP55_CELL_LEF)] && $::env(BP55_CELL_LEF) ne ""} { set cell_lef $::env(BP55_CELL_LEF) }
  puts "cell LEF: [file tail $cell_lef]"
  read_lef $cell_lef
}

# Wire RC for placement-stage estimates: one layer's LEF values for all corners.
# The PDK ships only nominal per-layer R/C in the tech LEF and no RC-corner data,
# so there is nothing to make this corner dependent with.
proc set_rc {} {
  set_wire_rc -signal -layer MET3
  set_wire_rc -clock  -layer MET4
}

# The SDC reads ::bp55_io_ref_pin (see pnr/bp55.sdc). Before CTS it is empty;
# from CTS on it is the clock pin chosen by pick_io_ref_pin and stored in the run dir.
proc read_constraints {} {
  global SDC RUN
  set ::bp55_io_ref_pin ""
  if {[file exists $RUN/io_ref_pin.txt]} {
    set f [open $RUN/io_ref_pin.txt]; set ::bp55_io_ref_pin [string trim [read $f]]; close $f
  }
  puts "constraints: [file tail $SDC], period $::env(BP55_PERIOD) ns, IO reference pin '$::bp55_io_ref_pin'"
  read_sdc $SDC
}

# After CTS: the flop clock pin whose slow-corner clock arrival is the median of all
# flops. IO delays are referenced to it, so an input or output path is timed like a
# flop-to-flop path between this block and a core flop on the same clock tree.
proc pick_io_ref_pin {} {
  global RUN
  # build the timing graph first: the arrival property segfaults on an unbuilt graph
  report_worst_slack -max
  set arr {}
  # arrival_max_rise: latest rising clock arrival over all corners, i.e. the slow corner
  foreach p [get_pins -hierarchical */CK] {
    lappend arr [list [get_property $p arrival_max_rise] [get_full_name $p]]
  }
  set arr [lsort -real -index 0 $arr]
  set n [llength $arr]
  set med [lindex $arr [expr {$n / 2}]]
  puts [format "clock arrival at %d flop CK pins (ss): min %.3f median %.3f max %.3f ns -> IO reference %s" \
          $n [lindex $arr 0 0] [lindex $med 0] [lindex $arr end 0] [lindex $med 1]]
  set f [open $RUN/io_ref_pin.txt w]; puts $f [lindex $med 1]; close $f
  return [lindex $med 1]
}

proc rpt {tag} {
  puts "==== $tag ===="
  foreach c {ss tt ff} {
    puts "-- corner $c"
    report_checks -corner $c -path_delay max -group_count 1 -format end
    report_checks -corner $c -path_delay min -group_count 1 -format end
  }
  foreach c {ss tt ff} {
    puts "corner $c: worst setup slack [sta::format_time [sta::worst_slack_corner [sta::find_corner $c] max] 3] ns, worst hold slack [sta::format_time [sta::worst_slack_corner [sta::find_corner $c] min] 3] ns"
  }
  report_tns
  report_design_area
}

# Clock-gating report (clock-gating runs only): ICG count and the worst enable
# (clock-gating check) setup and hold slack per corner.
proc cg_report {} {
  set icgs [get_cells -quiet -filter "ref_name =~ ICG*" *]
  puts "==== clock gating: [llength $icgs] ICG instances"
  if {[llength $icgs] == 0} return
  set en {}
  foreach i $icgs { lappend en [get_pins [get_full_name $i]/E] }
  foreach c {ss tt ff} {
    puts "-- corner $c, ICG enable pins"
    report_checks -corner $c -path_delay max -to $en -group_count 1 -format end
    report_checks -corner $c -path_delay min -to $en -group_count 1 -format end
  }
}
