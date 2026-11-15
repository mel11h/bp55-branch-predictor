#!/bin/bash
# BP55 measurement harness on CORE-V Wally (phase 1: Wally's own predictors).
#
#   wally/wally.sh setup                 fetch cores/cvw at the pinned commit if missing,
#                                        apply wally/patches/*.patch, make tool shims
#   wally/wally.sh bench                 build the 21 programs for Wally (bench/build_wally.sh,
#                                        GSF=4 CM_IT=60) and their memory images
#   wally/wally.sh build <cfg>           derive config rv32im_<cfg> and build its Verilator model
#   wally/wally.sh run <cfg> <prog>      run one program, print its counters, write
#                                        wally/results/<cfg>/<prog>.csv
#   wally/wally.sh sweep [cfg ...]       setup + bench + build + run every program on every cfg
#                                        (default: $ALL_CONFIGS), PAR runs in parallel
#   wally/wally.sh report [cfg ...]      results table (wally/results/summary.txt)
#   wally/wally.sh crosscheck            minstret vs rvsim, nobp redirects vs control-flow trace
#   wally/wally.sh modelcheck            bp55 counters vs sim/bpsim and the Wally-timing model
#   wally/wally.sh bits [cfg ...]        predictor storage bits of each configuration, from the RTL
#   wally/wally.sh clean                 delete Verilator build dirs and run logs
#
# Configurations are wally/configs/<cfg>.cfg on top of wally/configs/base.cfg.
# A/B against BP55: wally/wally.sh sweep gshare_iso bp55 && wally/wally.sh report && wally/wally.sh modelcheck
#
# Environment (all optional):
#   BP55_ROOT   repository root (default: parent of this script's directory)
#   CVW         Wally clone (default: $BP55_ROOT/cores/cvw)
#   WALLY_WORK  tool shims, logs and run dirs (default: $BP55_ROOT/cores/wally_work)
#   EDA_BIN     directory with verilator and the conda C++ compiler it calls
#               (default: $HOME/miniconda3/envs/eda/bin)
#   PAR         parallel simulations (default 16; about 135 MB each)
#   JOBS        C++ compile jobs per Verilator build (default: nproc)
#   KEEP_OBJ=1  keep Verilator object files (default: delete all but the executable)
set -euo pipefail

R=${BP55_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
H=$R/wally
CVW=${CVW:-$R/cores/cvw}
WORK=${WALLY_WORK:-$R/cores/wally_work}
EDA_BIN=${EDA_BIN:-$HOME/miniconda3/envs/eda/bin}
BENCH=$R/bench/build/wally
RES=$H/results
PAR=${PAR:-16}
CVW_URL=https://github.com/openhwfoundation/cvw
CVW_COMMIT=3617f2c70208d1cc7481e6a5c58837f8d6266513
ALL_CONFIGS="nobp static gshare gshare_iso twobit_iso local_iso bp55"
PROGS="coremark aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum nettle-aes nettle-sha256
nsichneu picojpeg qrduino sglib-combined slre statemate tarfind ud xgboost interp recurse"

die() { echo "wally.sh: $*" >&2; exit 1; }

env_setup() {
  # shellcheck disable=SC1091
  source "$R/tools/env.sh"
  export WALLY=$CVW
  export PATH="$WORK/bin:$CVW/bin:$EDA_BIN:$PATH"
}

setup() {
  if [ ! -d "$CVW/.git" ]; then
    echo "fetching cvw $CVW_COMMIT into $CVW"
    mkdir -p "$CVW"
    git -C "$CVW" init -q
    git -C "$CVW" remote add origin "$CVW_URL"
    git -C "$CVW" fetch -q --depth 1 origin "$CVW_COMMIT"
    git -C "$CVW" checkout -q FETCH_HEAD
  fi
  head=$(git -C "$CVW" rev-parse HEAD)
  [ "$head" = "$CVW_COMMIT" ] || die "$CVW is at $head, expected $CVW_COMMIT"
  local touched=""
  for p in "$H"/patches/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$CVW" apply -R --check "$p" 2>/dev/null; then :
    elif git -C "$CVW" apply --check "$p" 2>/dev/null; then
      git -C "$CVW" apply "$p"; echo "applied $(basename "$p")"
    else die "patch $(basename "$p") neither applies nor is applied; inspect $CVW"; fi
    touched="$touched $(git -C "$CVW" apply --numstat "$p" 2>/dev/null | awk '{print $3}' | tr '\n' ' ')"
  done
  # Every change in the clone must come from a patch in wally/patches.
  local stray=""
  while read -r f; do
    [ "$f" = "$BP55_DST" ] && continue   # the copy of rtl/bp55.sv, checked by install_bp55
    case " $touched " in *" $f "*) ;; *) stray="$stray $f";; esac
  done < <(git -C "$CVW" status --porcelain --untracked-files=all | awk '{print $2}' | grep -v '^config/deriv/' || true)
  [ -z "$stray" ] || die "changes in $CVW not covered by wally/patches:$stray"
  install_bp55
  mkdir -p "$WORK/bin"
  env_setup
  ln -sf "$(command -v llvm-nm)" "$WORK/bin/riscv64-unknown-elf-nm"
  # cvw/bin/elf2hex runs through "uv run --script", which would create a ~300 MB
  # virtual environment for cvw's pyproject; it needs only the standard library.
  printf '#!/bin/sh\nexec python3 "%s/bin/elf2hex" "$@"\n' "$CVW" > "$WORK/bin/elf2hex"
  chmod +x "$WORK/bin/elf2hex"
  command -v verilator >/dev/null || die "verilator not found (EDA_BIN=$EDA_BIN)"
}

