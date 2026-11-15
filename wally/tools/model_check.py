#!/usr/bin/env python3
"""BP55 in Wally against the software model (wally/wally.sh modelcheck).

usage: model_check.py <repo root> <work dir> [<results dir> <bench dir> <rebase>]

<rebase> is added to the trace addresses for the Wally-timing model (0x80000000 for the default
twins linked at 0; 0x7fff0000 for the RELAX=1 twins at 0x10000, whose extra start-up jump at
address 0 then costs the model one redirect that Wally does not have).

For every program with a wally/results/bp55/<prog>.csv:
  - the control-flow trace of the program's ISS twin (iss/rvsim; same objects as the Wally ELF,
    linked at 0, so the trace is rebased to 0x80000000 where needed) is written to <work>,
  - sim/bpsim (built from sim/bpsim.cc into <work>) is run on it with the v2 switches (v2=1) and
    training delays 0, 1 and 2 branches; its redirect total is EX mispredicts + decode redirects +
    phantom redirects, in the 6-stage pipeline bpsim models,
  - wally/tools/bp55_wally_model.cc (bp_model.h with Wally's redirect rule and E-stage training
    timing) is run on it,
and the counts are compared with Wally's counters (hpm6 redirects, hpm7 direction, repair-only).
Writes wally/results/bp55_model_check.csv and prints a table.
"""
import csv
import subprocess
import sys
from pathlib import Path


def main():
    root, work = Path(sys.argv[1]), Path(sys.argv[2])
    res = Path(sys.argv[3]) if len(sys.argv) > 3 else root / "wally/results"
    bench = Path(sys.argv[4]) if len(sys.argv) > 4 else root / "bench/build/wally"
    rebase = sys.argv[5] if len(sys.argv) > 5 else "0x80000000"
    work.mkdir(parents=True, exist_ok=True)
    bpsim, model = work / "bpsim", work / "bp55_wally_model"
    subprocess.run(["g++", "-O2", "-std=c++17", "-o", str(bpsim), str(root / "sim/bpsim.cc")], check=True)
    subprocess.run(["g++", "-O2", "-std=c++17", "-o", str(model), str(root / "wally/tools/bp55_wally_model.cc")], check=True)
    cfgargs = "LB=7 LBIM=9 LI=5 HT=6 NT=3 LT=6 TT=7 hist=5,12,28 v2=1".split()
    rows = []
    hdr = (f"{'program':<15} {'wally':>8} {'model':>8} {'diff':>6} | {'dir W':>7} {'dir M':>7} | {'rep W':>6} {'rep M':>6} |"
           f" {'bpsim d0':>8} {'d1':>8} {'d2':>8} (all redirects, 6-stage accounting)")
    print(hdr)
    for f in sorted((res / "bp55").glob("*.csv")):
        w = next(csv.DictReader(open(f)))
        prog = w["program"]
        trc = work / f"{prog}.trc"
        with open(trc, "wb") as t:
            subprocess.run([str(root / "iss/rvsim"), str(bench / f"iss/{prog}.bin"), "/dev/stdout", "100000000"],
                           stdout=t, stderr=subprocess.DEVNULL)
        with open(trc, "rb") as t:
            out = subprocess.run([str(model), rebase], stdin=t, capture_output=True, text=True, check=True).stdout
        m = dict(kv.split("=") for kv in out.split())
        bs = {}
        for d in (0, 1, 2):
            o = subprocess.run([str(bpsim), "BP55_v2"] + cfgargs + [f"delay={d}", "remap=0", "--", str(trc)],
                               capture_output=True, text=True, check=True).stdout.strip().split(",")
            v = list(map(int, o[3:]))
            # instr, br[6], cond_taken, dir_wrong, mis[6], idr[6], phantom, ph2, taken_cf, taken_hit0, slow_diff
            mis, idr, ph2 = sum(v[9:15]), sum(v[15:21]), v[22]
            bs[d] = dict(total=mis + idr + ph2, ex=mis, id=idr, ph=ph2, dir=v[8])
        trc.unlink()
        r = dict(program=prog, wally_redirects=int(w["bpwrong"]), model_redirects=int(m["redirects"]),
                 wally_dirwrong=int(w["dirwrong"]), model_dirwrong=int(m["dir_wrong"]),
                 wally_repair_only=int(w["bp55_repair_only"] or 0), model_need_only=int(m["need_only"]),
                 model_pc_wrong=int(m["pc_wrong"]), model_phantom_lookups=int(m["phantom"]),
                 model_phantom_redirects=int(m["phantom_redirects"]), instret=int(w["instret"]))
        for d in (0, 1, 2):
            r.update({f"bpsim_d{d}_total": bs[d]["total"], f"bpsim_d{d}_ex": bs[d]["ex"],
                      f"bpsim_d{d}_id": bs[d]["id"], f"bpsim_d{d}_phantom": bs[d]["ph"], f"bpsim_d{d}_dirwrong": bs[d]["dir"]})
        rows.append(r)
        print(f"{prog:<15} {r['wally_redirects']:8d} {r['model_redirects']:8d} {r['wally_redirects'] - r['model_redirects']:6d} | "
              f"{r['wally_dirwrong']:7d} {r['model_dirwrong']:7d} | {r['wally_repair_only']:6d} {r['model_need_only']:6d} |"
              f" {bs[0]['total']:8d} {bs[1]['total']:8d} {bs[2]['total']:8d}")
    tw = sum(r["wally_redirects"] for r in rows); tm = sum(r["model_redirects"] for r in rows)
    print(f"{'total':<15} {tw:8d} {tm:8d} {tw - tm:6d} ({100.0 * (tw - tm) / tm:+.3f} %)")
    with open(res / "bp55_model_check.csv", "w", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(rows[0])); wr.writeheader(); wr.writerows(rows)


if __name__ == "__main__":
    main()
