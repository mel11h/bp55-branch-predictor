#!/bin/bash
# One-command open-tool DRC + antenna + LVS for a BP55 GDS / netlist pair (NOT foundry sign-off).
#
# usage: signoff/run_signoff.sh --gds LAYOUT.gds[.gz] --verilog NETLIST.v[.gz] --out DIR
#                               [--top bp55] [--steps drc,antenna,lvs] [--threads 2]
#
# Every heavy step runs under systemd-run with MemoryHigh=5G/MemoryMax=7G and waits until at
# least 4 GB of memory are available. Outputs in DIR: *.log (with /usr/bin/time -v, so peak RSS
# is "Maximum resident set size"), drc_summary.tsv, antenna_summary.tsv, lvs.log, compressed
# report databases (*.lyrdb.gz, *.lvsdb.gz).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
top=bp55; steps=drc,antenna,lvs; threads=2; gds=; vlog=; out=
while [ $# -gt 0 ]; do
  case $1 in
    --gds) gds=$(realpath "$2"); shift 2 ;;
    --verilog) vlog=$(realpath "$2"); shift 2 ;;
    --out) mkdir -p "$2"; out=$(realpath "$2"); shift 2 ;;
    --top) top=$2; shift 2 ;;
    --steps) steps=$2; shift 2 ;;
    --threads) threads=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
[ -n "$gds" ] && [ -n "$out" ] || { echo "need --gds and --out"; exit 2; }
CDL=$root/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/cdl/ics55_LLSC_H7CR.cdl

waitmem() {   # wait until MemAvailable >= 4 GB
  while [ "$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)" -lt 4 ]; do
    echo "$(date +%T) waiting for memory (available < 4 GB)"; sleep 60
  done
}
run() {       # run LOG cmd...  (memory-capped, timed)
  local log=$1; shift
  waitmem
  systemd-run --user --collect --wait -P -p MemoryHigh=5G -p MemoryMax=7G --working-directory="$out" \
    /usr/bin/time -v "$@" > "$log" 2>&1 || echo "step failed, see $log"
  grep -E "Elapsed \(wall|Maximum resident" "$log" | sed 's/^\s*/  /'
}
has() { [[ ",$steps," == *",$1,"* ]]; }

echo "layout $gds  top $top  out $out"
if has drc; then
  echo "== DRC"
  run "$out/drc.log" klayout -b -r "$here/drc/icsprout55_drc.drc" -rd gds="$gds" -rd top="$top" \
      -rd report="$out/drc.lyrdb" -rd density_log="$out/density.log" -rd threads="$threads"
  python3 "$here/tools/rdb_summary.py" "$out/drc.lyrdb" 3 > "$out/drc_summary.tsv"
  gzip -f "$out/drc.lyrdb"
  awk -F'\t' '$2>0{printf "  %-22s %s\n", $1, $2}' "$out/drc_summary.tsv"
fi
if has antenna; then
  echo "== antenna"
  run "$out/antenna.log" klayout -b -r "$here/drc/icsprout55_antenna.drc" -rd gds="$gds" -rd top="$top" \
      -rd report="$out/antenna.lyrdb" -rd threads="$threads"
  python3 "$here/tools/rdb_summary.py" "$out/antenna.lyrdb" 3 > "$out/antenna_summary.tsv"
  gzip -f "$out/antenna.lyrdb"
  awk -F'\t' '{printf "  %-22s %s\n", $1, $2}' "$out/antenna_summary.tsv"
fi
if has lvs; then
  [ -n "$vlog" ] || { echo "LVS needs --verilog"; exit 2; }
  echo "== LVS"
  python3 "$here/tools/cdl_flatten.py" "$CDL" "$out/cells_flat.sp" 2>/dev/null
  python3 "$here/tools/verilog2spice.py" "$vlog" "$out/cells_flat.sp" "$out/top.sp" --top "$top"
  python3 "$here/tools/prune_spice.py" "$out/cells_flat.sp" "$out/top.sp.cells" "$out/cells_used.sp"
  cat "$out/cells_used.sp" "$out/top.sp" > "$out/schematic.sp"
  # KLayout extracts the device netlist; netgen compares (the KLayout 0.28.16 comparer stops with an
  # internal assertion on the full block)
  run "$out/lvs_extract.log" klayout -b -r "$here/lvs/icsprout55_lvs.lvs" -rd gds="$gds" -rd top="$top" \
      -rd schematic="$out/schematic.sp" -rd report="$out/lvs.lvsdb" -rd compare=0 -rd netlist_out="$out/layout.cir" -rd threads="$threads"
  grep -E "supply|well-tie" "$out/lvs_extract.log" | sed 's/^/  /'
  run "$out/lvs_netgen.log" "$here/lvs/netgen_lvs.sh" "$out/layout.cir" "$out/schematic.sp" "$top" "$out/netgen"
  grep -E "Netlists|Final result" "$out/netgen/netgen_lvs.out" | sed 's/^/  /'
  run "$out/lvs_cell_level.log" "$here/lvs/cell_level_lvs.sh" "$out/layout.cir" "$vlog" "$top" "$out/cell_level"
  tail -3 "$out/lvs_cell_level.log" | sed 's/^/  /'
  rm -f "$out/lvs.lvsdb" "$out"/netgen/*.cir "$out"/netgen/*.sp "$out"/cell_level/*.cir "$out"/cell_level/*.sp
  gzip -f "$out/layout.cir" "$out/netgen/netgen_lvs.out" "$out/cell_level/netgen_cell_level.out"
  rm -f "$out/cells_flat.sp" "$out/cells_used.sp" "$out/top.sp" "$out/top.sp.cells"; gzip -f "$out/schematic.sp" "$out/top.sp.netmap"
fi
