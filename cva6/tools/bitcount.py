#!/usr/bin/env python3
"""Count the branch-predictor state bits of a Verilated CVA6 model.

  bitcount.py <verilator obj dir>
  bitcount.py --dump <verilator obj dir>     every member with its width

Reads the member declarations of the generated model headers (V*___024root.h)
and sums the widths of the state registers of CVA6's predictor modules:
  BHT  i_bht ... bht_q       (bht.sv, gen_asic_bht; bht2lvl.sv for PH_BHT)
  BTB  i_btb ... btb_q       (btb.sv, gen_asic_btb)
  RAS  i_ras ... stack_q     (ras.sv)
Widths come from Verilator's /*msb:lsb*/ annotations, multiplied by every
VlUnpacked dimension. Only *_q registers of those instances are counted: the
frontend's one-entry bht_q/btb_q holding registers (used for unaligned RVC
instructions) and pipeline copies of predictions are not predictor tables.
A structure that is absent (size 0) prints 0. For BP55 builds the state registers
of the i_bp55 instance are summed as well (expected 8523, rtl/bp55.sv).
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


# BP55's state registers (rtl/bp55.sv "state" section), in the frontend's i_bp55 instance
BP55_STATE = {"btb_v", "btb_tag", "btb_type", "btb_tgt", "itc_v", "itc_tag", "itc_tgt", "bim", "ttag0", "ttag1",
              "ttag2", "tctr0", "tctr1", "tctr2", "tu0", "tu1", "tu2", "ras", "rasp", "ghr", "thr", "use_alt",
              "rstcnt", "clr_busy", "clr_cnt"}


def members(objdir):
    """(name, bits) of every member declared in the model's root headers"""
    out = {}
    for h in glob.glob(objdir + "/*___024root.h"):
        for ln in open(h):
            m = DECL.match(ln)
            if m:
                out[m.group(2)] = width(m.group(1))
    return out


def main():
    if sys.argv[1] == "--dump":          # every member, for cva6/tools/statediff.py
        for n, w in sorted(members(sys.argv[2]).items()):
            print(w, n)
        return
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
    bp = {}
    for n, w in members(sys.argv[1]).items():
        if "__DOT__i_bp55__DOT__" in n:
            base = re.sub(r"(__BRA__\d+__KET__)+$", "", n.split("__DOT__i_bp55__DOT__", 1)[1])
            if base in BP55_STATE:
                bp[base] = bp.get(base, 0) + w
    for n in sorted(bp):
        print(f"BP55 {bp[n]:6d}  i_bp55 {n}")
        per.setdefault("BP55", 0)
        per["BP55"] += bp[n]
        total += bp[n]
    print(" ".join(f"{s}={per[s]}" for s in per) + f" total={total}")


if __name__ == "__main__":
    main()
