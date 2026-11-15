#!/usr/bin/env python3
"""Step D check: OpenRCX extraction of the pattern layout with the generated rules vs the
2D field-solver reference SPEF the rules were made from.

usage: compare_patterns.py <reference patterns_<c>.spef> <openrcx ext_<c>.spef>
Reports, per pattern family and for the target wire (_3; both wires of DU patterns),
the distribution of OpenRCX/reference for total C, coupling C and R.
"""
import os
import re
import statistics
import sys
from collections import defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from compare_spef import read_spef  # noqa: E402


def main():
    ref, ext = read_spef(sys.argv[1]), read_spef(sys.argv[2])
    fam = defaultdict(lambda: defaultdict(list))
    for n, v in ref.items():
        if "cntx" in n or n not in ext:
            continue
        m = re.match(r"^(O6|U6|OU6|DU6|R6)_(M\d+[ou]+M\d+(?:uM\d+)?)_W\d+W\d+_S(\d+)S(\d+)_(\d+)$", n)
        if not m:
            continue
        kind, lay, s1, s2, num = m.groups()
        target = num == "3" or (kind == "DU6" and num in ("2", "3"))
        if not target:
            continue
        e = ext[n]
        if kind == "R6":
            if v[3] > 0:
                fam["R6 resistance"]["R"].append(e[3] / v[3])
            continue
        if v[0] > 0:
            fam[kind]["Ctot"].append(e[0] / v[0])
        if v[2] > 1e-4:
            fam[kind]["Ccpl"].append(e[2] / v[2])
        if v[3] > 0:
            fam[kind]["R"].append(e[3] / v[3])
    print("OpenRCX(rules) / reference, target wires of the bench patterns")
    allc = []
    for k in sorted(fam):
        for q in ("Ctot", "Ccpl", "R"):
            r = sorted(fam[k][q])
            if not r:
                continue
            if q == "Ctot":
                allc += r
            print(f"  {k:14s} {q:5s} n={len(r):4d} median {statistics.median(r):.3f} "
                  f"p5 {r[int(0.05*len(r))]:.3f} p95 {r[min(len(r)-1,int(0.95*len(r)))]:.3f} min {r[0]:.3f} max {r[-1]:.3f}")
    if allc:
        allc.sort()
        print(f"  all families Ctot n={len(allc)} median {statistics.median(allc):.3f} p5 {allc[int(0.05*len(allc))]:.3f} p95 {allc[int(0.95*len(allc))]:.3f}")


if __name__ == "__main__":
    main()
