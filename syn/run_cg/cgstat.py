#!/usr/bin/env python3
"""Clock-gating statistics of a structural netlist (yosys or OpenROAD write_verilog).

Counts flops, ICG cells, and flops whose clock pin is reached from an ICG output
through any number of buffers/inverters (so it also works on a post-CTS netlist).
usage: cgstat.py <netlist.v[.gz]>
"""
import collections
import gzip
import re
import sys

INST = re.compile(r"^\s*([A-Za-z_]\w*)\s+(\\\S+|[A-Za-z_][\w$\[\]]*)\s*\((.*?)\);", re.S | re.M)
PIN = re.compile(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)")


def main(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as f:
        text = f.read()
    m = re.search(r"\bmodule\s+bp55\b.*?;(.*)\bendmodule", text, re.S)
    body = m.group(1)
    drv = {}                       # net -> (inst, cell)
    insts = []
    for cell, name, conns in INST.findall(body):
        if cell in ("module", "input", "output", "wire", "assign", "reg"):
            continue
        pins = dict(PIN.findall(conns))
        insts.append((cell, name, pins))
        for p in ("Y", "ECK", "Q", "QN", "Z"):
            if p in pins and pins[p]:
                drv[pins[p]] = (name, cell, pins)
    flops = [i for i in insts if i[0].startswith(("DFF", "SDFF", "EDFF"))]
    icgs = [i for i in insts if i[0].startswith("ICG")]
    cnt = collections.Counter(i[0] for i in insts)

    def gated(net):
        seen = 0
        while net in drv and seen < 64:
            name, cell, pins = drv[net]
            if cell.startswith("ICG"):
                return name
            if cell.startswith(("BUF", "INV", "CLKBUF", "CLKINV")):
                net = pins.get("A", "")
                seen += 1
                continue
            return None
        return None

    per_icg = collections.Counter()
    ng = 0
    for cell, name, pins in flops:
        ck = pins.get("CK") or pins.get("CKN") or ""
        g = gated(ck)
        if g:
            ng += 1
            per_icg[g] += 1
    hist = collections.Counter(per_icg.values())
    print(f"instances {len(insts)}  flops {len(flops)}  ICG {len(icgs)}  "
          f"flops gated {ng}  ungated {len(flops) - ng}")
    print("ICG cell types: " + ", ".join(f"{c} {n}" for c, n in sorted(cnt.items()) if c.startswith("ICG")))
    print("flops per ICG (fanout: count): " + ", ".join(f"{k}: {v}" for k, v in sorted(hist.items())))
    if len(icgs) != len(per_icg):
        print(f"ICGs driving no flop: {len(icgs) - len(per_icg)}")


if __name__ == "__main__":
    main(sys.argv[1])