bench() {
  env_setup
  GSF=4 CM_IT=60 "$R/bench/build_wally.sh"
  for p in $PROGS; do
    [ -f "$BENCH/$p.elf" ] || die "missing $BENCH/$p.elf"
    make -s -f "$CVW/testbench/Makefile" WALLY="$CVW" "$BENCH/$p.elf.memfile" "$BENCH/$p.elf.objdump.addr"
  done
  echo "bench: $(echo $PROGS | wc -w) programs ready in bench/build/wally"
}

# BP55 RTL: rtl/bp55.sv is copied (never edited) to src/ifu/bpred/bp55.sv, where the Verilator
# Makefile's source glob picks it up; wally/patches/0002-bpred-bp55.patch instantiates it.
BP55_SRC=$R/rtl/bp55.sv
BP55_DST=src/ifu/bpred/bp55.sv
install_bp55() {
  cmp -s "$BP55_SRC" "$CVW/$BP55_DST" || cp "$BP55_SRC" "$CVW/$BP55_DST"
}

wkdir() { echo "$CVW/sim/verilator/wkdir/rv32im_$1_testbench"; }

build() {
  local cfg=$1
  [ -f "$H/configs/$cfg.cfg" ] || die "no configuration wally/configs/$cfg.cfg"
  env_setup
  python3 "$H/tools/mkconfig.py" "$CVW" "$cfg" "$H/configs/base.cfg" "$H/configs/$cfg.cfg" >/dev/null
  local wd; wd=$(wkdir "$cfg")
  # Rebuild only if the derived config, the clone's changes or the sources changed.
  local stamp
  stamp=$( { cat "$CVW/config/deriv/rv32im_$cfg/config.vh"; git -C "$CVW" rev-parse HEAD;
             git -C "$CVW" diff; cat "$CVW"/testbench/bp55perf.svh;
             grep -q 'BP_BP55' "$H/configs/$cfg.cfg" && cat "$CVW/$BP55_DST"; } | sha256sum | cut -c1-16)
  if [ -x "$wd/Vtestbench" ] && [ "$(cat "$wd/.bp55stamp" 2>/dev/null)" = "$stamp" ]; then
    echo "build $cfg: up to date"; return; fi
  rm -rf "$wd"
  local t0=$SECONDS
  make -s -C "$CVW/sim/verilator" WALLYCONF="rv32im_$cfg" TESTBENCH=testbench JOBS="${JOBS:-$(nproc)}" compile \
    > "$WORK/build_$cfg.log" 2>&1 || { tail -30 "$WORK/build_$cfg.log"; die "build of $cfg failed (log: $WORK/build_$cfg.log)"; }
  [ "${KEEP_OBJ:-0}" = 1 ] || find "$wd" -type f ! -name Vtestbench -delete
  echo "$stamp" > "$wd/.bp55stamp"
  echo "build $cfg: $((SECONDS - t0)) s, $(du -sh "$wd" | cut -f1)"
}

