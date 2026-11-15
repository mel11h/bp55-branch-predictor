#!/usr/bin/env python3
"""Compare net capacitances of two SPEF files (for example extracted vs estimated), and
put the total wire capacitance next to the total pin capacitance of the block.

usage: compare_spef.py <a.spef[.gz]> <b.spef[.gz]> [--def layout.def[.gz] --lib cells.lib]
                       [--label-a extracted] [--label-b estimate] [--top N]
prints: totals (ground / coupling / total) of each file, the distribution of the
per-net ratio a/b over nets present in both, the N nets with the largest absolute
difference, and (with --def/--lib) the total input-pin capacitance of all nets.
"""
import argparse
import gzip
import re
import statistics


def opener(p):
    return gzip.open(p, "rt") if p.endswith(".gz") else open(p)


def read_spef(path):
    """-> {net: [total, ground, coupling, res_sum]} (fF, ohm); total = ground + coupling lines."""
    names = {}
    nets = {}
    cunit = 1.0
    runit = 1.0
    section = None
    cur = None
    with opener(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            k = t[0]
            if k == "*C_UNIT":
                v, u = float(t[1]), t[2].upper()
                cunit = v * {"FF": 1.0, "PF": 1e3, "F": 1e15}[u]
            elif k == "*R_UNIT":
                runit = float(t[1]) * {"OHM": 1.0, "KOHM": 1e3}[t[2].upper()]
            elif k == "*NAME_MAP":
                section = "map"
            elif section == "map" and k.startswith("*") and k[1:].isdigit():
                names[k] = t[1]
            elif k == "*D_NET":
                section = None
                cur = names.get(t[1], t[1]).replace("\\", "")
                nets[cur] = [float(t[2]) * cunit, 0.0, 0.0, 0.0]
            elif k == "*CAP":
                section = "cap"
            elif k == "*RES":
                section = "res"
            elif k in ("*CONN", "*END"):
                section = None if k == "*END" else "conn"
            elif cur is not None and section == "cap":
                if len(t) == 3:
                    nets[cur][1] += float(t[2]) * cunit
                elif len(t) == 4:
                    nets[cur][2] += float(t[3]) * cunit
            elif cur is not None and section == "res" and len(t) == 4:
                nets[cur][3] += float(t[3]) * runit
    # total = sum of the capacitor lines (what STA uses); the *D_NET header value is ignored
    for v in nets.values():
        v[0] = v[1] + v[2]
    return nets


def pin_cap(def_path, lib_path):
    """Total input-pin capacitance (fF) of all nets in a DEF, from Liberty pin caps."""
    caps = {}
    cell = None
    pin = None
    unit = 1.0
    with opener(lib_path) as f:
        for line in f:
            s = line.strip()
            m = re.match(r"capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*(\w+)", s)
            if m:
                unit = float(m.group(1)) * {"pf": 1e3, "ff": 1.0}[m.group(2).lower()]
            m = re.match(r"cell\s*\(\s*\"?([\w]+)\"?\s*\)", s)
            if m:
                cell = m.group(1)
                continue
            m = re.match(r"pin\s*\(\s*\"?([\w]+)\"?\s*\)", s)
            if m:
                pin = m.group(1)
                continue
            m = re.match(r"capacitance\s*:\s*([\d.eE+-]+)", s)
            if m and cell and pin and (cell, pin) not in caps:
                caps[(cell, pin)] = float(m.group(1)) * unit
    comp = {}
    total = 0.0
    n = 0
    sec = None
    with opener(def_path) as f:
        for line in f:
            if line.startswith("COMPONENTS"):
                sec = "c"
            elif line.startswith("END COMPONENTS"):
                sec = None
            elif line.startswith("NETS"):
                sec = "n"
            elif line.startswith("END NETS"):
                break
            elif sec == "c":
                m = re.match(r"\s*-\s+(\S+)\s+(\S+)", line)
                if m:
                    comp[m.group(1)] = m.group(2)
            elif sec == "n":
                for inst, p in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line):
                    if inst == "PIN":
                        continue
                    c = caps.get((comp.get(inst, ""), p))
                    if c is not None:
                        total += c
                        n += 1
    return total, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--label-a", default="extracted")
    ap.add_argument("--label-b", default="estimate")
    ap.add_argument("--def", dest="defp")
    ap.add_argument("--lib")
    ap.add_argument("--top", type=int, default=10)
    o = ap.parse_args()
    A, B = read_spef(o.a), read_spef(o.b)
    for lab, X in ((o.label_a, A), (o.label_b, B)):
        tot = sum(v[0] for v in X.values())
        g = sum(v[1] for v in X.values())
        c = sum(v[2] for v in X.values())
        print(f"{lab:10s}: {len(X)} nets, total {tot/1000:.2f} pF (ground {g/1000:.2f} pF, coupling {c/1000:.2f} pF"
              f" = {100*c/max(tot,1e-12):.1f} %), sum of R {sum(v[3] for v in X.values())/1e3:.1f} kohm")
    common = [n for n in A if n in B and B[n][0] > 0 and A[n][0] > 0]
    r = sorted(A[n][0] / B[n][0] for n in common)
    q = lambda p: r[min(len(r) - 1, int(p * len(r)))]  # noqa: E731
    print(f"per-net total C ratio {o.label_a}/{o.label_b} over {len(common)} nets: "
          f"median {statistics.median(r):.3f}, p5 {q(0.05):.3f}, p25 {q(0.25):.3f}, p75 {q(0.75):.3f}, p95 {q(0.95):.3f}, "
          f"min {r[0]:.3f}, max {r[-1]:.3f}")
    sa = sum(A[n][0] for n in common)
    sb = sum(B[n][0] for n in common)
    print(f"sum over common nets: {o.label_a} {sa/1000:.2f} pF, {o.label_b} {sb/1000:.2f} pF, ratio {sa/sb:.3f}")
    big = [n for n in common if B[n][0] > 20.0]
    if big:
        rb = sorted(A[n][0] / B[n][0] for n in big)
        print(f"nets with {o.label_b} C > 20 fF ({len(big)}): ratio median {statistics.median(rb):.3f}, "
              f"p5 {rb[int(0.05*len(rb))]:.3f}, p95 {rb[min(len(rb)-1,int(0.95*len(rb)))]:.3f}")
    diff = sorted(common, key=lambda n: -abs(A[n][0] - B[n][0]))[: o.top]
    print(f"largest absolute differences (fF): net {o.label_a} {o.label_b}")
    for n in diff:
        print(f"  {n} {A[n][0]:.2f} {B[n][0]:.2f}")
    if o.defp and o.lib:
        pc, npins = pin_cap(o.defp, o.lib)
        wa = sum(v[0] for v in A.values())
        print(f"input-pin capacitance ({npins} pins, Liberty {o.lib.rsplit('/',1)[-1]}): {pc/1000:.2f} pF; "
              f"{o.label_a} wire C / pin C = {wa/pc:.2f}")


if __name__ == "__main__":
    main()
