# Power of a routed BP55 layout, typical corner, default activity and SAIF activity.
# env: BP55_ROOT, ODB (5_final.odb), SPEF (routed-wire SPEF from def2spef.py), BP55_SDC,
#      BP55_PERIOD, IO_REF_FILE (optional), LIBDIR (Liberty directory, .lib or .lib.gz),
#      SAIFS (space-separated list of SAIF files, optional), SAIF_SCOPE (instance path of bp55 in
#      the SAIF, default bp55)
# One report per activity source: report_power groups (Sequential / Combinational / Clock) with
# internal, switching and leakage columns, plus the ICG cells and the clock-tree buffers alone.
set LIBD $::env(LIBDIR)
set SC $::env(BP55_ROOT)/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR
define_corners tt
set lib $LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib
if {![file exists $lib]} { set lib $lib.gz }
read_liberty -corner tt $lib
read_db $::env(ODB)
read_spef -corner tt $::env(SPEF)
set ::bp55_io_ref_pin ""
if {[info exists ::env(IO_REF_FILE)] && [file exists $::env(IO_REF_FILE)]} {
  set f [open $::env(IO_REF_FILE)]; set ::bp55_io_ref_pin [string trim [read $f]]; close $f
}
read_sdc $::env(BP55_SDC)
set_propagated_clock [all_clocks]

proc pw {tag} {
  puts "==== power: $tag"
  report_power -corner tt -digits 4
  set icg [get_cells -quiet -filter "ref_name =~ ICG*" *]
  set ckb {}
  foreach c [get_cells *] {
    set n [get_full_name $c]
    if {[string match "clkbuf_*" $n] || [string match "clkload*" $n] || [string match "delaybuf_*" $n]} { lappend ckb $c }
  }
  if {[llength $icg]} { puts "-- ICG cells ([llength $icg])"; report_power -corner tt -digits 4 -instances $icg }
  if {[llength $ckb]} { puts "-- clock-tree buffers ([llength $ckb], clkbuf_* / clkload* / delaybuf_*)"; report_power -corner tt -digits 4 -instances $ckb }
}
pw "default activity (OpenSTA defaults: inputs 0.1 toggles/cycle, clock from the SDC)"
if {[info exists ::env(SAIFS)]} {
  set scope [expr {[info exists ::env(SAIF_SCOPE)] ? $::env(SAIF_SCOPE) : "bp55"}]
  foreach s $::env(SAIFS) {
    puts "==== reading SAIF [file tail $s], scope $scope"
    read_saif -scope $scope $s
    pw "SAIF [file tail $s]"
  }
}
