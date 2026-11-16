#!/bin/bash
# Run one or more flow stages for one run directory, each OpenROAD call under a hard
# memory cap (systemd user scope) and with at most 6 threads. Copy of pnr/flow/run.sh;
# differences: scripts from this directory, BP55_LIBDIR / BP55_CTS_ARGS passed through,
# defaults THREADS 6, MemoryHigh 8G, MemoryMax 10G, and it waits for free memory first.
#
# usage: pnr/run_v2_cg/scripts/run.sh <run_dir> <stage>...      stages: 1_place 2_cts 3_route 4_sta ...
# env:   NETLIST (1_place), BP55_SDC, BP55_PERIOD, BP55_IO_REF (1 = IO delays referenced
#        to a post-CTS flop clock pin, see pnr/bp55.sdc), THREADS (default 6),
#        MEM_HIGH / MEM_MAX (default 8G / 10G), MEM_WAIT_GB (default 6), OPENROAD_LIBS (extra LD_LIBRARY_PATH)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
export BP55_ROOT="${BP55_ROOT:-$(cd "$here/../../.." && pwd)}"
run="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
export RUN_DIR="$run"
: "${BP55_PERIOD:=6.0}"; export BP55_PERIOD
: "${BP55_IO_REF:=0}"; export BP55_IO_REF
threads="${THREADS:-6}"
for st in "$@"; do
  echo "[$(date +%H:%M:%S)] $st in $run (period $BP55_PERIOD, sdc ${BP55_SDC:-pnr/bp55.sdc})"
  df -h /home | tail -1
  envs=(-E BP55_ROOT -E RUN_DIR -E BP55_PERIOD -E BP55_IO_REF -E PATH -E BP55_LIBDIR="${BP55_LIBDIR:-}" -E BP55_CTS_ARGS="${BP55_CTS_ARGS:-}" -E BP55_CTS_PRE="${BP55_CTS_PRE:-}" -E BP55_CELL_LEF="${BP55_CELL_LEF:-}")
  [ -n "$SKIP_BUFFER_REMOVAL" ] && envs+=(-E SKIP_BUFFER_REMOVAL="$SKIP_BUFFER_REMOVAL")
  [ -n "$NETLIST" ] && envs+=(-E NETLIST="$(cd "$(dirname "$NETLIST")" && pwd)/$(basename "$NETLIST")")
  [ -n "$BP55_SDC" ] && envs+=(-E BP55_SDC="$(cd "$(dirname "$BP55_SDC")" && pwd)/$(basename "$BP55_SDC")")
  [ -n "$OPENROAD_LIBS" ] && envs+=(-E LD_LIBRARY_PATH="$OPENROAD_LIBS")
  # run a snapshot of the stage script: OpenROAD reads a script incrementally, so editing
  # the stage scripts while a stage runs corrupted the rest of that stage (seen twice)
  mkdir -p "$run/scripts"; cp "$here/$st.tcl" "$here/common.tcl" "$run/scripts/"
  # wait for memory: 6 GB available before placement/CTS/routing (machine-wide rule)
  while :; do
    avail=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
    [ "$avail" -ge "${MEM_WAIT_GB:-6}" ] && break
    echo "[$(date +%H:%M:%S)] waiting for memory: ${avail} GB available"; sleep 120
  done
  echo "[$(date +%H:%M:%S)] memory available: ${avail} GB"
  t0=$(date +%s)
  set +e
  systemd-run --user --collect -q --wait --pipe \
      -p MemoryHigh="${MEM_HIGH:-8G}" -p MemoryMax="${MEM_MAX:-10G}" -p MemorySwapMax=0 \
      --working-directory="$run" "${envs[@]}" \
      openroad -threads "$threads" -no_init -exit "$run/scripts/$st.tcl" > "$run/$st.log" 2>&1
  rc=$?
  set -e
  # keep the logs free of machine-specific paths
  sed -i -e "s#$BP55_ROOT/##g" "$run/$st.log"
  echo "[$(date +%H:%M:%S)] $st exit $rc after $(( $(date +%s) - t0 )) s"
  [ $rc = 0 ] || exit $rc
done
