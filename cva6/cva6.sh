#!/bin/bash
# BP55 measurement harness on CVA6 (phase 1: CVA6's own predictor).
#
#   cva6/cva6.sh setup               fetch cores/cva6 at the pinned commit if missing (with only
#                                    the submodules the build needs), apply cva6/patches/*.patch
#   cva6/cva6.sh bench               build the 21 programs (bench/build_cva6.sh, GSF=4 CM_IT=60)
#   cva6/cva6.sh build <var> ...     generate the configuration of variant <var> and build its
#                                    Verilator model (own testbench, cva6/tb)
#   cva6/cva6.sh run <var> <prog>    run one program, print its counters, write
#                                    cva6/results/<var>/<prog>.csv
#   cva6/cva6.sh sweep [var ...]     setup + bench + build + run every program on every variant
#                                    (default: $ALL_VARIANTS), PAR simulations in parallel
#   cva6/cva6.sh report [var ...]    results table (cva6/results/summary.txt)
#   cva6/cva6.sh crosscheck          instret vs iss/rvsim and other consistency checks
#   cva6/cva6.sh modelcheck          BP55 counters vs the software model (bp55_cva6_model.cc)
#   cva6/cva6.sh clean               delete build directories and run logs
#
# Variants are cva6/configs/<var>.cfg on top of cva6/configs/base.cfg; variants may
# only change predictor fields (cva6/tools/mkconfig.py enforces it).
# The A/B comparison: cva6/cva6.sh sweep big big2 bp55 && cva6/cva6.sh report
#
# Environment (all optional):
#   BP55_ROOT  repository root (default: parent of this script's directory)
#   CVA6       CVA6 clone (default: $BP55_ROOT/cores/cva6)
#   CVA6_WORK  build and log directory (default: $CVA6/bp55_work, git-excluded in the clone)
#   EDA_BIN    directory with verilator and the conda C++ compiler (default: $HOME/miniconda3/envs/eda/bin)
#   PAR        parallel simulations (default 4)
#   JOBS       C++ compile jobs per Verilator build (default 4)
#   BASE_CFG   base configuration cva6/configs/<name>.cfg (default base)
#   MEM_LAT    memory latency in cycles of the testbench AXI slave (default 1)
#   MIN_FREE_GB  minimum available memory before a build or a simulation starts (default 3)
#   KEEP_OBJ=1 keep Verilator object files
set -euo pipefail

R=${BP55_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
H=$R/cva6
CVA6=${CVA6:-$R/cores/cva6}
WORK=${CVA6_WORK:-$CVA6/bp55_work}
EDA_BIN=${EDA_BIN:-$HOME/miniconda3/envs/eda/bin}
BENCH=$R/bench/build/cva6
RES=$H/results
PAR=${PAR:-4}
JOBS=${JOBS:-4}
MEM_LAT=${MEM_LAT:-1}
MIN_FREE_GB=${MIN_FREE_GB:-3}
BASE_CFG=${BASE_CFG:-base}
CVA6_URL=https://github.com/openhwgroup/cva6
CVA6_COMMIT=742dc82a0c706e0a3bfb98b709fd3ee06d50d12a
# Submodules the build reads (core/Flist.cva6); cvfpu's fpu_div_sqrt_mvp is its own submodule.
SUBMODULES="core/cvfpu core/cache_subsystem/hpdcache"
SUBSUBMODULES="core/cvfpu:src/fpu_div_sqrt_mvp"
ALL_VARIANTS="nobp stock big big2 bp55"
PROGS="coremark aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum nettle-aes nettle-sha256
nsichneu picojpeg qrduino sglib-combined slre statemate tarfind ud xgboost interp recurse"

die() { echo "cva6.sh: $*" >&2; exit 1; }

env_setup() {
  # shellcheck disable=SC1091
  source "$R/tools/env.sh"
  export PATH="$EDA_BIN:$PATH"
}

wait_mem() { # wait until MemAvailable >= MIN_FREE_GB (other jobs share this machine)
  local need=$((MIN_FREE_GB * 1024 * 1024)) avail n=0
  while avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo); [ "$avail" -lt "$need" ]; do
    [ $((n % 12)) = 0 ] && echo "cva6.sh: $((avail / 1024)) MB available, waiting for ${MIN_FREE_GB} GB" >&2
    n=$((n + 1)); sleep 10
  done
}

