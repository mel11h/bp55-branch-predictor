#!/usr/bin/env python3
"""Flatten the ICsprout55 standard-cell CDL into plain SPICE that KLayout reads without
parameter evaluation: every library cell becomes a .SUBCKT that contains only M devices with
numeric W/L. Primitive subcircuits (INV, NAND2, ...) instantiated with parameters such as
"pl=6e-08 pw=2.7e-07" are expanded recursively with those parameters substituted.

usage: cdl_flatten.py IN.cdl OUT.sp [--cells-regex 'H7R$']
"""
import re, sys

src, dst = sys.argv[1], sys.argv[2]
cell_re = re.compile(sys.argv[sys.argv.index("--cells-regex") + 1] if "--cells-regex" in sys.argv else r"H7R$")

lines, cur = [], ""
for raw in open(src, encoding="latin-1"):
    s = raw.rstrip("\n")
    if s.startswith("+"):
        cur += " " + s[1:]
        continue
    if cur:
        lines.append(cur)
    cur = s
if cur:
    lines.append(cur)

subckts = {}          # name -> (pins, defaults, body)
name = None
for s in lines:
    t = s.strip()
    if not t or t.startswith("*"):
        continue
    u = t.upper()
    if u.startswith(".SUBCKT"):
        w = t.split()
        name = w[1]
        pins, defaults = [], {}
        for x in w[2:]:
            if "=" in x:
                k, v = x.split("=", 1); defaults[k.lower()] = v
            else:
                pins.append(x)
        subckts[name] = (pins, defaults, [])
    elif u.startswith(".ENDS"):
        name = None
    elif name:
        subckts[name][2].append(t)

UNIT = {"f": 1e-15, "p": 1e-12, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "meg": 1e6, "g": 1e9}
def num(v, params):
    v = v.strip().strip("'")
    if v.lower() in params:
        return num(params[v.lower()], {})
    m = re.match(r"^([-+]?[0-9.]+(?:e[-+]?\d+)?)(meg|[fpnumkg])?$", v, re.I)
    if not m:
        raise ValueError("cannot evaluate %r" % v)
    return float(m.group(1)) * UNIT.get((m.group(2) or "").lower(), 1.0)

def expand(cname, netmap, params, prefix, out):
    pins, defaults, body = subckts[cname]
    p = dict(defaults); p.update(params)
    for t in body:
        w = t.split()
        el = w[0]
        if el[0] in "Mm":
            d, g, s_, b, model = w[1:6]
            kv = dict(x.split("=", 1) for x in w[6:] if "=" in x)
            kv = {k.lower(): v for k, v in kv.items()}
            W = num(kv["w"], p); L = num(kv["l"], p)
            mult = int(round(num(kv.get("m", "1"), p)))
            nets = [netmap.get(x, prefix + x) for x in (d, g, s_, b)]
            for i in range(mult):
                out.append("M%s%s%s %s %s %s %s %s W=%.4gU L=%.4gU" % (prefix.replace("/", "_"), el[1:], "" if mult == 1 else "_m%d" % i,
                           nets[0], nets[1], nets[2], nets[3], model, W * 1e6, L * 1e6))
        elif el[0] in "Dd":
            a, c, model = w[1:4]
            kv = {x.split("=", 1)[0].lower(): x.split("=", 1)[1] for x in w[4:] if "=" in x}
            nets = [netmap.get(x, prefix + x) for x in (a, c)]
            out.append("D%s%s %s %s %s A=%.4gP P=%.4gU" % (prefix.replace("/", "_"), el[1:], nets[0], nets[1], model,
                       num(kv.get("area", "0"), p) * 1e12, num(kv.get("pj", "0"), p) * 1e6))
        elif el[0] in "Xx":
            args = [x for x in w[1:] if x != "/"]
            kv = {x.split("=", 1)[0].lower(): x.split("=", 1)[1] for x in args if "=" in x}
            pos = [x for x in args if "=" not in x]
            sub = pos[-1]; conns = pos[:-1]
            spins = subckts[sub][0]
            assert len(spins) == len(conns), (cname, t)
            # parameter values may refer to the caller's parameters
            kv = {k: str(num(v, p)) for k, v in kv.items()}
            nm = {sp: netmap.get(c, prefix + c) for sp, c in zip(spins, conns)}
            expand(sub, nm, kv, prefix + el + "/", out)
        else:
            raise ValueError("unsupported element %r in %s" % (t, cname))

n = 0
with open(dst, "w") as f:
    f.write("* flattened from %s by cdl_flatten.py; M devices only, W/L in um\n" % src.split("/")[-1])
    for cname, (pins, defaults, body) in subckts.items():
        if not cell_re.search(cname):
            continue
        out = []
        expand(cname, {x: x for x in pins}, {}, "", out)
        f.write(".SUBCKT %s %s\n%s\n.ENDS %s\n\n" % (cname, " ".join(pins), "\n".join(out), cname))
        n += 1
print("cells written:", n, file=sys.stderr)
