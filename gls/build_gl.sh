#!/bin/bash
# build_gl.sh <netlist .v|.v.gz | rtl:<rev>> <tag> <harness v1|v2>
#   Builds gls/build/<tag>/cosim: the gate netlist (or, with rtl:<rev>, the RTL of git revision <rev>,
#   rtl:WORKTREE for rtl/bp55.sv) compiled with Yosys write_cxxrtl together with the PDK cell models
#   (gls/build/cells_gl.v from gls/mkcells.py) and linked with the co-simulation harness:
#     v2: gls/mkharness.py applied to sim/cosim.cc + sim/bp_model.h of the working tree
#     v1: git show 8ff8f15:sim/cosim.cc and 8ff8f15:sim/bp_model.h, unchanged
#   Yosys passes on the netlist: hierarchy; proc (UDP replacements and cell bodies); flatten;
#   opt_clean; opt_expr (constant folding: the cells' supply1 set/reset pins); opt_dff -nodffe -nosdff
#   (a flop whose async set/reset is constant-inactive becomes a plain $dff / $adff; no enable or
#   sync-reset merging); opt_clean. The opt_expr/opt_dff step is required, not cosmetic: Yosys 0.69
#   write_cxxrtl emits $dffsr (async set + reset, what the UDP-derived flop model is before constant
#   folding) as "q.next = q.curr.update(...)" after the clocked "q.next = d", which discards the
#   clocked update, so every flop holds its value forever. The build fails if that pattern appears.
#   write_cxxrtl runs at -O4 for netlists (CXXRTL_O): public nets stay member variables instead of
#   being inlined into one expression per output, which at the default -O6 makes g++ need more than
#   7.5 GB for a flattened 80k-cell netlist.
#   Env: OPT (C++ optimisation level, default -O1), CXXRTL_O, CXXRTL_INC or YOSYS_CONFIG.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"
net=$1; tag=$2; h=$3
case $net in rtl:*) ;; *) net="$(cd "$(dirname "$net")" && pwd)/$(basename "$net")" ;; esac
B="$here/build/$tag"; mkdir -p "$B"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
if [ -z "${CXXRTL_INC:-}" ]; then
  YC=${YOSYS_CONFIG:-$(command -v yosys-config)}
  CXXRTL_INC=$("$YC" --datdir)/include/backends/cxxrtl/runtime
fi
case $net in
  rtl:WORKTREE) cp "$BP55_ROOT/rtl/bp55.sv" design.sv
                PASSES="read_verilog -sv design.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt" ;;
  rtl:*) git -C "$BP55_ROOT" show "${net#rtl:}:rtl/bp55.sv" > design.sv
         PASSES="read_verilog -sv design.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt" ;;
  *) [ -f "$here/build/cells_gl.v" ] || python3 "$here/mkcells.py" "$PDKV" "$here/build/cells_gl.v"
     case $net in *.gz) zcat "$net" > design.v ;; *) cp "$net" design.v ;; esac
     PASSES="read_verilog $here/build/cells_gl.v; read_verilog design.v; hierarchy -check -top bp55; proc; flatten; opt_clean; opt_expr; opt_dff -nodffe -nosdff; opt_clean; stat; write_cxxrtl ${CXXRTL_O:--O4} bp55_rtl.cc" ;;
esac
case $h in
  v2) python3 "$here/mkharness.py" "$BP55_ROOT/sim/cosim.cc" cosim.cc; cp "$BP55_ROOT/sim/bp_model.h" . ;;
  v1) git -C "$BP55_ROOT" show 8ff8f15:sim/cosim.cc > cosim.cc; git -C "$BP55_ROOT" show 8ff8f15:sim/bp_model.h > bp_model.h
      # the only change: f_meta is a CXXRTL wire<> in the v1 RTL (.curr.data) but a value<> in a netlist
      # (.data); read it through an overload that accepts both
      sed -i -e 's/t\.p_f__meta\.curr\.data\[i\]/gl_rd(t.p_f__meta)[i]/' \
             -e 's/^using Top = cxxrtl_design::p_bp55;/&\ntemplate <size_t N> static const uint32_t *gl_rd(const cxxrtl::value<N> \&v) { return v.data; }\ntemplate <size_t N> static const uint32_t *gl_rd(const cxxrtl::wire<N> \&w) { return w.curr.data; }/' cosim.cc
      grep -q 'gl_rd(t.p_f__meta)' cosim.cc ;;
  *) echo "harness must be v1 or v2"; exit 2 ;;
esac
case $net in rtl:*) PASSES="$PASSES; write_cxxrtl bp55_rtl.cc" ;; esac
yosys -q -l yosys.log -p "$PASSES" > /dev/null
# The debug-information functions of a flattened gate netlist are several hundred thousand lines
# (one entry per named net) and dominate g++ time; they only run at set-up and in the post-reset
# clear check, so they are compiled without optimisation (eval() keeps ${OPT:--O1}).
if grep -q 'curr\.update(' bp55_rtl.cc; then echo "write_cxxrtl emitted a \$dffsr (curr.update): flops would not clock, see header" >&2; exit 3; fi
[ -n "${DEBUG_O0:-1}" ] && sed -i -E 's/^(void p_bp55::debug_(eval|info)\()/__attribute__((optimize("O0"))) \1/' bp55_rtl.cc
g++ ${OPT:--O1} -std=c++17 -I"$CXXRTL_INC" -I. -o cosim cosim.cc
rm -f design.v bp55_rtl.cc bp55_rtl.h
echo "built $B/cosim"
