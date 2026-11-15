#!/usr/bin/env python3
# cmp_csv.py reference.csv new.csv : field-by-field comparison of bpsim CSV rows,
# keyed by (config, trace). Prints mismatching rows and a per-config summary.
import sys, collections
def load(fn):
    d = collections.OrderedDict()
    for l in open(fn):
        p = l.strip().split(',')
        if len(p) == 29: d[(p[0], p[2])] = p
    return d
ref, new = load(sys.argv[1]), load(sys.argv[2])
H = "cfg,bits,trace,instr,b0,b1,b2,b3,b4,b5,ctaken,dirwrong,m0,m1,m2,m3,m4,m5,i0,i1,i2,i3,i4,i5,phantom,ph2,takencf,hit0,slow".split(',')
per = collections.OrderedDict()
for k, r in new.items():
    s = per.setdefault(k[0], [0, 0, 0])
    if k not in ref: s[2] += 1; continue
    diff = [f"{H[i]}:{ref[k][i]}->{r[i]}" for i in range(29) if ref[k][i] != r[i]]
    if diff: s[1] += 1; print(f"DIFF {k[0]} {k[1]}: " + ' '.join(diff))
    else: s[0] += 1
missing = [k for k in ref if k[0] in per and k not in new]
for c, (ok, bad, nr) in per.items(): print(f"{c:16s} identical={ok} differ={bad} not_in_ref={nr}")
if missing: print("in reference but not reproduced:", missing)
sys.exit(1 if any(v[1] or v[2] for v in per.values()) or missing else 0)
