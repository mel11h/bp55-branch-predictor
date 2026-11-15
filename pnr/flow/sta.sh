#!/bin/bash
# Routed-wire multi-corner STA of a finished run (pnr/flow/sta_routed.tcl) without
# re-extracting. usage: pnr/flow/sta.sh <run_dir> <log name> [spef.gz]
# env: BP55_SDC, BP55_PERIOD, PICK_IO_REF
set -e
here="$(cd "$(dirname "$0")" && pwd)"
export BP55_ROOT="${BP55_ROOT:-$(cd "$here/../.." && pwd)}"
run="$(cd "$1" && pwd)"; log="$2"; spef="${3:-5_final.spef.gz}"
: "${BP55_PERIOD:=6.0}"; export BP55_PERIOD
export BP55_SDC="$(cd "$(dirname "${BP55_SDC:-$BP55_ROOT/pnr/bp55.sdc}")" && pwd)/$(basename "${BP55_SDC:-bp55.sdc}")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
zcat "$run/5_final.v.gz" > "$tmp/n.v"; zcat "$run/$spef" > "$tmp/p.spef"
STA_NETLIST="$tmp/n.v" STA_SPEF="$tmp/p.spef" IO_REF_FILE="$run/io_ref_pin.txt" PICK_IO_REF="${PICK_IO_REF:-0}" \
systemd-run --user --collect -q --wait --pipe -p MemoryHigh=5G -p MemoryMax=6G -p MemorySwapMax=0 \
    --working-directory="$run" -E BP55_ROOT -E BP55_SDC -E BP55_PERIOD -E STA_NETLIST -E STA_SPEF -E IO_REF_FILE -E PICK_IO_REF \
    openroad -threads 1 -no_init -exit "$here/sta_routed.tcl" > "$run/$log" 2>&1 || true
sed -i -e "s#$BP55_ROOT/##g" -e "s#$run/##g" -e "s#$tmp/##g" "$run/$log"
grep -A3 "==== summary" "$run/$log"
