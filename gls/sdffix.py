#!/usr/bin/env python3
"""Rewrite an OpenSTA SDF so that Icarus 12 can read it, choosing one corner value.

usage: sdffix.py <in.sdf> <out.sdf> max|min

Icarus 12 rejects two things OpenSTA writes: COND expressions such as (COND (~A0 & A1 & C0) ...) and
(min::max) triples with an empty typical value; its timing checks are not executed in any case.
This script
  - replaces every (a::b) / (a:b:c) triple by (v:v:v), v = the max or min value;
  - merges, per cell instance, all IOPATH entries for the same (input, output) pair, with and without
    COND, into one unconditional IOPATH holding the max (or min) of the rise and of the fall values
    (pessimistic for setup with max, for hold with min);
  - drops TIMINGCHECK blocks (Icarus 12 does not evaluate $setuphold / $width);
  - keeps INTERCONNECT entries unchanged.
"""
import re
import sys

src, dst, mode = sys.argv[1:4]
pick = max if mode == "max" else min
txt = open(src).read()


def val(t):
    nums = [float(x) for x in t.split(":") if x.strip() != ""]
    return pick(nums) if nums else None


def trip(m):
    v = val(m.group(1))
    return "()" if v is None else "(%.4f:%.4f:%.4f)" % (v, v, v)


out = []
pos = 0
# split into CELL blocks by a small parenthesis-matching scanner
cells = []
i = 0
n = len(txt)
head_end = txt.find("(CELL")
out.append(txt[:head_end])
i = head_end
depth_start = None
while i < n:
    j = txt.find("(CELL", i)
    if j < 0:
        out.append(txt[i:])
        break
    out.append(txt[i:j])
    d = 0
    k = j
    while k < n:
        c = txt[k]
        if c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0:
                break
        k += 1
    cell = txt[j:k + 1]
    i = k + 1
    if "(IOPATH" in cell and "(INSTANCE)" not in cell:
        paths = {}
        order = []
        for m in re.finditer(r"\(IOPATH\s+(\((?:posedge|negedge)\s+[^()\s]+\)|[^()\s]+)\s+([^()\s]+)\s+\(([^()]*)\)\s*\(([^()]*)\)\s*\)", cell):
            key = (m.group(1), m.group(2))
            r, f = val(m.group(3)), val(m.group(4))
            if key not in paths:
                paths[key] = [r, f]; order.append(key)
            else:
                p = paths[key]
                p[0] = r if p[0] is None else (p[0] if r is None else pick(p[0], r))
                p[1] = f if p[1] is None else (p[1] if f is None else pick(p[1], f))
        hdr = re.match(r"\(CELL\s*\(CELLTYPE[^)]*\)\s*\(INSTANCE[^)]*\)", cell, re.S).group(0)
        body = ["%s\n  (DELAY\n   (ABSOLUTE" % hdr]
        for key in order:
            r, f = paths[key]
            fmt = lambda v: "()" if v is None else "(%.4f:%.4f:%.4f)" % (v, v, v)
            body.append("    (IOPATH %s %s %s %s)" % (key[0], key[1], fmt(r), fmt(f)))
        body.append("   )\n  )\n )")
        cell = "\n".join(body)
    else:
        cell = re.sub(r"\(([-0-9.]*:[-0-9.]*:[-0-9.]*)\)", trip, cell)
    out.append(cell)
s = "".join(out)
s = re.sub(r"\(VOLTAGE[^)]*\)\s*|\(PROCESS[^)]*\)\s*|\(TEMPERATURE[^)]*\)\s*", "", s)
open(dst, "w").write(s)
