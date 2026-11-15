#!/bin/bash
# Setup/hold sensitivity to the extracted capacitance: all C (ground and coupling) scaled by
# 0.8 and 1.2 in all three corners, R unchanged, STA rerun.
# usage: rcx/scripts/sensitivity.sh <results dir with bp55_<corner>.spef.gz> <netlist> <sdc> [factors]
# env: BP55_PERIOD, IO_REF_FILE (as for run_rcx.sh). The scaled SPEFs are deleted afterwards.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
d="$(cd "$1" && pwd)"; net="$2"; sdc="$3"
for f in ${4:-0.8 1.2}; do
  s="$d/cscale_$f"; mkdir -p "$s"
  for c in rcworst typ rcbest; do
    "${PYTHON:-/usr/bin/python3}" -I "$here/scale_spef.py" "$d/bp55_$c.spef.gz" "$s/bp55_$c.spef.gz" "$f"
  done
  [ -f "$d/io_ref_pin.txt" ] && cp "$d/io_ref_pin.txt" "$s/"
  SKIP_EXTRACT=1 IO_REF_FILE="${IO_REF_FILE:-$s/io_ref_pin.txt}" "$here/../run_rcx.sh" "$d/bp55_typ.spef.gz" "$net" "$sdc" "$s"
  rm -f "$s"/bp55_*.spef.gz
done
