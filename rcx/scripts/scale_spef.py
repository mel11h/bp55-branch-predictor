#!/usr/bin/env python3
"""Scale every capacitance (ground and coupling) of a SPEF by a factor; R unchanged.
usage: scale_spef.py <in.spef[.gz]> <out.spef.gz> <factor>"""
import gzip
import sys

src, dst, f = sys.argv[1], sys.argv[2], float(sys.argv[3])
op = gzip.open if src.endswith(".gz") else open
sec = None
with op(src, "rt") as fi, gzip.open(dst, "wt") as fo:
    for line in fi:
        t = line.split()
        if t and t[0].startswith("*"):
            if t[0] == "*D_NET":
                t[2] = f"{float(t[2]) * f:.6g}"
                line = " ".join(t) + "\n"
            sec = t[0] if t[0] in ("*CAP", "*RES", "*CONN", "*END", "*D_NET") else sec
        elif sec == "*CAP" and len(t) in (3, 4):
            t[-1] = f"{float(t[-1]) * f:.6g}"
            line = " ".join(t) + "\n"
        fo.write(line)
