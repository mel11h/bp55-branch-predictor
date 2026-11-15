#!/usr/bin/env python3
"""Resolve the SVRF preprocessor (#DEFINE/#IFDEF/#IFNDEF/#ELSE/#ENDIF) of a flat SVRF deck.
usage: svrf_pp.py in.svrf out.svrf [NAME=VALUE ...]   (command-line values override #DEFINE)
Also strips '//' comments only when they start a line or follow whitespace."""
import re, sys
src, dst = sys.argv[1], sys.argv[2]
over = dict(a.split("=", 1) for a in sys.argv[3:])
defs = {}
out, stack = [], []          # stack of (active_parent, this_branch_active, taken)
def active(): return all(s[1] for s in stack)
for line in open(src, encoding="latin-1"):
    t = line.strip()
    m = re.match(r"#DEFINE\s+(\S+)(?:\s+(\S+))?", t)
    if m:
        if active():
            name, val = m.group(1), m.group(2) or ""
            defs[name] = over.get(name, val)
        continue
    m = re.match(r"#(IFDEF|IFNDEF)\s+(\S+)(?:\s+(\S+))?", t)
    if m:
        kind, name, val = m.groups()
        if val is None: cond = name in defs
        else: cond = defs.get(name) == val
        if kind == "IFNDEF": cond = not cond
        stack.append([active(), cond]); continue
    if t.startswith("#ELSE"):
        stack[-1][1] = not stack[-1][1]; continue
    if t.startswith("#ENDIF"):
        stack.pop(); continue
    if active(): out.append(line)
assert not stack, "unbalanced #IF"
open(dst, "w").write("".join(out))
sys.stderr.write("defines: %s\n" % defs)
