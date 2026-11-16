#!/usr/bin/env python3
"""Write an Icarus testbench that checks every translated cell (gls/mkcells.py, module suffix __T)
against the original PDK model (UDPs, Icarus) under random 2-state stimulus.

usage: cellcheck.py <pdk cell .v> <translated cells .v with suffix __T> <out tb .v> [iterations]

Per iteration: non-clock inputs change at t, clock pins (CK, CKN) at t+0.25, outputs are compared at
t+0.5, so no input changes in the same time step as a clock edge (zero-delay race free).
A point is compared when the original output is 0 or 1; the original output is X only until the
first clock edge / reset of a sequential cell. The testbench prints one CELL line per cell with the
number of compared points, original-X points and mismatches, and a CELLCHECK summary.
"""
import re
import sys

src, trans, out = sys.argv[1:4]
iters = int(sys.argv[4]) if len(sys.argv) > 4 else 4000
pdk = open(src).read()
tr = open(trans).read()
cells = re.findall(r"^module\s+(\w+)__T\b", tr, re.M)
cells = [c for c in cells if not c.startswith(("udp_", "ipicg_"))]
CLOCKS = {"CK", "CKN"}
lines = ["`timescale 1ns/1ps", "module tb;", "integer it, cmp, xs, bad, tcmp, tbad, ncells;"]
body, checks = [], []
nchk = 0
for c in cells:
    m = re.search(r"^module\s+%s\b.*?^endmodule" % c, pdk, re.S | re.M)
    if not m:
        continue  # physical-only stub (FILLER*, FILLTAP), no model to compare against
    m = m.group(0)
    m = re.sub(r"\bspecify\b.*?\bendspecify\b", "", m, flags=re.S)
    ins, outs = [], []
    for kind, names in re.findall(r"\b(input|output|inout)\s+([\w\s,]+);", m):
        for n in names.split(","):
            n = n.strip()
            if n:
                (ins if kind == "input" else outs if kind == "output" else []).append(n)
    if not outs:
        continue
    k = nchk; nchk += 1
    for n in ins:
        lines.append("reg i%d_%s;" % (k, n))
    for n in outs:
        lines.append("wire o%d_%s, t%d_%s;" % (k, n, k, n))
    conn_o = ", ".join([".%s(i%d_%s)" % (n, k, n) for n in ins] + [".%s(o%d_%s)" % (n, k, n) for n in outs])
    conn_t = ", ".join([".%s(i%d_%s)" % (n, k, n) for n in ins] + [".%s(t%d_%s)" % (n, k, n) for n in outs])
    lines.append("%s uo%d (%s);" % (c, k, conn_o))
    lines.append("%s__T ut%d (%s);" % (c, k, conn_t))
    lines.append("integer c%d, x%d, b%d;" % (k, k, k))
    data = [n for n in ins if n not in CLOCKS]
    clks = [n for n in ins if n in CLOCKS]
    body.append((k, c, data, clks, outs))
lines.append("initial begin")
lines.append("  tcmp = 0; tbad = 0; ncells = 0;")
for k, c, data, clks, outs in body:
    lines.append("  c%d = 0; x%d = 0; b%d = 0;" % (k, k, k))
lines.append("  for (it = 0; it < %d; it = it + 1) begin" % iters)
for k, c, data, clks, outs in body:
    for n in data:
        lines.append("    i%d_%s = $random;" % (k, n))
lines.append("    #0.25;")
for k, c, data, clks, outs in body:
    for n in clks:
        lines.append("    i%d_%s = $random;" % (k, n))
lines.append("    #0.25;")
for k, c, data, clks, outs in body:
    for n in outs:
        lines.append("    if (o%d_%s === 1'bx || o%d_%s === 1'bz) x%d = x%d + 1; else begin c%d = c%d + 1; if (o%d_%s !== t%d_%s) b%d = b%d + 1; end"
                     % (k, n, k, n, k, k, k, k, k, n, k, n, k, k))
lines.append("    #0.5;")
lines.append("  end")
for k, c, data, clks, outs in body:
    lines.append('  $display("CELL %-16s compared=%%0d orig_x=%%0d mismatches=%%0d", c%d, x%d, b%d); tcmp = tcmp + c%d; tbad = tbad + b%d; ncells = ncells + 1;'
                 % (c, k, k, k, k, k))
    lines.append("  if (c%d == 0) begin $display(\"CELL %s NEVER COMPARED\"); tbad = tbad + 1; end" % (k, c))
lines.append('  $display("CELLCHECK cells=%0d compared=%0d mismatches=%0d => %s", ncells, tcmp, tbad, tbad ? "FAIL" : "PASS");')
lines.append("  $finish;")
lines.append("end")
lines.append("endmodule")
open(out, "w").write("\n".join(lines) + "\n")
