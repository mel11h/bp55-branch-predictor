#!/usr/bin/env python3
"""rec2hex.py <in .rec[.gz]> <out text>: one line of 24 hex words per recorded cycle (for tb_replay.sv)."""
import gzip, struct, sys
src, dst = sys.argv[1:3]
f = gzip.open(src, "rb") if src.endswith(".gz") else open(src, "rb")
with open(dst, "w") as o:
    while True:
        b = f.read(96)
        if len(b) < 96:
            break
        o.write(" ".join("%08x" % x for x in struct.unpack("<24I", b)) + "\n")
