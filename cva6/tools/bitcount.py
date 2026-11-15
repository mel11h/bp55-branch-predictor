#!/usr/bin/env python3
"""Count the branch-predictor state bits of a Verilated CVA6 model.

  bitcount.py <verilator obj dir>

Reads the member declarations of the generated model headers (V*___024root.h)
and sums the widths of the state registers of CVA6's predictor modules:
  BHT  i_bht ... bht_q       (bht.sv, gen_asic_bht; bht2lvl.sv for PH_BHT)
  BTB  i_btb ... btb_q       (btb.sv, gen_asic_btb)
  RAS  i_ras ... stack_q     (ras.sv)
Widths come from Verilator's /*msb:lsb*/ annotations, multiplied by every
VlUnpacked dimension. Only *_q registers of those instances are counted: the
frontend's one-entry bht_q/btb_q holding registers (used for unaligned RVC
instructions) and pipeline copies of predictions are not predictor tables.
A structure that is absent (size 0) prints 0.
"""
import glob
import re
import sys

STRUCTS = [
    ("BHT", re.compile(r"__DOT__i_bht__DOT__(\w*__DOT__)?bht_q(__BRA__\d+__KET__)*$")),
    ("BTB", re.compile(r"__DOT__i_btb__DOT__(\w*__DOT__)?btb_q(__BRA__\d+__KET__)*$")),
    ("RAS", re.compile(r"__DOT__i_ras__DOT__stack_q(__BRA__\d+__KET__)*$")),
]
# Verilator splits some arrays into one member per element (name__BRA__<i>__KET__).
DECL = re.compile(r"^\s*((?:::)?(?:VlUnpacked<.*>|VlWide<\d+>/\*\d+:\d+\*/|[CSIQ]Data/\*\d+:\d+\*/))\s+(\w+);")


def width(t):
    """Bits of one declaration type string."""
    dims = 1
    t = t.replace("::", "")
    while t.startswith("VlUnpacked<"):
        inner, n = re.match(r"VlUnpacked<(.*), (\d+)>$", t).groups()
        dims *= int(n)
        t = inner
    m = re.search(r"/\*(\d+):(\d+)\*/", t)
    return dims * (int(m.group(1)) - int(m.group(2)) + 1)


def main():
    seen = {}
    for h in glob.glob(sys.argv[1] + "/*___024root.h"):
        for ln in open(h):
            m = DECL.match(ln)
            if not m:
                continue
            t, name = m.groups()
            for s, pat in STRUCTS:
                if "i_frontend__DOT__" in name and pat.search(name):
                    seen[name] = (s, width(t))
    total = 0
    per = {s: 0 for s, _ in STRUCTS}
    for name, (s, w) in sorted(seen.items()):
        per[s] += w
        total += w
        print(f"{s} {w:6d}  {name.split('i_frontend__DOT__', 1)[1]}")
    print(" ".join(f"{s}={per[s]}" for s in per) + f" total={total}")


if __name__ == "__main__":
    main()
