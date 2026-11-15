#!/usr/bin/env python3
"""Escape the brackets of non-bus net names in an OpenRCX SPEF name map.

Timing-repair buffers give nets names such as f_ckpt[19]4336 (escaped identifier
\\f_ckpt[19]4336 in the Verilog netlist). OpenRCX writes them unescaped, so OpenSTA reads
them as a bus bit and cannot find the net (STA-1650) and those nets stay unannotated.
This rewrites such names as f_ckpt\\[19\\]4336 in place.
usage: fix_spef_names.py <file.spef[.gz]>"""
import gzip
import os
import re
import sys

src = sys.argv[1]
tmp = src + ".tmp"
pat = re.compile(r"^(\*\d+ )(\S*\[\d+\]\S+)$")
n = 0
op = gzip.open if src.endswith(".gz") else open
with op(src, "rt") as fi, op(tmp, "wt") as fo:
    in_map = False
    for line in fi:
        if line.startswith("*NAME_MAP"):
            in_map = True
        elif in_map and line.startswith("*PORTS") or line.startswith("*D_NET"):
            in_map = False
        if in_map:
            m = pat.match(line.rstrip("\n"))
            if m and "\\[" not in m.group(2):
                line = m.group(1) + m.group(2).replace("[", "\\[").replace("]", "\\]") + "\n"
                n += 1
        fo.write(line)
os.replace(tmp, src)
print(f"{src}: escaped {n} net names")
