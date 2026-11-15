#!/bin/bash
# Extract a detailed-routed BP55 layout with the rcx/ rules in three RC corners and run
# three-corner STA on the SPEF (ss<-rcworst, tt<-typ, ff<-rcbest).
#
# usage: rcx/run_rcx.sh <layout .def|.def.gz|.odb> <netlist .v|.v.gz> <sdc> <out_dir>
# env:   BP55_PERIOD   clock period read by the SDC (default 6.2)
#        IO_REF_FILE   IO reference pin for pnr/bp55.sdc; if missing it is chosen (median
#                      slow-corner flop clock arrival) and written (default <out_dir>/io_ref_pin.txt)
#        ESTIMATE=1    also run the published estimated-parasitics STA on the same layout + SDC
#                      and write its parasitics as SPEF (for rcx/scripts/compare_spef.py)
#        SKIP_EXTRACT=1  no extraction (an existing bp55_<corner>.spef.gz is always reused)
#        RULES_DIR     rules directory (default rcx/rules)
# Every OpenROAD call runs in a memory-capped user scope and waits for 4 GB of free memory.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
export BP55_ROOT="${BP55_ROOT:-$(cd "$here/.." && pwd)}"
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
layout="$(abs "$1")"; netlist="$(abs "$2")"; sdc="$(abs "$3")"
mkdir -p "$4"; out="$(cd "$4" && pwd)"
rules="${RULES_DIR:-$here/rules}"
export BP55_PERIOD="${BP55_PERIOD:-6.2}"
export IO_REF_FILE="${IO_REF_FILE:-$out/io_ref_pin.txt}"
OR_LIBS="${OPENROAD_LIBS:-}"

memwait() {
  while [ "$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)" -lt ${MEM_MIN_GB:-4} ]; do
    echo "[$(date +%H:%M:%S)] waiting for 4 GB available memory"; sleep 30
  done
}
orun() { # <log> <tcl> [env names...]
  local log="$1" tcl="$2"; shift 2
  local envs=(-E BP55_ROOT -E PATH)
  for e in "$@"; do envs+=(-E "$e"); done
  [ -n "$OR_LIBS" ] && envs+=(-E LD_LIBRARY_PATH="$OR_LIBS")
  memwait
  systemd-run --user --collect -q --wait --pipe -p MemoryHigh=${MEM_HIGH:-5G} -p MemoryMax=${MEM_MAX:-7G} -p MemorySwapMax=0 \
      --working-directory="$out" "${envs[@]}" openroad -threads 4 -no_init -exit "$tcl" > "$log" 2>&1
  local rc=$?
  sed -i -e "s#$BP55_ROOT/##g" -e "s#$out/##g" "$log"
  return $rc
}

if [ -z "$SKIP_EXTRACT" ]; then
  for c in rcworst typ rcbest; do
    [ -s "$out/bp55_$c.spef.gz" ] && { echo "keep existing $out/bp55_$c.spef.gz"; continue; }
    echo "[$(date +%H:%M:%S)] extract $c"
    export RCX_LAYOUT="$layout" RCX_RULES="$rules/bp55_$c.rules" RCX_SPEF="$out/bp55_$c.spef"
    orun "$out/extract_$c.log" "$here/scripts/extract.tcl" RCX_LAYOUT RCX_RULES RCX_SPEF
    gzip -f "$out/bp55_$c.spef"
  done
fi

echo "[$(date +%H:%M:%S)] sta on extracted parasitics ($(basename "$sdc"), $BP55_PERIOD ns)"
export STA_MODE=spef BP55_SDC="$sdc" STA_NETLIST="$netlist" STA_LAYOUT="$layout" \
  STA_SPEF_SS="$out/bp55_rcworst.spef.gz" STA_SPEF_TT="$out/bp55_typ.spef.gz" STA_SPEF_FF="$out/bp55_rcbest.spef.gz"
tag="$(basename "$sdc" .sdc)_$BP55_PERIOD"
orun "$out/sta_rcx_$tag.log" "$here/scripts/sta.tcl" STA_MODE BP55_SDC BP55_PERIOD STA_NETLIST STA_LAYOUT \
  STA_SPEF_SS STA_SPEF_TT STA_SPEF_FF IO_REF_FILE || true
grep -A3 "==== summary" "$out/sta_rcx_$tag.log" || tail -20 "$out/sta_rcx_$tag.log"

if [ "${ESTIMATE:-0}" = 1 ]; then
  echo "[$(date +%H:%M:%S)] sta on estimated parasitics (published method)"
  export STA_MODE=estimate STA_EST_SPEF="$out/estimate_$tag.spef"
  orun "$out/sta_est_$tag.log" "$here/scripts/sta.tcl" STA_MODE BP55_SDC BP55_PERIOD STA_LAYOUT \
    IO_REF_FILE STA_EST_SPEF || true
  # estimate_parasitics writes one file per corner (estimate_<tag>_<corner>.spef), all identical
  # (one set_wire_rc for all corners): keep one, compressed, as estimate.spef.gz
  if [ -f "$out/estimate_${tag}_ss.spef" ]; then
    mv "$out/estimate_${tag}_ss.spef" "$out/estimate.spef"; rm -f "$out/estimate_${tag}"_*.spef
    gzip -f "$out/estimate.spef"
  fi
  grep -A3 "==== summary" "$out/sta_est_$tag.log" || tail -20 "$out/sta_est_$tag.log"
fi
