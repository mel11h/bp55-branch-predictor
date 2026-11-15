#!/usr/bin/env python3
"""CPI of selected configurations as the branch penalties grow.

CPI = 1 + (EX_PENALTY * ex_mispredictions + ID_PENALTY * id_redirects) / instructions,
averaged over the programs (unweighted), from results/final.csv.

Usage: python3 penalty_sweep.py [csv] [cfg ...]
"""
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from summ import load  # noqa: E402

args = sys.argv[1:]
csv = args[0] if args and args[0].endswith(".csv") else os.path.join(HERE, "..", "results", "final.csv")
cfgs = [a for a in args if not a.endswith(".csv")] or ["bimodal", "gshare_9k", "BP55", "BP55_128k"]

by = collections.defaultdict(list)
for r in load([csv]):
    by[r["cfg"]].append(r)

# (EX penalty, ID redirect penalty) in cycles. (3, 2) is the BP55 target pipeline.
POINTS = [(3, 2), (6, 2), (6, 3), (12, 2), (12, 4), (16, 4)]

print("%-6s %-6s " % ("EX", "ID") + " ".join("%-10s" % c for c in cfgs))
for ex, idp in POINTS:
    row = []
    for c in cfgs:
        rs = by[c]
        row.append(sum(1 + (ex * r["mis"] + idp * r["idr"]) / r["instr"] for r in rs) / len(rs))
    print("%-6d %-6d " % (ex, idp) + " ".join("%-10.4f" % v for v in row))
