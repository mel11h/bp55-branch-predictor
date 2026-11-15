#!/usr/bin/env python3
"""Keep only the .SUBCKT blocks named in a list file. usage: prune_spice.py IN.sp NAMES.txt OUT.sp"""
import sys
keep = set(open(sys.argv[2]).read().split())
out, cur, buf = [], None, []
for l in open(sys.argv[1]):
    w = l.split()
    if w and w[0].upper() == ".SUBCKT": cur = w[1]; buf = []
    if cur is None: out.append(l); continue
    buf.append(l)
    if w and w[0].upper() == ".ENDS":
        if cur in keep: out += buf
        cur = None
open(sys.argv[3], "w").writelines(out)
