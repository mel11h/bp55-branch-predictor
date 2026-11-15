#!/usr/bin/env python3
"""Compare a DRC report on the injected-violation layout with the expected outcome table.
usage: check_drc_tests.py tests.tsv report.lyrdb   -> PASS/FAIL per test, exit 1 on any FAIL"""
import re, sys
import xml.etree.ElementTree as ET
exp = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
items = []
for ev, el in ET.iterparse(sys.argv[2]):
    if el.tag == "item":
        c = (el.findtext("category") or "").strip("'")
        txt = " ".join((v.text or "") for v in el.find("values"))
        nums = [float(x) for x in re.findall(r"-?\d+\.?\d*", txt)]
        items.append((c, nums[0::2], nums[1::2])); el.clear()
bad = 0
for name, rule, want, x0, y0, x1, y1 in exp:
    x0, y0, x1, y1 = map(float, (x0, y0, x1, y1))
    n = sum(1 for c, xs, ys in items if c == rule and xs and min(xs) >= x0 and max(xs) <= x1 and min(ys) >= y0 and max(ys) <= y1)
    ok = (n > 0) if want == "1" else (n == 0)
    bad += not ok
    others = sorted(set(c for c, xs, ys in items if c != rule and xs and min(xs) >= x0 and max(xs) <= x1 and min(ys) >= y0 and max(ys) <= y1))
    print("%-4s %-18s %-16s expect %s got %d   other rules in cell: %s" % ("PASS" if ok else "FAIL", name, rule, ">0" if want == "1" else "0", n, ",".join(others)))
sys.exit(1 if bad else 0)
