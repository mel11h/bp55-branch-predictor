#!/usr/bin/env python3
"""Parse a flat (TVF-expanded, preprocessed) SVRF deck into rule records and find, for each
rule, the primary input layers it depends on. With --present L/D,... it also marks rules whose
primary inputs are all absent from a layout (such rules cannot produce results there).
usage: deck_rules.py deck.svrf [--present 2/1,9/1,...] > rules.tsv"""
import re, sys
src = open(sys.argv[1], encoding="latin-1").read().split("\n")
present = set()
if "--present" in sys.argv:
    present = set(sys.argv[sys.argv.index("--present") + 1].split(","))
KW = set("""AND OR NOT XOR INT EXT ENC ENCLOSE ENCLOSURE INSIDE OUTSIDE INTERACT TOUCH CUT EDGE COIN
SIZE BY WITH WIDTH LENGTH AREA HOLES INNER EMPTY RECTANGLE ANGLE ABUT SINGULAR REGION OPPOSITE
DENSITY WINDOW STEP BACKUP PRINT OF LAYER GOOD ALSO OVERLAP DFM COPY SPACE CONVEX EXPAND
UNDEROVER OVERUNDER CONNECTED SHIELDED PARA ONLY PROJ PROJECTING MEASURE ALL EXTENTS EXTENT
GRADIENT ABSOLUTE ASPECT ORTHOGONAL INTERSECTING ACUTE NOTCH SPACE PERP SHIELD LEVEL
DRAWN ORIGINAL SKEW OFFGRID ANGLED NET AREA NETAREA RATIO PERIMETER VERTEX WITH TEXT
STAMP DONUT GROW SHRINK MERGE EXCLUDE FALSE TRUE EXT1 EXT2 CENTERS CENTERLINE MAGNIFY
ROTATE SHIFT SNAP TOP BOTTOM LEFT RIGHT POLYGON ENDPOINT FIRST SECOND FILL RANGE
ANGLE1 ANGLE2 MEASURE OUTSIDE CORNER EDGE CONVEX BOTH EITHER EDGE PATHCHK GROUND POWER LABELED
""".split())
defs, maps, cur, rules = {}, {}, None, []
lname_map = {}
pending = []
for ln in src:
    t = ln.split("//")[0].strip()
    m = re.match(r"LAYER MAP (\d+) (DATATYPE|TEXTTYPE) (\d+) (\d+)", t)
    if m:
        maps.setdefault(m.group(4), []).append("%s/%s%s" % (m.group(1), m.group(3), "t" if m.group(2) == "TEXTTYPE" else "")); continue
    m = re.match(r"LAYER (\S+)\s+(\d+)$", t)
    if m: lname_map[m.group(1)] = maps.get(m.group(2), []); continue
    m = re.match(r"([A-Za-z0-9_:]+)\s*\{$", t)
    if m and cur is None: cur = {"name": m.group(1), "text": [], "desc": []}; continue
    if t == "}" and cur is not None: rules.append(cur); cur = None; continue
    if cur is not None:
        if t.startswith("@"): cur["desc"].append(t[1:].strip())
        else: cur["text"].append(t)
        continue
    m = re.match(r"([A-Za-z0-9_:]+)\s*=\s*(.+)$", t)
    if m: defs[m.group(1)] = m.group(2)
def toks(expr):
    return [w for w in re.findall(r"[A-Za-z_][A-Za-z0-9_:]*", expr) if w not in KW and not w.isupper() or w in defs or w in lname_map]
def prim(expr, local, seen):
    out = set()
    for w in re.findall(r"[A-Za-z_][A-Za-z0-9_:]*", expr):
        if w in seen: continue
        if w == "DRC:1": out.add("CHIP_EXTENT"); continue
        if w in local: out |= prim(local[w], local, seen | {w})
        elif w in lname_map: out.add(w)
        elif w in defs: out |= prim(defs[w], local, seen | {w})

    return out
for r in rules:
    local = {}
    body = []
    for t in r["text"]:
        m = re.match(r"([A-Za-z0-9_:]+)\s*=\s*(.+)$", t)
        if m: local[m.group(1)] = m.group(2)
        else: body.append(t)
    p = prim(" ".join(body), local, set()) if body else set()
    if not p: p = prim(" ".join(local.values()), local, set())
    gds = sorted(set(g for l in p for g in lname_map.get(l, [])))
    live = "CHIP_EXTENT" in p or any(g.rstrip("t") in present for g in gds)
    print("\t".join([r["name"], "live" if live else "absent", ",".join(sorted(p)), " | ".join(r["desc"])[:300]]))
