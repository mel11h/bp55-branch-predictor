#!/usr/bin/env python3
"""Prepare a KLayout-extracted layout netlist and the schematic for a netgen comparison.

layout (KLayout writes the 3-terminal MOS with bulk = source):
  bulk of nm* devices -> the subcircuit's VSS net, pm* devices -> VDD (the CDL ties bulk the same
  way; the well/substrate ties themselves are checked separately, see README of signoff/).
schematic: instances of device-less cells (fillers, tap cells) are removed from the top level,
  because KLayout drops device-less circuits from the extracted netlist.
usage: lvs_netgen_prep.py LAYOUT.cir SCHEMATIC.sp OUT_LAYOUT.cir OUT_SCHEMATIC.sp
"""
import re, sys
lay, sch, olay, osch = sys.argv[1:5]
def joined(fn):
    out = []
    for l in open(fn):
        if l.startswith("+") and out: out[-1] = out[-1].rstrip("\n") + " " + l[1:]
        else: out.append(l)
    return out
fixed = 0
with open(olay, "w") as f:
    pins = []
    for l in joined(lay):
        w = l.split()
        if w and w[0].upper() == ".SUBCKT": pins = w[2:]
        if w and w[0][0] in "Mm" and len(w) >= 6:
            model = w[5].lower()
            sup = "VSS" if model.startswith("nm") else "VDD" if model.startswith("pm") else None
            if sup and sup in pins:
                w[4] = sup; fixed += 1; l = " ".join(w) + "\n"
        f.write(l.replace("\\$", "n_"))   # KLayout escapes generated names as \$12
empty, cur, ndev = set(), None, 0
lines = joined(sch)
for l in lines:
    w = l.split()
    if not w: continue
    if w[0].upper() == ".SUBCKT": cur, ndev = w[1], 0
    elif w[0][0] in "MmDdXx" and cur: ndev += 1
    elif w[0].upper() == ".ENDS" and cur:
        if ndev == 0: empty.add(cur)
        cur = None
dropped = 0
with open(osch, "w") as f:
    for l in lines:
        w = l.split()
        if w and w[0][0] in "Xx" and w[-1] in empty: dropped += 1; continue
        f.write(l)
print("layout MOS bulk set: %d; device-less cells: %s; schematic instances dropped: %d" % (fixed, " ".join(sorted(empty)), dropped), file=sys.stderr)
