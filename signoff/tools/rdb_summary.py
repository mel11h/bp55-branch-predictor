#!/usr/bin/env python3
"""Summarise a KLayout .lyrdb (optionally .gz): violation count per category, plus the first
N sample locations (bbox centre of each item, in um). usage: rdb_summary.py FILE [N]"""
import gzip, re, sys
import xml.etree.ElementTree as ET
fn = sys.argv[1]; nsamp = int(sys.argv[2]) if len(sys.argv) > 2 else 3
f = gzip.open(fn) if fn.endswith(".gz") else open(fn, "rb")
counts, samples, desc = {}, {}, {}
cat_stack = []
for ev, el in ET.iterparse(f, events=("start", "end")):
    if ev == "end" and el.tag == "category" and el.find("name") is not None:
        desc[el.findtext("name")] = el.findtext("description") or ""
    if ev == "end" and el.tag == "item":
        c = (el.findtext("category") or "").strip("'")
        counts[c] = counts.get(c, 0) + 1
        if len(samples.setdefault(c, [])) < nsamp:
            v = el.find("values")
            txt = (v[0].text or "") if v is not None and len(v) else ""   # geometry is the first value; others are annotations
            nums = [float(x) for x in re.findall(r"-?\d+\.?\d*", txt)]
            if nums:
                xs, ys = nums[0::2], nums[1::2]
                samples[c].append("%s(%.3f,%.3f)" % ((el.findtext("cell") or "").strip("'") + ":" if el.findtext("cell") else "", (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2))
        el.clear()
for c in sorted(desc):
    print("%s\t%d\t%s\t%s" % (c, counts.get(c, 0), " ".join(samples.get(c, [])), desc[c]))
