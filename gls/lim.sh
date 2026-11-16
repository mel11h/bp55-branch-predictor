#!/bin/bash
# lim.sh <command...> : run a command in a transient systemd user scope with memory limits
# (MemoryHigh 5G, MemoryMax 7G by default; override MEMHIGH / MEMMAX), in the current directory,
# with the current PATH and the BP55 environment variables. Waits for the command and returns its status.
exec systemd-run --user --collect --wait --pipe --quiet --same-dir -p MemoryHigh=${MEMHIGH:-5G} -p MemoryMax=${MEMMAX:-7G} \
  -E PATH="$PATH" -E HOME="$HOME" ${BP55_ROOT:+-E BP55_ROOT="$BP55_ROOT"} ${YOSYS_CONFIG:+-E YOSYS_CONFIG="$YOSYS_CONFIG"} \
  ${OPT:+-E OPT="$OPT"} "$@"
