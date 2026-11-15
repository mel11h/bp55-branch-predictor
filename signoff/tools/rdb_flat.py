#!/usr/bin/env python3
"""Per-rule split of a hierarchical KLayout DRC report: markers in the top cell vs inside cell
masters, and a flat estimate (markers per master x placements of that master in the DEF).
usage: rdb_flat.py REPORT.lyrdb[.gz] DEF[.gz] [TOP]"""
import gzip, re, sys, collections
import xml.etree.ElementTree as ET
op = lambda f: gzip.open(f, "rt") if f.endswith(".gz") else open(f)
top = sys.argv[3] if len(sys.argv) > 3 else "bp55"
inst = collections.Counter()
for l in op(sys.argv[2]):
    m = re.match(r"\s*-\s+\S+\s+(\S+)\s+\+", l)
    if m: inst[m.group(1)] += 1
    if l.startswith("END COMPONENTS"): break
per = collections.defaultdict(collections.Counter)
for ev, el in ET.iterparse(op(sys.argv[1])):
    if el.tag == "item":
        c = (el.findtext("category") or "").strip("'"); cell = (el.findtext("cell") or "").strip("'")
        per[c][re.sub(r"\$VAR\d+$", "", cell)] += 1; el.clear()
print("rule\ttop_markers\tcell_markers\tflat_estimate\tmasters_affected\texamples")
for r in sorted(per):
    t = per[r].get(top, 0)
    cells = {k: v for k, v in per[r].items() if k != top}
    flat = t + sum(v * inst.get(k, 0) for k, v in cells.items() if inst.get(k))
    unknown = [k for k in cells if not inst.get(k)]
    print("%s\t%d\t%d\t%d%s\t%d\t%s" % (r, t, sum(cells.values()), flat, "+" if unknown else "", len(cells),
          ",".join(sorted(cells, key=lambda k: -cells[k])[:4])))
