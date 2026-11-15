# Paths: BP55_ROOT (source tools/env.sh) or, if unset, the repository this file is in.
# (originally absolute paths under /home/user/bp55)
set PDK [expr {[info exists ::env(BP55_ROOT)] ? "$::env(BP55_ROOT)/pdk" : [file normalize [file dirname [info script]]/../pdk]}]
set SC  $PDK/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR
# the PDK Makefile unpacks the Liberty archive to <SC>/liberty, the original machine had <SC>/liberty/liberty
set LIBD $SC/liberty
if {[file isdirectory $LIBD/liberty]} { set LIBD $LIBD/liberty }
proc load_tech {} {
  global PDK SC LIBD
  define_corners ss tt ff
  read_liberty -corner ss $LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib
  read_liberty -corner tt $LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib
  read_liberty -corner ff $LIBD/ics55_LLSC_H7CR_ff_rcbest_1p32_m40_nldm.lib
  read_lef $PDK/prtech/techLEF/N551P6M_ecos.lef
  read_lef $SC/lef/ics55_LLSC_H7CR_ecos.lef
}
proc set_rc {} {
  set_wire_rc -signal -layer MET3
  set_wire_rc -clock  -layer MET4
}
proc rpt {tag} {
  puts "==== $tag ===="
  foreach c {ss tt ff} {
    puts "-- corner $c"
    catch {report_checks -corner $c -path_delay max -group_path_count 1 -format end}
    catch {report_checks -corner $c -path_delay min -group_path_count 1 -format end}
  }
  report_worst_slack -max
  report_worst_slack -min
  report_tns
  report_design_area
}
