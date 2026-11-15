#!/usr/bin/env python3
"""BP55 in CVA6 against the software model (cva6/cva6.sh modelcheck).

usage: model_check.py <repo root> <work dir> <results dir> <bench dir>

For every program with a <results>/bp55/<prog>.csv: the control-flow trace of the
program's ISS twin (iss/rvsim; same objects as the CVA6 ELF, linked at 0, rebased to
0x80000000) is written to <work>, cva6/tools/bp55_cva6_model.cc (sim/bp_model.h with
CVA6's prediction rule and EX training timing) is run on it for training distances
D = 1..5 lookups, and its EX mispredicts (total, direction, return, indirect) and
frontend repairs are compared with the RTL counters. Writes
<results>/bp55_model_check.csv and prints a table.
"""
import csv
import subprocess
import sys
from pathlib import Path

DS = (1, 2, 3, 4, 5)


def main():
    root, work, res, bench = map(Path, sys.argv[1:5])
    work.mkdir(parents=True, exist_ok=True)
    model = work / "bp55_cva6_model"
    subprocess.run(["g++", "-O2", "-std=c++17", "-o", str(model), str(root / "cva6/tools/bp55_cva6_model.cc")],
                   check=True)
    rows = []
    print(f"{'program':<15} {'RTL mp':>8} " + " ".join(f"{'D=' + str(d):>8}" for d in DS) +
          f" | {'dir R':>7} {'dir M3':>7} | {'ret R':>6} {'ret M3':>6} | {'ind R':>6} {'ind M3':>6} | {'ferep R':>7} {'M3':>7}")
    for f in sorted((res / "bp55").glob("*.csv")):
        w = next(csv.DictReader(open(f)))
        prog = w["program"]
        trc = work / f"{prog}.trc"
        with open(trc, "wb") as t:
            subprocess.run([str(root / "iss/rvsim"), str(bench / f"iss/{prog}.bin"), "/dev/stdout", "100000000"],
                           stdout=t, stderr=subprocess.DEVNULL)
        m = {}
        for d in DS:
            with open(trc, "rb") as t:
                out = subprocess.run([str(model), str(d), "0x80000000"], stdin=t, capture_output=True, text=True,
                                     check=True).stdout
            m[d] = {k: int(v) for k, v in (kv.split("=") for kv in out.split())}
        trc.unlink()
        r = dict(program=prog, instret=int(w["instret"]), rtl_mp=int(w["mp"]), rtl_dir=int(w["mp_dir"]),
                 rtl_ret=int(w["mp_ret_nopred"]) + int(w["mp_ret_wrong"]),
                 rtl_ind=int(w["mp_ind_nopred"]) + int(w["mp_ind_wrong"]),
                 rtl_ferep=int(w["bp55_ferep"]) + int(w["bp55_ferep_drop"]), model_instr=m[3]["instr"])
        for d in DS:
            for k in ("mp", "mp_dir", "mp_ret", "mp_ind", "ferep"):
                r[f"model_d{d}_{k}"] = m[d][k]
        rows.append(r)
        print(f"{prog:<15} {r['rtl_mp']:8d} " + " ".join(f"{m[d]['mp']:8d}" for d in DS) +
              f" | {r['rtl_dir']:7d} {m[3]['mp_dir']:7d} | {r['rtl_ret']:6d} {m[3]['mp_ret']:6d} |"
              f" {r['rtl_ind']:6d} {m[3]['mp_ind']:6d} | {r['rtl_ferep']:7d} {m[3]['ferep']:7d}")
    tr = sum(r["rtl_mp"] for r in rows)
    line = f"{'total':<15} {tr:8d} " + " ".join(f"{sum(r[f'model_d{d}_mp'] for r in rows):8d}" for d in DS)
    print(line)
    for d in DS:
        tm = sum(r[f"model_d{d}_mp"] for r in rows)
        print(f"  D={d}: RTL - model = {tr - tm:+d} ({100.0 * (tr - tm) / tm:+.3f} %)")
    with open(res / "bp55_model_check.csv", "w", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)


if __name__ == "__main__":
    main()