# CSV columns, in the order of the BP55PERF line printed by the testbench.
COLS="cycles instret branches jumps returns bpwrong dirwrong tgtwrong raswrong classwrong loadstall storestall dcache_access dcache_miss dcache_stall icache_access icache_miss icache_stall csr_write fencei sfencevma interrupts exceptions div_cycles trapret_cycles csrfence_cycles redirectd_cycles bpwronge_cycles stalld_cycles hw_mcycle hw_minstret bp55_repair_only"

run() {
  local cfg=$1 prog=$2
  local exe; exe=$(wkdir "$cfg")/Vtestbench
  [ -x "$exe" ] || die "model for $cfg not built (wally/wally.sh build $cfg)"
  [ -f "$BENCH/$prog.elf.memfile" ] || die "program $prog not built (wally/wally.sh bench)"
  env_setup
  local rd="$WORK/run/$cfg/$prog" log="$WORK/logs/$cfg/$prog.log"
  rm -rf "$rd"; mkdir -p "$rd" "$(dirname "$log")" "$RES/$cfg"
  local t0; t0=$(date +%s.%N)
  ( cd "$rd" && "$exe" +TEST=default +ElfFile="$BENCH/$prog.elf" ) > "$log" 2>&1 || true
  local t1; t1=$(date +%s.%N)
  rm -rf "$rd"
  python3 "$H/tools/parse_run.py" "$cfg" "$prog" "$log" "$BENCH/iss/$prog.console" \
    "$(awk "BEGIN{print $t1 - $t0}")" "$COLS" > "$RES/$cfg/$prog.csv" || { cat "$RES/$cfg/$prog.csv"; tail -5 "$log"; return 1; }
  python3 - "$RES/$cfg/$prog.csv" <<'EOF'
import csv, sys
r = next(csv.DictReader(open(sys.argv[1])))
i = int(r["instret"]); c = int(r["cycles"])
print(f'{r["config"]:>10} {r["program"]:<15} {r["status"]:<5} cycles={c} instret={i} CPI={c/i:.4f} '
      f'br={r["branches"]} jmp={r["jumps"]} ret={r["returns"]} bpwrong={r["bpwrong"]} dir={r["dirwrong"]} '
      f'tgt={r["tgtwrong"]} ras={r["raswrong"]} class={r["classwrong"]} wall={float(r["wall_s"]):.0f}s')
EOF
}

sweep() {
  local cfgs=${*:-$ALL_CONFIGS}
  setup; bench
  for c in $cfgs; do build "$c"; done
  local t0=$SECONDS
  # longest programs first, so the tail of the sweep is short
  local order="aha-mont64 coremark recurse nettle-sha256 crc32 interp edn nettle-aes statemate xgboost md5sum
picojpeg qrduino slre sglib-combined depthconv huffbench tarfind ud nsichneu matmult-int"
  for p in $order; do for c in $cfgs; do echo "$c $p"; done; done |
    xargs -P "$PAR" -L 1 "$0" run
  echo "sweep: $(echo $cfgs | wc -w) configurations x $(echo $PROGS | wc -w) programs in $((SECONDS - t0)) s wall"
}

case "${1:-}" in
  setup) setup ;;
  bench) setup; bench ;;
  build) [ $# -ge 2 ] || die "usage: build <cfg>"; setup; shift; for c in "$@"; do build "$c"; done ;;
  run) [ $# -eq 3 ] || die "usage: run <cfg> <prog>"; run "$2" "$3" ;;
  sweep) shift; sweep "$@" ;;
  report) shift; python3 "$H/tools/report.py" "$RES" "$@" ;;
  crosscheck) env_setup; python3 "$H/tools/crosscheck.py" "$R" ;;
  modelcheck) env_setup; python3 "$H/tools/model_check.py" "$R" "$WORK/modelcheck" ;;
  bits) shift; for c in ${*:-$ALL_CONFIGS}; do
          python3 "$H/tools/mkconfig.py" "$CVW" "$c" "$H/configs/base.cfg" "$H/configs/$c.cfg" >/dev/null; done
        python3 "$H/tools/bitcount.py" "$CVW" ${*:-$ALL_CONFIGS} ;;
  clean) rm -rf "$CVW/sim/verilator/wkdir" "$WORK/run" "$WORK/logs" ;;
  *) sed -n '2,33p' "$0"; exit 1 ;;
esac
