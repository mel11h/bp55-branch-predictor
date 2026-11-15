#!/bin/bash
# Write the human-readable DRC/antenna summary, the .gitignore and MANIFEST.txt of a run.
# usage: pnr/flow/reports.sh <run_dir> <sdc file name> <period ns>
r="$(cd "$1" && pwd)"; sdc="$2"; per="$3"
cd "$r"
{
  echo "Router DRC and antenna summary for $(basename "$r")"
  echo
  echo "4_drt_drc.rpt: $(stat -c %s 4_drt_drc.rpt 2>/dev/null || echo missing) bytes. detailed_route -output_drc writes only violation markers,"
  echo "so an empty file means no violations at the end of routing. Iteration history from 3_route.log:"
  grep -E "DRT-0195|DRT-0199" 3_route.log | sed 's/^/  /'
  echo
  echo "8_drc_unfilled.rpt / 8_drc_filled.rpt (drt::check_drc on 5_final.odb before and after density_fill):"
  for f in 8_drc_unfilled.rpt 8_drc_filled.rpt; do [ -f $f ] && echo "  $f: $(stat -c %s $f) bytes, $(grep -c 'violation type' $f 2>/dev/null) violations"; done
  echo "  Whether the DRT checker treats fill shapes as obstacles in this OpenROAD build is not documented;"
  echo "  fill-to-metal and fill-to-fill spacing is checked independently on the merged GDS (8_fill_check.txt)."
  echo
  echo "antenna.rpt: $(stat -c %s antenna.rpt 2>/dev/null || echo missing) bytes. check_antennas result from 3_route.log:"
  grep -E "ANT-000[12]" 3_route.log | sed 's/^/  /'
  echo "  This check is vacuous: the PDK tech LEF has no ANTENNA* ratio rules and the cell LEF used by the flow"
  echo "  (ics55_LLSC_H7CR_ecos.lef) has no ANTENNAGATEAREA/ANTENNADIFFAREA (see pnr/pdk_inventory.txt)."
  echo "  The foundry antenna rules exist only as the Calibre deck pv/DRC/*.ant."
} > 4_drc_antenna_summary.txt
cat > .gitignore <<'E'
# large or regenerable outputs of this run; logs, reports and the gzipped netlist are kept
*.odb
*.def
*.def.gz
*.spef
*.spef.gz
*.gds
*.gds.gz
5_final.v
E
f() { for x in "$@"; do [ -e "$x" ] && printf '  %-22s %s\n' "$x" "$(stat -c %s "$x") bytes"; done; }
{
  echo "MANIFEST of $(basename "$r") (paths relative to this directory; not in git: see .gitignore)"
  echo "constraints: pnr/$sdc, BP55_PERIOD=$per ns; IO reference pin file: io_ref_pin.txt (read by the SDC as ::bp55_io_ref_pin)"
  echo "PDK: pdk/ (tech LEF prtech/techLEF/N551P6M_ecos.lef, cells ics55_LLSC_H7CR_ecos.lef, GDS ics55_LLSC_H7CR.gds)"
  echo "GDS layer map for the merged GDS: klayout.map (drawn metal <L>;1, fill <L>;2, pin text <L>;6)"
  echo
  echo "unfilled (final routed design, fillers placed):"
  f 5_final.odb 5_final.def.gz 5_final.v.gz 5_final.spef.gz bp55.gds.gz
  echo "filled (density_fill on 5_final.odb, rules pnr/flow/fill_rules.json):"
  f 8_fill.odb 8_fill.def.gz bp55_fill.gds.gz 8_fill.spef.gz
  echo "netlist: 5_final.v.gz is the same for unfilled and filled (fill adds no instances or nets)."
  echo "SPEF: lumped routed-wire extraction (pnr/flow/def2spef.py), no coupling, fill not included."
  echo "reports: 6_sta_routed.log (final STA), 9_sta_routed_filled.log, density_unfilled.txt, density_filled.txt,"
  echo "         8_fill_check.txt, 4_drc_antenna_summary.txt"
} > MANIFEST.txt
cat MANIFEST.txt