setup() {
  if [ ! -d "$CVA6/.git" ]; then
    echo "fetching cva6 $CVA6_COMMIT into $CVA6"
    mkdir -p "$CVA6"
    git -C "$CVA6" init -q
    git -C "$CVA6" remote add origin "$CVA6_URL"
    git -C "$CVA6" fetch -q --depth 1 origin "$CVA6_COMMIT"
    git -C "$CVA6" checkout -q FETCH_HEAD
  fi
  local head; head=$(git -C "$CVA6" rev-parse HEAD)
  [ "$head" = "$CVA6_COMMIT" ] || die "$CVA6 is at $head, expected $CVA6_COMMIT"
  for s in $SUBMODULES; do
    [ -e "$CVA6/$s/.git" ] || git -C "$CVA6" submodule update -q --init --depth 1 "$s"
  done
  for ss in $SUBSUBMODULES; do
    [ -e "$CVA6/${ss%%:*}/${ss#*:}/.git" ] || git -C "$CVA6/${ss%%:*}" submodule update -q --init --depth 1 "${ss#*:}"
  done
  grep -qx 'bp55_work/' "$CVA6/.git/info/exclude" 2>/dev/null || echo 'bp55_work/' >> "$CVA6/.git/info/exclude"
  # The patch series applies in order on the pinned commit. Build the expected tree in a
  # scratch index and compare it with the working tree: either the clone is pristine (apply
  # the series) or it must already be exactly HEAD + the series.
  mkdir -p "$WORK"; local idx; idx=$(mktemp "$WORK/index.XXXXXX")
  GIT_INDEX_FILE=$idx git -C "$CVA6" read-tree HEAD
  for p in "$H"/patches/*.patch; do
    GIT_INDEX_FILE=$idx git -C "$CVA6" apply --cached "$p" || { rm -f "$idx"; die "patch $(basename "$p") does not apply to $CVA6_COMMIT"; }
  done
  if [ -z "$(git -C "$CVA6" status --porcelain --untracked-files=all)" ]; then
    for p in "$H"/patches/*.patch; do git -C "$CVA6" apply "$p"; echo "applied $(basename "$p")"; done
  fi
  local stray
  stray=$(GIT_INDEX_FILE=$idx git -C "$CVA6" diff --name-only; git -C "$CVA6" ls-files --others --exclude-standard)
  rm -f "$idx"
  [ -z "$stray" ] || die "$CVA6 differs from $CVA6_COMMIT + cva6/patches in:" $stray
  env_setup
  command -v verilator >/dev/null || die "verilator not found (EDA_BIN=$EDA_BIN)"
}

bench() {
  env_setup
  GSF=4 CM_IT=60 CVA6_BENCH_OUT="$BENCH" "$R/bench/build_cva6.sh"
  for p in $PROGS; do [ -f "$BENCH/$p.elf" ] || die "missing $BENCH/$p.elf"; done
  echo "bench: $(echo $PROGS | wc -w) programs ready in bench/build/cva6"
}

install_bp55() { # build dir: copy rtl/bp55.sv unmodified into the build and select it
  cp "$R/rtl/bp55.sv" "$1/bp55.sv"
  cmp -s "$R/rtl/bp55.sv" "$1/bp55.sv" || die "copy of rtl/bp55.sv differs"
  echo "$1/bp55.sv" >> "$1/files.f"
  echo "+define+BP55_PRED" >> "$1/files.f"
}

# Build directory; a base other than configs/base.cfg (BASE_CFG=<name>) gets its own.
rname() { if [ "$BASE_CFG" = base ]; then echo "$1"; else echo "$BASE_CFG-$1"; fi; }
bdir() { echo "$WORK/build/$(rname "$1")"; }

build() {
  local var=$1
  [ -f "$H/configs/$var.cfg" ] || die "no variant cva6/configs/$var.cfg"
  env_setup
  local bd; bd=$(bdir "$var")
  mkdir -p "$bd"
  python3 "$H/tools/mkconfig.py" "$CVA6" "$H/configs/$BASE_CFG.cfg" "$H/configs/$var.cfg" "$bd" > "$bd/config.txt"
  # File list: the core's own list, with the target package replaced by the generated one.
  sed -e "s|\${CVA6_REPO_DIR}|$CVA6|g" -e "s|\${HPDCACHE_DIR}|$CVA6/core/cache_subsystem/hpdcache|g" \
      -e "s|^.*/core/include/\${TARGET_CFG}_config_pkg.sv$|$bd/cva6_bp55_config_pkg.sv|" \
      "$CVA6/core/Flist.cva6" > "$bd/files.f"
  grep -q 'TARGET_CFG' "$bd/files.f" && die "file list still refers to TARGET_CFG"
  if grep -q '^BP55 *1' "$H/configs/$var.cfg"; then install_bp55 "$bd"; fi
  local stamp
  stamp=$( { cat "$bd/cva6_bp55_config_pkg.sv" "$bd/files.f" "$H"/tb/*; cat "$bd/bp55.sv" 2>/dev/null; git -C "$CVA6" rev-parse HEAD;
             git -C "$CVA6" diff; verilator --version; echo "$JOBS"; } | sha256sum | cut -c1-16)
  if [ -x "$bd/obj/Vbp55_cva6_tb" ] && [ "$(cat "$bd/.stamp" 2>/dev/null)" = "$stamp" ]; then
    echo "build $var: up to date"; return; fi
  rm -rf "$bd/obj"
  wait_mem
  local t0=$SECONDS
  # Memory-capped: verilating and compiling CVA6 takes a few GB and this machine is shared.
  ( cd "$CVA6" && systemd-run --user --collect --wait --quiet --pipe -p MemoryHigh=6G -p MemoryMax=8G \
      --working-directory="$CVA6" --setenv=PATH="$PATH" --setenv=CVA6_REPO_DIR="$CVA6" \
      --setenv=HPDCACHE_DIR="$CVA6/core/cache_subsystem/hpdcache" \
      /usr/bin/time -v verilator --cc --exe --build -j "$JOBS" --no-timing \
      verilator_config.vlt -f "$bd/files.f" "$H/tb/bp55_cva6_tb.sv" "$H/tb/bp55_cva6_main.cpp" \
      --top-module bp55_cva6_tb --Mdir "$bd/obj" -O3 --unroll-count 256 +define+BP55_NO_DASM_TRACE \
      -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNOPTFLAT \
      -Wno-BLKANDNBLK -Wno-style -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
      -CFLAGS "-O2 -std=c++17" -MAKEFLAGS "OPT_FAST=-O2" ) > "$bd/build.log" 2>&1 \
    || { tail -30 "$bd/build.log"; die "build of $var failed (log: $bd/build.log)"; }
  [ -x "$bd/obj/Vbp55_cva6_tb" ] || die "build of $var produced no executable (log: $bd/build.log)"
  python3 "$H/tools/bitcount.py" "$bd/obj" > "$bd/bits.txt" || die "bit count failed for $var"
  python3 "$H/tools/bitcount.py" --dump "$bd/obj" | gzip > "$bd/members.txt.gz"
  mkdir -p "$RES"
  { echo "# variant $(rname "$var"): predictor state bits read from the Verilated model (cva6/tools/bitcount.py)"
    sed 's/^/# config: /' "$bd/config.txt"; cat "$bd/bits.txt"; } > "$RES/bits_$(rname "$var").txt"
  if [ "${KEEP_OBJ:-0}" != 1 ]; then find "$bd/obj" -type f ! -name Vbp55_cva6_tb -delete; fi
  echo "$stamp" > "$bd/.stamp"
  echo "build $var: $((SECONDS - t0)) s, peak RSS $(awk '/Maximum resident/ {printf "%.0f MB", $6/1024}' "$bd/build.log"), $(du -sh "$bd" | cut -f1)"
  cat "$bd/bits.txt"
}

COLS="cycles instret exceptions cond jal jal_call jalr_ret jalr_call jalr_ind cond_taken fe_taken_cond fe_taken_jal fe_taken_ret fe_taken_ind res mp mp_dir mp_ret_nopred mp_ret_wrong mp_ind_nopred mp_ind_wrong mp_other res_nocf flush_ex pen_n_mp pen_mode_mp pen_mean_mp pen_n_ok pen_mode_ok pen_mean_ok hw_mcycle hw_minstret oob axi_err"

run() {
  local var=$1 prog=$2
  local exe; exe=$(bdir "$var")/obj/Vbp55_cva6_tb
  [ -x "$exe" ] || die "model for $var not built (cva6/cva6.sh build $var)"
  [ -f "$BENCH/$prog.elf" ] || die "program $prog not built (cva6/cva6.sh bench)"
  local rn; rn=$(rname "$var")
  local ld="$WORK/logs/$rn"
  mkdir -p "$ld" "$RES/$rn"
  wait_mem
  # own working directory per run, so that nothing the model might write lands elsewhere
  local rd="$WORK/run/$rn/$prog"
  rm -rf "$rd"; mkdir -p "$rd"
  local t0; t0=$(date +%s.%N)
  ( cd "$rd" && /usr/bin/time -f "MAXRSS_KB=%M" "$exe" +elf="$BENCH/$prog.elf" +console="$ld/$prog.console" \
    +mem_lat="$MEM_LAT" ) > "$ld/$prog.log" 2>&1 || true
  local t1; t1=$(date +%s.%N)
  rm -rf "$rd"
  python3 "$H/tools/parse_run.py" "$rn" "$prog" "$ld/$prog.log" "$ld/$prog.console" \
    "$BENCH/iss/$prog.console" "$(awk "BEGIN{print $t1 - $t0}")" "$MEM_LAT" "$COLS" > "$RES/$rn/$prog.csv" \
    || { cat "$RES/$rn/$prog.csv"; tail -5 "$ld/$prog.log"; return 1; }
  python3 - "$RES/$rn/$prog.csv" <<'EOF'
import csv, sys
r = next(csv.DictReader(open(sys.argv[1])))
i = int(r["instret"]); c = int(r["cycles"])
print(f'{r["variant"]:>6} {r["program"]:<15} {r["status"]:<5} cycles={c} instret={i} CPI={c/i:.4f} '
      f'cond={r["cond"]} mp={r["mp"]} dir={r["mp_dir"]} ret={int(r["mp_ret_nopred"])+int(r["mp_ret_wrong"])} '
      f'ind={int(r["mp_ind_nopred"])+int(r["mp_ind_wrong"])} MPKI={1000*int(r["mp"])/i:.2f} '
      f'pen={r["pen_mode_mp"]}-{r["pen_mode_ok"]} wall={float(r["wall_s"]):.0f}s rss={int(r["maxrss_kb"])//1024}MB')
EOF
}

sweep() {
  local vars=${*:-$ALL_VARIANTS}
  setup; bench
  for v in $vars; do build "$v"; done
  local t0=$SECONDS
  # longest programs first, so the tail of the sweep is short
  local order="aha-mont64 coremark recurse nettle-sha256 crc32 interp edn nettle-aes statemate xgboost md5sum
picojpeg qrduino slre sglib-combined depthconv huffbench tarfind ud nsichneu matmult-int"
  for p in $order; do for v in $vars; do echo "$v $p"; done; done |
    xargs -P "$PAR" -L 1 "$0" run
  echo "sweep: $(echo $vars | wc -w) variants x $(echo $PROGS | wc -w) programs in $((SECONDS - t0)) s wall"
}

case "${1:-}" in
  setup) setup ;;
  bench) setup; bench ;;
  build) [ $# -ge 2 ] || die "usage: build <variant> ..."; setup; shift; for v in "$@"; do build "$v"; done ;;
  run) [ $# -eq 3 ] || die "usage: run <variant> <prog>"; run "$2" "$3" ;;
  sweep) shift; sweep "$@" ;;
  report) shift; python3 "$H/tools/report.py" "$RES" "$@" ;;
  crosscheck) python3 "$H/tools/crosscheck.py" "$RES" "$BENCH/iss/counts.csv" ;;
  modelcheck) python3 "$H/tools/model_check.py" "$R" "$WORK/model" "$RES" "$BENCH" ;;
  clean) rm -rf "$WORK" ;;
  *) sed -n '2,32p' "$0"; exit 1 ;;
esac
