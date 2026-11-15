#!/usr/bin/env python3
"""Convert a flat structural (OpenROAD write_verilog) netlist into a SPICE top-level subcircuit
for LVS, using the pin order of the standard-cell subcircuits in a (flattened) CDL/SPICE file.

- supply pins (VDD/VSS by default) of every cell are tied to global nets VDD/VSS, since the
  Verilog carries no power pins;
- 'assign a = b;' aliases are merged;
- unconnected or omitted cell pins get unique dangling nets;
- ports keep their Verilog names (bus bits as name[i]); internal nets are renamed n<k>
  so escaped identifiers cannot confuse the SPICE reader (the map is written to OUT.netmap).

usage: verilog2spice.py IN.v[.gz] CELLS.sp OUT.sp [--top NAME] [--power VDD] [--ground VSS]
"""
import gzip, re, sys

vin, cells_sp, out = sys.argv[1:4]
opt = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
PWR, GND = opt("--power", "VDD"), opt("--ground", "VSS")

pins = {}
for l in open(cells_sp):
    if l.upper().startswith(".SUBCKT"):
        w = l.split(); pins[w[1]] = w[2:]

txt = (gzip.open(vin, "rt") if vin.endswith(".gz") else open(vin)).read()
txt = re.sub(r"//[^\n]*", "", txt)
txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
m = re.search(r"\bmodule\s+(\S+)\s*\((.*?)\)\s*;(.*?)\bendmodule", txt, re.S)
top = opt("--top", m.group(1)); body = m.group(3)

ID = r"(?:\\\S+|[A-Za-z_][A-Za-z0-9_$]*)"
def norm(n):
    n = n.strip()
    if n.startswith("\\"): n = n[1:]
    return n

ports, widths = [], {}
stmts = [s.strip() for s in body.split(";") if s.strip()]
for s in stmts:
    mm = re.match(r"(input|output|inout)\s*(\[\s*(\d+)\s*:\s*(\d+)\s*\])?\s*(.*)$", s, re.S)
    if mm:
        for nm in mm.group(5).split(","):
            nm = norm(nm)
            if mm.group(2):
                a, b = int(mm.group(3)), int(mm.group(4))
                rng = range(a, b - 1, -1) if a >= b else range(a, b + 1)
                ports += ["%s[%d]" % (nm, i) for i in rng]; widths[nm] = (a, b)
            else:
                ports.append(nm)

parent = {}
def find(x):
    parent.setdefault(x, x)
    while parent[x] != x:
        parent[x] = parent[parent[x]]; x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra == rb: return
    # keep port names as representatives
    if rb in pset: ra, rb = rb, ra
    parent[rb] = ra
pset = set(ports)

def bits(expr):
    expr = expr.strip()
    if expr.startswith("{"):
        out = []
        for part in re.findall(r"\\\S+|[^,{}\s]+(?:\s*\[[^\]]*\])?", expr[1:-1]):
            out += bits(part)
        return out
    mm = re.match(r"(\\\S+|[A-Za-z_][A-Za-z0-9_$]*)\s*(\[\s*(\d+)\s*(?::\s*(\d+))?\s*\])?$", expr)
    if not mm:
        if re.match(r"\d+'b[01]+", expr): raise ValueError("constant in netlist: " + expr)
        raise ValueError("cannot parse net expression %r" % expr)
    nm = norm(mm.group(1))
    if mm.group(2) is None:
        if nm in widths:
            a, b = widths[nm]; rng = range(a, b - 1, -1) if a >= b else range(a, b + 1)
            return ["%s[%d]" % (nm, i) for i in rng]
        return [nm]
    if mm.group(4) is None:
        return ["%s[%s]" % (nm, mm.group(3))]
    a, b = int(mm.group(3)), int(mm.group(4))
    rng = range(a, b - 1, -1) if a >= b else range(a, b + 1)
    return ["%s[%d]" % (nm, i) for i in rng]

insts = []
for s in stmts:
    if re.match(r"(input|output|inout|wire)\b", s): continue
    mm = re.match(r"assign\s+(.*?)\s*=\s*(.*)$", s, re.S)
    if mm:
        for a, b in zip(bits(mm.group(1)), bits(mm.group(2))): union(a, b)
        continue
    mm = re.match(r"(\S+)\s+(\\\S+|\S+)\s*\((.*)\)$", s, re.S)
    if not mm: raise ValueError("cannot parse statement: %r" % s[:120])
    cell, inst, conns = mm.group(1), norm(mm.group(2)), mm.group(3)
    cmap = {}
    for pm in re.finditer(r"\.(\w+)\s*\(\s*(.*?)\s*\)\s*(?:,|$)", conns, re.S):
        if pm.group(2): cmap[pm.group(1)] = bits(pm.group(2))[0]
    insts.append((cell, inst, cmap))

names, k = {}, [0]
def spice_name(n):
    r = find(n)
    if r in pset: return r
    if r not in names:
        k[0] += 1; names[r] = "n%d" % k[0]
    return names[r]

missing = set(); dangling = 0
with open(out, "w") as f:
    # ports aliased to another port by 'assign' (e.g. assign f_ckpt[37] = f_ras_top[2]-driving net) are one
    # electrical net; keep one pin per net (the layout has one net carrying both labels)
    alias = [p for p in ports if find(p) != p]
    keep = [p for p in ports if find(p) == p]
    for p in alias: f.write("* port %s is the same net as port %s\n" % (p, find(p)))
    f.write("* top level %s from %s by verilog2spice.py\n.SUBCKT %s %s\n" % (top, vin.split("/")[-1], top, " ".join(keep)))
    for cell, inst, cmap in insts:
        if cell not in pins: missing.add(cell); continue
        nets = []
        for p in pins[cell]:
            if p == PWR: nets.append("VDD")
            elif p == GND: nets.append("VSS")
            elif p in cmap: nets.append(spice_name(cmap[p]))
            else:
                dangling += 1; nets.append("nc_%d" % dangling)
        f.write("X%s %s %s\n" % (re.sub(r"[^A-Za-z0-9_]", "_", inst), " ".join(nets), cell))
    f.write(".ENDS %s\n" % top)
used = sorted(set(c for c, _, _ in insts if c in pins))
with open(out + ".cells", "w") as f:
    f.write("\n".join(used) + "\n")
with open(out + ".netmap", "w") as f:
    for r, n in sorted(names.items(), key=lambda x: int(x[1][1:])): f.write("%s %s\n" % (n, r))
print("aliased ports %d; " % sum(1 for p in ports if find(p) != p), end="", file=sys.stderr)
print("instances %d, ports %d, internal nets %d, dangling pins %d, unknown cells %s" % (len(insts), len(ports), len(names), dangling, sorted(missing)), file=sys.stderr)
